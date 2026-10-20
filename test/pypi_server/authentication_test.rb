require_relative "../test_helper"
require "rotp"

# A PypiServer with an authenticator. "pub-token" writes and has the TOTP
# secret, "lic-token" only reads. twine sends Basic auth and nothing else,
# so the code rides in the username: `twine upload -u 123456 -p pub-token`.
class PypiServerAuthenticationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_pypi_auth")
    @secret = ROTP::Base32.random
    @totp = ROTP::TOTP.new(@secret)
    @repository = Paquette::PypiServer::DirectoryPypiRepository.new(@dir)
    @authenticator = TestAuthenticator.new(readers: ["lic-token"], writers: ["pub-token"], otp_secret: @secret)
    @app = Paquette::PypiServer.new(@repository, authenticator: @authenticator)
    write_wheel(@dir, name: "existing", version: "1.0.0")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_a_reader_reads_with_the_pypi_token_username
    basic_authorize("__token__", "lic-token")
    get "/simple/existing/"

    assert_equal 200, last_response.status
  end

  def test_a_reader_reads_with_the_token_as_the_username
    basic_authorize("lic-token", "")
    get "/simple/existing/"

    assert_equal 200, last_response.status
  end

  # Basic is the only challenge pip will answer with credentials
  def test_an_anonymous_read_is_challenged_with_basic
    get "/simple/existing/"

    assert_equal 401, last_response.status
    assert_equal %(Basic realm="Paquette"), last_response.headers["www-authenticate"]
  end

  def test_an_upload_with_the_code_as_the_username_goes_through
    basic_authorize(@totp.now, "pub-token")
    upload

    assert_equal 200, last_response.status, last_response.body
    assert_equal [:check_otp!, "pub-token", @totp.now], @authenticator.questions.last
  end

  def test_an_upload_with_the_code_in_the_otp_header_goes_through
    basic_authorize("__token__", "pub-token")
    header "OTP", @totp.now
    upload

    assert_equal 200, last_response.status, last_response.body
  end

  def test_an_upload_without_a_code_is_told_how_to_send_one
    basic_authorize("__token__", "pub-token")
    upload

    assert_equal 401, last_response.status
    assert_includes last_response.body, "twine upload -u 123456 -p TOKEN"
    assert_equal "otp_missing", last_request.env[Paquette::Authentication::OUTCOME_KEY]
    refute_path_exists File.join(@dir, "widgets")
  end

  def test_an_upload_with_a_wrong_code_is_refused
    basic_authorize(((@totp.now.to_i + 1) % 1_000_000).to_s.rjust(6, "0"), "pub-token")
    upload

    assert_equal 401, last_response.status
    assert_equal "otp_rejected", last_request.env[Paquette::Authentication::OUTCOME_KEY]
  end

  def test_a_reader_may_not_upload
    basic_authorize(@totp.now, "lic-token")
    upload

    assert_equal 403, last_response.status
    refute_path_exists File.join(@dir, "widgets")
  end

  def test_an_anonymous_upload_is_unauthorized
    upload

    assert_equal 401, last_response.status
  end

  # The refusal comes before the body is parsed, never after it is stored
  def test_a_refused_upload_never_reaches_the_repository
    repository = Object.new
    def repository.add_file(*)
      raise "the upload reached the repository"
    end
    server = Paquette::PypiServer.new(repository, authenticator: @authenticator)
    env = Rack::MockRequest.env_for("/legacy/", :method => "POST", :input => "garbage",
      "HTTP_AUTHORIZATION" => "Basic #{["__token__:lic-token"].pack("m0")}")

    status, = server.call(env)
    assert_equal 403, status
  end

  private

  def upload
    bytes = wheel_bytes(name: "widgets", version: "1.0.0")
    file = Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream", true,
      original_filename: "widgets-1.0.0-py3-none-any.whl")
    post "/legacy/", {":action" => "file_upload", "protocol_version" => "1", "content" => file}
  end
end
