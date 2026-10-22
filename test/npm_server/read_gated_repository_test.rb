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

  def gated(repository = @repository, &entitler)
    Paquette::NpmServer::ReadGatedRepository.new(repository, EntitlingAuthenticator.new(&entitler))
  end

  def allowing_everything
    gated { |name:, version: nil| true }
  end

  def allowing_nothing
    gated { |name:, version: nil| false }
  end

  # The summary fields come from one version, and must be one the caller may
  # read, or a lapsed licensee reads the README of a release they did not get
  def test_the_package_s_summary_is_the_newest_entitled_version_s
    Dir.mktmpdir("paquette_npm_summary") do |dir|
      write_npm_package(dir, name: "helpers", version: "1.0.0", description: "One",
        homepage: "https://one.example", files: {"README.md" => "# Helpers 1.0.0\n"})
      write_npm_package(dir, name: "helpers", version: "1.1.0", description: "Withheld",
        homepage: "https://withheld.example", keywords: ["withheld"], files: {"README.md" => "# Helpers 1.1.0, withheld\n"})
      repository = Paquette::NpmServer::DirectoryNpmRepository.new(dir)
      lapsed = gated(repository) { |name:, version: nil| version.nil? || version == "1.0.0" }

      metadata = lapsed.package_metadata("helpers")

      assert_equal ["1.0.0"], metadata["versions"].keys
      assert_equal "# Helpers 1.0.0\n", metadata["readme"]
      assert_equal "One", metadata["description"]
      assert_equal "https://one.example", metadata["homepage"]
      refute_includes JSON.dump(metadata), "ithheld"
    end
  end

  # A repository that predates package_summary gets none at all
  def test_a_repository_without_a_summary_leaks_none
    inner = Object.new
    def inner.package_metadata(_) = {"versions" => {"1.0.0" => {}, "2.0.0" => {}}, "time" => {}, "readme" => "2.0.0 secrets", "description" => "2.0.0"}
    def inner.versions_for_package(_) = ["1.0.0", "2.0.0"]
    def inner.dist_tags(_) = {"latest" => "2.0.0"}
    gate = gated(inner) { |name:, version: nil| version.nil? || version == "1.0.0" }

    metadata = gate.package_metadata("helpers")

    assert_nil metadata["readme"]
    assert_nil metadata["description"]
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
  def test_a_fully_gated_package_is_absent_rather_than_empty
    assert_nil allowing_nothing.package_metadata("allowed")
  end

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

  # Who may write is the authenticator's to say, not the gate's
  def test_writes_pass_through
    repo = allowing_everything

    repo.add_package(npm_tarball_bytes(name: "new", version: "1.0.0"))
    assert repo.package_exists?("new", "1.0.0")

    repo.write_dist_tag("new", "next", "1.0.0")
    assert_equal "1.0.0", repo.dist_tags("new")["next"]

    repo.yank_package("new", "1.0.0")
    refute repo.package_exists?("new", "1.0.0")
  end

  # The server puts the gate on for every caller whose authenticator answers
  # entitled?, so nothing has to be wired for one.
  def test_the_server_gates_by_the_caller_s_authenticator
    app = Paquette::NpmServer.new(@repository, authenticator: EntitlingAuthenticator.gating { |name:, version: nil| name == "allowed" })
    request = Rack::MockRequest.new(app)

    assert_equal 200, request.get("/allowed").status
    assert_equal 404, request.get("/denied").status
  end

  # The validator is what the caller can see, so it moves when and only when
  # that does, and a caller who sees nothing in scope gets none.
  def test_the_validator_names_what_the_caller_can_see
    everything = allowing_everything.cache_validator("allowed")
    ones = gated { |name:, version: nil| version.nil? || version.start_with?("1.") }.cache_validator("allowed")

    refute_nil everything
    refute_nil ones
    refute_equal everything, ones
    assert_equal everything, allowing_everything.cache_validator("allowed")
    assert_nil allowing_nothing.cache_validator("allowed")
    assert_nil allowing_nothing.cache_validator
    refute_equal allowing_everything.cache_validator, allowing_everything.cache_validator("allowed")
  end
end
