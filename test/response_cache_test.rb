require_relative "test_helper"

# Lets in what `permitted` says, and names the caller as `identities` does.
class ResponseCacheAuthenticator
  attr_accessor :permitted
  attr_reader :identity_questions

  def initialize(identities, &permitted)
    @identities = identities
    @permitted = permitted || ->(_token) { true }
    @identity_questions = []
  end

  def read_permitted?(auth_token:)
    @permitted.call(auth_token)
  end

  def write_permitted?(auth_token:)
    false
  end

  def check_otp!(auth_token:, otp_code:)
    raise Paquette::OtpRejected
  end

  def identity(auth_token:)
    @identity_questions << auth_token
    @identities.call(auth_token)
  end
end

class ResponseCacheTest < Minitest::Test
  # Renders a body per call and answers 304 to its own ETag, the way a server
  # with a named stack does. `etag:` nil leaves the ETag off. Identifies the
  # caller to the cache the way a server does once its authenticator said yes,
  # which a refusal (any status but 200) never gets to.
  class Origin
    attr_reader :calls, :seen_etags
    attr_accessor :etag, :status, :headers, :body, :identities, :during_call

    def initialize
      @calls = 0
      @seen_etags = []
      @etag = %("v1")
      @status = 200
      @headers = {}
      @body = "the index"
      # Tokens "a" and "a2" are the same user's, before and after a rotation
      @identities = {"a" => "user-1", "a2" => "user-1", "b" => "user-2"}
    end

    def call(env)
      @calls += 1
      lookup = env[Paquette::ResponseCache::LOOKUP_KEY]
      token = Paquette::AuthToken.from_env(env)
      if lookup && token && @status == 200
        etag = lookup.identify(@identities[token])
        env["HTTP_IF_NONE_MATCH"] = etag if etag
      end
      @during_call&.call
      @seen_etags << env["HTTP_IF_NONE_MATCH"]
      env["origin.note"] = "was here"
      headers = {"content-type" => "text/plain", "cache-control" => "private, no-cache"}.merge(@headers)
      headers["etag"] = @etag if @etag
      return [304, headers.except("content-type"), []] if @etag && env["HTTP_IF_NONE_MATCH"] == @etag && @status == 200

      [@status, headers, [@body]]
    end
  end

  def setup
    @dir = Dir.mktmpdir("paquette_response_cache")
    @origin = Origin.new
    @cache = Paquette::ResponseCache.new(@origin, directory: @dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_second_request_gets_the_stored_body_after_a_304_from_the_origin
    first = get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    second = get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")

    assert_equal [200, "the index"], [first[0], body_of(first)]
    assert_equal [200, "the index"], [second[0], body_of(second)]
    assert_equal %("v1"), second[1]["etag"]
    assert_equal [nil, %("v1")], @origin.seen_etags, "the origin is asked to revalidate, not to render"
    assert_equal "hit", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  def test_a_client_holding_the_current_etag_gets_a_304
    get("/versions")
    response = get("/versions", "HTTP_IF_NONE_MATCH" => %("v1"))

    assert_equal 304, response[0]
    assert_equal "", body_of(response)
  end

  def test_a_client_holding_a_stale_etag_gets_the_body
    get("/versions")
    response = get("/versions", "HTTP_IF_NONE_MATCH" => %("v0"))

    assert_equal [200, "the index"], [response[0], body_of(response)]
    assert_equal %("v0"), @last_env["HTTP_IF_NONE_MATCH"], "the client's own header is put back"
  end

  def test_a_changed_origin_replaces_the_entry
    get("/versions")
    @origin.etag = %("v2")
    @origin.body = "the new index"

    assert_equal "the new index", body_of(get("/versions"))
    assert_equal "the new index", body_of(get("/versions"))
    assert_equal [nil, %("v1"), %("v2")], @origin.seen_etags
  end

  def test_each_identity_has_its_own_entry
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer b")

    assert_equal [nil, nil], @origin.seen_etags
  end

  # Tokens get rotated; the user they belong to does not
  def test_a_rotated_token_finds_the_entry_the_old_one_left
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    response = get("/versions", "HTTP_AUTHORIZATION" => "Basic #{["a2:"].pack("m0")}")

    assert_equal [200, "the index"], [response[0], body_of(response)]
    assert_equal [nil, %("v1")], @origin.seen_etags
    assert_equal "hit", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  def test_a_token_nobody_owns_is_not_stored
    @origin.identities["stray"] = ""
    2.times { get("/versions", "HTTP_AUTHORIZATION" => "Bearer nobody") }
    2.times { get("/versions", "HTTP_AUTHORIZATION" => "Bearer stray") }

    assert_equal [nil, nil, nil, nil], @origin.seen_etags
    assert_empty stored_entries
    assert_equal "bypass", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  # The server decides, from the authenticator; the client gets no say
  def test_nothing_the_client_sends_names_an_identity
    2.times do
      get("/versions", "HTTP_AUTHORIZATION" => "Bearer nobody", "HTTP_X_PAQUETTE_USER" => "user-1",
        "HTTP_PAQUETTE.RESPONSE_CACHE.LOOKUP" => "user-1")
    end

    assert_empty stored_entries
  end

  def test_a_server_that_never_identifies_the_caller_is_not_cached
    plain = ->(_env) { [200, {"etag" => %("v1"), "cache-control" => "private, no-cache"}, ["body"]] }
    cache = Paquette::ResponseCache.new(plain, directory: @dir)
    2.times { cache.call(Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer a")) }

    assert_empty stored_entries
  end

  # Another request for the same entry writes a new body between this one's
  # read of the ETag and its read of the body - which, for one identity with two
  # licences, would be another licence's body under this one's headers
  def test_a_body_replaced_during_revalidation_is_never_served_under_the_old_etag
    get("/versions")
    racing = true
    @origin.during_call = lambda do
      next unless racing

      racing = false
      @origin.etag, @origin.body = %("v2"), "the other licence's index"
      @cache.call(Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer a"))
      @origin.etag, @origin.body = %("v1"), "the index"
    end
    response = get("/versions")

    assert_equal [200, %("v1"), "the index"], [response[0], response[1]["etag"], body_of(response)]
  end

  # One URL spelled many ways is many entries; the cap keeps that the caller's
  # own problem
  def test_an_identity_keeps_at_most_its_share_of_entries
    @cache = Paquette::ResponseCache.new(@origin, directory: @dir, max_entries_per_identity: 3)
    3.times { |n| get("/other/#{n}", "HTTP_AUTHORIZATION" => "Bearer b") }
    %w[/versions /v%65rsions /%76ersions /ve%72sions /ver%73ions].each { |path| get(path) }

    assert_equal 6, stored_entries.length
    get("/ver%73ions")
    assert_equal "hit", @last_env[Paquette::ResponseCache::OUTCOME_KEY], "the newest stays"
    get("/other/0", "HTTP_AUTHORIZATION" => "Bearer b")
    assert_equal "hit", @last_env[Paquette::ResponseCache::OUTCOME_KEY], "another identity's entries are its own"
  end

  def test_an_integer_identity_is_cached
    @origin.identities["a"] = 42
    get("/versions")
    get("/versions")

    assert_equal "hit", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  def test_a_blank_identity_is_nobody
    @origin.identities["a"] = "  "
    2.times { get("/versions") }

    assert_empty stored_entries
  end

  # Stringifies differently on every request, so it would fill the disk and
  # never hit
  def test_an_identity_that_is_not_a_string_or_an_integer_raises
    @origin.identities["a"] = Object.new

    assert_raises(TypeError) { get("/versions") }
    refute @last_env.key?(Paquette::ResponseCache::LOOKUP_KEY)
  end

  def test_a_cache_that_cannot_write_still_answers
    blocked = File.join(@dir, "blocked")
    File.write(blocked, "a file where the directory should be")
    cache = Paquette::ResponseCache.new(@origin, directory: blocked)
    response = cache.call(Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer a"))

    assert_equal [200, "the index"], [response[0], body_of(response)]
  end

  def test_the_lookup_is_gone_from_the_env_afterwards
    get("/versions")

    refute @last_env.key?(Paquette::ResponseCache::LOOKUP_KEY)
  end

  # The same for everybody, and a 304 away anyway - storing it would let a
  # stranger write to the disk
  def test_an_anonymous_request_is_not_stored
    2.times { get("/versions", "HTTP_AUTHORIZATION" => nil) }
    get("/versions", "HTTP_AUTHORIZATION" => "  ")

    assert_equal [nil, nil, nil], @origin.seen_etags
    assert_empty stored_entries
    assert_equal "bypass", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  # Anybody's to vary, one entry per value
  def test_a_request_with_a_query_string_is_not_stored
    get("/versions?cachebust=1")
    get("/versions?cachebust=1")

    assert_equal [nil, nil], @origin.seen_etags
    assert_empty stored_entries
  end

  # Only whether it asks for JSON is in the key
  def test_varied_request_headers_do_not_mint_entries
    50.times do |n|
      get("/simple/widgets/", "HTTP_ACCEPT" => "x/#{n}", "HTTP_ACCEPT_ENCODING" => "x-#{n}", "HTTP_COOKIE" => "c=#{n}")
      get("/simple/widgets/", "HTTP_ACCEPT" => "x/#{n}+json")
    end

    assert_equal 2, stored_entries.length
  end

  # Paquette never reads them, and Cloudflare and the like hand out new ones
  def test_a_cookie_does_not_split_the_entry
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a", "HTTP_COOKIE" => "__cf_bm=one")
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a", "HTTP_COOKIE" => "__cf_bm=two")

    assert_equal [nil, %("v1")], @origin.seen_etags
  end

  # npm package documents carry absolute tarball URLs built from the host
  def test_each_host_has_its_own_entry
    get("http://npm.one.test/widget")
    get("http://npm.two.test/widget")
    get("http://npm.one.test/widget", "HTTP_ACCEPT_ENCODING" => "gzip")

    assert_equal [nil, nil, %("v1")], @origin.seen_etags
  end

  # The PyPI index answers one URL in HTML or JSON, so pip and a browser
  # would otherwise keep replacing each other's entry
  def test_each_accept_has_its_own_entry
    json = "application/vnd.pypi.simple.v1+json"
    get("/simple/widgets/", "HTTP_ACCEPT" => json)
    get("/simple/widgets/", "HTTP_ACCEPT" => "text/html")
    get("/simple/widgets/", "HTTP_ACCEPT" => json)
    get("/simple/widgets/", "HTTP_ACCEPT" => "text/html")

    assert_equal [nil, nil, %("v1"), %("v1")], @origin.seen_etags
  end

  def test_the_pypi_index_is_replayed_in_the_format_asked_for
    packages = Dir.mktmpdir("paquette_response_cache_pypi")
    write_wheel(packages, name: "widgets", version: "1.0.0")
    authenticator = ResponseCacheAuthenticator.new(->(_token) { "user-1" })
    cache = Paquette::ResponseCache.new(Paquette::PypiServer.new(packages, authenticator: authenticator), directory: @dir)
    page = ->(accept) { cache.call(Rack::MockRequest.env_for("/simple/widgets/", "HTTP_ACCEPT" => accept, "HTTP_AUTHORIZATION" => "Bearer a")) }

    2.times do
      json = page.call(Paquette::PypiServer::JSON_TYPE)
      html = page.call("text/html")
      assert_equal Paquette::PypiServer::JSON_TYPE, json[1]["content-type"]
      assert_equal "widgets", JSON.parse(body_of(json))["name"]
      assert_includes body_of(html), "<h1>Links for widgets</h1>"
    end
  ensure
    FileUtils.rm_rf(packages)
  end

  # The cache never answers on its own, so a credential refused later is
  # refused with a body on disk for it - and never told which one that is
  def test_a_refusal_goes_out_without_being_shown_the_entry
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    @origin.status = 401
    @origin.body = "Unauthorized"

    refused = get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    assert_equal [401, "Unauthorized"], [refused[0], body_of(refused)]
    assert_equal "bypass", @last_env[Paquette::ResponseCache::OUTCOME_KEY]
    @origin.status = 200
    @origin.body = "the index"
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")

    assert_equal [nil, nil, %("v1")], @origin.seen_etags
  end

  def test_a_response_without_an_etag_is_not_stored
    @origin.etag = nil
    2.times { get("/versions") }

    assert_equal 2, @origin.calls
    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  def test_what_must_not_be_kept_is_not_stored
    [
      {"cache-control" => "private, no-store"},
      {"set-cookie" => "session=1"},
      {"vary" => "*"},
      {"content-length" => (Paquette::ResponseCache::DEFAULT_MAX_BODY_BYTES + 1).to_s}
    ].each do |headers|
      @origin.headers = headers
      get("/versions")
      assert_empty Dir.glob(File.join(@dir, "**", "*.json")), headers.inspect
    end
  end

  def test_a_body_past_the_limit_is_served_but_not_stored
    small = Paquette::ResponseCache.new(@origin, directory: @dir, max_body_bytes: 4)

    assert_equal "the index", body_of(small.call(Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer a")))
    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  # Downloads are files on disk already
  def test_a_file_body_is_not_stored
    file_origin = lambda do |env|
      env[Paquette::ResponseCache::LOOKUP_KEY].identify("user-1")
      [200, {"etag" => %("f")}, Rack::Files::Iterator.new(__FILE__, 0..10, 11)]
    end
    Paquette::ResponseCache.new(file_origin, directory: @dir)
      .call(Rack::MockRequest.env_for("/gems/x.gem", "HTTP_AUTHORIZATION" => "Bearer a"))

    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  def test_ranges_heads_and_writes_go_straight_through
    get("/versions")
    get("/versions", "HTTP_RANGE" => "bytes=0-3")
    @cache.call(Rack::MockRequest.env_for("/versions", method: "HEAD").merge("HTTP_AUTHORIZATION" => "Bearer a"))
    @cache.call(Rack::MockRequest.env_for("/api/v1/gems", method: "POST").merge("HTTP_AUTHORIZATION" => "Bearer a"))

    assert_equal [nil, nil, nil, nil], @origin.seen_etags
  end

  # Applications leave notes in the env for their log line
  def test_the_env_handed_on_is_the_caller_s_own
    get("/versions")
    get("/versions")

    assert_equal "was here", @last_env["origin.note"]
  end

  def test_a_damaged_entry_is_a_miss
    get("/versions")
    Dir.glob(File.join(@dir, "**", "*.json")).each { |path| File.write(path, "{nope") }
    response = get("/versions")

    assert_equal [200, "the index"], [response[0], body_of(response)]
    assert_equal [nil, nil], @origin.seen_etags
  end

  def test_a_missing_body_is_a_miss
    get("/versions")
    Dir.glob(File.join(@dir, "**", "*.body")).each { |path| File.delete(path) }

    assert_equal "the index", body_of(get("/versions"))
    assert_equal [nil, nil], @origin.seen_etags
  end

  # What Rack::MockRequest and some servers hand over: UTF-8 in name only
  def test_a_utf8_tagged_header_that_is_not_utf8_does_not_raise
    header = (+"Bearer \xFF\xE2").force_encoding("UTF-8")

    assert_equal [200, 200], 2.times.map { get("/versions", "HTTP_AUTHORIZATION" => header)[0] }
  end

  def test_keys_survive_header_bytes_that_are_not_utf8
    response = get("/versions", "HTTP_AUTHORIZATION" => "Bearer \xFF\xE2".b)

    assert_equal 200, response[0]
  end

  private

  # With a credential unless told otherwise, since nothing anonymous is stored
  def get(url, headers = {})
    headers = {"HTTP_AUTHORIZATION" => "Bearer a"}.merge(headers).compact
    @last_env = Rack::MockRequest.env_for(url, headers)
    @cache.call(@last_env)
  end

  def stored_entries
    Dir.glob(File.join(@dir, "**", "*.json"))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end
end

# The cache in front of a real GemServer: a gated stack that can name itself
# answers the revalidation with a 304 before the gate is asked anything.
class ResponseCacheGemServerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_response_cache_gems")
    @questions = 0
    @licensed = true
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: "licensee-1") do |name:, version: nil|
      @questions += 1
      true
    end
    @authenticator = ResponseCacheAuthenticator.new(->(token) { "licensee-1" if token.start_with?("licensee-1") }) { @licensed }
    @app = Paquette::ResponseCache.new(Paquette::GemServer.new(gated, authenticator: @authenticator), directory: @dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_hit_does_not_render
    first = get("/versions")
    asked_while_rendering = @questions
    second = get("/versions")

    assert_operator asked_while_rendering, :>, 0
    assert_equal asked_while_rendering, @questions, "the stored body was replayed without asking the gate"
    assert_equal first[2].to_a.join, second[2].to_a.join
    assert_equal [200, 200], [first[0], second[0]]
  end

  def test_a_revoked_token_is_refused_with_an_entry_on_disk
    get("/versions")
    @licensed = false

    assert_equal 401, get("/versions")[0]
  end

  # Asked only past read_permitted?, and only with a cache in front
  def test_identity_is_asked_only_about_a_token_that_was_let_in
    get("/versions")
    @licensed = false
    get("/versions", token: "licensee-1-revoked")
    @licensed = true
    get("/versions?x=1")
    Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR), authenticator: @authenticator)
      .call(Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer licensee-1-direct"))

    assert_equal ["licensee-1"], @authenticator.identity_questions
  end

  # A nil identity is "serve them, but do not cache for them", not a refusal
  def test_a_nil_identity_is_served_in_full_and_not_stored
    authenticator = ResponseCacheAuthenticator.new(->(_token) {})
    app = Paquette::ResponseCache.new(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR),
      authenticator: authenticator), directory: @dir)
    responses = 2.times.map do
      env = Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer licensee-1")
      [app.call(env), env]
    end

    assert_equal [200, 200], responses.map { |response, _| response[0] }
    refute_empty responses.first[0][2].to_a.join
    assert_equal %w[bypass bypass], responses.map { |_, env| env[Paquette::ResponseCache::OUTCOME_KEY] }
    assert_equal ["licensee-1", "licensee-1"], authenticator.identity_questions
    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  def test_an_authenticator_without_identity_is_never_cached
    authenticator = Object.new
    authenticator.define_singleton_method(:read_permitted?) { |auth_token:| true }
    app = Paquette::ResponseCache.new(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR),
      authenticator: authenticator), directory: @dir)
    env = Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "Bearer licensee-1")
    app.call(env)

    assert_equal "bypass", env[Paquette::ResponseCache::OUTCOME_KEY]
    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  # The authenticator still has the last word over a token the identity knows
  def test_a_rotated_token_is_served_from_the_entry_once_it_authenticates
    first = get("/versions")
    asked_while_rendering = @questions
    second = get("/versions", token: "licensee-1-rotated")

    assert_equal [200, first[2].to_a.join], [second[0], second[2].to_a.join]
    assert_equal asked_while_rendering, @questions
    @licensed = false
    assert_equal 401, get("/versions", token: "licensee-1-rotated")[0]
  end

  private

  def get(path, token: "licensee-1")
    @app.call(Rack::MockRequest.env_for(path, "HTTP_AUTHORIZATION" => "Bearer #{token}"))
  end
end

# One cache in front of all three servers. The key starts with the host and the
# mount point, so servers that answer the same path - even with the same ETag -
# never get each other's bodies.
class ResponseCacheSharedTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_response_cache_shared")
    @authenticator = ResponseCacheAuthenticator.new(->(_token) { "user-1" })
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_one_cache_serves_all_three_servers
    pypi_dir = Dir.mktmpdir("paquette_response_cache_shared_pypi")
    write_wheel(pypi_dir, name: "widgets", version: "1.0.0")
    router = Paquette::SubdomainRouter.new do |r|
      r.map "gem", to: Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR), authenticator: @authenticator)
      r.map "npm", to: Paquette::NpmServer.new(FIXTURE_NPM_DIR, authenticator: @authenticator)
      r.map "pypi", to: Paquette::PypiServer.new(pypi_dir, authenticator: @authenticator)
    end
    cache = Paquette::ResponseCache.new(router, directory: @dir)
    urls = %w[http://gem.example.test/versions http://npm.example.test/react-dropzone http://pypi.example.test/simple/widgets/]

    first = urls.map { |url| get(cache, url) }
    second = urls.map { |url| get(cache, url) }

    assert_equal [200] * 3, second.map(&:first)
    assert_equal first.map { |r| body_of(r) }, second.map { |r| body_of(r) }
    assert_equal 3, Dir.glob(File.join(@dir, "**", "*.json")).length
    assert_equal ["hit"] * 3, urls.map { |url| outcome_of(url, cache) }
  ensure
    FileUtils.rm_rf(pypi_dir)
  end

  def test_the_same_path_and_etag_on_two_hosts_are_two_entries
    router = Paquette::SubdomainRouter.new do |r|
      r.map "gem", to: same_etag_origin("gem body")
      r.map "npm", to: same_etag_origin("npm body")
    end
    cache = Paquette::ResponseCache.new(router, directory: @dir)

    get(cache, "http://gem.example.test/index")
    assert_equal "npm body", body_of(get(cache, "http://npm.example.test/index"))
    assert_equal "gem body", body_of(get(cache, "http://gem.example.test/index"))
    assert_equal "npm body", body_of(get(cache, "http://npm.example.test/index"))
  end

  def test_the_same_path_and_etag_under_two_mounts_are_two_entries
    gem_origin = same_etag_origin("gem body")
    npm_origin = same_etag_origin("npm body")
    app = Rack::Builder.new do
      map("/gems") { run gem_origin }
      map("/npm") { run npm_origin }
    end
    cache = Paquette::ResponseCache.new(app, directory: @dir)

    get(cache, "http://packages.example.test/gems/index")
    assert_equal "npm body", body_of(get(cache, "http://packages.example.test/npm/index"))
    assert_equal "gem body", body_of(get(cache, "http://packages.example.test/gems/index"))
  end

  private

  def outcome_of(url, app)
    env = Rack::MockRequest.env_for(url, "HTTP_AUTHORIZATION" => "Bearer a")
    app.call(env)
    env[Paquette::ResponseCache::OUTCOME_KEY]
  end

  # Answers 304 to the one ETag both origins share, the worst case for a key
  # that left the server out
  def same_etag_origin(body)
    lambda do |env|
      etag = env[Paquette::ResponseCache::LOOKUP_KEY]&.identify("user-1")
      env["HTTP_IF_NONE_MATCH"] = etag if etag
      headers = {"etag" => %("same"), "cache-control" => "private, no-cache"}
      next [304, headers, []] if env["HTTP_IF_NONE_MATCH"] == %("same")

      [200, headers.merge("content-type" => "text/plain"), [body]]
    end
  end

  def get(app, url)
    app.call(Rack::MockRequest.env_for(url, "HTTP_AUTHORIZATION" => "Bearer a"))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end
end
