require_relative "test_helper"

class GatedGemRepositoryTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @directory_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
  end

  def test_gem_names_with_all_gems_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    names = repository.gem_names
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
    assert_includes names, "minuscule_test"
    assert_equal 4, names.length
  end

  def test_gem_names_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    names = repository.gem_names
    assert_includes names, "zip_kit"
    refute_includes names, "scatter_gather"
    refute_includes names, "test-gem"
    assert_equal 1, names.length
  end

  def test_gem_names_with_no_gems_entitled
    entitler = ->(name:, version: nil) { false }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    names = repository.gem_names
    assert_equal 0, names.length
  end

  def test_gem_versions_with_all_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert versions.length >= 7 # Total number of gem files

    # Check for zip_kit versions
    # standard:disable Style/HashSlice
    zip_kit_versions = versions.select { |name, _| name == "zip_kit" }
    # standard:enable Style/HashSlice
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.0"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.1"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.3.2"
  end

  def test_gem_versions_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert_equal 3, versions.length

    # All versions should be zip_kit
    versions.each do |name, version|
      assert_equal "zip_kit", name
    end

    zip_kit_versions = versions.map { |_, v| v }
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"
  end

  def test_gem_versions_with_subset_of_zip_kit_versions_entitled
    # Only allow zip_kit 6.2.0 and 6.2.1, but not 6.3.2
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || ["6.2.0", "6.2.1"].include?(version))
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert_equal 2, versions.length

    zip_kit_versions = versions.map { |_, v| v }
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    refute_includes zip_kit_versions, "6.3.2"
  end

  def test_versions_for_gem_with_all_versions_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"
  end

  def test_versions_for_gem_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # zip_kit should return all versions
    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"

    # scatter_gather should return empty array (not entitled)
    scatter_versions = repository.versions_for_gem("scatter_gather")
    assert_equal 0, scatter_versions.length
  end

  def test_versions_for_gem_with_subset_of_versions_entitled
    # Only allow zip_kit 6.2.0 and 6.2.1
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || ["6.2.0", "6.2.1"].include?(version))
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    refute_includes zip_kit_versions, "6.3.2"
  end

  def test_versions_for_gem_with_gem_not_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # scatter_gather is not entitled, should return empty array
    scatter_versions = repository.versions_for_gem("scatter_gather")
    assert_equal 0, scatter_versions.length
  end

  def test_gem_file_path_with_entitled_version
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    expected_path = File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem")
    assert_equal expected_path, repository.gem_file_path("zip_kit", "6.2.0")
  end

  def test_gem_file_path_with_not_entitled_version
    # Only allow zip_kit 6.2.0 and 6.2.1, not 6.3.2
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || ["6.2.0", "6.2.1"].include?(version))
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # Should return path for entitled version
    expected_path = File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem")
    assert_equal expected_path, repository.gem_file_path("zip_kit", "6.2.0")

    # Should return nil for not entitled version
    assert_nil repository.gem_file_path("zip_kit", "6.3.2")
  end

  def test_gem_file_path_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # scatter_gather is not entitled
    assert_nil repository.gem_file_path("scatter_gather", "0.1.0")
  end

  def test_gem_exists_with_entitled_version
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    assert repository.gem_exists?("zip_kit", "6.2.0")
    assert repository.gem_exists?("zip_kit", "6.2.1")
    assert repository.gem_exists?("scatter_gather", "0.1.0")
  end

  def test_gem_exists_with_not_entitled_version
    # Only allow zip_kit 6.2.0 and 6.2.1
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || ["6.2.0", "6.2.1"].include?(version))
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # Should return true for entitled versions
    assert repository.gem_exists?("zip_kit", "6.2.0")
    assert repository.gem_exists?("zip_kit", "6.2.1")

    # Should return nil (not true) for not entitled version
    assert_nil repository.gem_exists?("zip_kit", "6.3.2")
  end

  def test_gem_exists_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # scatter_gather is not entitled
    assert_nil repository.gem_exists?("scatter_gather", "0.1.0")
  end

  def test_compact_info_with_entitled_gem
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 3, info.length

    # Check that each line has the compact index format
    info.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line)
    end

    versions = info.map { |line| line.split(" ")[0] }
    assert_includes versions, "6.2.0"
    assert_includes versions, "6.2.1"
    assert_includes versions, "6.3.2"
  end

  def test_compact_info_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # zip_kit is entitled
    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 3, info.length

    # scatter_gather is not entitled
    info = repository.compact_info("scatter_gather")
    assert_nil info
  end

  def test_compact_info_with_subset_of_versions_entitled
    # Only allow zip_kit 6.2.0 and 6.2.1
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || ["6.2.0", "6.2.1"].include?(version))
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 2, info.length

    versions = info.map { |line| line.split(" ")[0] }
    assert_includes versions, "6.2.0"
    assert_includes versions, "6.2.1"
    refute_includes versions, "6.3.2"
  end

  def test_delegated_methods_still_work
    # Test that methods not overridden in GatedGemRepository still delegate correctly
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # Test gem_spec delegation
    spec = repository.gem_spec("zip_kit", "6.2.0")
    refute_nil spec
    assert_equal "zip_kit", spec.name
    assert_equal "6.2.0", spec.version.to_s

    # Test gem_dependencies delegation
    deps = repository.gem_dependencies("zip_kit", "6.2.0")
    assert deps.is_a?(Array)
  end

  def test_complex_entitlement_logic
    # Complex scenario: allow only zip_kit versions >= 6.2.1 and all scatter_gather
    entitler = ->(name:, version: nil) do
      if name == "zip_kit"
        version.nil? || Gem::Version.new(version) >= Gem::Version.new("6.2.1")
      else
        name == "scatter_gather"
      end
    end
    repository = Paquette::GemServer::GatedGemRepository.new(@directory_repository, &entitler)

    # gem_names should include both
    names = repository.gem_names
    assert_includes names, "zip_kit"
    assert_includes names, "scatter_gather"
    refute_includes names, "test-gem"

    # zip_kit should only have versions >= 6.2.1
    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 2, zip_kit_versions.length
    refute_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"

    # scatter_gather should have all versions
    scatter_versions = repository.versions_for_gem("scatter_gather")
    assert_equal 2, scatter_versions.length
    assert_includes scatter_versions, "0.1.0"
    assert_includes scatter_versions, "0.1.1"
  end
end
