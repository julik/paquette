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
    attr_reader :method #: String

    attr_reader :pattern #: ::Mustermann::Pattern

    attr_reader :block #: Proc

    # The pattern as written, not as matched — interpolating the matched
    # path would open a new metric per gem name in the corpus.
    attr_reader :metric_name #: String

    # - `method`: the HTTP method, uppercase
    # - `pattern`: a Mustermann pattern string
    # - `block`: the handler
    #
    #: (String method, String pattern, Proc block) -> void
    def initialize(method, pattern, block)
      @method = method
      @pattern = Mustermann.new(pattern)
      @block = block
      @metric_name = "#{method} #{pattern}"
    end

    # Anything that is not a read changes the corpus, and is what a server
    # asks a one-time password for.
    #
    #: () -> bool
    def write?
      @method != "GET" && @method != "HEAD"
    end

    #: (::Rack::Request request) -> boolish
    def match?(request)
      @method == request.request_method && @pattern.match(path_of(request))
    end

    # Rack::Builder#map hands the mount point itself over with an empty
    # PATH_INFO — which is not a path, it is the root of the mount, where
    # the index page lives.
    #
    #: (::Rack::Request request) -> String
    def path_of(request)
      path = request.path_info
      path.empty? ? "/" : path
    end

    # Mustermann unescapes %xx, so a segment can arrive as invalid UTF-8 —
    # on which every regexp a handler runs raises instead of failing to
    # match. Refused at the door.
    #
    # Returns the pattern's captures.
    # Raises `MalformedRequest`.
    #
    #: (::Rack::Request request) -> Hash[String, untyped]
    def params(request)
      params = @pattern.params(path_of(request)) #: Hash[String, untyped]
      params.each_value do |value|
        segments = Array(value) #: Array[untyped]
        segments.each do |segment|
          raise MalformedRequest, "Path segment is not valid UTF-8" unless segment.to_s.valid_encoding?
        end
      end
    end

    # - `server`: the server instance the block runs against
    #
    #: (untyped server, ::Rack::Request request) -> Paquette::rack_response
    def perform_action(server, request)
      Measurometer.instrument("paquette.route.#{@metric_name}") { call_block(server, request) }
    end

    #: (untyped server, ::Rack::Request request) -> Paquette::rack_response
    def call_block(server, request)
      route_params = params(request)
      query_params = query_params(request)
      symbol_params = route_params.merge(query_params).transform_keys(&:to_sym)
      server.instance_exec(**acceptable(symbol_params), &@block)
    end

    # Rack parses the query string *and* the body to answer #params, and a
    # body that does not match its Content-Type makes it raise — the
    # client's fault, not a 500. The bare EOFError is the multipart
    # parser's, untagged, for a body shorter than its Content-Length.
    #
    # Raises `MalformedRequest`.
    #
    #: (::Rack::Request request) -> Hash[String, untyped]
    def query_params(request)
      request.params
    rescue Rack::BadRequest, EOFError => e
      raise MalformedRequest, "Could not parse request parameters: #{e.class}"
    end

    # The block only gets the keywords it declares: a client's stray query
    # parameter (npm sends ?write=true) must not crash it with ArgumentError.
    #
    #: (Hash[Symbol, untyped] params) -> Hash[Symbol, untyped]
    def acceptable(params)
      parameters = @block.parameters
      return params if parameters.any? { |type, _| type == :keyrest }

      accepted = parameters.filter_map { |type, name| name if type == :key || type == :keyreq }
      params.slice(*accepted)
    end
  end

  # The DSL object yielded by Routes.draw. `S` is the server class whose
  # instances the handler blocks run on.
  #--
  # @rbs generic S
  class RouteBuilder
    #: (Array[Route] routes) -> void
    def initialize(routes)
      @routes = routes
    end

    #: (String pattern) { (**untyped) [self: S] -> untyped } -> void
    def get(pattern, &block)
      @routes << Route.new("GET", pattern, block)
    end

    #: (String pattern) { (**untyped) [self: S] -> untyped } -> void
    def post(pattern, &block)
      @routes << Route.new("POST", pattern, block)
    end

    #: (String pattern) { (**untyped) [self: S] -> untyped } -> void
    def put(pattern, &block)
      @routes << Route.new("PUT", pattern, block)
    end

    #: (String pattern) { (**untyped) [self: S] -> untyped } -> void
    def delete(pattern, &block)
      @routes << Route.new("DELETE", pattern, block)
    end

    #: (String pattern) { (**untyped) [self: S] -> untyped } -> void
    def patch(pattern, &block)
      @routes << Route.new("PATCH", pattern, block)
    end
  end

  # Regexp.timeout bounds one match; nothing bounds a table of them, so
  # the clock is checked between candidates.
  DEFAULT_MATCH_BUDGET = 0.1

  # - `match_budget`: seconds allowed for matching the whole table
  # - the block: the RouteBuilder to declare routes on; name the server
  #   class with `#$` so Steep checks the handlers against it
  #
  #: [S] (?match_budget: Float) { (RouteBuilder[S] builder) -> void } -> Paquette::Routes
  def self.draw(match_budget: DEFAULT_MATCH_BUDGET, &block)
    routes = []
    builder = RouteBuilder.new(routes)
    block.call(builder)
    new(routes, match_budget: match_budget)
  end

  # For the linear_time? test; the request path does not need it.
  attr_reader :routes #: Array[Route]

  #: (Array[Route] routes, ?match_budget: Float) -> void
  def initialize(routes, match_budget: DEFAULT_MATCH_BUDGET)
    @routes = routes
    @match_budget = match_budget
  end

  # Raises `MatchBudgetExceeded`.
  #
  #: (::Rack::Request request) -> Route?
  def match(request)
    Measurometer.instrument("paquette.routes.match") do
      deadline = now + @match_budget

      @routes.find do |route|
        raise MatchBudgetExceeded, "Route matching took longer than #{@match_budget}s" if now > deadline
        route.match?(request)
      end
    end
  end

  #: (Route route, untyped server, ::Rack::Request request) -> Paquette::rack_response
  def perform_action(route, server, request)
    route.perform_action(server, request)
  end

  # What a request would dispatch to, named. `name` is the route's
  # metric_name; `params` is what the pattern extracted, symbol-keyed.
  Recognition = Data.define(
    :name, #: String
    :params #: Hash[Symbol, untyped]
  )

  # Recognize without performing: only the path is read, never the query
  # parser. A matched path whose segments fail the UTF-8 check still gets
  # its name, with empty params.
  #
  # Returns nil for a request no route wants.
  #
  #: (::Rack::Request request) -> Recognition?
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

  #: () -> Float
  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
