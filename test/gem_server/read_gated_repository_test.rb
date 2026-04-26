require_relative "../test_helper"

class ReadGatedRepositoryTest < Minitest::Test
  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @directory_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
  end

  def test_gem_names_with_all_gems_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_equal ["minuscule_test", "zip_kit"], repository.gem_names.sort
  end

  def test_gem_names_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_equal ["zip_kit"], repository.gem_names
  end

  def test_gem_names_with_no_gems_entitled
    entitler = ->(name:, version: nil) { false }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_equal [], repository.gem_names
  end

  def test_gem_versions_with_all_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert_equal 3, versions.length

    # standard:disable Style/HashSlice
    zip_kit_versions = versions.select { |name, _| name == "zip_kit" }
    # standard:enable Style/HashSlice
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.0"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.1"
  end

  def test_gem_versions_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert_equal 2, versions.length
    versions.each do |name, _|
      assert_equal "zip_kit", name
    end

    zip_kit_versions = versions.map { |_, v| v }
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
  end

  def test_gem_versions_with_subset_of_zip_kit_versions_entitled
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || version == "6.2.0")
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    versions = repository.gem_versions
    assert_equal 1, versions.length
    assert_equal "zip_kit", versions.first.first
    assert_equal "6.2.0", versions.first.last
  end

  def test_versions_for_gem_with_all_versions_entitled
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
  end

  def test_versions_for_gem_with_only_zip_kit_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"

    assert_equal [], repository.versions_for_gem("minuscule_test")
  end

  def test_versions_for_gem_with_subset_of_versions_entitled
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || version == "6.2.0")
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal ["6.2.0"], zip_kit_versions
  end

  def test_versions_for_gem_with_gem_not_entitled
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_equal [], repository.versions_for_gem("minuscule_test")
  end

  def test_gem_file_path_with_entitled_version
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    expected_path = File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem")
    assert_equal expected_path, repository.gem_file_path("zip_kit", "6.2.0")
  end

  def test_gem_file_path_with_not_entitled_version
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || version == "6.2.0")
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    expected_path = File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem")
    assert_equal expected_path, repository.gem_file_path("zip_kit", "6.2.0")

    assert_nil repository.gem_file_path("zip_kit", "6.2.1")
  end

  def test_gem_file_path_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_nil repository.gem_file_path("minuscule_test", "0.1.0")
  end

  def test_gem_exists_with_entitled_version
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert repository.gem_exists?("zip_kit", "6.2.0")
    assert repository.gem_exists?("zip_kit", "6.2.1")
    assert repository.gem_exists?("minuscule_test", "0.1.0")
  end

  def test_gem_exists_with_not_entitled_version
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || version == "6.2.0")
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert repository.gem_exists?("zip_kit", "6.2.0")
    assert_equal false, repository.gem_exists?("zip_kit", "6.2.1")
  end

  def test_gem_exists_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    assert_equal false, repository.gem_exists?("minuscule_test", "0.1.0")
  end

  def test_compact_info_with_entitled_gem
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 2, info.length
    info.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line)
    end

    versions = info.map { |line| line.split(" ")[0] }
    assert_includes versions, "6.2.0"
    assert_includes versions, "6.2.1"
  end

  def test_compact_info_with_not_entitled_gem
    entitler = ->(name:, version: nil) { name == "zip_kit" }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 2, info.length

    assert_equal [], repository.compact_info("minuscule_test")
  end

  def test_compact_info_with_subset_of_versions_entitled
    entitler = ->(name:, version: nil) do
      name == "zip_kit" && (version.nil? || version == "6.2.0")
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    info = repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 1, info.length
    assert_equal "6.2.0", info.first.split(" ")[0]
  end

  def test_add_gem_raises_write_not_allowed
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository) { |**| true }

    assert_raises(Paquette::GemServer::ReadGatedRepository::WriteNotAllowed) do
      repository.add_gem("anything")
    end
  end

  def test_yank_gem_raises_write_not_allowed
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository) { |**| true }

    assert_raises(Paquette::GemServer::ReadGatedRepository::WriteNotAllowed) do
      repository.yank_gem("zip_kit", "6.2.0")
    end
  end

  def test_delegated_methods_still_work
    # Test that methods not overridden in ReadGatedRepository still delegate correctly
    entitler = ->(name:, version: nil) { true }
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    spec = repository.gem_spec("zip_kit", "6.2.0")
    refute_nil spec
    assert_equal "zip_kit", spec.name
    assert_equal "6.2.0", spec.version.to_s

    deps = repository.gem_dependencies("zip_kit", "6.2.0")
    assert deps.is_a?(Array)
  end

  def test_complex_entitlement_logic
    # Allow zip_kit >= 6.2.1 and all minuscule_test
    entitler = ->(name:, version: nil) do
      if name == "zip_kit"
        version.nil? || Gem::Version.new(version) >= Gem::Version.new("6.2.1")
      else
        name == "minuscule_test"
      end
    end
    repository = Paquette::GemServer::ReadGatedRepository.new(@directory_repository, &entitler)

    names = repository.gem_names
    assert_includes names, "zip_kit"
    assert_includes names, "minuscule_test"

    zip_kit_versions = repository.versions_for_gem("zip_kit")
    assert_equal ["6.2.1"], zip_kit_versions

    minuscule_versions = repository.versions_for_gem("minuscule_test")
    assert_equal ["0.1.0"], minuscule_versions
  end
end
