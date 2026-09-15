require_relative "../test_helper"
require "puma"
require "puma/server"
require "tmpdir"
require "rubygems/package"

# The compact index is a contract with Bundler, and the only way to know it is
# being honoured is to let Bundler have it. Asserting the shape of the strings
# proves the strings have the shape we believe in; this test proves that the
# real resolver, downloading the real .gem, agrees with what it was told.
#
# Before dependencies were emitted in /info/, this failed exactly the way the
# bug report did: "Downloading paquette_root-1.0.0 revealed dependencies not in
# the API (paquette_dep (>= 1.0, < 2))" — Bundler resolves against the index,
# then checks the downloaded gem against it, and refuses when they disagree.
class BundlerDependencyResolutionTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("paquette_bundler_test")
    @gems_dir = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(@gems_dir)

    build_gem("paquette_dep", "1.2.0")
    build_gem("paquette_dep", "2.0.0")
    build_gem("paquette_root", "1.0.0",
      runtime_dependencies: {"paquette_dep" => [">= 1.0", "< 2"]},
      development_dependencies: {"paquette_absent" => [">= 0"]})

    repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    start_server(Paquette::GemServer.new(repository))
  end

  def teardown
    @server&.stop(true)
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_bundler_installs_a_gem_with_runtime_dependencies
    app_dir = File.join(@tmpdir, "app")
    FileUtils.mkdir_p(app_dir)
    File.write(File.join(app_dir, "Gemfile"), <<~RUBY)
      source "http://127.0.0.1:#{@port}"
      gem "paquette_root"
    RUBY

    output, status = bundle_install(app_dir)

    assert status.success?, "bundle install failed:\n#{output}"

    lockfile = File.read(File.join(app_dir, "Gemfile.lock"))

    # Bundler only learns about the dependency from the index, so its presence
    # in the lock is the proof that the index carried it.
    assert_includes lockfile, "paquette_dep (1.2.0)"
    assert_includes lockfile, "paquette_root (1.0.0)"

    # The `< 2` half of the requirement has to survive the "&" joining, or 2.0.0
    # would have been picked.
    refute_includes lockfile, "paquette_dep (2.0.0)"

    # A development dependency in the index would have sent Bundler looking for
    # a gem this registry does not have, and the install would have failed.
    refute_includes lockfile, "paquette_absent"
  end

  # The line format itself, since the Bundler run above can only tell us that
  # *something* acceptable was served, not what.
  def test_info_line_carries_runtime_dependencies_and_nothing_else
    repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    line = repository.compact_info("paquette_root").fetch(0)

    version, rest = line.split(" ", 2)
    dependencies, requirements = rest.split("|", 2)

    assert_equal "1.0.0", version
    # Two clauses on one dependency join with "&" — a comma there would read as
    # the start of a second dependency.
    assert_equal "paquette_dep:>= 1.0&< 2", dependencies
    refute_includes dependencies, "paquette_absent"
    assert_match(/\Achecksum:[a-f0-9]{64},ruby:>= 2\.6\z/, requirements)
  end

  private

  def bundle_install(app_dir)
    env = Bundler.with_unbundled_env { ENV.to_h }
    env["BUNDLE_GEMFILE"] = File.join(app_dir, "Gemfile")
    env["BUNDLE_PATH"] = File.join(@tmpdir, "bundle")
    # A pristine cache, so nothing that was fetched from a real registry earlier
    # can stand in for what this server is being asked to serve.
    env["BUNDLE_USER_HOME"] = File.join(@tmpdir, "bundle_user_home")

    # unsetenv_others, because spawn otherwise MERGES this hash into the current
    # environment — and the current environment is the one `bundle exec` set up
    # for Paquette's own suite, RUBYOPT=-rbundler/setup and all.
    output = IO.popen(env, ["bundle", "install"], chdir: app_dir, err: [:child, :out], unsetenv_others: true, &:read)
    [output, $?]
  end

  def start_server(app)
    @server = Puma::Server.new(app)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
  end

  def build_gem(name, version, runtime_dependencies: {}, development_dependencies: {})
    source_dir = File.join(@tmpdir, "src", "#{name}-#{version}")
    FileUtils.mkdir_p(File.join(source_dir, "lib"))
    File.write(File.join(source_dir, "lib", "#{name}.rb"), "module #{name.split("_").map(&:capitalize).join}; end\n")

    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = "Paquette test fixture"
      s.authors = ["Paquette"]
      s.files = ["lib/#{name}.rb"]
      s.required_ruby_version = ">= 2.6"
      s.license = "MIT"
      runtime_dependencies.each { |dep_name, req| s.add_dependency(dep_name, *req) }
      development_dependencies.each { |dep_name, req| s.add_development_dependency(dep_name, *req) }
    end

    # capture_io only to keep the gem builder's chatter out of the test output
    built = nil
    capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }

    FileUtils.mkdir_p(File.join(@gems_dir, name))
    FileUtils.mv(File.join(source_dir, built), File.join(@gems_dir, name, built))
  end
end
