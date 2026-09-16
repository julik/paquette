require "mustermann"
require "measurometer"

module Paquette
  class Routes
    # A request whose own bytes Rack could not parse — not a routing failure
    # and not a server fault, so it is raised here and turned into a 400 by
    # whichever server is dispatching. See Route#query_params.
    class MalformedRequest < StandardError; end

    class Route
      attr_reader :method, :pattern, :block

      # The pattern as written, not as matched: it is the one name for this
      # route that stays the same across every request, which is exactly what a
      # metric path needs. Interpolating the matched path instead would open a
      # new metric per gem name in the corpus.
      attr_reader :metric_name

      def initialize(method, pattern, block)
        @method = method
        @pattern = Mustermann.new(pattern)
        @block = block
        @metric_name = "#{method} #{pattern}"
      end

      def match?(request)
        @method == request.request_method && @pattern.match(request.path_info)
      end

      def params(request)
        @pattern.params(request.path_info)
      end

      def perform_action(instance, request)
        Measurometer.instrument("paquette.route.#{@metric_name}") { call_block(instance, request) }
      end

      def call_block(instance, request)
        route_params = params(request)
        query_params = query_params(request)
        symbol_params = route_params.merge(query_params).transform_keys(&:to_sym)
        instance.instance_exec(**acceptable(symbol_params), &@block)
      end

      # Rack parses the query string *and* the body to answer #params, and a
      # request whose body does not match its Content-Type makes it raise —
      # scanners hitting "/" with a multipart Content-Type and no body do this
      # routinely, and it used to surface as a 500 for what is squarely the
      # client's fault.
      #
      # Rack::BadRequest is the marker module Rack mixes into the errors it
      # raises for exactly this. The bare EOFError is caught alongside it
      # because the multipart parser raises one, untagged, when a body is
      # shorter than the Content-Length that announced it — the same fault,
      # only it arrives as a truncated upload rather than an absent one.
      def query_params(request)
        request.params
      rescue Rack::BadRequest, EOFError => e
        raise MalformedRequest, "Could not parse request parameters: #{e.class}"
      end

      # The block only gets the keywords it declares: a client's stray query
      # parameter (npm sends ?write=true) must not crash it with ArgumentError.
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
      Measurometer.instrument("paquette.routes.match") do
        @routes.find { |route| route.match?(request) }
      end
    end

    def perform_action(route, instance, request)
      route.perform_action(instance, request)
    end
  end
end
