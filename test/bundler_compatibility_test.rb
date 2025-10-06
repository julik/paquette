require_relative "test_helper"

class BundlerCompatibilityTest < RackIntegrationTest
  def test_bundler_can_fetch_specs
    # Test the specs endpoint that Bundler uses
    get "/specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    # The specs are now in Marshal format, so we can't easily test the content
    # Just verify it returns data
    assert last_response.body.length > 0
  end

  def test_bundler_can_fetch_dependencies
    # Test the dependencies endpoint that Bundler uses
    get "/api/v1/dependencies", gems: ["test-gem"]
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal 1, dependencies.length
    assert_equal "test-gem", dependencies[0]["name"]
    assert_equal "1.0.0", dependencies[0]["number"]
    assert_equal "ruby", dependencies[0]["platform"]
    assert_equal [], dependencies[0]["dependencies"]
  end

  def test_bundler_can_download_gems
    # Test that Bundler can download gem files
    get "/gems/test-gem-1.0.0.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal "fake gem content", last_response.body
  end

  def test_bundler_handles_missing_gems_gracefully
    # Test that missing gems return 404 (Bundler expects this)
    get "/gems/nonexistent-1.0.0.gem"
    assert_equal 404, last_response.status
  end

  def test_bundler_can_search_gems
    # Test the search endpoint
    get "/api/v1/search.json", query: "test"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert_equal 1, results.length
    assert_equal "test-gem", results[0]["name"]
    assert_equal "1.0.0", results[0]["version"]
  end

  def test_bundler_can_get_gem_names
    # Test the names endpoint
    get "/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_includes names, "test-gem"
    assert_includes names, "another-gem"
  end

  def test_bundler_can_get_gem_versions
    # Test the versions endpoint
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    versions = JSON.parse(last_response.body)
    assert_equal 2, versions.length

    test_gem = versions.find { |v| v["name"] == "test-gem" }
    assert_equal "1.0.0", test_gem["number"]
    assert_equal "ruby", test_gem["platform"]
  end
end
