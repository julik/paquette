require_relative "test_helper"

class SubdomainRouterIntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    # No need to set environment variables since we use the packages directory structure
  end

  def app
    # Load the actual config.ru file
    Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
  end

  def test_gem_subdomain_routing
    # Test that requests to gem.example.com are routed to GemServer
    get "/", {}, {"HTTP_HOST" => "gem.example.com"}
    assert_equal 200, last_response.status
    assert_equal "Paquette RubyGems Repository", last_response.body
  end

  def test_gem_subdomain_api_endpoints
    # Test that gem API endpoints work with gem subdomain
    get "/api/v1/names", {}, {"HTTP_HOST" => "gem.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
  end

  def test_gem_subdomain_specs_endpoint
    # Test that specs endpoint works with gem subdomain
    get "/specs.4.8", {}, {"HTTP_HOST" => "gem.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert specs.length >= 6

    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_npm_subdomain_routing
    # Test that requests to npm.example.com are routed to NpmServer
    get "/", {}, {"HTTP_HOST" => "npm.example.com"}
    assert_equal 200, last_response.status
    assert_equal "Paquette NPM Repository", last_response.body
  end

  def test_npm_subdomain_ping_endpoint
    # Test that npm ping endpoint works with npm subdomain
    get "/-/ping", {}, {"HTTP_HOST" => "npm.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    response = JSON.parse(last_response.body)
    assert_equal({}, response)
  end

  def test_npm_subdomain_package_metadata
    # Test that package metadata works with npm subdomain
    get "/react-dropzone", {}, {"HTTP_HOST" => "npm.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    metadata = JSON.parse(last_response.body)
    assert_equal "react-dropzone", metadata["name"]
    assert metadata["versions"].is_a?(Hash)
    assert metadata["versions"].key?("14.3.8")
  end

  def test_npm_subdomain_package_download
    # Test that package download works with npm subdomain
    get "/react-dropzone/react-dropzone-14.3.8.tgz", {}, {"HTTP_HOST" => "npm.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_unknown_subdomain_fallback
    # Test that unknown subdomains get the fallback response
    get "/", {}, {"HTTP_HOST" => "api.example.com"}
    assert_equal 404, last_response.status
    assert_equal "Need subdomain gem/npm", last_response.body
  end

  def test_no_subdomain_fallback
    # Test that requests without subdomain get the fallback response
    get "/", {}, {"HTTP_HOST" => "example.com"}
    assert_equal 404, last_response.status
    assert_equal "Need subdomain gem/npm", last_response.body
  end

  def test_localhost_with_port_gem_subdomain
    # Test that localhost with port works for gem subdomain
    get "/", {}, {"HTTP_HOST" => "gem.localhost:9292"}
    assert_equal 200, last_response.status
    assert_equal "Paquette RubyGems Repository", last_response.body
  end

  def test_localhost_with_port_npm_subdomain
    # Test that localhost with port works for npm subdomain
    get "/", {}, {"HTTP_HOST" => "npm.localhost:9292"}
    assert_equal 200, last_response.status
    assert_equal "Paquette NPM Repository", last_response.body
  end

  def test_gem_subdomain_gem_download
    # Test that gem download works with gem subdomain
    get "/gems/scatter_gather-0.1.1.gem", {}, {"HTTP_HOST" => "gem.example.com"}
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_cross_subdomain_isolation
    # Test that npm endpoints don't work on gem subdomain
    get "/-/ping", {}, {"HTTP_HOST" => "gem.example.com"}
    assert_equal 404, last_response.status

    # Test that gem endpoints don't work on npm subdomain
    get "/api/v1/names", {}, {"HTTP_HOST" => "npm.example.com"}
    assert_equal 404, last_response.status
  end
end
