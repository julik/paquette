require_relative "test_helper"

class IntegrationTest < RackIntegrationTest
  def setup
    # Use the actual gems directory for testing
    @test_gems_dir = File.expand_path("../../gems", __dir__)
    @app = Paquette::App.new(@test_gems_dir)
  end

  def app
    @app
  end

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
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
  end

  def test_versions_endpoint
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    versions = JSON.parse(last_response.body)
    assert versions.length >= 6 # We have 6 gems in total

    # Check for specific gems
    scatter_gather_versions = versions.select { |v| v["name"] == "scatter_gather" }
    assert_equal 2, scatter_gather_versions.length
    assert_includes scatter_gather_versions.map { |v| v["number"] }, "0.1.0"
    assert_includes scatter_gather_versions.map { |v| v["number"] }, "0.1.1"

    zip_kit_versions = versions.select { |v| v["name"] == "zip_kit" }
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.0"
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.1"
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.3.2"
  end

  def test_specs_endpoint
    get "/specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert specs.length >= 6

    # Check for specific gems
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_latest_specs_endpoint
    get "/latest_specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert specs.length >= 3 # Should have latest version of each gem

    # Check for latest versions
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_gem_download
    get "/gems/scatter_gather-0.1.1.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_gem_info_endpoint
    get "/info/scatter_gather"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    info = JSON.parse(last_response.body)
    assert_equal "scatter_gather", info["name"]
    assert info["version"].is_a?(String)
    assert info["info"].is_a?(String)
  end

  def test_search_endpoint
    get "/api/v1/search.json", query: "scatter"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert results.is_a?(Array)
    scatter_result = results.find { |r| r["name"] == "scatter_gather" }
    assert_not_nil scatter_result
  end

  def test_compact_index_names
    get "/names"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    names = last_response.body.split("\n")
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
  end

  def test_compact_index_versions
    get "/versions"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    versions = last_response.body.split("\n")
    assert versions.length >= 6
    assert_includes versions, "scatter_gather 0.1.0,0.1.1"
    assert_includes versions, "test-gem 1.0.0"
    assert_includes versions, "zip_kit 6.2.0,6.2.1,6.3.2"
  end

  def test_compact_index_info
    get "/info/scatter_gather"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    info = last_response.body
    assert_includes info, "scatter_gather"
    assert_includes info, "0.1.0"
    assert_includes info, "0.1.1"
  end
end