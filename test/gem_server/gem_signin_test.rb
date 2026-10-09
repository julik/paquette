require_relative "../test_helper"
require "puma"
require "puma/server"
require "io/wait"
require "rotp"
require "rubygems/gemcutter_utilities"
require "securerandom"
require "tmpdir"

# The real `gem signin` against a live server, answering its prompts the way
# a person would, and then the real `gem push` with the key it stored. The
# client only asks for a password when its stdin is a terminal, so it gets
# a PTY rather than a pipe.
#
# The host goes in RUBYGEMS_HOST as well as --host. With --host alone the
# client still believes it talks to rubygems.org, and sends the password to
# rubygems.org's /api/v1/profile/me.yaml before it ever gets here.
class GemSigninTest < Minitest::Test
  PROMPT_TIMEOUT = 20 # seconds, per prompt

  def setup
    begin
      require "pty"
    rescue LoadError
      skip "PTY is not available on this platform"
    end

    @tmpdir = Dir.mktmpdir("paquette_gem_signin")
    @home = File.join(@tmpdir, "home")
    FileUtils.mkdir_p(@home)
    gems_dir = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(gems_dir)

    @otp_secret = ROTP::Base32.random
    @issued = {}
    @issue_calls = []
    issued = @issued
    issue_calls = @issue_calls
    otp_secret = @otp_secret
    repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

    app = Rack::Builder.new do
      use Paquette::GemServer::SignIn,
        otp_gate: ->(user) { Paquette::GemServer.otp_gate(secret: otp_secret, issuer: "test") if user == "mfa@example.com" },
        issue_key: ->(user, name:, scopes:, mfa:) {
          issue_calls << {user: user, name: name, scopes: scopes, mfa: mfa}
          "rubygems_#{SecureRandom.hex(24)}".tap { |key| issued[key] = {user: user, scopes: scopes} }
        } do |email:, password:|
        email if {"julik@example.com" => "hunter2", "mfa@example.com" => "s3cret"}[email] == password
      end
      use Paquette::TokenAuthorization do |token|
        issued[token]
      end
      run Paquette::GemServer.new(repo)
    end

    @server = Puma::Server.new(app)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
    @host = "http://127.0.0.1:#{@port}"
  end

  def teardown
    @server&.stop(true)
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_gem_signin_stores_a_key_that_gem_push_then_uses
    transcript = gem_signin do |session|
      session.answer("Username/email:", "julik@example.com")
      session.answer("Password:", "hunter2")
      session.answer("API Key name", "paquette-test-key")
      answer_scopes(session, %w[index_rubygems push_rubygem])
      session.expect("Signed in with API key: paquette-test-key")
    end

    assert_equal [{user: "julik@example.com", name: "paquette-test-key", scopes: %w[index_rubygems push_rubygem], mfa: false}],
      @issue_calls, transcript

    key = @issued.keys.first
    assert_includes File.read(credentials_path), key, "the client did not store the key it was given"

    output, status = gem_command("push", "--host", @host, File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem"))
    assert status.success?, output
    assert_includes output, "Successfully registered gem: minuscule_test-0.1.0"
  end

  def test_gem_signin_asks_for_the_otp_and_retries_with_it
    transcript = gem_signin do |session|
      session.answer("Username/email:", "mfa@example.com")
      session.answer("Password:", "s3cret")
      session.answer("API Key name", "")
      answer_scopes(session, nil)
      session.answer("Code:", ROTP::TOTP.new(@otp_secret, issuer: "test").now)
      session.expect("Signed in with API key:")
    end

    assert_equal 1, @issue_calls.length, transcript
    assert_equal %w[index_rubygems], @issue_calls.first[:scopes]
    assert_includes File.read(credentials_path), @issued.keys.first
  end

  def test_gem_signin_with_a_wrong_password_stores_nothing
    transcript = gem_signin(expect_success: false) do |session|
      session.answer("Username/email:", "julik@example.com")
      session.answer("Password:", "wrong")
      session.answer("API Key name", "")
      answer_scopes(session, nil)
      session.expect("HTTP Basic: Access denied.")
    end

    assert_empty @issue_calls, transcript
    refute File.exist?(credentials_path)
  end

  private

  # nil keeps the client's default scope, index_rubygems
  def answer_scopes(session, scopes)
    session.answer("Do you want to customise scopes?", scopes ? "y" : "n")
    return unless scopes

    Gem::GemcutterUtilities::EXCLUSIVELY_API_SCOPES.each { |scope| session.answer(scope.to_s, "n") }
    Gem::GemcutterUtilities::API_SCOPES.each do |scope|
      session.answer(scope.to_s, scopes.include?(scope.to_s) ? "y" : "n")
    end
  end

  # Waits for each prompt in turn and types the answer, keeping what the
  # client printed for the failure message.
  class Session
    attr_reader :transcript

    def initialize(reader, writer)
      @reader = reader
      @writer = writer
      @transcript = +""
      @unread = +""
    end

    def expect(text)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROMPT_TIMEOUT
      until @unread.include?(text)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Minitest::Assertion, "Timed out waiting for #{text.inspect}, got:\n#{@transcript}" if remaining <= 0
        next unless @reader.wait_readable(remaining)

        chunk = @reader.readpartial(4096)
        @transcript << chunk
        @unread << chunk
      end
      # Only what came after the prompt counts towards the next one
      @unread = @unread.split(text, 2).last
    rescue EOFError, Errno::EIO
      raise Minitest::Assertion, "gem exited while waiting for #{text.inspect}, got:\n#{@transcript}"
    end

    def answer(prompt, reply)
      expect(prompt)
      @writer.write("#{reply}\n")
    end
  end

  def gem_signin(expect_success: true)
    session = nil
    PTY.spawn(client_env, "gem", "signin", "--host", @host, unsetenv_others: true) do |reader, writer, pid|
      session = Session.new(reader, writer)
      begin
        yield session
      ensure
        # A failed expectation leaves the client sitting at a prompt
        unless wait_for_exit(pid)
          Process.kill("KILL", pid)
          Process.wait(pid)
        end
      end
    end
    assert_equal expect_success, $?.success?, session.transcript
    session.transcript
  end

  def wait_for_exit(pid, seconds = 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return true if Process.waitpid(pid, Process::WNOHANG)
      sleep 0.05
    end
    false
  end

  def gem_command(*args)
    output = IO.popen(client_env, ["gem", *args], err: [:child, :out], unsetenv_others: true, &:read)
    [output, $?]
  end

  # A home of its own, so the credentials file is this test's and no
  # GEM_HOST_API_KEY from the outside makes `gem signin` skip the prompts
  def client_env
    env = Bundler.with_unbundled_env { ENV.to_h }
    env.delete("GEM_HOST_API_KEY")
    env.delete("GEM_HOST_OTP_CODE")
    env["RUBYGEMS_HOST"] = @host
    env["HOME"] = @home
    env["XDG_DATA_HOME"] = File.join(@home, ".local", "share")
    env["XDG_CONFIG_HOME"] = File.join(@home, ".config")
    env["XDG_CACHE_HOME"] = File.join(@home, ".cache")
    env
  end

  # The client writes ~/.gem/credentials if it exists and the XDG one
  # otherwise
  def credentials_path
    legacy = File.join(@home, ".gem", "credentials")
    File.exist?(legacy) ? legacy : File.join(@home, ".local", "share", "gem", "credentials")
  end
end
