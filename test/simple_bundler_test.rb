require_relative 'test_helper'
require 'open3'
require 'tempfile'
require 'net/http'

class SimpleBundlerTest < RackIntegrationTest
  def setup
    super
    @server_pid = nil
    @server_port = find_free_port
  end
  
  def teardown
    stop_server if @server_pid
    super
  end
  
  def test_server_can_serve_gems
    # Start the Paquette server
    start_server
    
    # Wait for server to be ready
    wait_for_server
    
    # Test that the server can serve gem information
    test_gem_endpoints
    
    # Test that we can download a gem
    test_gem_download
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
    
    @server_pid = spawn(cmd, out: '/dev/null', err: '/dev/null')
    sleep 2
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
  
  def test_gem_endpoints
    # Test /names endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/names"))
    assert_equal '200', response.code
    assert_includes response.body, 'test-gem'
    
    # Test /versions endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/versions"))
    assert_equal '200', response.code
    assert_includes response.body, 'test-gem 1.0.0'
    
    # Test /info endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/info/test-gem"))
    assert_equal '200', response.code
    assert_includes response.body, 'test-gem,1.0.0,ruby,'
    
    # Test /api/v1/dependencies endpoint
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/api/v1/dependencies?gems=test-gem"))
    assert_equal '200', response.code
    assert_includes response.body, 'test-gem'
  end
  
  def test_gem_download
    # Test gem download
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{@server_port}/gems/test-gem-1.0.0.gem"))
    assert_equal '200', response.code
    assert_equal 'application/octet-stream', response.content_type
    assert response.body.length > 0
  end
end
