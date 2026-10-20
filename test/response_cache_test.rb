require_relative "test_helper"

class ResponseCacheTest < Minitest::Test
  # Renders a body per call and answers 304 to its own ETag, the way a server
  # with a named stack does. `etag:` nil leaves the ETag off.
  class Origin
    attr_reader :calls, :seen_etags
    attr_accessor :etag, :status, :headers, :body

    def initialize
      @calls = 0
      @seen_etags = []
      @etag = %("v1")
      @status = 200
      @headers = {}
      @body = "the index"
    end

    def call(env)
      @calls += 1
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

  def test_each_credential_has_its_own_entry
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer b")

    assert_equal [nil, nil], @origin.seen_etags
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
    cache = Paquette::ResponseCache.new(Paquette::PypiServer.new(packages), directory: @dir)
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
  # refused with a body on disk for it
  def test_a_refusal_on_revalidation_goes_out_and_drops_the_entry
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")
    @origin.status = 401
    @origin.body = "Unauthorized"

    assert_equal 401, get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")[0]
    @origin.status = 200
    @origin.body = "the index"
    get("/versions", "HTTP_AUTHORIZATION" => "Bearer a")

    assert_equal [nil, %("v1"), nil], @origin.seen_etags
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

    assert_equal "the index", body_of(small.call(Rack::MockRequest.env_for("/versions")))
    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  # Downloads are files on disk already
  def test_a_file_body_is_not_stored
    file_origin = ->(_env) { [200, {"etag" => %("f")}, Rack::Files::Iterator.new(__FILE__, 0..10, 11)] }
    Paquette::ResponseCache.new(file_origin, directory: @dir).call(Rack::MockRequest.env_for("/gems/x.gem"))

    assert_empty Dir.glob(File.join(@dir, "**", "*.json"))
  end

  def test_ranges_heads_and_writes_go_straight_through
    get("/versions")
    get("/versions", "HTTP_RANGE" => "bytes=0-3")
    @cache.call(Rack::MockRequest.env_for("/versions", method: "HEAD"))
    @cache.call(Rack::MockRequest.env_for("/api/v1/gems", method: "POST"))

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
    licensed = -> { @licensed }
    authenticator = Object.new
    authenticator.define_singleton_method(:read_permitted?) { |auth_token:| licensed.call }
    @app = Paquette::ResponseCache.new(Paquette::GemServer.new(gated, authenticator: authenticator), directory: @dir)
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

  private

  def get(path)
    @app.call(Rack::MockRequest.env_for(path, "HTTP_AUTHORIZATION" => "Bearer licensee-1"))
  end
end
