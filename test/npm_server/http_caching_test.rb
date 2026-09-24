require_relative "../test_helper"

# Conditional GET and download caching on the npm server - the twin of
# test/gem_server/http_caching_test.rb, and the same warning applies twice
# over.
#
# On the gem side a Personalizer changes the bytes of a .gem and the
# checksum the index publishes for it. On the npm side it changes the
# *packument itself*: dist.integrity is recomputed per licensee and the
# document carries one per version. So a packument cached under a
# licensee-independent key and replayed to a second licensee hands them
# integrity hashes that cannot match the tarball they download next, and
# npm reports that as tampering and refuses to install. Several tests below
# therefore assert the absence of a validator, or that two validators
# differ, rather than that caching works.
class NpmHttpCachingTest < Minitest::Test
  PACKAGE = "widgets"

  def setup
    @dir = Dir.mktmpdir("paquette_npm_caching")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
    write_npm_package(@dir, name: PACKAGE, version: "1.0.0")
    write_npm_package(@dir, name: PACKAGE, version: "1.1.0")
    @cache_dirs = []
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
    @cache_dirs.each { |dir| FileUtils.remove_entry(dir) if File.exist?(dir) }
  end

  # ------------------------------------------------------------------
  # Packuments
  # ------------------------------------------------------------------

  def test_a_repeat_packument_fetch_is_not_modified
    app = plain_app

    first = get(app, "/#{PACKAGE}")
    assert_equal 200, first[0]
    etag = first[1]["ETag"]
    refute_nil etag

    second = get(app, "/#{PACKAGE}", "HTTP_IF_NONE_MATCH" => etag)
    assert_equal 304, second[0]
    assert_equal etag, second[1]["ETag"]
    assert_equal "", body_of(second)
  end

  def test_a_stale_packument_etag_does_not_get_a_304
    assert_equal 200, get(plain_app, "/#{PACKAGE}", "HTTP_IF_NONE_MATCH" => %("nonsense"))[0]
  end

  def test_two_packages_do_not_share_a_packument_validator
    write_npm_package(@dir, name: "other", version: "1.0.0")
    app = plain_app

    refute_equal get(app, "/#{PACKAGE}")[1]["ETag"], get(app, "/other")[1]["ETag"]
  end

  def test_the_packument_validator_moves_on_publish
    app = plain_app
    before = get(app, "/#{PACKAGE}")[1]["ETag"]

    @repository.add_package(npm_tarball_bytes(name: PACKAGE, version: "2.0.0"))

    refute_equal before, get(app, "/#{PACKAGE}")[1]["ETag"]
    assert_equal 200, get(app, "/#{PACKAGE}", "HTTP_IF_NONE_MATCH" => before)[0]
  end

  def test_the_packument_validator_moves_on_unpublish
    app = plain_app
    before = get(app, "/#{PACKAGE}")[1]["ETag"]

    @repository.yank_package(PACKAGE, "1.1.0")

    refute_equal before, get(app, "/#{PACKAGE}")[1]["ETag"]
  end

  # The case the gem side does not have. A dist-tag write rewrites
  # dist-tags.json in place, so no path moves and a fingerprint built from
  # paths alone would not notice. The repository folds that file's mtime in
  # for exactly this reason.
  def test_the_packument_validator_moves_on_a_dist_tag_write
    app = plain_app
    before = get(app, "/#{PACKAGE}")[1]["ETag"]

    @repository.write_dist_tag(PACKAGE, "beta", "1.0.0")

    refute_equal before, get(app, "/#{PACKAGE}")[1]["ETag"],
      "a dist-tag write must move the validator, or npm keeps resolving a tag that moved"
  end

  # The packument embeds absolute tarball URLs built from the request base.
  # Host is part of any cache key already; scheme is not, and a proxy
  # varying X-Forwarded-Proto for one host would otherwise let a cached
  # document hand http:// URLs to an https:// client.
  def test_the_packument_validator_folds_in_the_request_base_url
    app = plain_app
    http = app.call(Rack::MockRequest.env_for("http://npm.example.com/#{PACKAGE}"))
    https = app.call(Rack::MockRequest.env_for("https://npm.example.com/#{PACKAGE}"))

    refute_equal http[1]["ETag"], https[1]["ETag"]
  end

  # ------------------------------------------------------------------
  # dist-tags
  # ------------------------------------------------------------------

  def test_dist_tags_answer_conditional_requests
    @repository.write_dist_tag(PACKAGE, "beta", "1.1.0")
    app = plain_app

    first = get(app, "/-/package/#{PACKAGE}/dist-tags")
    assert_equal 200, first[0]
    refute_nil first[1]["ETag"]

    assert_equal 304, get(app, "/-/package/#{PACKAGE}/dist-tags",
      "HTTP_IF_NONE_MATCH" => first[1]["ETag"])[0]
  end

  def test_dist_tags_validator_moves_when_a_tag_is_repointed
    @repository.write_dist_tag(PACKAGE, "beta", "1.0.0")
    app = plain_app
    before = get(app, "/-/package/#{PACKAGE}/dist-tags")[1]["ETag"]

    @repository.write_dist_tag(PACKAGE, "beta", "1.1.0")

    refute_equal before, get(app, "/-/package/#{PACKAGE}/dist-tags")[1]["ETag"]
  end

  def test_dist_tags_and_the_packument_do_not_share_a_validator
    @repository.write_dist_tag(PACKAGE, "beta", "1.1.0")
    app = plain_app

    refute_equal get(app, "/#{PACKAGE}")[1]["ETag"],
      get(app, "/-/package/#{PACKAGE}/dist-tags")[1]["ETag"]
  end

  # ------------------------------------------------------------------
  # whoami is identity and is never stored
  # ------------------------------------------------------------------

  def test_whoami_is_never_cacheable
    response = get(plain_app, "/-/whoami")

    assert_equal 200, response[0]
    assert_equal "no-store", response[1]["Cache-Control"]
    assert_nil response[1]["ETag"], "identity must not be given a validator"
  end

  def test_whoami_is_not_cacheable_under_gating_either
    response = get(gated_app(gate_key: "alice") { |**| true }, "/-/whoami")

    assert_equal "no-store", response[1]["Cache-Control"]
    refute_includes response[1]["Cache-Control"], "public"
  end

  # ------------------------------------------------------------------
  # The wrapper chain
  # ------------------------------------------------------------------

  def test_a_gate_without_a_key_emits_no_etag_at_all
    response = get(gated_app(gate_key: nil) { |**| true }, "/#{PACKAGE}")

    assert_equal 200, response[0]
    assert_nil response[1]["ETag"]
    assert_equal 200, get(gated_app(gate_key: nil) { |**| true }, "/#{PACKAGE}", "HTTP_IF_NONE_MATCH" => "*")[0]
  end

  def test_the_fail_closed_gate_propagates_through_a_personalizer_above_it
    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository) { |**| true }
    personalized = Paquette::NpmServer::Personalizer.new(gated,
      license_key: "L", personalization_key: "one", cache_dir: tmp_cache_dir)

    assert_nil get(Paquette::NpmServer.new(personalized), "/#{PACKAGE}")[1]["ETag"]
  end

  def test_two_different_gates_produce_different_validators
    alice = get(gated_app(gate_key: "alice") { |**| true }, "/#{PACKAGE}")
    bob = get(gated_app(gate_key: "bob") { |**| true }, "/#{PACKAGE}")

    refute_nil alice[1]["ETag"]
    refute_nil bob[1]["ETag"]
    refute_equal alice[1]["ETag"], bob[1]["ETag"]

    crossed = get(gated_app(gate_key: "alice") { |**| true },
      "/#{PACKAGE}", "HTTP_IF_NONE_MATCH" => bob[1]["ETag"])
    assert_equal 200, crossed[0]
  end

  def test_the_same_gate_key_is_stable_across_freshly_built_stacks
    one = get(gated_app(gate_key: "licensee-1") { |**| true }, "/#{PACKAGE}")[1]["ETag"]
    two = get(gated_app(gate_key: "licensee-1") { |**| true }, "/#{PACKAGE}")[1]["ETag"]

    assert_equal one, two
  end

  def test_a_personalized_packument_does_not_collide_with_the_plain_one
    plain = get(plain_app, "/#{PACKAGE}")[1]["ETag"]
    personalized = get(personalized_app(key: "one"), "/#{PACKAGE}")[1]["ETag"]

    refute_nil personalized
    refute_equal plain, personalized
  end

  # The one that matters most on this side. Two licensees get genuinely
  # different documents, because dist.integrity is computed from their own
  # repacked tarball - so if the validators ever collided, npm would be
  # handed hashes for bytes it will never receive.
  def test_two_licensees_get_different_packuments_and_different_validators
    one = get(personalized_app(key: "one"), "/#{PACKAGE}")
    two = get(personalized_app(key: "two"), "/#{PACKAGE}")

    integrity_one = integrity_in(one, "1.0.0")
    integrity_two = integrity_in(two, "1.0.0")

    refute_nil integrity_one
    refute_equal integrity_one, integrity_two,
      "this test is meaningless unless personalization really changes the document"
    refute_equal one[1]["ETag"], two[1]["ETag"],
      "two licensees with different integrity hashes must not share a validator"
  end

  # ------------------------------------------------------------------
  # Cache-Control
  # ------------------------------------------------------------------

  def test_no_gated_or_personalized_response_ever_carries_public
    apps = {
      "gated with a key" => gated_app(gate_key: "alice") { |**| true },
      "gated without a key" => gated_app(gate_key: nil) { |**| true },
      "personalized" => personalized_app(key: "one"),
      "gated and personalized" => gated_and_personalized_app
    }

    paths = ["/#{PACKAGE}", "/-/package/#{PACKAGE}/dist-tags", "/#{PACKAGE}/-/#{PACKAGE}-1.0.0.tgz"]

    apps.each do |description, app|
      paths.each do |path|
        headers = get(app, path)[1]
        control = headers["Cache-Control"].to_s

        refute_includes control, "public", "#{description} #{path} is offered to a shared cache"
        assert_includes control, "private", "#{description} #{path} must be marked private"
        assert_equal "Authorization, Accept-Encoding", headers["Vary"], "#{description} #{path}"
      end
    end
  end

  def test_a_plain_registry_is_public_and_says_so
    headers = get(plain_app, "/#{PACKAGE}")[1]
    assert_equal "public, no-cache", headers["Cache-Control"]
    assert_nil headers["Vary"]
  end

  def test_a_private_packument_still_lets_the_client_keep_a_copy
    control = get(personalized_app(key: "one"), "/#{PACKAGE}")[1]["Cache-Control"]
    assert_equal "private, no-cache", control
    refute_includes control, "no-store"
  end

  # ------------------------------------------------------------------
  # Tarballs
  # ------------------------------------------------------------------

  def test_a_plain_tarball_is_immutable_and_public
    headers = get(plain_app, tarball_path)[1]

    assert_equal "public, max-age=31536000, immutable", headers["Cache-Control"]
    assert_equal "bytes", headers["Accept-Ranges"]
    assert_equal "application/octet-stream", headers["Content-Type"]
    refute_nil headers["ETag"]
    refute_nil headers["Last-Modified"]
  end

  # The ETag is the very integrity hash the packument published. npm
  # hard-fails when the tarball does not match the document, so these two
  # must be the same number by construction.
  def test_the_tarball_etag_is_the_integrity_the_packument_published
    app = plain_app
    published = integrity_in(get(app, "/#{PACKAGE}"), "1.0.0")

    assert_equal %("#{published}"), get(app, tarball_path)[1]["ETag"]
  end

  def test_a_tarball_answers_if_none_match_and_if_modified_since
    app = plain_app
    headers = get(app, tarball_path)[1]

    assert_equal 304, get(app, tarball_path, "HTTP_IF_NONE_MATCH" => headers["ETag"])[0]
    assert_equal 304, get(app, tarball_path, "HTTP_IF_MODIFIED_SINCE" => headers["Last-Modified"])[0]
    assert_equal 200, get(app, tarball_path, "HTTP_IF_MODIFIED_SINCE" => Time.at(0).httpdate)[0]
  end

  def test_a_personalized_tarball_does_not_share_the_plain_validator
    plain = get(plain_app, tarball_path)[1]["ETag"]
    personalized = get(personalized_app(key: "one"), tarball_path)[1]["ETag"]

    refute_equal plain, personalized
  end

  def test_a_range_request_returns_the_right_bytes_and_content_range
    app = plain_app
    whole = body_of(get(app, tarball_path))

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=0-9")
    assert_equal 206, response[0]
    assert_equal "bytes 0-9/#{whole.bytesize}", response[1]["Content-Range"]
    assert_equal whole[0, 10], body_of(response)
  end

  def test_a_suffix_range
    app = plain_app
    whole = body_of(get(app, tarball_path))
    size = whole.bytesize

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=-16")
    assert_equal 206, response[0]
    assert_equal "bytes #{size - 16}-#{size - 1}/#{size}", response[1]["Content-Range"]
    assert_equal whole[size - 16, 16], body_of(response)
  end

  def test_an_unsatisfiable_range_is_416_with_the_entity_size
    app = plain_app
    size = body_of(get(app, tarball_path)).bytesize

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=#{size + 1000}-#{size + 2000}")
    assert_equal 416, response[0]
    assert_equal "bytes */#{size}", response[1]["Content-Range"]
  end

  def test_a_garbled_range_header_serves_the_whole_entity
    app = plain_app
    whole = body_of(get(app, tarball_path))

    response = get(app, tarball_path, "HTTP_RANGE" => "cubits=0-9")
    assert_equal 200, response[0]
    assert_equal whole, body_of(response)
  end

  def test_several_ranges_at_once_come_back_as_a_multipart_response
    app = plain_app
    whole = body_of(get(app, tarball_path))

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=0-9,20-29")
    assert_equal 206, response[0]
    assert response[1]["Content-Type"].start_with?("multipart/byteranges;")
    assert_includes body_of(response), whole[0, 10]
  end

  def test_if_range_with_a_stale_tag_serves_the_whole_entity
    app = plain_app
    whole = body_of(get(app, tarball_path))

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=0-9", "HTTP_IF_RANGE" => %("stale"))
    assert_equal 200, response[0]
    assert_equal whole, body_of(response)
  end

  def test_a_tarball_over_a_gated_package_is_still_refused
    app = gated_app(gate_key: "alice") { |**| false }
    assert_equal 404, get(app, tarball_path, "HTTP_RANGE" => "bytes=0-9")[0]
  end

  def test_a_range_over_a_personalized_tarball_reads_the_personalized_bytes
    app = personalized_app(key: "one")
    whole = body_of(get(app, tarball_path))

    response = get(app, tarball_path, "HTTP_RANGE" => "bytes=0-31")
    assert_equal 206, response[0]
    assert_equal whole[0, 32], body_of(response)
  end

  private

  def tarball_path
    "/#{PACKAGE}/-/#{PACKAGE}-1.0.0.tgz"
  end

  def integrity_in(response, version)
    JSON.parse(body_of(response)).dig("versions", version, "dist", "integrity")
  end

  def plain_app
    Paquette::NpmServer.new(@repository)
  end

  def gated_app(gate_key:, &entitler)
    Paquette::NpmServer.new(
      Paquette::NpmServer::ReadGatedRepository.new(@repository, gate_key: gate_key, &entitler)
    )
  end

  def personalized_app(key:)
    personalized = Paquette::NpmServer::Personalizer.new(@repository,
      license_key: "LICENSE-#{key}", personalization_key: key,
      files: {"LICENSE.txt" => "Licensed to #{key}\n"}, cache_dir: tmp_cache_dir)

    Paquette::NpmServer.new(personalized)
  end

  def gated_and_personalized_app
    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository, gate_key: "alice") { |**| true }
    personalized = Paquette::NpmServer::Personalizer.new(gated,
      license_key: "L", personalization_key: "alice",
      files: {"LICENSE.txt" => "Licensed to alice\n"}, cache_dir: tmp_cache_dir)

    Paquette::NpmServer.new(personalized)
  end

  def tmp_cache_dir
    dir = Dir.mktmpdir("paquette_npm_caching_cache")
    @cache_dirs << dir
    dir
  end

  def get(app, path, env = {})
    app.call(Rack::MockRequest.env_for("http://npm.example.com#{path}", env))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end
end
