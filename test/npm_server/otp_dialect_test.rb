require_relative "../test_helper"
require "rotp"

# How npm speaks OTP, owned by NpmServer: the code arrives in `npm-otp` with
# the plain `OTP` header as the curl-user fallback, and a refusal must read
# as an OTP challenge to npm's client — the www-authenticate header and
# "one-time pass" in the body — or npm reports a failed login instead of
# prompting for a code.
class NpmServerOtpDialectTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret, issuer: "test-registry")
    @gate = Paquette::NpmServer.otp_gate(secret: @secret, issuer: "test-registry")
  end

  def test_a_live_code_in_the_npm_otp_header_authorizes
    assert @gate.verify({"HTTP_NPM_OTP" => @totp.now}).authorized?
  end

  def test_a_registry_scripted_with_curl_and_a_plain_otp_header_passes
    assert @gate.verify({"HTTP_OTP" => @totp.now}).authorized?
  end

  def test_npm_s_own_header_wins_when_both_are_present
    outcome = @gate.verify({"HTTP_NPM_OTP" => @totp.now, "HTTP_OTP" => "000000"})

    assert outcome.authorized?, "the code npm itself sent must be the one verified"
  end

  def test_a_missing_code_is_challenged
    outcome = @gate.verify({})

    assert_equal "otp_missing", outcome.reason
    assert_npm_challenge outcome.response
  end

  def test_a_wrong_code_is_challenged_again_rather_than_refused_flat
    outcome = @gate.verify({"HTTP_NPM_OTP" => "000000"})

    assert_equal "otp_rejected", outcome.reason
    assert_npm_challenge outcome.response
  end

  private

  # Both marks, asserted together: neither client-side detection path may be
  # the only one.
  def assert_npm_challenge(response)
    status, headers, body = response
    assert_equal 401, status
    assert_equal "OTP", headers["www-authenticate"]
    assert_includes body.join, "one-time pass"
  end
end
