require_relative "test_helper"
require "open3"
require "tempfile"
require "net/http"

class BundlerInstallTest < Minitest::Test
  def setup
    @server_pid = nil
    @server_port = find_free_port
    @gems_dir = File.expand_path("../../gems", __dir__)
  end

  def teardown
    stop_server if @server_pid
  end

  def test_bundler_can_install_from_paquette
    # Start the Paquette server
    start_server
    wait_for_server

    # Create a temporary directory for the test
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        # Create a simple Gemfile that uses our test gem
        create_gemfile
        create_gemfile_lock

        # Run bundler install
        result = run_bundler_install
        assert result[:success], "Bundler install failed: #{result[:error]}"

        # Verify the gem was installed
        assert File.exist?("vendor/bundle/ruby/*/gems/test-gem-1.0.0"), "test-gem was not installed"
      end
    end
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
    gems_dir = File.expand_path("../../gems", __dir__)
    cmd = "cd #{File.expand_path("../..", __dir__)} && GEMS_DIR=#{gems_dir} bundle exec puma -p #{@server_port} -e test"
    
    @server_pid = spawn(cmd, out: "/dev/null", err: "/dev/null")
    sleep 2
  end

  def stop_server
    return unless @server_pid
    
    Process.kill("TERM", @server_pid)
    Process.wait(@server_pid)
    @server_pid = nil
  rescue Errno::ESRCH, Errno::ECHILD
    # Process already dead
  end

  def wait_for_server
    max_attempts = 30
    attempts = 0
    
    while attempts < max_attempts
      begin
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/"))
        return if response.code == "200"
      rescue
        # Server not ready yet
      end
      
      sleep 0.5
      attempts += 1
    end
    
    flunk "Server did not start within 15 seconds"
  end

  def create_gemfile
    File.write("Gemfile", <<~GEMFILE)
      source "http://127.0.0.1:#{@server_port}"
      
      gem "test-gem", "~> 1.0"
    GEMFILE
  end

  def create_gemfile_lock
    File.write("Gemfile.lock", <<~LOCK)
      GEM
        remote: http://127.0.0.1:#{@server_port}/
        specs:
          test-gem (1.0.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        test-gem (~> 1.0)

      BUNDLED WITH
        2.4.0
    LOCK
  end

  def run_bundler_install
    stdout, stderr, status = Open3.capture3("bundle install --path vendor/bundle")
    
    {
      success: status.success?,
      stdout: stdout,
      error: stderr
    }
  end
end
