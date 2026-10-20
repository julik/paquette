require_relative "test_helper"
require "rotp"

class TotpTest < Minitest::Test
  def setup
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
  end

  def test_a_live_code_passes_and_names_its_time_step
    assert_kind_of Integer, Paquette::Totp.verify!(@secret, @totp.now)
  end

  def test_a_code_from_one_period_ago_passes
    assert Paquette::Totp.verify!(@secret, @totp.at(Time.now - 30))
  end

  def test_a_code_already_used_is_refused_after_its_time_step
    used = Paquette::Totp.verify!(@secret, @totp.now)

    assert_raises(Paquette::OtpRejected) { Paquette::Totp.verify!(@secret, @totp.now, after: used) }
    assert_raises(Paquette::OtpRejected) { Paquette::Totp.verify!(@secret, @totp.at(Time.now - 30), after: used) }
  end

  def test_the_next_code_passes_after_the_last_one
    used = Paquette::Totp.verify!(@secret, @totp.at(Time.now - 30))

    assert_operator Paquette::Totp.verify!(@secret, @totp.now, after: used), :>, used
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
