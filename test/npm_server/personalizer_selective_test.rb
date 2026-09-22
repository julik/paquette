require_relative "../test_helper"
require "digest"

# The files_for:/personalization_key:/cache_dir: side of the npm Personalizer;
# twin of the gem-side PersonalizerSelectiveTest.
class NpmPersonalizerSelectiveTest < Minitest::Test
  PACKAGE = "@acme/widgets"

  def setup
    @packages_dir = Dir.mktmpdir("npm_personalizer_selective")
    write_npm_package(@packages_dir, name: PACKAGE, version: "1.0.0")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    @cache_dir = Dir.mktmpdir("npm_personalizer_selective_cache")
  end

  def teardown
    FileUtils.remove_entry(@packages_dir)
    FileUtils.remove_entry(@cache_dir)
  end

  def test_cache_dir_is_where_personalized_tarballs_land
    personalizer = Paquette::NpmServer::Personalizer.new(@repository, license_key: "L-1", cache_dir: @cache_dir)

    path = personalizer.package_file_path(PACKAGE, "1.0.0")

    assert File.exist?(path)
    assert path.start_with?(@cache_dir), "expected #{path} under #{@cache_dir}"
  end

  def test_files_for_injects_per_package_content_and_is_asked_once_per_file
    calls = 0
    personalizer = Paquette::NpmServer::Personalizer.new(@repository,
      license_key: "L-1",
      personalization_key: "Licensee One",
      files_for: ->(name, version, _path) {
        calls += 1
        {"LICENSE-NOTE.txt" => "For Licensee One: #{name} #{version}"}
      },
      cache_dir: @cache_dir)

    first = personalizer.package_file_path(PACKAGE, "1.0.0")
    second = personalizer.package_file_path(PACKAGE, "1.0.0")

    assert_equal first, second
    assert_equal 1, calls, "the cache answers before files_for is asked again"
    assert_equal "For Licensee One: #{PACKAGE} 1.0.0", tarball_file(first, "package/LICENSE-NOTE.txt")

    # The integrity the document advertises is the served file's.
    assert_equal Digest::SHA1.file(first).hexdigest, personalizer.dist_for(PACKAGE, "1.0.0")["shasum"]
  end

  def test_files_for_nil_serves_the_original_and_keeps_the_repository_s_hashes
    calls = 0
    personalizer = Paquette::NpmServer::Personalizer.new(@repository,
      license_key: "L-1",
      files_for: ->(*) {
        calls += 1
        nil
      },
      cache_dir: @cache_dir)

    original = @repository.package_file_path(PACKAGE, "1.0.0")

    assert_equal original, personalizer.package_file_path(PACKAGE, "1.0.0")
    assert_equal original, personalizer.package_file_path(PACKAGE, "1.0.0")
    assert_equal 1, calls, "the opt-out marker answers before files_for is asked again"
    assert_equal @repository.dist_for(PACKAGE, "1.0.0"), personalizer.dist_for(PACKAGE, "1.0.0")
    assert_equal 1, Dir.glob(File.join(@cache_dir, "*.plain")).length
  end

  def test_two_personalization_keys_never_share_a_file
    build_for = ->(key) do
      Paquette::NpmServer::Personalizer.new(@repository,
        license_key: "L-1",
        personalization_key: key,
        files_for: ->(_name, _version, _path) { {"LICENSE-NOTE.txt" => "For #{key}"} },
        cache_dir: @cache_dir).package_file_path(PACKAGE, "1.0.0")
    end

    one = build_for.call("Licensee One")
    other = build_for.call("Licensee Two")

    refute_equal one, other
    assert_equal "For Licensee One", tarball_file(one, "package/LICENSE-NOTE.txt")
    assert_equal "For Licensee Two", tarball_file(other, "package/LICENSE-NOTE.txt")
  end
end
