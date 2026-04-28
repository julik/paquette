require "rack/auth/abstract/handler"
require "rack/auth/abstract/request"

module Paquette
  # Rack authentication handler that extracts an opaque access token from either
  # a Bearer header or a Basic auth header (token-as-username). This makes the
  # server compatible with any HTTP client — machine-oriented clients like
  # Bundler, npm, pip and curl that only speak Basic auth can authenticate the
  # same way as clients that send a proper Bearer token.
  #
  # Accepting the token as the Basic auth username is a trick popularised by
  # GitHub's package registries and personal access tokens. Most package manager
  # CLIs configure credentials as a username/password pair and transmit them via
  # Basic auth — there is no built-in mechanism to send a Bearer header. By
  # treating the Basic username as the token (with an empty or sentinel password)
  # the customer can drop their token straight into their package manager config:
  #
  #   # Bundler
  #   bundle config set --global gems.example.com "pqt_token_here:"
  #
  #   # npm .npmrc
  #   //registry.example.com/:_auth=<base64 of "pqt_token_here:">
  #
  # The password field is either empty or the literal "x-oauth-token" — a
  # convention from GitHub that exists because some HTTP clients refuse to send
  # an empty password.
  #
  # Accepted schemes:
  #
  #   Authorization: Bearer <token>
  #   Authorization: Basic base64("<token>:")
  #   Authorization: Basic base64("<token>:x-oauth-token")
  #
  # Usage:
  #
  #   # The block receives the raw token string and should return an identity
  #   # object (user, team, account — whatever makes sense) or a falsy value
  #   # to reject the request. The identity is stored in env["paquette.identity"].
  #
  #   use Paquette::TokenAuthorization, "Paquette" do |token|
  #     AccessToken.find_by(secret: token)&.owner
  #   end
  #
  class TokenAuthorization < Rack::Auth::AbstractHandler
    BEARER_SENTINEL = "x-oauth-token"

    # @param app  [#call]   the downstream Rack app
    # @param realm [String] the authentication realm (used in WWW-Authenticate)
    # @yield [token] block that receives the token string and returns an
    #   identity object (truthy) or nil/false to reject
    def initialize(app, realm = "Paquette", &authenticator)
      super(app, realm)
      @authenticator = authenticator || ->(_token) { true }
    end

    def call(env)
      auth = Request.new(env)

      if auth.provided? && (token = auth.token) && (identity = @authenticator.call(token))
        env["paquette.access_token"] = token
        env["paquette.identity"] = identity
        @app.call(env)
      else
        unauthorized
      end
    end

    private

    def challenge
      %(Bearer realm="#{realm}")
    end

    class Request < Rack::Auth::AbstractRequest
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

      def credentials
        @credentials ||= params.unpack1("m").split(":", 2)
      end
    end
  end
end
