require_relative "test_helper"

# route_for exists so an application can name a request — a monitoring
# action, a log field — before handling it, and in front of a cache, without
# keeping a parallel routing table of its own. What it owes: the same route
# the dispatch would pick, stable names, path params, and no reading of the
# body along the way.
class RouteRecognitionTest < Minitest::Test
  def test_gem_server_names_the_download_route_and_extracts_the_filename
    recognition = Paquette::GemServer.route_for(Rack::MockRequest.env_for("/gems/zip_kit-6.2.1.gem"))

    assert_equal "GET /gems/:gem_filename", recognition.name
    assert_equal "zip_kit-6.2.1.gem", recognition.params[:gem_filename]
  end

  def test_gem_server_names_the_index_routes
    assert_equal "GET /versions", Paquette::GemServer.route_for(Rack::MockRequest.env_for("/versions")).name
    assert_equal "GET /info/:gem_name", Paquette::GemServer.route_for(Rack::MockRequest.env_for("/info/zip_kit")).name
    assert_equal "POST /api/v1/gems",
      Paquette::GemServer.route_for(Rack::MockRequest.env_for("/api/v1/gems", method: "POST")).name
  end

  def test_gem_server_returns_nil_for_a_request_no_route_wants
    assert_nil Paquette::GemServer.route_for(Rack::MockRequest.env_for("/definitely/not/a/route"))
    assert_nil Paquette::GemServer.route_for(Rack::MockRequest.env_for("/versions", method: "PATCH"))
  end

  def test_recognition_reads_the_path_and_never_the_body
    env = Rack::MockRequest.env_for("/api/v1/gems",
      :method => "POST", :input => "gem bytes", "CONTENT_TYPE" => "application/octet-stream")

    Paquette::GemServer.route_for(env)

    assert_equal 0, env["rack.input"].pos, "route_for read the request body"
  end

  def test_split_gem_filename
    assert_equal ["zip_kit", "6.2.1"], Paquette::GemServer.split_gem_filename("zip_kit-6.2.1.gem")
    assert_equal ["a-1", "1.0.0"], Paquette::GemServer.split_gem_filename("a-1-1.0.0.gem")
    assert_nil Paquette::GemServer.split_gem_filename("not-a-gem-at-all")
    assert_nil Paquette::GemServer.split_gem_filename(nil)
    assert_nil Paquette::GemServer.split_gem_filename("zip\xFF_kit-1.0.0.gem".b)
  end

  def test_npm_server_names_metadata_and_tarball_routes_in_one_scoped_spelling
    metadata = Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/@acme%2Fwidgets"))
    assert_equal "GET /:package_name", metadata.name
    assert_equal "@acme/widgets", metadata.params[:package_name]

    # The plain-slash spelling npm uses for tarball URLs lands on the same
    # routes with the same params.
    tarball = Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/@acme/widgets/-/widgets-1.0.0.tgz"))
    assert_equal "GET /:package_name/-/:tarball_name", tarball.name
    assert_equal "@acme/widgets", tarball.params[:package_name]
    assert_equal "widgets-1.0.0.tgz", tarball.params[:tarball_name]
  end

  def test_npm_server_names_publish_and_unpublish
    publish = Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/@acme/widgets", method: "PUT"))
    assert_equal "PUT /:package_name", publish.name

    unpublish = Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/@acme/widgets/-rev/3-abc", method: "DELETE"))
    assert_equal "DELETE /:package_name/-rev/:rev", unpublish.name
  end

  def test_npm_server_returns_nil_for_a_request_no_route_wants
    assert_nil Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/a/b/c/d/e"))
    assert_nil Paquette::NpmServer.route_for(Rack::MockRequest.env_for("/-/ping", method: "PATCH"))
  end

  def test_version_from_tarball_name
    assert_equal "1.0.0", Paquette::NpmServer.version_from_tarball_name("@acme/widgets", "widgets-1.0.0.tgz")
    assert_equal "2.0.0-beta.1", Paquette::NpmServer.version_from_tarball_name("plain", "plain-2.0.0-beta.1.tgz")
    assert_nil Paquette::NpmServer.version_from_tarball_name("@acme/widgets", "other-1.0.0.tgz")
    assert_nil Paquette::NpmServer.version_from_tarball_name("plain", "plain-.tgz")
    assert_nil Paquette::NpmServer.version_from_tarball_name("plain", "plain-1.0.0.zip")
  end
end
