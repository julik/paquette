require_relative "test_helper"

class NpmRepackerTest < Minitest::Test
  def setup
    @test_package_path = File.join(FIXTURE_NPM_DIR, "react-dropzone", "react-dropzone-14.3.8.tgz")
    @work_dir = Dir.mktmpdir("npm_repacker_test")
  end

  def teardown
    FileUtils.rm_rf(@work_dir) if @work_dir
  end

  def into(name = "out.tgz")
    File.join(@work_dir, name)
  end

  def fixture_package(**options)
    path = File.join(@work_dir, "source.tgz")
    File.binwrite(path, npm_tarball_bytes(name: "widget", version: "1.0.0", **options))
    path
  end

  def test_repack_with_text_replacement
    skip "Test package not found" unless File.exist?(@test_package_path)

    new_package_path = Paquette::NpmRepacker.repack(@test_package_path, values: {}, into: into) do |input_file, output_file, file_path|
      unless File.extname(file_path).match?(/\.(ts|js|mjs|jsx|tsx)$/)
        IO.copy_stream(input_file, output_file)
        next
      end

      output_file.write(input_file.read.gsub("Dropzone", "Liftzone"))
    end

    assert_path_exists new_package_path

    sources = Paquette::Tarball.entries(new_package_path).select do |entry|
      File.extname(entry.name).match?(/\.(ts|js|mjs|jsx|tsx)$/)
    end

    assert sources.any? { |entry| entry.content.include?("Liftzone") }
    sources.each { |entry| refute_includes entry.content, "Dropzone" }
  end

  def test_the_block_sees_paths_relative_to_the_package_root
    seen = []
    Paquette::NpmRepacker.repack(fixture_package, values: {}, into: into) do |input_file, output_file, file_path|
      seen << file_path
      IO.copy_stream(input_file, output_file)
    end

    assert_includes seen, "package.json"
    assert_includes seen, "index.js"
    refute seen.any? { |path| path.start_with?("package/") }
  end

  def test_repack_with_nonexistent_package
    assert_raises(ArgumentError) do
      Paquette::NpmRepacker.repack("/nonexistent/path.tgz", values: {}) { |input_file, output_file, file_path| }
    end
  end

  def test_the_values_are_stamped_into_package_json
    path = Paquette::NpmRepacker.repack(fixture_package, values: {"licensee" => "LIC-1"}, into: into)

    package_json = JSON.parse(tarball_file(path, "package/package.json"))
    assert_equal({"licensee" => "LIC-1"}, package_json["paquette"])
    assert_equal "widget", package_json["name"]
  end

  def test_no_values_leaves_package_json_alone
    path = Paquette::NpmRepacker.repack(fixture_package, values: {}, into: into)

    assert_nil JSON.parse(tarball_file(path, "package/package.json"))["paquette"]
  end

  def test_a_marker_line_is_filled_in
    source = fixture_package(files: {"index.js" => "// paquette:licensee\nexport const x = 1;\n"})
    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed to Acme"}, into: into)

    content = tarball_file(path, "package/index.js")
    assert_equal "// licensed to Acme\nexport const x = 1;\n", content
  end

  # A marker for a key the caller did not supply is a comment, and stays one.
  def test_a_marker_for_an_unknown_key_is_left_alone
    source = fixture_package(files: {"index.js" => "// paquette:other\nexport const x = 1;\n"})
    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed to Acme"}, into: into)

    assert_equal "// paquette:other\nexport const x = 1;\n", tarball_file(path, "package/index.js")
  end

  # `esbuild --minify` pulls a legal comment onto the end of a code line. The
  # whole-line match then misses it and the package would be served with no
  # license key in it and nothing to say so.
  def test_a_marker_the_line_match_cannot_reach_is_refused
    source = fixture_package(files: {"index.js" => "function e(o,r){return o+r}// paquette:licensee\n"})

    error = assert_raises(Paquette::Markers::NotApplied) do
      Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed to Acme"}, into: into)
    end

    assert_includes error.message, "index.js"
  end

  # A multi-line value used to have its newlines flattened to spaces,
  # publishing something other than what the caller wrote.
  def test_a_value_spanning_several_lines_is_refused
    error = assert_raises(Paquette::Markers::MultilineValue) do
      Paquette::NpmRepacker.repack(fixture_package,
        values: {"licensee" => "licensed to Acme\nand a second line"}, into: into)
    end

    assert_includes error.message, "one line"
  end

  def test_a_value_with_a_bare_carriage_return_is_refused
    assert_raises(Paquette::Markers::MultilineValue) do
      Paquette::NpmRepacker.repack(fixture_package, values: {"licensee" => "licensed\rto Acme"}, into: into)
    end
  end

  def test_a_key_that_is_not_a_marker_key_is_refused
    assert_raises(ArgumentError) do
      Paquette::NpmRepacker.repack(fixture_package, values: {"Licensee Name" => "Acme"}, into: into)
    end
  end

  # Most packages in a corpus carry no marker; that is not a failure.
  def test_a_package_without_the_marker_repacks_normally
    source = fixture_package(files: {"index.js" => "export const x = 1;\n"})

    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed to Acme"}, into: into)

    assert_equal "export const x = 1;\n", tarball_file(path, "package/index.js")
  end

  # Not alone on its line means not a marker, whatever the file.
  def test_a_marker_inside_other_text_on_its_line_is_left_alone
    source = fixture_package(files: {"styles.css" => "/* paquette:licensee */\n"})

    path = Paquette::NpmRepacker.repack(source, values: {"other" => "x"}, into: into)

    assert_equal "/* paquette:licensee */\n", tarball_file(path, "package/styles.css")
  end

  # Every text entry is a candidate, not only the sources: a LICENSE carries a
  # marker as readily as a module does, and keeps its own comment leader.
  def test_markers_in_any_text_file_are_filled_in
    source = fixture_package(files: {
      "LICENSE.txt" => "Licensed to:\n    paquette:licensee\n",
      "styles.css" => "/* unrelated */\n"
    })

    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "Acme Inc."}, into: into)

    assert_equal "Licensed to:\n    Acme Inc.\n", tarball_file(path, "package/LICENSE.txt")
    assert_equal "/* unrelated */\n", tarball_file(path, "package/styles.css")
  end

  def test_marker_keys_lists_what_the_package_asks_for
    assert_empty Paquette::NpmRepacker.marker_keys(fixture_package)

    source = fixture_package(files: {
      "index.js" => "// paquette:licensee\n// paquette:licensee\n",
      "LICENSE.txt" => "paquette:customer\n"
    })
    assert_equal %w[customer licensee], Paquette::NpmRepacker.marker_keys(source).sort
  end

  # The line count is what sourcemaps are sensitive to: a mapping's generated
  # column restarts each line, so a longer line disturbs nothing below it, but
  # an extra line shifts every mapping after it. The map rides along untouched.
  def test_replacement_preserves_the_line_count_and_the_sourcemap
    source = fixture_package(files: {
      "index.js" => "// paquette:licensee\nexport const x = 1;\n//# sourceMappingURL=index.js.map\n",
      "index.js.map" => JSON.generate({"version" => 3, "sources" => ["index.ts"], "mappings" => "AAAA"})
    })

    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed to Acme, at some length"}, into: into)

    content = tarball_file(path, "package/index.js")
    assert_equal 3, content.lines.length
    assert_equal "// licensed to Acme, at some length\n", content.lines.first
    assert_equal "export const x = 1;\n", content.lines[1]
    assert_equal "//# sourceMappingURL=index.js.map\n", content.lines[2]
    assert_equal "AAAA", JSON.parse(tarball_file(path, "package/index.js.map"))["mappings"]
  end

  def test_binary_files_are_left_alone
    png = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".b
    source = fixture_package(files: {"logo.png" => png})

    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "licensed"}, into: into)

    assert_equal png, tarball_file(path, "package/logo.png").b
  end

  def test_injected_files
    path = Paquette::NpmRepacker.repack(fixture_package, values: {},
      files: {"LICENSE.txt" => "Licensed to Acme", "docs/USAGE.md" => "# Usage"}, into: into)

    assert_equal "Licensed to Acme", tarball_file(path, "package/LICENSE.txt")
    assert_equal "# Usage", tarball_file(path, "package/docs/USAGE.md")
  end

  def test_an_injected_file_replaces_one_already_there
    path = Paquette::NpmRepacker.repack(fixture_package, values: {},
      files: {"README.md" => "replaced"}, into: into)

    assert_equal "replaced", tarball_file(path, "package/README.md")
    assert_equal 1, Paquette::Tarball.entries(path).count { |entry| entry.name == "package/README.md" }
  end

  def test_an_injected_file_keeps_the_mode_of_the_one_it_replaces
    source = File.join(@work_dir, "source.tgz")
    Paquette::Tarball.write(source, [
      Paquette::Tarball::Entry.new(name: "package/package.json", mode: 0o644, mtime: NPM_EPOCH, content: '{"name":"widget"}'),
      Paquette::Tarball::Entry.new(name: "package/bin/cli.js", mode: 0o755, mtime: NPM_EPOCH, content: "#!/usr/bin/env node\n")
    ])

    path = Paquette::NpmRepacker.repack(source, values: {},
      files: {"bin/cli.js" => "#!/usr/bin/env node\n// licensed\n", "LICENSE.txt" => "Licensed to Acme"}, into: into)

    modes = Paquette::Tarball.entries(path).to_h { |entry| [entry.name, entry.mode] }
    assert_equal 0o755, modes["package/bin/cli.js"]
    assert_equal 0o644, modes["package/LICENSE.txt"]
  end

  # The tarball is rewritten in memory and never unpacked, so nothing on the
  # way — a Tempfile, the process umask — reaches the modes it writes. The
  # gem repacker learned that the hard way.
  def test_repacking_is_byte_identical_whatever_the_umask
    source = File.join(@work_dir, "source.tgz")
    Paquette::Tarball.write(source, [
      Paquette::Tarball::Entry.new(name: "package/package.json", mode: 0o664, mtime: NPM_EPOCH, content: '{"name":"widget"}'),
      Paquette::Tarball::Entry.new(name: "package/index.js", mode: 0o600, mtime: NPM_EPOCH, content: "module.exports = 1;\n"),
      Paquette::Tarball::Entry.new(name: "package/bin/cli.js", mode: 0o755, mtime: NPM_EPOCH, content: "#!/usr/bin/env node\n")
    ])

    digests = [0o022, 0o002, 0o077].map do |umask|
      previous = File.umask(umask)
      begin
        path = Paquette::NpmRepacker.repack(source, values: {},
          files: {"LICENSE.txt" => "Licensed to Acme"}, into: into("umask-#{umask.to_s(8)}.tgz"))
        Digest::SHA256.file(path).hexdigest
      ensure
        File.umask(previous)
      end
    end

    assert_equal 1, digests.uniq.length
  end

  def test_repack_changes_the_checksum
    source = fixture_package
    original = Digest::SHA256.file(source).hexdigest

    path = Paquette::NpmRepacker.repack(source, values: {"licensee" => "L"}, into: into)

    refute_equal original, Digest::SHA256.file(path).hexdigest
  end

  # What makes the Personalizer's published integrity hashes true.
  def test_repacking_is_reproducible
    source = fixture_package
    options = {
      values: {"licensee" => "LIC-1"},
      files: {"LICENSE.txt" => "Licensed to Acme"}
    }

    first = Paquette::NpmRepacker.repack(source, into: into("first.tgz"), **options)
    sleep 1.1
    second = Paquette::NpmRepacker.repack(source, into: into("second.tgz"), **options)

    assert_equal Digest::SHA256.file(first).hexdigest, Digest::SHA256.file(second).hexdigest
  end

  def test_into_places_the_result_where_the_caller_asked
    destination = File.join(@work_dir, "nested", "here.tgz")
    path = Paquette::NpmRepacker.repack(fixture_package, values: {}, into: destination)

    assert_equal destination, path
    assert_path_exists destination
  end

  def test_without_into_the_result_lands_somewhere_of_ours
    path = Paquette::NpmRepacker.repack(fixture_package, values: {})

    assert_path_exists path
    assert path.end_with?("-repacked.tgz")
  ensure
    FileUtils.rm_rf(File.dirname(path)) if path
  end
end
