require_relative "test_helper"
require "rotp"

class AccessTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @access = Paquette::Access.new(repository: :repository, otp_secret: @secret)
  end

  def test_a_secret_makes_writes_need_a_code
    assert @access.otp_required?
    refute Paquette::Access.new(repository: :repository).otp_required?
  end

  def test_a_live_code_verifies
    assert @access.verify_otp(@totp.now)
    assert @access.verify_otp(@totp.at(Time.now - 30))
  end

  def test_a_code_outside_the_drift_or_wrong_is_rejected
    refute @access.verify_otp(@totp.at(Time.now - 300))
    refute @access.verify_otp("000000")
    refute @access.verify_otp("\xFF\xE2")
  end

  def test_the_drift_is_configurable
    strict = Paquette::Access.new(repository: :repository, otp_secret: @secret, otp_drift: 0)

    refute strict.verify_otp(@totp.at(Time.now - 60))
  end

  def test_without_a_secret_no_code_verifies
    refute Paquette::Access.new(repository: :repository).verify_otp("123456")
  end

  # A user row with no secret set must not read as "OTP off"
  def test_an_empty_secret_is_a_configuration_error_not_a_pass
    assert_raises(ArgumentError) { Paquette::Access.new(repository: :repository, otp_secret: "") }
    assert_raises(ArgumentError) { Paquette::Access.new(repository: :repository, otp_secret: 123) }
  end
end
