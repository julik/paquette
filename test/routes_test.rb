require_relative "test_helper"

class RoutesTest < Minitest::Test
  include Rack::Test::Methods

  class TestApp
    attr_reader :last_params, :last_action

    def initialize
      @last_params = nil
      @last_action = nil
    end

    def call(env)
      request = Rack::Request.new(env)
      
      if (route = @routes.match(request))
        @last_params = route.params(request)
        @last_action = @routes.perform_action(route, self, request)
      else
        [404, {}, ["Not Found"]]
      end
    end

    def setup_routes
      @routes = Paquette::Routes.draw do |r|
        r.get "/" do
          [200, {}, ["Root"]]
        end

        r.get "/hello/:name" do |name:|
          [200, {}, ["Hello #{name}"]]
        end

        r.get "/gem/stuff/:some_param.gz" do |some_param:|
          [200, {}, ["Gem stuff with param: #{some_param}"]]
        end

        r.post "/api/data" do
          [201, {}, ["Data created"]]
        end

        r.get "/api/version/:version" do |version:|
          [200, {}, ["Version: #{version}"]]
        end
      end
    end

  end

  def setup
    @app = TestApp.new
    @app.setup_routes
  end

  attr_reader :app

  def test_root_route
    get "/"
    assert_equal 200, last_response.status
    assert_equal "Root", last_response.body
  end

  def test_hello_route_with_params
    get "/hello/world"
    assert_equal 200, last_response.status
    assert_equal "Hello world", last_response.body
    assert_equal "world", app.last_params["name"]
  end

  def test_gem_stuff_route_with_params
    get "/gem/stuff/test-param.gz"
    assert_equal 200, last_response.status
    assert_equal "Gem stuff with param: test-param", last_response.body
    assert_equal "test-param", app.last_params["some_param"]
  end

  def test_post_route
    post "/api/data"
    assert_equal 201, last_response.status
    assert_equal "Data created", last_response.body
  end

  def test_version_route_with_params
    get "/api/version/1.2.3"
    assert_equal 200, last_response.status
    assert_equal "Version: 1.2.3", last_response.body
    assert_equal "1.2.3", app.last_params["version"]
  end

  def test_nonexistent_route
    get "/nonexistent"
    assert_equal 404, last_response.status
    assert_equal "Not Found", last_response.body
  end

  def test_wrong_method
    post "/hello/world"
    assert_equal 404, last_response.status
    assert_equal "Not Found", last_response.body
  end

  def test_routes_class_draw_method
    routes = Paquette::Routes.draw do |r|
      r.get "/test" do
        [200, {}, ["Test"]]
      end
    end

    assert_instance_of Paquette::Routes, routes
    assert_equal 1, routes.instance_variable_get(:@routes).length
  end

  def test_route_builder_methods
    routes = Paquette::Routes.draw do |r|
      r.get "/get" do; [200, {}, ["GET"]]; end
      r.post "/post" do; [200, {}, ["POST"]]; end
      r.put "/put" do; [200, {}, ["PUT"]]; end
      r.delete "/delete" do; [200, {}, ["DELETE"]]; end
      r.patch "/patch" do; [200, {}, ["PATCH"]]; end
    end

    assert_equal 5, routes.instance_variable_get(:@routes).length
  end

  def test_instance_exec_in_route_blocks
    test_instance = self
    
    routes = Paquette::Routes.draw do |r|
      r.get "/self-test" do
        [200, {}, ["Instance: #{self.class}"]]
      end
    end

    # Create a mock request
    request = Rack::Request.new(Rack::MockRequest.env_for("/self-test"))
    route = routes.match(request)
    
    assert route
    result = routes.perform_action(route, test_instance, request)
    assert_equal [200, {}, ["Instance: RoutesTest"]], result
  end
end
