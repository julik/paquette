require "minitest/autorun"
require "net/http"
require_relative "../lib/paquette"

class BundlerInstallTest < Minitest::Test
  GEMFILE_SOURCE = <<~RUBY
    source "http://localhost:9876" do
      gem "zip_kit"
    end
  RUBY

  def setup
    @server_thread = nil
    @server_port = find_free_port
    @gems_dir = File.expand_path("./gems", Dir.pwd)
  end

  def teardown
    stop_server if @server_thread
  end

  def test_paquette_server_can_serve_gems
    # Start the Paquette server
    start_server
    wait_for_server

    # Test that the server can serve gem information
    test_gem_endpoints

    # Test that we can download a gem
    test_gem_download
  end

  private

  def find_free_port
    require "socket"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def start_server
    gems_dir = File.expand_path("./gems", Dir.pwd)
    cmd = "cd #{Dir.pwd} && GEMS_DIR=#{gems_dir} puma -p #{@server_port} -e test"

    @server_thread = Thread.new do
      system(cmd)
    end
  end

  def stop_server
    return unless @server_thread

    # Kill the puma process
    system("pkill -f 'puma.*#{@server_port}'")
    @server_thread.kill
    @server_thread.join(1) # Wait up to 1 second for thread to finish
    @server_thread = nil
  end

  def wait_for_server
    max_attempts = 50 # 5 seconds with 0.1 second intervals
    attempts = 0

    while attempts < max_attempts
      begin
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/"))
        return if response.code == "200"
      rescue
        # Server not ready yet
      end

      sleep 0.1
      attempts += 1
    end

    flunk "Server did not start within 5 seconds"
  end

  def test_gem_endpoints
    # Test names endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/names"))
    assert_equal "200", response.code
    names = JSON.parse(response.body)
    assert_includes names, "test-gem"

    # Test versions endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/versions"))
    assert_equal "200", response.code
    versions = JSON.parse(response.body)
    test_gem_versions = versions.select { |v| v["name"] == "test-gem" }
    assert_equal 1, test_gem_versions.length
    assert_equal "1.0.0", test_gem_versions.first["number"]

    # Test specs endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/specs.4.8"))
    assert_equal "200", response.code
    assert_equal "application/octet-stream", response.content_type
    specs = Marshal.load(response.body)
    assert specs.is_a?(Array)
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "test-gem"
  end

  def test_gem_download
    # Test gem download
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/gems/test-gem-1.0.0.gem"))
    assert_equal "200", response.code
    assert_equal "application/octet-stream", response.content_type
    assert response.body.length > 0
  end
end
