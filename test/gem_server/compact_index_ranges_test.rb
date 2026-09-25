require_relative "../test_helper"
require "digest"

# Ranged fetching of the compact index.
#
# Bundler >= 2.5 does not re-download /versions and /info/NAME when it
# already holds a copy: it asks for the tail with `Range: bytes=N-`, appends
# what comes back to the copy it has, and verifies the result against the
# `Repr-Digest` header - which carries the digest of the *whole*
# representation even on a 206. Without that header it refuses to append and
# fetches the whole document again.
#
# Two things are tested here. One is that the reassembly a client performs
# actually produces the bytes the digest advertises. The other is that the
# `Range` header, which is client-chosen and arbitrary, is parsed without
# anything expensive and answers garbage with a plain 200 rather than an
# error - RFC 9110 lets a server ignore Range, and a 416 handed to a client
# that merely guessed an offset wrong would break an install that would
# otherwise have worked.
class CompactIndexRangesTest < Minitest::Test
  RANGED_PATHS = ["/versions", "/names", "/info/zip_kit"]

  # ------------------------------------------------------------------
  # What a full response advertises
  # ------------------------------------------------------------------

  def test_every_compact_index_response_advertises_ranges_and_its_digest
    app = plain_app

    RANGED_PATHS.each do |path|
      response = get(app, path)
      body = body_of(response)
      digest = Digest::SHA256.base64digest(body)

      assert_equal 200, response[0], path
      assert_equal "bytes", response[1]["Accept-Ranges"], path
      assert_equal "sha-256=:#{digest}:", response[1]["Repr-Digest"], path
      assert_equal "sha-256=#{digest}", response[1]["Digest"], path
    end
  end

  # The digest describes the representation, not the response body, which is
  # the whole point of it on a 206: the client compares it against what it
  # has after appending.
  def test_a_partial_response_carries_the_digest_of_the_whole_document
    app = plain_app
    full = body_of(get(app, "/versions"))

    partial = get(app, "/versions", "HTTP_RANGE" => "bytes=10-")

    assert_equal 206, partial[0]
    refute_equal full, body_of(partial), "a 206 is not the whole document"
    assert_equal "sha-256=:#{Digest::SHA256.base64digest(full)}:", partial[1]["Repr-Digest"]
    assert_equal "bytes 10-#{full.bytesize - 1}/#{full.bytesize}", partial[1]["Content-Range"]
  end

  # ------------------------------------------------------------------
  # Reassembly, the way Bundler does it
  # ------------------------------------------------------------------

  # Bundler asks from one byte *before* the end of the copy it holds, so it
  # can check that the byte it gets back is the byte it already has before
  # appending the rest. This walks that exact protocol and verifies the
  # result against the advertised digest, for every endpoint that serves
  # ranges.
  def test_a_tail_append_reconstructs_the_document_and_matches_the_digest
    app = plain_app

    RANGED_PATHS.each do |path|
      full = body_of(get(app, path))
      held = full.byteslice(0, full.bytesize - 1)

      tail = get(app, path, "HTTP_RANGE" => "bytes=#{held.bytesize - 1}-")
      assert_equal 206, tail[0], path

      overlap = body_of(tail)
      assert_equal held.byteslice(held.bytesize - 1, 1), overlap.byteslice(0, 1),
        "#{path}: the overlapping byte is what tells the client the prefix is still good"

      reassembled = held.byteslice(0, held.bytesize - 1) + overlap
      assert_equal full, reassembled, path
      assert_equal "sha-256=:#{Digest::SHA256.base64digest(reassembled)}:", tail[1]["Repr-Digest"], path
    end
  end

  # The header is what used to make this impossible: with `created_at:`
  # stamped from the clock, every render moved the first line and therefore
  # every byte offset in the document. It is now the oldest publication time
  # in the corpus, so a push leaves the prefix alone and only the rows from
  # the changed one onward move.
  def test_a_push_leaves_the_prefix_of_the_document_untouched
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "zip_kit"))
      FileUtils.cp(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.0.gem"), File.join(dir, "zip_kit"))
      repository = Paquette::GemServer::DirectoryGemRepository.new(dir)
      app = Paquette::GemServer.new(repository)

      before = body_of(get(app, "/versions"))

      # Pushed later than the oldest gem already there, which is the case
      # that matters: the corpus grows and `created_at:` does not move.
      repository.add_gem(File.binread(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.1.gem")))
      after = body_of(get(app, "/versions"))

      refute_equal before, after, "a push must change the document"
      assert_equal before.lines.first, after.lines.first, "created_at must survive a push"
      assert_equal "---", after.lines[1].chomp
    end
  end

  # ------------------------------------------------------------------
  # Ranges that are satisfiable
  # ------------------------------------------------------------------

  def test_the_three_range_forms
    app = plain_app
    full = body_of(get(app, "/versions"))
    size = full.bytesize

    {
      "bytes=0-0" => [0, 0],
      "bytes=0-9" => [0, 9],
      "bytes=#{size - 1}-" => [size - 1, size - 1],
      "bytes=-5" => [size - 5, size - 1],
      # More than there is, from both ends: clamped rather than refused.
      "bytes=0-#{size + 1000}" => [0, size - 1],
      "bytes=-#{size + 1000}" => [0, size - 1]
    }.each do |header, (first, last)|
      response = get(app, "/versions", "HTTP_RANGE" => header)

      assert_equal 206, response[0], header
      assert_equal "bytes #{first}-#{last}/#{size}", response[1]["Content-Range"], header
      assert_equal full.byteslice(first..last), body_of(response), header
    end
  end

  # Surrounding whitespace is stripped, which is how a field value is read
  # everywhere else. Whitespace *inside* the range is not - it is not a
  # number, so the header is ignored (see below).
  def test_whitespace_around_the_header_is_tolerated
    app = plain_app
    ["  bytes=0-0  ", "bytes=0-0\n", "\tbytes=0-0"].each do |header|
      assert_equal 206, get(app, "/versions", "HTTP_RANGE" => header)[0], header.inspect
    end
  end

  # ------------------------------------------------------------------
  # Ranges that are not, and outright garbage
  # ------------------------------------------------------------------

  # Every one of these is answered with the whole document. None of them is
  # a 416 and none of them raises: a Range this server will not serve is a
  # Range it ignores.
  def test_a_range_it_will_not_serve_is_ignored_rather_than_refused
    app = plain_app
    full = body_of(get(app, "/versions"))

    [
      "bytes=-",
      "bytes=",
      "bytes",
      "",
      "bytes=1-2, 5-6",
      "bytes=0-1,4-5",
      "bytes=99999999999999999999-",
      "bytes=-99999999999999999999",
      "bytes=#{full.bytesize}-",
      "bytes=#{full.bytesize + 10}-",
      "bytes=5-2",
      "bytes=-0",
      "items=0-1",
      "bytes=abc-def",
      "bytes=1.5-2",
      "bytes= 0-1",
      "bytes=+0-1",
      "bytes=0x10-",
      "bytes=\n0-1",
      "chars=0-1",
      "bytes=0-1; x=y",
      # Longer than any single byte range can be, so it is not one.
      "bytes=#{"0" * 200}-",
      "bytes=" + (["0-1"] * 100).join(",")
    ].each do |header|
      response = get(app, "/versions", "HTTP_RANGE" => header)

      assert_equal 200, response[0], header.inspect
      assert_equal full, body_of(response), header.inspect
      assert_nil response[1]["Content-Range"], header.inspect
      assert_equal "bytes", response[1]["Accept-Ranges"], header.inspect
    end
  end

  # An empty corpus still owes /names the format's "---" marker and the
  # empty line after it, so the shortest document this server can serve is
  # five bytes rather than none. A range past the end of it is unsatisfiable
  # and is still answered 200 with the whole document rather than a 416.
  def test_ranges_over_the_shortest_document_this_server_serves
    Dir.mktmpdir do |dir|
      app = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(dir))
      marker = "---\n\n"
      assert_equal 5, marker.bytesize, "three dashes and two newlines"
      assert_equal marker, body_of(get(app, "/names")), "an empty corpus still names the format"

      satisfiable = get(app, "/names", "HTTP_RANGE" => "bytes=1-")
      assert_equal 206, satisfiable[0]
      assert_equal marker.byteslice(1..), body_of(satisfiable)

      ["bytes=99-", "bytes=-0", "bytes=5-"].each do |header|
        response = get(app, "/names", "HTTP_RANGE" => header)
        assert_equal 200, response[0], header
        assert_equal marker, body_of(response), header
        assert_nil response[1]["Content-Range"], header
      end
    end
  end

  # The header is client-chosen and unbounded in length, and the only
  # pattern it meets runs over a run of digits that has already been split
  # out and length-capped. Nothing here should take measurable time.
  def test_pathological_range_headers_are_answered_promptly
    app = plain_app

    headers = [
      "bytes=" + ("9" * 100_000) + "-",
      "bytes=" + ("-" * 100_000),
      "bytes=" + ("0-1," * 50_000),
      "bytes=" + ("9" * 50_000) + "-" + ("9" * 50_000),
      ("bytes=" * 50_000) + "0-1",
      "b" * 1_000_000
    ]

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    headers.each do |header|
      assert_equal 200, get(app, "/versions", "HTTP_RANGE" => header)[0], "#{header[0, 20]}..."
    end
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert took < 5.0, "answering pathological Range headers took #{took}s"
  end

  # (Regexp.linear_time? on BYTE_OFFSET is asserted in
  # test/regexp_linearity_test.rb, which walks every pattern a request can
  # reach.)

  # ------------------------------------------------------------------
  # Where Range sits among the other conditionals
  # ------------------------------------------------------------------

  # The conditional check comes first, which is what keeps a 304 from ever
  # costing a render. A client that holds the current document and asks for
  # a range of it is told it already has it.
  def test_a_matching_if_none_match_beats_a_range
    app = plain_app
    etag = get(app, "/versions")[1]["ETag"]

    response = get(app, "/versions", "HTTP_IF_NONE_MATCH" => etag, "HTTP_RANGE" => "bytes=0-0")

    assert_equal 304, response[0]
    assert_equal "", body_of(response)
    assert_nil response[1]["Content-Range"]
  end

  def test_a_stale_if_none_match_with_a_range_gets_the_range
    app = plain_app
    response = get(app, "/versions", "HTTP_IF_NONE_MATCH" => %("stale"), "HTTP_RANGE" => "bytes=0-0")

    assert_equal 206, response[0]
  end

  # If-Range asks for the range only if the document is still the one the
  # client holds. Anything that does not strongly match gets the whole
  # document, which is always a correct answer to a range request.
  def test_if_range_is_honoured
    app = plain_app
    etag = get(app, "/versions")[1]["ETag"]

    assert_equal 206, get(app, "/versions", "HTTP_RANGE" => "bytes=0-0", "HTTP_IF_RANGE" => etag)[0]

    [%("elsewhere"), "W/#{etag}", Time.now.httpdate, "nonsense"].each do |if_range|
      response = get(app, "/versions", "HTTP_RANGE" => "bytes=0-0", "HTTP_IF_RANGE" => if_range)
      assert_equal 200, response[0], if_range
    end
  end

  # ------------------------------------------------------------------
  # Under the gating model
  # ------------------------------------------------------------------

  # A gate built without a gate_key refuses to name itself, so no ETag is
  # emitted - that must not change here. The digest and the ranges still
  # work: they describe the bytes this caller is being served, and nothing
  # about them is stored or shared by anyone.
  def test_a_stack_that_cannot_name_itself_still_ranges_and_still_emits_no_etag
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: nil) { |**| true }
    app = Paquette::GemServer.new(gated)

    full = get(app, "/versions")
    assert_nil full[1]["ETag"], "a keyless gate must still emit no validator"
    assert_equal "sha-256=:#{Digest::SHA256.base64digest(body_of(full))}:", full[1]["Repr-Digest"]

    partial = get(app, "/versions", "HTTP_RANGE" => "bytes=0-0")
    assert_equal 206, partial[0]
    assert_nil partial[1]["ETag"]

    # And with no tag to compare against, If-Range can only mean "send it
    # all".
    assert_equal 200, get(app, "/versions", "HTTP_RANGE" => "bytes=0-0", "HTTP_IF_RANGE" => %("x"))[0]
  end

  # A gate hides gems from the index, and a range is a range of the document
  # this caller was going to be served - not of the ungated one.
  def test_a_range_is_taken_out_of_the_gated_document
    repository = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    gated = Paquette::GemServer::ReadGatedRepository.new(repository, gate_key: "alice") do |name:, version: nil|
      name == "minuscule_test"
    end
    app = Paquette::GemServer.new(gated)

    full = body_of(get(app, "/versions"))
    refute_includes full, "zip_kit"

    partial = get(app, "/versions", "HTTP_RANGE" => "bytes=0-")
    assert_equal 206, partial[0]
    assert_equal full, body_of(partial)
    assert_equal "sha-256=:#{Digest::SHA256.base64digest(full)}:", partial[1]["Repr-Digest"]
  end

  private

  def plain_app
    Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR))
  end

  def get(app, path, env = {})
    app.call(Rack::MockRequest.env_for(path, env))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end
end
