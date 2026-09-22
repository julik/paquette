require_relative "../test_helper"
require "rotp"

# How `gem push` speaks OTP, owned by GemServer: the code arrives in the
# `OTP` header and the exact refusal sentences are the contract with the
# client.
class GemServerOtpDialectTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret, issuer: "test-registry")
    @gate = Paquette::GemServer.otp_gate(secret: @secret, issuer: "test-registry")
  end

  def test_a_live_code_in_the_otp_header_authorizes
    assert @gate.verify({"HTTP_OTP" => @totp.now}).authorized?
  end

  def test_npm_s_header_is_not_this_dialect
    outcome = @gate.verify({"HTTP_NPM_OTP" => @totp.now})

    assert_equal "otp_missing", outcome.reason
  end

  def test_a_missing_code_gets_the_sentence_gem_push_expects
    outcome = @gate.verify({})

    assert_equal "otp_missing", outcome.reason
    assert_equal [401, {}, ["You have enabled multifactor authentication"]], outcome.response
  end

  def test_a_wrong_code_gets_the_sentence_gem_push_expects
    outcome = @gate.verify({"HTTP_OTP" => "000000"})

    assert_equal "otp_rejected", outcome.reason
    assert_equal [401, {}, ["OTP verification failed"]], outcome.response
  end
end
