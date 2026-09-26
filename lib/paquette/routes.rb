require "mustermann"
require "measurometer"

# A small method-and-pattern route table with a per-request matching budget.
# Both servers dispatch through one of these.
class Paquette::Routes
  # Raised when the fault is in the request's own bytes rather than in
  # anything it asked for; whichever server is dispatching turns it into a
  # 400.
  class BadRequest < StandardError; end

  # Rack could not parse the request. See Route#query_params.
  class MalformedRequest < BadRequest; end

  # Route matching ran past its budget. See Routes#match.
  class MatchBudgetExceeded < BadRequest; end

  # One route: an HTTP method, a Mustermann pattern and a handler block.
  class Route
    # @return [String]
    attr_reader :method

    # @return [Mustermann::Pattern]
    attr_reader :pattern

    # @return [Proc]
    attr_reader :block

    # The pattern as written, not as matched — interpolating the matched
    # path would open a new metric per gem name in the corpus.
    #
    # @return [String]
    attr_reader :metric_name

    # @param method [String] the HTTP method, uppercase
    # @param pattern [String] a Mustermann pattern string
    # @param block [Proc] the handler
    def initialize(method, pattern, block)
      @method = method
      @pattern = Mustermann.new(pattern)
      @block = block
      @metric_name = "#{method} #{pattern}"
    end

    # @param request [Rack::Request]
    # @return [Boolean]
    def match?(request)
      @method == request.request_method && @pattern.match(path_of(request))
    end

    # Rack::Builder#map hands the mount point itself over with an empty
    # PATH_INFO — which is not a path, it is the root of the mount, where
    # the index page lives.
    #
    # @param request [Rack::Request]
    # @return [String]
    def path_of(request)
      path = request.path_info
      path.empty? ? "/" : path
    end

    # Mustermann unescapes %xx, so a segment can arrive as invalid UTF-8 —
    # on which every regexp a handler runs raises instead of failing to
    # match. Refused at the door.
    #
    # @param request [Rack::Request]
    # @return [Hash{String => Object}] the pattern's captures
    # @raise [MalformedRequest]
    def params(request)
      @pattern.params(path_of(request)).each_value do |value|
        Array(value).each do |segment|
          raise MalformedRequest, "Path segment is not valid UTF-8" unless segment.to_s.valid_encoding?
        end
      end
    end

    # @param instance [Object] the server instance the block runs against
    # @param request [Rack::Request]
    # @return [Array] a Rack response triplet
    def perform_action(instance, request)
      Measurometer.instrument("paquette.route.#{@metric_name}") { call_block(instance, request) }
    end

    # @param instance [Object]
    # @param request [Rack::Request]
    # @return [Array] a Rack response triplet
    def call_block(instance, request)
      route_params = params(request)
      query_params = query_params(request)
      symbol_params = route_params.merge(query_params).transform_keys(&:to_sym)
      instance.instance_exec(**acceptable(symbol_params), &@block)
    end

    # Rack parses the query string *and* the body to answer #params, and a
    # body that does not match its Content-Type makes it raise — the
    # client's fault, not a 500. The bare EOFError is the multipart
    # parser's, untagged, for a body shorter than its Content-Length.
    #
    # @param request [Rack::Request]
    # @return [Hash{String => Object}]
    # @raise [MalformedRequest]
    def query_params(request)
      request.params
    rescue Rack::BadRequest, EOFError => e
      raise MalformedRequest, "Could not parse request parameters: #{e.class}"
    end

    # The block only gets the keywords it declares: a client's stray query
    # parameter (npm sends ?write=true) must not crash it with ArgumentError.
    #
    # @param params [Hash{Symbol => Object}]
    # @return [Hash{Symbol => Object}]
    def acceptable(params)
      parameters = @block.parameters
      return params if parameters.any? { |type, _| type == :keyrest }

      accepted = parameters.filter_map { |type, name| name if type == :key || type == :keyreq }
      params.slice(*accepted)
    end
  end

  # The DSL object yielded by {Routes.draw}.
  class RouteBuilder
    # @param routes [Array<Route>]
    def initialize(routes)
      @routes = routes
    end

    # @param pattern [String]
    # @return [void]
    def get(pattern, &block)
      @routes << Route.new("GET", pattern, block)
    end

    # @param pattern [String]
    # @return [void]
    def post(pattern, &block)
      @routes << Route.new("POST", pattern, block)
    end

    # @param pattern [String]
    # @return [void]
    def put(pattern, &block)
      @routes << Route.new("PUT", pattern, block)
    end

    # @param pattern [String]
    # @return [void]
    def delete(pattern, &block)
      @routes << Route.new("DELETE", pattern, block)
    end

    # @param pattern [String]
    # @return [void]
    def patch(pattern, &block)
      @routes << Route.new("PATCH", pattern, block)
    end
  end

  # Regexp.timeout bounds one match; nothing bounds a table of them, so
  # the clock is checked between candidates.
  DEFAULT_MATCH_BUDGET = 0.1

  # @param match_budget [Float] seconds allowed for matching the whole table
  # @yield [builder] the {RouteBuilder} to declare routes on
  # @return [Routes]
  def self.draw(match_budget: DEFAULT_MATCH_BUDGET, &block)
    routes = []
    builder = RouteBuilder.new(routes)
    block.call(builder)
    new(routes, match_budget: match_budget)
  end

  # For the linear_time? test; the request path does not need it.
  #
  # @return [Array<Route>]
  attr_reader :routes

  # @param routes [Array<Route>]
  # @param match_budget [Float]
  def initialize(routes, match_budget: DEFAULT_MATCH_BUDGET)
    @routes = routes
    @match_budget = match_budget
  end

  # @param request [Rack::Request]
  # @return [Route, nil]
  # @raise [MatchBudgetExceeded]
  def match(request)
    Measurometer.instrument("paquette.routes.match") do
      deadline = now + @match_budget

      @routes.find do |route|
        raise MatchBudgetExceeded, "Route matching took longer than #{@match_budget}s" if now > deadline
        route.match?(request)
      end
    end
  end

  # @param route [Route]
  # @param instance [Object]
  # @param request [Rack::Request]
  # @return [Array] a Rack response triplet
  def perform_action(route, instance, request)
    route.perform_action(instance, request)
  end

  # What a request would dispatch to, named. `name` is the route's
  # metric_name; `params` is what the pattern extracted, symbol-keyed.
  #
  # @!attribute name
  #   @return [String]
  # @!attribute params
  #   @return [Hash{Symbol => Object}]
  Recognition = Data.define(:name, :params)

  # Recognize without performing: only the path is read, never the query
  # parser. A matched path whose segments fail the UTF-8 check still gets
  # its name, with empty params.
  #
  # @param request [Rack::Request]
  # @return [Recognition, nil] nil for a request no route wants
  def recognize(request)
    route = match(request)
    return nil unless route

    params = begin
      route.params(request).transform_keys(&:to_sym)
    rescue BadRequest
      {}
    end
    Recognition.new(name: route.metric_name, params: params)
  end

  private

  # @return [Float]
  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
