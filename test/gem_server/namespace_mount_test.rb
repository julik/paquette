require_relative "../test_helper"
require "puma"
require "puma/server"
require "tmpdir"

# A gem server mounted under a path prefix, which is the shape gem.coop's
# namespaces take: https://gem.coop/@kaspth/versions, /@kaspth/info/oaken,
# /@kaspth/gems/oaken-1.0.0.gem — the same three endpoints as the global
# index, with the namespace sitting between the host and the endpoint. A
# Bundler `source` is a URL prefix, so serving a namespace is exactly
# Rack::Builder#map and nothing more, as long as nothing in here reads the
# path from anywhere but PATH_INFO or answers with a path of its own.
#
# Every route matches on PATH_INFO, and the compact index carries names and
# versions rather than URLs — Bundler appends "/gems/<file>.gem" to the source
# it was given — so a mount should need no cooperation from this server. These
# tests are what says so, on the endpoints Bundler actually walks and with
# Bundler itself at the end.
class NamespaceMountTest < Minitest::Test
  include Rack::Test::Methods

  NAMESPACE = "/@acme"
  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @tmpdir = Dir.mktmpdir("paquette_namespace")
    @gems_dir = File.join(@tmpdir, "gems")
    FileUtils.cp_r(FIXTURE_GEMS_DIR, @gems_dir)

    repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    gem_server = Paquette::GemServer.new(repository)

    @app = Rack::Builder.new do
      map(NAMESPACE) { run gem_server }
      run ->(_env) { [404, {"Content-Type" => "text/plain"}, ["No namespace"]] }
    end.to_app
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  attr_reader :app

  def test_compact_index_versions_file_is_served_under_the_namespace
    get "#{NAMESPACE}/versions"

    assert_equal 200, last_response.status
    names = last_response.body.lines.drop(2).map { |line| line.split(" ").first }
    assert_includes names, "zip_kit"
    assert_includes names, "minuscule_test"
  end

  def test_compact_index_info_file_is_served_under_the_namespace
    get "#{NAMESPACE}/info/zip_kit"

    assert_equal 200, last_response.status
    versions = last_response.body.lines.drop(1).map { |line| line.split(" ").first }
    assert_equal ["6.2.0", "6.2.1"], versions.sort
  end

  # The one endpoint whose URL Bundler builds itself, by appending to the
  # source. Nothing in the index says where the .gem lives, which is why a
  # prefix costs this server nothing.
  def test_gem_files_are_served_under_the_namespace
    get "#{NAMESPACE}/gems/minuscule_test-0.1.0.gem"

    assert_equal 200, last_response.status
    assert_equal File.binread(MINUSCULE_FIXTURE), last_response.body
  end

  def test_legacy_and_api_endpoints_are_served_under_the_namespace
    get "#{NAMESPACE}/specs.4.8.gz"
    assert_equal 200, last_response.status

    get "#{NAMESPACE}/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal ["minuscule_test", "zip_kit"], JSON.parse(last_response.body).sort

    get "#{NAMESPACE}/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal 3, JSON.parse(last_response.body).length
  end

  def test_the_index_page_is_served_at_the_root_of_the_namespace
    get "#{NAMESPACE}/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, Paquette::GemServer::DEFAULT_BLURB
  end

  # Rack::Builder#map hands a request for the mount point itself over with an
  # empty PATH_INFO, and "" is not "/" to any router. A namespace URL with no
  # trailing slash is what a person pastes into a browser, so it has to be the
  # index rather than a 404.
  def test_the_index_page_is_served_at_the_namespace_without_a_trailing_slash
    get NAMESPACE

    assert_equal 200, last_response.status
    assert_includes last_response.body, Paquette::GemServer::DEFAULT_BLURB
  end

  def test_push_and_yank_work_under_the_namespace
    yanked = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    yanked.yank_gem("minuscule_test", "0.1.0")

    post "#{NAMESPACE}/api/v1/gems", File.binread(MINUSCULE_FIXTURE), "CONTENT_TYPE" => "application/octet-stream"
    # A yanked name cannot come back, which is the repository's rule; what
    # matters here is that the request reached it at all.
    assert_equal 403, last_response.status

    post "#{NAMESPACE}/api/v1/gems", File.binread(zip_kit_fixture("6.2.1")), "CONTENT_TYPE" => "application/octet-stream"
    assert_equal 409, last_response.status, "the gem is already in the corpus"

    delete "#{NAMESPACE}/api/v1/gems/yank", {gem_name: "zip_kit", version: "6.2.1"}
    assert_equal 200, last_response.status
    refute_includes Paquette::GemServer::DirectoryGemRepository.new(@gems_dir).versions_for_gem("zip_kit"), "6.2.1"
  end

  # The mount is the whole boundary: the same paths outside it belong to
  # whatever else the application runs there.
  def test_the_same_paths_outside_the_namespace_are_not_the_gem_server
    get "/versions"
    assert_equal 404, last_response.status
    assert_equal "No namespace", last_response.body
  end

  # What a namespace is *for*: two of them side by side, each its own corpus,
  # neither able to see the other's gems.
  def test_two_namespaces_serve_their_own_corpora
    other_dir = File.join(@tmpdir, "other_gems")
    FileUtils.mkdir_p(other_dir)
    other = Paquette::GemServer::DirectoryGemRepository.new(other_dir)
    other.add_gem(File.binread(MINUSCULE_FIXTURE))

    acme = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(@gems_dir))
    beta = Paquette::GemServer.new(other)
    two = Rack::Builder.new do
      map("/@acme") { run acme }
      map("/@beta") { run beta }
    end.to_app

    session = Rack::Test::Session.new(two)

    session.get "/@beta/info/minuscule_test"
    assert_equal 200, session.last_response.status

    session.get "/@beta/info/zip_kit"
    assert_equal 404, session.last_response.status, "@beta was never pushed zip_kit"

    session.get "/@acme/info/zip_kit"
    assert_equal 200, session.last_response.status
    refute_empty session.last_response.body.lines.drop(1)
  end

  # The proof that costs the most and settles the most: the real resolver,
  # walking a real namespaced source, downloading and unpacking the gems.
  def test_bundler_installs_from_a_namespaced_source
    server = Puma::Server.new(@app)
    port = server.add_tcp_listener("127.0.0.1", 0).addr[1]
    server.run

    app_dir = File.join(@tmpdir, "app")
    FileUtils.mkdir_p(app_dir)
    File.write(File.join(app_dir, "Gemfile"), <<~RUBY)
      source "http://127.0.0.1:#{port}#{NAMESPACE}" do
        gem "zip_kit"
        gem "minuscule_test"
      end
    RUBY

    output, status = bundle_install(app_dir)

    assert status.success?, "bundle install failed:\n#{output}"

    lockfile = File.read(File.join(app_dir, "Gemfile.lock"))
    assert_includes lockfile, "remote: http://127.0.0.1:#{port}#{NAMESPACE}"
    assert_includes lockfile, "zip_kit (6.2.1)"
    assert_includes lockfile, "minuscule_test (0.1.0)"

    installed = Dir.glob(File.join(@tmpdir, "bundle", "**", "gems", "*")).map { |path| File.basename(path) }
    assert_includes installed, "zip_kit-6.2.1", "the .gem was resolved but never unpacked"
  ensure
    server&.stop(true)
  end

  private

  def zip_kit_fixture(version)
    File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-#{version}.gem")
  end

  def bundle_install(app_dir)
    env = Bundler.with_unbundled_env { ENV.to_h }
    env["BUNDLE_GEMFILE"] = File.join(app_dir, "Gemfile")
    env["BUNDLE_PATH"] = File.join(@tmpdir, "bundle")
    env["BUNDLE_USER_HOME"] = File.join(@tmpdir, "bundle_user_home")

    IO.popen(env, ["bundle", "install"], chdir: app_dir, err: [:child, :out], unsetenv_others: true, &:read).then do |output|
      [output, $?]
    end
  end
end
