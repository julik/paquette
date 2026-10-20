require "rotp"

# Checks a one-time password against a base32 TOTP secret, for an
# authenticator's `check_otp!`. Paquette has nowhere to keep state, so the
# application keeps what refuses a replay - the time step `verify!` returns,
# handed back as `after:` next time - and throttles wrong guesses.
module Paquette::Totp
  # One TOTP period, both directions.
  #
  # @return [Integer]
  DEFAULT_DRIFT = 30

  # @param secret [String] the base32 TOTP secret
  # @param code [String]
  # @param drift [Integer] allowed clock drift in seconds, both directions
  # @param after [Integer, nil] the time step of the last code accepted for this
  #   secret: that code, and any older one, is refused
  # @raise [Paquette::OtpRejected] when the code is not good now, or was used
  # @raise [ArgumentError] on a nil or empty secret - far more often a user
  #   row with none set than a decision to skip the check
  # @return [Integer] the time step the code belongs to, to pass as `after:`
  def self.verify!(secret, code, drift: DEFAULT_DRIFT, after: nil)
    raise ArgumentError, "The TOTP secret must be a non-empty String" unless secret.is_a?(String) && !secret.empty?

    ROTP::TOTP.new(secret).verify(code.to_s, drift_behind: drift, drift_ahead: drift, after: after) ||
      raise(Paquette::OtpRejected)
  end
end
