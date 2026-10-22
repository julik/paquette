require_relative "../test_helper"
require "digest"
require "rubygems/package"
require "open3"
require "zlib"

class GemRepackerTest < Minitest::Test
  def setup
    @test_gem_path = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")
  end

  def test_repack_with_line_transformation
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    # Generate random characters for the replacement
    random_chars = (0...8).map { ("a".."z").to_a[rand(26)] }.join

    # The fixture carries `# paquette:licensee` in every Ruby file
    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: {"licensee" => "LIC#{random_chars}"})

    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?("-repacked.gem")

    # Unpack the produced gem and verify the replacement
    verify_repacking(new_gem_path, random_chars)

    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  # Every entry keeps the mode the source gem's packer gave it — not the 0600
  # of the Tempfile the .rb files are rewritten through (a gem that installs
  # root-owned 0600 files cannot be required by anyone else), and not the
  # mode extraction leaves on disk after this process's umask.
  def test_repack_keeps_the_file_modes_of_the_source_gem
    Dir.mktmpdir("gem_repacker_permissions") do |dir|
      source = build_gem_with_modes(dir)

      [0o022, 0o077].each do |umask|
        repacked = with_umask(umask) do
          Paquette::GemServer::GemRepacker.repack(source,
            values: {"licensee" => "LIC-1"},
            into: File.join(dir, "repacked-#{umask.to_s(8)}.gem"))
        end

        assert_equal data_entry_modes(source), data_entry_modes(repacked), "under umask #{umask.to_s(8)}"
      end
    end
  end

  def test_repack_is_byte_identical_whatever_the_umask
    Dir.mktmpdir("gem_repacker_umask") do |dir|
      source = build_gem_with_modes(dir)

      digests = [0o022, 0o002, 0o077].map do |umask|
        with_umask(umask) do
          repacked = Paquette::GemServer::GemRepacker.repack(source,
            values: {"licensee" => "somebody"},
            files: {"LICENSE-EXTRA.txt" => "Licensed to somebody\n"},
            into: File.join(dir, "repacked-#{umask.to_s(8)}.gem"))
          Digest::SHA256.file(repacked).hexdigest
        end
      end

      assert_equal 1, digests.uniq.length
    end
  end

  def test_repack_gives_an_injected_file_a_readable_mode_and_a_replaced_one_its_old_mode
    Dir.mktmpdir("gem_repacker_injected") do |dir|
      source = build_gem_with_modes(dir)

      repacked = with_umask(0o077) do
        Paquette::GemServer::GemRepacker.repack(source,
          values: {"licensee" => "LIC-1"},
          files: {"LICENSE-EXTRA.txt" => "new\n", "data/readonly.txt" => "replaced\n"},
          into: File.join(dir, "repacked.gem"))
      end

      modes = data_entry_modes(repacked)
      assert_equal 0o100644, modes["LICENSE-EXTRA.txt"]
      assert_equal data_entry_modes(source)["data/readonly.txt"], modes["data/readonly.txt"]
    end
  end

  # Every value is stamped into the gemspec metadata under paquette.<key>,
  # whether or not a marker asked for it
  def test_repack_stamps_every_value_into_the_metadata
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    values = {"license_key" => "TEST-LICENSE-123", "custom_field" => "custom_value"}
    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: values)

    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?("-repacked.gem")

    verify_metadata_in_gem(new_gem_path, {
      "paquette.license_key" => "TEST-LICENSE-123",
      "paquette.custom_field" => "custom_value"
    })

    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  def test_repack_with_personalizer_metadata
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    # Test that Personalizer-style metadata addition works
    personalized_gem_path = create_personalized_gem

    # Verify the metadata was added
    verify_metadata_in_gem(personalized_gem_path, {"paquette.license_key" => "TEST-LICENSE-456"})

    # Clean up
    File.delete(personalized_gem_path) if File.exist?(personalized_gem_path)
  end

  def test_repack_with_file_injection
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    # Test injecting new files into the gem
    files_to_inject = {
      "LICENSE" => "MIT License\nCopyright (c) 2024 Test Company",
      "README.md" => "# Test Gem\n\nThis is a test gem with injected files.",
      "docs/CHANGELOG.md" => "# Changelog\n\n## 0.1.0\n- Initial release"
    }

    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: {}, files: files_to_inject)

    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?("-repacked.gem")

    # Verify the injected files exist in the repacked gem
    verify_injected_files(new_gem_path, files_to_inject)

    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  def test_repack_with_file_replacement
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    # Test replacing existing files in the gem
    files_to_replace = {
      "lib/minuscule_test.rb" => "# Replaced content\nmodule MinusculeTest\n  VERSION = '0.1.0-replaced'\nend"
    }

    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: {}, files: files_to_replace)

    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?("-repacked.gem")

    # Verify the file was replaced
    verify_injected_files(new_gem_path, files_to_replace)

    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  def test_repack_with_combined_features
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    # Test combining file injection with other features
    files_to_inject = {
      "LICENSE" => "MIT License\nCopyright (c) 2024 Test Company",
      "docs/README.md" => "# Test Gem\n\nThis gem has been personalized."
    }

    values = {"licensee" => "LICENSE-INJECTED", "license_key" => "TEST-LICENSE-COMBINED"}

    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: values, files: files_to_inject)

    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?("-repacked.gem")

    # Verify all features work together
    verify_metadata_in_gem(new_gem_path, {"paquette.license_key" => "TEST-LICENSE-COMBINED", "paquette.licensee" => "LICENSE-INJECTED"})
    verify_injected_files(new_gem_path, files_to_inject)
    verify_repacking(new_gem_path, "ENSE-INJECTED")

    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  # A value for a key no file carries a marker for is stamped and nothing else;
  # a marker for a key with no value stays as it is
  def test_values_and_markers_need_not_match
    assert File.exist?(@test_gem_path), "Test gem not found at #{@test_gem_path}"

    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: {"custom_field" => "CUSTOM-VALUE-123"})

    verify_metadata_in_gem(new_gem_path, {"paquette.custom_field" => "CUSTOM-VALUE-123"})
    lines = unpacked_lines(new_gem_path, "lib/minuscule_test.rb")
    assert_includes lines, "# paquette:licensee"
  ensure
    File.delete(new_gem_path) if new_gem_path && File.exist?(new_gem_path)
  end

  # Markers are filled in every text file, not only the Ruby ones, and in
  # injected files too
  def test_markers_are_filled_in_every_text_file
    Dir.mktmpdir("gem_repacker_markers") do |dir|
      source = build_gem_with_modes(dir)
      repacked = Paquette::GemServer::GemRepacker.repack(source,
        values: {"licensee" => "Acme BV"},
        files: {"LICENSE.txt" => "Licensed to:\n    paquette:licensee\n"},
        into: File.join(dir, "repacked.gem"))

      assert_equal ["# Acme BV", "module Moded; end"], unpacked_lines(repacked, "lib/moded.rb")
      assert_equal ["Acme BV", "  Acme BV"], unpacked_lines(repacked, "data/readonly.txt"),
        "a marker in a plain text file is filled in, indentation kept"
      assert_equal ["Licensed to:", "    Acme BV"], unpacked_lines(repacked, "LICENSE.txt")
    end
  end

  def test_a_marker_that_is_not_alone_on_its_line_fails_the_repack
    Dir.mktmpdir("gem_repacker_inline") do |dir|
      source = build_gem_with_modes(dir, extra: {"lib/inline.rb" => ["x = 1 # paquette:licensee\n", 0o644]})

      assert_raises(Paquette::Markers::NotApplied) do
        Paquette::GemServer::GemRepacker.repack(source, values: {"licensee" => "L"}, into: File.join(dir, "repacked.gem"))
      end
      refute File.exist?(File.join(dir, "repacked.gem"))
    end
  end

  def test_marker_keys_reads_the_gem_without_unpacking_it
    assert_equal ["licensee"], Paquette::GemServer::GemRepacker.marker_keys(@test_gem_path)

    other = File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.0.gem")
    assert_equal [], Paquette::GemServer::GemRepacker.marker_keys(other)

    Dir.mktmpdir("gem_repacker_keys") do |dir|
      assert_equal ["licensee", "customer"], Paquette::GemServer::GemRepacker.marker_keys(build_gem_with_modes(dir,
        extra: {"lib/more.rb" => ["// paquette:customer\n# paquette:licensee\n", 0o644]}))
    end
  end

  def test_values_are_checked_before_anything_is_unpacked
    assert_raises(Paquette::Markers::MultilineValue) do
      Paquette::GemServer::GemRepacker.new(@test_gem_path, values: {"licensee" => "a\nb"})
    end
    assert_raises(ArgumentError) do
      Paquette::GemServer::GemRepacker.new(@test_gem_path, values: {"Bad Key" => "x"})
    end
    assert_raises(ArgumentError) do
      Paquette::GemServer::GemRepacker.new(@test_gem_path, values: {"licensee" => 1})
    end
  end

  # A repack has to be reproducible, because Personalizer publishes a SHA256 for
  # one and then serves another. Without SOURCE_DATE_EPOCH it was not: a .gem is
  # a tar of three gzip members, a gzip header carries the time it was written,
  # and RubyGems takes that — and the inner tar mtimes — from Time.now. The same
  # inputs a second apart produced different bytes that inflated to identical
  # content, which every `bundle install` would report as a checksum mismatch.
  #
  # The sleep is the test. Anything shorter than a second passes whether this
  # works or not, which is exactly how the bug survived being looked at.
  def test_repacking_is_reproducible_across_seconds
    first = Paquette::GemServer::GemRepacker.repack(@test_gem_path,
      values: {"licensee" => "Acme BV"}, files: {"LICENSE-COMMERCIAL.txt" => "Licensed to Acme BV.\n"})
    digest = Digest::SHA256.file(first).hexdigest

    sleep 1.1

    second = Paquette::GemServer::GemRepacker.repack(@test_gem_path,
      values: {"licensee" => "Acme BV"}, files: {"LICENSE-COMMERCIAL.txt" => "Licensed to Acme BV.\n"})

    refute_equal first, second, "each repack should land somewhere of its own"
    assert_equal digest, Digest::SHA256.file(second).hexdigest,
      "same inputs must give the same bytes, or a published checksum describes a gem nobody receives"
  end

  # Pinned to the gem it was made from rather than to a build clock, so two
  # machines repacking the same source agree.
  def test_the_repack_keeps_the_original_gems_date
    original = Gem::Package.new(@test_gem_path).spec.date
    repacked = Paquette::GemServer::GemRepacker.repack(@test_gem_path, values: {}, files: {"X.txt" => "x\n"})

    assert_equal original, Gem::Package.new(repacked).spec.date
  end

  # The timestamp that makes a repack reproducible is something RubyGems will
  # only take through ENV["SOURCE_DATE_EPOCH"], which is process-wide: two
  # threads repacking at once through that variable are two builds sharing one
  # timestamp, and the loser comes out stamped with the winner's date. A server
  # repacks on request threads, so this is the ordinary case and not the exotic
  # one. BuildTime is the way around it.
  #
  # Both gems are built alone first, so the assertion is against bytes known to
  # be right rather than against the two threads merely agreeing with each other
  # — which they would also do if both were wrong.
  def test_repacking_is_reproducible_when_two_threads_build_at_once
    other_gem = File.join(FIXTURE_GEMS_DIR, "zip_kit", Dir.children(File.join(FIXTURE_GEMS_DIR, "zip_kit")).grep(/\.gem\z/).min)
    refute_equal Gem::Package.new(@test_gem_path).spec.date, Gem::Package.new(other_gem).spec.date,
      "this test needs two gems with different dates to be about anything"

    alone = [@test_gem_path, other_gem].to_h do |path|
      [path, Digest::SHA256.file(repack_of(path)).hexdigest]
    end

    # Enough rounds that an unlocked build would land inside somebody else's
    # ENV window rather than getting lucky.
    concurrent = 12.times.flat_map do
      [@test_gem_path, other_gem].map do |path|
        Thread.new { [path, Digest::SHA256.file(repack_of(path)).hexdigest] }
      end
    end.map(&:value)

    concurrent.each do |path, digest|
      assert_equal alone[path], digest,
        "#{File.basename(path)} came out of a concurrent repack with different bytes"
    end
  end

  # A server's environment is not a build's scratch space. Nothing here may
  # write SOURCE_DATE_EPOCH even briefly: a concurrent build reading it mid-flight
  # is the bug BuildTime exists to remove, and code that sets it "just for a
  # moment" is how that bug comes back.
  def test_repacking_leaves_the_environment_alone
    # Watching for a fixed number of iterations races the build and usually
    # loses, which is a test that passes for the wrong reason. This one watches
    # until the build says it is done.
    seen = []
    building = true
    watcher = Thread.new do
      while building
        seen << ENV["SOURCE_DATE_EPOCH"]
        # Paced, not spinning: a tight loop here holds the GVL against the
        # thread doing the work and turns a 60ms build into most of a minute.
        # The bad version of this sets the variable for the whole build, so
        # millisecond sampling has tens of chances to see it.
        sleep 0.001
      end
    end

    repack_of(@test_gem_path)
    building = false
    watcher.join

    assert_operator seen.length, :>, 1, "the watcher never got to look"

    assert_nil ENV["SOURCE_DATE_EPOCH"], "a repack left SOURCE_DATE_EPOCH behind"
    assert_equal [nil], seen.uniq, "a repack set SOURCE_DATE_EPOCH while it ran"
  end

  # And the timestamp still reaches the archive: the whole point of the bypass
  # is that RubyGems sees the source gem's date, not the clock and not ENV.
  def test_the_build_time_bypass_reaches_rubygems
    date = Gem::Package.new(@test_gem_path).spec.date

    Paquette::GemServer::GemRepacker::BuildTime.with(date) do
      assert_equal date.to_i.to_s, Gem.source_date_epoch_string
      assert_equal date.to_i, Gem.source_date_epoch.to_i
    end

    refute_equal date.to_i.to_s, Gem.source_date_epoch_string,
      "the build time outlived the block it was set for"
  end

  # The working directory is made before anything can go wrong and removed
  # after everything has: a repack that raises used to leave it in the system
  # temp directory, one per failure, with no one left holding the path.
  def test_a_failed_repack_leaves_no_working_directory_behind
    sandbox = Dir.mktmpdir("paquette_repacker_test")
    previous_tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = sandbox

    not_a_gem = File.join(sandbox, "not-a-gem-1.0.0.gem")
    File.binwrite(not_a_gem, "this is not a gem\n")

    assert_raises(RuntimeError) { Paquette::GemServer::GemRepacker.repack(not_a_gem, values: {}) }
    assert_empty Dir.children(sandbox).grep(/\Agem_repacker/), "a failed repack left its working directory behind"
  ensure
    ENV["TMPDIR"] = previous_tmpdir
    FileUtils.remove_entry(sandbox) if sandbox && File.exist?(sandbox)
  end

  private

  # A gem whose files do not all share one mode, the way a gem built on a
  # umask-002 machine or shipping an executable arrives.
  #
  # @return [String] path of the built gem
  def build_gem_with_modes(dir, extra: {})
    root = File.join(dir, "source")
    files = {
      "lib/moded.rb" => ["# paquette:licensee\nmodule Moded; end\n", 0o664],
      "exe/moded" => ["#!/usr/bin/env ruby\n", 0o755],
      "data/readonly.txt" => ["paquette:licensee\n  paquette:licensee\n", 0o444],
      "README.md" => ["# Moded\n", 0o644]
    }.merge(extra)
    files.each do |path, (content, mode)|
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      File.chmod(mode, full)
    end

    spec = Gem::Specification.new do |s|
      s.name = "moded"
      s.version = "0.1.0"
      s.summary = "Files with different modes"
      s.authors = ["Paquette"]
      s.files = files.keys.sort
    end
    modes = spec.files.to_h { |path| [path, File.stat(File.join(root, path)).mode] }

    gem_path = File.join(dir, "moded-0.1.0.gem")
    Paquette::GemServer::GemRepacker::RootedPackage.build(spec, root, gem_path, build_time: Time.utc(2026, 1, 1), modes: modes)
    gem_path
  end

  def with_umask(umask)
    previous = File.umask(umask)
    yield
  ensure
    File.umask(previous)
  end

  # @return [Hash{String => Integer}] tar entry name => mode, from data.tar.gz
  def data_entry_modes(gem_path)
    modes = {}
    File.open(gem_path, "rb") do |io|
      Gem::Package::TarReader.new(io).each do |entry|
        next unless entry.full_name == "data.tar.gz"
        Zlib::GzipReader.wrap(entry) do |gz|
          Gem::Package::TarReader.new(gz).each { |file| modes[file.full_name] = file.header.mode }
        end
      end
    end
    modes
  end

  def verify_repacking(gem_path, expected_random_chars)
    # Create a temporary directory to unpack the new gem
    temp_dir = Dir.mktmpdir("verify_repacking")
    unpacked_dir = File.join(temp_dir, "unpacked")
    FileUtils.mkdir_p(unpacked_dir)

    begin
      # Unpack the new gem
      _, stderr, status = Open3.capture3("gem unpack #{gem_path} --target=#{unpacked_dir}")
      assert status.success?, "Failed to unpack the repacked gem: #{stderr}"

      # Find the unpacked gem directory
      gem_dir = Dir.glob(File.join(unpacked_dir, "*")).find { |path| File.directory?(path) }
      assert gem_dir, "Could not find unpacked gem directory"

      # Check all Ruby files for the replacement
      found_replacement = false
      Dir.glob(File.join(gem_dir, "**", "*.rb")).each do |rb_file|
        File.readlines(rb_file).each do |line|
          if line.chomp == "# LIC#{expected_random_chars}"
            found_replacement = true
          end
          # Ensure the original line is gone
          refute_equal line.chomp, "# paquette:licensee", "Original line still present in #{rb_file}"
        end
      end

      assert found_replacement, "Replacement line '# LIC#{expected_random_chars}' not found in any Ruby file"
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end

  def repack_of(gem_path)
    Paquette::GemServer::GemRepacker.repack(gem_path,
      values: {"license_key" => "L-1"},
      files: {"LICENSE-COMMERCIAL.txt" => "Licensed to Acme BV.\n"})
  end

  # The lines of one file out of a gem, endings dropped
  def unpacked_lines(gem_path, entry)
    Dir.mktmpdir do |dir|
      Gem::Package.new(gem_path).extract_files(dir)
      File.readlines(File.join(dir, entry), chomp: true)
    end
  end

  def create_personalized_gem
    # Create a personalized gem using the Personalizer approach
    personalized_dir = File.join(Dir.tmpdir, "paquette_personalized")
    FileUtils.mkdir_p(personalized_dir)

    personalized_path = File.join(personalized_dir, "minuscule_test-0.1.0-personalized.gem")

    # The repacker says where it put the gem. Guessing a path in the shared
    # tmpdir instead — which this helper used to do, mirroring Personalizer —
    # is how two repacks of one gem ended up overwriting each other and a
    # caller was handed whichever finished last.
    repacked = Paquette::GemServer::GemRepacker.repack(@test_gem_path,
      values: {"license_key" => "TEST-LICENSE-456", "licensee" => "TEST-LICENSE-456"})

    FileUtils.mv(repacked, personalized_path)
    personalized_path
  end

  def verify_metadata_in_gem(gem_path, expected_metadata)
    # Read the gem specification directly from the gem file
    gem_package = Gem::Package.new(gem_path)
    spec = gem_package.spec

    # Verify each expected metadata key is present in the spec
    expected_metadata.each do |key, value|
      assert_equal value, spec.metadata[key], "Expected metadata key '#{key}' to have value '#{value}', but got '#{spec.metadata[key]}'"
    end
  end

  def verify_injected_files(gem_path, expected_files)
    # Create a temporary directory to unpack the new gem
    temp_dir = Dir.mktmpdir("verify_injected_files")
    unpacked_dir = File.join(temp_dir, "unpacked")
    FileUtils.mkdir_p(unpacked_dir)

    begin
      # Unpack the new gem
      _, stderr, status = Open3.capture3("gem unpack #{gem_path} --target=#{unpacked_dir}")
      assert status.success?, "Failed to unpack the gem: #{stderr}"

      # Find the unpacked gem directory
      gem_dir = Dir.glob(File.join(unpacked_dir, "*")).find { |path| File.directory?(path) }
      assert gem_dir, "Could not find unpacked gem directory"

      # Verify each expected file exists and has the correct content
      expected_files.each do |file_path, expected_content|
        full_file_path = File.join(gem_dir, file_path)
        assert File.exist?(full_file_path), "Expected file '#{file_path}' not found in unpacked gem"

        actual_content = File.read(full_file_path)
        assert_equal expected_content, actual_content, "File '#{file_path}' content doesn't match expected content"
      end
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
