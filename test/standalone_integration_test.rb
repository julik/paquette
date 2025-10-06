require "minitest/autorun"
require "net/http"
require "socket"
require "tempfile"
require "json"

class StandaloneIntegrationTest < Minitest::Test
  def setup
    @server_pid = nil
    @server_port = find_free_port
  end

  def teardown
    stop_server if @server_pid
  end

  def test_server_starts_and_serves_real_gems
    # Start the Paquette server
    start_server

    # Wait for server to be ready
    wait_for_server

    # Test all gem endpoints
    test_names_endpoint
    test_versions_endpoint
    test_info_endpoints
    test_dependencies_endpoint
    test_gem_downloads
  end

  private

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def start_server
    # Start Puma server in background with real gems directory
    gems_dir = File.expand_path("../gems", __dir__)
    cmd = "cd #{File.expand_path("..", __dir__)} && GEMS_DIR=#{gems_dir} bundle exec puma -p #{@server_port} -e test"

    @server_pid = spawn(cmd, out: "/dev/null", err: "/dev/null")
    sleep 3
  end

  def stop_server
    return unless @server_pid

    begin
      Process.kill("TERM", @server_pid)
      Process.wait(@server_pid, 5)
    rescue Errno::ESRCH, Errno::ECHILD
      # Process already dead
    ensure
      @server_pid = nil
    end
  end

  def wait_for_server
    max_attempts = 30
    attempt = 0

    while attempt < max_attempts
      begin
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/"))
        if response.code == "200"
          return
        end
      rescue
        # Server not ready yet
      end

      sleep 0.5
      attempt += 1
    end

    flunk "Server did not start within #{max_attempts * 0.5} seconds"
  end

  def test_names_endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/names"))
    assert_equal "200", response.code
    assert_equal "text/plain", response.content_type

    names = response.body.split("\n")
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
    assert_equal 2, names.length
  end

  def test_versions_endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/versions"))
    assert_equal "200", response.code
    assert_equal "text/plain", response.content_type

    versions = response.body.split("\n")
    assert_includes versions, "test-gem 1.0.0"
    assert_includes versions, "zip_kit 6.2.0"
    assert_includes versions, "zip_kit 6.2.1"
    assert_includes versions, "zip_kit 6.3.2"
    assert_equal 4, versions.length
  end

  def test_info_endpoints
    # Test zip_kit info
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/info/zip_kit"))
    assert_equal "200", response.code
    assert_equal "text/plain", response.content_type

    info_lines = response.body.split("\n")
    assert_includes info_lines, "zip_kit,6.2.0,ruby,"
    assert_includes info_lines, "zip_kit,6.2.1,ruby,"
    assert_includes info_lines, "zip_kit,6.3.2,ruby,"
    assert_equal 3, info_lines.length

    # Test test-gem info
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/info/test-gem"))
    assert_equal "200", response.code
    assert_equal "text/plain", response.content_type

    info_lines = response.body.split("\n")
    assert_includes info_lines, "test-gem,1.0.0,ruby,"
    assert_equal 1, info_lines.length

    # Test nonexistent gem
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/info/nonexistent"))
    assert_equal "404", response.code
  end

  def test_dependencies_endpoint
    # Test single gem
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=zip_kit"))
    assert_equal "200", response.code
    assert_equal "application/json", response.content_type

    dependencies = JSON.parse(response.body)
    assert_equal 3, dependencies.length

    zip_kit_versions = dependencies.map { |d| d["number"] }
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"

    # Test multiple gems
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=zip_kit,test-gem"))
    assert_equal "200", response.code

    dependencies = JSON.parse(response.body)
    assert_equal 4, dependencies.length

    # Test empty request
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies"))
    assert_equal "200", response.code

    dependencies = JSON.parse(response.body)
    assert_equal 4, dependencies.length
  end

  def test_gem_downloads
    # Test zip_kit download
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/gems/zip_kit-6.3.2.gem"))
    assert_equal "200", response.code
    assert_equal "application/octet-stream", response.content_type
    assert response.body.length > 0

    # Test test-gem download
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/gems/test-gem-1.0.0.gem"))
    assert_equal "200", response.code
    assert_equal "application/octet-stream", response.content_type
    assert response.body.length > 0

    # Test nonexistent gem
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/gems/nonexistent-1.0.0.gem"))
    assert_equal "404", response.code
  end
end
