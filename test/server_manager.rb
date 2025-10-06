require "open3"
require "net/http"
require "tempfile"
require "timeout"

class ServerManager
  @@server_pid = nil
  @@server_port = nil
  @@server_output = nil

  def self.start_server(port = nil)
    return if @@server_pid

    port ||= find_free_port
    @@server_port = port

    # Start the server in the background with the gems directory
    gems_dir = File.expand_path("../gems", __dir__)
    cmd = "GEMS_DIR=#{gems_dir} bundle exec puma -p #{port}"
    @@server_output = Tempfile.new("paquette_server")
    
    # Use spawn to start the process in the background
    @@server_pid = spawn(cmd, out: @@server_output.path, err: @@server_output.path)
    
    # Wait for the server to be ready
    wait_for_server(port)
    
    # Register cleanup
    at_exit { stop_server }
  end

  def self.stop_server
    return unless @@server_pid

    begin
      Process.kill("TERM", @@server_pid)
      # Use a timeout to avoid hanging
      Timeout.timeout(5) do
        Process.wait(@@server_pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
      # Process already dead or timeout
    ensure
      @@server_pid = nil
      @@server_port = nil
      @@server_output&.close
      @@server_output = nil
    end
  end

  def self.server_url
    "http://127.0.0.1:#{@@server_port}"
  end

  def self.server_port
    @@server_port
  end

  def self.server_pid
    @@server_pid
  end

  def self.server_output
    @@server_output&.read
  end

  private

  def self.find_free_port
    require "socket"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def self.wait_for_server(port, max_attempts = 30)
    max_attempts.times do |i|
      begin
        response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/"))
        return if response.code == "200"
      rescue
        # Server not ready yet
      end
      
      sleep 0.5
    end
    
    raise "Server did not start within #{max_attempts * 0.5} seconds"
  end
end
