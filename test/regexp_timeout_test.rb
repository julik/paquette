require_relative "test_helper"

class RegexpTimeoutTest < Minitest::Test
  include Rack::Test::Methods

  # The backreference is what makes it exponential: 3.2 memoizes most nested
  # quantifiers into linear time but gives up on this shape.
  CATASTROPHIC = /\A([a-z]+)+\1\z/
  CATASTROPHIC_INPUT = ("a" * 40) + "!"

  attr_reader :app

  def build(inner, seconds: 0.05)
    @app = Paquette::RegexpTimeout.new(inner, seconds: seconds)
  end

  def test_installs_the_timeout_for_the_duration_of_the_call
    observed = :unset
    build(->(_env) {
      observed = Regexp.timeout
      [200, {"Content-Type" => "text/plain"}, ["ok"]]
    })

    get "/"

    assert_equal 200, last_response.status
    assert_in_delta 0.05, observed, 0.0001
  end

  def test_restores_the_previous_value_when_the_body_is_closed
    build(->(_env) { [200, {"Content-Type" => "text/plain"}, ["ok"]] })

    status, _headers, body = app.call(Rack::MockRequest.env_for("/"))

    assert_equal 200, status
    assert_in_delta 0.05, Regexp.timeout, 0.0001, "the ceiling must outlive #call, for streamed bodies"

    body.close
    assert_nil Regexp.timeout
  end

  def test_restores_the_previous_value_when_the_app_raises
    build(->(_env) { raise ArgumentError, "boom" })

    assert_raises(ArgumentError) { app.call(Rack::MockRequest.env_for("/")) }
    assert_nil Regexp.timeout
  end

  # Set-and-restore would have one request's exit lower the ceiling while
  # another is still inside a match.
  def test_an_overlapping_request_keeps_the_ceiling
    build(->(_env) { [200, {}, ["ok"]] })

    _, _, first = app.call(Rack::MockRequest.env_for("/one"))
    _, _, second = app.call(Rack::MockRequest.env_for("/two"))

    first.close
    assert_in_delta 0.05, Regexp.timeout, 0.0001

    second.close
    assert_nil Regexp.timeout
  end

  def test_a_runaway_match_becomes_a_bad_request
    build(->(_env) {
      CATASTROPHIC.match?(CATASTROPHIC_INPUT)
      [200, {}, ["never reached"]]
    })

    get "/"

    assert_equal 400, last_response.status
    assert_includes last_response.body, "too long"
    assert_nil Regexp.timeout, "a timed-out request still gives the ceiling back"
  end

  def test_leaves_an_ambient_timeout_of_its_own_alone
    Regexp.timeout = 3.0
    build(->(_env) { [200, {}, ["ok"]] })

    _, _, body = app.call(Rack::MockRequest.env_for("/"))
    assert_in_delta 0.05, Regexp.timeout, 0.0001

    body.close
    assert_in_delta 3.0, Regexp.timeout, 0.0001
  ensure
    Regexp.timeout = nil
  end

  def teardown
    Regexp.timeout = nil
  end
end
