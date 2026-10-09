require "rack/auth/basic"
require "measurometer"

# Rack middleware answering `gem signin --host`: the client sends the
# username/email and password it prompted for as HTTP Basic auth to
# `POST /api/v1/api_key`, and stores whatever plain-text key comes back in
# its credentials file under that host. `gem push`, `gem yank` and `gem owner`
# then send that key as a bare `Authorization` header, which
# Paquette::TokenAuthorization accepts.
#
# Paquette keeps no accounts and no keys. Checking the credentials, minting
# the key and remembering it are the embedding application's, through the
# block and the `issue_key:` callable. Every other request passes through to
# the wrapped app untouched, so this goes in front of the token check:
#
#   use Paquette::GemServer::SignIn, issue_key: ->(user, name:, scopes:, mfa:) { ... } do |email:, password:|
#     User.authenticate_by(email: email, password: password)
#   end
#   use Paquette::TokenAuthorization do |token|
#     ApiKey.find_by_plaintext(token)&.user
#   end
#   run Paquette::GemServer.new(repo)
class Paquette::GemServer::SignIn
  prepend Paquette::RegexpTimeout

  # @return [String]
  API_KEY_PATH = "/api/v1/api_key"

  # @return [String]
  WEBAUTHN_VERIFICATION_PATH = "/api/v1/webauthn_verification"

  # The scope params rubygems.org knows. The client sends each one it wants
  # as `scope=true`; anything else in the body is not a scope.
  #
  # @return [Array<String>]
  SCOPES = %w[
    index_rubygems
    push_rubygem
    yank_rubygem
    add_owner
    remove_owner
    access_webhooks
    show_dashboard
    configure_trusted_publishers
  ].freeze

  # rubygems.org's own cap on a key name.
  #
  # @return [Integer]
  MAX_KEY_NAME_BYTES = 255

  # Rails' wording for a failed Basic auth, which is what rubygems.org sends
  # and what `gem signin` prints.
  #
  # @return [String]
  ACCESS_DENIED = "HTTP Basic: Access denied.\n"

  # @return [Proc]
  REFUSE_EVERYONE = ->(email:, password:) {}

  # @param app [#call] the downstream Rack app
  # @param issue_key [#call] receives the identity and `name:` (what the user
  #   called the key), `scopes:` (an Array of SCOPES entries) and `mfa:`
  #   (whether the user asked for the key to demand an OTP), and returns the
  #   plain-text key to hand the client — or nil to refuse. Storing the key so
  #   the TokenAuthorization block can find it again is up to it.
  # @param otp_gate [#call, nil] receives the identity and returns a
  #   Paquette::OtpGate (see GemServer.otp_gate) — or anything answering
  #   `verify(env)` the same way — to demand a one-time password from that
  #   user, or nil to let them sign in without one
  # @param realm [String] the realm in the Basic auth challenge
  # @yield [email:, password:] the username/email and password the client
  #   prompted for. The client asks for "Username/email", so `email:` is
  #   whatever the user typed there
  # @yieldreturn [Object, nil] an identity, or a falsy value to refuse. With no
  #   block given every sign-in is refused
  def initialize(app, issue_key:, otp_gate: nil, realm: "Paquette", &authenticator)
    @app = app
    @issue_key = issue_key
    @otp_gate = otp_gate
    @realm = realm
    @authenticator = authenticator || REFUSE_EVERYONE
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST"

    case env["PATH_INFO"]
    when API_KEY_PATH
      Measurometer.instrument("paquette.gem_server.sign_in") { sign_in(env) }
    when WEBAUTHN_VERIFICATION_PATH
      # Asked before the OTP prompt. Anything but a 2xx makes the client
      # fall back to "Code:", and rubygems.org says this to a user with no
      # security device
      text(422, "You don't have any security devices enabled")
    else
      @app.call(env)
    end
  end

  private

  # @param env [Hash]
  # @return [Array] a Rack response triplet
  def sign_in(env)
    auth = Rack::Auth::Basic::Request.new(env)
    return access_denied unless auth.provided? && auth.basic?

    # Base64 decodes to binary, and a binary "pässword" is not equal to the
    # UTF-8 one the application stored
    email, password = auth.credentials.map { |part| part.dup.force_encoding(Encoding::UTF_8) }
    identity = if email&.valid_encoding? && password&.valid_encoding?
      Measurometer.instrument("paquette.gem_server.sign_in.authenticate") do
        @authenticator.call(email: email, password: password)
      end
    end
    return access_denied unless identity

    # After the password, never before: an OTP prompt for a wrong password
    # would tell the caller the account exists
    if (gate = @otp_gate&.call(identity))
      outcome = gate.verify(env)
      unless outcome.authorized?
        Measurometer.increment_counter("paquette.gem_server.sign_in.#{outcome.reason}")
        return outcome.response
      end
    end

    params = Rack::Request.new(env).POST
    name = params["name"]
    unless name.is_a?(String) && !name.empty? && name.bytesize <= MAX_KEY_NAME_BYTES && name.valid_encoding?
      return text(422, "Name must be between 1 and #{MAX_KEY_NAME_BYTES} bytes")
    end

    scopes = SCOPES.select { |scope| params[scope] == "true" }
    return text(422, "Please enable at least one scope") if scopes.empty?

    key = @issue_key.call(identity, name: name, scopes: scopes, mfa: params["mfa"] == "true")
    if key.nil? || key.to_s.empty?
      Measurometer.increment_counter("paquette.gem_server.sign_in.refused")
      return text(403, "Not allowed to create an API key")
    end

    Measurometer.increment_counter("paquette.gem_server.sign_in.issued")
    text(200, key.to_s)
  rescue Rack::BadRequest, EOFError => e
    text(400, "Malformed request body: #{e.class}")
  end

  # @return [Array] a Rack response triplet
  def access_denied
    Measurometer.increment_counter("paquette.gem_server.sign_in.rejected")
    [401, {"content-type" => "text/plain", "www-authenticate" => %(Basic realm="#{@realm}"), "cache-control" => "no-store"}, [ACCESS_DENIED]]
  end

  # @param status [Integer]
  # @param message [String]
  # @return [Array] a Rack response triplet
  def text(status, message)
    [status, {"content-type" => "text/plain", "cache-control" => "no-store"}, [message]]
  end
end
