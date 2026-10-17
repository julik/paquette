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

  def test_extracts_a_bare_token_sent_without_a_scheme_the_way_gem_push_sends_it
    env = env_for("/")
    env["HTTP_AUTHORIZATION"] = VALID_TOKEN
    status, _, body = @app.call(env)
    assert_equal 200, status
    assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
  end

  def test_rejects_a_bare_token_the_authenticator_does_not_know
    env = env_for("/")
    env["HTTP_AUTHORIZATION"] = "rubygems_not_ours"
    status, _, _ = @app.call(env)
    assert_equal 401, status
  end

  def test_rejects_a_blank_authorization_header
    env = env_for("/")
    env["HTTP_AUTHORIZATION"] = ""
    status, _, _ = @app.call(env)
    assert_equal 401, status
  end

  def test_extracts_token_from_basic_auth_with_x_oauth_basic_password
    status, _, body = @app.call(env_for("/", basic: [VALID_TOKEN, "x-oauth-basic"]))
    assert_equal 200, status
    assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
  end

  def test_extracts_token_from_basic_auth_whatever_the_password
    status, _, body = @app.call(env_for("/", basic: [VALID_TOKEN, "anything at all"]))
    assert_equal 200, status
    assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
  end

  def test_extracts_token_from_basic_auth_password_with_a_sentinel_username
    %w[x-oauth-basic x-access-token x-oauth-token].each do |username|
      status, _, body = @app.call(env_for("/", basic: [username, VALID_TOKEN]))
      assert_equal 200, status, username
      assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
    end
  end

  def test_extracts_token_from_basic_auth_password_with_an_empty_username
    status, _, body = @app.call(env_for("/", basic: ["", VALID_TOKEN]))
    assert_equal 200, status
    assert_equal VALID_TOKEN, JSON.parse(body_string(body))["token"]
  end

  def test_does_not_take_the_password_when_the_username_is_not_a_sentinel
    request = Paquette::TokenAuthorization::Request.new(env_for("/", basic: ["someone", VALID_TOKEN]))
    assert_equal "someone", request.token
  end

  def test_rejects_basic_auth_with_a_sentinel_username_and_no_password
    status, _, _ = @app.call(env_for("/", basic: ["x-oauth-basic", ""]))
    assert_equal 401, status
    assert_nil Paquette::TokenAuthorization::Request.new(env_for("/", basic: ["x-oauth-basic", ""])).token
  end

  def test_rejects_basic_auth_with_both_halves_empty
    status, _, _ = @app.call(env_for("/", basic: ["", ""]))
    assert_equal 401, status
  end

  def test_rejects_a_wrong_token_with_x_oauth_basic_password
    status, _, _ = @app.call(env_for("/", basic: ["ghp_not_ours", "x-oauth-basic"]))
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
