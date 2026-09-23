require "mustermann"
require "measurometer"

class Paquette::Routes
  # Raised when the fault is in the request's own bytes rather than in
  # anything it asked for; whichever server is dispatching turns it into a
  # 400.
  class BadRequest < StandardError; end

  # Rack could not parse the request. See Route#query_params.
  class MalformedRequest < BadRequest; end

  # Route matching ran past its budget. See Routes#match.
  class MatchBudgetExceeded < BadRequest; end

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

    # Mustermann unescapes %xx, so a segment can arrive as bytes that are not
    # valid UTF-8 — and then every regexp a handler runs on it raises
    # ArgumentError instead of failing to match. No gem or package is named
    # in invalid UTF-8, so it is refused at the door.
    def params(request)
      @pattern.params(request.path_info).each_value do |value|
        Array(value).each do |segment|
          raise MalformedRequest, "Path segment is not valid UTF-8" unless segment.to_s.valid_encoding?
        end
      end
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

  # Regexp.timeout bounds one match. Nothing bounds a table of them, and the
  # bound it does give grows every time a route is added. Between candidates
  # is the only place the router gets control back, so that is where the
  # clock is checked: total matching costs the budget plus at most one
  # timeout, whatever the table grows to.
  DEFAULT_MATCH_BUDGET = 0.1

  def self.draw(match_budget: DEFAULT_MATCH_BUDGET, &block)
    routes = []
    builder = RouteBuilder.new(routes)
    block.call(builder)
    new(routes, match_budget: match_budget)
  end

  # For the linear_time? test; the request path does not need it.
  attr_reader :routes

  def initialize(routes, match_budget: DEFAULT_MATCH_BUDGET)
    @routes = routes
    @match_budget = match_budget
  end

  def match(request)
    Measurometer.instrument("paquette.routes.match") do
      deadline = now + @match_budget

      @routes.find do |route|
        raise MatchBudgetExceeded, "Route matching took longer than #{@match_budget}s" if now > deadline
        route.match?(request)
      end
    end
  end

  def perform_action(route, instance, request)
    route.perform_action(instance, request)
  end

  # What a request would dispatch to, named. `name` is the route's
  # metric_name — the pattern as written, one stable string per route — and
  # `params` is what the pattern extracted from the path, symbol-keyed.
  Recognition = Data.define(:name, :params)

  # Recognize without performing, for callers that must name a request
  # before handling it — an instrumentation action, a log field — and may
  # not touch the body doing so: only the path is read, never the query
  # parser that reaches into the input. Returns nil for a request no route
  # wants. A matched path whose segments fail the UTF-8 check still gets its
  # name, with empty params — the name is knowable, the values are garbage.
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

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
