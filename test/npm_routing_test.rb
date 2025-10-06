require_relative 'test_helper'

class NpmRoutingTest < RackIntegrationTest
  def test_npm_package_routing
    get '/express'
    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.content_type
    
    response = JSON.parse(last_response.body)
    assert_equal 'express', response['name']
  end
  
  def test_npm_scoped_package_routing
    get '/@types/node'
    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.content_type
    
    response = JSON.parse(last_response.body)
    assert_equal '@types/node', response['name']
  end
  
  def test_npm_explicit_routing
    get '/npm/express'
    assert_equal 200, last_response.status
    assert_equal 'application/json', last_response.content_type
    
    response = JSON.parse(last_response.body)
    assert_equal 'express', response['name']
  end
end
