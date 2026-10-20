require "measurometer"

# What both servers ask of the authenticator they are built with. It is any
# object answering three questions about a token:
#
#   read_permitted?(auth_token:)        # => Boolean
#   write_permitted?(auth_token:)       # => Boolean, for the whole registry
#   check_otp!(auth_token:, otp_code:)  # raises Paquette::OtpRejected on a wrong code
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
  # @rbs!
  #   # What an including server supplies: where the code travels, and the
  #   # refusals its client knows.
  #   private def otp_code: (Paquette::rack_env env) -> String?
  #   private def otp_missing: () -> Paquette::rack_response
  #   private def otp_rejected: () -> Paquette::rack_response
  #
  #   # The three questions a server asks of its authenticator.
  #   interface _Authenticator
  #     def read_permitted?: (auth_token: String?) -> boolish
  #     def write_permitted?: (auth_token: String?) -> boolish
  #     def check_otp!: (auth_token: String?, otp_code: String) -> void
  #   end

  # Where the outcome lands for the application's own log line: "authorized",
  # "credentials_unreadable", "read_refused", "write_refused", "otp_missing"
  # or "otp_rejected".
  OUTCOME_KEY = "paquette.authentication"

  # What a server built without an authenticator asks: everyone reads, nobody
  # writes. There is no secret to check a one-time password against.
  class ReadOnly
    #: (auth_token: String?) -> bool
    def read_permitted?(auth_token:)
      true
    end

    #: (auth_token: String?) -> bool
    def write_permitted?(auth_token:)
      false
    end

    # Raises `Paquette::OtpRejected` always.
    #
    #: (auth_token: String?, otp_code: String) -> void
    def check_otp!(auth_token:, otp_code:)
      raise Paquette::OtpRejected
    end
  end

  # Lets anyone read and write, and takes any code as the one-time password - a
  # write still has to carry one. For development and tests, never for a server
  # anyone else can reach.
  class Open
    #: (auth_token: String?) -> bool
    def read_permitted?(auth_token:)
      true
    end

    #: (auth_token: String?) -> bool
    def write_permitted?(auth_token:)
      true
    end

    #: (auth_token: String?, otp_code: String) -> void
    def check_otp!(auth_token:, otp_code:)
    end
  end

  private

  #: (Paquette::Authentication::_Authenticator? authenticator) -> void
  def setup_authentication(authenticator)
    @authenticator = authenticator || ReadOnly.new
  end

  # The refusal for this request, or nil to let it through.
  #
  # - `route`: nil when nothing matched - the caller is still asked about, so
  #   an unknown path does not tell a stranger which paths exist
  #
  # Returns a Rack response triplet.
  #
  #: (Paquette::Routes::Route? route, Paquette::rack_env env) -> Paquette::rack_response?
  def authentication_refusal(route, env)
    token = Paquette::AuthToken.from_env(env)
    outcome = authentication_outcome(route, token, env)
    env[OUTCOME_KEY] = outcome
    # A read let through is nearly every request, and not worth a counter
    unless outcome == "authorized" && !route&.write?
      Measurometer.increment_counter("paquette.authentication.#{outcome}")
    end

    case outcome
    when "credentials_unreadable", "read_refused" then unauthorized
    when "write_refused" then token ? forbidden : unauthorized
    when "otp_missing" then otp_missing
    when "otp_rejected" then otp_rejected
    end
  end

  #: (Paquette::Routes::Route? route, String? token, Paquette::rack_env env) -> String
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

  # The authenticator is the caller's, and it usually goes to a database to
  # resolve the token - before any of the work the request asked for.
  #
  #: (Symbol question, **untyped kwargs) -> untyped
  def ask_authenticator(question, **kwargs)
    Measurometer.instrument("paquette.authentication.#{question.to_s.delete_suffix("?").delete_suffix("!")}") do
      @authenticator.public_send(question, **kwargs)
    end
  end

  #: () -> Paquette::rack_response
  def unauthorized
    [401, {"Content-Type" => "text/plain", "www-authenticate" => %(Bearer realm="Paquette")}, ["Unauthorized"]]
  end

  #: () -> Paquette::rack_response
  def forbidden
    [403, {"Content-Type" => "text/plain"}, ["This token may not write to this registry"]]
  end
end
