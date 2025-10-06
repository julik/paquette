require "minitest/autorun"
require "rack/test"
require_relative "../lib/paquette"

class IntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    # Use the actual gems directory for testing
    @test_gems_dir = File.expand_path("./gems", Dir.pwd)
    @app = Paquette::App.new(@test_gems_dir)
  end

  attr_reader :app

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

  def test_search_endpoint
    get "/api/v1/search.json", query: "scatter"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert results.is_a?(Array)
    scatter_result = results.find { |r| r["name"] == "scatter_gather" }
    refute_nil scatter_result
  end

  # Test that compact index endpoints are disabled (return 404)
  def test_compact_index_names_disabled
    get "/names"
    assert_equal 404, last_response.status
  end

  def test_compact_index_versions_disabled
    get "/versions"
    assert_equal 404, last_response.status
  end

  def test_compact_index_info_disabled
    get "/info/scatter_gather"
    assert_equal 404, last_response.status
  end
end
