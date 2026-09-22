require_relative "test_helper"
require "rotp"

# The dialect-neutral core: asking the dialect for the code, verifying it
# with drift, and reporting the outcome vocabulary. Which header carries a
# code and what a refusal looks like on the wire are the servers' knowledge —
# see the OtpDialect tests beside each server. The stub here reads a header
# no real protocol uses, which is the point: the gate must work without
# knowing a single header name of its own.
class OtpGateTest < Minitest::Test
  module StubDialect
    module_function

    def code_in(env)
      env["HTTP_X_STUB_CODE"]
    end

    def otp_missing
      [401, {}, ["missing"]]
    end

    def otp_rejected
      [401, {}, ["rejected"]]
    end
  end

  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret, issuer: "test-registry")
    @gate = Paquette::OtpGate.new(secret: @secret, issuer: "test-registry", dialect: StubDialect)
  end

  def test_a_live_code_authorizes
    outcome = @gate.verify({"HTTP_X_STUB_CODE" => @totp.now})

    assert outcome.authorized?
    assert_equal "authorized", outcome.reason
    assert_nil outcome.response
  end

  def test_a_code_from_the_previous_period_is_still_accepted
    outcome = @gate.verify({"HTTP_X_STUB_CODE" => @totp.at(Time.now - 30)})

    assert outcome.authorized?
  end

  def test_a_missing_code_hands_back_the_dialect_s_missing_refusal
    outcome = @gate.verify({})

    refute outcome.authorized?
    assert_equal "otp_missing", outcome.reason
    assert_equal StubDialect.otp_missing, outcome.response
  end

  def test_a_wrong_code_hands_back_the_dialect_s_rejected_refusal
    outcome = @gate.verify({"HTTP_X_STUB_CODE" => "000000"})

    refute outcome.authorized?
    assert_equal "otp_rejected", outcome.reason
    assert_equal StubDialect.otp_rejected, outcome.response
  end

  def test_an_empty_code_counts_as_missing_not_as_a_wrong_guess
    outcome = @gate.verify({"HTTP_X_STUB_CODE" => ""})

    assert_equal "otp_missing", outcome.reason
  end
end
