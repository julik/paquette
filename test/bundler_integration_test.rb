require_relative "test_helper"
require "open3"
require "timeout"
require "tempfile"
require "net/http"

class BundlerIntegrationTest < RackIntegrationTest
  def setup
    super
    @server_pid = nil
    @server_port = find_free_port
  end

  def teardown
    stop_server if @server_pid
    @server_log&.close
    @server_log&.unlink
    super
  end

  def test_bundler_can_install_gems_from_paquette
    # Start the Paquette server
    start_server

    # Wait for server to be ready
    wait_for_server

    # Test that Bundler can install gems from Paquette
    result = run_bundler_install

    # Verify the installation was successful
    assert_equal 0, result[:exit_code], "Bundle install failed: #{result[:stderr]}"
    assert_includes result[:stdout], "Bundle complete!"
    assert_includes result[:stdout], "test-gem"

    # Verify the gem was actually installed
    verify_gem_installation
  end

  def test_bundler_can_use_compact_index
    # Start the Paquette server
    start_server

    # Wait for server to be ready
    wait_for_server

    # Test compact index endpoints work
    test_compact_index_endpoints

    # Test that Bundler can use the compact index
    result = run_bundler_install

    assert_equal 0, result[:exit_code], "Bundle install failed: #{result[:stderr]}"
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
    # Start Puma server in background with test gems directory
    gems_dir = File.expand_path("../../gems", __dir__)
    cmd = "cd #{File.expand_path("..", __dir__)} && GEMS_DIR=#{gems_dir} bundle exec puma -p #{@server_port} -e test"

    # Use a temporary file for server output to debug issues
    @server_log = Tempfile.new("paquette_server")
    @server_pid = spawn(cmd, out: @server_log.path, err: @server_log.path)

    # Give the server a moment to start
    sleep 3
  end

  def stop_server
    return unless @server_pid

    begin
      Process.kill("TERM", @server_pid)
      Process.wait(@server_pid, 5) # Wait up to 5 seconds
    rescue Errno::ESRCH, Errno::ECHILD
      # Process already dead
    rescue => e
      puts "Warning: Could not stop server cleanly: #{e.message}"
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
        # Server not ready yet
      rescue
        # Server not ready yet
      end

      sleep 0.5
      attempt += 1
    end

    # Print server logs for debugging
    if @server_log
      @server_log.rewind
      server_output = @server_log.read
      puts "Server output: #{server_output}"
    end

    flunk "Server did not start within #{max_attempts * 0.5} seconds"
  end

  def run_bundler_install
    # Create a temporary directory for the test
    test_dir = File.expand_path("bundler_integration", __dir__)

    # Update the Gemfile to use the correct port
    update_gemfile_with_port(test_dir)

    # Change to the test directory and run bundle install
    stdout, stderr, status = Open3.capture3(
      "cd #{test_dir} && bundle install",
      chdir: test_dir
    )

    {
      stdout: stdout,
      stderr: stderr,
      exit_code: status.exitstatus
    }
  end

  def verify_gem_installation
    test_dir = File.expand_path("bundler_integration", __dir__)

    # Check that the gem was installed in the bundle
    stdout, stderr, status = Open3.capture3(
      "cd #{test_dir} && bundle list",
      chdir: test_dir
    )

    assert_equal 0, status.exitstatus, "bundle list failed: #{stderr}"
    assert_includes stdout, "test-gem"
  end

  def test_compact_index_endpoints
    require "net/http"

    # Test /names endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/names"))
    assert_equal "200", response.code
    assert_includes response.body, "test-gem"

    # Test /versions endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/versions"))
    assert_equal "200", response.code
    assert_includes response.body, "test-gem 1.0.0"

    # Test /info endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/info/test-gem"))
    assert_equal "200", response.code
    assert_includes response.body, "test-gem,1.0.0,ruby,"
  end

  def update_gemfile_with_port(test_dir)
    gemfile_path = File.join(test_dir, "Gemfile")
    gemfile_content = File.read(gemfile_path)
    updated_content = gemfile_content.gsub(/localhost:\d+/, "127.0.0.1:#{@server_port}")
    File.write(gemfile_path, updated_content)
  end
end
