require_relative "../test_helper"

# The legacy Marshal index is three documents, not two, and they partition
# the corpus: specs.4.8 is every release, prerelease_specs.4.8 is every
# prerelease, latest_specs.4.8 is the newest release of each gem. A 404 on
# the prerelease document is not the same answer as an empty one — `gem
# install --pre` and `gem list --remote --prerelease` fetch it, and mirroring
# tools treat the 404 as a broken source rather than as "no prereleases here".
class GemServerPrereleaseSpecsTest < Minitest::Test
  include Rack::Test::Methods

  # One gem with a release and prereleases either side of it, and one gem
  # that has never had a release at all. The second one is the interesting
  # case: it belongs in prerelease_specs and in neither of the others, so
  # "latest" for it is nothing rather than its newest prerelease.
  CORPUS = {
    "stable_and_pre" => ["1.0.0", "1.0.0.beta1", "2.0.0.rc1"],
    "only_pre" => ["0.1.0.alpha", "0.2.0.beta2"],
    "only_stable" => ["3.1.4"]
  }.freeze

  def setup
    @tmpdir = Dir.mktmpdir("paquette_prerelease_specs")
    @gems_dir = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(@gems_dir)
    CORPUS.each { |name, versions| versions.each { |version| build_gem_on_disk(name, version) } }

    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @app = Paquette::GemServer.new(@repository)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  attr_reader :app

  def test_prerelease_specs_carries_every_prerelease_and_nothing_else
    assert_equal [
      ["only_pre", Gem::Version.new("0.1.0.alpha"), "ruby"],
      ["only_pre", Gem::Version.new("0.2.0.beta2"), "ruby"],
      ["stable_and_pre", Gem::Version.new("1.0.0.beta1"), "ruby"],
      ["stable_and_pre", Gem::Version.new("2.0.0.rc1"), "ruby"]
    ], specs_at("/prerelease_specs.4.8").sort
  end

  def test_specs_carries_every_release_and_no_prerelease
    assert_equal [
      ["only_stable", Gem::Version.new("3.1.4"), "ruby"],
      ["stable_and_pre", Gem::Version.new("1.0.0"), "ruby"]
    ], specs_at("/specs.4.8").sort
  end

  # A gem whose every version is a prerelease has no latest release, so it is
  # absent here rather than represented by its newest prerelease. That is what
  # rubygems.org serves, and it is what keeps `gem install only_pre` without
  # --pre from resolving to something the user did not ask for.
  def test_latest_specs_carries_the_newest_release_of_each_gem_only
    assert_equal [
      ["only_stable", Gem::Version.new("3.1.4"), "ruby"],
      ["stable_and_pre", Gem::Version.new("1.0.0"), "ruby"]
    ], specs_at("/latest_specs.4.8").sort
  end

  # No version appears in two of the three documents, and none goes missing.
  def test_the_three_documents_partition_the_corpus
    releases = specs_at("/specs.4.8")
    prereleases = specs_at("/prerelease_specs.4.8")

    assert_empty releases & prereleases
    assert_equal CORPUS.sum { |_, versions| versions.length }, releases.length + prereleases.length
    assert (specs_at("/latest_specs.4.8") - releases).empty?
  end

  def test_prerelease_specs_content_type
    get "/prerelease_specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    get "/prerelease_specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type
  end

  # The .gz variant is the same bytes through gzip, not a separate render.
  def test_every_gz_variant_decompresses_to_the_uncompressed_document
    %w[specs.4.8 latest_specs.4.8 prerelease_specs.4.8].each do |document|
      get "/#{document}"
      plain = last_response.body

      get "/#{document}.gz"
      gzipped = Zlib::GzipReader.new(StringIO.new(last_response.body)).read

      assert_equal plain, gzipped, "/#{document}.gz does not decompress to /#{document}"
    end
  end

  # What Bundler and RubyGems actually do with the body: Marshal.load it and
  # read three columns off every row.
  def test_the_document_round_trips_through_marshal_into_what_bundler_expects
    specs = specs_at("/prerelease_specs.4.8")

    assert_kind_of Array, specs
    specs.each do |name, version, platform|
      assert_kind_of String, name
      # A Gem::Version, not a String: that is what rubygems.org marshals into
      # this column, and Gem::SpecFetcher sorts what it unmarshals — Strings
      # would sort 1.10.0 below 1.9.0.
      assert_kind_of Gem::Version, version
      assert_equal "ruby", platform
      assert version.prerelease?, "#{name}-#{version} is not a prerelease"
    end
  end

  # A platform-suffixed filename puts something in the version column that
  # Gem::Version will not parse — and newer RubyGems parses "1.0.0-java" as
  # the prerelease "1.0.0.pre.java" if you hand it the whole column, which
  # would file a release build under prereleases. split_version_column cuts
  # the platform off first, so the row carries a bare version beside "java".
  def test_a_platform_suffixed_release_is_not_mistaken_for_a_prerelease
    build_gem_on_disk("platformed", "1.0.0", platform: "java")

    assert_includes specs_at("/specs.4.8"), ["platformed", Gem::Version.new("1.0.0"), "java"]
    refute_includes specs_at("/prerelease_specs.4.8").map(&:first), "platformed"
  end

  def test_a_platform_suffixed_prerelease_is_a_prerelease
    build_gem_on_disk("platformed_pre", "1.0.0.beta1", platform: "java")

    assert_includes specs_at("/prerelease_specs.4.8"), ["platformed_pre", Gem::Version.new("1.0.0.beta1"), "java"]
    refute_includes specs_at("/specs.4.8").map(&:first), "platformed_pre"
  end

  # The wrappers are the point of this codebase, and a new whole-index
  # endpoint is exactly where a withheld version leaks back out.
  def test_a_gated_version_is_absent_from_prerelease_specs
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository) do |name: nil, **|
      name != "only_pre"
    end
    session = session_over(gated)

    session.get "/prerelease_specs.4.8"
    names = Marshal.load(session.last_response.body).map(&:first).uniq
    refute_includes names, "only_pre"
    assert_includes names, "stable_and_pre"
  end

  def test_a_fully_gated_repository_serves_an_empty_prerelease_document
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository) { |**| false }
    session = session_over(gated)

    session.get "/prerelease_specs.4.8"
    assert_equal 200, session.last_response.status
    assert_equal [], Marshal.load(session.last_response.body)
  end

  # Nothing that is still cooling may be resolvable, and prerelease_specs is
  # as resolvable as the other two.
  def test_a_cooling_version_is_absent_from_prerelease_specs
    just_pushed = ->(name:, version:) { Time.now }
    cooling = Paquette::GemServer::CooldownRepository.new(@repository, interval: 3600, published_at: just_pushed)
    session = session_over(cooling)

    session.get "/prerelease_specs.4.8"
    assert_equal [], Marshal.load(session.last_response.body),
      "a just-published prerelease is served through a one-hour cooldown"

    cooled = Paquette::GemServer::CooldownRepository.new(@repository, interval: 3600,
      published_at: just_pushed, clock: -> { Time.now + 7200 })
    session = session_over(cooled)

    session.get "/prerelease_specs.4.8"
    refute_empty Marshal.load(session.last_response.body)
  end

  private

  def session_over(repository)
    Rack::Test::Session.new(Rack::MockSession.new(Paquette::GemServer.new(repository)))
  end

  def specs_at(path)
    get path
    assert_equal 200, last_response.status, path
    Marshal.load(last_response.body)
  end

  def build_gem_on_disk(name, version, platform: nil)
    source_dir = File.join(@tmpdir, "src", "#{name}-#{version}-#{platform}")
    FileUtils.mkdir_p(File.join(source_dir, "lib"))
    File.write(File.join(source_dir, "lib", "fixture.rb"), "module Fixture; end\n")

    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.platform = platform if platform
      s.summary = "Paquette prerelease fixture"
      s.authors = ["Paquette"]
      s.files = ["lib/fixture.rb"]
      s.license = "MIT"
    end

    built = nil
    capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }
    FileUtils.mkdir_p(File.join(@gems_dir, name))
    FileUtils.cp(File.join(source_dir, built), File.join(@gems_dir, name, built))
  end
end
