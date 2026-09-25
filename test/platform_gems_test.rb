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

# The write half of the same story. Reads were platform-correct long before
# this: what was missing was that a push derived its destination from
# `spec.name` and `spec.version` alone, so the java build of a name and
# version that already existed wanted the plain build's path and was refused
# 409 "already exists". A platform build is an artifact, not a second copy
# of one, and everything that identifies an artifact here — the filename,
# the duplicate check, the tomb, the yank — now carries the platform.
class PlatformGemWritesTest < Minitest::Test
  include Rack::Test::Methods

  PLATFORMS = ["ruby", "java", "arm64-darwin"]

  def setup
    @gems_dir = Dir.mktmpdir("paquette_platform_writes")
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @app = Paquette::GemServer.new(@repository)
  end

  def teardown
    FileUtils.remove_entry(@gems_dir) if @gems_dir && Dir.exist?(@gems_dir)
  end

  attr_reader :app

  def push(name:, version:, platform: "ruby", **kwargs)
    spec = platform_gem_spec(name: name, version: version, platform: platform, **kwargs)
    post "/api/v1/gems", gem_bytes_for(spec), "CONTENT_TYPE" => "application/octet-stream"
    spec
  end

  def yank(name:, version:, platform: nil)
    params = {gem_name: name, version: version}
    params[:platform] = platform unless platform.nil?
    delete "/api/v1/gems/yank", params
  end

  def test_three_platforms_of_one_version_are_three_artifacts
    PLATFORMS.each do |platform|
      push(name: "nokogiri", version: "1.16.0", platform: platform)
      assert_equal 200, last_response.status, platform
    end

    assert_equal ["nokogiri-1.16.0-arm64-darwin.gem", "nokogiri-1.16.0-java.gem", "nokogiri-1.16.0.gem"],
      Dir.children(File.join(@gems_dir, "nokogiri")).sort
  end

  # The stored name is not a spelling of our own that happens to resemble
  # RubyGems': it is asserted against Gem::Specification#file_name, which is
  # what `gem build` names the file and what /gems/ is asked for.
  def test_the_stored_filename_is_the_one_rubygems_itself_would_produce
    PLATFORMS.each do |platform|
      spec = push(name: "nokogiri", version: "1.16.0", platform: platform)
      assert_equal 200, last_response.status, platform
      assert_path_exists File.join(@gems_dir, "nokogiri", spec.file_name)
    end
  end

  def test_a_plain_ruby_gem_keeps_the_filename_it_always_had
    push(name: "widgets", version: "1.0.0")

    assert_equal ["widgets-1.0.0.gem"], Dir.children(File.join(@gems_dir, "widgets"))
  end

  def test_each_pushed_platform_downloads_its_own_bytes
    PLATFORMS.each { |platform| push(name: "nokogiri", version: "1.16.0", platform: platform) }

    bodies = PLATFORMS.map do |platform|
      suffix = (platform == "ruby") ? "" : "-#{platform}"
      get "/gems/nokogiri-1.16.0#{suffix}.gem"

      assert_equal 200, last_response.status, platform
      assert_equal platform, Gem::Package.new(StringIO.new(last_response.body)).spec.platform.to_s
      last_response.body
    end

    assert_equal 3, bodies.uniq.length, "each platform build must serve its own bytes"
  end

  def test_pushing_the_same_platform_twice_is_still_a_conflict
    push(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 200, last_response.status

    push(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 409, last_response.status
    assert_includes last_response.body, "nokogiri-1.16.0-java"
  end

  # Two spellings of one platform. RubyGems parses "x86_64-darwin20" and
  # "x86_64-darwin-20" into the same Gem::Platform, so both name the same
  # artifact and the second push is the duplicate it looks like — rather
  # than a second file quietly shadowing the first under a different name.
  def test_two_spellings_of_one_platform_are_one_artifact
    assert_equal "x86_64-darwin-20", Gem::Platform.new("x86_64-darwin20").to_s

    push(name: "nokogiri", version: "1.16.0", platform: "x86_64-darwin-20")
    assert_equal 200, last_response.status

    push(name: "nokogiri", version: "1.16.0", platform: "x86_64-darwin20")
    assert_equal 409, last_response.status

    assert_equal ["nokogiri-1.16.0-x86_64-darwin-20.gem"], Dir.children(File.join(@gems_dir, "nokogiri"))
  end

  # `gem yank a -v 1.16.0 --platform java` sends the platform as its own
  # param. The two siblings must survive it.
  def test_yanking_one_platform_by_param_leaves_the_siblings_alive
    PLATFORMS.each { |platform| push(name: "nokogiri", version: "1.16.0", platform: platform) }

    yank(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 200, last_response.status

    get "/gems/nokogiri-1.16.0-java.gem"
    assert_equal 404, last_response.status

    get "/gems/nokogiri-1.16.0.gem"
    assert_equal 200, last_response.status

    get "/gems/nokogiri-1.16.0-arm64-darwin.gem"
    assert_equal 200, last_response.status
  end

  # The other half of the same rule: `gem yank` omits the platform for a
  # plain-ruby gem, and an omitted or blank platform means "ruby" — not
  # "every platform of this version".
  def test_an_absent_or_blank_platform_yanks_only_the_plain_build
    ["", nil].each do |platform_param|
      PLATFORMS.each { |platform| push(name: "nokogiri", version: "1.16.0", platform: platform) }

      yank(name: "nokogiri", version: "1.16.0", platform: platform_param)
      assert_equal 200, last_response.status, platform_param.inspect

      get "/gems/nokogiri-1.16.0.gem"
      assert_equal 404, last_response.status, platform_param.inspect

      ["java", "arm64-darwin"].each do |platform|
        get "/gems/nokogiri-1.16.0-#{platform}.gem"
        assert_equal 200, last_response.status, "#{platform_param.inspect} took #{platform} with it"
      end

      FileUtils.rm_rf(File.join(@gems_dir, "nokogiri"))
    end
  end

  # Tombs are per-artifact. A yanked java build must not stand in the way of
  # the ruby build being pushed, and must stand in the way of itself.
  def test_a_tomb_belongs_to_one_platform_and_not_to_its_siblings
    push(name: "nokogiri", version: "1.16.0", platform: "java")
    yank(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 200, last_response.status

    push(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 403, last_response.status
    assert_includes last_response.body, "was yanked"

    push(name: "nokogiri", version: "1.16.0")
    assert_equal 200, last_response.status

    push(name: "nokogiri", version: "1.16.0", platform: "arm64-darwin")
    assert_equal 200, last_response.status
  end

  def test_a_yank_of_a_platform_that_was_never_pushed_is_a_404
    push(name: "nokogiri", version: "1.16.0")

    yank(name: "nokogiri", version: "1.16.0", platform: "java")
    assert_equal 404, last_response.status

    get "/gems/nokogiri-1.16.0.gem"
    assert_equal 200, last_response.status
  end

  # The version column as the index publishes it, handed straight back to a
  # yank. A client reading /info/ and yanking what it read should not have
  # to take the column apart first.
  def test_a_yank_accepts_the_platform_already_glued_to_the_version
    push(name: "nokogiri", version: "1.16.0", platform: "java")
    push(name: "nokogiri", version: "1.16.0")

    yank(name: "nokogiri", version: "1.16.0-java")
    assert_equal 200, last_response.status

    get "/gems/nokogiri-1.16.0-java.gem"
    assert_equal 404, last_response.status

    get "/gems/nokogiri-1.16.0.gem"
    assert_equal 200, last_response.status
  end

  def test_the_index_follows_a_per_platform_yank
    PLATFORMS.each { |platform| push(name: "nokogiri", version: "1.16.0", platform: platform) }
    yank(name: "nokogiri", version: "1.16.0", platform: "java")

    get "/info/nokogiri"
    columns = last_response.body.split("\n")[1..].map { |line| line.split(" ").first }
    assert_equal ["1.16.0", "1.16.0-arm64-darwin"], columns.sort

    get "/specs.4.8"
    assert_equal [["nokogiri", "1.16.0", "arm64-darwin"], ["nokogiri", "1.16.0", "ruby"]],
      Marshal.load(last_response.body).map { |name, version, platform| [name, version.to_s, platform] }.sort
  end
end

# The platform string is chosen by whoever uploads the gem, and it is about
# to become part of a filename. Everything here is a string a gemspec can
# legally carry and a filesystem should never be asked to.
class HostilePlatformPushTest < Minitest::Test
  include Rack::Test::Methods

  # Written onto the ivar rather than through `platform=`, which normalizes
  # — a hostile uploader is not obliged to use RubyGems' setter, and a
  # gemspec loaded out of an uploaded tarball is a YAML document that sets
  # the ivar directly.
  HOSTILE = [
    "../../../../tmp/pwned",
    "..",
    ".",
    "a/../../b",
    "/etc/passwd",
    ".ssh",
    "java ",
    "java\nwidgets 9.9.9 |checksum:deadbeef",
    "java\r\n0.0.1",
    "java ",
    "java/",
    "a" * 300,
    "\xFF".b,
    "java\xE2".b,
    "java\xFF".b
  ]

  def setup
    @gems_dir = Dir.mktmpdir("paquette_hostile_platform")
    @app = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(@gems_dir))
  end

  def teardown
    FileUtils.remove_entry(@gems_dir) if @gems_dir && Dir.exist?(@gems_dir)
  end

  attr_reader :app

  # The filename a hostile platform is allowed to claim, and nothing else:
  # the name, the version, and an optional suffix out of PLATFORM's charset.
  SAFE_GEM_FILENAME = /\Awidgets-1\.0\.0(-[A-Za-z0-9][A-Za-z0-9_.-]{0,63})?\.gem\z/

  # Two things have to be true and only one of them is ours. RubyGems parses
  # a declared platform into a Gem::Platform on the way in and prints it back
  # in its own spelling, so "../../../../tmp/pwned" arrives as "unknown" and
  # "java/" as "java-" — the hostile bytes are gone before the validator sees
  # them, and a push carrying one is accepted under a harmless name rather
  # than refused. That is upstream's doing, not a guarantee this class is
  # entitled to lean on, which is why SpecValidator holds the platform to a
  # charset of its own anyway (regexp_linearity_test.rb pushes the raw string
  # past the normalization and asserts the refusal).
  #
  # What is asserted here is the property that matters either way: whatever
  # the server decides, nothing a gemspec declared has put a byte into a path
  # that PLATFORM would not have admitted, and nothing has landed outside the
  # one package directory.
  def test_a_hostile_platform_never_becomes_part_of_a_path
    HOSTILE.each do |platform|
      bytes = hostile_gem_bytes(name: "widgets", version: "1.0.0") do |spec|
        spec.instance_variable_set(:@new_platform, platform)
        spec.instance_variable_set(:@original_platform, platform)
      end

      post "/api/v1/gems", bytes, "CONTENT_TYPE" => "application/octet-stream"
      assert_includes [200, 400, 409], last_response.status, platform.inspect
    end

    written = Dir.glob(File.join(@gems_dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
    written.each do |path|
      assert_equal File.join(@gems_dir, "widgets"), File.dirname(path), path
      assert_match SAFE_GEM_FILENAME, File.basename(path), path
    end
  end

  # A hostile platform must not reach the filesystem through the yank path
  # either — the params of a DELETE name a path exactly as a gemspec's
  # fields do, and until the validator covered them a gem_name of
  # "../../srv/other" was handed straight to File.join.
  def test_every_hostile_yank_reference_is_refused
    decoy = File.join(@gems_dir, "outside-1.0.0.gem")
    File.binwrite(decoy, "not yours")

    HOSTILE.each do |platform|
      delete "/api/v1/gems/yank", {gem_name: "widgets", version: "1.0.0", platform: platform}
      assert_equal 400, last_response.status, platform.inspect
    end

    ["../outside", "..", ".", "a/b", "/etc/passwd", ".hidden", "widgets\nforged"].each do |gem_name|
      delete "/api/v1/gems/yank", {gem_name: gem_name, version: "1.0.0"}
      assert_equal 400, last_response.status, gem_name.inspect
    end

    ["1.0.0/../../x", "../1.0.0", "1.0.0\nforged", "not-a-version"].each do |version|
      delete "/api/v1/gems/yank", {gem_name: "widgets", version: version}
      assert_equal 400, last_response.status, version.inspect
    end

    assert_path_exists decoy
    assert_equal "not yours", File.read(decoy)
  end

  # A run of dashes is the shape that makes a splitter take a caller-chosen
  # amount of time, and the platform is the one field whose charset has to
  # admit a dash at all.
  def test_pathological_platform_references_are_answered_promptly
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    ["-" * 20_000, "a-" * 10_000, "java-" * 4000, "%0A", "%E2", "\xFF".b, "\xE2".b].each do |platform|
      delete "/api/v1/gems/yank", {gem_name: "widgets", version: "1.0.0", platform: platform}
      assert_equal 400, last_response.status, platform[0, 16].inspect
    end

    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert took < 2.0, "pathological platforms took #{took}s"
  end
end

# The wrappers are the point of this codebase, and they are also where a
# platform leak would be quietest: every one of them passes a *version
# column* around, so each has to be asked whether it can still tell
# "1.16.0" and "1.16.0-java" apart when it was only ever written to think
# about a name and a version.
class PlatformGemWrappersTest < Minitest::Test
  include Rack::Test::Methods

  PLATFORMS = ["ruby", "java", "arm64-darwin"]

  def setup
    @gems_dir = Dir.mktmpdir("paquette_platform_wrappers")
    PLATFORMS.each do |platform|
      write_platform_gem(@gems_dir, name: "nokogiri", version: "1.16.0", platform: platform)
    end
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @app = Paquette::GemServer.new(@repository)
  end

  def teardown
    FileUtils.remove_entry(@gems_dir) if @gems_dir && Dir.exist?(@gems_dir)
    FileUtils.remove_entry(@cache_dir) if @cache_dir && Dir.exist?(@cache_dir)
  end

  attr_reader :app

  def column_for(platform)
    Paquette::GemServer.version_column("1.16.0", platform)
  end

  # The gate is handed the column, so withholding one platform is something
  # it can express. The trap is the other direction: a gate that names the
  # bare number must not be read as naming every platform of it.
  def test_a_read_gate_can_withhold_one_platform_without_touching_its_siblings
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository, gate_key: "t") do |name:, version: nil|
      version != "1.16.0-java"
    end

    assert_equal ["1.16.0", "1.16.0-arm64-darwin"], gated.versions_for_gem("nokogiri").sort
    refute gated.gem_exists?("nokogiri", "1.16.0-java")
    assert gated.gem_exists?("nokogiri", "1.16.0")
    assert gated.gem_exists?("nokogiri", "1.16.0-arm64-darwin")
    assert_nil gated.gem_file_path("nokogiri", "1.16.0-java")

    assert_equal ["1.16.0", "1.16.0-arm64-darwin"],
      gated.compact_info("nokogiri").map { |line| line.split(" ").first }.sort
  end

  # The leak this is looking for: a gate that only knows about "1.16.0"
  # letting "1.16.0-java" through because the two look alike, or denying
  # it because they look alike. It must be told about each one separately.
  def test_a_gate_keyed_on_the_bare_number_is_never_asked_about_a_platform_build
    asked = []
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository, gate_key: "t") do |name:, version: nil|
      asked << version
      version.nil? || version == "1.16.0"
    end

    assert_equal ["1.16.0"], gated.versions_for_gem("nokogiri")
    assert_includes asked, "1.16.0-java"
    assert_includes asked, "1.16.0-arm64-darwin"

    # And a gate that names a platform build alone withholds exactly it.
    only_java = Paquette::GemServer::ReadGatedRepository.new(@repository, gate_key: "t") do |name:, version: nil|
      version.nil? || version == "1.16.0-java"
    end
    assert_equal ["1.16.0-java"], only_java.versions_for_gem("nokogiri")
  end

  # A cooldown is a filter over the same column, so one platform can be
  # cooling while its siblings are servable — which is what happens in real
  # life, because the platform builds of one release are pushed minutes
  # apart.
  def test_a_cooldown_cools_one_platform_at_a_time
    published = {
      "1.16.0" => Time.utc(2024, 1, 1),
      "1.16.0-java" => Time.utc(2024, 1, 1),
      "1.16.0-arm64-darwin" => Time.utc(2024, 6, 1)
    }
    cooled = Paquette::GemServer::CooldownRepository.new(
      @repository,
      interval: 7 * 24 * 60 * 60,
      published_at: ->(name:, version:) { published.fetch(version) },
      published_at_validator: -> { "fixed" },
      clock: -> { Time.utc(2024, 6, 2) }
    )

    assert_equal ["1.16.0", "1.16.0-java"], cooled.versions_for_gem("nokogiri").sort
    refute cooled.gem_exists?("nokogiri", "1.16.0-arm64-darwin")
    assert cooled.gem_exists?("nokogiri", "1.16.0-java")
    assert_nil cooled.gem_file_path("nokogiri", "1.16.0-arm64-darwin")
  end

  # Writes through a readonly view are refused whatever the platform, which
  # is the whole of what that wrapper promises.
  def test_a_readonly_view_refuses_a_platform_yank_as_it_refuses_any_other
    readonly = Paquette::GemServer::ReadonlyRepository.new(@repository)

    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) do
      readonly.yank_gem("nokogiri", "1.16.0-java")
    end
    assert_path_exists File.join(@gems_dir, "nokogiri", "nokogiri-1.16.0-java.gem")
  end

  # The personalizer opens a gem, rewrites it and hands back a different
  # file. A repacked java build that came back claiming to be a ruby build
  # would be installed on the wrong machine, and the index row it is served
  # under would no longer describe it.
  def test_a_personalized_platform_gem_is_still_that_platform
    @cache_dir = Dir.mktmpdir("paquette_platform_personalized")
    personalized = Paquette::GemServer::Personalizer.new(
      @repository,
      license_key: "LICENSE-KEY",
      files: {"LICENSE.txt" => "For one licensee only"},
      cache_dir: @cache_dir
    )

    PLATFORMS.each do |platform|
      column = column_for(platform)
      served = personalized.gem_file_path("nokogiri", column)

      refute_equal @repository.gem_file_path("nokogiri", column), served, platform
      spec = Gem::Package.new(served).spec
      assert_equal platform, spec.platform.to_s, platform
      assert_equal "nokogiri-#{column}", spec.full_name, platform
      assert_equal "LICENSE-KEY", spec.metadata["paquette.license_key"], platform
    end
  end

  # Three platforms repacked for one licensee are three distinct files: a
  # cache path that ignored the platform would hand the java build's bytes
  # to somebody asking for the ruby one.
  def test_a_personalizer_keeps_the_three_platforms_apart_in_its_cache
    @cache_dir = Dir.mktmpdir("paquette_platform_personalized")
    personalized = Paquette::GemServer::Personalizer.new(
      @repository,
      license_key: "LICENSE-KEY",
      files: {"LICENSE.txt" => "For one licensee only"},
      cache_dir: @cache_dir
    )

    served = PLATFORMS.map { |platform| personalized.gem_file_path("nokogiri", column_for(platform)) }
    assert_equal 3, served.uniq.length
    assert_equal 3, served.map { |path| File.binread(path) }.uniq.length
  end

  # And the checksum the personalized index publishes for a platform build
  # is the checksum of the platform build it actually serves. A row whose
  # checksum came from a sibling makes `bundle install` report the gem as
  # tampered with.
  def test_a_personalized_index_row_describes_the_platform_build_it_names
    @cache_dir = Dir.mktmpdir("paquette_platform_personalized")
    personalized = Paquette::GemServer::Personalizer.new(
      @repository,
      license_key: "LICENSE-KEY",
      files: {"LICENSE.txt" => "For one licensee only"},
      cache_dir: @cache_dir
    )

    rows = personalized.compact_info("nokogiri").to_h do |line|
      column, rest = line.split(" ", 2)
      [column, rest[/checksum:([0-9a-f]+)/, 1]]
    end

    assert_equal ["1.16.0", "1.16.0-arm64-darwin", "1.16.0-java"], rows.keys.sort
    rows.each do |column, checksum|
      served = personalized.gem_file_path("nokogiri", column)
      assert_equal Digest::SHA256.file(served).hexdigest, checksum, column
      assert_equal checksum, personalized.gem_checksum("nokogiri", column), column
    end
  end
end
