require_relative "../test_helper"

class NpmReadGatedRepositoryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_npm_gated_test")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)

    write_npm_package(@dir, name: "allowed", version: "1.0.0")
    write_npm_package(@dir, name: "allowed", version: "1.1.0")
    write_npm_package(@dir, name: "allowed", version: "2.0.0")
    write_npm_package(@dir, name: "denied", version: "1.0.0")
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def gated(&entitler)
    Paquette::NpmServer::ReadGatedRepository.new(@repository, &entitler)
  end

  def allowing_everything
    gated { |name:, version: nil| true }
  end

  def allowing_nothing
    gated { |name:, version: nil| false }
  end

  def test_package_names_are_filtered
    repo = gated { |name:, version: nil| name == "allowed" }
    assert_equal ["allowed"], repo.package_names
  end

  def test_versions_are_filtered
    repo = gated { |name:, version: nil| version.nil? || version.start_with?("1.") }
    assert_equal %w[1.0.0 1.1.0], repo.versions_for_package("allowed")
  end

  def test_package_exists_returns_false_rather_than_nil
    repo = allowing_nothing
    assert_equal false, repo.package_exists?("allowed", "1.0.0")
  end

  def test_package_file_path_is_withheld
    assert_nil allowing_nothing.package_file_path("allowed", "1.0.0")
  end

  def test_package_info_is_withheld
    assert_nil allowing_nothing.package_info("allowed", "1.0.0")
    assert_empty allowing_nothing.package_dependencies("allowed", "1.0.0")
  end

  def test_metadata_only_carries_entitled_versions
    repo = gated { |name:, version: nil| version.nil? || version != "2.0.0" }
    metadata = repo.package_metadata("allowed")

    assert_equal %w[1.0.0 1.1.0], metadata["versions"].keys.sort
    assert_equal %w[1.0.0 1.1.0], (metadata["time"].keys - %w[created modified]).sort
  end

  # A package whose every version is gated away does not exist for this caller.
  # An empty versions map would otherwise be served as a real package that
  # happens to be uninstallable.
  def test_a_fully_gated_package_is_absent_rather_than_empty
    assert_nil allowing_nothing.package_metadata("allowed")
  end

  # latest has to keep pointing at something this caller may actually download.
  def test_latest_falls_back_to_the_newest_entitled_version
    repo = gated { |name:, version: nil| version.nil? || version != "2.0.0" }

    assert_equal "1.1.0", repo.dist_tags("allowed")["latest"]
    assert_equal "1.1.0", repo.package_metadata("allowed")["dist-tags"]["latest"]
  end

  def test_a_tag_pointing_outside_the_entitlement_is_dropped
    @repository.write_dist_tag("allowed", "next", "2.0.0")
    repo = gated { |name:, version: nil| version.nil? || version != "2.0.0" }

    refute_includes repo.dist_tags("allowed").keys, "next"
  end

  def test_metadata_for_a_denied_package
    repo = gated { |name:, version: nil| name != "denied" }
    assert_nil repo.package_metadata("denied")
    assert_empty repo.dist_tags("denied")
  end

  def test_writes_are_refused
    repo = allowing_everything

    assert_raises(Paquette::NpmServer::ReadGatedRepository::WriteNotAllowed) do
      repo.add_package(npm_tarball_bytes(name: "new", version: "1.0.0"))
    end

    assert_raises(Paquette::NpmServer::ReadGatedRepository::WriteNotAllowed) do
      repo.yank_package("allowed", "1.0.0")
    end

    assert_raises(Paquette::NpmServer::ReadGatedRepository::WriteNotAllowed) do
      repo.write_dist_tag("allowed", "next", "1.0.0")
    end
  end

  def test_the_former_name_still_builds_a_stack
    repo = Paquette::NpmServer::GatedNpmRepository.new(@repository) { |name:, version: nil| name == "allowed" }
    assert_equal ["allowed"], repo.package_names
  end
end
