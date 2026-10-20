require_relative "test_helper"

class ServedGemTest < Minitest::Test
  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @dir = Dir.mktmpdir("paquette_served")
    FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "zip_kit"), @dir)
    @app = Writable.gem_server(Paquette::GemServer::DirectoryGemRepository.new(@dir))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_an_index_names_its_gem
    assert_equal({route: "GET /info/:gem_name", package: "zip_kit"}, served("/info/zip_kit"))
  end

  def test_a_download_names_its_version
    assert_equal({route: "GET /gems/:gem_filename", package: "zip_kit", version: "6.2.1"}, served("/gems/zip_kit-6.2.1.gem"))
  end

  def test_a_quick_spec_names_its_version
    assert_equal "6.2.1", served("/quick/Marshal.4.8/zip_kit-6.2.1.gemspec.rz")[:version]
  end

  # Or a scanner mints a tag value per name it makes up
  def test_a_gem_that_is_not_there_is_not_named
    assert_equal({route: "GET /info/:gem_name"}, served("/info/made_up"))
    assert_equal({route: "GET /gems/:gem_filename"}, served("/gems/made_up-1.0.0.gem"))
  end

  def test_a_304_on_a_held_validator_names_its_gem
    etag = request("/info/zip_kit")[1]["etag"]

    assert_equal "zip_kit", served("/info/zip_kit", "HTTP_IF_NONE_MATCH" => etag)[:package]
  end

  def test_if_none_match_star_does_not_name_a_gem
    assert_nil served("/info/made_up", "HTTP_IF_NONE_MATCH" => "*")[:package]
  end

  # A push names its gem in the body only
  def test_a_push_names_what_it_wrote
    env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST", :input => File.binread(MINUSCULE_FIXTURE),
      "CONTENT_TYPE" => "application/octet-stream")
    @app.call(env)

    assert_equal({route: "POST /api/v1/gems", package: "minuscule_test", version: "0.1.0"}, env[Paquette::Served::KEY])
  end

  def test_a_refused_request_still_names_its_route
    refusing = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(@dir),
      authenticator: TestAuthenticator.new(readers: []))
    env = Rack::MockRequest.env_for("/info/zip_kit")

    assert_equal 401, refusing.call(env)[0]
    assert_equal({route: "GET /info/:gem_name"}, env[Paquette::Served::KEY])
  end

  def test_an_unrouted_request_leaves_nothing
    env = Rack::MockRequest.env_for("/no/such/thing")
    @app.call(env)

    refute env.key?(Paquette::Served::KEY)
  end

  private

  def request(path, headers = {})
    @app.call(Rack::MockRequest.env_for(path, headers))
  end

  def served(path, headers = {})
    env = Rack::MockRequest.env_for(path, headers)
    @app.call(env)
    env[Paquette::Served::KEY]
  end
end

class ServedNpmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_served_npm")
    write_npm_package(@dir, name: "@acme/widget", version: "1.0.0")
    @app = Writable.npm_server(Paquette::NpmServer::DirectoryNpmRepository.new(@dir))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # The application holds the env npm's scoped path was rewritten in a copy of
  def test_a_scoped_document_names_its_package_in_the_env_the_application_holds
    assert_equal({route: "GET /:package_name", package: "@acme/widget"}, served("/@acme%2fwidget"))
  end

  def test_a_tarball_names_its_version
    assert_equal "1.0.0", served("/@acme/widget/-/widget-1.0.0.tgz")[:version]
  end

  def test_a_package_that_is_not_there_is_not_named
    assert_nil served("/made-up")[:package]
  end

  def test_a_publish_names_what_it_wrote
    env = Rack::MockRequest.env_for("/gadget", :method => "PUT",
      :input => npm_publish_body(name: "gadget", version: "2.0.0"), "CONTENT_TYPE" => "application/json")
    @app.call(env)

    assert_equal({route: "PUT /:package_name", package: "gadget", version: "2.0.0"}, env[Paquette::Served::KEY])
  end

  private

  def served(path)
    env = Rack::MockRequest.env_for(path)
    @app.call(env)
    env[Paquette::Served::KEY]
  end
end
