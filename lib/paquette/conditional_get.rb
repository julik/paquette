require "rack"
require "time"
require "digest"

# Conditional GET and cache directives, shared by both servers so the
# security-critical answers cannot drift between them. The including class
# supplies `@request` (the Rack::Request being served), `@repository` (the
# wrapper stack) and `@shared_caching`.
module Paquette::ConditionalGet
  # A year, the longest max-age RFC 9111 suggests anyone bother emitting,
  # paired with `immutable` so a revalidating client does not even ask.
  IMMUTABLE_MAX_AGE = 31_536_000

  private

  # The validator for one response. nil (no ETag at all) when the stack
  # refuses to name itself: a wrong ETag on a gated index is worse than
  # serving every request in full.
  #
  # @param resource_parts [Array<String>] what distinguishes this endpoint's
  #   body from another's over the same corpus
  # @param weak [Boolean]
  # @return [String, nil]
  def etag_for(*resource_parts, weak: false)
    Paquette::CacheValidation.etag_for(@repository, *resource_parts, weak: weak)
  end

  # Request headers that carry a credential. A request with either one is
  # never answered `public` — these are the two Rack::Cache itself treats
  # as private by default.
  CREDENTIAL_HEADERS = %w[HTTP_AUTHORIZATION HTTP_COOKIE].freeze

  # `public` only when the embedder allowed shared caching, the request
  # carried no credential and nothing in the stack varies by caller —
  # getting this wrong serves one caller's view to the next. `no-cache`
  # rather than `no-store` so the 304 stays reachable.
  #
  # @param max_age [Integer, nil]
  # @return [Hash{String => String}]
  def cache_directives(max_age: nil)
    scope = shareable_response? ? "public" : "private"
    control = max_age ? "#{scope}, max-age=#{max_age}, immutable" : "#{scope}, no-cache"
    {"cache-control" => control, "vary" => vary_header}
  end

  # @return [Boolean]
  def shareable_response?
    return false unless @shared_caching
    return false if CREDENTIAL_HEADERS.any? { |name| @request.has_header?(name) }

    !Paquette::CacheValidation.varies_by_caller?(@repository)
  end

  # Not sufficient on its own — several CDNs ignore Vary on anything but
  # Accept-Encoding; `private` is what actually stands between two callers.
  #
  # @return [String]
  def vary_header
    "Authorization, Cookie, Accept-Encoding"
  end

  # What every response leaving either server goes through. Anything a
  # handler did not label is `private, no-store`: it carries no validator,
  # so nothing could revalidate it.
  #
  # @param response [Array] a Rack response triplet
  # @return [Array] a Rack response triplet
  def with_caching_defaults(response)
    status, headers, body = response
    # Rack::Headers rather than a plain Hash: handlers here spell names in
    # title case and Rack::Files in lowercase, and a plain Hash would let one
    # response carry both `Cache-Control` and `cache-control` — which a cache
    # is entitled to read as whichever it finds first.
    headers = Rack::Headers[headers]
    headers["cache-control"] ||= "private, no-store"
    headers["vary"] = vary_with_authorization(headers["vary"])
    [status, headers, body]
  end

  # @param vary [String, nil] the Vary already on the response
  # @return [String] that Vary with Authorization merged in
  def vary_with_authorization(vary)
    fields = vary.to_s.split(",").map(&:strip).reject(&:empty?)
    return "*" if fields.include?("*")

    fields << "Authorization" unless fields.any? { |field| field.casecmp?("Authorization") }
    fields.join(", ")
  end

  # A 200 with the validator and the caching directives attached. An absent
  # etag (fail-closed) still gets the directives: the response is then
  # simply uncacheable-without-asking rather than mislabelled.
  #
  # @param response [Array] a Rack response triplet
  # @param etag [String, nil]
  # @return [Array] a Rack response triplet
  def cacheable(response, etag)
    status, headers, body = response
    headers = Rack::Headers[headers].merge!(cache_directives)
    headers["etag"] = etag if etag
    [status, headers, body]
  end

  # `cacheable` plus ranges — what makes Bundler >= 2.5 fetch the compact
  # index incrementally. `Repr-Digest` carries the digest of the *whole*
  # representation even on a 206 (RFC 9530), or Bundler will not append;
  # `Digest:` is the obsolete RFC 3230 spelling some intermediaries read.
  #
  # @param response [Array] a Rack response triplet, body already in hand
  # @param etag [String, nil]
  # @return [Array] a Rack response triplet
  def cacheable_with_ranges(response, etag)
    status, headers, body = cacheable(response, etag)
    content = +""
    body.each { |chunk| content << chunk }

    digest = Digest::SHA256.base64digest(content)
    headers["accept-ranges"] = "bytes"
    headers["repr-digest"] = "sha-256=:#{digest}:"
    headers["digest"] = "sha-256=#{digest}"

    range = requested_byte_range(content.bytesize, etag)
    return [status, headers, [content]] if range.nil?

    headers["content-range"] = "bytes #{range.begin}-#{range.end}/#{content.bytesize}"
    [206, headers, [content.byteslice(range)]]
  end

  # The single byte range this request asks for, or nil for "serve the
  # whole thing" — never a 416, which would turn a Bundler that merely
  # guessed the tail wrong into a failed install. Called after the
  # conditional check: a matching If-None-Match is a 304, not a 206.
  #
  # @param size [Integer] the body size in bytes
  # @param etag [String, nil]
  # @return [Range, nil]
  def requested_byte_range(size, etag)
    header = @request.get_header("HTTP_RANGE")
    return nil if header.nil? || size.zero?
    return nil unless if_range_allows_range?(etag)

    parse_byte_range(header, size)
  end

  # Absent, If-Range allows the range. Present, only a strong tag equal to
  # ours does: a weak validator says nothing about byte offsets, and a date
  # says nothing about a body that is not a file.
  #
  # @param etag [String, nil]
  # @return [Boolean]
  def if_range_allows_range?(etag)
    if_range = @request.get_header("HTTP_IF_RANGE")
    return true if if_range.nil?

    !etag.nil? && !etag.start_with?("W/") && if_range.strip == etag
  end

  # The longest Range header worth looking at: a single byte range is two
  # numbers and a dash, anything longer is multi-range or junk.
  MAX_RANGE_HEADER_BYTES = 128

  # One offset, bounded, because this string is client-chosen: `\d+` would
  # let a caller hand us a megabyte of digits to convert to an Integer.
  BYTE_OFFSET = /\A[0-9]{1,19}\z/

  # Parses `bytes=first-last`, with either side optionally empty, and
  # nothing else. String operations rather than a pattern over the whole
  # header, per AGENTS.md.
  #
  # @param header [String]
  # @param size [Integer]
  # @return [Range, nil]
  def parse_byte_range(header, size)
    spec = header.to_s.strip
    return nil if spec.bytesize > MAX_RANGE_HEADER_BYTES
    return nil unless spec.start_with?("bytes=")

    first, dash, last = spec.delete_prefix("bytes=").partition("-")
    return nil if dash.empty?
    return nil unless first.empty? || first.match?(BYTE_OFFSET)
    return nil unless last.empty? || last.match?(BYTE_OFFSET)
    return suffix_byte_range(last, size) if first.empty?

    first_byte = first.to_i
    return nil if first_byte >= size

    last_byte = last.empty? ? size - 1 : [last.to_i, size - 1].min
    return nil if last_byte < first_byte

    first_byte..last_byte
  end

  # `bytes=-N` asks for the final N bytes. A bare `bytes=-` names no number
  # and `bytes=-0` asks for nothing; neither is satisfiable, so both get the
  # whole body.
  #
  # @param last [String]
  # @param size [Integer]
  # @return [Range, nil]
  def suffix_byte_range(last, size)
    return nil if last.empty?

    length = last.to_i
    return nil if length.zero?

    [size - length, 0].max..(size - 1)
  end

  # A 304 repeats the validator and the directives — a shared cache
  # updates its stored headers from it.
  #
  # @param etag [String, nil]
  # @param extra [Hash{String => String}] extra headers
  # @return [Array] a Rack response triplet
  def not_modified(etag, extra: {})
    headers = Rack::Headers[cache_directives(max_age: extra.key?("Last-Modified") ? IMMUTABLE_MAX_AGE : nil)]
    headers["etag"] = etag if etag
    [304, headers.merge!(extra), []]
  end

  # A response that must never be stored by anything, for content that is
  # the caller's identity itself.
  #
  # @param response [Array] a Rack response triplet
  # @return [Array] a Rack response triplet
  def uncacheable(response)
    status, headers, body = response
    [status, Rack::Headers[headers].merge!("cache-control" => "private, no-store", "vary" => vary_header), body]
  end

  # If-None-Match wins over If-Modified-Since when both are present, which
  # is what RFC 9110 requires.
  #
  # @param etag [String, nil]
  # @param mtime [Time]
  # @return [Boolean, nil]
  def conditional_hit?(etag, mtime)
    return if_none_match_satisfied?(etag) if @request.get_header("HTTP_IF_NONE_MATCH")

    if_modified_since_satisfied?(mtime)
  end

  # @param etag [String, nil]
  # @return [Boolean]
  def if_none_match_satisfied?(etag)
    return false if etag.nil?

    header = @request.get_header("HTTP_IF_NONE_MATCH")
    return false if header.nil?
    return true if header.strip == "*"

    ours = opaque_tag(etag)
    header.split(",").any? { |candidate| opaque_tag(candidate) == ours }
  end

  # Weak comparison, which is what If-None-Match on a GET calls for: a
  # W/"x" a client holds matches the "x" we would send. String operations
  # rather than a regexp because the value is client-chosen and arbitrarily
  # long (see AGENTS.md).
  #
  # @param value [String]
  # @return [String]
  def opaque_tag(value)
    tag = value.to_s.strip
    tag = tag.delete_prefix("W/")
    tag.delete_prefix('"').delete_suffix('"')
  end

  # An unparseable date is not a match; second resolution is all an HTTP
  # date has.
  #
  # @param mtime [Time]
  # @return [Boolean]
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

  # Rack::Files, so the range machinery is Rack's rather than ours. A nil
  # root: #serving takes an absolute path and never reads @root, and the
  # path is the repository's to decide.
  #
  # @return [Rack::Files]
  def package_file_server
    @package_file_server ||= Rack::Files.new(nil, {}, "application/octet-stream")
  end

  # Serves one immutable artifact off disk — a .gem or .tgz at a given
  # path never changes; yank and unpublish rename away.
  #
  # @param path [String] absolute path of the file
  # @param stat [File::Stat]
  # @param etag [String, nil]
  # @return [Array] a Rack response triplet
  def serve_immutable_file(path, stat, etag)
    last_modified = stat.mtime.httpdate

    # Before Rack::Files gets a look in, because the whole point of a
    # conditional GET is to not open the file at all.
    if conditional_hit?(etag, stat.mtime)
      return not_modified(etag, extra: {"Last-Modified" => last_modified})
    end

    status, headers, body = package_file_server.serving(rack_files_request(etag, stat), path)

    headers = Rack::Headers[headers]

    # Rack::Files honours Range but never advertises it, so a client that
    # looks before it leaps is told nothing.
    headers["accept-ranges"] = "bytes"
    headers["etag"] = etag if etag
    headers["last-modified"] = last_modified
    headers.merge!(cache_directives(max_age: IMMUTABLE_MAX_AGE))

    [status, headers, body]
  end

  # The request as Rack::Files should see it: If-Modified-Since comes out
  # because we already answered it (Rack::Files would 304 bare, dropping
  # ETag and Cache-Control), and If-Range is answered here by dropping the
  # Range header, because Rack::Files does not implement it at all.
  #
  # @param etag [String, nil]
  # @param stat [File::Stat]
  # @return [Rack::Request]
  def rack_files_request(etag, stat)
    env = @request.env.except("HTTP_IF_MODIFIED_SINCE")

    if_range = @request.get_header("HTTP_IF_RANGE")
    if if_range && !if_range_matches?(if_range, etag, stat)
      env = env.except("HTTP_RANGE")
    end

    Rack::Request.new(env)
  end

  # An If-Range carries either an entity tag or an HTTP date. A tag is
  # compared strongly — a weak validator says nothing about byte offsets,
  # which is the only thing this comparison is for.
  #
  # @param if_range [String]
  # @param etag [String, nil]
  # @param stat [File::Stat]
  # @return [Boolean]
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
