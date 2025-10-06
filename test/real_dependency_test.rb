require "minitest/autorun"
require "net/http"
require "socket"
require "json"

class RealDependencyTest < Minitest::Test
  def setup
    @server_pid = nil
    @server_port = find_free_port
  end

  def teardown
    stop_server if @server_pid
  end

  def test_dependencies_endpoint_with_real_gems
    # Start the Paquette server with real gems
    start_server

    # Wait for server to be ready
    wait_for_server

    # Test dependencies endpoint
    test_dependencies_endpoint
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

  def test_dependencies_endpoint
    # Test single gem
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=test-gem"))
    assert_equal "200", response.code
    assert_equal "application/json", response.content_type

    dependencies = JSON.parse(response.body)
    assert_equal 1, dependencies.length

    test_gem = dependencies.first
    assert_equal "test-gem", test_gem["name"]
    assert_equal "1.0.0", test_gem["number"]
    assert_equal "ruby", test_gem["platform"]
    assert_equal [], test_gem["dependencies"] # test-gem has no dependencies

    # Test zip_kit
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=zip_kit"))
    assert_equal "200", response.code

    dependencies = JSON.parse(response.body)
    assert_equal 3, dependencies.length # zip_kit has 3 versions

    # All zip_kit versions should have no runtime dependencies
    dependencies.each do |dep|
      assert_equal "zip_kit", dep["name"]
      assert_equal "ruby", dep["platform"]
      assert_equal [], dep["dependencies"] # zip_kit has no runtime dependencies
    end

    # Test multiple gems
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=test-gem,zip_kit"))
    assert_equal "200", response.code

    dependencies = JSON.parse(response.body)
    assert_equal 4, dependencies.length # test-gem (1) + zip_kit (3)

    # Test all gems
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies"))
    assert_equal "200", response.code

    dependencies = JSON.parse(response.body)
    assert_equal 4, dependencies.length # All gems in the repository
  end
end
