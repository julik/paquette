require 'minitest/autorun'
require 'rack/test'
require 'fileutils'
require_relative '../lib/paquette'

class RackIntegrationTest < Minitest::Test
  include Rack::Test::Methods
  
  def setup
    # Create a temporary gems directory for testing
    @test_gems_dir = File.expand_path('../test_gems', __dir__)
    FileUtils.mkdir_p(@test_gems_dir)
    
    # Create test gems
    create_test_gems
  end
  
  def app
    @app ||= Paquette::App.new(@test_gems_dir)
  end
  
  def teardown
    # Clean up test gems directory
    FileUtils.rm_rf(@test_gems_dir) if File.exist?(@test_gems_dir)
  end
  
  private
  
  def create_test_gems
    # Create test-gem-1.0.0.gem
    File.write(File.join(@test_gems_dir, 'test-gem-1.0.0.gem'), "fake gem content")
    
    # Create another-gem-2.1.0.gem
    File.write(File.join(@test_gems_dir, 'another-gem-2.1.0.gem'), "fake gem content")
  end
end
