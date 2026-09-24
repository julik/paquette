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

  # A gemspec is YAML the uploader wrote, and add_gem used to take
  # spec.name straight to File.join. A name of "../../pwned" put the whole
  # uploaded payload two directories above the gems root — an arbitrary
  # file write from a push, and in the README's default dev setup an
  # unauthenticated one. The assertion is deliberately about the
  # filesystem and not about the exception: a rejection that still wrote
  # the file would pass an assert_raises.
  def test_add_gem_refuses_a_name_that_escapes_the_gems_directory
    binary = hostile_gem_bytes(name: "../../pwned")

    Dir.mktmpdir do |outer|
      gems_dir = File.join(outer, "a", "b", "gems")
      repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)
      before = Dir.glob(File.join(outer, "**", "*"), File::FNM_DOTMATCH).sort

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem(binary)
      end

      assert_equal before, Dir.glob(File.join(outer, "**", "*"), File::FNM_DOTMATCH).sort,
        "the push wrote something, and everything it could have written is outside the gems root"
      assert_equal [], repo.gem_names
    end
  end

  # Every shape of the same hole, in case the first character rule and the
  # separator rule are ever loosened independently.
  def test_add_gem_refuses_every_traversing_name
    Dir.mktmpdir do |outer|
      gems_dir = File.join(outer, "a", "b", "gems")
      repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

      ["..", "../..", "../../pwned", "a/../../b", "/tmp/pwned", ".hidden", "-rf"].each do |name|
        assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem, "accepted #{name.inspect}") do
          repo.add_gem(hostile_gem_bytes(name: name))
        end
      end

      assert_equal [], Dir.glob(File.join(outer, "**", "*.gem"))
    end
  end

  # The other half of the same trust: /info/ and /versions are
  # line-oriented, so a "\n" in a field is a forged row rather than a
  # broken one.
  def test_add_gem_refuses_a_name_carrying_a_newline
    binary = hostile_gem_bytes(name: "safe\nforged 9.9.9 deadbeef")

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem(binary)
      end

      assert_equal [], repo.gem_names
      assert_equal [], repo.compact_info("safe")
    end
  end

  def test_add_gem_refuses_a_forged_ruby_requirement
    # Interpolated into the "ruby:" field, which is the tail of every info
    # line — so a newline there appends a row just as a forged name does.
    binary = hostile_gem_bytes(name: "widgets") do |spec|
      spec.required_ruby_version = forged_requirement(">=", "2.0\nforged 9.9.9 deadbeef")
    end

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem(binary)
      end
      assert_equal [], repo.compact_info("widgets")
    end
  end

  def test_add_gem_refuses_a_forged_version
    binary = hostile_gem_bytes(name: "widgets", version: "1.0.0\nforged 9.9.9 deadbeef")

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem(binary)
      end
      assert_equal [], repo.gem_names
    end
  end

  # The corpus is only ever fed by add_gem, so what it renders is what
  # add_gem let through: one line per real version, and no line the
  # uploader wrote for themselves.
  def test_compact_info_stays_one_line_per_version_under_a_forging_push
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(File.binread(@minuscule_fixture))

      ["minuscule_test\nforged 9.9.9 deadbeef", "safe\nforged"].each do |name|
        repo.add_gem(hostile_gem_bytes(name: name))
      rescue Paquette::GemServer::DirectoryGemRepository::InvalidGem
        nil
      end

      info = repo.compact_info("minuscule_test")
      assert_equal 1, info.length
      refute_includes info.join, "9.9.9"
      info.each { |line| refute_includes line, "\n" }
    end
  end

  # YAML aliases are how a few hundred bytes of gemspec become an
  # arbitrarily large object graph, which on an open push endpoint is a
  # memory-exhaustion DoS. Nothing RubyGems emits uses them.
  def test_add_gem_refuses_a_gemspec_that_uses_yaml_aliases
    Gem.load_yaml
    skip "this RubyGems has no Gem::SafeYAML.aliases_enabled=" unless Gem::SafeYAML.respond_to?(:aliases_enabled=)

    binary = gem_bytes_with_metadata(hostile_gem_bytes(name: "aliased"), ALIASED_GEMSPEC_YAML)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      error = without_rubygems_chatter do
        assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) { repo.add_gem(binary) }
      end

      assert_match(/alias/i, error.message)
      assert_equal [], repo.gem_names
    end
  end

  # The flag is process-global and belongs to the host application, so a
  # push must hand it back exactly as it found it — including when the
  # parse raises, which is the case that is easy to get wrong.
  def test_reading_an_uploaded_spec_restores_the_alias_flag
    Gem.load_yaml
    skip "this RubyGems has no Gem::SafeYAML.aliases_enabled=" unless Gem::SafeYAML.respond_to?(:aliases_enabled=)

    was_enabled = Gem::SafeYAML.aliases_enabled?
    aliased = gem_bytes_with_metadata(hostile_gem_bytes(name: "aliased"), ALIASED_GEMSPEC_YAML)

    without_rubygems_chatter do
      [true, false].each do |enabled|
        # A fresh corpus each time: a yanked gem leaves a tomb, and the
        # second push would be refused for that reason instead.
        Dir.mktmpdir do |tmp|
          repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
          Gem::SafeYAML.aliases_enabled = enabled

          repo.add_gem(File.binread(@minuscule_fixture))
          assert_equal enabled, Gem::SafeYAML.aliases_enabled?, "a successful push left the flag changed"

          begin
            repo.add_gem(aliased)
          rescue Paquette::GemServer::DirectoryGemRepository::InvalidGem
            nil
          end
          assert_equal enabled, Gem::SafeYAML.aliases_enabled?, "a failed push left the flag changed"
        end
      end
    end
  ensure
    Gem::SafeYAML.aliases_enabled = was_enabled unless was_enabled.nil?
  end

  def test_add_gem_accepts_an_io_and_streams_it
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      spec = repo.add_gem(StringIO.new(binary))

      assert_equal "minuscule_test", spec.name
      assert_equal binary, File.binread(repo.gem_file_path("minuscule_test", "0.1.0"))
    end
  end

  def test_add_gem_accepts_a_real_file_handle
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      spec = File.open(@minuscule_fixture, "rb") { |io| repo.add_gem(io) }

      assert_equal "minuscule_test", spec.name
      assert repo.gem_exists?("minuscule_test", "0.1.0")
    end
  end

  def test_add_gem_refuses_a_payload_over_max_bytes
    binary = File.binread(@minuscule_fixture)

    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::GemTooLarge) do
        repo.add_gem(binary, max_bytes: binary.bytesize - 1)
      end

      assert_equal [], Dir.glob(File.join(tmp, "**", "*.gem"))
      # The exact size still fits: the cap is a maximum, not a strict less-than.
      assert repo.add_gem(binary, max_bytes: binary.bytesize)
    end
  end

  def test_add_gem_rejects_an_empty_io
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)

      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
        repo.add_gem(StringIO.new(""))
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

      # Every freshly written sidecar names its format, and the reader
      # refuses anything stamped with a different number.
      written = JSON.parse(File.read(sidecar_path(tmp, "zip_kit", "6.2.0")))
      assert_equal Paquette::GemServer::DirectoryGemRepository::SIDECAR_FORMAT_VERSION,
        written.fetch("format_version")

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

  def test_compact_info_names_the_required_rubygems_version
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(gem_bytes("picky", "1.0.0", required_rubygems_version: ">= 1.3.2"))

      line = repo.compact_info("picky").fetch(0)

      assert_match(/\A1\.0\.0 \|checksum:[0-9a-f]{64},ruby:>= 2\.6,rubygems:>= 1\.3\.2\z/, line)
      # And the warm path renders the same bytes — /versions MD5s this body,
      # so a field that only appears on a cold read would move every digest.
      assert_equal line, repo.compact_info("picky").fetch(0)
    end
  end

  # Gem::Requirement#to_s joins clauses with ", ", and a comma already
  # separates fields in the metadata segment, so they come out joined with
  # "&" the way rubygems.org joins them.
  def test_compact_info_joins_multiple_rubygems_clauses_with_an_ampersand
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(gem_bytes("fussy", "1.0.0", required_rubygems_version: [">= 1.3.2", "< 4"]))

      line = repo.compact_info("fussy").fetch(0)

      assert_includes line, ",rubygems:>= 1.3.2&< 4"
      refute_includes line, ", "
    end
  end

  # rubygems.org leaves the field out entirely rather than writing
  # ">= 0" — a gem with no constraint must serve exactly the line it
  # served before the field existed.
  def test_compact_info_omits_rubygems_when_the_gem_declares_no_constraint
    Dir.mktmpdir do |tmp|
      repo = seeded_repo(tmp)

      line = repo.compact_info("minuscule_test").fetch(0)

      refute_includes line, "rubygems:"
      assert_match(/\A0\.1\.0 \|checksum:[0-9a-f]{64},ruby:[^,]+\z/, line)
    end
  end

  # The one that a format bump exists for. A cache warmed by the previous
  # release holds entries with no "rubygems" key, and an entry like that is
  # indistinguishable from a gem that genuinely has no constraint — so it
  # has to be thrown away on the version stamp alone, before its contents
  # are consulted at all.
  def test_compact_info_discards_a_sidecar_from_an_older_format_version
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(gem_bytes("picky", "1.0.0", required_rubygems_version: ">= 1.3.2"))
      expected = repo.compact_info("picky")

      # Exactly what the previous release would have left behind: the old
      # format number, no "rubygems" key, and a size/mtime that still
      # vouches for the gem file — so the version stamp is the only thing
      # that can reject it.
      sidecar = sidecar_path(tmp, "picky", "1.0.0")
      fields = JSON.parse(File.read(sidecar))
      fields.delete("rubygems")
      fields["format_version"] = 1
      File.write(sidecar, JSON.generate(fields))

      assert_equal expected, repo.compact_info("picky")

      # Re-derived rather than re-read on every request from here on.
      rewritten = JSON.parse(File.read(sidecar))
      assert_equal Paquette::GemServer::DirectoryGemRepository::SIDECAR_FORMAT_VERSION,
        rewritten.fetch("format_version")
      assert_equal ">= 1.3.2", rewritten.fetch("rubygems")
    end
  end

  # A sidecar written before anyone stamped a version is ambiguous the same
  # way, and goes the same way.
  def test_compact_info_discards_an_unversioned_sidecar
    Dir.mktmpdir do |tmp|
      repo = Paquette::GemServer::DirectoryGemRepository.new(tmp)
      repo.add_gem(gem_bytes("picky", "1.0.0", required_rubygems_version: ">= 1.3.2"))
      expected = repo.compact_info("picky")

      sidecar = sidecar_path(tmp, "picky", "1.0.0")
      fields = JSON.parse(File.read(sidecar))
      fields.delete("rubygems")
      fields.delete("format_version")
      File.write(sidecar, JSON.generate(fields))

      assert_equal expected, repo.compact_info("picky")
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

  # The fixture gems on disk all leave required_rubygems_version at its
  # default, so a gem that declares one gets built here rather than
  # checked in — the field under test is the only reason it exists.
  def gem_bytes(name, version, required_rubygems_version: nil)
    Dir.mktmpdir do |source_dir|
      FileUtils.mkdir_p(File.join(source_dir, "lib"))
      File.write(File.join(source_dir, "lib", "#{name}.rb"), "module #{name.capitalize}; end\n")

      spec = Gem::Specification.new do |s|
        s.name = name
        s.version = version
        s.summary = "Paquette test fixture"
        s.authors = ["Paquette"]
        s.files = ["lib/#{name}.rb"]
        s.required_ruby_version = ">= 2.6"
        s.license = "MIT"
        s.required_rubygems_version = required_rubygems_version if required_rubygems_version
      end

      # capture_io only to keep the gem builder's chatter out of the dots
      built = nil
      capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }
      File.binread(File.join(source_dir, built))
    end
  end

  def sidecar_path(gems_dir, gem_name, version)
    File.join(gems_dir, gem_name, ".paquette-cache", "#{gem_name}-#{version}.json")
  end
end
