require "rotp"

# Verifies the one-time password on a publishing request. What counts as a
# publishing request is the caller's business — this gate verifies, it does
# not route. Everything protocol-shaped is the server's business: which
# header carries the code and what a refusal looks like on the wire both
# live in the `dialect:` collaborator each server class supplies — see
# GemServer.otp_gate and NpmServer.otp_gate, which are how an application
# should build one. What is left here is only what every dialect shares:
# ask for the code, count nothing-and-empty as missing, verify against the
# clock with drift, and say what happened in one word.
class Paquette::OtpGate
  # What the gate decided. `reason` is a short machine-readable word for a
  # log line or a metric tag; `response` is the ready Rack refusal, and its
  # absence is the authorization.
  Outcome = Data.define(:reason, :response) do
    def authorized? = response.nil?
  end

  # `dialect` answers `code_in(env)` — the code its protocol's header
  # carried, or nil — and `otp_missing` / `otp_rejected`, each a Rack
  # response triplet. An empty code counts as missing, not as a wrong
  # guess: a shell that expanded nothing did not guess.
  def initialize(secret:, issuer:, dialect:, drift: 30)
    @totp = ROTP::TOTP.new(secret, issuer: issuer)
    @dialect = dialect
    @drift = drift
  end

  def verify(env)
    code = @dialect.code_in(env)
    if code.nil? || code.empty?
      return Outcome.new(reason: "otp_missing", response: @dialect.otp_missing)
    end

    unless @totp.verify(code, drift_behind: @drift, drift_ahead: @drift)
      return Outcome.new(reason: "otp_rejected", response: @dialect.otp_rejected)
    end

    Outcome.new(reason: "authorized", response: nil)
  end
end
