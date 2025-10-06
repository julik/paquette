require 'minitest/autorun'
require 'rack/test'
require_relative '../lib/paquette'

class StandaloneRealGemsTest < Minitest::Test
  include Rack::Test::Methods
  
  def setup
    @app = Paquette::GemServer.new(File.expand_path('../gems', __dir__))
  end
  
  def app
    @app
  end
  
  def test_serves_real_gems
    get '/api/v1/names'
    assert_equal 200, last_response.status
    
    names = JSON.parse(last_response.body)
    assert_includes names, 'zip_kit'
    assert_includes names, 'scatter_gather'
  end
  
  def test_zip_kit_versions
    get '/api/v1/versions'
    assert_equal 200, last_response.status
    
    versions = JSON.parse(last_response.body)
    zip_kit_versions = versions.select { |v| v['name'] == 'zip_kit' }
    assert_equal 3, zip_kit_versions.length
    
    version_numbers = zip_kit_versions.map { |v| v['number'] }
    assert_includes version_numbers, '6.2.0'
    assert_includes version_numbers, '6.2.1'
    assert_includes version_numbers, '6.3.2'
  end
  
  def test_zip_kit_dependencies
    get '/api/v1/dependencies?gems=zip_kit'
    assert_equal 200, last_response.status
    
    dependencies = JSON.parse(last_response.body)
    assert_equal 3, dependencies.length
    
    # All zip_kit versions should be present
    version_numbers = dependencies.map { |d| d['number'] }
    assert_includes version_numbers, '6.2.0'
    assert_includes version_numbers, '6.2.1'
    assert_includes version_numbers, '6.3.2'
  end
  
  def test_compact_index_with_real_gems
    get '/names'
    assert_equal 200, last_response.status
    
    names = last_response.body.split("\n")
    assert_includes names, 'zip_kit'
    assert_includes names, 'scatter_gather'
  end
end
