require "digest"
require "fileutils"
require "json"
require "measurometer"
require "securerandom"

# Keeps whole 200s of either server on disk, one entry per caller, and
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
# Which entry is the caller's is the server's to say, and only once the
# Paquette::Authenticator it built for the request has let the read in: the
# cache leaves a Lookup in the env, and the server hands it what `identity` on
# that authenticator says the token belongs to - a user or a license, never the
# token itself, so a rotated token finds the entries the old one left. An env
# key with a dot in it cannot come from a client, so nothing on the wire can
# name an identity. A request the server never identifies - anonymous, refused,
# or with an authenticator that has no `identity` or answers nil - goes
# straight through.
#
# Entries are keyed by the URL, that identity, and whether `Accept` asks for
# JSON - the PyPI index answers one URL in HTML or JSON. The URL carries the
# host and the mount point, so one cache can sit in front of all three servers,
# told apart by subdomain or by path prefix. The key is not what
# keeps two callers apart - the ETag is, since the stored one has to be current
# for the caller asking - but it keeps each caller from overwriting another's
# entry, and an identity that wrongly names two customers alike from serving
# one's body to the other.
#
# Only identified requests without a query string are stored, and the
# client's own headers go into the key only as that one bit, so a stranger puts
# nothing on disk: an anonymous response is the same for everybody and a 304
# away anyway, and a query string is anybody's to vary. An identified caller can
# still spell one URL many ways - percent-escapes, X-Forwarded-Host - so each
# identity keeps at most `max_entries_per_identity:` entries, the least recently
# written going first. The directory can be emptied at any time. Keep a
# compressor such as Rack::Deflater outside the cache, since the encoding is not
# in the key.
#
# A body is filed under its ETag as well as its key, so a request revalidated
# against one ETag can never read the body another request has just written
# for the same key.
class Paquette::ResponseCache
  prepend Paquette::RegexpTimeout

  # The largest body worth keeping. Gem and tarball downloads are files already
  # and are never stored; what is left is indexes and package documents.
  #
  # @return [Integer]
  DEFAULT_MAX_BODY_BYTES = 8 * 1024 * 1024

  # Enough for every index URL of a sizeable licence on a couple of hosts.
  #
  # @return [Integer]
  DEFAULT_MAX_ENTRIES_PER_IDENTITY = 128

  # What happened, for the application's own log line: "hit", "miss" or "bypass".
  #
  # @return [String]
  OUTCOME_KEY = "paquette.response_cache"

  # Where the Lookup waits for the server to identify the caller.
  #
  # @return [String]
  LOOKUP_KEY = "paquette.response_cache.lookup"

  # Headers that are about one response on the wire rather than the content.
  #
  # @return [Array<String>]
  UNSTORED_HEADERS = %w[connection keep-alive transfer-encoding date age content-length].freeze

  # @param app [#call] the Rack app to cache
  # @param directory [String] where entries live, created when missing
  # @param max_body_bytes [Integer]
  # @param max_entries_per_identity [Integer]
  def initialize(app, directory:, max_body_bytes: DEFAULT_MAX_BODY_BYTES,
    max_entries_per_identity: DEFAULT_MAX_ENTRIES_PER_IDENTITY)
    @app = app
    @directory = directory.to_s
    @max_body_bytes = max_body_bytes
    @max_entries_per_identity = max_entries_per_identity
  end

  # The env is the caller's own and is handed on, not copied: an application
  # that leaves notes in it for its log line has to find them afterwards.
  #
  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    return record(env, "bypass") { @app.call(env) } unless cacheable_request?(env)

    client_etags = env["HTTP_IF_NONE_MATCH"]
    lookup = Paquette::ResponseCache::Lookup.new do |identity|
      key = key_for(env, identity)
      [key, read(key)]
    end
    env[LOOKUP_KEY] = lookup
    response = begin
      @app.call(env)
    ensure
      env.delete(LOOKUP_KEY)
      # The server swapped in the stored ETag
      client_etags.nil? ? env.delete("HTTP_IF_NONE_MATCH") : env["HTTP_IF_NONE_MATCH"] = client_etags
    end

    return record(env, "bypass") { response } unless lookup.key
    return record(env, "miss") { store_and_answer(env, lookup.key, response) } unless lookup.entry

    answer(env, lookup.key, lookup.entry, response)
  end

  private

  # A Range is a slice of a body the server builds anyway, and Bundler sends one
  # only alongside an If-None-Match the server can answer by itself.
  #
  # @param env [Hash]
  # @return [Boolean]
  def cacheable_request?(env)
    env["REQUEST_METHOD"] == "GET" && !env.key?("HTTP_RANGE") && env["QUERY_STRING"].to_s.empty?
  end

  # What the server said to the stored ETag: a 304 is a hit, anything else is
  # the new answer.
  #
  # @param env [Hash]
  # @param key [String]
  # @param entry [Hash]
  # @param response [Array] a Rack response triplet
  # @return [Array] a Rack response triplet
  def answer(env, key, entry, response)
    status, headers, body = response
    unless status == 304
      delete(key) if (400..499).cover?(status)
      return record(env, "miss") { store_and_answer(env, key, response) }
    end

    body.close if body.respond_to?(:close)
    etag = entry.fetch("etag")
    return record(env, "hit") { [304, Rack::Headers[headers], []] } if etag_matches?(env["HTTP_IF_NONE_MATCH"], etag)

    stored = begin
      File.binread(body_path(key, etag))
    rescue Errno::ENOENT
      # Replaced or emptied since the read. Asked again without a Lookup, so
      # the server authenticates and renders in full
      return record(env, "miss") { store_and_answer(env, key, @app.call(env)) }
    end
    fresh = Rack::Headers[entry.fetch("headers")].merge!(Rack::Headers[headers].except("content-length"))
    record(env, "hit") { [200, fresh, [stored]] }
  end

  # @param env [Hash]
  # @param key [String]
  # @param response [Array] a Rack response triplet
  # @return [Array] a Rack response triplet
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

    store(key, headers, chunks) if size <= @max_body_bytes

    if etag_matches?(env["HTTP_IF_NONE_MATCH"], headers["etag"])
      [304, headers.except("content-length"), []]
    else
      [status, headers, chunks]
    end
  end

  # @param status [Integer]
  # @param headers [Rack::Headers]
  # @param body [#each]
  # @return [Boolean]
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
  # @param header [String, nil] the client's If-None-Match
  # @param etag [String, nil]
  # @return [Boolean]
  def etag_matches?(header, etag)
    return false if header.nil? || etag.nil?

    ours = etag.delete_prefix("W/")
    header.split(",").any? do |candidate|
      candidate = candidate.strip
      candidate == "*" || candidate.delete_prefix("W/") == ours
    end
  end

  # @param env [Hash]
  # @param outcome [String]
  # @return [Array] a Rack response triplet
  def record(env, outcome)
    env[OUTCOME_KEY] = outcome
    Measurometer.increment_counter("paquette.response_cache.#{outcome}")
    yield
  end

  # The identity's directory, then the URL with its host and scheme: npm
  # package documents carry absolute tarball URLs built from them. A request
  # with a query string is not stored, so there is none to leave out.
  #
  # @param env [Hash]
  # @param identity [String]
  # @return [String] "identity digest/entry digest"
  def key_for(env, identity)
    request = Rack::Request.new(env)
    digest = Digest::SHA256.new
    digest << request.base_url << "\0" << request.script_name << "\0" << request.path_info
    digest << "\0" << (env["HTTP_ACCEPT"].to_s.include?("json") ? "json" : "")
    "#{Digest::SHA256.hexdigest(identity)}/#{digest.hexdigest}"
  end

  # @param key [String]
  # @return [Hash, nil]
  def read(key)
    entry = read_meta(key)
    entry if entry && File.exist?(body_path(key, entry["etag"]))
  end

  # @param key [String]
  # @return [Hash, nil]
  def read_meta(key)
    entry = JSON.parse(File.read(meta_path(key)))
    entry if entry["etag"].is_a?(String) && entry["headers"].is_a?(Hash)
  # Missing is the common case; a directory that cannot be read is a miss too
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # A cache that cannot write still answers: the response is in hand.
  #
  # @param key [String]
  # @param headers [Rack::Headers]
  # @param chunks [Array<String>]
  # @return [void]
  def store(key, headers, chunks)
    previous = read_meta(key)
    make_room(key) unless previous
    write(key, headers, chunks)
    # Only once the metadata points elsewhere, so a reader of the old one
    # finds its body or nothing
    FileUtils.rm_f(body_path(key, previous["etag"])) if previous && previous["etag"] != headers["etag"]
    Measurometer.increment_counter("paquette.response_cache.stored")
  rescue SystemCallError
    Measurometer.increment_counter("paquette.response_cache.write_failed")
  end

  # @param key [String] the entry about to be added
  # @return [void]
  def make_room(key)
    entries = Dir.glob(File.join(identity_dir(key), "*.json"))
    excess = entries.length - @max_entries_per_identity + 1
    return unless excess > 0

    entries.sort_by { |path| File.mtime(path) }.first(excess).each do |path|
      delete("#{key.split("/").first}/#{File.basename(path, ".json")}")
    rescue Errno::ENOENT # another request got there first
    end
  end

  # Body first and the metadata last, each renamed into place, so a reader
  # never finds metadata pointing at half a body.
  #
  # @param key [String]
  # @param headers [Rack::Headers]
  # @param chunks [Array<String>]
  # @return [void]
  def write(key, headers, chunks)
    FileUtils.mkdir_p(identity_dir(key))
    kept = headers.to_h.except(*UNSTORED_HEADERS)
    atomically(body_path(key, headers["etag"])) { |io| chunks.each { |chunk| io.write(chunk) } }
    atomically(meta_path(key)) { |io| io.write(JSON.dump("etag" => headers["etag"], "headers" => kept)) }
  end

  # @param path [String]
  # @return [void]
  def atomically(path)
    temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
    File.open(temporary, "wb") { |io| yield io }
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
  end

  # @param key [String]
  # @return [void]
  def delete(key)
    entry = read_meta(key)
    FileUtils.rm_f(meta_path(key))
    FileUtils.rm_f(body_path(key, entry["etag"])) if entry
  end

  # @param key [String]
  # @return [String]
  def identity_dir(key)
    File.join(@directory, key[0, 2], key.split("/").first)
  end

  # @param key [String]
  # @return [String]
  def meta_path(key)
    File.join(identity_dir(key), "#{key.split("/").last}.json")
  end

  # @param key [String]
  # @param etag [String]
  # @return [String]
  def body_path(key, etag)
    File.join(identity_dir(key), "#{key.split("/").last}.#{Digest::SHA256.hexdigest(etag)[0, 16]}.body")
  end
end

# What the cache leaves in the env for the server to fill in. The server calls
# {#identify} once its authenticator has let the read in, and puts the ETag it
# gets back into If-None-Match.
class Paquette::ResponseCache::Lookup
  # @return [String, nil]
  attr_reader :key

  # @return [Hash, nil] the stored entry, when there is one
  attr_reader :entry

  # @yield [identity] returns the key and the stored entry for that identity
  def initialize(&find)
    @find = find
  end

  # Only the first identity counts, should two servers see one request. A
  # String or an Integer, because anything else - a model object, say -
  # stringifies differently on every request and would never hit.
  #
  # @param identity [String, Integer, nil] who the authenticator says the
  #   caller is; nil or blank for nobody
  # @raise [TypeError] for anything else
  # @return [String, nil] the stored ETag to revalidate with
  def identify(identity)
    unless identity.nil? || identity.is_a?(String) || identity.is_a?(Integer)
      raise TypeError, "identity must return a String, an Integer or nil, not a #{identity.class}"
    end
    # Binary: `strip` raises on a String that is not valid UTF-8
    return nil if @key || identity.to_s.b.strip.empty?

    @key, @entry = @find.call(identity.to_s)
    @entry&.fetch("etag")
  end
end
