require_relative "test_helper"

class GemServerRepositoryTest < RackIntegrationTest
  def setup
    super
    @app = Paquette::GemServer.new(@test_gems_dir)
  end

  def test_gem_server_uses_repository
    # Test that the gem server is using the repository abstraction
    get "/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_includes names, "test-gem"
    assert_includes names, "another-gem"
    assert_equal 2, names.length
  end

  def test_dependencies_through_repository
    get "/api/v1/dependencies?gems=test-gem"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal 1, dependencies.length
    assert_equal "test-gem", dependencies[0]["name"]
    assert_equal "1.0.0", dependencies[0]["number"]
    assert_equal "ruby", dependencies[0]["platform"]
    assert_equal [], dependencies[0]["dependencies"]
  end

  def test_compact_index_through_repository
    get "/names"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    names = last_response.body.split("\n")
    assert_includes names, "test-gem"
    assert_includes names, "another-gem"
    assert_equal 2, names.length
  end

  def test_gem_download_through_repository
    get "/gems/test-gem-1.0.0.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal "fake gem content", last_response.body
  end
end
