require_relative "../test_helper"

class DirectoryGemRepositoryTest < Minitest::Test
  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @minuscule_fixture = File.join(@gems_dir, "minuscule_test", "minuscule_test-0.1.0.gem")
  end

  def test_gem_names
    names = @repository.gem_names
    assert_equal ["minuscule_test", "zip_kit"], names.sort
  end

  def test_gem_versions
    versions = @repository.gem_versions
    assert_equal 3, versions.length

    # standard:disable Style/HashSlice
    zip_kit_versions = versions.select { |name, _| name == "zip_kit" }
    # standard:enable Style/HashSlice
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.0"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.1"

    # standard:disable Style/HashSlice
    minuscule_versions = versions.select { |name, _| name == "minuscule_test" }
    # standard:enable Style/HashSlice
    assert_equal 1, minuscule_versions.length
    assert_includes minuscule_versions.map { |_, v| v }, "0.1.0"
  end

  def test_versions_for_gem
    zip_kit_versions = @repository.versions_for_gem("zip_kit")
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"

    minuscule_versions = @repository.versions_for_gem("minuscule_test")
    assert_equal ["0.1.0"], minuscule_versions

    assert_equal [], @repository.versions_for_gem("nonexistent")
  end

  def test_gem_exists
    assert @repository.gem_exists?("zip_kit", "6.2.0")
    assert @repository.gem_exists?("zip_kit", "6.2.1")
    assert @repository.gem_exists?("minuscule_test", "0.1.0")

    refute @repository.gem_exists?("zip_kit", "6.3.2")
    refute @repository.gem_exists?("nonexistent", "1.0.0")
  end

  def test_gem_file_path
    assert_equal File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem"),
      @repository.gem_file_path("zip_kit", "6.2.0")
    assert_equal File.join(@gems_dir, "minuscule_test", "minuscule_test-0.1.0.gem"),
      @repository.gem_file_path("minuscule_test", "0.1.0")
  end

  def test_gem_spec
    spec = @repository.gem_spec("zip_kit", "6.2.0")
    refute_nil spec
    assert_equal "zip_kit", spec.name
    assert_equal "6.2.0", spec.version.to_s

    spec = @repository.gem_spec("minuscule_test", "0.1.0")
    refute_nil spec
    assert_equal "minuscule_test", spec.name
    assert_equal "0.1.0", spec.version.to_s

    assert_nil @repository.gem_spec("nonexistent", "1.0.0")
  end

  def test_gem_dependencies
    assert @repository.gem_dependencies("zip_kit", "6.2.0").is_a?(Array)
    assert @repository.gem_dependencies("minuscule_test", "0.1.0").is_a?(Array)
    assert_equal [], @repository.gem_dependencies("nonexistent", "1.0.0")
  end

  def test_add_gem_persists_file_and_returns_spec
    binary = File.binread(@minuscule_fixture)

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
    binary = File.binread(@minuscule_fixture)

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

  def test_yank_gem_moves_file_to_tomb
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(binary)

      repo.yank_gem("minuscule_test", "0.1.0")

      refute repo.gem_exists?("minuscule_test", "0.1.0")
      assert repo.tomb_exists?("minuscule_test", "0.1.0")
      assert_equal binary, File.binread(repo.tomb_file_path("minuscule_test", "0.1.0"))
    end
  end

  def test_yank_excludes_gem_from_listings
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(binary)
      repo.yank_gem("minuscule_test", "0.1.0")

      assert_equal [], repo.versions_for_gem("minuscule_test")
      assert_equal [], repo.gem_versions
      assert_equal [], repo.compact_info("minuscule_test")
    end
  end

  def test_yank_gem_raises_when_missing
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::GemNotFound) do
        repo.yank_gem("nonexistent", "1.0.0")
      end
    end
  end

  def test_yank_twice_raises_not_found
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(binary)
      repo.yank_gem("minuscule_test", "0.1.0")

      assert_raises(Paquette::GemServer::DirectoryGemRepository::GemNotFound) do
        repo.yank_gem("minuscule_test", "0.1.0")
      end
    end
  end

  def test_add_gem_refuses_when_tombed
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(binary)
      repo.yank_gem("minuscule_test", "0.1.0")

      assert_raises(Paquette::GemServer::DirectoryGemRepository::GemYanked) do
        repo.add_gem(binary)
      end
    end
  end

  def test_compact_info
    info = @repository.compact_info("zip_kit")
    assert info.is_a?(Array)
    assert_equal 2, info.length
    info.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line, "Line should match compact index format: #{line}")
    end
    versions = info.map { |line| line.split(" ")[0] }
    assert_includes versions, "6.2.0"
    assert_includes versions, "6.2.1"

    info = @repository.compact_info("minuscule_test")
    assert info.is_a?(Array)
    assert_equal 1, info.length
    assert_match(/^0\.1\.0\s+\|checksum:[a-f0-9]{64},ruby:.+$/, info[0])

    assert_equal [], @repository.compact_info("nonexistent")
  end
end
