require "measurometer"

# How a server asks who is calling. It is built with an `authenticator:` - a
# factory answering `call(token)` with a Paquette::Authenticator for one
# request, which is what a subclass of that class is - and asks it once per
# request, with the token Paquette::AuthToken read out of the request, or nil
# when the caller sent no credentials. The instance is left in
# `env["paquette.authenticator"]` for the rest of the stack and for the
# application's own code.
#
# Every request asks `read_permitted?`, and a refusal is a 401. A write also
# asks `write_permitted?` (a 403 when a token was sent, a 401 when none was),
# and then needs a one-time password. A write without a code is answered with
# the prompt each client knows, without asking the authenticator - so
# `check_otp!` only ever sees a non-empty code. All of this happens before the
# handler, so a refused push is refused before its body is read.
#
# `identity` is only asked when a Paquette::ResponseCache in front wants to
# know, and only once `read_permitted?` has let the caller in.
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

  # Lets anyone read and write, and takes any code as the one-time password - a
  # write still has to carry one. For development and tests, never for a server
  # anyone else can reach.
  class Open < Paquette::Authenticator
    # @return [Boolean]
    def write_permitted?
      true
    end

    # @param code [String]
    # @return [void]
    def check_otp!(code)
    end
  end

  private

  # @param authenticator [#call, nil] the factory; nil is "everyone reads,
  #   nobody writes"
  # @return [void]
  # @raise [ArgumentError] for an object that is not a factory - an instance
  #   of the authenticator rather than its class, say
  def setup_authentication(authenticator)
    @authenticator_factory = authenticator || Paquette::Authenticator
    return if @authenticator_factory.respond_to?(:call)

    raise ArgumentError,
      "authenticator: must answer call(token) with an authenticator for one request - a subclass of " \
      "Paquette::Authenticator, or a lambda - not #{@authenticator_factory.inspect}"
  end

  # The refusal for this request, or nil to let it through. On the way, the
  # caller's authenticator is built and put in the env.
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
    outcome = if token.nil? && Paquette::AuthToken.provided?(env)
      # A mangled header must not become an anonymous request
      "credentials_unreadable"
    else
      authenticator = authenticator_for(env, token)
      authentication_outcome(route, authenticator, env)
    end
    env[OUTCOME_KEY] = outcome

    # A read let through is nearly every request, and not worth a counter
    if outcome == "authorized" && !route&.write?
      identify_for_response_cache(env, request_env, authenticator) if route
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

  # One per request. An authenticator already in the env - put there by
  # something in front of this server - is the caller's and is kept.
  #
  # @param env [Hash]
  # @param token [String, nil]
  # @return [Paquette::Authenticator]
  def authenticator_for(env, token)
    env[Paquette::Authenticator::ENV_KEY] ||= Measurometer.instrument("paquette.authentication.resolve") do
      @authenticator_factory.call(token)
    end
  end

  # @param route [Paquette::Routes::Route, nil]
  # @param authenticator [Paquette::Authenticator]
  # @param env [Hash] the Rack env
  # @return [String]
  def authentication_outcome(route, authenticator, env)
    return "read_refused" unless ask_authenticator(authenticator, :read_permitted?)
    return "authorized" unless route&.write?
    return "write_refused" unless ask_authenticator(authenticator, :write_permitted?)

    code = otp_code(env)
    # An empty code counts as missing, not as a wrong guess: a shell that
    # expanded nothing did not guess
    return "otp_missing" if code.nil? || code.empty?

    begin
      ask_authenticator(authenticator, :check_otp!, code)
      "authorized"
    rescue Paquette::OtpRejected
      "otp_rejected"
    end
  end

  # Tells a ResponseCache in front who the caller is, and revalidates against
  # what it holds for them. Only past the authenticator, so a stored body is
  # never matched to a caller that was not let in.
  #
  # @param env [Hash] the Rack env
  # @param request_env [Hash]
  # @param authenticator [Paquette::Authenticator]
  # @return [void]
  def identify_for_response_cache(env, request_env, authenticator)
    lookup = env[Paquette::ResponseCache::LOOKUP_KEY]
    return unless lookup && authenticator.token && authenticator.respond_to?(:identity)

    etag = lookup.identify(ask_authenticator(authenticator, :identity))
    request_env["HTTP_IF_NONE_MATCH"] = etag if etag
  end

  # The authenticator is the caller's, and it usually goes to a database to
  # resolve the token - before any of the work the request asked for.
  #
  # @param authenticator [Paquette::Authenticator]
  # @param question [Symbol]
  # @param args [Array]
  # @return [Object]
  def ask_authenticator(authenticator, question, *args)
    Measurometer.instrument("paquette.authentication.#{question.to_s.delete_suffix("?").delete_suffix("!")}") do
      authenticator.public_send(question, *args)
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
