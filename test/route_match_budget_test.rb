require_relative "test_helper"
require "mustermann/regular"

class RouteMatchBudgetTest < Minitest::Test
  # Routes#match asks a route only for #match?, and a deterministic stall makes
  # a far steadier budget test than a regexp tuned to be slow on one machine.
  class SlowRoute
    attr_reader :metric_name

    def initialize(seconds)
      @seconds = seconds
      @metric_name = "GET /slow"
    end

    def match?(_request)
      sleep(@seconds)
      false
    end
  end

  # Non-linear because of the backreference: 3.2 memoizes most nested
  # quantifiers into linear time but gives up on this shape.
  CATASTROPHIC = Mustermann::Regular.new("/([a-z]+)+\\1")
  CATASTROPHIC_PATH = "/" + ("a" * 40) + "!"

  def teardown
    Regexp.timeout = nil
  end

  def test_a_table_of_slow_routes_costs_the_budget_rather_than_the_table
    routes = Paquette::Routes.new([SlowRoute.new(0.02)] * 20, match_budget: 0.1)

    ran_for = elapsed do
      assert_raises(Paquette::Routes::MatchBudgetExceeded) { routes.match(request_for("/anything")) }
    end

    # Twenty at 0.02s is 0.4s unbudgeted. With a budget it is the budget plus
    # however long the candidate that blew it was already running.
    assert_operator ran_for, :<, 0.25, "route matching ran for #{ran_for}s"
  end

  # The bound has to stay put as the table grows, which is the whole reason it
  # is not simply a smaller Regexp.timeout.
  def test_the_bound_does_not_grow_with_the_route_table
    short = elapsed { budget_blown_by(10) }
    long = elapsed { budget_blown_by(80) }

    assert_operator (long - short).abs, :<, 0.1, "10 routes took #{short}s, 80 took #{long}s"
  end

  def test_the_budget_is_not_spent_on_routes_the_method_rules_out
    routes = Paquette::Routes.draw(match_budget: 0.1) do |r|
      50.times { r.post("/never/:x") { [200, {}, ["no"]] } }
      r.get("/reachable") { [200, {}, ["yes"]] }
    end

    assert_equal "GET /reachable", routes.match(request_for("/reachable")).metric_name
  end

  def test_an_ordinary_request_never_notices_the_budget
    routes = Paquette::Routes.draw(match_budget: 0.1) do |r|
      r.get("/gems/:gem_filename") { [200, {}, ["ok"]] }
    end

    1000.times { assert routes.match(request_for("/gems/zip_kit-6.2.0.gem")) }
  end

  def test_both_routing_faults_are_the_same_kind_of_400
    assert_operator Paquette::Routes::MatchBudgetExceeded, :<, Paquette::Routes::BadRequest
    assert_operator Paquette::Routes::MalformedRequest, :<, Paquette::Routes::BadRequest
  end

  # A genuinely catastrophic pattern trips the per-match ceiling before the
  # budget is ever consulted — which is the division of labour: the ceiling
  # stops one runaway match, the budget stops a table of merely slow ones.
  def test_a_catastrophic_route_pattern_is_a_400_rather_than_a_hang
    routes = Paquette::Routes.draw(match_budget: 0.1) do |r|
      12.times { r.get(CATASTROPHIC) { [200, {}, ["never"]] } }
    end

    session = Rack::Test::Session.new(dispatcher_for(routes))
    ran_for = elapsed { session.get(CATASTROPHIC_PATH) }

    assert_equal 400, session.last_response.status
    assert_operator ran_for, :<, 0.5, "the request ran for #{ran_for}s"
  end

  private

  def budget_blown_by(count)
    routes = Paquette::Routes.new([SlowRoute.new(0.02)] * count, match_budget: 0.1)
    assert_raises(Paquette::Routes::MatchBudgetExceeded) { routes.match(request_for("/anything")) }
  end

  # The dispatch both servers do, with nothing else in the way.
  def dispatcher_for(routes)
    Class.new do
      prepend Paquette::RegexpTimeout

      define_method(:initialize) { |table| @routes = table }

      def call(env)
        @routes.match(Rack::Request.new(env)) ? [200, {}, ["ok"]] : [404, {}, ["Not Found"]]
      rescue Paquette::Routes::BadRequest => e
        [400, {"Content-Type" => "text/plain"}, [e.message]]
      end
    end.new(routes)
  end

  def request_for(path)
    Rack::Request.new(Rack::MockRequest.env_for(path))
  end
end
