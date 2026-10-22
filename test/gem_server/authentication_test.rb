require_relative "../test_helper"
require "rotp"

# A GemServer with an authenticator. "pub-key" writes and has the TOTP secret,
# "lic-key" only reads, and anonymous callers read too. `gem push` sends its key
# bare in Authorization and the code in the `OTP` header, and the two refusal
# sentences are the contract with the client, word for word.
class GemServerAuthenticationTest < Minitest::Test
  include Rack::Test::Methods

  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @dir = Dir.mktmpdir("paquette_gem_auth")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@dir)
    @authenticator = TestAuthenticator.new(readers: [nil, "lic-key"], writers: ["pub-key"], otp_secret: @secret)
    @app = Paquette::GemServer.new(@repository, authenticator: @authenticator)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_an_unknown_key_is_refused
    header "Authorization", "mallory-key"
    get "/versions"

    assert_equal 401, last_response.status
    assert_equal %(Bearer realm="Paquette"), last_response.headers["www-authenticate"]
  end

  def test_anonymous_callers_read_when_the_authenticator_lets_nil_in
    get "/versions"
    assert_equal 200, last_response.status

    members_only = Paquette::GemServer.new(@repository, authenticator: TestAuthenticator.new(readers: ["lic-key"]))
    assert_equal 401, Rack::MockRequest.new(members_only).get("/versions").status
  end

  # A mangled header must not become an anonymous request
  def test_a_header_with_no_token_in_it_is_refused_without_asking
    header "Authorization", "Bearer"
    get "/versions"

    assert_equal 401, last_response.status
    assert_empty @authenticator.questions
    assert_equal "credentials_unreadable", last_request.env["paquette.authentication"]
  end

  def test_a_blank_header_is_anonymous
    header "Authorization", ""
    get "/versions"

    assert_equal 200, last_response.status
    assert_equal [[:read_permitted?, nil]], @authenticator.questions
  end

  # What Bundler sends for a source URL with the key in it
  def test_bundler_s_basic_auth_is_read
    basic_authorize "lic-key", "x-oauth-basic"
    get "/versions"

    assert_equal 200, last_response.status
    assert_equal [[:read_permitted?, "lic-key"]], @authenticator.questions
  end

  def test_an_unknown_path_is_refused_before_it_is_looked_up
    header "Authorization", "mallory-key"
    get "/no-such-thing"

    assert_equal 401, last_response.status
  end

  def test_a_push_with_a_live_code_goes_through
    push(key: "pub-key", otp: @totp.now)

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Successfully registered gem"
    assert_equal "authorized", last_request.env["paquette.authentication"]
  end

  def test_a_push_without_a_code_gets_the_sentence_gem_push_prompts_on
    push(key: "pub-key")

    assert_equal 401, last_response.status
    assert_equal "You have enabled multifactor authentication", last_response.body
    assert_empty @repository.gem_names
    refute @authenticator.questions.any? { |q, *| q == :check_otp! }, "a missing code is not the authenticator's to judge"
  end

  def test_an_empty_code_is_a_missing_one
    push(key: "pub-key", otp: "")

    assert_equal "You have enabled multifactor authentication", last_response.body
  end

  def test_a_push_with_a_wrong_code_gets_the_sentence_gem_push_reports
    push(key: "pub-key", otp: "000000")

    assert_equal 401, last_response.status
    assert_equal "OTP verification failed", last_response.body
    assert_empty @repository.gem_names
    assert_equal "otp_rejected", last_request.env["paquette.authentication"]
  end

  def test_the_authenticator_is_asked_in_order_with_the_token_and_the_code
    code = @totp.now
    push(key: "pub-key", otp: code)

    assert_equal [[:read_permitted?, "pub-key"], [:write_permitted?, "pub-key"], [:check_otp!, "pub-key", code]],
      @authenticator.questions
  end

  # Anything but OtpRejected is the authenticator's own failure, not a wrong code
  def test_other_errors_from_check_otp_propagate
    broken = Class.new(Paquette::Authentication::Open) do
      def check_otp!(code) = raise(IOError, "the database is gone")
    end
    server = Paquette::GemServer.new(@repository, authenticator: broken)

    assert_raises(IOError) do
      server.call(Rack::MockRequest.env_for("/api/v1/gems", :method => "POST", "HTTP_AUTHORIZATION" => "k", "HTTP_OTP" => "1"))
    end
  end

  def test_npm_s_header_is_not_this_dialect
    push(key: "pub-key", headers: {"HTTP_NPM_OTP" => @totp.now})

    assert_equal "You have enabled multifactor authentication", last_response.body
  end

  def test_a_reader_may_not_push
    push(key: "lic-key", otp: @totp.now)

    assert_equal 403, last_response.status
    assert_empty @repository.gem_names
  end

  # 401, not 403, so the client asks for credentials
  def test_an_anonymous_push_is_unauthorized
    push(otp: @totp.now)

    assert_equal 401, last_response.status
    refute_includes last_response.body, "multifactor"
  end

  def test_a_yank_is_a_write_too
    push(key: "pub-key", otp: @totp.now)

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}, {"HTTP_AUTHORIZATION" => "pub-key"}
    assert_equal 401, last_response.status

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}, {"HTTP_AUTHORIZATION" => "lic-key", "HTTP_OTP" => @totp.now}
    assert_equal 403, last_response.status

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"},
      {"HTTP_AUTHORIZATION" => "pub-key", "HTTP_OTP" => @totp.now}
    assert_equal 200, last_response.status
  end

  def test_reads_never_ask_for_a_code
    push(key: "pub-key", otp: @totp.now)
    header "Authorization", "lic-key"

    get "/info/minuscule_test"
    assert_equal 200, last_response.status

    get "/gems/minuscule_test-0.1.0.gem"
    assert_equal 200, last_response.status
  end

  # The checks run before the handler, so a refused push is refused without its
  # body ever being read - a client re-sends it with the code anyway
  def test_a_refused_push_does_not_read_the_body
    ["pub-key", "lic-key"].each do |key|
      body = Object.new
      def body.read(*) = raise("the body was read")
      def body.rewind = nil
      env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST",
        "CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => key)
      env["rack.input"] = body

      status, = app.call(env)
      assert_includes [401, 403], status
    end
  end

  def test_a_refusal_is_never_stored_by_a_cache
    push(key: "pub-key")

    assert_equal "private, no-store", last_response.headers["cache-control"]
  end

  def test_without_an_authenticator_everyone_reads_and_nobody_writes
    default = Rack::MockRequest.new(Paquette::GemServer.new(@repository))

    assert_equal 200, default.get("/versions").status
    response = default.post("/api/v1/gems", :input => File.binread(MINUSCULE_FIXTURE),
      "CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => "any", "HTTP_OTP" => ANY_OTP)
    assert_equal 403, response.status
    assert_empty @repository.gem_names
  end

  def test_the_open_authenticator_still_wants_a_code
    open = Rack::MockRequest.new(Paquette::GemServer.new(@repository, authenticator: OPEN_AUTHENTICATOR))

    response = open.post("/api/v1/gems", :input => File.binread(MINUSCULE_FIXTURE), "CONTENT_TYPE" => "application/octet-stream")
    assert_equal "You have enabled multifactor authentication", response.body

    response = open.post("/api/v1/gems", :input => File.binread(MINUSCULE_FIXTURE),
      "CONTENT_TYPE" => "application/octet-stream", "HTTP_OTP" => ANY_OTP)
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
