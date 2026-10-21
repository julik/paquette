require "measurometer"

# What the servers ask of the authenticator they are built with. It is any
# object answering three questions about a token, and optionally a fourth:
#
#   read_permitted?(auth_token:)        # => Boolean
#   write_permitted?(auth_token:)       # => Boolean, for the whole registry
#   check_otp!(auth_token:, otp_code:)  # raises Paquette::OtpRejected on a wrong code
#   identity(auth_token:)               # => String or nil, who the token belongs to
#
# `identity` is only asked when a Paquette::ResponseCache in front wants to
# know, and only about a token `read_permitted?` has just let in. It names a
# user or a license rather than the token, so entries survive a rotation.
#
# The token is the one Paquette::AuthToken reads, and nil when the caller sent
# no credentials - answering true to `read_permitted?` for nil is how a
# registry lets anonymous callers read.
#
# Every request asks `read_permitted?`, and a refusal is a 401. A write also
# asks `write_permitted?` (a 403 when a token was sent, a 401 when none was),
# and then needs a one-time password. A write without a code is answered with
# the prompt each client knows, without asking the authenticator - so
# `check_otp!` only ever sees a non-empty code. All of this happens before the
# handler, so a refused push is refused before its body is read.
#
# What is not shared - which header carries the code, what a refusal looks like
# on the wire - is each server's own, because the client on the other end
# dictates it: an including server defines `otp_code(env)`, `otp_missing` and
# `otp_rejected`.
module Paquette::Authentication
  # Where the outcome lands for the application's own log line: "authorized",
  # "credentials_unreadable", "read_refused", "write_refused", "otp_missing"
  # or "otp_rejected".
  #
  # @return [String]
  OUTCOME_KEY = "paquette.authentication"

  # What a server built without an authenticator asks: everyone reads, nobody
  # writes. There is no secret to check a one-time password against.
  class ReadOnly
    # @param auth_token [String, nil]
    # @return [Boolean]
    def read_permitted?(auth_token:)
      true
    end

    # @param auth_token [String, nil]
    # @return [Boolean]
    def write_permitted?(auth_token:)
      false
    end

    # @param auth_token [String, nil]
    # @param otp_code [String]
    # @raise [Paquette::OtpRejected] always
    # @return [void]
    def check_otp!(auth_token:, otp_code:)
      raise Paquette::OtpRejected
    end
  end

  # Lets anyone read and write, and takes any code as the one-time password - a
  # write still has to carry one. For development and tests, never for a server
  # anyone else can reach.
  class Open
    # @param auth_token [String, nil]
    # @return [Boolean]
    def read_permitted?(auth_token:)
      true
    end

    # @param auth_token [String, nil]
    # @return [Boolean]
    def write_permitted?(auth_token:)
      true
    end

    # @param auth_token [String, nil]
    # @param otp_code [String]
    # @return [void]
    def check_otp!(auth_token:, otp_code:)
    end
  end

  private

  # @param authenticator [Object, nil]
  # @return [void]
  def setup_authentication(authenticator)
    @authenticator = authenticator || ReadOnly.new
  end

  # The refusal for this request, or nil to let it through.
  #
  # @param route [Paquette::Routes::Route, nil] nil when nothing matched -
  #   the caller is still asked about, so an unknown path does not tell a
  #   stranger which paths exist
  # @param env [Hash] the Rack env
  # @param request_env [Hash] the env the handler will read, which some
  #   servers dup off the one they were given
  # @return [Array, nil] a Rack response triplet
  def authentication_refusal(route, env, request_env = env)
    token = Paquette::AuthToken.from_env(env)
    outcome = authentication_outcome(route, token, env)
    env[OUTCOME_KEY] = outcome
    # A read let through is nearly every request, and not worth a counter
    if outcome == "authorized" && !route&.write?
      identify_for_response_cache(env, request_env, token) if route
    else
      Measurometer.increment_counter("paquette.authentication.#{outcome}")
    end

    case outcome
    when "credentials_unreadable", "read_refused" then unauthorized
    when "write_refused" then token ? forbidden : unauthorized
    when "otp_missing" then otp_missing
    when "otp_rejected" then otp_rejected
    end
  end

  # @param route [Paquette::Routes::Route, nil]
  # @param token [String, nil]
  # @param env [Hash] the Rack env
  # @return [String]
  def authentication_outcome(route, token, env)
    # A mangled header must not become an anonymous request
    return "credentials_unreadable" if token.nil? && Paquette::AuthToken.provided?(env)
    return "read_refused" unless ask_authenticator(:read_permitted?, auth_token: token)
    return "authorized" unless route&.write?
    return "write_refused" unless ask_authenticator(:write_permitted?, auth_token: token)

    code = otp_code(env)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess
    return "otp_missing" if code.nil? || code.empty?

    begin
      ask_authenticator(:check_otp!, auth_token: token, otp_code: code)
      "authorized"
    rescue Paquette::OtpRejected
      "otp_rejected"
    end
  end

  # Tells a ResponseCache in front who the caller is, and revalidates against
  # what it holds for them. Only past the authenticator, so a stored body is
  # never matched to a token that was not let in.
  #
  # @param env [Hash] the Rack env
  # @param request_env [Hash]
  # @param token [String, nil]
  # @return [void]
  def identify_for_response_cache(env, request_env, token)
    lookup = env[Paquette::ResponseCache::LOOKUP_KEY]
    return unless lookup && token && @authenticator.respond_to?(:identity)

    etag = lookup.identify(ask_authenticator(:identity, auth_token: token))
    request_env["HTTP_IF_NONE_MATCH"] = etag if etag
  end

  # The authenticator is the caller's, and it usually goes to a database to
  # resolve the token - before any of the work the request asked for.
  #
  # @param question [Symbol]
  # @param kwargs [Hash]
  # @return [Object]
  def ask_authenticator(question, **kwargs)
    Measurometer.instrument("paquette.authentication.#{question.to_s.delete_suffix("?").delete_suffix("!")}") do
      @authenticator.public_send(question, **kwargs)
    end
  end

  # @return [Array] a Rack response triplet
  def unauthorized
    [401, {"Content-Type" => "text/plain", "www-authenticate" => %(Bearer realm="Paquette")}, ["Unauthorized"]]
  end

  # @return [Array] a Rack response triplet
  def forbidden
    [403, {"Content-Type" => "text/plain"}, ["This token may not write to this registry"]]
  end
end
