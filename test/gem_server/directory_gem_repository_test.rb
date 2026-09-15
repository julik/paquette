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

  # A registry that predates the cache is just a tree of .gem files, and it
  # has to serve correctly from the first request with nothing but ordinary
  # traffic to warm it — no backfill step, no re-push. The files here are
  # placed by hand, deliberately not through add_gem, because that is what
  # an inherited directory looks like.
  def test_compact_info_warms_a_pre_existing_directory_through_serving_alone
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "zip_kit"))
      FileUtils.cp(File.join(@gems_dir, "zip_kit", "zip_kit-6.2.0.gem"), File.join(tmp, "zip_kit"))
      FileUtils.cp(File.join(@gems_dir, "zip_kit", "zip_kit-6.2.1.gem"), File.join(tmp, "zip_kit"))
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      refute Dir.exist?(File.join(tmp, "zip_kit", ".paquette-cache"))

      first = repo.compact_info("zip_kit")
      assert_equal @repository.compact_info("zip_kit"), first
      assert File.exist?(sidecar_path(tmp, "zip_kit", "6.2.0"))
      assert File.exist?(sidecar_path(tmp, "zip_kit", "6.2.1"))

      # Every freshly written sidecar names its format. Nothing reads the
      # number yet — it is there so a future format change has something on
      # disk to dispatch on.
      written = JSON.parse(File.read(sidecar_path(tmp, "zip_kit", "6.2.0")))
      assert_equal 1, written.fetch("format_version")

      # The second call must come out of the sidecars, not the gems — plant
      # a checksum no file hashes to and see it served back
      sidecar = sidecar_path(tmp, "zip_kit", "6.2.0")
      fields = JSON.parse(File.read(sidecar))
      fields["checksum"] = "f" * 64
      File.write(sidecar, JSON.generate(fields))

      line = repo.compact_info("zip_kit").find { |l| l.start_with?("6.2.0 ") }
      assert_includes line, "checksum:#{"f" * 64}"
    end
  end

  def test_compact_info_warm_cache_output_is_byte_identical_to_cold
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)

      cold = repo.compact_info("zip_kit")
      assert File.exist?(sidecar_path(tmp, "zip_kit", "6.2.0")), "The first call should have left a sidecar behind"

      warm = repo.compact_info("zip_kit")
      assert_equal cold, warm
    end
  end

  def test_compact_info_serves_from_sidecar_without_reopening_the_gem
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      repo.compact_info("minuscule_test")

      # Plant a checksum in the sidecar that no gem file could ever hash to.
      # If the warm path served it, the gem was not re-read — which is the
      # entire point of the cache, proven from the outside without
      # instrumenting Gem::Package. The size and mtime stay untouched so the
      # staleness guard keeps vouching for the entry.
      sidecar = sidecar_path(tmp, "minuscule_test", "0.1.0")
      fields = JSON.parse(File.read(sidecar))
      fields["checksum"] = "0" * 64
      File.write(sidecar, JSON.generate(fields))

      line = repo.compact_info("minuscule_test").fetch(0)
      assert_includes line, "checksum:#{"0" * 64}"
    end
  end

  def test_yanked_gem_disappears_despite_warm_cache
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      repo.compact_info("minuscule_test")

      repo.yank_gem("minuscule_test", "0.1.0")

      assert_equal [], repo.compact_info("minuscule_test")
      refute File.exist?(sidecar_path(tmp, "minuscule_test", "0.1.0")), "Yank should tidy the orphaned sidecar away"
    end
  end

  def test_compact_info_re_derives_when_gem_file_bytes_change
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      repo.compact_info("zip_kit")

      # A gem file changing in place should never happen — a yank renames,
      # a re-push is refused. But if it ever does, the sidecar's size and
      # mtime no longer match and the entry must be re-derived rather than
      # vouch for bytes it has never seen.
      other_bytes = File.binread(File.join(@gems_dir, "zip_kit", "zip_kit-6.2.1.gem"))
      File.binwrite(File.join(tmp, "zip_kit", "zip_kit-6.2.0.gem"), other_bytes)

      line = repo.compact_info("zip_kit").find { |l| l.start_with?("6.2.0 ") }
      assert_includes line, "checksum:#{Digest::SHA256.hexdigest(other_bytes)}"
    end
  end

  def test_compact_info_recovers_from_corrupt_sidecar
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      expected = repo.compact_info("minuscule_test")

      sidecar = sidecar_path(tmp, "minuscule_test", "0.1.0")
      File.write(sidecar, "definitely { not JSON")

      assert_equal expected, repo.compact_info("minuscule_test")
      # And the corrupt file got replaced with a usable one, not left to be
      # tripped over on every request from here on out
      assert_kind_of Hash, JSON.parse(File.read(sidecar))
    end
  end

  def test_compact_info_serves_from_source_when_gems_dir_is_read_only
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      expected_zip_kit = repo.compact_info("zip_kit")

      FileUtils.rm_rf(File.join(tmp, "zip_kit", ".paquette-cache"))
      FileUtils.chmod(0o555, File.join(tmp, "zip_kit"))
      begin
        assert_equal expected_zip_kit, repo.compact_info("zip_kit")
        refute Dir.exist?(File.join(tmp, "zip_kit", ".paquette-cache"))
      ensure
        FileUtils.chmod(0o755, File.join(tmp, "zip_kit"))
      end
    end
  end

  def test_sidecar_cache_is_invisible_to_listings
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)
      repo.compact_info("zip_kit")
      repo.compact_info("minuscule_test")

      # And a cache directory sitting at the top level of the gems dir —
      # where nothing in this class ever puts one — must not read as a
      # package either
      FileUtils.mkdir_p(File.join(tmp, ".paquette-cache"))
      File.write(File.join(tmp, ".paquette-cache", "stray.json"), "{}")

      assert_equal ["minuscule_test", "zip_kit"], repo.gem_names
      assert_equal [["minuscule_test", "0.1.0"], ["zip_kit", "6.2.0"], ["zip_kit", "6.2.1"]], repo.gem_versions
      assert_equal ["6.2.0", "6.2.1"], repo.versions_for_gem("zip_kit")
    end
  end

  private

  # A throwaway repository holding all three fixture gems, pushed the way a
  # real one receives them. The fixtures under test/ stay read-only in these
  # tests because the cache writes next to the gems it describes.
  def seeded_repo(tmp)
    repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
    ["minuscule_test/minuscule_test-0.1.0.gem", "zip_kit/zip_kit-6.2.0.gem", "zip_kit/zip_kit-6.2.1.gem"].each do |rel|
      repo.add_gem(File.binread(File.join(@gems_dir, rel)))
    end
    repo
  end

  def sidecar_path(gems_dir, gem_name, version)
    File.join(gems_dir, gem_name, ".paquette-cache", "#{gem_name}-#{version}.json")
  end
end
