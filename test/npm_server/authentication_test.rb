require_relative "../test_helper"
require "rotp"

# An NpmServer with an authenticator. "pub-token" writes and has the TOTP
# secret, "lic-token" only reads. npm sends a Bearer token and the code in
# `npm-otp`, with the plain `OTP` header as the curl-user fallback, and a
# refusal must read as an OTP challenge to npm's client (the www-authenticate
# header and "one-time pass" in the body) or npm reports a failed login instead
# of prompting for a code.
class NpmServerAuthenticationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_npm_auth")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
    @authenticator = TestAuthenticator.new(readers: ["lic-token"], writers: ["pub-token"], otp_secret: @secret)
    @app = Paquette::NpmServer.new(@repository, authenticator: @authenticator)
    write_npm_package(@dir, name: "existing", version: "1.0.0")
    as("pub-token")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_an_unknown_token_is_refused
    as("mallory-token")
    get "/existing"

    assert_equal 401, last_response.status
    assert_equal %(Bearer realm="Paquette"), last_response.headers["www-authenticate"]
  end

  def test_no_token_is_refused_when_the_authenticator_does_not_let_nil_in
    header "Authorization", nil
    get "/existing"

    assert_equal 401, last_response.status
  end

  def test_whoami_answers_for_a_token
    as("lic-token")
    get "/-/whoami"

    assert_equal "paquette", JSON.parse(last_response.body)["username"]
  end

  def test_whoami_is_unauthorized_without_one
    anonymous = Paquette::NpmServer.new(@repository, authenticator: TestAuthenticator.new(readers: [nil]))
    response = Rack::MockRequest.new(anonymous).get("/-/whoami")

    assert_equal 401, response.status
  end

  def test_a_publish_with_a_live_code_goes_through
    publish("HTTP_NPM_OTP" => @totp.now)

    assert_equal 201, last_response.status
  end

  def test_a_publish_scripted_with_curl_and_a_plain_otp_header_goes_through
    publish("HTTP_OTP" => @totp.now)

    assert_equal 201, last_response.status
  end

  def test_npm_s_own_header_wins_when_both_are_present
    publish("HTTP_NPM_OTP" => @totp.now, "HTTP_OTP" => "000000")

    assert_equal 201, last_response.status
  end

  def test_a_publish_without_a_code_is_challenged
    publish

    assert_npm_challenge
    refute @repository.package_exists?("new-package", "1.0.0")
  end

  def test_a_wrong_code_is_challenged_again_rather_than_refused_flat
    publish("HTTP_NPM_OTP" => "000000")

    assert_npm_challenge
    refute @repository.package_exists?("new-package", "1.0.0")
  end

  def test_a_dist_tag_change_is_a_write
    put "/-/package/existing/dist-tags/beta", JSON.dump("1.0.0"), {"CONTENT_TYPE" => "application/json"}

    assert_npm_challenge
  end

  def test_an_unpublish_is_a_write
    delete "/existing/-rev/1-abc"

    assert_npm_challenge
    assert @repository.package_exists?("existing", "1.0.0")
  end

  def test_a_scoped_publish_is_a_write
    put "/@acme%2fwidget", npm_publish_body(name: "@acme/widget", version: "1.0.0"), {"CONTENT_TYPE" => "application/json"}

    assert_npm_challenge
  end

  def test_reads_never_ask_for_a_code
    get "/existing"
    assert_equal 200, last_response.status

    get "/existing/-/existing-1.0.0.tgz"
    assert_equal 200, last_response.status
  end

  # Refused outright rather than challenged: no code would make it go through
  def test_a_publish_by_a_reader_is_forbidden_not_challenged
    as("lic-token")
    publish("HTTP_NPM_OTP" => @totp.now)

    assert_equal 403, last_response.status
    refute_equal "OTP", last_response.headers["www-authenticate"]
    refute @repository.package_exists?("new-package", "1.0.0")
  end

  # npm's env is a copy with the scoped path rewritten; the outcome has to
  # land in the one the application holds
  def test_the_outcome_is_left_in_the_env_the_application_passed
    env = Rack::MockRequest.env_for("/existing", "HTTP_AUTHORIZATION" => "Bearer lic-token")
    app.call(env)

    assert_equal "authorized", env["paquette.authentication"]
  end

  def test_without_an_authenticator_everyone_reads_and_nobody_writes
    default = Rack::MockRequest.new(Paquette::NpmServer.new(@repository))

    assert_equal 200, default.get("/existing").status
    response = default.put("/new-package", :input => npm_publish_body(name: "new-package", version: "1.0.0"),
      "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer any", "HTTP_NPM_OTP" => ANY_OTP)
    assert_equal 403, response.status
  end

  private

  def as(token)
    header "Authorization", "Bearer #{token}"
  end

  def publish(headers = {})
    put "/new-package", npm_publish_body(name: "new-package", version: "1.0.0"),
      headers.merge("CONTENT_TYPE" => "application/json")
  end

  # Both marks, asserted together: neither client-side detection path may be
  # the only one
  def assert_npm_challenge
    assert_equal 401, last_response.status
    assert_equal "OTP", last_response.headers["www-authenticate"]
    assert_includes last_response.body, "one-time pass"
  end
end
