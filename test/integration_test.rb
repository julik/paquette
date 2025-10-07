require_relative "test_helper"

class IntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    # Use the gem server directly for backward compatibility testing
    gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @app = Paquette::GemServer.new(gems_dir)
  end

  attr_reader :app

  def test_root_endpoint
    get "/"
    assert_equal 200, last_response.status
    assert_equal "Paquette RubyGems Repository", last_response.body
  end

  def test_names_endpoint
    get "/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
  end

  def test_versions_endpoint
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    versions = JSON.parse(last_response.body)
    assert versions.length >= 6 # We have 6 gems in total

    # Check for specific gems
    scatter_gather_versions = versions.select { |v| v["name"] == "scatter_gather" }
    assert_equal 2, scatter_gather_versions.length
    assert_includes scatter_gather_versions.map { |v| v["number"] }, "0.1.0"
    assert_includes scatter_gather_versions.map { |v| v["number"] }, "0.1.1"

    zip_kit_versions = versions.select { |v| v["name"] == "zip_kit" }
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.0"
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.1"
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.3.2"
  end

  def test_specs_endpoint
    get "/specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert specs.length >= 6

    # Check for specific gems
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_latest_specs_endpoint
    get "/latest_specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert specs.length >= 3 # Should have latest version of each gem

    # Check for latest versions
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_gem_download
    get "/gems/scatter_gather-0.1.1.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_search_endpoint
    get "/api/v1/search.json", query: "scatter"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert results.is_a?(Array)
    scatter_result = results.find { |r| r["name"] == "scatter_gather" }
    refute_nil scatter_result
  end

  # Test compact index endpoints
  def test_compact_index_names
    get "/names"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    names = last_response.body.split("\n")
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
  end

  def test_compact_index_versions
    get "/versions"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    # Check for checksum header
    assert last_response.headers["X-Checksum-Sha256"]
    refute_nil last_response.headers["X-Checksum-Sha256"]

    lines = last_response.body.split("\n")

    # Check for timestamp header
    assert lines[0].start_with?("created_at:")
    assert lines[1] == "---"

    # Check gem lines (skip timestamp and separator)
    gem_lines = lines[2..]
    assert gem_lines.length >= 3

    # Check that each gem line has the format "gem_name versions checksum"
    gem_lines.each do |line|
      parts = line.split(" ")
      assert parts.length >= 3, "Each gem line should have at least 3 parts: #{line}"
      assert_match(/^[a-f0-9]{32}$/, parts[-1], "Checksum should be 32 hex characters: #{line}")
    end

    # Check for specific gems
    gem_names = gem_lines.map { |line| line.split(" ")[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_compact_index_info
    get "/info/scatter_gather"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    info_lines = last_response.body.split("\n")
    assert info_lines.length >= 2

    # Check that each line has the format "version |checksum:sha256_checksum,ruby:required_ruby_version"
    info_lines.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line, "Line should match compact index format: #{line}")

      # Parse the line
      version, rest = line.split(" ", 2)
      assert version.match?(/^\d+\.\d+\.\d+/), "Version should be in semver format: #{version}"

      # Check checksum and ruby version parts
      assert rest.start_with?("|checksum:"), "Should have checksum prefix: #{rest}"
      checksum_part, ruby_part = rest[1..].split(",", 2)
      assert checksum_part.start_with?("checksum:"), "Should have checksum: #{checksum_part}"
      checksum = checksum_part.split(":", 2)[1]
      assert_match(/^[a-f0-9]{64}$/, checksum, "Checksum should be 64 hex characters (SHA256): #{checksum}")

      assert ruby_part.start_with?("ruby:"), "Should have ruby version requirement: #{ruby_part}"
    end

    # Check for specific versions
    version_lines = info_lines.map { |line| line.split(" ")[0] }
    assert_includes version_lines, "0.1.0"
    assert_includes version_lines, "0.1.1"
  end

  def test_compact_index_info_nonexistent
    get "/info/nonexistent"
    assert_equal 404, last_response.status
  end

  def test_specs_gz_endpoint
    get "/specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type

    # Verify it's proper gzip format by decompressing
    decompressed = Zlib::GzipReader.new(StringIO.new(last_response.body)).read
    specs = Marshal.load(decompressed)
    assert specs.is_a?(Array)
    assert specs.length >= 6

    # Check for specific gems
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_latest_specs_gz_endpoint
    get "/latest_specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type

    # Verify it's proper gzip format by decompressing
    decompressed = Zlib::GzipReader.new(StringIO.new(last_response.body)).read
    specs = Marshal.load(decompressed)
    assert specs.is_a?(Array)
    assert specs.length >= 3 # Should have latest version of each gem

    # Check for latest versions
    gem_names = specs.map { |spec| spec[0] }
    assert_includes gem_names, "scatter_gather"
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"
  end

  def test_quick_gemspec_endpoint
    get "/quick/Marshal.4.8/zip_kit-6.3.2.gemspec.rz"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    # Verify it's compressed with raw deflate and can be decompressed
    decompressed = Zlib::Inflate.inflate(last_response.body)
    spec = Marshal.load(decompressed)
    assert_equal "zip_kit", spec.name
    assert_equal "6.3.2", spec.version.to_s
  end

  def test_quick_gemspec_nonexistent
    get "/quick/Marshal.4.8/nonexistent-1.0.0.gemspec.rz"
    assert_equal 404, last_response.status
  end
end
