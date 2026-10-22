require_relative "../test_helper"
require "digest"

# The cache_dir: side of the npm Personalizer - where files land, which
# packages opt out, and the promise that the caches answer before the tarball
# is ever opened; twin of the gem-side PersonalizerSelectiveTest.
class NpmPersonalizerSelectiveTest < Minitest::Test
  PACKAGE = "@acme/widgets"

  def setup
    @packages_dir = Dir.mktmpdir("npm_personalizer_selective")
    write_npm_package(@packages_dir, name: PACKAGE, version: "1.0.0",
      files: {"index.js" => "// paquette:licensee\nmodule.exports = 1;\n"})
    write_npm_package(@packages_dir, name: "plain", version: "1.0.0")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    @cache_dir = Dir.mktmpdir("npm_personalizer_selective_cache")
  end

  def teardown
    FileUtils.remove_entry(@packages_dir)
    FileUtils.remove_entry(@cache_dir)
  end

  def personalizer(**options)
    Paquette::NpmServer::Personalizer.new(@repository, cache_dir: @cache_dir, **options)
  end

  def as(licensee, &block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, {"licensee" => licensee}), &block)
  end

  def test_cache_dir_is_where_personalized_tarballs_land
    path = as("Licensee One") { personalizer.package_file_path(PACKAGE, "1.0.0") }

    assert File.exist?(path)
    assert path.start_with?(@cache_dir), "expected #{path} under #{@cache_dir}"
  end

  def test_a_personalized_tarball_is_built_once_and_then_reused
    repo = personalizer(files: {"LICENSE-NOTE.txt" => "For\n  paquette:licensee\n"})

    first = as("Licensee One") { repo.package_file_path(PACKAGE, "1.0.0") }
    built_at = File.mtime(first)
    second = as("Licensee One") { repo.package_file_path(PACKAGE, "1.0.0") }

    assert_equal first, second
    assert_equal built_at, File.mtime(second), "the cache answers before the tarball is repacked again"
    assert_equal "For\n  Licensee One\n", tarball_file(first, "package/LICENSE-NOTE.txt")

    # The integrity the document advertises is the served file's.
    as("Licensee One") do
      assert_equal Digest::SHA1.file(first).hexdigest, repo.dist_for(PACKAGE, "1.0.0")["shasum"]
    end
  end

  # Whether a package carries a marker is a fact about the package, written
  # down once and never asked of the licensee.
  def test_a_package_without_a_marker_is_served_as_it_is_and_remembered
    original = @repository.package_file_path("plain", "1.0.0")
    repo = personalizer

    as("Licensee One") do
      assert_equal original, repo.package_file_path("plain", "1.0.0")
      assert_equal @repository.dist_for("plain", "1.0.0"), repo.dist_for("plain", "1.0.0")
    end
    as("Licensee Two") { assert_equal original, repo.package_file_path("plain", "1.0.0") }

    assert_equal 1, Dir.glob(File.join(@cache_dir, "*.plain")).length
    assert_empty Dir.glob(File.join(@cache_dir, "*.tgz"))
  end

  def test_two_licensees_never_share_a_file
    repo = personalizer(files: {"LICENSE-NOTE.txt" => "paquette:licensee\n"})

    one = as("Licensee One") { repo.package_file_path(PACKAGE, "1.0.0") }
    other = as("Licensee Two") { repo.package_file_path(PACKAGE, "1.0.0") }

    refute_equal one, other
    assert_equal "Licensee One\n", tarball_file(one, "package/LICENSE-NOTE.txt")
    assert_equal "Licensee Two\n", tarball_file(other, "package/LICENSE-NOTE.txt")
  end

  # The injected files are part of what the cache is keyed on.
  def test_different_injected_files_never_share_a_file
    one = as("L") { personalizer(files: {"A.txt" => "a"}).package_file_path(PACKAGE, "1.0.0") }
    other = as("L") { personalizer(files: {"A.txt" => "b"}).package_file_path(PACKAGE, "1.0.0") }

    refute_equal one, other
  end
end
