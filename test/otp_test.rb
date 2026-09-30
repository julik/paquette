require_relative "test_helper"
require "rotp"

# The protocol-neutral half: verifying a code with drift and naming the
# outcome. Which header carries the code and what a refusal looks like are
# each server's, and are tested beside it.
class OtpTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
  end

  def test_a_live_code_authorizes
    assert_equal :authorized, Paquette::Otp.verify(@secret, @totp.now)
  end

  def test_a_code_from_the_previous_period_is_still_accepted
    assert_equal :authorized, Paquette::Otp.verify(@secret, @totp.at(Time.now - 30))
  end

  def test_a_code_outside_the_drift_is_rejected
    assert_equal :rejected, Paquette::Otp.verify(@secret, @totp.at(Time.now - 300))
  end

  def test_a_wrong_code_is_rejected
    assert_equal :rejected, Paquette::Otp.verify(@secret, "000000")
  end

  def test_an_absent_code_is_missing
    assert_equal :missing, Paquette::Otp.verify(@secret, nil)
  end

  def test_an_empty_code_counts_as_missing_not_as_a_wrong_guess
    assert_equal :missing, Paquette::Otp.verify(@secret, "")
  end

  def test_a_code_that_is_not_valid_utf8_is_rejected_rather_than_raising
    assert_equal :rejected, Paquette::Otp.verify(@secret, "\xFF\xE2")
  end

  def test_a_nil_secret_switches_the_check_off
    assert_nil Paquette::Otp.checked_secret(nil)
  end

  # A user row with no secret set must not read as "OTP off".
  def test_an_empty_secret_is_refused
    assert_raises(ArgumentError) { Paquette::Otp.checked_secret("") }
    assert_raises(ArgumentError) { Paquette::GemServer.new(nil, otp_secret: "") }
    assert_raises(ArgumentError) { Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(Dir.tmpdir), otp_secret: "") }
  end
end
