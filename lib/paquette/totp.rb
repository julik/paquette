require "rotp"

# Checks a one-time password against a base32 TOTP secret, for an
# authenticator's `check_otp!`. Replay protection and lockout after wrong
# guesses need state Paquette has nowhere to keep, so those stay with the
# application.
module Paquette::Totp
  # One TOTP period, both directions.
  #
  # @return [Integer]
  DEFAULT_DRIFT = 30

  # @param secret [String] the base32 TOTP secret
  # @param code [String]
  # @param drift [Integer] allowed clock drift in seconds, both directions
  # @raise [Paquette::OtpRejected] when the code is not good now
  # @raise [ArgumentError] on a nil or empty secret - far more often a user
  #   row with none set than a decision to skip the check
  # @return [void]
  def self.verify!(secret, code, drift: DEFAULT_DRIFT)
    raise ArgumentError, "The TOTP secret must be a non-empty String" unless secret.is_a?(String) && !secret.empty?

    raise Paquette::OtpRejected unless ROTP::TOTP.new(secret).verify(code.to_s, drift_behind: drift, drift_ahead: drift)
  end
end
