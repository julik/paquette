require_relative "test_helper"
require "rotp"

# The protocol-neutral half of authentication: reading a token out of
# whichever scheme carried it, resolving it once per request, and verifying
# a one-time code. How each server refuses is tested beside that server.
class AuthenticationTest < Minitest::Test
  TOKEN = "pqt_test_token_for_auth_checks_abc123z"

  # Counts its calls, so that "resolved once" can be asserted.
  class CountingAuthenticator
    attr_reader :calls

    def initialize(&resolver)
      @resolver = resolver
      @calls = []
    end

    def identify(token)
      @calls << token
      @resolver.call(token)
    end

    def otp_secret(_identity) = nil
  end

  def setup
    @authenticator = CountingAuthenticator.new { |token| (token == TOKEN) ? :acme : nil }
  end

  def test_token_in_reads_a_bearer_token
    assert_equal TOKEN, Paquette::Authentication.token_in(env_for(bearer: TOKEN))
  end

  # What Bundler sends for `https://TOKEN:x-oauth-basic@host`. Reading the
  # raw Authorization header instead gets "Basic dG9r...", which is what
  # our own Rails guide used to do.
  def test_token_in_reads_a_token_riding_in_the_basic_username
    ["", "x-oauth-basic", "x-oauth-token"].each do |password|
      assert_equal TOKEN, Paquette::Authentication.token_in(env_for(basic: [TOKEN, password])), password
    end
  end

  # `gem push` and `gem yank` put the API key in the header as it is.
  def test_token_in_reads_the_bare_key_gem_push_sends
    env = env_for
    env["HTTP_AUTHORIZATION"] = TOKEN
    assert_equal TOKEN, Paquette::Authentication.token_in(env)
  end

  def test_token_in_is_nil_without_credentials
    assert_nil Paquette::Authentication.token_in(env_for)
  end

  def test_token_in_is_nil_for_a_basic_login_with_a_real_password
    assert_nil Paquette::Authentication.token_in(env_for(basic: [TOKEN, "hunter2"]))
  end

  def test_token_in_is_nil_for_a_scheme_it_does_not_speak
    env = env_for
    env["HTTP_AUTHORIZATION"] = "Digest username=\"x\""
    assert_nil Paquette::Authentication.token_in(env)
  end

  def test_token_in_survives_a_basic_payload_that_is_not_utf8
    env = env_for
    env["HTTP_AUTHORIZATION"] = "Basic #{["\xFF\xE2:".b].pack("m0")}"
    assert_equal "\xFF\xE2".b, Paquette::Authentication.token_in(env)
  end

  def test_identify_stores_the_identity_in_the_env
    env = env_for(bearer: TOKEN)

    assert_equal :acme, Paquette::Authentication.identify(env, @authenticator)
    assert_equal :acme, env["paquette.identity"]
  end

  # The application asks to build its gate, the server asks again: one
  # lookup between them.
  def test_identify_asks_the_authenticator_once_per_request
    env = env_for(bearer: TOKEN)
    2.times { Paquette::Authentication.identify(env, @authenticator) }

    assert_equal [TOKEN], @authenticator.calls
  end

  def test_a_refusal_is_remembered_too
    env = env_for(bearer: "nope")
    2.times { assert_nil Paquette::Authentication.identify(env, @authenticator) }

    assert_equal ["nope"], @authenticator.calls
  end

  # No credentials at all is the authenticator's call: a guest object is
  # how anonymous callers get in.
  def test_no_credentials_asks_the_authenticator_with_nil
    guest_friendly = CountingAuthenticator.new { |token| token ? :member : :guest }

    assert_equal :guest, Paquette::Authentication.identify(env_for, guest_friendly)
    assert_equal [nil], guest_friendly.calls
  end

  # A mangled header must not become an anonymous session, however friendly
  # the authenticator is to guests.
  def test_credentials_with_no_usable_token_are_refused_without_asking
    guest_friendly = CountingAuthenticator.new { |token| token ? :member : :guest }

    assert_nil Paquette::Authentication.identify(env_for(basic: [TOKEN, "hunter2"]), guest_friendly)
    assert_empty guest_friendly.calls
  end

  def test_a_live_code_verifies
    secret = ROTP::Base32.random
    totp = ROTP::TOTP.new(secret)

    assert_equal :authorized, Paquette::Authentication.verify_otp(secret, totp.now)
    assert_equal :authorized, Paquette::Authentication.verify_otp(secret, totp.at(Time.now - 30))
  end

  def test_a_code_outside_the_drift_or_wrong_is_rejected
    secret = ROTP::Base32.random
    totp = ROTP::TOTP.new(secret)

    assert_equal :rejected, Paquette::Authentication.verify_otp(secret, totp.at(Time.now - 300))
    assert_equal :rejected, Paquette::Authentication.verify_otp(secret, "000000")
    assert_equal :rejected, Paquette::Authentication.verify_otp(secret, "\xFF\xE2")
  end

  def test_an_absent_or_empty_code_is_missing_not_a_wrong_guess
    secret = ROTP::Base32.random

    assert_equal :missing, Paquette::Authentication.verify_otp(secret, nil)
    assert_equal :missing, Paquette::Authentication.verify_otp(secret, "")
  end

  private

  def env_for(bearer: nil, basic: nil)
    env = Rack::MockRequest.env_for("/")
    if bearer
      env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    elsif basic
      env["HTTP_AUTHORIZATION"] = "Basic #{["#{basic[0]}:#{basic[1]}"].pack("m0")}"
    end
    env
  end
end
