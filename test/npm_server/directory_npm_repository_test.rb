require_relative "../test_helper"

class DirectoryNpmRepositoryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_npm_repo_test")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def test_package_names_includes_scoped_packages
    write_npm_package(@dir, name: "lodash", version: "4.17.21")
    write_npm_package(@dir, name: "@acme/widgets", version: "1.0.0")
    write_npm_package(@dir, name: "@acme/gadgets", version: "1.0.0")

    assert_equal ["@acme/gadgets", "@acme/widgets", "lodash"], @repository.package_names
  end

  def test_package_versions
    write_npm_package(@dir, name: "lodash", version: "4.17.21")
    write_npm_package(@dir, name: "@acme/widgets", version: "1.0.0")

    assert_equal [["@acme/widgets", "1.0.0"], ["lodash", "4.17.21"]], @repository.package_versions
  end

  def test_versions_are_ordered_by_semver_not_by_string
    %w[1.0.0 1.0.2 1.0.10 1.2.0].each do |version|
      write_npm_package(@dir, name: "widget", version: version)
    end

    assert_equal %w[1.0.0 1.0.2 1.0.10 1.2.0], @repository.versions_for_package("widget")
  end

  def test_package_info_comes_from_the_tarball
    write_npm_package(@dir, name: "widget", version: "1.0.0",
      dependencies: {"left-pad" => "^1.3.0"}, engines: {"node" => ">=18"})

    info = @repository.package_info("widget", "1.0.0")
    assert_equal "widget", info["name"]
    assert_equal({"left-pad" => "^1.3.0"}, info["dependencies"])
    assert_equal({"node" => ">=18"}, info["engines"])
  end

  def test_package_dependencies
    write_npm_package(@dir, name: "widget", version: "1.0.0", dependencies: {"left-pad" => "^1.3.0"})

    assert_equal({"left-pad" => "^1.3.0"}, @repository.package_dependencies("widget", "1.0.0"))
  end

  def test_dist_hashes_describe_the_file_on_disk
    path = write_npm_package(@dir, name: "widget", version: "1.0.0")

    dist = @repository.dist_for("widget", "1.0.0")
    assert_equal Digest::SHA1.file(path).hexdigest, dist["shasum"]
    assert_equal "sha512-" + [Digest::SHA512.file(path).digest].pack("m0"), dist["integrity"]
    assert_equal "/widget/-/widget-1.0.0.tgz", dist["tarball"]
  end

  def test_scoped_tarball_path_drops_the_scope_from_the_filename
    write_npm_package(@dir, name: "@acme/widgets", version: "1.0.0")

    assert_equal "/@acme/widgets/-/widgets-1.0.0.tgz", @repository.dist_for("@acme/widgets", "1.0.0")["tarball"]
    assert_path_exists @repository.package_file_path("@acme/widgets", "1.0.0")
  end

  def test_metadata_times_come_from_the_file_rather_than_the_clock
    path = write_npm_package(@dir, name: "widget", version: "1.0.0")
    published_at = Time.utc(2020, 3, 4, 5, 6, 7)
    File.utime(published_at, published_at, path)

    metadata = @repository.package_metadata("widget")
    assert_equal published_at.iso8601, metadata["time"]["1.0.0"]
    assert_equal published_at.iso8601, metadata["time"]["created"]
  end

  def test_metadata_document_fields_come_from_the_latest_version
    write_npm_package(@dir, name: "widget", version: "1.0.0", description: "the old one")
    write_npm_package(@dir, name: "widget", version: "2.0.0", description: "the current one",
      homepage: "https://example.com")

    metadata = @repository.package_metadata("widget")
    assert_equal "the current one", metadata["description"]
    assert_equal "https://example.com", metadata["homepage"]
    assert_equal "# widget\n", metadata["readme"]
  end

  def test_metadata_is_nil_for_an_unknown_package
    assert_nil @repository.package_metadata("nope")
  end

  # A package name is also a path.
  def test_a_traversing_name_resolves_to_nothing
    assert_nil @repository.package_file_path("../../etc", "1.0.0")
    refute @repository.package_exists?("../../etc", "1.0.0")
    assert_empty @repository.versions_for_package("../../etc")
  end

  def test_add_package
    info = @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))

    assert_equal "widget", info["name"]
    assert @repository.package_exists?("widget", "1.0.0")
  end

  def test_add_scoped_package
    @repository.add_package(npm_tarball_bytes(name: "@acme/widgets", version: "1.0.0"))

    assert @repository.package_exists?("@acme/widgets", "1.0.0")
    assert_equal ["@acme/widgets"], @repository.package_names
  end

  def test_add_package_refuses_an_existing_version
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))

    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::PackageAlreadyExists) do
      @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    end
  end

  def test_add_package_refuses_junk
    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::InvalidPackage) do
      @repository.add_package("not a tarball at all")
    end
  end

  def test_add_package_refuses_an_empty_payload
    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::InvalidPackage) do
      @repository.add_package("")
    end
  end

  def test_yank_package_leaves_a_tomb_that_blocks_republishing
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    @repository.yank_package("widget", "1.0.0")

    refute @repository.package_exists?("widget", "1.0.0")
    assert @repository.tomb_exists?("widget", "1.0.0")

    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::PackageYanked) do
      @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    end
  end

  def test_yank_package_on_an_unknown_version
    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::PackageNotFound) do
      @repository.yank_package("widget", "1.0.0")
    end
  end

  def test_dist_tags_persist_across_publishes
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "2.0.0-beta.1"),
      dist_tags: {"beta" => "2.0.0-beta.1"})

    tags = @repository.dist_tags("widget")
    assert_equal "1.0.0", tags["latest"]
    assert_equal "2.0.0-beta.1", tags["beta"]
  end

  # A tag pointing at a version that is no longer there would send npm to a 404.
  def test_a_tag_is_dropped_when_its_version_is_unpublished
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "2.0.0-beta.1"),
      dist_tags: {"beta" => "2.0.0-beta.1"})
    @repository.yank_package("widget", "2.0.0-beta.1")

    refute_includes @repository.dist_tags("widget").keys, "beta"
  end

  def test_write_dist_tag
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.1.0"))

    @repository.write_dist_tag("widget", "stable", "1.0.0")
    assert_equal "1.0.0", @repository.dist_tags("widget")["stable"]
  end

  def test_latest_cannot_be_pointed_elsewhere
    @repository.add_package(npm_tarball_bytes(name: "widget", version: "1.0.0"))

    assert_raises(Paquette::NpmServer::DirectoryNpmRepository::InvalidPackage) do
      @repository.write_dist_tag("widget", "latest", "1.0.0")
    end
  end

  def test_replacing_a_tarball_is_noticed
    write_npm_package(@dir, name: "widget", version: "1.0.0", description: "first")
    assert_equal "first", @repository.package_info("widget", "1.0.0")["description"]

    sleep 0.01
    write_npm_package(@dir, name: "widget", version: "1.0.0", description: "second")
    assert_equal "second", @repository.package_info("widget", "1.0.0")["description"]
  end
end
