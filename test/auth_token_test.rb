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

  # pip and twine, against any index that follows pypi.org
  def test_reads_the_password_behind_the_pypi_token_username
    assert_equal TOKEN, token_for(basic("__token__", TOKEN))
  end

  # twine has nowhere else to put a one-time password
  def test_a_code_shaped_username_gives_way_to_the_password
    ["123456", "1234567", "12345678"].each do |code|
      assert_equal TOKEN, token_for(basic(code, TOKEN)), code
      assert_equal code, otp_for(basic(code, TOKEN)), code
    end
  end

  # A token that is all digits is still a token the GitHub way round
  def test_a_numeric_token_with_a_placeholder_or_no_password_stays_the_token
    ["", "x-oauth-basic", "__token__"].each do |password|
      assert_equal "123456", token_for(basic("123456", password)), password
      assert_nil otp_for(basic("123456", password)), password
    end
    assert_equal "123456", token_for("Basic #{["123456"].pack("m0")}")
  end

  def test_a_username_that_is_not_quite_a_code_is_the_token
    ["12345", "123456789", "12345a", "123 456", "123456\n"].each do |username|
      assert_equal username, token_for(basic(username, TOKEN)), username.inspect
      assert_nil otp_for(basic(username, TOKEN)), username.inspect
    end
  end

  def test_no_code_out_of_anything_but_basic
    assert_nil otp_for("Bearer 123456")
    assert_nil otp_for("123456")
    assert_nil Paquette::AuthToken.otp_from_env(Rack::MockRequest.env_for("/"))
  end

  def test_a_code_out_of_a_basic_payload_that_is_not_utf8_is_nil_or_bytes
    otp = otp_for("Basic #{["\xFF\xFE:#{TOKEN}".b].pack("m0")}")

    assert_nil otp
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

  def test_nil_for_a_basic_payload_that_is_not_utf8
    assert_nil token_for("Basic #{["\xFF\xE2:".b].pack("m0")}")
    assert_nil token_for("Basic #{[":\xE2".b].pack("m0")}")
  end

  # Refused as unreadable rather than raised out of `downcase`
  def test_nil_for_a_header_that_is_not_utf8
    assert_nil token_for((+"\xFF\xE2 abc").force_encoding("UTF-8"))
    assert_nil token_for((+"\xFF").force_encoding("UTF-8"))
  end

  # What Puma hands over: binary, which is fine as long as it is UTF-8 inside
  def test_a_binary_header_holding_utf8_gives_a_utf8_token
    token = token_for("Bearer #{TOKEN}".b)

    assert_equal TOKEN, token
    assert_equal Encoding::UTF_8, token.encoding
  end

  def test_nil_for_a_bearer_or_bare_token_that_is_not_utf8
    assert_nil token_for("Bearer \xE2".b)
    assert_nil token_for("Bearer pqt_\xFFabc".b)
    assert_nil token_for("pqt_\xFF".b)
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

  def otp_for(header)
    Paquette::AuthToken.otp_from_env(env_with(header))
  end
end
