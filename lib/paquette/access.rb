require "rotp"

# What one caller gets: the repository stack they see and write to, and
# whether their writes need a one-time code. An authenticator returns one
# per request - this one, or any object answering the same three methods.
#
# Bring your own when the code needs state Paquette has no place for:
# refusing a code that was already used once, or locking out after a few
# wrong guesses.
class Paquette::Access
  # Allowed clock drift in seconds, both directions - one TOTP period.
  #
  # @return [Integer]
  DEFAULT_OTP_DRIFT = 30

  # @return [Object] the repository stack this caller is served from
  attr_reader :repository

  # @return [String, nil] what `npm whoami` answers
  attr_reader :username

  # @param repository [Object] a GemRepository or NpmRepository stack
  # @param otp_secret [String, nil] the base32 TOTP secret every write must
  #   prove, or nil for none
  # @param otp_drift [Integer] allowed clock drift in seconds, both directions
  # @param username [String, nil]
  # @raise [ArgumentError] on an empty secret - far more often a user row
  #   with none set than a decision to skip the check
  def initialize(repository:, otp_secret: nil, otp_drift: DEFAULT_OTP_DRIFT, username: nil)
    usable = otp_secret.nil? || (otp_secret.is_a?(String) && !otp_secret.empty?)
    raise ArgumentError, "otp_secret must be nil or a non-empty String" unless usable

    @repository = repository
    @otp_secret = otp_secret
    @otp_drift = otp_drift
    @username = username
  end

  # @return [Boolean]
  def otp_required?
    !@otp_secret.nil?
  end

  # @param code [String] never empty - the server answers a missing code itself
  # @return [Boolean]
  def verify_otp(code)
    return false unless @otp_secret

    !!ROTP::TOTP.new(@otp_secret).verify(code, drift_behind: @otp_drift, drift_ahead: @otp_drift)
  end
end
