require_relative "../test_helper"
require "rubygems/package"
require "digest"

# The files_for:/personalization_key:/cache_dir: side of the Personalizer —
# per-gem content, packages opting out, and the promise that the caches
# answer before the gem is ever opened.
class PersonalizerSelectiveTest < Minitest::Test
  def setup
    # A copy, because compact_info writes sidecars into the corpus it reads.
    @gems_dir = Dir.mktmpdir("personalizer_selective_gems")
    FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), @gems_dir)
    FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "zip_kit"), @gems_dir)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @cache_dir = Dir.mktmpdir("personalizer_selective_cache")
  end

  def teardown
    FileUtils.remove_entry(@gems_dir)
    FileUtils.remove_entry(@cache_dir)
  end

  def test_cache_dir_is_where_personalized_gems_land
    personalizer = Paquette::GemServer::Personalizer.new(@repository, license_key: "L-1", cache_dir: @cache_dir)

    path = personalizer.gem_file_path("minuscule_test", "0.1.0")

    assert File.exist?(path)
    assert path.start_with?(@cache_dir), "expected #{path} under #{@cache_dir}"
  end

  def test_files_for_injects_per_gem_content_and_is_asked_once_per_file
    calls = 0
    personalizer = Paquette::GemServer::Personalizer.new(@repository,
      license_key: "L-1",
      personalization_key: "Licensee One",
      files_for: ->(name, version, _path) {
        calls += 1
        {"LICENSE-NOTE.txt" => "For Licensee One: #{name} #{version}"}
      },
      cache_dir: @cache_dir)

    first = personalizer.gem_file_path("minuscule_test", "0.1.0")
    second = personalizer.gem_file_path("minuscule_test", "0.1.0")

    assert_equal first, second
    assert_equal 1, calls, "the cache answers before files_for is asked again"
    assert_equal "For Licensee One: minuscule_test 0.1.0", file_in_gem(first, "LICENSE-NOTE.txt")
  end

  def test_files_for_nil_serves_the_original_byte_for_byte_and_is_remembered
    calls = 0
    personalizer = Paquette::GemServer::Personalizer.new(@repository,
      license_key: "L-1",
      files_for: ->(*) {
        calls += 1
        nil
      },
      cache_dir: @cache_dir)

    original = @repository.gem_file_path("minuscule_test", "0.1.0")

    assert_equal original, personalizer.gem_file_path("minuscule_test", "0.1.0")
    assert_equal original, personalizer.gem_file_path("minuscule_test", "0.1.0")
    assert_equal 1, calls, "the opt-out marker answers before files_for is asked again"
    assert_equal 1, Dir.glob(File.join(@cache_dir, "*.plain")).length
  end

  def test_two_personalization_keys_never_share_a_file
    build_for = ->(key) do
      Paquette::GemServer::Personalizer.new(@repository,
        license_key: "L-1",
        personalization_key: key,
        files_for: ->(_name, _version, _path) { {"LICENSE-NOTE.txt" => "For #{key}"} },
        cache_dir: @cache_dir).gem_file_path("minuscule_test", "0.1.0")
    end

    one = build_for.call("Licensee One")
    other = build_for.call("Licensee Two")

    refute_equal one, other
    assert_equal "For Licensee One", file_in_gem(one, "LICENSE-NOTE.txt")
    assert_equal "For Licensee Two", file_in_gem(other, "LICENSE-NOTE.txt")
  end

  def test_compact_info_keeps_the_lines_and_swaps_only_the_checksum
    personalizer = Paquette::GemServer::Personalizer.new(@repository,
      license_key: "L-1",
      files_for: ->(_name, _version, _path) { {"LICENSE-NOTE.txt" => "note"} },
      cache_dir: @cache_dir)

    plain_lines = @repository.compact_info("zip_kit")
    personalized_lines = personalizer.compact_info("zip_kit")

    assert_equal plain_lines.length, personalized_lines.length
    plain_lines.zip(personalized_lines).each do |plain, personalized|
      refute_equal plain, personalized
      assert_equal plain.sub(/checksum:[0-9a-f]+/, ""), personalized.sub(/checksum:[0-9a-f]+/, ""),
        "everything but the checksum must survive"

      version = personalized.split(" ", 2).first
      served_checksum = Digest::SHA256.file(personalizer.gem_file_path("zip_kit", version)).hexdigest
      assert_includes personalized, "checksum:#{served_checksum}"
    end
  end

  def test_compact_info_of_an_opted_out_gem_is_the_repository_s_own
    personalizer = Paquette::GemServer::Personalizer.new(@repository,
      license_key: "L-1",
      files_for: ->(*) {},
      cache_dir: @cache_dir)

    assert_equal @repository.compact_info("zip_kit"), personalizer.compact_info("zip_kit")
  end

  private

  def file_in_gem(gem_path, name)
    Dir.mktmpdir do |dir|
      Gem::Package.new(gem_path).extract_files(dir)
      File.read(File.join(dir, name))
    end
  end
end
