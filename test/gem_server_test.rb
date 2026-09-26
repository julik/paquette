require_relative "test_helper"

class GemServerTest < Minitest::Test
  include Rack::Test::Methods

  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    repo = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    @app = Paquette::GemServer.new(repo)
  end

  attr_reader :app

  # A writable gem server over `dir`, which is what every push test needs.
  def push_session(dir)
    repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
    Rack::Test::Session.new(Rack::MockSession.new(Paquette::GemServer.new(repo)))
  end

  def test_root_endpoint
    get "/"
    assert_equal 200, last_response.status
    assert_equal "text/html", last_response.content_type.split(";").first
    assert_includes last_response.body, Paquette::GemServer::DEFAULT_BLURB
  end

  # A scanner sending a multipart Content-Type with no body: the client's
  # mistake, not ours, and it used to come back as a 500.
  def test_unparseable_request_body_is_a_bad_request
    status, _headers, body = app.call(malformed_multipart_env("/"))
    assert_equal 400, status
    assert_includes body.first, "Could not parse request parameters"
  end

  def test_truncated_request_body_is_a_bad_request
    status, = app.call(malformed_multipart_env("/", body: "", content_length: "10"))
    assert_equal 400, status
  end

  def test_names_endpoint
    get "/api/v1/names"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    names = JSON.parse(last_response.body)
    assert_equal ["minuscule_test", "zip_kit"], names.sort
  end

  def test_versions_endpoint
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    versions = JSON.parse(last_response.body)
    assert_equal 3, versions.length

    zip_kit_versions = versions.select { |v| v["name"] == "zip_kit" }
    assert_equal 2, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.0"
    assert_includes zip_kit_versions.map { |v| v["number"] }, "6.2.1"

    minuscule_versions = versions.select { |v| v["name"] == "minuscule_test" }
    assert_equal 1, minuscule_versions.length
    assert_includes minuscule_versions.map { |v| v["number"] }, "0.1.0"
  end

  def test_specs_endpoint
    get "/specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert_equal 3, specs.length

    gem_names = specs.map { |spec| spec[0] }.sort.uniq
    assert_equal ["minuscule_test", "zip_kit"], gem_names
  end

  def test_latest_specs_endpoint
    get "/latest_specs.4.8"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    specs = Marshal.load(last_response.body)
    assert specs.is_a?(Array)
    assert_equal 2, specs.length

    gem_names = specs.map { |spec| spec[0] }.sort
    assert_equal ["minuscule_test", "zip_kit"], gem_names
  end

  def test_gem_download
    get "/gems/zip_kit-6.2.0.gem"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_search_endpoint
    get "/api/v1/search.json", query: "zip"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    results = JSON.parse(last_response.body)
    assert results.is_a?(Array)
    assert results.any? { |r| r["name"] == "zip_kit" }
  end

  # Test compact index endpoints
  def test_compact_index_names
    get "/names"
    assert_equal 200, last_response.status
    assert_equal Paquette::GemServer::COMPACT_INDEX_CONTENT_TYPE, last_response.content_type

    # The format's own marker first, then one name per line, then the
    # newline that terminates the last of them.
    assert_equal "---\nminuscule_test\nzip_kit\n", last_response.body
  end

  def test_compact_index_versions
    get "/versions"
    assert_equal 200, last_response.status
    assert_equal Paquette::GemServer::COMPACT_INDEX_CONTENT_TYPE, last_response.content_type
    assert last_response.body.end_with?("\n"), "every line of the compact index is terminated, the last one included"

    lines = last_response.body.split("\n")

    # Check for timestamp header
    assert lines[0].start_with?("created_at:")
    assert lines[1] == "---"

    # Check gem lines (skip timestamp and separator)
    gem_lines = lines[2..]
    assert_equal 2, gem_lines.length

    # Check that each gem line has the format "gem_name versions checksum"
    gem_lines.each do |line|
      parts = line.split(" ")
      assert parts.length >= 3, "Each gem line should have at least 3 parts: #{line}"
      assert_match(/^[a-f0-9]{32}$/, parts[-1], "Checksum should be 32 hex characters: #{line}")
    end

    gem_names = gem_lines.map { |line| line.split(" ")[0] }
    assert_equal ["minuscule_test", "zip_kit"], gem_names.sort
  end

  # Bundler skips re-fetching /info/NAME when this column matches the MD5 of the
  # info file it already has, so the column has to be that MD5 and nothing else.
  # rubygems.org does the same: md5(/info/rake) == the rake row's third column.
  def test_versions_checksum_is_the_md5_of_the_info_file
    get "/versions"
    row = last_response.body.split("\n").find { |line| line.start_with?("zip_kit ") }

    get "/info/zip_kit"
    assert_equal Digest::MD5.hexdigest(last_response.body), row.split(" ").last
  end

  def test_compact_index_info
    get "/info/zip_kit"
    assert_equal 200, last_response.status
    assert_equal Paquette::GemServer::COMPACT_INDEX_CONTENT_TYPE, last_response.content_type

    lines = last_response.body.split("\n")

    # The format's own header, as rubygems.org serves it
    assert_equal "---", lines[0]

    info_lines = lines[1..]
    assert_equal 2, info_lines.length

    # Check that each line has the format "version |checksum:sha256_checksum,ruby:required_ruby_version"
    info_lines.each do |line|
      assert_match(/^\S+\s+\|checksum:[a-f0-9]{64},ruby:.+$/, line, "Line should match compact index format: #{line}")

      version, rest = line.split(" ", 2)
      assert version.match?(/^\d+\.\d+\.\d+/), "Version should be in semver format: #{version}"

      assert rest.start_with?("|checksum:"), "Should have checksum prefix: #{rest}"
      checksum_part, ruby_part = rest[1..].split(",", 2)
      assert checksum_part.start_with?("checksum:"), "Should have checksum: #{checksum_part}"
      checksum = checksum_part.split(":", 2)[1]
      assert_match(/^[a-f0-9]{64}$/, checksum, "Checksum should be 64 hex characters (SHA256): #{checksum}")

      assert ruby_part.start_with?("ruby:"), "Should have ruby version requirement: #{ruby_part}"
    end

    version_lines = info_lines.map { |line| line.split(" ")[0] }
    assert_includes version_lines, "6.2.0"
    assert_includes version_lines, "6.2.1"
  end

  def test_compact_index_info_nonexistent
    get "/info/nonexistent"
    assert_equal 404, last_response.status
  end

  def test_specs_gz_endpoint
    get "/specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type

    decompressed = Zlib::GzipReader.new(StringIO.new(last_response.body)).read
    specs = Marshal.load(decompressed)
    assert specs.is_a?(Array)
    assert_equal 3, specs.length

    gem_names = specs.map { |spec| spec[0] }.sort.uniq
    assert_equal ["minuscule_test", "zip_kit"], gem_names
  end

  def test_latest_specs_gz_endpoint
    get "/latest_specs.4.8.gz"
    assert_equal 200, last_response.status
    assert_equal "application/x-gzip", last_response.content_type

    decompressed = Zlib::GzipReader.new(StringIO.new(last_response.body)).read
    specs = Marshal.load(decompressed)
    assert specs.is_a?(Array)
    assert_equal 2, specs.length

    gem_names = specs.map { |spec| spec[0] }.sort
    assert_equal ["minuscule_test", "zip_kit"], gem_names
  end

  def test_quick_gemspec_endpoint
    get "/quick/Marshal.4.8/zip_kit-6.2.0.gemspec.rz"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type

    decompressed = Zlib::Inflate.inflate(last_response.body)
    spec = Marshal.load(decompressed)
    assert_equal "zip_kit", spec.name
    assert_equal "6.2.0", spec.version.to_s
  end

  def test_quick_gemspec_nonexistent
    get "/quick/Marshal.4.8/nonexistent-1.0.0.gemspec.rz"
    assert_equal 404, last_response.status
  end

  def test_push_publishes_gem
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      binary = File.binread(MINUSCULE_FIXTURE)

      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"

      assert_equal 200, session.last_response.status
      assert_equal "text/plain", session.last_response.content_type
      assert_equal "Successfully registered gem: minuscule_test-0.1.0", session.last_response.body

      persisted = File.join(dir, "minuscule_test", "minuscule_test-0.1.0.gem")
      assert File.exist?(persisted)
      assert_equal binary, File.binread(persisted)
    end
  end

  def test_push_rejects_duplicate
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      binary = File.binread(MINUSCULE_FIXTURE)

      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"
      assert_equal 200, session.last_response.status

      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"
      assert_equal 409, session.last_response.status
      assert_match(/already exists/, session.last_response.body)
    end
  end

  def test_push_rejects_invalid_payload
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      session.post "/api/v1/gems", "not a real gem", "CONTENT_TYPE" => "application/octet-stream"
      assert_equal 400, session.last_response.status
    end
  end

  # End to end, over the endpoint a `gem push` actually reaches, and in
  # the README's default dev setup that endpoint has no auth in front of
  # it at all. What is asserted is that nothing landed anywhere outside
  # the configured gems root, not merely that the status was a 400.
  def test_push_of_a_traversing_name_writes_nothing_outside_the_gems_root
    Dir.mktmpdir do |outer|
      gems_dir = File.join(outer, "a", "b", "gems")
      session = push_session(gems_dir)
      before = Dir.glob(File.join(outer, "**", "*"), File::FNM_DOTMATCH).sort

      session.post "/api/v1/gems", hostile_gem_bytes(name: "../../pwned"), "CONTENT_TYPE" => "application/octet-stream"

      assert_equal 400, session.last_response.status
      refute_empty session.last_response.body, "Bundler raises on a push response with no text"
      assert_equal before, Dir.glob(File.join(outer, "**", "*"), File::FNM_DOTMATCH).sort
    end
  end

  def test_push_of_a_forged_name_is_a_bad_request_with_a_body
    Dir.mktmpdir do |dir|
      session = push_session(dir)

      session.post "/api/v1/gems", hostile_gem_bytes(name: "safe\nforged 9.9.9 deadbeef"),
        "CONTENT_TYPE" => "application/octet-stream"

      assert_equal 400, session.last_response.status
      refute_empty session.last_response.body
      assert_equal "text/plain", session.last_response.content_type

      # And the index it was aiming at is untouched.
      session.get "/names"
      assert_equal "---\n\n", session.last_response.body
    end
  end

  # An announced length over the cap costs nothing: it is refused before a
  # byte of the body is read.
  def test_push_refuses_an_oversized_declared_length
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app = Paquette::GemServer.new(repo, max_push_bytes: 64)
      session = Rack::Test::Session.new(Rack::MockSession.new(app))

      session.post "/api/v1/gems", File.binread(MINUSCULE_FIXTURE), "CONTENT_TYPE" => "application/octet-stream"

      assert_equal 413, session.last_response.status
      refute_empty session.last_response.body
      assert_equal [], Dir.glob(File.join(dir, "**", "*.gem"))
    end
  end

  # And a length the client lied about does not get a free pass, because
  # the cap is also enforced on the copy itself.
  def test_push_refuses_a_body_larger_than_a_understated_content_length
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      server = Paquette::GemServer.new(repo, max_push_bytes: 64)
      binary = File.binread(MINUSCULE_FIXTURE)

      env = Rack::MockRequest.env_for("/api/v1/gems",
        "REQUEST_METHOD" => "POST", "CONTENT_TYPE" => "application/octet-stream")
      env["rack.input"] = StringIO.new(binary)
      env["CONTENT_LENGTH"] = "10"

      status, _headers, body = server.call(env)

      assert_equal 413, status
      refute_empty body.first
      assert_equal [], Dir.glob(File.join(dir, "**", "*.gem"))
    end
  end

  def test_push_accepts_a_gem_within_the_cap
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      size = File.size(MINUSCULE_FIXTURE)
      app = Paquette::GemServer.new(repo, max_push_bytes: size)
      session = Rack::Test::Session.new(Rack::MockSession.new(app))

      session.post "/api/v1/gems", File.binread(MINUSCULE_FIXTURE), "CONTENT_TYPE" => "application/octet-stream"

      assert_equal 200, session.last_response.status
      assert repo.gem_exists?("minuscule_test", "0.1.0")
    end
  end

  # A repository wrapper may read the push once for its own purposes — a
  # date check, a scan — and rewind for the repository underneath. Each
  # rewind starts the count over, so a body read twice is not refused for
  # being twice as large.
  def test_capped_body_starts_its_count_over_on_rewind
    body = Paquette::GemServer::CappedBody.new(StringIO.new("a" * 64), 64)

    assert_equal 64, body.read.bytesize
    body.rewind
    assert_equal 64, body.read.bytesize
  end

  def test_capped_body_refuses_one_byte_past_the_cap
    body = Paquette::GemServer::CappedBody.new(StringIO.new("a" * 65), 64)

    assert_raises(Paquette::GemServer::CappedBody::TooLarge) { body.read }
  end

  def test_yank_removes_gem_from_listings
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      binary = File.binread(MINUSCULE_FIXTURE)
      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"

      session.delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}
      assert_equal 200, session.last_response.status
      assert_equal "Successfully yanked gem: minuscule_test-0.1.0", session.last_response.body

      tomb = File.join(dir, "minuscule_test", "minuscule_test-0.1.0.gem.tomb")
      assert File.exist?(tomb)
      refute File.exist?(File.join(dir, "minuscule_test", "minuscule_test-0.1.0.gem"))

      # The gem disappears from version listings and compact info
      session.get "/api/v1/versions"
      versions = JSON.parse(session.last_response.body)
      assert_empty versions.select { |v| v["name"] == "minuscule_test" }

      session.get "/info/minuscule_test"
      assert_equal 404, session.last_response.status
    end
  end

  def test_yank_nonexistent_returns_404
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      session.delete "/api/v1/gems/yank", {gem_name: "nope", version: "1.0.0"}
      assert_equal 404, session.last_response.status
    end
  end

  def test_yank_missing_params_returns_400
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      session.delete "/api/v1/gems/yank", {gem_name: "foo"}
      assert_equal 400, session.last_response.status
    end
  end

  def test_push_refuses_tombed_gem
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      binary = File.binread(MINUSCULE_FIXTURE)

      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"
      session.delete "/api/v1/gems/yank", {gem_name: "minuscule_test", version: "0.1.0"}

      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"
      assert_equal 403, session.last_response.status
      assert_match(/yanked/, session.last_response.body)
    end
  end

  # Serving /versions writes derived-metadata sidecars into .paquette-cache
  # directories next to the gems. Every endpoint that lists the tree — the
  # compact index, the legacy Marshal indexes, the JSON API — must stay
  # blind to them: a cache file that shows up as a gem name or a version is
  # a cache file a Bundler will try to install.
  def test_sidecar_cache_never_surfaces_in_any_listing_endpoint
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app_with_writable_dir = Paquette::GemServer.new(repo)
      session = Rack::Test::Session.new(Rack::MockSession.new(app_with_writable_dir))

      binary = File.binread(MINUSCULE_FIXTURE)
      session.post "/api/v1/gems", binary, "CONTENT_TYPE" => "application/octet-stream"

      # Warm the cache, then check every listing against the same one gem
      session.get "/versions"
      assert Dir.exist?(File.join(dir, "minuscule_test", ".paquette-cache"))

      session.get "/names"
      assert_equal ["---", "minuscule_test"], session.last_response.body.split("\n")

      session.get "/versions"
      gem_rows = session.last_response.body.split("\n")[2..]
      assert_equal ["minuscule_test"], gem_rows.map { |row| row.split(" ")[0] }

      session.get "/api/v1/names"
      assert_equal ["minuscule_test"], JSON.parse(session.last_response.body)

      session.get "/api/v1/versions"
      versions = JSON.parse(session.last_response.body)
      assert_equal [["minuscule_test", "0.1.0"]], versions.map { |v| [v["name"], v["number"]] }

      session.get "/specs.4.8"
      specs = Marshal.load(session.last_response.body)
      assert_equal [["minuscule_test", Gem::Version.new("0.1.0"), "ruby"]], specs

      session.get "/latest_specs.4.8"
      specs = Marshal.load(session.last_response.body)
      assert_equal [["minuscule_test", Gem::Version.new("0.1.0"), "ruby"]], specs
    end
  end

  def test_compact_info_returns_404_for_gated_gem
    repo = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repo) { |**| false }
    gated_app = Paquette::GemServer.new(gated)
    session = Rack::Test::Session.new(Rack::MockSession.new(gated_app))

    session.get "/info/zip_kit"
    assert_equal 404, session.last_response.status
  end

  def test_gem_download_returns_404_for_gated_gem
    repo = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repo) { |**| false }
    gated_app = Paquette::GemServer.new(gated)
    session = Rack::Test::Session.new(Rack::MockSession.new(gated_app))

    session.get "/gems/zip_kit-6.2.1.gem"
    assert_equal 404, session.last_response.status
    assert_match(/not found/i, session.last_response.body)
  end

  def test_push_and_yank_return_403_through_read_gated_repository
    Dir.mktmpdir do |dir|
      repo = Paquette::GemServer::DirectoryGemRepository.new(dir)
      gated = Paquette::GemServer::ReadGatedRepository.new(repo) { |**| true }
      read_only_app = Paquette::GemServer.new(gated)
      session = Rack::Test::Session.new(Rack::MockSession.new(read_only_app))

      session.post "/api/v1/gems", "anything", "CONTENT_TYPE" => "application/octet-stream"
      assert_equal 403, session.last_response.status
      assert_match(/not allowed/, session.last_response.body)

      session.delete "/api/v1/gems/yank", {gem_name: "foo", version: "1.0.0"}
      assert_equal 403, session.last_response.status
      assert_match(/not allowed/, session.last_response.body)
    end
  end
end
