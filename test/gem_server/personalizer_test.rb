require_relative "../test_helper"
require "tmpdir"
require "digest"
require "rubygems/package"

class PersonalizerTest < Minitest::Test
  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @personalizer = Paquette::GemServer::Personalizer.new(@dir_repository,
      license_key: "TEST-LICENSE-123",
      magic_comment_replacements: {"# paquette_license_info" => "TEST-LICENSE-123"})
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

  # ── Files injected per licensee ────────────────────────────────────────────
  #
  # The repacker has always been able to write whole files into a gem; the
  # personalizer is what knows who the gem is for. Together they are how a
  # LICENSE naming its licensee gets into a download.

  def test_injected_files_reach_the_gem_and_its_manifest
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    personalizer = personalizer_for("ST-5DM4XRJ", "Acme BV")
    spec = Gem::Package.new(personalizer.gem_file_path("minuscule_test", "0.1.0")).spec

    assert_includes spec.files, "LICENSE-COMMERCIAL.txt",
      "an injected file has to be in spec.files or `gem contents` cannot see it"
  end

  def test_injected_files_carry_what_was_rendered_into_them
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    personalizer = personalizer_for("ST-5DM4XRJ", "Acme BV")
    licence = read_from_gem(personalizer.gem_file_path("minuscule_test", "0.1.0"), "LICENSE-COMMERCIAL.txt")

    assert_includes licence, "ST-5DM4XRJ"
    assert_includes licence, "Acme BV"
  end

  # The one that matters most. These used to share a path keyed by gem and
  # version, so two licensees downloading at once could each be handed the
  # other's copy — and with a licensee's NAME in the file, that is the other
  # customer's name.
  def test_two_licensees_never_share_a_personalized_file
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    alice = personalizer_for("ST-AAAAAAA", "Alice Ltd").gem_file_path("minuscule_test", "0.1.0")
    bob = personalizer_for("ST-BBBBBBB", "Bob GmbH").gem_file_path("minuscule_test", "0.1.0")

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

    first = personalizer_for("ST-5DM4XRJ", "Acme BV").gem_file_path("minuscule_test", "0.1.0")
    digest = Digest::SHA256.file(first).hexdigest

    second = personalizer_for("ST-5DM4XRJ", "Acme BV").gem_file_path("minuscule_test", "0.1.0")

    assert_equal first, second, "the same licensee must land on the same cached artifact"
    assert_equal digest, Digest::SHA256.file(second).hexdigest
  end

  # And the index says what will actually arrive. This is the property that
  # makes `bundle install` verify rather than report a checksum mismatch, which
  # to a customer is indistinguishable from a tampered gem.
  def test_the_published_checksum_describes_the_personalized_download
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    personalizer = personalizer_for("ST-5DM4XRJ", "Acme BV")
    published = extract_checksum(personalizer.compact_info("minuscule_test").first)
    downloaded = Digest::SHA256.file(personalizer.gem_file_path("minuscule_test", "0.1.0")).hexdigest

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

    # A directory that is not ours, sitting in the same tmpdir, with something
    # in it that has to still be there afterwards.
    bystander = Dir.mktmpdir("bystander")
    File.write(File.join(bystander, "somebody-elses.txt"), "not ours\n")
    before = Dir.children(Dir.tmpdir)

    personalizer_for("ST-CCCCCCC", "Cleanup Ltd").gem_file_path("minuscule_test", "0.1.0")

    assert File.exist?(File.join(bystander, "somebody-elses.txt")),
      "a personalize deleted a file belonging to something else"

    # The cache directory may appear — that is the point of it. A working
    # directory may not: those are made per repack and have to go with it.
    orphans = (Dir.children(Dir.tmpdir) - before).grep(/\Agem_repack|\Apaquette_personalize\d/)
    assert_empty orphans, "a personalize left working directories behind"
  ensure
    FileUtils.remove_entry(bystander) if bystander && File.exist?(bystander)
  end

  private

  def personalizer_for(license_ref, licensee)
    Paquette::GemServer::Personalizer.new(
      Paquette::GemServer::DirectoryGemRepository.new(@gems_dir),
      license_key: license_ref,
      files: {"LICENSE-COMMERCIAL.txt" => "Licensed to #{licensee} under #{license_ref}.\n"}
    )
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
