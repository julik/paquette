require_relative "../test_helper"
require "rotp"

# A GemServer built once — the way a rackup file builds it — with one
# authenticator serving every caller. Alice has a TOTP secret, Bob has none,
# and Carol is a licensee who reads through a gate and may not write.
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
    licensed = Paquette::GemServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "minuscule_test" }
    @authenticator = TestAuthenticator.new(@repository,
      tokens: {"alice-key" => :alice, "bob-key" => :bob, "carol-key" => :carol},
      secrets: {alice: @secret},
      repositories: {carol: licensed})
    @app = Paquette::GemServer.new(authenticator: @authenticator)
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

    open_to_guests = Paquette::GemServer.new(authenticator: TestAuthenticator.new(@repository, guest: :guest))
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

  # One server, two stacks: the publisher writes, the licensee reads what
  # their gate lets through
  def test_each_caller_is_served_from_the_repository_their_access_names
    push(key: "bob-key")
    post "/api/v1/gems", File.binread(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.1.gem")),
      {"CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => "bob-key"}

    header "Authorization", "bob-key"
    get "/names"
    assert_includes last_response.body, "zip_kit"

    header "Authorization", "carol-key"
    get "/names"
    assert_includes last_response.body, "minuscule_test"
    refute_includes last_response.body, "zip_kit"
  end

  # A caller who may not write learns so before uploading the gem, and is
  # not asked for a code they have no use for
  def test_a_push_to_a_read_only_stack_is_refused_before_the_body_is_read
    body = Object.new
    def body.read(*) = raise("the body was read")
    def body.rewind = nil
    env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST",
      "CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => "carol-key")
    env["rack.input"] = body

    status, _, response_body = app.call(env)
    assert_equal 403, status
    refute_includes response_body.join, "multifactor"
  end

  def test_a_yank_from_a_read_only_stack_is_refused
    push(key: "bob-key")

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}, {"HTTP_AUTHORIZATION" => "carol-key"}
    assert_equal 403, last_response.status
    assert_equal ["minuscule_test"], @repository.gem_names
  end

  # The application may read the access the server resolved, for its own
  # log line
  def test_the_access_is_left_in_the_env
    env = Rack::MockRequest.env_for("/versions", "HTTP_AUTHORIZATION" => "carol-key")
    app.call(env)

    assert_equal "carol", env["paquette.access"].username
  end

  def test_a_repository_and_an_authenticator_are_one_or_the_other
    assert_raises(ArgumentError) { Paquette::GemServer.new }
    assert_raises(ArgumentError) { Paquette::GemServer.new(@repository, authenticator: @authenticator) }
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
