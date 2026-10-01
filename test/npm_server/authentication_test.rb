require_relative "../test_helper"
require "rotp"

# An NpmServer built once with one authenticator serving every caller.
# Alice has a TOTP secret, Bob has none, and Carol is a licensee who reads
# through a gate and may not write. npm sends a Bearer token and the
# code in `npm-otp`, with the plain `OTP` header as the curl-user fallback,
# and a refusal must read as an OTP challenge to npm's client (the
# www-authenticate header and "one-time pass" in the body) or npm reports a
# failed login instead of prompting for a code.
class NpmServerAuthenticationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_npm_auth")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
    licensed = Paquette::NpmServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "existing" }
    @authenticator = TestAuthenticator.new(@repository,
      tokens: {"alice-token" => :alice, "bob-token" => :bob, "carol-token" => :carol},
      secrets: {alice: @secret},
      repositories: {carol: licensed})
    @app = Paquette::NpmServer.new(authenticator: @authenticator)
    write_npm_package(@dir, name: "existing", version: "1.0.0")
    as("alice-token")
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

  def test_whoami_names_the_identity_the_authenticator_resolved
    get "/-/whoami"

    assert_equal "alice", JSON.parse(last_response.body)["username"]
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

  def test_a_caller_without_a_secret_publishes_without_a_code
    as("bob-token")
    publish

    assert_equal 201, last_response.status
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

  def test_reads_never_ask_for_a_code
    get "/existing"
    assert_equal 200, last_response.status

    get "/existing/-/existing-1.0.0.tgz"
    assert_equal 200, last_response.status
  end

  def test_each_caller_is_served_from_the_repository_their_access_names
    write_npm_package(@dir, name: "unlicensed", version: "1.0.0")

    get "/unlicensed"
    assert_equal 200, last_response.status

    as("carol-token")
    get "/unlicensed"
    assert_equal 404, last_response.status
    get "/existing"
    assert_equal 200, last_response.status
  end

  # Refused outright rather than challenged: no code would make it go through
  def test_a_publish_to_a_read_only_stack_is_forbidden_not_challenged
    as("carol-token")
    publish

    assert_equal 403, last_response.status
    refute_equal "OTP", last_response.headers["www-authenticate"]
    refute @repository.package_exists?("new-package", "1.0.0")
  end

  # npm's env is a copy with the scoped path rewritten; the access has to
  # land in the one the application holds
  def test_the_access_is_left_in_the_env_the_application_passed
    env = Rack::MockRequest.env_for("/existing", "HTTP_AUTHORIZATION" => "Bearer carol-token")
    app.call(env)

    assert_equal "carol", env["paquette.access"].username
  end

  def test_a_repository_and_an_authenticator_are_one_or_the_other
    assert_raises(ArgumentError) { Paquette::NpmServer.new }
    assert_raises(ArgumentError) { Paquette::NpmServer.new(@repository, authenticator: @authenticator) }
  end

  def test_without_an_authenticator_everything_is_open
    open = Paquette::NpmServer.new(@repository)
    response = Rack::MockRequest.new(open).put("/new-package",
      :input => npm_publish_body(name: "new-package", version: "1.0.0"), "CONTENT_TYPE" => "application/json")

    assert_equal 201, response.status
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
  # the only one.
  def assert_npm_challenge
    assert_equal 401, last_response.status
    assert_equal "OTP", last_response.headers["www-authenticate"]
    assert_includes last_response.body, "one-time pass"
  end
end
