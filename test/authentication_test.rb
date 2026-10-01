require_relative "test_helper"

# The protocol-neutral half of authentication: reading a token out of
# whichever scheme carried it, and resolving it once per request. How each server
# refuses is tested beside that server.
class AuthenticationTest < Minitest::Test
  TOKEN = "pqt_test_token_for_auth_checks_abc123z"

  def setup
    @authenticator = TestAuthenticator.new(:repository, tokens: {TOKEN => :acme})
  end

  def test_token_in_reads_a_bearer_token
    assert_equal TOKEN, Paquette::Authentication.token_in(env_for(bearer: TOKEN))
  end

  # What Bundler sends for `https://TOKEN:x-oauth-basic@host`. Reading the
  # raw Authorization header instead gets "Basic dG9r...", which is what
  # our own Rails guide used to do.
  def test_token_in_reads_a_token_riding_in_the_basic_username
    ["", "x-oauth-basic", "x-oauth-token"].each do |password|
      assert_equal TOKEN, Paquette::Authentication.token_in(env_for(basic: [TOKEN, password])), password
    end
  end

  # `gem push` and `gem yank` put the API key in the header as it is.
  def test_token_in_reads_the_bare_key_gem_push_sends
    env = env_for
    env["HTTP_AUTHORIZATION"] = TOKEN
    assert_equal TOKEN, Paquette::Authentication.token_in(env)
  end

  def test_token_in_is_nil_without_credentials
    assert_nil Paquette::Authentication.token_in(env_for)
  end

  def test_token_in_is_nil_for_a_basic_login_with_a_real_password
    assert_nil Paquette::Authentication.token_in(env_for(basic: [TOKEN, "hunter2"]))
  end

  def test_token_in_is_nil_for_a_scheme_it_does_not_speak
    env = env_for
    env["HTTP_AUTHORIZATION"] = "Digest username=\"x\""
    assert_nil Paquette::Authentication.token_in(env)
  end

  def test_token_in_survives_a_basic_payload_that_is_not_utf8
    env = env_for
    env["HTTP_AUTHORIZATION"] = "Basic #{["\xFF\xE2:".b].pack("m0")}"
    assert_equal "\xFF\xE2".b, Paquette::Authentication.token_in(env)
  end

  def test_access_stores_the_access_in_the_env
    env = env_for(bearer: TOKEN)
    access = Paquette::Authentication.access(env, @authenticator)

    assert_equal "acme", access.username
    assert_same access, env["paquette.access"]
  end

  # The authenticator gets the request too - the client IP for an audit
  # trail, say
  def test_the_authenticator_is_handed_the_request
    env = env_for(bearer: TOKEN)
    Paquette::Authentication.access(env, @authenticator)

    _token, request = @authenticator.requests.first
    assert_kind_of Rack::Request, request
    assert_same env, request.env
  end

  # The application asks to build its gate, the server asks again: one
  # lookup between them.
  def test_access_asks_the_authenticator_once_per_request
    env = env_for(bearer: TOKEN)
    2.times { Paquette::Authentication.access(env, @authenticator) }

    assert_equal [TOKEN], @authenticator.requests.map(&:first)
  end

  def test_a_refusal_is_remembered_too
    env = env_for(bearer: "nope")
    2.times { assert_nil Paquette::Authentication.access(env, @authenticator) }

    assert_equal ["nope"], @authenticator.requests.map(&:first)
  end

  # No credentials at all is the authenticator's call: an access for a
  # guest is how anonymous callers get in.
  def test_no_credentials_asks_the_authenticator_with_nil
    guest_friendly = TestAuthenticator.new(:repository, guest: :guest)

    assert_equal "guest", Paquette::Authentication.access(env_for, guest_friendly).username
    assert_equal [nil], guest_friendly.requests.map(&:first)
  end

  # A mangled header must not become an anonymous session, however friendly
  # the authenticator is to guests.
  def test_credentials_with_no_usable_token_are_refused_without_asking
    guest_friendly = TestAuthenticator.new(:repository, guest: :guest)

    assert_nil Paquette::Authentication.access(env_for(basic: [TOKEN, "hunter2"]), guest_friendly)
    assert_empty guest_friendly.requests
  end

  def test_a_repository_that_never_heard_of_writable_is_writable
    assert Paquette::Authentication.writable?(Object.new)
    assert Paquette::Authentication.writable?(Paquette::GemServer::DirectoryGemRepository.allocate)
    refute Paquette::Authentication.writable?(Paquette::GemServer::ReadonlyRepository.new(Object.new))
    refute Paquette::Authentication.writable?(Paquette::NpmServer::ReadGatedRepository.new(Object.new) { true })
  end

  private

  def env_for(bearer: nil, basic: nil)
    env = Rack::MockRequest.env_for("/")
    if bearer
      env["HTTP_AUTHORIZATION"] = "Bearer #{bearer}"
    elsif basic
      env["HTTP_AUTHORIZATION"] = "Basic #{["#{basic[0]}:#{basic[1]}"].pack("m0")}"
    end
    env
  end
end
