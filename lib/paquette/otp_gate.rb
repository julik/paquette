require "rotp"

# Verifies the one-time password on a publishing request. Protocol specifics
# (which header carries the code, what a refusal looks like on the wire) live
# in the `dialect:` collaborator each server class supplies — see
# GemServer.otp_gate and NpmServer.otp_gate.
class Paquette::OtpGate
  # What the gate decided. `reason` is a short machine-readable word for a
  # log line or a metric tag; `response` is the ready Rack refusal, and its
  # absence is the authorization.
  #
  # @!attribute reason
  #   @return [String]
  # @!attribute response
  #   @return [Array, nil] a Rack response triplet, or nil when authorized
  Outcome = Data.define(:reason, :response) do
    # @return [Boolean]
    def authorized? = response.nil?
  end

  # @param secret [String] the TOTP secret
  # @param issuer [String] the TOTP issuer name
  # @param dialect [Object] answers `code_in(env)` with the code the
  #   protocol's header carried (or nil), and `otp_missing` / `otp_rejected`,
  #   each a Rack response triplet
  # @param drift [Integer] allowed clock drift in seconds, both directions
  def initialize(secret:, issuer:, dialect:, drift: 30)
    @totp = ROTP::TOTP.new(secret, issuer: issuer)
    @dialect = dialect
    @drift = drift
  end

  # @param env [Hash] the Rack env
  # @return [Outcome]
  def verify(env)
    code = @dialect.code_in(env)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess.
    if code.nil? || code.empty?
      return Outcome.new(reason: "otp_missing", response: @dialect.otp_missing)
    end

    unless @totp.verify(code, drift_behind: @drift, drift_ahead: @drift)
      return Outcome.new(reason: "otp_rejected", response: @dialect.otp_rejected)
    end

    Outcome.new(reason: "authorized", response: nil)
  end
end
