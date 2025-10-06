require_relative 'test_helper'
require 'open3'
require 'tempfile'
require 'net/http'

class RealBundlerTest < RackIntegrationTest
  def setup
    super
    @server_pid = nil
    @server_port = find_free_port
    @test_dir = nil
  end
  
  def teardown
    stop_server if @server_pid
    @server_log&.close
    @server_log&.unlink
    cleanup_test_dir if @test_dir
    super
  end
  
  def test_bundler_can_install_from_paquette
    # Start the Paquette server
    start_server
    
    # Wait for server to be ready
    wait_for_server
    
    # Create a test project
    create_test_project
    
    # Run bundle install
    result = run_bundle_install
    
    # Verify success
    assert_equal 0, result[:exit_code], "Bundle install failed: #{result[:stderr]}"
    assert_includes result[:stdout], "Bundle complete!"
    
    # Print server logs for debugging
    if @server_log
      @server_log.rewind
      server_output = @server_log.read
      puts "Server output: #{server_output}"
    end
    
    # Verify the gem was installed
    verify_gem_installed
  end
  
  private
  
  def find_free_port
    require 'socket'
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end
  
  def start_server
    # Start Puma server in background with test gems directory
    gems_dir = File.expand_path('../../gems', __dir__)
    cmd = "cd #{File.expand_path('..', __dir__)} && GEMS_DIR=#{gems_dir} bundle exec puma -p #{@server_port} -e test"
    
    @server_log = Tempfile.new('paquette_server')
    @server_pid = spawn(cmd, out: @server_log.path, err: @server_log.path)
    sleep 3
  end
  
  def stop_server
    return unless @server_pid
    
    begin
      Process.kill('TERM', @server_pid)
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
        if response.code == '200'
          return
        end
      rescue => e
        # Server not ready yet
      end
      
      sleep 0.5
      attempt += 1
    end
    
    flunk "Server did not start within #{max_attempts * 0.5} seconds"
  end
  
  def create_test_project
    @test_dir = Dir.mktmpdir('paquette_test')
    
    # Create Gemfile
    gemfile_content = <<~GEMFILE
      source 'http://127.0.0.1:#{@server_port}'
      
      gem 'test-gem'
    GEMFILE
    
    File.write(File.join(@test_dir, 'Gemfile'), gemfile_content)
  end
  
  def cleanup_test_dir
    FileUtils.rm_rf(@test_dir) if @test_dir && File.exist?(@test_dir)
  end
  
  def run_bundle_install
    stdout, stderr, status = Open3.capture3(
      "cd #{@test_dir} && bundle install",
      chdir: @test_dir
    )
    
    {
      stdout: stdout,
      stderr: stderr,
      exit_code: status.exitstatus
    }
  end
  
  def verify_gem_installed
    stdout, stderr, status = Open3.capture3(
      "cd #{@test_dir} && bundle list",
      chdir: @test_dir
    )
    
    assert_equal 0, status.exitstatus, "bundle list failed: #{stderr}"
    assert_includes stdout, "test-gem"
  end
end
