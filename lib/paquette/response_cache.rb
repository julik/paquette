require "digest"
require "fileutils"
require "json"
require "measurometer"
require "securerandom"

# Keeps whole 200s of either server on disk, one entry per credential, and
# replays one only when the server says it is still current. Rack::Cache cannot
# do this here: a response to a request with credentials is `private`, and a
# shared cache refuses to store those, so behind authentication it stores
# nothing at all.
#
# Every request still reaches the server - with `If-None-Match` set to the
# stored entry's ETag. A server that can name its stack (a ReadGatedRepository
# given a `gate_key:`, say) answers that with a 304 before rendering anything,
# and the stored body goes out as the 200. So the authenticator and the gate are
# asked every time: a revoked token is refused even with a body on disk for it,
# and a response without an ETag is never stored.
#
#   use Paquette::ResponseCache, directory: "tmp/cache/gems"
#   run Paquette::GemServer.new(repo, authenticator: authenticator)
#
# Entries are keyed by the URL, the credential, and whether `Accept` asks for
# JSON - the PyPI index answers one URL in HTML or JSON. The key is not what
# keeps two callers apart - the ETag is, since the stored one has to be current
# for the caller asking - but it keeps each token from overwriting another's
# entry, and a gate_key that wrongly names two customers alike from serving one's
# body to the other.
#
# Only requests with credentials and without a query string are stored, and
# the client's own headers go into the key only as that one bit. So a stranger
# puts nothing on disk, and a credential at most two entries per index URL it
# may read: an anonymous response is the same for everybody and a 304 away
# anyway, and a query string or a raw header is anybody's to vary. Nothing is
# evicted beyond that, and the directory can be emptied at any time. Keep a
# compressor such as Rack::Deflater outside the cache, since the encoding is not
# in the key.
class Paquette::ResponseCache
  prepend Paquette::RegexpTimeout

  # The largest body worth keeping. Gem and tarball downloads are files already
  # and are never stored; what is left is indexes and package documents.
  DEFAULT_MAX_BODY_BYTES = 8 * 1024 * 1024 #: Integer

  # What happened, for the application's own log line: "hit", "miss" or "bypass".
  OUTCOME_KEY = "paquette.response_cache"

  # Headers that are about one response on the wire rather than the content.
  UNSTORED_HEADERS = %w[connection keep-alive transfer-encoding date age content-length].freeze #: Array[String]

  # - `app`: the Rack app to cache
  # - `directory`: where entries live, created when missing
  #
  #: (Paquette::_RackApp app, directory: String, ?max_body_bytes: Integer) -> void
  def initialize(app, directory:, max_body_bytes: DEFAULT_MAX_BODY_BYTES)
    @app = app
    @directory = directory.to_s
    @max_body_bytes = max_body_bytes
  end

  #: (Paquette::rack_env env) -> Paquette::rack_response
  def call(env)
    return record(env, "bypass") { @app.call(env) } unless cacheable_request?(env)

    key = key_for(env)
    entry = read(key)
    entry ? revalidate(env, key, entry) : record(env, "miss") { fetch(env, key) }
  end

  private

  # A Range is a slice of a body the server builds anyway, and Bundler sends one
  # only alongside an If-None-Match the server can answer by itself.
  #
  #: (Paquette::rack_env env) -> bool
  def cacheable_request?(env)
    env["REQUEST_METHOD"] == "GET" && !env.key?("HTTP_RANGE") &&
      # Binary: `strip` raises on a header that is not valid UTF-8
      !env["HTTP_AUTHORIZATION"].to_s.b.strip.empty? && env["QUERY_STRING"].to_s.empty?
  end

  # The env is the caller's own and is handed on, not copied: an application
  # that leaves notes in it for its log line has to find them afterwards.
  #
  #: (Paquette::rack_env env, String key, Hash[untyped, untyped] entry) -> Paquette::rack_response
  def revalidate(env, key, entry)
    client_etags = env["HTTP_IF_NONE_MATCH"]
    env["HTTP_IF_NONE_MATCH"] = entry.fetch("etag")
    status, headers, body = begin
      @app.call(env)
    ensure
      client_etags.nil? ? env.delete("HTTP_IF_NONE_MATCH") : env["HTTP_IF_NONE_MATCH"] = client_etags
    end

    unless status == 304
      # A refusal must not leave a body behind for when the credential is
      # good again
      delete(key) if (400..499).cover?(status)
      return record(env, "miss") { store_and_answer(env, key, [status, headers, body]) }
    end

    body.close if body.respond_to?(:close)
    record(env, "hit") do
      fresh = Rack::Headers[entry.fetch("headers")].merge!(Rack::Headers[headers].except("content-length"))
      if etag_matches?(client_etags, entry.fetch("etag"))
        [304, Rack::Headers[headers], []]
      else
        [200, fresh, [File.binread(body_path(key))]]
      end
    end
  rescue Errno::ENOENT # the body went missing between the read and now
    delete(key)
    record(env, "miss") { fetch(env, key) }
  end

  #: (Paquette::rack_env env, String key) -> Paquette::rack_response
  def fetch(env, key)
    store_and_answer(env, key, @app.call(env))
  end

  #: (Paquette::rack_env env, String key, Paquette::rack_response response) -> Paquette::rack_response
  def store_and_answer(env, key, response)
    status, headers, body = response
    headers = Rack::Headers[headers]
    return response unless storable?(status, headers, body)

    chunks = []
    size = 0
    body.each do |chunk|
      chunks << chunk
      size += chunk.bytesize
    end
    body.close if body.respond_to?(:close)

    if size <= @max_body_bytes
      write(key, headers, chunks)
      Measurometer.increment_counter("paquette.response_cache.stored")
    end

    if etag_matches?(env["HTTP_IF_NONE_MATCH"], headers["etag"])
      [304, headers.except("content-length"), []]
    else
      [status, headers, chunks]
    end
  end

  #: (Integer status, Rack::Headers headers, untyped body) -> bool
  def storable?(status, headers, body)
    return false unless status == 200 && headers["etag"]
    return false if headers["set-cookie"] || body.respond_to?(:to_path)
    return false if headers["cache-control"].to_s.downcase.include?("no-store")
    return false if headers["vary"].to_s.strip == "*"

    declared = headers["content-length"]
    declared.nil? || declared.to_i <= @max_body_bytes
  end

  # Weak comparison, as RFC 9110 asks of If-None-Match.
  #
  # - `header`: the client's If-None-Match
  #
  #: (String? header, String? etag) -> bool
  def etag_matches?(header, etag)
    return false if header.nil? || etag.nil?

    ours = etag.delete_prefix("W/")
    header.split(",").any? do |candidate|
      candidate = candidate.strip
      candidate == "*" || candidate.delete_prefix("W/") == ours
    end
  end

  #: (Paquette::rack_env env, String outcome) { () -> Paquette::rack_response } -> Paquette::rack_response
  def record(env, outcome)
    env[OUTCOME_KEY] = outcome
    Measurometer.increment_counter("paquette.response_cache.#{outcome}")
    yield
  end

  # The URL with its host and scheme: npm package documents carry absolute
  # tarball URLs built from them. A request with a query string is not stored,
  # so there is none to leave out.
  #
  #: (Paquette::rack_env env) -> String
  def key_for(env)
    request = Rack::Request.new(env)
    digest = Digest::SHA256.new
    digest << request.base_url << request.script_name << request.path_info
    # Paquette reads its token out of Authorization and nothing else, so a
    # cookie would only make each new one a miss
    digest << "\0" << env["HTTP_AUTHORIZATION"].to_s
    digest << "\0" << (env["HTTP_ACCEPT"].to_s.include?("json") ? "json" : "")
    digest.hexdigest
  end

  #: (String key) -> Hash[untyped, untyped]?
  def read(key)
    entry = JSON.parse(File.read(meta_path(key)))
    entry if entry["etag"].is_a?(String) && entry["headers"].is_a?(Hash) && File.exist?(body_path(key))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  # Body first and the metadata last, each renamed into place, so a reader
  # never finds metadata pointing at half a body.
  #
  #: (String key, Rack::Headers headers, Array[String] chunks) -> void
  def write(key, headers, chunks)
    FileUtils.mkdir_p(File.dirname(meta_path(key)))
    kept = headers.to_h.except(*UNSTORED_HEADERS)
    atomically(body_path(key)) { |io| chunks.each { |chunk| io.write(chunk) } }
    atomically(meta_path(key)) { |io| io.write(JSON.dump("etag" => headers["etag"], "headers" => kept)) }
  end

  #: (String path) { (::File io) -> void } -> void
  def atomically(path)
    temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
    File.open(temporary, "wb") { |io| yield io }
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
  end

  #: (String key) -> void
  def delete(key)
    FileUtils.rm_f([meta_path(key), body_path(key)])
  end

  #: (String key) -> String
  def meta_path(key)
    File.join(@directory, shard_of(key), "#{key}.json")
  end

  #: (String key) -> String
  def body_path(key)
    File.join(@directory, shard_of(key), "#{key}.body")
  end

  #: (String key) -> String
  def shard_of(key)
    key[0, 2] #: String
  end
end
