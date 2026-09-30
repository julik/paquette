require_relative "../test_helper"
require "rotp"

# How npm speaks OTP to an NpmServer given an `otp_secret:` — the code
# arrives in `npm-otp`, with the plain `OTP` header as the curl-user
# fallback, and a refusal must read as an OTP challenge to npm's client
# (the www-authenticate header and "one-time pass" in the body) or npm
# reports a failed login instead of prompting for a code.
class NpmServerOtpTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_npm_otp")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
    @app = Paquette::NpmServer.new(@repository, otp_secret: @secret)
    write_npm_package(@dir, name: "existing", version: "1.0.0")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

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

  def test_reads_never_ask_for_a_code
    get "/existing"
    assert_equal 200, last_response.status

    get "/existing/-/existing-1.0.0.tgz"
    assert_equal 200, last_response.status

    get "/-/whoami"
    assert_equal 200, last_response.status
  end

  def test_without_a_secret_a_publish_needs_no_code
    @app = Paquette::NpmServer.new(@repository)
    publish

    assert_equal 201, last_response.status
  end

  private

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
