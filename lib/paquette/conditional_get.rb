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
#
# Nothing either server sends is `public` unless the request carried no
# credential and nothing in the stack varies by caller. See
# cache_directives for why.
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

  # Request headers that carry a credential. A request with either one is
  # never answered `public`, whatever the stack looks like - these are the
  # two Rack::Cache itself treats as private by default.
  CREDENTIAL_HEADERS = %w[HTTP_AUTHORIZATION HTTP_COOKIE].freeze

  # Cache-Control, and the reason this feature is not simply "emit an ETag".
  #
  # Paquette does not require authentication, so an open registry is a
  # real configuration and deserves headers a CDN can use. But most
  # deployments put a credential in front, and the same URL is routinely
  # served ungated to one caller (the owner reading the unwrapped
  # repository with a publishing token) and gated to the next. The cache
  # Paquette tells embedders to put in front (rack-cache, Rails'
  # Rack::Cache, a CDN) is *shared* and keyed on the URL. RFC 9111 keeps a
  # shared cache from storing a response to a request that carried
  # Authorization - and `public` is the directive that overrides exactly
  # that rule. Rack::Cache honours it to the letter: a `public` answer to a
  # publisher's authorized download used to be stored, and the next
  # anonymous request for the URL was answered out of the cache without
  # the embedder's gate ever running.
  #
  # So `public` is decided per request, and only when all of these hold:
  #
  # - the server was not built with `shared_caching: false`, which is how
  #   an embedder says it authorizes by something Paquette cannot see (an
  #   IP allowlist, mTLS, a header checked in middleware);
  # - the request carries no credential (CREDENTIAL_HEADERS);
  # - nothing in the wrapper stack varies by caller. A gate may decide by
  #   something Paquette cannot see either, so two anonymous callers can
  #   get different answers from it, and a personalizer bakes each
  #   licensee's bytes. A repository that cannot say is taken to vary.
  #
  # Everything else is `private`, which keeps every shared cache out while
  # the client's own cache - Bundler's compact index, npm's metadata cache -
  # still keeps its copy and revalidates it.
  #
  # `no-cache` rather than `no-store` on the index endpoints: it still
  # forces a revalidation on each use, so nothing stale is served, while
  # letting the client (and, when public, a CDN) keep the copy it needs in
  # order to send If-None-Match at all. `no-store` would make the 304
  # unreachable on precisely the most expensive endpoints there are. It is
  # `no-cache` rather than a short max-age for a CDN too: a push or a yank
  # is visible on the next request instead of a max-age later, and the
  # revalidation it costs is answered from the corpus fingerprint without
  # rendering anything.
  def cache_directives(max_age: nil)
    scope = shareable_response? ? "public" : "private"
    control = max_age ? "#{scope}, max-age=#{max_age}, immutable" : "#{scope}, no-cache"
    {"cache-control" => control, "vary" => vary_header}
  end

  def shareable_response?
    return false unless @shared_caching
    return false if CREDENTIAL_HEADERS.any? { |name| @request.has_header?(name) }

    !Paquette::CacheValidation.varies_by_caller?(@repository)
  end

  # Emitted on everything a handler labels, public or private.
  #
  # On a `public` response it is what stops a Vary-honouring cache
  # (Rack::Cache is one) from handing the anonymous copy it stored to a
  # request that carries a credential - and so may be entitled to a
  # different answer. Cookie is in there for the same reason it is in
  # CREDENTIAL_HEADERS.
  #
  # It is emphatically not sufficient on its own, and must never be read as
  # if it were: several CDNs ignore Vary on anything but Accept-Encoding
  # unless told otherwise, and Paquette does not resolve identity - the
  # embedder may carry the licensee in a client certificate or a
  # subdomain. `private` on every credentialed or caller-specific response
  # is what actually stands between two callers.
  #
  # Accept-Encoding is in there because a compressing proxy in front of
  # these JSON and text bodies would otherwise let one encoding's stored
  # response answer a request that cannot read it.
  def vary_header
    "Authorization, Cookie, Accept-Encoding"
  end

  # What every response leaving either server goes through, whichever
  # handler made it - an error, the placeholder page, a legacy Marshal
  # index nobody ever gave a validator.
  #
  # Anything a handler did not label is `private, no-store`, whoever asks
  # and whatever the stack: it carries no
  # validator, so there is nothing a client could revalidate, and there is
  # no reason for a shared cache to so much as consider it. Vary always
  # names Authorization, merged into whatever Vary is there already.
  #
  # The headers come out as a Rack::Headers. Handlers here spell names in
  # title case and Rack::Files in lowercase, and a plain Hash would let one
  # response carry both `Cache-Control` and `cache-control` - which a cache
  # is entitled to read as whichever of the two it finds first.
  def with_caching_defaults(response)
    status, headers, body = response
    headers = Rack::Headers[headers]
    headers["cache-control"] ||= "private, no-store"
    headers["vary"] = vary_with_authorization(headers["vary"])
    [status, headers, body]
  end

  def vary_with_authorization(vary)
    fields = vary.to_s.split(",").map(&:strip).reject(&:empty?)
    return "*" if fields.include?("*")

    fields << "Authorization" unless fields.any? { |field| field.casecmp?("Authorization") }
    fields.join(", ")
  end

  # A 200 with the validator and the caching directives attached. An absent
  # etag (fail-closed) still gets the directives: the response is then
  # simply uncacheable-without-asking rather than mislabelled.
  def cacheable(response, etag)
    status, headers, body = response
    headers = Rack::Headers[headers].merge!(cache_directives)
    headers["etag"] = etag if etag
    [status, headers, body]
  end

  # A 304 repeats the validator and the directives. One that omitted them
  # would teach the client nothing, and would leave a shared cache to
  # update its stored headers from a response that says nothing about who
  # may keep it.
  def not_modified(etag, extra: {})
    headers = Rack::Headers[cache_directives(max_age: extra.key?("Last-Modified") ? IMMUTABLE_MAX_AGE : nil)]
    headers["etag"] = etag if etag
    [304, headers.merge!(extra), []]
  end

  # A response that must never be stored by anything, for content that is
  # the caller's identity itself. `private` as well as `no-store`, whatever
  # the request carried.
  def uncacheable(response)
    status, headers, body = response
    [status, Rack::Headers[headers].merge!("cache-control" => "private, no-store", "vary" => vary_header), body]
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
    # one header - with_private_caching does the same for every response.
    headers = Rack::Headers[headers]

    # Rack::Files honours Range but never advertises it, so a client that
    # looks before it leaps is told nothing. Everything here is a seekable
    # file on disk, so the answer is unconditionally yes.
    headers["accept-ranges"] = "bytes"
    headers["etag"] = etag if etag
    headers["last-modified"] = last_modified
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
