require "rack/auth/abstract/request"
require "measurometer"

# Who is calling and what they get, asked of the authenticator a server is
# built with:
#
#   authenticate(token, request) # => an access object, or nil to refuse
#                                #    with a 401. token is nil when the
#                                #    caller sent none, so returning an
#                                #    access object is how anonymous
#                                #    callers are let in
#
# The access object answers `repository`, `otp_required?` and
# `verify_otp(code)` - see Paquette::Access for the stock one. Because the
# repository comes out of it, one server built at boot can hand a publisher
# a writable stack and a licensee a gated, read-only one.
#
# The access lives in env["paquette.access"], resolved at most once per
# request: whichever of the application and the server asks first stores
# it, and the other reads it back.
#
# What is not shared - which header carries a one-time code, what a refusal
# looks like on the wire - is each server's own, because the client on the
# other end dictates it: an including server defines `otp_code(env)`,
# `otp_missing` and `otp_rejected`.
module Paquette::Authentication
  # @return [String]
  ACCESS_KEY = "paquette.access"

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

  # The caller's access, resolved through the authenticator once and
  # remembered in the env. Credentials that carry no usable token are
  # refused without asking: a mangled header must not become an anonymous
  # session.
  #
  # @param env [Hash] the Rack env
  # @param authenticator [Object] answers `authenticate(token, request)`
  # @return [Object, nil] the access, or nil when refused
  def self.access(env, authenticator)
    return env[ACCESS_KEY] if env.key?(ACCESS_KEY)

    auth = Request.new(env)
    access = if !auth.provided?
      call_authenticator(authenticator, nil, env)
    elsif (token = auth.token)
      call_authenticator(authenticator, token, env)
    end

    Measurometer.increment_counter(access ? "paquette.authentication.accepted" : "paquette.authentication.rejected")
    env[ACCESS_KEY] = access
  end

  # The authenticator is the caller's, and it usually goes to a database to
  # resolve the token - on every request, before any of the work the
  # request asked for.
  #
  # @param authenticator [Object]
  # @param token [String, nil]
  # @param env [Hash]
  # @return [Object, nil]
  def self.call_authenticator(authenticator, token, env)
    Measurometer.instrument("paquette.authentication.authenticate") do
      authenticator.authenticate(token, Rack::Request.new(env))
    end
  end

  # A repository predating `writable?` is taken at its word that it is - its
  # write methods still raise if it is not.
  #
  # @param repository [Object]
  # @return [Boolean]
  def self.writable?(repository)
    !repository.respond_to?(:writable?) || repository.writable?
  end

  private

  # The access this request is served under: the authenticator's answer, or
  # without an authenticator the one stack the server was built with, open
  # to everyone.
  #
  # @param env [Hash] the Rack env
  # @return [Object, nil] nil when the authenticator refused the caller
  def access_for(env)
    return @open_access unless @authenticator

    Paquette::Authentication.access(env, @authenticator)
  end

  # @return [Array] a Rack response triplet
  def unauthorized
    [401, {"Content-Type" => "text/plain", "www-authenticate" => %(Bearer realm="Paquette")}, ["Unauthorized"]]
  end

  # The refusal for a write this caller may not make, or nil to let it
  # through. Asked before the handler runs, so a push is refused before its
  # body is read.
  #
  # @param access [Object]
  # @param env [Hash] the Rack env
  # @return [Array, nil] a Rack response triplet
  def write_refusal(access, env)
    unless Paquette::Authentication.writable?(access.repository)
      Measurometer.increment_counter("paquette.authentication.write_refused")
      return [403, {"Content-Type" => "text/plain"}, ["Writes are not allowed for this caller"]]
    end
    return nil unless access.otp_required?

    code = otp_code(env)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess
    result = if code.nil? || code.empty?
      :missing
    elsif access.verify_otp(code)
      :authorized
    else
      :rejected
    end

    Measurometer.increment_counter("paquette.otp.#{result}")
    case result
    when :missing then otp_missing
    when :rejected then otp_rejected
    end
  end

  # Builds the default access for a server with no authenticator
  #
  # @param repository [Object, nil]
  # @param authenticator [Object, nil]
  # @return [void]
  def setup_access(repository, authenticator)
    if repository.nil? == authenticator.nil?
      raise ArgumentError, "Pass either a repository or an authenticator: with an authenticator, the repository comes from the access it returns"
    end

    @authenticator = authenticator
    @open_access = repository && Paquette::Access.new(repository: repository)
  end
end
