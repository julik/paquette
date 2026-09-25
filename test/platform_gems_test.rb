require_relative "test_helper"

# A corpus holding the same name and version at three platforms, which is
# the ordinary shape of any gem with a native extension — nokogiri 1.16.0
# exists for ruby, for java and for arm64-darwin, and a client picks the
# one matching the machine it is installing on.
#
# What every assertion here is really about is the version column. On disk
# and in the compact index the platform is glued onto it ("1.16.0-java"),
# which is correct in both places; everywhere else — the legacy Marshal
# indexes, the dependency API, search — the platform is its own field and
# the number beside it is bare. Glue them and a client is handed
# "1.16.0-java" as a version, which resolves to nothing at all, on a
# platform ("ruby") that is not the gem's.
class PlatformGemsTest < Minitest::Test
  include Rack::Test::Methods

  PLATFORMS = ["ruby", "java", "arm64-darwin"]

  def setup
    @gems_dir = Dir.mktmpdir("paquette_platform_gems")
    PLATFORMS.each do |platform|
      write_platform_gem(@gems_dir, name: "nokogiri", version: "1.16.0", platform: platform,
        dependencies: {"racc" => "~> 1.4"})
    end
    # An older plain-ruby build, so "latest" has something to be later than.
    write_platform_gem(@gems_dir, name: "nokogiri", version: "1.15.0", dependencies: {"racc" => "~> 1.4"})

    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @app = Paquette::GemServer.new(@repository)
  end

  def teardown
    FileUtils.remove_entry(@gems_dir) if @gems_dir && Dir.exist?(@gems_dir)
  end

  attr_reader :app

  # All three land on disk under their own filenames, which is what makes
  # the rest of this file a test of the server rather than of the fixture.
  def test_the_three_builds_coexist_on_disk
    assert_equal ["nokogiri-1.15.0.gem", "nokogiri-1.16.0-arm64-darwin.gem", "nokogiri-1.16.0-java.gem",
      "nokogiri-1.16.0.gem"],
      Dir.children(File.join(@gems_dir, "nokogiri")).sort
  end

  # Unchanged, and deliberately so: "1.16.0-java" in the version column is
  # the compact index's own wire format, and Bundler splits it back apart
  # itself. This is the one place the glue belongs.
  def test_compact_info_keeps_the_platform_glued_to_the_version
    get "/info/nokogiri"
    assert_equal 200, last_response.status

    columns = last_response.body.split("\n")[1..].map { |line| line.split(" ").first }
    assert_equal ["1.15.0", "1.16.0", "1.16.0-arm64-darwin", "1.16.0-java"], columns.sort
  end

  def test_specs_index_names_the_platform_and_a_bare_version
    get "/specs.4.8"
    assert_equal 200, last_response.status

    specs = Marshal.load(last_response.body)
    assert_equal [
      ["nokogiri", Gem::Version.new("1.15.0"), "ruby"],
      ["nokogiri", Gem::Version.new("1.16.0"), "arm64-darwin"],
      ["nokogiri", Gem::Version.new("1.16.0"), "java"],
      ["nokogiri", Gem::Version.new("1.16.0"), "ruby"]
    ].sort_by { |name, version, platform| [name, version.to_s, platform] },
      specs.sort_by { |name, version, platform| [name, version.to_s, platform] }
  end

  # rubygems.org's own specs.4.8 unmarshals to [String, Gem::Version,
  # String]. Gem::SpecFetcher sorts the tuples it builds out of these
  # rows, and Strings sort "1.10.0" below "1.9.0".
  def test_specs_index_carries_gem_version_objects
    get "/specs.4.8"
    specs = Marshal.load(last_response.body)

    assert_equal [[String, Gem::Version, String]], specs.map { |row| row.map(&:class) }.uniq
  end

  def test_specs_gz_index_matches_the_uncompressed_one
    get "/specs.4.8"
    plain = Marshal.load(last_response.body)

    get "/specs.4.8.gz"
    assert_equal "application/x-gzip", last_response.content_type
    gzipped = Marshal.load(Zlib::GzipReader.new(StringIO.new(last_response.body)).read)

    assert_equal plain, gzipped
  end

  # One row per name *and platform*, the way rubygems.org publishes it: a
  # java build is not an older version of the ruby one, and picking a
  # single latest row per name would hide two of these three from every
  # client resolving off this index.
  def test_latest_specs_keeps_one_row_per_platform
    get "/latest_specs.4.8"
    specs = Marshal.load(last_response.body)

    assert_equal [
      ["nokogiri", "1.16.0", "arm64-darwin"],
      ["nokogiri", "1.16.0", "java"],
      ["nokogiri", "1.16.0", "ruby"]
    ], specs.map { |name, version, platform| [name, version.to_s, platform] }.sort
  end

  # The bug this catches: "1.16.0-java" read as a version is
  # 1.16.0.pre.java, a prerelease, so a platform build compared as a glued
  # column ranks below every plain release and 1.15.0 would win.
  def test_latest_specs_does_not_read_a_platform_suffix_as_a_prerelease
    get "/latest_specs.4.8"
    specs = Marshal.load(last_response.body)

    refute_includes specs.map { |row| row[1].to_s }, "1.15.0"
  end

  def test_latest_specs_gz_matches_the_uncompressed_one
    get "/latest_specs.4.8"
    plain = Marshal.load(last_response.body)

    get "/latest_specs.4.8.gz"
    gzipped = Marshal.load(Zlib::GzipReader.new(StringIO.new(last_response.body)).read)

    assert_equal plain, gzipped
  end

  # Marshal, not JSON: Bundler's legacy dependency fetcher hands the body
  # straight to Marshal.load.
  def test_dependency_api_reports_each_platform_separately
    get "/api/v1/dependencies", gems: "nokogiri"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    deps = Marshal.load(last_response.body)
    assert_equal [
      {name: "nokogiri", number: "1.15.0", platform: "ruby", dependencies: [["racc", "~> 1.4"]]},
      {name: "nokogiri", number: "1.16.0", platform: "arm64-darwin", dependencies: [["racc", "~> 1.4"]]},
      {name: "nokogiri", number: "1.16.0", platform: "java", dependencies: [["racc", "~> 1.4"]]},
      {name: "nokogiri", number: "1.16.0", platform: "ruby", dependencies: [["racc", "~> 1.4"]]}
    ].sort_by { |entry| [entry[:number], entry[:platform]] },
      deps.sort_by { |entry| [entry[:number], entry[:platform]] }
  end

  def test_dependency_api_json_says_the_same_thing_in_json
    get "/api/v1/dependencies.json", gems: "nokogiri"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    deps = JSON.parse(last_response.body)
    java = deps.find { |entry| entry["platform"] == "java" }

    assert_equal "1.16.0", java["number"]
    assert_equal [["racc", "~> 1.4"]], java["dependencies"]
    assert_equal ["arm64-darwin", "java", "ruby", "ruby"], deps.map { |entry| entry["platform"] }.sort
  end

  def test_dependency_api_answers_an_empty_request_with_an_empty_index
    get "/api/v1/dependencies"
    assert_equal [], Marshal.load(last_response.body)

    get "/api/v1/dependencies.json"
    assert_equal [], JSON.parse(last_response.body)
  end

  def test_dependency_api_takes_several_comma_separated_names
    write_platform_gem(@gems_dir, name: "racc", version: "1.7.3")

    get "/api/v1/dependencies", gems: "nokogiri,racc"
    deps = Marshal.load(last_response.body)

    assert_equal ["nokogiri", "racc"], deps.map { |entry| entry[:name] }.uniq.sort
  end

  # The placeholders this used to serve — authors ["Unknown"], info
  # "Uploaded to Paquette" — were the same for every gem in the corpus,
  # and the platform was always "ruby".
  def test_search_reports_the_real_spec_rather_than_placeholders
    get "/api/v1/search.json", query: "nokogiri"
    assert_equal 200, last_response.status

    results = JSON.parse(last_response.body)
    java = results.find { |result| result["platform"] == "java" }

    assert_equal "1.16.0", java["version"]
    assert_equal ["Platform Fixture"], java["authors"]
    assert_equal "A java build of nokogiri", java["info"]
    assert_equal ["arm64-darwin", "java", "ruby", "ruby"], results.map { |result| result["platform"] }.sort
  end

  def test_search_over_a_name_that_matches_nothing_is_empty
    get "/api/v1/search.json", query: "nothing-like-this"
    assert_equal [], JSON.parse(last_response.body)
  end

  def test_versions_api_splits_the_platform_out_of_the_number
    get "/api/v1/versions"
    versions = JSON.parse(last_response.body)

    assert_equal [
      ["1.15.0", "ruby"],
      ["1.16.0", "arm64-darwin"],
      ["1.16.0", "java"],
      ["1.16.0", "ruby"]
    ], versions.map { |version| [version["number"], version["platform"]] }.sort
  end

  # Each build is its own gemspec, fetched under its own glued name — the
  # path /quick/ is asked for is the .gem filename without the extension.
  def test_each_platform_has_its_own_quick_gemspec
    PLATFORMS.each do |platform|
      suffix = (platform == "ruby") ? "" : "-#{platform}"
      get "/quick/Marshal.4.8/nokogiri-1.16.0#{suffix}.gemspec.rz"

      assert_equal 200, last_response.status, platform
      spec = Marshal.load(Zlib::Inflate.inflate(last_response.body))
      assert_equal "nokogiri", spec.name
      assert_equal "1.16.0", spec.version.to_s
      assert_equal platform, spec.platform.to_s
    end
  end

  def test_each_platform_downloads_its_own_bytes
    bodies = PLATFORMS.map do |platform|
      suffix = (platform == "ruby") ? "" : "-#{platform}"
      get "/gems/nokogiri-1.16.0#{suffix}.gem"

      assert_equal 200, last_response.status, platform
      assert_equal "application/octet-stream", last_response.content_type
      last_response.body
    end

    assert_equal 3, bodies.uniq.length, "each platform build must serve its own bytes"
    bodies.zip(PLATFORMS).each do |body, platform|
      assert_equal platform, Gem::Package.new(StringIO.new(body)).spec.platform.to_s
    end
  end

  # Yanking one build leaves the other two downloadable, which is the
  # whole reason the platform belongs in the key rather than beside it.
  def test_yanking_one_platform_leaves_the_others_alone
    delete "/api/v1/gems/yank", {gem_name: "nokogiri", version: "1.16.0-java"}
    assert_equal 200, last_response.status

    get "/gems/nokogiri-1.16.0-java.gem"
    assert_equal 404, last_response.status

    get "/gems/nokogiri-1.16.0-arm64-darwin.gem"
    assert_equal 200, last_response.status

    get "/gems/nokogiri-1.16.0.gem"
    assert_equal 200, last_response.status

    get "/specs.4.8"
    platforms = Marshal.load(last_response.body).map { |row| row[2] }.sort
    assert_equal ["arm64-darwin", "ruby", "ruby"], platforms
  end

  def test_every_platform_can_be_yanked_in_turn
    PLATFORMS.each do |platform|
      suffix = (platform == "ruby") ? "" : "-#{platform}"
      delete "/api/v1/gems/yank", {gem_name: "nokogiri", version: "1.16.0#{suffix}"}
      assert_equal 200, last_response.status, platform
    end

    get "/info/nokogiri"
    columns = last_response.body.split("\n")[1..].map { |line| line.split(" ").first }
    assert_equal ["1.15.0"], columns
  end
end
