require_relative "../test_helper"
require "tmpdir"
require "digest"
require "rubygems/package"

class PersonalizerTest < Minitest::Test
  # The licensee the fixture gem's `# paquette:licensee` marker gets filled with
  LICENSEE = {"licensee" => "TEST-LICENSE-123"}.freeze

  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @cache_dir = Dir.mktmpdir("personalizer_test")
    @personalizer = Paquette::GemServer::Personalizer.new(@dir_repository, cache_dir: @cache_dir)
    @current = Paquette::Authenticator.current
    Thread.current[Paquette::Authenticator::CURRENT_KEY] = PersonalizingAuthenticator.new(nil, LICENSEE)
  end

  def teardown
    Thread.current[Paquette::Authenticator::CURRENT_KEY] = @current
    FileUtils.remove_entry(@cache_dir)
  end

  def test_personalizer_delegates_to_repository
    # Test that basic repository methods still work
    assert @personalizer.gem_names.include?("minuscule_test")
    assert @personalizer.versions_for_gem("minuscule_test").include?("0.1.0")
    assert @personalizer.gem_exists?("minuscule_test", "0.1.0")
  end

  def test_gem_file_path_returns_personalized_gem
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Get the personalized gem path
    personalized_path = @personalizer.gem_file_path("minuscule_test", "0.1.0")
    assert_equal "# TEST-LICENSE-123", read_from_gem(personalized_path, "lib/minuscule_test.rb").lines[1].chomp,
      "the marker line is filled in, comment leader and all"

    # Should be a different path than the original
    original_path = @dir_repository.gem_file_path("minuscule_test", "0.1.0")
    refute_equal original_path, personalized_path

    # Should exist and be a file
    assert File.exist?(personalized_path)
    assert File.file?(personalized_path)

    # Should have a different checksum than the original
    require "digest"
    original_checksum = Digest::SHA256.file(original_path).hexdigest
    personalized_checksum = Digest::SHA256.file(personalized_path).hexdigest
    refute_equal original_checksum, personalized_checksum
  end

  def test_compact_info_uses_personalized_checksums
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Get compact info from personalizer
    personalized_info = @personalizer.compact_info("minuscule_test")

    # Get compact info from original repository
    original_info = @dir_repository.compact_info("minuscule_test")

    # Should have same number of versions
    assert_equal original_info.length, personalized_info.length

    # But checksums should be different
    original_checksum = extract_checksum(original_info.first)
    personalized_checksum = extract_checksum(personalized_info.first)

    refute_equal original_checksum, personalized_checksum
  end

  # A repack changes the gem's bytes and nothing else about it, so only the
  # checksum of its info line may move. "rubygems:" sits after the field
  # being rewritten, which is exactly where a too-greedy substitution would
  # eat it.
  def test_compact_info_rewrites_only_the_checksum_of_a_line_carrying_a_rubygems_field
    Dir.mktmpdir do |gems_dir|
      repository = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)
      repository.add_gem(gem_with_required_rubygems_version)
      original = repository.compact_info("picky").fetch(0)
      assert_includes original, ",rubygems:>= 1.3.2"

      personalizer = Paquette::GemServer::Personalizer.new(
        Paquette::GemServer::DirectoryGemRepository.new(gems_dir),
        files: {"LICENSE-COMMERCIAL.txt" => "Licensed to Acme BV.\n"},
        cache_dir: @cache_dir
      )
      personalized = personalizer.compact_info("picky").fetch(0)

      refute_equal extract_checksum(original), extract_checksum(personalized)
      # And the line is otherwise character-for-character what it was: swap
      # the checksum back and the two must be indistinguishable.
      assert_equal original,
        Paquette::GemServer::GemRepository.replace_checksum(personalized, extract_checksum(original))
      # The checksum in the index is the one the customer's download hashes to
      assert_equal Digest::SHA256.file(personalizer.gem_file_path("picky", "1.0.0")).hexdigest,
        extract_checksum(personalized)
    end
  end

  # ── Files injected per licensee ────────────────────────────────────────────
  #
  # The repacker has always been able to write whole files into a gem; the
  # authenticator is what knows who the gem is for. The file is one template
  # for the registry, and the markers in it are filled with the caller's
  # values - which is how a LICENSE naming its licensee gets into a download.

  def test_injected_files_reach_the_gem_and_its_manifest
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    spec = as("ST-5DM4XRJ", "Acme BV") { Gem::Package.new(licensed_personalizer.gem_file_path("minuscule_test", "0.1.0")).spec }

    assert_includes spec.files, "LICENSE-COMMERCIAL.txt",
      "an injected file has to be in spec.files or `gem contents` cannot see it"
  end

  def test_injected_files_carry_what_was_rendered_into_them
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    licence = as("ST-5DM4XRJ", "Acme BV") { read_from_gem(licensed_personalizer.gem_file_path("minuscule_test", "0.1.0"), "LICENSE-COMMERCIAL.txt") }

    assert_includes licence, "ST-5DM4XRJ"
    assert_includes licence, "Acme BV"
    refute_includes licence, "paquette:"
  end

  # The one that matters most. These used to share a path keyed by gem and
  # version, so two licensees downloading at once could each be handed the
  # other's copy — and with a licensee's NAME in the file, that is the other
  # customer's name.
  def test_two_licensees_never_share_a_personalized_file
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    personalizer = licensed_personalizer
    alice = as("ST-AAAAAAA", "Alice Ltd") { personalizer.gem_file_path("minuscule_test", "0.1.0") }
    bob = as("ST-BBBBBBB", "Bob GmbH") { personalizer.gem_file_path("minuscule_test", "0.1.0") }

    refute_equal alice, bob, "one path for two licensees is one licensee receiving the other's gem"
    assert_includes read_from_gem(alice, "LICENSE-COMMERCIAL.txt"), "Alice Ltd"
    refute_includes read_from_gem(alice, "LICENSE-COMMERCIAL.txt"), "Bob GmbH"
  end

  # The cache is not an optimization — it is what makes the published checksum
  # true, and this test is the reason why.
  #
  # Repacking is NOT byte-reproducible. Every gzip member inside a .gem
  # (metadata.gz, data.tar.gz, checksums.yaml.gz) carries Time.now in its
  # header, so the same inputs repacked a second later produce a different
  # SHA256 while inflating to the same content. Measured: identical within one
  # second, different across one.
  #
  # So a personalized gem has to be BUILT ONCE and KEPT. If compact_info
  # computed a checksum from one repack and the download regenerated another,
  # every `bundle install` would report a mismatch — which to a customer is
  # indistinguishable from a tampered gem.
  def test_a_personalized_gem_is_built_once_and_then_reused
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    first = as("ST-5DM4XRJ", "Acme BV") { licensed_personalizer.gem_file_path("minuscule_test", "0.1.0") }
    digest = Digest::SHA256.file(first).hexdigest

    second = as("ST-5DM4XRJ", "Acme BV") { licensed_personalizer.gem_file_path("minuscule_test", "0.1.0") }

    assert_equal first, second, "the same licensee must land on the same cached artifact"
    assert_equal digest, Digest::SHA256.file(second).hexdigest
  end

  # And the index says what will actually arrive. This is the property that
  # makes `bundle install` verify rather than report a checksum mismatch, which
  # to a customer is indistinguishable from a tampered gem.
  def test_the_published_checksum_describes_the_personalized_download
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    personalizer = licensed_personalizer
    published, downloaded = as("ST-5DM4XRJ", "Acme BV") do
      [extract_checksum(personalizer.compact_info("minuscule_test").first),
        Digest::SHA256.file(personalizer.gem_file_path("minuscule_test", "0.1.0")).hexdigest]
    end

    assert_equal published, downloaded
  end

  # Nothing this does may reach outside a directory it made itself.
  #
  # The tidy-up here used to be FileUtils.remove_entry(File.dirname(repacked)) —
  # a recursive delete of whatever directory the repacker happened to choose. In
  # the shop that surfaced as Errno::EPERM on /var/folders/…/T/com.apple.…,
  # which is macOS declining to let one process delete another's files out of
  # the shared temp directory. It only failed loudly because it was refused.
  def test_personalizing_leaves_nothing_behind_and_takes_nothing_it_did_not_make
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # A temp directory of this test's own, because the check below diffs the
    # whole of Dir.tmpdir: the suite runs a forked process per test class, and
    # a sibling personalizing at the same moment has working directories of
    # its own in there. Reading those as ours is how this failed in CI and
    # never on a laptop.
    sandbox = Dir.mktmpdir("paquette_personalize_test")
    previous_tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = sandbox

    # A directory that is not ours, sitting in the same tmpdir, with something
    # in it that has to still be there afterwards.
    bystander = Dir.mktmpdir("bystander")
    File.write(File.join(bystander, "somebody-elses.txt"), "not ours\n")
    before = Dir.children(Dir.tmpdir)

    as("ST-CCCCCCC", "Cleanup Ltd") { licensed_personalizer.gem_file_path("minuscule_test", "0.1.0") }

    assert File.exist?(File.join(bystander, "somebody-elses.txt")),
      "a personalize deleted a file belonging to something else"

    # The cache directory may appear — that is the point of it. A working
    # directory may not: those are made per repack and have to go with it.
    orphans = (Dir.children(Dir.tmpdir) - before).grep(/\Agem_repack|\Apaquette_personalize\d/)
    assert_empty orphans, "a personalize left working directories behind"
  ensure
    FileUtils.remove_entry(bystander) if bystander && File.exist?(bystander)
    ENV["TMPDIR"] = previous_tmpdir
    FileUtils.remove_entry(sandbox) if sandbox && File.exist?(sandbox)
  end

  # A gem with no marker anywhere is nobody's to personalize, whoever asks:
  # its bytes, its checksum and its metadata are the ones on disk.
  def test_a_gem_without_a_marker_is_served_byte_for_byte
    original = @dir_repository.gem_file_path("zip_kit", "6.2.0")

    assert_equal original, @personalizer.gem_file_path("zip_kit", "6.2.0")
    assert_equal @dir_repository.gem_checksum("zip_kit", "6.2.0"), @personalizer.gem_checksum("zip_kit", "6.2.0")
    assert_equal @dir_repository.compact_info("zip_kit"), @personalizer.compact_info("zip_kit")
  end

  # A marker for a key the caller did not supply is a comment and stays one
  def test_a_marker_without_a_value_is_left_alone
    path = as_values("license_key" => "ST-1") { @personalizer.gem_file_path("minuscule_test", "0.1.0") }

    refute_equal @dir_repository.gem_file_path("minuscule_test", "0.1.0"), path, "the stamp alone is a reason to repack"
    assert_equal "# paquette:licensee", read_from_gem(path, "lib/minuscule_test.rb").lines[1].chomp
  end

  def test_a_value_spanning_lines_is_refused_before_anything_is_written
    assert_raises(Paquette::Markers::MultilineValue) do
      as_values("licensee" => "two\nlines") { @personalizer.gem_file_path("minuscule_test", "0.1.0") }
    end
    assert_empty Dir.glob(File.join(@cache_dir, "*.gem"))
  end

  def test_a_caller_without_personalization_gets_the_original
    Paquette::Authenticator.with(Paquette::Authenticator.new(nil)) do
      assert_equal @dir_repository.gem_file_path("minuscule_test", "0.1.0"), @personalizer.gem_file_path("minuscule_test", "0.1.0")
    end
    Paquette::Authenticator.with(nil) do
      assert_equal @dir_repository.gem_file_path("minuscule_test", "0.1.0"), @personalizer.gem_file_path("minuscule_test", "0.1.0")
    end
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, {})) do
      assert_equal @dir_repository.gem_file_path("minuscule_test", "0.1.0"), @personalizer.gem_file_path("minuscule_test", "0.1.0")
    end
  end

  private

  LICENSE_TEMPLATE = <<~LICENSE
    This copy is licensed to:

        paquette:licensee
        paquette:license_key

  LICENSE

  def licensed_personalizer
    Paquette::GemServer::Personalizer.new(
      Paquette::GemServer::DirectoryGemRepository.new(@gems_dir),
      files: {"LICENSE-COMMERCIAL.txt" => LICENSE_TEMPLATE},
      cache_dir: @cache_dir
    )
  end

  def as(license_ref, licensee, &block)
    as_values("license_key" => license_ref, "licensee" => licensee, &block)
  end

  def as_values(values, &block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, values), &block)
  end

  # None of the checked-in fixtures declares a required_rubygems_version —
  # the default is ">= 0", which is not published at all — so a gem that
  # does gets built here.
  def gem_with_required_rubygems_version
    Dir.mktmpdir do |source_dir|
      FileUtils.mkdir_p(File.join(source_dir, "lib"))
      # Marked, so the personalizer has a reason to repack it
      File.write(File.join(source_dir, "lib", "picky.rb"), "# paquette:licensee\nmodule Picky; end\n")

      spec = Gem::Specification.new do |s|
        s.name = "picky"
        s.version = "1.0.0"
        s.summary = "Paquette test fixture"
        s.authors = ["Paquette"]
        s.files = ["lib/picky.rb"]
        s.license = "MIT"
        s.required_ruby_version = ">= 2.6"
        s.required_rubygems_version = ">= 1.3.2"
      end

      built = nil
      capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec) } }
      File.binread(File.join(source_dir, built))
    end
  end

  def read_from_gem(gem_path, entry)
    dir = Dir.mktmpdir
    Gem::Package.new(gem_path).extract_files(dir)
    path = File.join(dir, entry)
    File.exist?(path) ? File.read(path) : ""
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def extract_checksum(info_line)
    if (match = info_line.match(/checksum:([a-f0-9]+)/))
      match[1]
    end
  end
end
