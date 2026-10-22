require_relative "../test_helper"
require "rubygems/package"
require "digest"

# Which gems the Personalizer touches, and the promise that the caches answer
# before a gem is ever opened: a gem opts in by carrying a marker, a gem
# without one is served as it sits on disk, and both facts are remembered.
class PersonalizerSelectiveTest < Minitest::Test
  LICENSEE_ONE = {"licensee" => "Licensee One"}.freeze
  LICENSEE_TWO = {"licensee" => "Licensee Two"}.freeze

  def setup
    # A copy, because compact_info writes sidecars into the corpus it reads.
    @gems_dir = Dir.mktmpdir("personalizer_selective_gems")
    FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), @gems_dir)
    FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "zip_kit"), @gems_dir)
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @cache_dir = Dir.mktmpdir("personalizer_selective_cache")
    @personalizer = Paquette::GemServer::Personalizer.new(@repository, cache_dir: @cache_dir)
  end

  def teardown
    FileUtils.remove_entry(@gems_dir)
    FileUtils.remove_entry(@cache_dir)
  end

  def test_cache_dir_is_where_personalized_gems_land
    path = as(LICENSEE_ONE) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }

    assert File.exist?(path)
    assert path.start_with?(@cache_dir), "expected #{path} under #{@cache_dir}"
  end

  # The one look inside the gem is for the markers, and it happens once per
  # gem file: a second ask lands on the cached repack.
  def test_a_marked_gem_is_repacked_once_and_the_cache_answers_after
    scans = 0
    counting = Paquette::GemServer::GemRepacker.singleton_class.instance_method(:marker_keys)
    Paquette::GemServer::GemRepacker.define_singleton_method(:marker_keys) do |path|
      scans += 1
      counting.bind_call(self, path)
    end

    first = as(LICENSEE_ONE) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }
    second = as(LICENSEE_ONE) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }

    assert_equal first, second
    assert_equal 1, scans, "the cache answers before the gem is opened again"
    assert_equal "# Licensee One", file_in_gem(first, "lib/minuscule_test.rb").lines[1].chomp
  ensure
    Paquette::GemServer::GemRepacker.define_singleton_method(:marker_keys, counting) if counting
  end

  def test_a_gem_without_a_marker_is_served_byte_for_byte_and_is_remembered
    scans = 0
    counting = Paquette::GemServer::GemRepacker.singleton_class.instance_method(:marker_keys)
    Paquette::GemServer::GemRepacker.define_singleton_method(:marker_keys) do |path|
      scans += 1
      counting.bind_call(self, path)
    end

    original = @repository.gem_file_path("zip_kit", "6.2.0")

    assert_equal original, as(LICENSEE_ONE) { @personalizer.gem_file_path("zip_kit", "6.2.0") }
    assert_equal original, as(LICENSEE_TWO) { @personalizer.gem_file_path("zip_kit", "6.2.0") }
    assert_equal 1, scans, "the opt-out marker answers before the gem is opened again, whoever asks"
    assert_equal 1, Dir.glob(File.join(@cache_dir, "*.plain")).length
    assert_empty Dir.glob(File.join(@cache_dir, "*.gem"))
  ensure
    Paquette::GemServer::GemRepacker.define_singleton_method(:marker_keys, counting) if counting
  end

  def test_two_licensees_never_share_a_file
    one = as(LICENSEE_ONE) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }
    other = as(LICENSEE_TWO) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }

    refute_equal one, other
    assert_equal "# Licensee One", file_in_gem(one, "lib/minuscule_test.rb").lines[1].chomp
    assert_equal "# Licensee Two", file_in_gem(other, "lib/minuscule_test.rb").lines[1].chomp
  end

  # The same values from two authenticator instances - two requests - land on
  # one file: the cache is keyed by what is written, not by who asked.
  def test_the_same_values_land_on_the_same_file
    one = as(LICENSEE_ONE) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }
    other = as(LICENSEE_ONE.dup) { @personalizer.gem_file_path("minuscule_test", "0.1.0") }

    assert_equal one, other
  end

  # Static files are part of what gets written, so a different template is a
  # different file
  def test_different_injected_files_never_share_a_file
    with_note = Paquette::GemServer::Personalizer.new(@repository, files: {"NOTE.txt" => "note"}, cache_dir: @cache_dir)
    with_other = Paquette::GemServer::Personalizer.new(@repository, files: {"NOTE.txt" => "other"}, cache_dir: @cache_dir)

    one = as(LICENSEE_ONE) { with_note.gem_file_path("minuscule_test", "0.1.0") }
    other = as(LICENSEE_ONE) { with_other.gem_file_path("minuscule_test", "0.1.0") }

    refute_equal one, other
    assert_equal "note", file_in_gem(one, "NOTE.txt")
    assert_equal "other", file_in_gem(other, "NOTE.txt")
  end

  def test_compact_info_keeps_the_lines_and_swaps_only_the_checksum
    # zip_kit carries no marker, so this corpus needs a marked gem with
    # several versions
    FileUtils.rm_rf(File.join(@gems_dir, "zip_kit"))
    ["1.0.0", "1.1.0"].each { |version| @repository.add_gem(marked_gem("marked", version)) }

    plain_lines = @repository.compact_info("marked")
    personalized_lines = as(LICENSEE_ONE) { @personalizer.compact_info("marked") }

    assert_equal 2, plain_lines.length
    assert_equal plain_lines.length, personalized_lines.length
    plain_lines.zip(personalized_lines).each do |plain, personalized|
      refute_equal plain, personalized
      assert_equal plain.sub(/checksum:[0-9a-f]+/, ""), personalized.sub(/checksum:[0-9a-f]+/, ""),
        "everything but the checksum must survive"

      version = personalized.split(" ", 2).first
      served_checksum = as(LICENSEE_ONE) { Digest::SHA256.file(@personalizer.gem_file_path("marked", version)).hexdigest }
      assert_includes personalized, "checksum:#{served_checksum}"
    end
  end

  def test_compact_info_of_an_unmarked_gem_is_the_repository_s_own
    assert_equal @repository.compact_info("zip_kit"), as(LICENSEE_ONE) { @personalizer.compact_info("zip_kit") }
  end

  private

  def as(values, &block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, values), &block)
  end

  def marked_gem(name, version)
    Dir.mktmpdir do |source_dir|
      FileUtils.mkdir_p(File.join(source_dir, "lib"))
      File.write(File.join(source_dir, "lib", "#{name}.rb"), "# paquette:licensee\nmodule Marked; end\n")

      spec = Gem::Specification.new do |s|
        s.name = name
        s.version = version
        s.summary = "Paquette test fixture"
        s.authors = ["Paquette"]
        s.files = ["lib/#{name}.rb"]
        s.date = Time.utc(2024, 1, 1)
      end

      built = nil
      capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }
      File.binread(File.join(source_dir, built))
    end
  end

  def file_in_gem(gem_path, name)
    Dir.mktmpdir do |dir|
      Gem::Package.new(gem_path).extract_files(dir)
      File.read(File.join(dir, name))
    end
  end
end
