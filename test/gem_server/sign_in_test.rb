require_relative "../test_helper"
require "rotp"
require "securerandom"

# The requests `gem signin` makes, in the shape RubyGems' gemcutter_utilities
# builds them: Basic auth with what the user typed, a form body with the key
# name and one `scope=true` per scope, and the code in the `OTP` header once
# the server has asked for one.
class GemServerSignInTest < Minitest::Test
  include Rack::Test::Methods

  USERS = {"julik@example.com" => "hunter2", "mfa@example.com" => "s3cret"}

  def setup
    @gems_dir = Dir.mktmpdir("paquette_sign_in")
    @issued = {}
    @issue_calls = []
    @otp_secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@otp_secret, issuer: "test-registry")
    @authenticator = ->(email:, password:) { email if USERS[email] == password }
  end

  def teardown
    FileUtils.remove_entry(@gems_dir) if @gems_dir && File.exist?(@gems_dir)
  end

  def app
    issued = @issued
    issue_calls = @issue_calls
    authenticator = @authenticator
    otp_secret = @otp_secret
    issue_key = @issue_key || ->(user, name:, scopes:, mfa:) {
      issue_calls << {user: user, name: name, scopes: scopes, mfa: mfa}
      key = "rubygems_#{SecureRandom.hex(24)}"
      issued[key] = user
      key
    }
    otp_gate = ->(user) { Paquette::GemServer.otp_gate(secret: otp_secret, issuer: "test-registry") if user.start_with?("mfa@") }
    repo = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)

    Rack::Builder.new do
      use Paquette::GemServer::SignIn, issue_key: issue_key, otp_gate: otp_gate, &authenticator
      use Paquette::TokenAuthorization do |token|
        issued[token]
      end
      run Paquette::GemServer.new(repo)
    end
  end

  def test_signs_in_and_returns_the_plain_key_in_the_body
    sign_in("julik@example.com", "hunter2")

    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type
    assert_includes last_response.headers["cache-control"], "no-store"
    assert_equal "julik@example.com", @issued.fetch(last_response.body)
  end

  def test_hands_the_key_name_scopes_and_mfa_flag_to_issue_key
    sign_in("julik@example.com", "hunter2", name: "laptop-julik-20261009", scopes: %w[index_rubygems push_rubygem], mfa: true)

    assert_equal 200, last_response.status
    assert_equal [{user: "julik@example.com", name: "laptop-julik-20261009", scopes: %w[index_rubygems push_rubygem], mfa: true}], @issue_calls
  end

  def test_a_scope_sent_as_anything_but_true_is_not_granted
    post "/api/v1/api_key", "name=k&index_rubygems=true&push_rubygem=false&admin=true", basic_auth("julik@example.com", "hunter2")

    assert_equal %w[index_rubygems], @issue_calls.first[:scopes]
    refute @issue_calls.first[:mfa]
  end

  def test_the_issued_key_pushes_a_gem_the_way_gem_push_sends_it
    sign_in("julik@example.com", "hunter2", scopes: %w[push_rubygem])
    key = last_response.body

    gem_bytes = File.binread(File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem"))
    post "/api/v1/gems", gem_bytes, {"CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => key}

    assert_equal 200, last_response.status, last_response.body
    assert_equal "Successfully registered gem: minuscule_test-0.1.0", last_response.body
  end

  def test_a_made_up_key_does_not_push
    post "/api/v1/gems", "whatever", {"CONTENT_TYPE" => "application/octet-stream", "HTTP_AUTHORIZATION" => "rubygems_madeup"}

    assert_equal 401, last_response.status
  end

  def test_a_wrong_password_is_denied_with_a_basic_challenge
    sign_in("julik@example.com", "wrong")

    assert_equal 401, last_response.status
    assert_equal "HTTP Basic: Access denied.\n", last_response.body
    assert_equal 'Basic realm="Paquette"', last_response.headers["www-authenticate"]
    assert_empty @issue_calls
  end

  def test_an_unknown_user_is_denied
    sign_in("nobody@example.com", "hunter2")

    assert_equal 401, last_response.status
    assert_empty @issue_calls
  end

  def test_no_credentials_at_all_is_denied
    post "/api/v1/api_key", "name=k&index_rubygems=true"

    assert_equal 401, last_response.status
  end

  def test_a_bearer_token_is_not_a_sign_in
    post "/api/v1/api_key", "name=k&index_rubygems=true", {"HTTP_AUTHORIZATION" => "Bearer rubygems_abc"}

    assert_equal 401, last_response.status
  end

  def test_without_an_authenticator_every_sign_in_is_refused
    called = false
    middleware = Paquette::GemServer::SignIn.new(->(_env) { [200, {}, ["downstream"]] }, issue_key: ->(*, **) { called = true })
    env = Rack::MockRequest.env_for("/api/v1/api_key", :method => "POST", :input => "name=k&index_rubygems=true",
      "CONTENT_TYPE" => "application/x-www-form-urlencoded")
    env["HTTP_AUTHORIZATION"] = basic_auth("julik@example.com", "hunter2").fetch("HTTP_AUTHORIZATION")

    status, _, _ = middleware.call(env)

    assert_equal 401, status
    refute called
  end

  def test_a_user_with_mfa_is_asked_for_the_otp_in_the_words_the_client_recognizes
    sign_in("mfa@example.com", "s3cret")

    assert_equal 401, last_response.status
    # gemcutter_utilities' mfa_unauthorized? matches this prefix and nothing else
    assert last_response.body.start_with?("You have enabled multifactor authentication")
    assert_empty @issue_calls
  end

  def test_a_user_with_mfa_and_a_wrong_otp_is_refused
    sign_in("mfa@example.com", "s3cret", otp: "000000")

    assert_equal 401, last_response.status
    assert_equal "OTP verification failed", last_response.body
    assert_empty @issue_calls
  end

  def test_a_user_with_mfa_and_a_live_otp_gets_a_key
    sign_in("mfa@example.com", "s3cret", otp: @totp.now)

    assert_equal 200, last_response.status
    assert_equal "mfa@example.com", @issued.fetch(last_response.body)
  end

  def test_a_wrong_password_never_reaches_the_otp_prompt
    sign_in("mfa@example.com", "wrong")

    assert_equal 401, last_response.status
    assert_equal "HTTP Basic: Access denied.\n", last_response.body # no hint that the account exists
  end

  def test_the_webauthn_probe_is_refused_so_the_client_prompts_for_a_code
    post "/api/v1/webauthn_verification", "", basic_auth("mfa@example.com", "s3cret")

    assert_equal 422, last_response.status
    refute last_response.body.start_with?("You have enabled multifactor authentication")
  end

  def test_no_scopes_is_refused_the_way_rubygems_org_refuses_it
    sign_in("julik@example.com", "hunter2", scopes: [])

    assert_equal 422, last_response.status
    assert_equal "Please enable at least one scope", last_response.body
    assert_empty @issue_calls
  end

  def test_a_missing_or_oversized_name_is_refused
    post "/api/v1/api_key", "index_rubygems=true", basic_auth("julik@example.com", "hunter2")
    assert_equal 422, last_response.status

    sign_in("julik@example.com", "hunter2", name: "n" * 256)
    assert_equal 422, last_response.status

    post "/api/v1/api_key", "name=%FF&index_rubygems=true", basic_auth("julik@example.com", "hunter2")
    assert_equal 422, last_response.status
    assert_empty @issue_calls
  end

  def test_issue_key_returning_nil_refuses_the_sign_in
    @issue_key = ->(*, **) {}
    sign_in("julik@example.com", "hunter2")

    assert_equal 403, last_response.status
  end

  def test_a_malformed_body_is_a_bad_request_not_a_crash
    post "/api/v1/api_key", "name[]=a&name[b]=c", basic_auth("julik@example.com", "hunter2")

    assert_equal 400, last_response.status
  end

  def test_a_name_sent_as_an_array_is_refused
    post "/api/v1/api_key", "name[]=a&index_rubygems=true", basic_auth("julik@example.com", "hunter2")

    assert_equal 422, last_response.status
    assert_empty @issue_calls
  end

  def test_non_ascii_credentials_arrive_as_utf8
    @authenticator = ->(email:, password:) { email if email == "jülik@example.com" && password == "pässword" }
    sign_in("jülik@example.com", "pässword")

    assert_equal 200, last_response.status
  end

  def test_credentials_that_are_not_utf8_are_denied_without_asking_the_authenticator
    @authenticator = ->(email:, password:) { flunk "authenticator called with #{email.inspect}" }
    post "/api/v1/api_key", "name=k&index_rubygems=true", {
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "HTTP_AUTHORIZATION" => "Basic #{["\xFF:pw".b].pack("m0")}"
    }

    assert_equal 401, last_response.status
  end

  def test_a_password_containing_a_colon_survives_basic_auth
    @authenticator = ->(email:, password:) { email if password == "a:b:c" }
    sign_in("julik@example.com", "a:b:c")

    assert_equal 200, last_response.status
  end

  def test_everything_else_passes_through_to_the_wrapped_app
    get "/api/v1/api_key"
    assert_equal 401, last_response.status
    assert_equal 'Bearer realm="Paquette"', last_response.headers["www-authenticate"]

    sign_in("julik@example.com", "hunter2")
    get "/api/v1/names", {}, {"HTTP_AUTHORIZATION" => last_response.body}
    assert_equal 200, last_response.status
  end

  def test_mounted_under_a_prefix_it_answers_the_prefixed_path
    inner = app
    mounted = Rack::Builder.new { map("/@acme") { run inner } }
    status, _, body = mounted.call(Rack::MockRequest.env_for("/@acme/api/v1/api_key", :method => "POST",
      :input => "name=k&index_rubygems=true", "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "HTTP_AUTHORIZATION" => basic_auth("julik@example.com", "hunter2").fetch("HTTP_AUTHORIZATION")))

    assert_equal 200, status
    assert @issued.key?(body.to_enum(:each).to_a.join)
  end

  private

  def sign_in(email, password, name: "host-user-20261009120000", scopes: %w[index_rubygems], mfa: false, otp: nil)
    form = {name: name}
    scopes.each { |scope| form[scope] = true }
    form["mfa"] = true if mfa
    headers = basic_auth(email, password)
    headers["HTTP_OTP"] = otp if otp
    post "/api/v1/api_key", URI.encode_www_form(form), headers
  end

  def basic_auth(email, password)
    {
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "HTTP_AUTHORIZATION" => "Basic #{["#{email}:#{password}"].pack("m0")}"
    }
  end
end
