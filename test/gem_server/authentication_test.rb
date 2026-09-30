require_relative "../test_helper"
require "rotp"

# A GemServer built once — the way a rackup file builds it — with one
# authenticator serving every caller. Alice has a TOTP secret, Bob has none.
# `gem push` sends its key bare in Authorization and the code in the `OTP`
# header, and the two refusal sentences are the contract with the client,
# word for word.
class GemServerAuthenticationTest < Minitest::Test
  include Rack::Test::Methods

  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @dir = Dir.mktmpdir("paquette_gem_auth")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@dir)
    @authenticator = TestAuthenticator.new(
      tokens: {"alice-key" => :alice, "bob-key" => :bob},
      secrets: {alice: @secret}
    )
    @app = Paquette::GemServer.new(@repository, authenticator: @authenticator)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_an_unknown_key_is_refused
    push(key: "mallory-key")

    assert_equal 401, last_response.status
    assert_empty @repository.gem_names
  end

  def test_no_key_is_refused_unless_the_authenticator_has_a_guest
    get "/versions"
    assert_equal 401, last_response.status

    open_to_guests = Paquette::GemServer.new(@repository, authenticator: TestAuthenticator.new(guest: :guest))
    assert_equal 200, Rack::MockRequest.new(open_to_guests).get("/versions").status
  end

  # What Bundler sends for a source URL with the key in it.
  def test_bundler_s_basic_auth_is_read
    basic_authorize "alice-key", "x-oauth-basic"
    get "/versions"

    assert_equal 200, last_response.status
  end

  def test_a_push_with_a_live_code_goes_through
    push(key: "alice-key", otp: @totp.now)

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Successfully registered gem"
  end

  def test_a_push_without_a_code_gets_the_sentence_gem_push_prompts_on
    push(key: "alice-key")

    assert_equal 401, last_response.status
    assert_equal "You have enabled multifactor authentication", last_response.body
    assert_empty @repository.gem_names
  end

  def test_a_push_with_a_wrong_code_gets_the_sentence_gem_push_reports
    push(key: "alice-key", otp: "000000")

    assert_equal 401, last_response.status
    assert_equal "OTP verification failed", last_response.body
    assert_empty @repository.gem_names
  end

  # Same server object, different caller: the secret is per identity, not
  # per server.
  def test_a_caller_without_a_secret_pushes_without_a_code
    push(key: "bob-key")

    assert_equal 200, last_response.status
  end

  def test_npm_s_header_is_not_this_dialect
    push(key: "alice-key", headers: {"HTTP_NPM_OTP" => @totp.now})

    assert_equal "You have enabled multifactor authentication", last_response.body
  end

  def test_a_yank_is_a_write_too
    push(key: "alice-key", otp: @totp.now)

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}, {"HTTP_AUTHORIZATION" => "alice-key"}
    assert_equal 401, last_response.status

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"},
      {"HTTP_AUTHORIZATION" => "alice-key", "HTTP_OTP" => @totp.now}
    assert_equal 200, last_response.status
  end

  def test_reads_never_ask_for_a_code
    push(key: "alice-key", otp: @totp.now)
    header "Authorization", "alice-key"

    get "/info/minuscule_test"
    assert_equal 200, last_response.status

    get "/gems/minuscule_test-0.1.0.gem"
    assert_equal 200, last_response.status
  end

  # The check runs before the handler, so a refused push is refused without
  # its body ever being read — a client re-sends it with the code anyway.
  def test_a_refused_push_does_not_read_the_body
    body = Object.new
    def body.read(*) = raise("the body was read")
    def body.rewind = nil
    env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST",
      "CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => "alice-key")
    env["rack.input"] = body

    status, = app.call(env)
    assert_equal 401, status
  end

  def test_a_refusal_is_never_stored_by_a_cache
    push(key: "alice-key")

    assert_equal "private, no-store", last_response.headers["cache-control"]
  end

  # A user row with no secret set must not read as "OTP off".
  def test_an_empty_secret_is_a_configuration_error_not_a_pass
    @app = Paquette::GemServer.new(@repository,
      authenticator: TestAuthenticator.new(tokens: {"alice-key" => :alice}, secrets: {alice: ""}))

    assert_raises(ArgumentError) { push(key: "alice-key") }
    assert_empty @repository.gem_names
  end

  def test_without_an_authenticator_everything_is_open
    open = Paquette::GemServer.new(@repository)
    response = Rack::MockRequest.new(open).post("/api/v1/gems", :input => File.binread(MINUSCULE_FIXTURE),
      "CONTENT_TYPE" => "application/octet-stream")

    assert_equal 200, response.status
  end

  private

  def push(key: nil, otp: nil, headers: {})
    headers = headers.merge("CONTENT_TYPE" => "application/octet-stream")
    headers["HTTP_AUTHORIZATION"] = key if key
    headers["HTTP_OTP"] = otp if otp
    post "/api/v1/gems", File.binread(MINUSCULE_FIXTURE), headers
  end
end
