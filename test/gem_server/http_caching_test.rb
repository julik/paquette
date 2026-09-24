require_relative "../test_helper"
require "digest"

# Conditional GET and download caching on the gem server.
#
# The half of this that matters is not "does a 304 come back" - it is that a
# validator is never reused across two callers who would be served different
# things. Paquette's whole design is a repository wrapped per request in a
# gate (each licensee sees a different subset of the corpus) and a
# personalizer (each licensee's gems carry different checksums), so an ETag
# derived from the corpus alone would let one licensee's cached index answer
# another licensee's request. That is a confidentiality bug and strictly
# worse than serving every request in full, which is why several of the tests
# below assert the *absence* of an ETag.
class HttpCachingTest < Minitest::Test
  def setup
    @cache_dirs = []
  end

  def teardown
    @cache_dirs.each { |dir| FileUtils.remove_entry(dir) if File.exist?(dir) }
  end

  # ------------------------------------------------------------------
  # Conditional GET on the index endpoints
  # ------------------------------------------------------------------

  def test_repeat_versions_request_with_if_none_match_is_not_modified
    app = plain_app

    first = get(app, "/versions")
    assert_equal 200, first[0]
    etag = first[1]["ETag"]
    refute_nil etag, "a plain repository must be able to name its index"

    second = get(app, "/versions", "HTTP_IF_NONE_MATCH" => etag)
    assert_equal 304, second[0]
    assert_equal etag, second[1]["ETag"]
    assert_equal "", body_of(second), "a 304 carries no body"
  end

  def test_names_and_info_answer_conditional_requests
    app = plain_app

    ["/names", "/info/zip_kit"].each do |path|
      first = get(app, path)
      assert_equal 200, first[0], path
      etag = first[1]["ETag"]
      refute_nil etag, path

      # Strong, not weak: these bodies are byte-identical across renders,
      # unlike /versions which stamps a created_at.
      refute etag.start_with?("W/"), "#{path} should carry a strong validator"

      assert_equal 304, get(app, path, "HTTP_IF_NONE_MATCH" => etag)[0], path
    end
  end

  def test_versions_validator_is_weak_because_the_body_carries_a_timestamp
    etag = get(plain_app, "/versions")[1]["ETag"]
    assert etag.start_with?("W/"),
      "/versions renders a fresh created_at every time, so it cannot claim byte equality"
  end

  def test_a_stale_etag_does_not_get_a_304
    app = plain_app
    assert_equal 200, get(app, "/versions", "HTTP_IF_NONE_MATCH" => %("nonsense"))[0]
  end

  def test_if_none_match_accepts_a_star_and_a_list_of_candidates
    app = plain_app
    etag = get(app, "/names")[1]["ETag"]

    assert_equal 304, get(app, "/names", "HTTP_IF_NONE_MATCH" => "*")[0]
    assert_equal 304, get(app, "/names", "HTTP_IF_NONE_MATCH" => %("other", #{etag}))[0]
    # Weak comparison is what a GET calls for, so a client that kept the
    # tag weakly still matches.
    assert_equal 304, get(app, "/names", "HTTP_IF_NONE_MATCH" => "W/#{etag}")[0]
  end

  # ------------------------------------------------------------------
  # The validator tracks the corpus
  # ------------------------------------------------------------------

  def test_etag_changes_after_a_push_and_after_a_yank
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), dir)
      repository = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app = Paquette::GemServer.new(repository)

      before = get(app, "/versions")[1]["ETag"]
      assert_equal before, get(app, "/versions")[1]["ETag"], "an unchanged corpus keeps its validator"

      repository.add_gem(File.binread(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.1.gem")))
      after_push = get(app, "/versions")[1]["ETag"]
      refute_equal before, after_push, "a push must move the validator"

      # And the tag the client is holding no longer earns a 304.
      assert_equal 200, get(app, "/versions", "HTTP_IF_NONE_MATCH" => before)[0]

      repository.yank_gem("zip_kit", "6.2.1")
      refute_equal after_push, get(app, "/versions")[1]["ETag"], "a yank must move the validator"
    end
  end

  # A yanked gem must not be reachable through a validator a client kept
  # from before the yank. It is not, because every /info/ validator folds in
  # the corpus fingerprint and a yank renames the .gem file away.
  def test_a_yanked_gem_gets_a_404_rather_than_a_304
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "zip_kit"), dir)
      repository = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app = Paquette::GemServer.new(repository)

      etag = get(app, "/info/zip_kit")[1]["ETag"]
      repository.yank_gem("zip_kit", "6.2.0")
      repository.yank_gem("zip_kit", "6.2.1")

      assert_equal 404, get(app, "/info/zip_kit", "HTTP_IF_NONE_MATCH" => etag)[0]
    end
  end

  def test_two_gems_do_not_share_one_info_validator
    app = plain_app
    zip_kit = get(app, "/info/zip_kit")[1]["ETag"]
    minuscule = get(app, "/info/minuscule_test")[1]["ETag"]

    refute_equal zip_kit, minuscule
    assert_equal 200, get(app, "/info/minuscule_test", "HTTP_IF_NONE_MATCH" => zip_kit)[0]
  end

  def test_endpoints_over_one_corpus_do_not_share_a_validator
    app = plain_app
    tags = ["/versions", "/names", "/info/zip_kit"].map { |path| get(app, path)[1]["ETag"] }
    assert_equal tags.length, tags.uniq.length, "each endpoint names its own body"
  end

  # ------------------------------------------------------------------
  # The wrapper chain: the part that must not be got wrong
  # ------------------------------------------------------------------

  # The gate is an arbitrary caller-supplied block. Nothing here can tell
  # what subset it selects, so without a caller-supplied key the server
  # refuses to name the response at all.
  def test_a_gate_without_a_key_emits_no_etag_at_all
    response = get(gated_app(gate_key: nil) { |**| true }, "/versions")

    assert_equal 200, response[0]
    assert_nil response[1]["ETag"],
      "a gate that cannot describe itself must not be given a validator"

    # And with no validator there is no way to earn a 304 either.
    assert_equal 200, get(gated_app(gate_key: nil) { |**| true }, "/versions", "HTTP_IF_NONE_MATCH" => "*")[0]
  end

  def test_the_fail_closed_gate_propagates_through_a_personalizer_above_it
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repository) { |**| true }
    personalized = Paquette::GemServer::Personalizer.new(gated,
      license_key: "L", personalization_key: "one", cache_dir: tmp_cache_dir)

    assert_nil Paquette::GemServer.new(personalized).call(env_for("/versions"))[1]["ETag"],
      "a layer that refused to name itself must not be named from above"
  end

  # The heart of it: two licensees, two gates, two different views of the
  # corpus. Their validators must not collide, or one 304 hands the other's
  # entitlements over.
  def test_two_different_gates_produce_different_validators
    alice = get(gated_app(gate_key: "alice") { |name:, version: nil| name == "zip_kit" }, "/versions")
    bob = get(gated_app(gate_key: "bob") { |name:, version: nil| name == "minuscule_test" }, "/versions")

    refute_nil alice[1]["ETag"]
    refute_nil bob[1]["ETag"]
    refute_equal alice[1]["ETag"], bob[1]["ETag"]

    # Concretely: Bob's tag must not get Alice's index off the hook.
    crossed = get(gated_app(gate_key: "alice") { |name:, version: nil| name == "zip_kit" },
      "/versions", "HTTP_IF_NONE_MATCH" => bob[1]["ETag"])
    assert_equal 200, crossed[0]
  end

  # Two gates that select the *same* gems but belong to different licensees
  # still differ, because the key is the licensee and not the outcome. This
  # is the case a naive "digest what the gate returned" scheme would get
  # wrong the moment entitlements changed.
  def test_gates_with_different_keys_differ_even_when_they_select_the_same_gems
    one = get(gated_app(gate_key: "licensee-1") { |**| true }, "/names")[1]["ETag"]
    two = get(gated_app(gate_key: "licensee-2") { |**| true }, "/names")[1]["ETag"]

    refute_equal one, two
  end

  def test_the_same_gate_key_is_stable_across_freshly_built_stacks
    # The README builds the wrapper stack per request, so the Proc is a new
    # object every time and cannot be what the validator is keyed on.
    one = get(gated_app(gate_key: "licensee-1") { |**| true }, "/names")[1]["ETag"]
    two = get(gated_app(gate_key: "licensee-1") { |**| true }, "/names")[1]["ETag"]

    assert_equal one, two
  end

  def test_a_personalized_index_does_not_collide_with_the_plain_one
    plain = get(plain_app, "/versions")[1]["ETag"]
    personalized = get(personalized_app(key: "one"), "/versions")[1]["ETag"]

    refute_nil personalized
    refute_equal plain, personalized
  end

  def test_two_licensees_of_one_personalizer_do_not_collide
    one = get(personalized_app(key: "one"), "/versions")[1]["ETag"]
    two = get(personalized_app(key: "two"), "/versions")[1]["ETag"]

    refute_equal one, two
  end

  def test_a_gated_stack_with_a_key_still_tracks_the_corpus
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), dir)
      repository = Paquette::GemServer::DirectoryGemRepository.new(dir)
      build = -> {
        gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: "k") { |**| true }
        Paquette::GemServer.new(gated)
      }

      before = get(build.call, "/versions")[1]["ETag"]
      repository.add_gem(File.binread(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.1.gem")))

      refute_equal before, get(build.call, "/versions")[1]["ETag"],
        "the gate's key must be mixed into the corpus fingerprint, not substituted for it"
    end
  end

  # ------------------------------------------------------------------
  # Cache-Control: the directive that keeps a shared cache honest
  # ------------------------------------------------------------------

  # Every request reaching Paquette may have been authorized by something,
  # and the embedder routinely serves one URL ungated to a caller holding a
  # credential and gated to the next. `public` is the directive that lets a
  # shared cache store the answer to an authorized request anyway, after
  # which the next caller for that URL gets it without the embedder's gate
  # running. So it is only ever sent to a request with no credential, over
  # a stack in which nothing varies by caller, from a server that was not
  # told to keep out of shared caches.
  def test_public_only_for_an_anonymous_request_over_an_open_stack
    each_caller do |caller, request_env|
      each_stack do |description, app, open|
        each_response(app, request_env) do |path, (status, headers, _body)|
          control = headers["Cache-Control"].to_s
          label = "#{caller} #{description} #{path} (#{status})"

          if open && caller == "anonymous" && !control.include?("no-store")
            assert control.start_with?("public, "), "#{label} should be offered to a shared cache, got #{control}"
          else
            refute_includes control, "public", "#{label} is offered to a shared cache"
            assert control.start_with?("private, "), "#{label} must be marked private, got #{control}"
          end
          assert_includes vary_fields(headers), "Authorization", label
        end
      end
    end
  end

  # Handlers spell headers in title case and Rack::Files in lowercase. A
  # response carrying both `Cache-Control` and `cache-control` is one a
  # cache may read either way.
  def test_no_response_carries_one_header_in_two_spellings
    each_caller do |caller, request_env|
      each_stack do |description, app, _open|
        each_response(app, request_env) do |path, (_status, headers, _body)|
          names = headers.keys.map(&:downcase)
          assert_equal names.uniq, names, "#{caller} #{description} #{path}"
        end
      end
    end
  end

  def test_the_header_matrix
    each_caller do |caller, request_env|
      each_stack do |description, app, open|
        scope = (open && caller == "anonymous") ? "public" : "private"
        label = "#{caller} #{description}"
        get_with = ->(path) { get(app, path, request_env)[1] }

        assert_directives "#{scope}, no-cache", get_with.call("/versions"), "#{label} /versions"
        assert_directives "#{scope}, no-cache", get_with.call("/names"), "#{label} /names"
        assert_directives "#{scope}, no-cache", get_with.call("/info/zip_kit"), "#{label} /info/"
        assert_directives "#{scope}, max-age=31536000, immutable",
          get_with.call("/gems/zip_kit-6.2.0.gem"), "#{label} download"

        # What nobody labelled: no validator, so nothing for anyone to
        # revalidate, and never public.
        assert_directives "private, no-store", get_with.call("/specs.4.8.gz"), "#{label} specs"
        assert_directives "private, no-store", get_with.call("/gems/nothing-1.0.0.gem"), "#{label} 404"
      end
    end
  end

  # no-cache, not no-store: the client keeping a copy is the entire point -
  # without it there is no If-None-Match to send and the 304 is unreachable.
  def test_a_private_index_still_lets_the_client_keep_a_copy
    control = get(plain_app, "/versions", "HTTP_AUTHORIZATION" => "Bearer x")[1]["Cache-Control"]
    assert_equal "private, no-cache", control
    refute_includes control, "no-store"
  end

  def test_a_304_repeats_the_caching_directives
    [[plain_app, {}, "public"], [plain_app, {"HTTP_AUTHORIZATION" => "Bearer x"}, "private"],
      [personalized_app(key: "one"), {}, "private"]].each do |app, request_env, scope|
      etag = get(app, "/versions", request_env)[1]["ETag"]
      response = get(app, "/versions", request_env.merge("HTTP_IF_NONE_MATCH" => etag))

      assert_equal 304, response[0]
      assert_directives "#{scope}, no-cache", response[1], "index 304"

      download = get(app, "/gems/zip_kit-6.2.0.gem", request_env)[1]
      response = get(app, "/gems/zip_kit-6.2.0.gem", request_env.merge("HTTP_IF_NONE_MATCH" => download["ETag"]))

      assert_equal 304, response[0]
      assert_directives "#{scope}, max-age=31536000, immutable", response[1], "download 304"
    end
  end

  # ------------------------------------------------------------------
  # Downloads
  # ------------------------------------------------------------------

  def test_a_plain_download_is_immutable
    headers = get(plain_app, "/gems/zip_kit-6.2.0.gem")[1]

    assert_equal "public, max-age=31536000, immutable", headers["Cache-Control"]
    assert_equal "bytes", headers["Accept-Ranges"]
    assert_equal "application/octet-stream", headers["Content-Type"]
    refute_nil headers["ETag"]
    refute_nil headers["Last-Modified"]
  end

  def test_a_download_answers_if_none_match_and_if_modified_since
    app = plain_app
    headers = get(app, "/gems/zip_kit-6.2.0.gem")[1]

    assert_equal 304, get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_IF_NONE_MATCH" => headers["ETag"])[0]
    assert_equal 304, get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_IF_MODIFIED_SINCE" => headers["Last-Modified"])[0]

    # A date the file is newer than, and a date that is not a date at all.
    stale = Time.at(0).httpdate
    assert_equal 200, get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_IF_MODIFIED_SINCE" => stale)[0]
    assert_equal 200, get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_IF_MODIFIED_SINCE" => "not a date")[0]
  end

  # If-None-Match is the precise question and wins over the date, as RFC
  # 9110 requires - a non-matching tag means "send it" even if the date
  # would have said otherwise.
  def test_if_none_match_takes_precedence_over_if_modified_since
    app = plain_app
    last_modified = get(app, "/gems/zip_kit-6.2.0.gem")[1]["Last-Modified"]

    response = get(app, "/gems/zip_kit-6.2.0.gem",
      "HTTP_IF_NONE_MATCH" => %("stale"), "HTTP_IF_MODIFIED_SINCE" => last_modified)
    assert_equal 200, response[0]
  end

  def test_two_gems_do_not_share_a_download_validator
    app = plain_app
    one = get(app, "/gems/zip_kit-6.2.0.gem")[1]["ETag"]
    two = get(app, "/gems/zip_kit-6.2.1.gem")[1]["ETag"]

    refute_equal one, two
  end

  # A personalized gem is different bytes, so it must be a different tag -
  # otherwise a cache keyed on the URL hands one licensee's build to
  # another.
  def test_a_personalized_download_does_not_share_the_plain_validator
    plain = get(plain_app, "/gems/zip_kit-6.2.0.gem")[1]["ETag"]
    personalized = get(personalized_app(key: "one"), "/gems/zip_kit-6.2.0.gem")[1]["ETag"]

    refute_equal plain, personalized
  end

  # ------------------------------------------------------------------
  # Range requests
  # ------------------------------------------------------------------

  def test_a_range_request_returns_the_right_bytes_and_content_range
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=0-99")
    assert_equal 206, response[0]
    assert_equal "bytes 0-99/#{whole.bytesize}", response[1]["Content-Range"]
    assert_equal "100", response[1]["Content-Length"]
    assert_equal whole[0, 100], body_of(response)
  end

  def test_a_range_from_the_middle_and_a_suffix_range
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))
    size = whole.bytesize

    middle = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=1000-1099")
    assert_equal 206, middle[0]
    assert_equal whole[1000, 100], body_of(middle)

    suffix = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=-16")
    assert_equal 206, suffix[0]
    assert_equal "bytes #{size - 16}-#{size - 1}/#{size}", suffix[1]["Content-Range"]
    assert_equal whole[size - 16, 16], body_of(suffix)

    open_ended = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=#{size - 4}-")
    assert_equal 206, open_ended[0]
    assert_equal whole[size - 4, 4], body_of(open_ended)
  end

  # A range that happens to cover the whole entity is still a range, and
  # RFC 9110 lets the server answer it with a 206 - which is what Rack does.
  # The bytes are what matter either way.
  def test_a_range_spanning_the_entire_file_returns_every_byte
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=0-#{whole.bytesize - 1}")
    assert_equal 206, response[0]
    assert_equal whole, body_of(response)
  end

  def test_an_unsatisfiable_range_is_416_with_the_entity_size
    app = plain_app
    size = body_of(get(app, "/gems/zip_kit-6.2.0.gem")).bytesize

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=#{size + 1000}-#{size + 2000}")
    assert_equal 416, response[0]
    assert_equal "bytes */#{size}", response[1]["Content-Range"]
  end

  # An unparseable Range is not an unsatisfiable one - the header is
  # ignored and the whole entity is served, which is what RFC 9110 says to
  # do.
  def test_a_garbled_range_header_serves_the_whole_entity
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "cubits=0-9")
    assert_equal 200, response[0]
    assert_equal whole, body_of(response)
  end

  def test_several_ranges_at_once_come_back_as_a_multipart_response
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=0-9,100-109")
    assert_equal 206, response[0]
    # "byteranges", no hyphen, as RFC 9110 spells it.
    assert response[1]["Content-Type"].start_with?("multipart/byteranges;"),
      "expected a multipart response, got #{response[1]["Content-Type"].inspect}"

    body = body_of(response)
    assert_equal response[1]["Content-Length"].to_i, body.bytesize,
      "the announced length must include the part envelopes"
    assert_includes body, whole[0, 10]
    assert_includes body, whole[100, 10]
  end

  # A client resuming a download whose bytes have since changed must get the
  # whole thing rather than a splice of two different gems.
  def test_if_range_with_a_stale_tag_serves_the_whole_entity
    app = plain_app
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem",
      "HTTP_RANGE" => "bytes=0-9", "HTTP_IF_RANGE" => %("stale"))
    assert_equal 200, response[0]
    assert_equal whole, body_of(response)
  end

  def test_if_range_with_the_current_tag_serves_the_range
    app = plain_app
    etag = get(app, "/gems/zip_kit-6.2.0.gem")[1]["ETag"]

    response = get(app, "/gems/zip_kit-6.2.0.gem",
      "HTTP_RANGE" => "bytes=0-9", "HTTP_IF_RANGE" => etag)
    assert_equal 206, response[0]
  end

  def test_a_range_over_a_gated_gem_is_still_refused
    app = gated_app(gate_key: "alice") { |**| false }
    assert_equal 404, get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=0-9")[0]
  end

  def test_a_range_over_a_personalized_gem_reads_the_personalized_bytes
    app = personalized_app(key: "one")
    whole = body_of(get(app, "/gems/zip_kit-6.2.0.gem"))

    response = get(app, "/gems/zip_kit-6.2.0.gem", "HTTP_RANGE" => "bytes=0-63")
    assert_equal 206, response[0]
    assert_equal whole[0, 64], body_of(response)
  end

  # ------------------------------------------------------------------
  # The repository protocol itself
  # ------------------------------------------------------------------

  def test_a_repository_that_never_heard_of_the_protocol_fails_closed
    stand_in = Class.new do
      def gem_names = []

      def gem_versions = []

      def compact_info(_name) = []

      def gem_exists?(_name, _version) = false
    end.new

    app = Paquette::GemServer.new(stand_in)
    response = get(app, "/versions")

    assert_equal 200, response[0]
    assert_nil response[1]["ETag"], "an unknown repository must not be given a validator"
    assert_includes response[1]["Cache-Control"], "private"
  end

  def test_gem_checksum_agrees_with_what_the_compact_index_publishes
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    checksum = repository.gem_checksum("zip_kit", "6.2.0")

    assert_equal Digest::SHA256.file(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.0.gem")).hexdigest,
      checksum
    assert_includes repository.compact_info("zip_kit").join("\n"), "checksum:#{checksum}"
  end

  def test_gem_checksum_is_gated_and_personalized_by_the_wrappers
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    plain = repository.gem_checksum("zip_kit", "6.2.0")

    gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: "k") { |**| false }
    assert_nil gated.gem_checksum("zip_kit", "6.2.0")

    personalized = Paquette::GemServer::Personalizer.new(repository,
      license_key: "L", personalization_key: "one", cache_dir: tmp_cache_dir)
    refute_equal plain, personalized.gem_checksum("zip_kit", "6.2.0")
  end

  private

  CALLERS = {
    "anonymous" => {},
    "bearer" => {"HTTP_AUTHORIZATION" => "Bearer publisher"},
    "cookie" => {"HTTP_COOKIE" => "session=abc"}
  }

  def each_caller(&block)
    CALLERS.each(&block)
  end

  # The third value says whether the stack is open: nothing in it varies by
  # caller and the server was not told to keep out of shared caches.
  def each_stack
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    [
      ["plain", plain_app, true],
      ["plain, shared_caching: false", Paquette::GemServer.new(repository, shared_caching: false), false],
      ["gated with a key", gated_app(gate_key: "alice") { |**| true }, false],
      ["gated without a key", gated_app(gate_key: nil) { |**| true }, false],
      ["personalized", personalized_app(key: "one"), false],
      ["gated and personalized", gated_and_personalized_app, false]
    ].each { |description, app, open| yield description, app, open }
  end

  # Every kind of response the gem server hands out, 304s included - by
  # tag where the stack emits one, and by date on the download, which a
  # keyless gate still answers.
  def each_response(app, request_env = {})
    ["/versions", "/names", "/info/zip_kit", "/gems/zip_kit-6.2.0.gem",
      "/specs.4.8.gz", "/quick/Marshal.4.8/zip_kit-6.2.0.gemspec.rz", "/api/v1/versions",
      "/gems/nothing-1.0.0.gem", "/"].each do |path|
      response = get(app, path, request_env)
      yield path, response

      if (etag = response[1]["ETag"])
        not_modified = get(app, path, request_env.merge("HTTP_IF_NONE_MATCH" => etag))
        assert_equal 304, not_modified[0], path
        yield "#{path} (If-None-Match)", not_modified
      end

      if (last_modified = response[1]["Last-Modified"])
        not_modified = get(app, path, request_env.merge("HTTP_IF_MODIFIED_SINCE" => last_modified))
        assert_equal 304, not_modified[0], path
        yield "#{path} (If-Modified-Since)", not_modified
      end
    end
  end

  def assert_directives(control, headers, message)
    assert_equal control, headers["Cache-Control"], message
    assert_includes vary_fields(headers), "Authorization", message
  end

  def vary_fields(headers)
    headers["Vary"].to_s.split(",").map(&:strip)
  end

  def plain_app
    Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR))
  end

  def gated_app(gate_key:, &entitler)
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    Paquette::GemServer.new(
      Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: gate_key, &entitler)
    )
  end

  def personalized_app(key:)
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    personalized = Paquette::GemServer::Personalizer.new(repository,
      license_key: "LICENSE-#{key}", personalization_key: key, cache_dir: tmp_cache_dir)

    Paquette::GemServer.new(personalized)
  end

  def gated_and_personalized_app
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: "alice") { |**| true }
    personalized = Paquette::GemServer::Personalizer.new(gated,
      license_key: "L", personalization_key: "alice", cache_dir: tmp_cache_dir)

    Paquette::GemServer.new(personalized)
  end

  # One per licensee, so the personalizer's own cache cannot be what makes
  # two stacks look alike.
  def tmp_cache_dir
    dir = Dir.mktmpdir("paquette_caching_test")
    @cache_dirs << dir
    dir
  end

  def env_for(path, env = {})
    Rack::MockRequest.env_for(path, env)
  end

  def get(app, path, env = {})
    app.call(env_for(path, env))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end
end
