require_relative "../test_helper"

# Versions that are not three dot-separated integers, which is most of the
# interesting ones. These used to be accepted by a push, written to disk, and
# then invisible: versions_for_gem returned [], so compact_info returned [],
# so /info/ 404ed and /versions never listed the gem, and the download route
# refused the very filename the push had written. No error anywhere — the gem
# simply was not there.
#
# case_transform-0.2 and rails_twirp-0.17 are real, published gems, and both
# were lost this way.
class GemServerVersionShapesTest < Minitest::Test
  include Rack::Test::Methods

  # The version column as it appears in a filename: a version, optionally
  # followed by a platform. The value is what the server must report back.
  PUSHABLE_VERSIONS = {
    "case_transform" => "0.2",
    "rails_twirp" => "0.17",
    "prerelease_gem" => "1.0.pre",
    "four_segments" => "1.2.3.4",
    "single_segment" => "2",
    "classic" => "6.2.1"
  }.freeze

  def setup
    @tmpdir = Dir.mktmpdir("paquette_version_shapes")
    @gems_dir = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(@gems_dir)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @app = Paquette::GemServer.new(@repository)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  attr_reader :app

  def test_a_pushed_gem_is_visible_at_every_version_shape
    PUSHABLE_VERSIONS.each do |name, version|
      push_gem(name, version)

      assert_equal [version], @repository.versions_for_gem(name),
        "#{name}-#{version} was accepted by the push and then not found on disk"
      assert_includes @repository.gem_versions, [name, version]
      refute_empty @repository.compact_info(name), "#{name}-#{version} has no /info/ line"
    end
  end

  def test_every_version_shape_reaches_the_http_endpoints
    PUSHABLE_VERSIONS.each do |name, version|
      push_gem(name, version)

      get "/info/#{name}"
      assert_equal 200, last_response.status, "/info/#{name} for #{version}"
      assert_includes last_response.body, version

      get "/versions"
      assert_equal 200, last_response.status
      assert_includes last_response.body, "#{name} #{version} "

      get "/names"
      assert_includes last_response.body.split("\n"), name

      get "/gems/#{name}-#{version}.gem"
      assert_equal 200, last_response.status, "/gems/#{name}-#{version}.gem"
      assert_equal File.binread(@repository.gem_file_path(name, version)), last_response.body

      get "/quick/Marshal.4.8/#{name}-#{version}.gemspec.rz"
      assert_equal 200, last_response.status, "/quick for #{name}-#{version}"
    end
  end

  # The two-segment case, spelled out on its own so a regression names the gem
  # it broke rather than a loop index.
  def test_rails_twirp_at_0_17_downloads
    push_gem("rails_twirp", "0.17")

    get "/gems/rails_twirp-0.17.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.headers["Content-Type"]
  end

  def test_case_transform_at_0_2_downloads
    push_gem("case_transform", "0.2")

    get "/gems/case_transform-0.2.gem"
    assert_equal 200, last_response.status
  end

  # A platform-suffixed filename carries something in the version column that
  # is not a version at all. Built rather than pushed: the push keys a gem on
  # spec.version, which drops the platform, so putting the file on disk is the
  # only way to have this filename to serve.
  def test_a_platform_suffixed_gem_is_served_under_its_filename
    build_gem_on_disk("nokogiri_stub", "1.16.0", platform: "arm64-darwin")
    column = "1.16.0-arm64-darwin"

    assert_equal [column], @repository.versions_for_gem("nokogiri_stub")
    refute_empty @repository.compact_info("nokogiri_stub")

    get "/gems/nokogiri_stub-#{column}.gem"
    assert_equal 200, last_response.status

    get "/info/nokogiri_stub"
    assert_equal 200, last_response.status
    assert_includes last_response.body, column
  end

  # Several shapes of one gem at once, because versions_for_gem sorts and
  # every whole-index endpoint walks what it returns.
  def test_one_gem_at_several_version_shapes_lists_all_of_them
    %w[0.2 0.17 1.0.pre 1.2.3].each { |version| push_gem("mixed_versions", version) }

    assert_equal %w[0.17 0.2 1.0.pre 1.2.3], @repository.versions_for_gem("mixed_versions")
    assert_equal 4, @repository.compact_info("mixed_versions").length

    get "/versions"
    assert_includes last_response.body, "mixed_versions 0.17,0.2,1.0.pre,1.2.3 "
  end

  # The dash between name and version is ambiguous, and the whole split lives
  # in one place now, so the repository and the download route agree about it.
  def test_a_name_ending_in_a_version_like_segment_round_trips
    push_gem("rack-2", "1.0.0")

    assert_equal ["1.0.0"], @repository.versions_for_gem("rack-2")
    assert_equal ["rack-2", "1.0.0"], Paquette::GemServer.split_gem_filename("rack-2-1.0.0.gem")

    get "/gems/rack-2-1.0.0.gem"
    assert_equal 200, last_response.status
  end

  # versions_for_gem no longer compiles a pattern out of the name it was
  # handed, so a name that is not valid UTF-8 has to come back empty rather
  # than raise out of the compile.
  def test_a_name_that_is_not_valid_utf8_is_not_a_crash
    assert_equal [], @repository.versions_for_gem("zip\xFF_kit".b)
    assert_equal [], @repository.compact_info("zip\xFF_kit".b)
  end

  private

  def push_gem(name, version)
    post "/api/v1/gems", gem_bytes(name, version), "CONTENT_TYPE" => "application/octet-stream"
    assert_equal 200, last_response.status, "pushing #{name}-#{version}: #{last_response.body}"
  end

  def build_gem_on_disk(name, version, platform: nil)
    bytes, filename = gem_bytes(name, version, platform: platform, with_filename: true)
    FileUtils.mkdir_p(File.join(@gems_dir, name))
    File.binwrite(File.join(@gems_dir, name, filename), bytes)
  end

  def gem_bytes(name, version, platform: nil, with_filename: false)
    module_name = name.split(/[_-]/).map(&:capitalize).join
    source_dir = File.join(@tmpdir, "src", "#{name}-#{version}-#{platform}")
    FileUtils.mkdir_p(File.join(source_dir, "lib"))
    File.write(File.join(source_dir, "lib", "fixture.rb"), "module #{module_name}; end\n")

    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.platform = platform if platform
      s.summary = "Paquette version shape fixture"
      s.authors = ["Paquette"]
      s.files = ["lib/fixture.rb"]
      s.license = "MIT"
    end

    built = nil
    capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }
    bytes = File.binread(File.join(source_dir, built))

    with_filename ? [bytes, built] : bytes
  end
end
