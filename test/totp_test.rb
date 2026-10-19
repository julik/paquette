require_relative "test_helper"
require "rotp"

class TotpTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
  end

  def test_a_live_code_passes
    assert_nil Paquette::Totp.verify!(@secret, @totp.now)
  end

  def test_a_code_from_one_period_ago_passes
    assert_nil Paquette::Totp.verify!(@secret, @totp.at(Time.now - 30))
  end

  def test_a_stale_code_is_rejected
    assert_raises(Paquette::OtpRejected) { Paquette::Totp.verify!(@secret, @totp.at(Time.now - 120)) }
  end

  def test_a_wrong_code_is_rejected
    assert_raises(Paquette::OtpRejected) { Paquette::Totp.verify!(@secret, "not a code") }
  end

  # Far more often a user row with no secret set than a decision to skip the check
  def test_a_missing_secret_is_an_error_not_a_pass
    [nil, ""].each do |secret|
      assert_raises(ArgumentError) { Paquette::Totp.verify!(secret, "123456") }
    end
  end
end
