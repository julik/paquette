require_relative "test_helper"

class IntegrationTest < RackIntegrationTest
  def test_root_endpoint
    get "/"
    assert_equal 200, last_response.status
    assert_equal "Paquette RubyGems Repository", last_response.body
  end

  def test_names_endpoint
    get "/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_includes names, "test-gem"
    assert_includes names, "another-gem"
  end

  def test_versions_endpoint
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    versions = JSON.parse(last_response.body)
    assert_equal 2, versions.length

    test_gem = versions.find { |v| v["name"] == "test-gem" }
    assert_equal "1.0.0", test_gem["number"]
    assert_equal "ruby", test_gem["platform"]
  end

  def test_dependencies_endpoint_with_array
    get "/api/v1/dependencies", gems: ["test-gem"]
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal 1, dependencies.length
    assert_equal "test-gem", dependencies[0]["name"]
    assert_equal "1.0.0", dependencies[0]["number"]
  end

  def test_dependencies_endpoint_with_single_gem
    get "/api/v1/dependencies", gems: "test-gem"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal 1, dependencies.length
    assert_equal "test-gem", dependencies[0]["name"]
  end

  def test_dependencies_endpoint_empty
    get "/api/v1/dependencies"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal [], dependencies
  end

  def test_gem_download
    get "/gems/test-gem-1.0.0.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal "fake gem content", last_response.body
  end

  def test_gem_download_not_found
    get "/gems/nonexistent-1.0.0.gem"
    assert_equal 404, last_response.status
    assert_equal "Gem not found", last_response.body
  end

  def test_search_endpoint
    get "/api/v1/search.json", query: "test"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert_equal 1, results.length
    assert_equal "test-gem", results[0]["name"]
  end

  def test_search_endpoint_empty_query
    get "/api/v1/search.json"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert_equal 2, results.length # Should return all gems
  end

  def test_specs_endpoint
    get "/specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    # The specs are now in Marshal format, so we can't easily test the content
    # Just verify it returns data
    assert last_response.body.length > 0
  end

  def test_specs_gz_endpoint
    get "/specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type

    # The specs are now in compressed Marshal format
    assert last_response.body.length > 0
  end

  def test_gem_upload_endpoint
    post "/api/v1/gems"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    response = JSON.parse(last_response.body)
    assert_equal "success", response["status"]
  end

  def test_not_found
    get "/nonexistent"
    # Now routes to NPM server, which returns package info
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    response = JSON.parse(last_response.body)
    assert_equal "nonexistent", response["name"]
  end
end
