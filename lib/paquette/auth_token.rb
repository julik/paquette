require "rack/auth/abstract/request"

# Reads the access token out of a request, whichever way the client wrapped it.
# This is the token an authenticator gets:
#
#   Authorization: <token>                          # `gem push`, `gem yank`, `gem owner`
#   Authorization: Bearer <token>                   # npm
#   Authorization: Basic base64("<token>:")         # Bundler, any password ignored
#   Authorization: Basic base64("x-oauth-basic:<token>")
#   Authorization: Basic base64("__token__:<token>")  # pip and twine, the PyPI convention
#   Authorization: Basic base64("123456:<token>")     # twine with a one-time password
#
# Some HTTP clients refuse to send an empty password, which is where the
# placeholders come from - GitHub documents them both ways round.
module Paquette::AuthToken
  BEARER_SENTINEL = "x-oauth-token"

  # Basic auth usernames that say "the token is in the password".
  USERNAME_SENTINELS = ["x-oauth-basic", "x-access-token", BEARER_SENTINEL, "__token__"].freeze #: Array[String]

  # twine can send nothing but a username and a password, so on a PyPI upload
  # the username is where the one-time password rides
  OTP_USERNAME = /\A[0-9]{6,8}\z/

  # A lone `Authorization: Bearer` is a client with nothing to send, not a
  # bare key that happens to read "Bearer"
  SCHEMES = ["bearer", "basic"].freeze #: Array[String]

  # Whether the request carries credentials at all. With some that yield no
  # token, the caller meant to authenticate and did not manage to - which is
  # not the same as anonymous. A blank header is no credentials: some proxies
  # and HTTP libraries send one for nothing.
  #
  #: (Paquette::rack_env env) -> bool
  def self.provided?(env)
    auth = Rack::Auth::AbstractRequest.new(env)
    auth.provided? && auth.parts.any? { |part| !part.empty? }
  end

  # Always valid UTF-8: a token in any other bytes is no token, so nothing an
  # authenticator does with it - a regexp, a lookup, a log line - can raise on
  # it. Puma hands headers over as binary, and a Basic payload decodes to
  # whatever bytes the client encoded.
  #
  # Returns the token, or nil when there is none to be had.
  #
  #: (Paquette::rack_env env) -> String?
  def self.from_env(env)
    auth = Rack::Auth::AbstractRequest.new(env)
    return nil unless auth.provided?

    token = case auth.parts.length
    when 1
      bare = auth.parts.first
      bare unless SCHEMES.include?(bare.downcase)
    when 2
      case auth.scheme
      when "bearer" then auth.params
      when "basic" then from_basic(auth.params)
      end
    end
    return nil if token.nil? || token.empty?

    token = token.dup.force_encoding(Encoding::UTF_8)
    token if token.valid_encoding?
  rescue ArgumentError # invalid UTF-8 in the header refuses `downcase`
    nil
  end

  # The one-time password a Basic username carries - see OTP_USERNAME.
  #
  #: (Paquette::rack_env env) -> String?
  def self.otp_from_env(env)
    auth = Rack::Auth::AbstractRequest.new(env)
    return nil unless auth.provided? && auth.parts.length == 2 && auth.scheme == "basic"

    username, password = auth.params.unpack1("m").split(":", 2)
    username if otp_username?(username, password)
  rescue ArgumentError
    nil
  end

  # The password next to a token username carries no secret, so it is not
  # looked at - `TOKEN:x-oauth-basic` is what GitHub's docs teach.
  #
  # - `encoded`: the base64 Basic credentials
  #
  #: (String encoded) -> String?
  def self.from_basic(encoded)
    decoded = encoded.unpack1("m") #: String
    username, password = decoded.split(":", 2)
    if username.nil? || username.empty? || USERNAME_SENTINELS.include?(username) || otp_username?(username, password)
      password
    else
      username
    end
  end
  private_class_method :from_basic

  # A token that happens to be all digits still works the GitHub way round,
  # `123456:x-oauth-basic`, and on its own with no password at all
  #
  #: (String? username, String? password) -> bool
  def self.otp_username?(username, password)
    return false if password.nil? || password.empty? || USERNAME_SENTINELS.include?(password)

    OTP_USERNAME.match?(username.to_s)
  end
  private_class_method :otp_username?
end
