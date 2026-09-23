require_relative "../test_helper"
require "puma"
require "puma/server"
require "tmpdir"

# Bundler installing the fixture corpus, end to end: resolve against the
# compact index, download the .gem files, unpack them into a bundle. The
# dependency-resolution test next door proves the index *says* the right
# thing about gems this suite builds; this one proves real published gems
# come back out of the server installable.
#
# It used to point Bundler at "gem.localhost" through the subdomain router
# and never look at the result — a host that does not resolve on macOS, so
# every run of it silently installed nothing. The subdomain routing has its
# own test that does not need DNS; what is worth a live server here is the
# install.
class BundlerInstallTest < Minitest::Test
  FIXTURE_GEMS = File.expand_path("../fixtures/gems", __dir__)

  def setup
    @tmpdir = Dir.mktmpdir("paquette_bundler_install")
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS)
    @server = Puma::Server.new(Paquette::GemServer.new(repository))
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
  end

  def teardown
    @server&.stop(true)
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_bundler_installs_gems_from_the_server
    app_dir = File.join(@tmpdir, "app")
    FileUtils.mkdir_p(app_dir)
    File.write(File.join(app_dir, "Gemfile"), <<~RUBY)
      source "http://127.0.0.1:#{@port}" do
        gem "zip_kit"
        gem "minuscule_test"
      end
    RUBY

    output, status = bundle_install(app_dir)

    assert status.success?, "bundle install failed:\n#{output}"

    lockfile = File.read(File.join(app_dir, "Gemfile.lock"))
    # The newest of the two zip_kit fixtures: the index offers both, so the
    # choice is Bundler's and it proves it saw the whole version list.
    assert_includes lockfile, "zip_kit (6.2.1)"
    assert_includes lockfile, "minuscule_test (0.1.0)"

    installed = Dir.glob(File.join(@tmpdir, "bundle", "**", "gems", "*")).map { |path| File.basename(path) }
    assert_includes installed, "zip_kit-6.2.1", "the .gem was resolved but never unpacked"
    assert_includes installed, "minuscule_test-0.1.0"
  end

  private

  def bundle_install(app_dir)
    env = Bundler.with_unbundled_env { ENV.to_h }
    env["BUNDLE_GEMFILE"] = File.join(app_dir, "Gemfile")
    env["BUNDLE_PATH"] = File.join(@tmpdir, "bundle")
    # A pristine cache, so nothing fetched from a real registry earlier can
    # stand in for what this server is being asked to serve.
    env["BUNDLE_USER_HOME"] = File.join(@tmpdir, "bundle_user_home")

    # unsetenv_others, because spawn otherwise MERGES this hash into the
    # current environment — and the current environment is the one `bundle
    # exec` set up for Paquette's own suite, RUBYOPT=-rbundler/setup and all.
    output = IO.popen(env, ["bundle", "install"], chdir: app_dir, err: [:child, :out], unsetenv_others: true, &:read)
    [output, $?]
  end
end
