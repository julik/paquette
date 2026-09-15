require "mustermann"

module Paquette
  class Routes
    class Route
      attr_reader :method, :pattern, :block

      def initialize(method, pattern, block)
        @method = method
        @pattern = Mustermann.new(pattern)
        @block = block
      end

      def match?(request)
        @method == request.request_method && @pattern.match(request.path_info)
      end

      def params(request)
        @pattern.params(request.path_info)
      end

      def perform_action(instance, request)
        # Extract params and pass them as keyword arguments
        route_params = params(request)
        # Also include query parameters
        query_params = request.params
        # Convert string keys to symbols for keyword arguments
        symbol_params = route_params.merge(query_params).transform_keys(&:to_sym)
        instance.instance_exec(**acceptable(symbol_params), &@block)
      end

      # A route block declares the parameters it wants, and a query string is
      # written by whoever is calling us — npm asks for `/:package/?write=true`
      # during an unpublish, Bundler appends its own. Passing every query
      # parameter through as a keyword means any such caller can crash a route
      # with ArgumentError, so the block is only given what it said it takes.
      def acceptable(params)
        parameters = @block.parameters
        return params if parameters.any? { |type, _| type == :keyrest }

        accepted = parameters.filter_map { |type, name| name if type == :key || type == :keyreq }
        params.slice(*accepted)
      end
    end

    class RouteBuilder
      def initialize(routes)
        @routes = routes
      end

      def get(pattern, &block)
        @routes << Route.new("GET", pattern, block)
      end

      def post(pattern, &block)
        @routes << Route.new("POST", pattern, block)
      end

      def put(pattern, &block)
        @routes << Route.new("PUT", pattern, block)
      end

      def delete(pattern, &block)
        @routes << Route.new("DELETE", pattern, block)
      end

      def patch(pattern, &block)
        @routes << Route.new("PATCH", pattern, block)
      end
    end

    def self.draw(&block)
      routes = []
      builder = RouteBuilder.new(routes)
      block.call(builder)
      new(routes)
    end

    def initialize(routes)
      @routes = routes
    end

    def match(request)
      @routes.find { |route| route.match?(request) }
    end

    def perform_action(route, instance, request)
      route.perform_action(instance, request)
    end
  end
end
