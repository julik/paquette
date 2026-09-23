require_relative "test_helper"

class RegexpTimeoutTest < Minitest::Test
  include Rack::Test::Methods

  # The backreference is what makes it exponential: 3.2 memoizes most nested
  # quantifiers into linear time but gives up on this shape.
  CATASTROPHIC = /\A([a-z]+)+\1\z/
  CATASTROPHIC_INPUT = ("a" * 40) + "!"

  # What every app in the gem does at its class body, standing in for all of
  # them: the module is prepended, so #call here is the inner app.
  class App
    prepend Paquette::RegexpTimeout

    def initialize(&inner)
      @inner = inner
    end

    def call(env) = @inner.call(env)
  end

  attr_reader :app

  def build(&inner)
    @app = App.new(&inner)
  end

  def test_installs_the_timeout_for_the_duration_of_the_call
    observed = :unset
    build { |_env|
      observed = Regexp.timeout
      [200, {"Content-Type" => "text/plain"}, ["ok"]]
    }

    get "/"

    assert_equal 200, last_response.status
    assert_in_delta 0.05, observed, 0.0001
  end

  def test_restores_the_previous_value_when_the_body_is_closed
    build { |_env| [200, {"Content-Type" => "text/plain"}, ["ok"]] }

    status, _headers, body = app.call(Rack::MockRequest.env_for("/"))

    assert_equal 200, status
    assert_in_delta 0.05, Regexp.timeout, 0.0001, "the ceiling must outlive #call, for streamed bodies"

    body.close
    assert_nil Regexp.timeout
  end

  def test_restores_the_previous_value_when_the_app_raises
    build { |_env| raise ArgumentError, "boom" }

    assert_raises(ArgumentError) { app.call(Rack::MockRequest.env_for("/")) }
    assert_nil Regexp.timeout
  end

  # Set-and-restore would have one request's exit lower the ceiling while
  # another is still inside a match.
  def test_an_overlapping_request_keeps_the_ceiling
    build { |_env| [200, {}, ["ok"]] }

    _, _, first = app.call(Rack::MockRequest.env_for("/one"))
    _, _, second = app.call(Rack::MockRequest.env_for("/two"))

    first.close
    assert_in_delta 0.05, Regexp.timeout, 0.0001

    second.close
    assert_nil Regexp.timeout
  end

  # One app calling another — a subdomain router in front of a gem server —
  # arms it twice, and the outer exit is what puts the ceiling back.
  def test_nested_apps_share_one_ceiling
    inner = App.new { |_env| [200, {}, ["ok"]] }
    outer = App.new { |env| inner.call(env) }

    _, _, body = outer.call(Rack::MockRequest.env_for("/"))
    assert_in_delta 0.05, Regexp.timeout, 0.0001

    body.close
    assert_nil Regexp.timeout
  end

  # A body nobody closes leaks a request, and the count then says the ceiling
  # is already up. Arming has to look at Regexp.timeout rather than at the
  # count, or one leak disarms every request after it.
  def test_rearms_after_a_leaked_request_and_a_cleared_timeout
    build { |_env| [200, {}, ["ok"]] }
    app.call(Rack::MockRequest.env_for("/leaked"))
    Regexp.timeout = nil

    observed = :unset
    build { |_env|
      observed = Regexp.timeout
      [200, {}, ["ok"]]
    }
    _, _, body = app.call(Rack::MockRequest.env_for("/"))

    assert_in_delta 0.05, observed, 0.0001
    body.close
  end

  def test_a_runaway_match_becomes_a_bad_request
    build { |_env|
      CATASTROPHIC.match?(CATASTROPHIC_INPUT)
      [200, {}, ["never reached"]]
    }

    get "/"

    assert_equal 400, last_response.status
    assert_includes last_response.body, "too long"
    assert_nil Regexp.timeout, "a timed-out request still gives the ceiling back"
  end

  def test_leaves_an_ambient_timeout_of_its_own_alone
    Regexp.timeout = 3.0
    build { |_env| [200, {}, ["ok"]] }

    _, _, body = app.call(Rack::MockRequest.env_for("/"))
    assert_in_delta 0.05, Regexp.timeout, 0.0001

    body.close
    assert_in_delta 3.0, Regexp.timeout, 0.0001
  ensure
    Regexp.timeout = nil
  end

  def test_honours_a_ceiling_the_application_configured
    Paquette.regexp_timeout = 0.2
    observed = :unset
    build { |_env|
      observed = Regexp.timeout
      [200, {}, ["ok"]]
    }

    get "/"

    assert_in_delta 0.2, observed, 0.0001
  ensure
    Paquette.regexp_timeout = Paquette::RegexpTimeout::DEFAULT_TIMEOUT
  end

  # The count is process-wide by design, so a test that leaks a request would
  # otherwise leak it into the next one.
  def teardown
    Paquette::RegexpTimeout.instance_variable_set(:@in_flight, 0)
    Paquette::RegexpTimeout.instance_variable_set(:@ambient, nil)
    Regexp.timeout = nil
  end
end
