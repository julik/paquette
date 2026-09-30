require_relative "../test_helper"
require "rotp"

# How `gem push` and `gem yank` speak OTP to a GemServer given an
# `otp_secret:` — the code arrives in the `OTP` header, and the two refusal
# sentences are the contract with the client, word for word.
class GemServerOtpTest < Minitest::Test
  include Rack::Test::Methods

  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @dir = Dir.mktmpdir("paquette_gem_otp")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@dir)
    @app = Paquette::GemServer.new(@repository, otp_secret: @secret)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_a_push_with_a_live_code_goes_through
    push(otp: @totp.now)

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Successfully registered gem"
  end

  def test_a_push_without_a_code_gets_the_sentence_gem_push_prompts_on
    push

    assert_equal 401, last_response.status
    assert_equal "You have enabled multifactor authentication", last_response.body
    assert_empty @repository.gem_names
  end

  def test_a_push_with_a_wrong_code_gets_the_sentence_gem_push_reports
    push(otp: "000000")

    assert_equal 401, last_response.status
    assert_equal "OTP verification failed", last_response.body
    assert_empty @repository.gem_names
  end

  def test_npm_s_header_is_not_this_dialect
    push(headers: {"HTTP_NPM_OTP" => @totp.now})

    assert_equal "You have enabled multifactor authentication", last_response.body
  end

  def test_a_yank_is_a_write_too
    push(otp: @totp.now)

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}
    assert_equal 401, last_response.status

    delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}, {"HTTP_OTP" => @totp.now}
    assert_equal 200, last_response.status
  end

  def test_reads_never_ask_for_a_code
    push(otp: @totp.now)

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
    env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST", "CONTENT_TYPE" => "application/octet-stream")
    env["rack.input"] = body

    status, = app.call(env)
    assert_equal 401, status
  end

  def test_a_refusal_is_never_stored_by_a_cache
    push

    assert_equal "private, no-store", last_response.headers["cache-control"]
  end

  def test_without_a_secret_a_push_needs_no_code
    @app = Paquette::GemServer.new(@repository)
    push

    assert_equal 200, last_response.status
  end

  private

  def push(otp: nil, headers: {})
    headers = headers.merge("CONTENT_TYPE" => "application/octet-stream")
    headers["HTTP_OTP"] = otp if otp
    post "/api/v1/gems", File.binread(MINUSCULE_FIXTURE), headers
  end
end
