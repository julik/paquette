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

    new_package_path = Paquette::NpmRepacker.repack(@test_package_path, into: into) do |input_file, output_file, file_path|
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
    Paquette::NpmRepacker.repack(fixture_package, into: into) do |input_file, output_file, file_path|
      seen << file_path
      IO.copy_stream(input_file, output_file)
    end

    assert_includes seen, "package.json"
    assert_includes seen, "index.js"
    refute seen.any? { |path| path.start_with?("package/") }
  end

  def test_repack_with_nonexistent_package
    assert_raises(ArgumentError) do
      Paquette::NpmRepacker.repack("/nonexistent/path.tgz") { |input_file, output_file, file_path| }
    end
  end

  def test_repack_without_a_block
    path = Paquette::NpmRepacker.repack(fixture_package,
      package_json_extras: {"paquette" => {"licenseKey" => "LIC-1"}}, into: into)

    package_json = JSON.parse(tarball_file(path, "package/package.json"))
    assert_equal({"licenseKey" => "LIC-1"}, package_json["paquette"])
    assert_equal "widget", package_json["name"]
  end

  def test_magic_comment_replacement
    source = fixture_package(files: {"index.js" => "// paquette_license_info\nexport const x = 1;\n"})
    path = Paquette::NpmRepacker.repack(source,
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme"}, into: into)

    content = tarball_file(path, "package/index.js")
    assert_equal "// licensed to Acme\nexport const x = 1;\n", content
  end

  # `esbuild --minify` pulls a legal comment onto the end of a code line. The
  # whole-line match then misses it and the package would be served with no
  # license key in it and nothing to say so.
  def test_a_marker_the_line_match_cannot_reach_is_refused
    source = fixture_package(files: {"index.js" => "function e(o,r){return o+r}// paquette_license_info\n"})

    error = assert_raises(Paquette::NpmRepacker::MarkerNotApplied) do
      Paquette::NpmRepacker.repack(source,
        magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme"}, into: into)
    end

    assert_includes error.message, "index.js"
  end

  # Most packages in a corpus carry no marker; that is not a failure.
  def test_a_package_without_the_marker_repacks_normally
    source = fixture_package(files: {"index.js" => "export const x = 1;\n"})

    path = Paquette::NpmRepacker.repack(source,
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme"}, into: into)

    assert_equal "export const x = 1;\n", tarball_file(path, "package/index.js")
  end

  # A marker inside a file type we never rewrite is not a missed replacement.
  def test_a_marker_in_an_unprocessed_file_is_left_alone
    source = fixture_package(files: {"styles.css" => "/* // paquette_license_info */\n"})

    path = Paquette::NpmRepacker.repack(source,
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme"}, into: into)

    assert_equal "/* // paquette_license_info */\n", tarball_file(path, "package/styles.css")
  end

  # Sourcemaps address generated code by line, so a marker line must be
  # replaced by exactly one line or every mapping below it misaligns.
  def test_replacement_preserves_the_line_count
    source = fixture_package(files: {
      "index.js" => "// paquette_license_info\nexport const x = 1;\n//# sourceMappingURL=index.js.map\n",
      "index.js.map" => JSON.generate({"version" => 3, "sources" => ["index.ts"], "mappings" => "AAAA"})
    })

    path = Paquette::NpmRepacker.repack(source,
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme\nand a second line"},
      into: into)

    content = tarball_file(path, "package/index.js")
    assert_equal 3, content.lines.length
    assert_equal "// licensed to Acme and a second line\n", content.lines.first
    assert_equal 3, JSON.parse(tarball_file(path, "package/index.js.map"))["version"]
  end

  def test_binary_files_are_left_alone
    png = "\x89PNG\r\n\x1a\n\x00\x01\x02\xff".b
    source = fixture_package(files: {"logo.png" => png})

    path = Paquette::NpmRepacker.repack(source,
      magic_comment_replacements: {"// paquette_license_info" => "licensed"}, into: into)

    assert_equal png, tarball_file(path, "package/logo.png").b
  end

  def test_injected_files
    path = Paquette::NpmRepacker.repack(fixture_package,
      files: {"LICENSE.txt" => "Licensed to Acme", "docs/USAGE.md" => "# Usage"}, into: into)

    assert_equal "Licensed to Acme", tarball_file(path, "package/LICENSE.txt")
    assert_equal "# Usage", tarball_file(path, "package/docs/USAGE.md")
  end

  def test_an_injected_file_replaces_one_already_there
    path = Paquette::NpmRepacker.repack(fixture_package,
      files: {"README.md" => "replaced"}, into: into)

    assert_equal "replaced", tarball_file(path, "package/README.md")
    assert_equal 1, Paquette::Tarball.entries(path).count { |entry| entry.name == "package/README.md" }
  end

  def test_repack_changes_the_checksum
    source = fixture_package
    original = Digest::SHA256.file(source).hexdigest

    path = Paquette::NpmRepacker.repack(source, package_json_extras: {"paquette" => {}}, into: into)

    refute_equal original, Digest::SHA256.file(path).hexdigest
  end

  # What makes the Personalizer's published integrity hashes true.
  def test_repacking_is_reproducible
    source = fixture_package
    options = {
      package_json_extras: {"paquette" => {"licenseKey" => "LIC-1"}},
      magic_comment_replacements: {"// paquette_license_info" => "licensed"},
      files: {"LICENSE.txt" => "Licensed to Acme"}
    }

    first = Paquette::NpmRepacker.repack(source, into: into("first.tgz"), **options)
    sleep 1.1
    second = Paquette::NpmRepacker.repack(source, into: into("second.tgz"), **options)

    assert_equal Digest::SHA256.file(first).hexdigest, Digest::SHA256.file(second).hexdigest
  end

  def test_into_places_the_result_where_the_caller_asked
    destination = File.join(@work_dir, "nested", "here.tgz")
    path = Paquette::NpmRepacker.repack(fixture_package, into: destination)

    assert_equal destination, path
    assert_path_exists destination
  end

  def test_without_into_the_result_lands_somewhere_of_ours
    path = Paquette::NpmRepacker.repack(fixture_package)

    assert_path_exists path
    assert path.end_with?("-repacked.tgz")
  ensure
    FileUtils.rm_rf(File.dirname(path)) if path
  end
end
