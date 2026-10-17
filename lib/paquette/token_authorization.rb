require "rack/auth/abstract/handler"
require "rack/auth/abstract/request"
require "measurometer"

# Rack authentication handler that extracts an opaque access token from
# either a Bearer header or a Basic auth header with the token as username
# and any password (the GitHub registry convention) — so machine clients like
# Bundler and npm, which only speak Basic auth, can authenticate with just a
# token in their config. The token is also taken from the Basic password when
# the username is empty or one of USERNAME_SENTINELS. A bare
# `Authorization: <token>` with no scheme is taken too: that is how `gem push`
# sends the key `gem signin` stored. The resolved identity is stored in
# env["paquette.identity"].
class Paquette::TokenAuthorization < Rack::Auth::AbstractHandler
  prepend Paquette::RegexpTimeout

  # Some HTTP clients refuse to send an empty Basic auth password, so a
  # placeholder goes in its place. Any password is accepted next to a token
  # username, so this is kept for callers who refer to it.
  #
  # @return [String]
  BEARER_SENTINEL = "x-oauth-token"

  # Basic auth usernames that say "the token is in the password". GitHub takes
  # `x-oauth-basic` and `x-access-token` this way round as well as the other.
  #
  # @return [Array<String>]
  USERNAME_SENTINELS = ["x-oauth-basic", "x-access-token", BEARER_SENTINEL].freeze

  # @param app [#call] the downstream Rack app
  # @param realm [String] the authentication realm (used in WWW-Authenticate)
  # @yield [token] receives the raw token string on every request
  # @yieldreturn [Object, nil] an identity object (user, team, account), or
  #   a falsy value to reject the request
  def initialize(app, realm = "Paquette", &authenticator)
    super(app, realm)
    @authenticator = authenticator || ->(_token) { true }
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    auth = Request.new(env)

    # The authenticator is the caller's, and it usually goes to a database to
    # resolve the token — on every single request, before any of the work the
    # request asked for. Timed separately from the app it guards.
    identity = if auth.provided? && (token = auth.token)
      Measurometer.instrument("paquette.token_authorization.authenticate") { @authenticator.call(token) }
    end

    if identity
      Measurometer.increment_counter("paquette.token_authorization.accepted")
      env["paquette.access_token"] = token
      env["paquette.identity"] = identity
      @app.call(env)
    else
      Measurometer.increment_counter("paquette.token_authorization.rejected")
      unauthorized
    end
  end

  private

  # @return [String]
  def challenge
    %(Bearer realm="#{realm}")
  end

  # Reads the token out of one request, whichever of the two schemes the
  # client used to carry it.
  class Request < Rack::Auth::AbstractRequest
    # @return [String, nil] the token, whichever scheme carried it
    def token
      return @token if defined?(@token)

      # `gem push`, `gem yank` and `gem owner` send the key with no scheme at
      # all, the way rubygems.org takes it
      return @token = parts.first if parts.length == 1

      @token = case scheme
      when "bearer"
        params
      when "basic"
        # The password carries no secret when the token is the username, so it
        # is not looked at - `TOKEN:x-oauth-basic` is what GitHub's docs teach
        username, password = credentials
        if username.nil? || username.empty? || USERNAME_SENTINELS.include?(username)
          password unless password.nil? || password.empty?
        else
          username
        end
      end
    end

    # @return [Array(String, String), Array(String)] username and password
    def credentials
      @credentials ||= params.unpack1("m").split(":", 2)
    end
  end
end
