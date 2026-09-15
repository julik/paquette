require_relative "test_helper"

class TarballTest < Minitest::Test
  FIXTURE = File.join(FIXTURE_NPM_DIR, "react-dropzone", "react-dropzone-14.3.8.tgz")

  def entries
    [
      Paquette::Tarball::Entry.new(name: "package/package.json", mode: 0o644, mtime: 499162500, content: '{"name":"widget"}'),
      Paquette::Tarball::Entry.new(name: "package/bin/cli.js", mode: 0o755, mtime: 499162500, content: "#!/usr/bin/env node\n"),
      Paquette::Tarball::Entry.new(name: "package/index.js", mode: 0o644, mtime: 499162500, content: "module.exports = 1;\n")
    ]
  end

  def test_reads_a_real_npm_tarball
    skip "Fixture not present" unless File.exist?(FIXTURE)

    names = Paquette::Tarball.entries(FIXTURE).map(&:name)
    assert_includes names, "package/package.json"
    assert_equal "package", Paquette::Tarball.root_dir(FIXTURE)
  end

  def test_reads_package_json
    skip "Fixture not present" unless File.exist?(FIXTURE)

    info = Paquette::Tarball.package_json(FIXTURE)
    assert_equal "react-dropzone", info["name"]
    assert_equal "14.3.8", info["version"]
  end

  def test_package_json_is_nil_when_absent
    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "x.tgz"),
        [Paquette::Tarball::Entry.new(name: "package/index.js", mode: 0o644, mtime: 0, content: "x")])

      assert_nil Paquette::Tarball.package_json(path)
    end
  end

  def test_malformed_input_is_reported_as_such
    Dir.mktmpdir do |dir|
      path = File.join(dir, "junk.tgz")
      File.binwrite(path, "definitely not a gzip stream")

      assert_raises(Paquette::Tarball::MalformedTarball) { Paquette::Tarball.package_json(path) }
    end
  end

  def test_roundtrip_preserves_names_contents_and_mtimes
    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"), entries)
      read_back = Paquette::Tarball.entries(path).sort_by(&:name)

      assert_equal entries.sort_by(&:name).map(&:name), read_back.map(&:name)
      assert_equal entries.sort_by(&:name).map(&:content), read_back.map(&:content)
      assert_equal entries.sort_by(&:name).map(&:mtime), read_back.map(&:mtime)
    end
  end

  def test_the_executable_bit_survives
    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"), entries)
      by_name = Paquette::Tarball.entries(path).to_h { |entry| [entry.name, entry] }

      assert_equal 0o755, by_name["package/bin/cli.js"].mode
      assert_equal 0o644, by_name["package/index.js"].mode
    end
  end

  # npm checks downloaded bytes against a previously published hash, so the
  # same entries must always pack to the same file.
  def test_output_is_byte_reproducible
    Dir.mktmpdir do |dir|
      first = Paquette::Tarball.write(File.join(dir, "a.tgz"), entries)
      sleep 1.1 # long enough that a timestamp in the archive would move
      second = Paquette::Tarball.write(File.join(dir, "b.tgz"), entries)

      assert_equal Digest::SHA256.file(first).hexdigest, Digest::SHA256.file(second).hexdigest
    end
  end

  # Entry order comes out of a Hash, so it must not reach the bytes.
  def test_entry_order_does_not_change_the_output
    Dir.mktmpdir do |dir|
      forwards = Paquette::Tarball.write(File.join(dir, "a.tgz"), entries)
      backwards = Paquette::Tarball.write(File.join(dir, "b.tgz"), entries.reverse)

      assert_equal Digest::SHA256.file(forwards).hexdigest, Digest::SHA256.file(backwards).hexdigest
    end
  end

  def test_the_gzip_header_carries_no_timestamp
    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"), entries)
      header = File.binread(path, 10)

      assert_equal "\x1f\x8b".b, header[0, 2]
      assert_equal 0, header[4, 4].unpack1("V")
    end
  end

  def test_system_tar_can_read_what_we_write
    skip "No tar available" if `which tar`.strip.empty?

    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"), entries)
      listing = `tar tzf #{path}`

      assert_equal 0, $?.exitstatus
      assert_includes listing, "package/package.json"
      assert_equal '{"name":"widget"}', `tar xzfO #{path} package/package.json`
    end
  end

  def test_long_paths_survive
    long_name = "package/" + (["a-reasonably-long-directory-name"] * 4).join("/") + "/index.js"

    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"),
        [Paquette::Tarball::Entry.new(name: long_name, mode: 0o644, mtime: 0, content: "x")])

      assert_equal [long_name], Paquette::Tarball.entries(path).map(&:name)
    end
  end

  def test_integrity_hashes
    Dir.mktmpdir do |dir|
      path = Paquette::Tarball.write(File.join(dir, "out.tgz"), entries)
      hashes = Paquette::Tarball.integrity(path)

      assert_equal Digest::SHA1.file(path).hexdigest, hashes[:shasum]
      assert_equal "sha512-" + [Digest::SHA512.file(path).digest].pack("m0"), hashes[:integrity]
    end
  end
end
