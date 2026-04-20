require_relative "../test_helper"

class DirectoryGemRepositoryTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
  end

  def test_gem_names
    names = @repository.gem_names
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
    assert_includes names, "minuscule_test"
    assert_equal 4, names.length
  end

  def test_gem_versions
    versions = @repository.gem_versions
    assert versions.length >= 7 # Total number of gem files

    # Check for scatter_gather versions
    # standard:disable Style/HashSlice
    scatter_versions = versions.select { |name, _| name == "scatter_gather" }
    assert_equal 2, scatter_versions.length
    assert_includes scatter_versions.map { |_, v| v }, "0.1.0"
    assert_includes scatter_versions.map { |_, v| v }, "0.1.1"

    # Check for zip_kit versions
    # standard:disable Style/HashSlice
    zip_kit_versions = versions.select { |name, _| name == "zip_kit" }
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.0"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.1"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.3.2"

    # Check for minuscule_test versions
    # standard:disable Style/HashSlice
    minuscule_versions = versions.select { |name, _| name == "minuscule_test" }
    # standard:enable Style/HashSlice
    assert_equal 1, minuscule_versions.length
    assert_includes minuscule_versions.map { |_, v| v }, "0.1.0"
  end

  def test_versions_for_gem
    scatter_versions = @repository.versions_for_gem("scatter_gather")
    assert_equal 2, scatter_versions.length
    assert_includes scatter_versions, "0.1.0"
    assert_includes scatter_versions, "0.1.1"

    zip_kit_versions = @repository.versions_for_gem("zip_kit")
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"

    test_gem_versions = @repository.versions_for_gem("test-gem")
    assert_equal 1, test_gem_versions.length
    assert_includes test_gem_versions, "1.0.0"

    minuscule_versions = @repository.versions_for_gem("minuscule_test")
    assert_equal 1, minuscule_versions.length
    assert_includes minuscule_versions, "0.1.0"
  end

  def test_gem_exists
    assert @repository.gem_exists?("scatter_gather", "0.1.0")
    assert @repository.gem_exists?("scatter_gather", "0.1.1")
    assert @repository.gem_exists?("zip_kit", "6.2.0")
    assert @repository.gem_exists?("test-gem", "1.0.0")
    assert @repository.gem_exists?("minuscule_test", "0.1.0")

    refute @repository.gem_exists?("scatter_gather", "0.2.0")
    refute @repository.gem_exists?("nonexistent", "1.0.0")
  end

  def test_gem_file_path
    expected_path = File.join(@gems_dir, "scatter_gather", "scatter_gather-0.1.0.gem")
    assert_equal expected_path, @repository.gem_file_path("scatter_gather", "0.1.0")

    expected_path = File.join(@gems_dir, "zip_kit", "zip_kit-6.3.2.gem")
    assert_equal expected_path, @repository.gem_file_path("zip_kit", "6.3.2")

    expected_path = File.join(@gems_dir, "minuscule_test", "minuscule_test-0.1.0.gem")
    assert_equal expected_path, @repository.gem_file_path("minuscule_test", "0.1.0")
  end

  def test_gem_spec
    spec = @repository.gem_spec("test-gem", "1.0.0")
    refute_nil spec
    assert_equal "test-gem", spec.name
    assert_equal "1.0.0", spec.version.to_s

    spec = @repository.gem_spec("scatter_gather", "0.1.1")
    refute_nil spec
    assert_equal "scatter_gather", spec.name
    assert_equal "0.1.1", spec.version.to_s

    spec = @repository.gem_spec("minuscule_test", "0.1.0")
    refute_nil spec
    assert_equal "minuscule_test", spec.name
    assert_equal "0.1.0", spec.version.to_s

    # Test non-existent gem
    spec = @repository.gem_spec("nonexistent", "1.0.0")
    assert_nil spec
  end

  def test_gem_dependencies
    deps = @repository.gem_dependencies("test-gem", "1.0.0")
    assert deps.is_a?(Array)
    # The actual dependencies depend on what's in the test-gem.gem file

    deps = @repository.gem_dependencies("scatter_gather", "0.1.1")
    assert deps.is_a?(Array)
    # The actual dependencies depend on what's in the scatter_gather-0.1.1.gem file

    deps = @repository.gem_dependencies("minuscule_test", "0.1.0")
    assert deps.is_a?(Array)
    # The actual dependencies depend on what's in the minuscule_test-0.1.0.gem file

    # Test non-existent gem
    deps = @repository.gem_dependencies("nonexistent", "1.0.0")
    assert_equal [], deps
  end

  def test_add_gem_persists_file_and_returns_spec
    fixture = File.expand_path("./packages/gems/minuscule_test/minuscule_test-0.1.0.gem", Dir.pwd)
    binary = File.binread(fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      spec = repo.add_gem(binary)

      assert_equal "minuscule_test", spec.name
      assert_equal "0.1.0", spec.version.to_s
      assert repo.gem_exists?("minuscule_test", "0.1.0")
      assert_equal binary, File.binread(repo.gem_file_path("minuscule_test", "0.1.0"))
    end
  end

  def test_add_gem_rejects_duplicate
    fixture = File.expand_path("./packages/gems/minuscule_test/minuscule_test-0.1.0.gem", Dir.pwd)
    binary = File.binread(fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(binary)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::GemAlreadyExists) do
        repo.add_gem(binary)
      end
    end
  end

  def test_add_gem_rejects_invalid_payload
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem("")
      end

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem("not a real gem file")
      end
    end
  end

  def test_compact_info
    info = @repository.compact_info("scatter_gather")
    assert info.is_a?(Array)
    assert_equal 2, info.length

    # Check that each line has the format "version |checksum:sha256_checksum,ruby:required_ruby_version"
    info.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line, "Line should match compact index format: #{line}")
    end

    # Extract versions to check they're correct
    versions = info.map { |line| line.split(" ")[0] }
    assert_includes versions, "0.1.0"
    assert_includes versions, "0.1.1"

    info = @repository.compact_info("test-gem")
    assert info.is_a?(Array)
    assert_equal 1, info.length
    assert_match(/^1\.0\.0\s+\|checksum:[a-f0-9]{64},ruby:.+$/, info[0])

    info = @repository.compact_info("minuscule_test")
    assert info.is_a?(Array)
    assert_equal 1, info.length
    assert_match(/^0\.1\.0\s+\|checksum:[a-f0-9]{64},ruby:.+$/, info[0])

    # Test non-existent gem
    info = @repository.compact_info("nonexistent")
    assert_equal [], info
  end
end
