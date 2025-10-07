require_relative "test_helper"

class BundlerInstallTest < Minitest::Test
  def setup
    @server_thread = nil
    @server_port = find_free_port
    @gems_dir = File.expand_path("./gems", Dir.pwd)
  end

  def teardown
    stop_server if @server_thread
  end

  def test_gem_installation
    skip
    start_server
    wait_for_server

    tempdir = Dir.mktmpdir
    pid = fork do
      Dir.chdir(tempdir)
      File.open("Gemfile", "w") do |gemfile|
        gemfile << <<~RUBY
          source "http://localhost:#{@server_port}" do
            gem "zip_kit"
            gem "minuscule_test"
          end
        RUBY
      end
      ENV.delete("BUNDLE_GEMFILE")
      puts `bundle install --verbose`
    end
    Process.wait(pid)
  ensure
    stop_server
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
end
