require_relative "test_helper"

class AuthTokenTest < Minitest::Test
  TOKEN = "pqt_test_token_for_auth_checks_abc123z"

  def test_reads_a_bearer_token
    assert_equal TOKEN, token_for("Bearer #{TOKEN}")
  end

  def test_reads_the_bare_key_gem_push_sends
    assert_equal TOKEN, token_for(TOKEN)
  end

  # What Bundler sends for `https://TOKEN:x-oauth-basic@host`
  def test_reads_the_basic_username_whatever_the_password
    ["", "x-oauth-basic", "x-oauth-token", "anything at all"].each do |password|
      assert_equal TOKEN, token_for(basic(TOKEN, password)), password
    end
  end

  def test_reads_a_basic_username_with_no_colon_at_all
    assert_equal TOKEN, token_for("Basic #{[TOKEN].pack("m0")}")
  end

  def test_reads_the_basic_password_behind_a_placeholder_username
    ["", "x-oauth-basic", "x-access-token", "x-oauth-token"].each do |username|
      assert_equal TOKEN, token_for(basic(username, TOKEN)), username
    end
  end

  # The password is only looked at behind a placeholder username
  def test_a_real_username_wins_over_a_token_shaped_password
    assert_equal "someone", token_for(basic("someone", TOKEN))
  end

  def test_nil_without_a_header
    assert_nil Paquette::AuthToken.from_env(Rack::MockRequest.env_for("/"))
    refute Paquette::AuthToken.provided?(Rack::MockRequest.env_for("/"))
  end

  # A client with nothing to send, not a bare key that reads "Bearer"
  def test_nil_for_a_lone_scheme_name
    ["Bearer", "bearer", "Basic", "Bearer ", "Basic "].each do |header|
      assert_nil token_for(header), header.inspect
    end
  end

  # Some proxies send one for nothing, so it is anonymous rather than mangled
  def test_a_blank_header_is_no_credentials
    ["", "   "].each do |header|
      assert_nil token_for(header)
      refute Paquette::AuthToken.provided?(env_with(header)), header.inspect
    end
  end

  def test_nil_for_a_placeholder_username_with_no_password
    assert_nil token_for(basic("x-oauth-basic", ""))
    assert_nil token_for(basic("", ""))
  end

  def test_nil_for_a_scheme_it_does_not_speak
    assert_nil token_for(%(Digest username="x"))
  end

  def test_survives_a_basic_payload_that_is_not_utf8
    assert_equal "\xFF\xE2".b, token_for("Basic #{["\xFF\xE2:".b].pack("m0")}")
  end

  # Refused as unreadable rather than raised out of `downcase`
  def test_nil_for_a_header_that_is_not_utf8
    assert_nil token_for((+"\xFF\xE2 abc").force_encoding("UTF-8"))
    assert_nil token_for((+"\xFF").force_encoding("UTF-8"))
  end

  # A Bearer token is passed on as sent, whatever its bytes
  def test_passes_a_bearer_token_that_is_not_utf8_on_as_it_is
    assert_equal "\xE2".b, token_for("Bearer \xE2".b)&.b
  end

  private

  def basic(username, password)
    "Basic #{["#{username}:#{password}"].pack("m0")}"
  end

  def env_with(header)
    Rack::MockRequest.env_for("/", "HTTP_AUTHORIZATION" => header)
  end

  def token_for(header)
    Paquette::AuthToken.from_env(env_with(header))
  end
end
