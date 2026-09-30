require "rack/auth/abstract/handler"
require "rack/auth/abstract/request"
require "measurometer"

# Rack authentication handler that extracts an opaque access token from
# either a Bearer header or a Basic auth header with the token as username
# (the GitHub registry convention) — so machine clients like Bundler and npm,
# which only speak Basic auth, can authenticate with just a token in their
# config. The resolved identity is stored in env["paquette.identity"].
#
# An application that resolves the caller itself, per request, reads the
# token with {.token_in} rather than parsing the header on its own.
class Paquette::TokenAuthorization < Rack::Auth::AbstractHandler
  prepend Paquette::RegexpTimeout

  # Some HTTP clients refuse to send an empty Basic auth password; GitHub's
  # convention is this literal in its place.
  #
  # @return [String]
  BEARER_SENTINEL = "x-oauth-token"

  # The token a request carries, whichever of the two schemes carried it.
  #
  # @param env [Hash] the Rack env
  # @return [String, nil] nil when there is none, or when Basic auth carries
  #   a real password — that is a login, not a token
  def self.token_in(env)
    auth = Request.new(env)
    auth.token if auth.provided?
  end

  # @param app [#call] the downstream Rack app
  # @param realm [String] the authentication realm (used in WWW-Authenticate)
  # @param anonymous [Boolean] let a request with no credentials at all
  #   through, with no identity, so the server and the repository stack
  #   decide what an anonymous caller gets. Credentials that do not resolve
  #   are refused either way: a typo in a token must not quietly become an
  #   anonymous session
  # @yield [token] receives the raw token string on every request
  # @yieldreturn [Object, nil] an identity object (user, team, account), or
  #   a falsy value to reject the request
  def initialize(app, realm = "Paquette", anonymous: false, &authenticator)
    super(app, realm)
    @anonymous = anonymous
    @authenticator = authenticator || ->(_token) { true }
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    auth = Request.new(env)
    if @anonymous && !auth.provided?
      Measurometer.increment_counter("paquette.token_authorization.anonymous")
      return @app.call(env)
    end

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

      @token = case scheme
      when "bearer"
        params
      when "basic"
        username, password = credentials
        if password.nil? || password.empty? || password == BEARER_SENTINEL
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
