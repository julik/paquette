require "rotp"
require "measurometer"

# The one-time password check both servers run on a write when they were
# given an `otp_secret:`. What is shared lives here: when to ask, how to
# verify, what to count. What is not — which header carries the code, what
# a refusal looks like on the wire — is each server's own, because it is
# dictated by the client on the other end: an including server defines
# `otp_code(env)`, `otp_missing` and `otp_rejected`.
module Paquette::Otp
  # Allowed clock drift in seconds, both directions — one TOTP period.
  #
  # @return [Integer]
  DEFAULT_DRIFT = 30

  # @param secret [String] the base32 TOTP secret
  # @param code [String, nil] what the client sent
  # @param drift [Integer] allowed clock drift in seconds, both directions
  # @return [Symbol] :authorized, :missing or :rejected
  def self.verify(secret, code, drift: DEFAULT_DRIFT)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess.
    return :missing if code.nil? || code.empty?
    return :rejected unless ROTP::TOTP.new(secret).verify(code, drift_behind: drift, drift_ahead: drift)

    :authorized
  end

  # nil switches the check off; an empty String is refused rather than
  # read as "off", because it is far more often a user row with no secret
  # set than a decision.
  #
  # @param secret [String, nil]
  # @return [String, nil]
  # @raise [ArgumentError]
  def self.checked_secret(secret)
    return nil if secret.nil?
    raise ArgumentError, "otp_secret: must be nil or a non-empty String" unless secret.is_a?(String) && !secret.empty?

    secret
  end

  private

  # The refusal for a write that did not carry a valid code, or nil to let
  # it through. Asked before the handler runs, so a push is refused before
  # its body is read.
  #
  # @param env [Hash] the Rack env
  # @return [Array, nil] a Rack response triplet, or nil when authorized
  def otp_refusal(env)
    return nil unless @otp_secret

    result = Paquette::Otp.verify(@otp_secret, otp_code(env), drift: @otp_drift)
    Measurometer.increment_counter("paquette.otp.#{result}")
    case result
    when :missing then otp_missing
    when :rejected then otp_rejected
    end
  end
end
