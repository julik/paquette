require "test_helper"

class TokenAuthorizationTest < Minitest::Test
  VALID_TOKEN = "pqt_test_token_for_auth_checks_abc123z"
  IDENTITY = {name: "test-team", id: 42}

  def setup
    @inner_app = ->(env) {
      body = JSON.dump(token: env["paquette.access_token"], identity: env["paquette.identity"])
      [200, {"content-type" => "application/json"}, [body]]
    }
    @app = Paquette::TokenAuthorization.new(@inner_app, "Paquette") { |token|
      token.start_with?("pqt_") ? IDENTITY : nil
    }
  end

  def test_returns_401_without_any_authorization_header
    status, _, _ = @app.call(env_for("/"))
    assert_equal 401, status
  end

  def test_returns_401_for_invalid_token_format
    status, _, _ = @app.call(env_for("/", bearer: "not_a_valid_token"))
    assert_equal 401, status
  end

  def test_extracts_token_from_bearer_header
    status, _, body = @app.call(env_for("/", bearer: VALID_TOKEN))
    assert_equal 200, status
    parsed = JSON.parse(body_string(body))
    assert_equal VALID_TOKEN, parsed["token"]
  end

  def test_extracts_token_from_basic_auth_with_empty_password
    status, _, body = @app.call(env_for("/", basic: [VALID_TOKEN, ""]))
    assert_equal 200, status
    parsed = JSON.parse(body_string(body))
    assert_equal VALID_TOKEN, parsed["token"]
  end

  def test_extracts_token_from_basic_auth_with_x_oauth_token_password
    status, _, body = @app.call(env_for("/", basic: [VALID_TOKEN, "x-oauth-token"]))
    assert_equal 200, status
    parsed = JSON.parse(body_string(body))
    assert_equal VALID_TOKEN, parsed["token"]
  end

  def test_rejects_basic_auth_with_wrong_password
    status, _, _ = @app.call(env_for("/", basic: [VALID_TOKEN, "wrong_password"]))
    assert_equal 401, status
  end

  def test_rejects_basic_auth_with_invalid_token_as_username
    status, _, _ = @app.call(env_for("/", basic: ["bad-token!", ""]))
    assert_equal 401, status
  end

  def test_sets_identity_and_token_in_env
    _, _, body = @app.call(env_for("/", bearer: VALID_TOKEN))
    parsed = JSON.parse(body_string(body))
    assert_equal VALID_TOKEN, parsed["token"]
    assert_equal({"name" => "test-team", "id" => 42}, parsed["identity"])
  end

  def test_returns_www_authenticate_bearer_challenge_on_401
    _, headers, _ = @app.call(env_for("/"))
    assert_equal 'Bearer realm="Paquette"', headers["www-authenticate"]
  end

  def test_token_in_reads_a_bearer_token
    assert_equal VALID_TOKEN, Paquette::TokenAuthorization.token_in(env_for("/", bearer: VALID_TOKEN))
  end

  # What Bundler sends for `https://TOKEN:x-oauth-basic@host` — the case the
  # hand-rolled `get_header("HTTP_AUTHORIZATION")` in our own docs got wrong.
  def test_token_in_reads_a_token_out_of_basic_auth
    assert_equal VALID_TOKEN, Paquette::TokenAuthorization.token_in(env_for("/", basic: [VALID_TOKEN, ""]))
    assert_equal VALID_TOKEN, Paquette::TokenAuthorization.token_in(env_for("/", basic: [VALID_TOKEN, "x-oauth-token"]))
  end

  def test_token_in_is_nil_without_credentials
    assert_nil Paquette::TokenAuthorization.token_in(env_for("/"))
  end

  def test_token_in_is_nil_for_a_basic_login_with_a_real_password
    assert_nil Paquette::TokenAuthorization.token_in(env_for("/", basic: [VALID_TOKEN, "hunter2"]))
  end

  def test_token_in_is_nil_for_a_scheme_it_does_not_speak
    env = env_for("/")
    env["HTTP_AUTHORIZATION"] = "Digest username=\"x\""
    assert_nil Paquette::TokenAuthorization.token_in(env)
  end

  def test_anonymous_lets_a_request_without_credentials_through_with_no_identity
    app = Paquette::TokenAuthorization.new(@inner_app, "Paquette", anonymous: true) { |token| IDENTITY }

    status, _, body = app.call(env_for("/"))
    assert_equal 200, status
    assert_equal({"token" => nil, "identity" => nil}, JSON.parse(body_string(body)))
  end

  def test_anonymous_still_resolves_a_token_that_is_there
    app = Paquette::TokenAuthorization.new(@inner_app, "Paquette", anonymous: true) { |token|
      token.start_with?("pqt_") ? IDENTITY : nil
    }

    status, _, body = app.call(env_for("/", bearer: VALID_TOKEN))
    assert_equal 200, status
    assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
  end

  # A typo in a token must not quietly become an anonymous session.
  def test_anonymous_still_refuses_credentials_that_do_not_resolve
    app = Paquette::TokenAuthorization.new(@inner_app, "Paquette", anonymous: true) { |token|
      token.start_with?("pqt_") ? IDENTITY : nil
    }

    assert_equal 401, app.call(env_for("/", bearer: "not_a_valid_token")).first
    assert_equal 401, app.call(env_for("/", basic: [VALID_TOKEN, "wrong_password"])).first
  end

  def test_anonymous_works_through_rack_builder_use
    identity = IDENTITY
    inner = @inner_app
    app = Rack::Builder.new do
      use Paquette::TokenAuthorization, "Paquette", anonymous: true do |_token|
        identity
      end
      run inner
    end.to_app

    assert_equal 200, app.call(env_for("/")).first
  end

  private

  def env_for(path, bearer: nil, basic: nil)
    env = Rack::MockRequest.env_for(path)
    if bearer
      env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    elsif basic
      encoded = ["#{basic[0]}:#{basic[1]}"].pack("m0")
      env["HTTP_AUTHORIZATION"] = "Basic #{encoded}"
    end
    env
  end

  def body_string(body)
    str = +""
    body.each { |part| str << part }
    str
  end
end
