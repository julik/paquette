require "rack/auth/abstract/request"
require "rotp"
require "measurometer"

# Who is calling, and whether a write really is them — asked of one
# authenticator object that both servers take as `authenticator:`, so the
# same object serves a rackup file built once at boot and an application
# that assembles a server per request.
#
# An authenticator answers two questions:
#
#   identify(token)      # => an identity, or nil to refuse with a 401.
#                        #    token is nil when the caller sent none, so
#                        #    returning a guest object is how anonymous
#                        #    callers are let in
#   otp_secret(identity) # => the base32 TOTP secret every write by this
#                        #    identity must prove, or nil for none
#
# The identity lives in env["paquette.identity"], resolved at most once per
# request: whichever of the application and the server asks first stores
# it, and the other reads it back.
#
# What is not shared — which header carries a one-time code, what a refusal
# looks like on the wire — is each server's own, because the client on the
# other end dictates it: an including server defines `otp_code(env)`,
# `otp_missing` and `otp_rejected`.
module Paquette::Authentication
  # @return [String]
  IDENTITY_KEY = "paquette.identity"

  # Allowed clock drift in seconds, both directions — one TOTP period.
  #
  # @return [Integer]
  DEFAULT_OTP_DRIFT = 30

  # What stands in for a password when the token rides in the username:
  # GitHub documents the first, and some clients refuse an empty password.
  #
  # @return [Array<String>]
  TOKEN_PASSWORDS = ["", "x-oauth-basic", "x-oauth-token"].freeze

  # Reads the token out of one request, whichever way the client sent it:
  # npm sends Bearer, Bundler sends Basic with the token as the username,
  # and `gem push` and `gem yank` send the bare key with no scheme at all.
  class Request < Rack::Auth::AbstractRequest
    # @return [String, nil] nil for a scheme this does not speak, or for
    #   Basic auth carrying a real password — that is a login, not a token
    def token
      return params if parts.length == 1

      case scheme
      when "bearer"
        params
      when "basic"
        username, password = params.unpack1("m").split(":", 2)
        username if password.nil? || TOKEN_PASSWORDS.include?(password)
      end
    end
  end

  # The token a request carries, or nil.
  #
  # @param env [Hash] the Rack env
  # @return [String, nil]
  def self.token_in(env)
    auth = Request.new(env)
    auth.token if auth.provided?
  end

  # The caller's identity, resolved through the authenticator once and
  # remembered in the env. Credentials that carry no usable token are
  # refused without asking: a mangled header must not become an anonymous
  # session.
  #
  # @param env [Hash] the Rack env
  # @param authenticator [Object] answers `identify(token)`
  # @return [Object, nil] the identity, or nil when refused
  def self.identify(env, authenticator)
    return env[IDENTITY_KEY] if env.key?(IDENTITY_KEY)

    auth = Request.new(env)
    identity = if !auth.provided?
      call_authenticator(authenticator, nil)
    elsif (token = auth.token)
      call_authenticator(authenticator, token)
    end

    Measurometer.increment_counter(identity ? "paquette.authentication.accepted" : "paquette.authentication.rejected")
    env[IDENTITY_KEY] = identity
  end

  # The authenticator is the caller's, and it usually goes to a database to
  # resolve the token — on every request, before any of the work the
  # request asked for.
  #
  # @param authenticator [Object]
  # @param token [String, nil]
  # @return [Object, nil]
  def self.call_authenticator(authenticator, token)
    Measurometer.instrument("paquette.authentication.identify") { authenticator.identify(token) }
  end

  # @param secret [String] the base32 TOTP secret
  # @param code [String, nil] what the client sent
  # @param drift [Integer] allowed clock drift in seconds, both directions
  # @return [Symbol] :authorized, :missing or :rejected
  def self.verify_otp(secret, code, drift: DEFAULT_OTP_DRIFT)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess.
    return :missing if code.nil? || code.empty?
    return :rejected unless ROTP::TOTP.new(secret).verify(code, drift_behind: drift, drift_ahead: drift)

    :authorized
  end

  private

  # A 401 when the server has an authenticator and it refused the caller;
  # nil otherwise.
  #
  # @param env [Hash] the Rack env
  # @return [Array, nil] a Rack response triplet
  def authentication_refusal(env)
    return nil unless @authenticator
    return nil if Paquette::Authentication.identify(env, @authenticator)

    [401, {"Content-Type" => "text/plain", "www-authenticate" => %(Bearer realm="Paquette")}, ["Unauthorized"]]
  end

  # The refusal for a write that did not carry a valid code, or nil to let
  # it through. Asked before the handler runs, so a push is refused before
  # its body is read.
  #
  # @param env [Hash] the Rack env
  # @return [Array, nil] a Rack response triplet
  # @raise [ArgumentError] when the authenticator answers an empty secret —
  #   far more often a user row with none set than a decision to skip
  def otp_refusal(env)
    return nil unless @authenticator

    secret = @authenticator.otp_secret(env[IDENTITY_KEY])
    return nil if secret.nil?
    raise ArgumentError, "otp_secret must be nil or a non-empty String" unless secret.is_a?(String) && !secret.empty?

    result = Paquette::Authentication.verify_otp(secret, otp_code(env), drift: @otp_drift)
    Measurometer.increment_counter("paquette.otp.#{result}")
    case result
    when :missing then otp_missing
    when :rejected then otp_rejected
    end
  end
end
