require "rack"
require "time"

# Conditional GET and cache directives, shared by both servers.
#
# Mixed into GemServer and NpmServer, which each supply `@request` (the
# Rack::Request being served) and `@repository` (the wrapper stack). The
# two servers ask the same questions of HTTP and must not answer them
# differently, which is the whole reason this is one module and not two
# copies: a validator comparison or a `private` directive that drifted
# between them would be a confidentiality bug on whichever side lost.
module Paquette::ConditionalGet
  # A year, the longest max-age RFC 9111 suggests anyone bother emitting,
  # paired with `immutable` so a revalidating client does not even ask.
  IMMUTABLE_MAX_AGE = 31_536_000

  private

  # The validator for one response: the whole wrapper stack's
  # cache_validator, plus whatever distinguishes this endpoint's body from
  # another's over the same corpus.
  #
  # nil when the stack refuses to name itself - a read gate built without a
  # gate_key is the case that matters - and nil means no ETag is emitted at
  # all. That is the fail-closed half of the design: a validator derived
  # from the corpus alone would let one licensee's cached response satisfy
  # another licensee's request, and a wrong ETag on a gated index is worse
  # than serving every request in full.
  def etag_for(*resource_parts, weak: false)
    Paquette::CacheValidation.etag_for(@repository, *resource_parts, weak: weak)
  end

  # Cache-Control, and the reason this feature is not simply "emit an ETag".
  #
  # Paquette caches nothing itself and tells embedders to put an ordinary
  # HTTP cache in front (rack-cache, or Rails' Rack::Cache integration).
  # Those are *shared* caches: they key on the URL, and a response marked
  # `public` is one they will store once and replay to whoever asks next.
  # For a gated or personalized response that next requester is a different
  # licensee, and what they would receive is somebody else's entitlements -
  # or, on the npm side, integrity hashes for a tarball they will never be
  # handed. So anything that passed through a gate or a personalizer is
  # `private`, full stop, and never carries `public`.
  #
  # `Cache-Control: private` is the load-bearing control here. `Vary` is
  # defence in depth and nothing more - see vary_header below.
  #
  # `no-cache` rather than `no-store` on the index endpoints: `private`
  # already keeps the response out of every shared cache, and `no-cache`
  # still forces a revalidation on each use, so nothing stale is served.
  # `no-store` would additionally stop the *client* - Bundler's compact
  # index, npm's own metadata cache - from keeping the copy it needs in
  # order to send If-None-Match at all, which would make the 304
  # unreachable on precisely the most expensive endpoints there are.
  def cache_directives(max_age: nil)
    if Paquette::CacheValidation.private_to_caller?(@repository)
      control = max_age ? "private, max-age=#{max_age}, immutable" : "private, no-cache"
      {"Cache-Control" => control, "Vary" => vary_header}
    else
      control = max_age ? "public, max-age=#{max_age}, immutable" : "public, no-cache"
      {"Cache-Control" => control}
    end
  end

  # Emitted alongside `private`, and honest for the auth flow this gem
  # documents: TokenAuthorization reads the token out of Authorization, in
  # both its Bearer and its Basic spelling.
  #
  # It is emphatically not sufficient on its own, and must never be read as
  # if it were. Paquette does not resolve identity - the embedding
  # application does, and the README's own example resolves the user from
  # env["REMOTE_USER"]. An application may just as well carry the licensee
  # in a cookie, a client certificate or a subdomain. A shared cache keyed
  # only on Authorization would then serve one licensee's packument to
  # another quite happily, which is why `private` is what actually stands
  # between two licensees and this header is only defence in depth.
  #
  # Accept-Encoding is in there because a compressing proxy in front of
  # these JSON and text bodies would otherwise let one encoding's stored
  # response answer a request that cannot read it.
  def vary_header
    "Authorization, Accept-Encoding"
  end

  # A 200 with the validator and the caching directives attached. An absent
  # etag (fail-closed) still gets the directives: the response is then
  # simply uncacheable-without-asking rather than mislabelled.
  def cacheable(response, etag)
    status, headers, body = response
    headers = headers.merge(cache_directives)
    headers["ETag"] = etag if etag
    [status, headers, body]
  end

  # A 304 repeats the validator and the directives. One that omitted them
  # would teach the client nothing and would show a shared cache no
  # `private`, which is worse than not answering conditionally at all.
  def not_modified(etag, extra: {})
    headers = cache_directives(max_age: extra.key?("Last-Modified") ? IMMUTABLE_MAX_AGE : nil)
    headers["ETag"] = etag if etag
    [304, headers.merge(extra), []]
  end

  # A response that must never be stored by anything, for content that is
  # the caller's identity itself.
  def uncacheable(response)
    status, headers, body = response
    [status, headers.merge("Cache-Control" => "no-store", "Vary" => vary_header), body]
  end

  # If-None-Match wins over If-Modified-Since when both are present, which
  # is what RFC 9110 requires: the entity tag is the precise question and
  # the date is the approximation.
  def conditional_hit?(etag, mtime)
    return if_none_match_satisfied?(etag) if @request.get_header("HTTP_IF_NONE_MATCH")

    if_modified_since_satisfied?(mtime)
  end

  def if_none_match_satisfied?(etag)
    return false if etag.nil?

    header = @request.get_header("HTTP_IF_NONE_MATCH")
    return false if header.nil?
    return true if header.strip == "*"

    ours = opaque_tag(etag)
    header.split(",").any? { |candidate| opaque_tag(candidate) == ours }
  end

  # Weak comparison, which is what If-None-Match on a GET calls for: a
  # W/"x" a client holds matches the "x" we would send, and vice versa.
  # Done with delete_prefix and delete_suffix rather than a regexp on
  # purpose - this string is client-chosen and arbitrarily long, and the
  # house rule is not to point a pattern at one when plain string
  # operations will do (see AGENTS.md).
  def opaque_tag(value)
    tag = value.to_s.strip
    tag = tag.delete_prefix("W/")
    tag.delete_prefix('"').delete_suffix('"')
  end

  # An unparseable date is not a match - Time.httpdate raises on anything
  # that is not one, and a client sending garbage gets the full body rather
  # than an error. Second resolution, because that is all an HTTP date has.
  def if_modified_since_satisfied?(mtime)
    header = @request.get_header("HTTP_IF_MODIFIED_SINCE")
    return false if header.nil?

    since = begin
      Time.httpdate(header)
    rescue ArgumentError
      return false
    end

    mtime.to_i <= since.to_i
  end

  # One file off disk, which is exactly what Rack::Files is for - so the
  # range machinery is Rack's rather than ours or a dependency's. It gives
  # us 206 with a Content-Range, multipart/byteranges for several ranges at
  # once, a 416 carrying "bytes */size" for one that cannot be satisfied,
  # and - the fiddly bit - a Range header whose *unit* is not "bytes"
  # ignored outright per RFC 9110 rather than refused.
  #
  # Rack::Files.new(nil): #serving takes an absolute path and never reads
  # @root, and the path here is the repository's to decide - a Personalizer
  # answers with a materialized file somewhere else entirely. Routing that
  # through Rack's root-joining would be wrong, so there is no root.
  #
  # The body it returns is a Rack::Files::Iterator, which opens the file
  # inside a block per read and aliases #to_path, so a server that can use
  # sendfile will.
  def package_file_server
    @package_file_server ||= Rack::Files.new(nil, {}, "application/octet-stream")
  end

  # Both servers hand out immutable artifacts: a .gem at a given path never
  # changes (a yank renames it away and a name+version cannot be pushed
  # twice) and neither does a .tgz (an unpublish leaves a tomb behind that
  # stops the version being republished with different bytes).
  def serve_immutable_file(path, stat, etag)
    last_modified = stat.mtime.httpdate

    # Before Rack::Files gets a look in, because the whole point of a
    # conditional GET is to not open the file at all.
    if conditional_hit?(etag, stat.mtime)
      return not_modified(etag, extra: {"Last-Modified" => last_modified})
    end

    status, headers, body = package_file_server.serving(rack_files_request(etag, stat), path)

    # Rack::Files emits the lowercase header names Rack 3 asks for, and the
    # rest of these servers still spell them in title case. Rack::Headers
    # reads either way and emits the lowercase ones, so the two conventions
    # can meet here without producing a response carrying both spellings of
    # one header.
    headers = Rack::Headers[headers]

    # Rack::Files honours Range but never advertises it, so a client that
    # looks before it leaps is told nothing. Everything here is a seekable
    # file on disk, so the answer is unconditionally yes.
    headers["Accept-Ranges"] = "bytes"
    headers["ETag"] = etag if etag
    headers["Last-Modified"] = last_modified
    headers.merge!(cache_directives(max_age: IMMUTABLE_MAX_AGE))

    [status, headers, body]
  end

  # The request as Rack::Files should see it, which is not quite the one
  # that arrived.
  #
  # If-Modified-Since is taken out because we have already answered it -
  # Rack::Files would otherwise apply its own exact-string comparison and
  # return a bare [304, {}, []], dropping the ETag and the Cache-Control on
  # the way out. It would also get the precedence wrong: an If-None-Match
  # that did *not* match means "send the body", and a date must not
  # override that.
  #
  # If-Range is handled here because Rack::Files does not implement it at
  # all. A client resuming a download holds offsets into a representation
  # it fetched earlier; if the bytes have changed since, those offsets
  # describe nothing, and splicing them into the file now on disk yields an
  # artifact that is a mixture of two. The rule is to serve the whole
  # entity instead, which is done by dropping the Range header.
  def rack_files_request(etag, stat)
    env = @request.env.except("HTTP_IF_MODIFIED_SINCE")

    if_range = @request.get_header("HTTP_IF_RANGE")
    if if_range && !if_range_matches?(if_range, etag, stat)
      env = env.except("HTTP_RANGE")
    end

    Rack::Request.new(env)
  end

  # An If-Range carries either an entity tag or an HTTP date. A tag is
  # compared strongly - a weak validator says nothing about byte offsets,
  # which is the only thing this comparison is for.
  def if_range_matches?(if_range, etag, stat)
    return false if if_range.start_with?("W/")
    return if_range.strip == etag if etag && if_range.strip.start_with?('"')

    begin
      Time.httpdate(if_range).to_i == stat.mtime.to_i
    rescue ArgumentError
      false
    end
  end
end
