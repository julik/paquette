require_relative "test_helper"

class SubdomainRouterTest < Minitest::Test
  def setup
    @mock_app = MockApp.new
    gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    packages_dir = File.expand_path("./packages/npm", Dir.pwd)
    @gem_server = Paquette::GemServer.new(gems_dir)
    @npm_server = Paquette::NpmServer.new(packages_dir)
    @router = Paquette::SubdomainRouter.new do |router|
      router.map "gems", to: @gem_server
      router.map "npm", to: @npm_server
      router.fallback to: @mock_app
    end
  end

  def test_extract_subdomain_with_gems_subdomain
    test_cases = [
      ["gems.example.com", "gems"],
      ["gems.localhost", "gems"],
      ["gems.localhost:9292", "gems"]
    ]

    test_cases.each do |host, expected|
      result = @router.send(:extract_subdomain, host)
      assert_equal expected, result, "Expected '#{expected}' for host '#{host}', got '#{result}'"
    end
  end

  def test_extract_subdomain_with_npm_subdomain
    test_cases = [
      ["npm.example.com", "npm"],
      ["npm.localhost", "npm"],
      ["npm.localhost:9292", "npm"]
    ]

    test_cases.each do |host, expected|
      result = @router.send(:extract_subdomain, host)
      assert_equal expected, result, "Expected '#{expected}' for host '#{host}', got '#{result}'"
    end
  end

  def test_extract_subdomain_with_no_subdomain
    test_cases = [
      ["localhost", nil],
      ["localhost:9292", nil],
      ["example.com", nil],
      ["api.example.com", nil] # unknown subdomain
    ]

    test_cases.each do |host, expected|
      result = @router.send(:extract_subdomain, host)
      if expected.nil?
        assert_nil result, "Expected nil for host '#{host}', got '#{result}'"
      else
        assert_equal expected, result, "Expected '#{expected}' for host '#{host}', got '#{result}'"
      end
    end
  end

  def test_routing_to_gems_server
    env = create_env("gems.example.com", "/")

    # Mock the GemServer instance to verify it's called
    gem_server_mock = Minitest::Mock.new
    gem_server_mock.expect :call, [200, {}, ["GemServer response"]], [env]

    # Stub the instance method
    @gem_server.stub :call, ->(env) { gem_server_mock.call(env) } do
      response = @router.call(env)
      assert_equal [200, {}, ["GemServer response"]], response
    end

    gem_server_mock.verify
  end

  def test_routing_to_npm_server
    env = create_env("npm.example.com", "/")

    # Mock the NpmServer instance to verify it's called
    npm_server_mock = Minitest::Mock.new
    npm_server_mock.expect :call, [200, {}, ["NpmServer response"]], [env]

    # Stub the instance method
    @npm_server.stub :call, ->(env) { npm_server_mock.call(env) } do
      response = @router.call(env)
      assert_equal [200, {}, ["NpmServer response"]], response
    end

    npm_server_mock.verify
  end

  def test_routing_to_default_app
    env = create_env("example.com", "/")

    # The router should call the default app
    response = @router.call(env)
    assert_equal [200, {}, ["Default app response"]], response
  end

  def test_fallback_behavior
    env = create_env("unknown.example.com", "/")

    # The router should call the fallback app
    response = @router.call(env)
    assert_equal [200, {}, ["Default app response"]], response
  end

  private

  def create_env(host, path)
    {
      "HTTP_HOST" => host,
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "rack.input" => StringIO.new
    }
  end

  # Mock app for testing
  class MockApp
    def call(env)
      [200, {}, ["Default app response"]]
    end
  end
end
