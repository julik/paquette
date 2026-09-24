require_relative "test_helper"

# Pathological and randomly generated path segments against both servers, as
# AGENTS.md asks for. Nothing here checks that the right answer comes back —
# these paths have no right answer. It checks that every one of them is
# answered at all, promptly, and with a status rather than a stack trace.
class RegexpFuzzTest < Minitest::Test
  # Deterministic so a failure reproduces; set PAQUETTE_FUZZ_SEED to replay one.
  SEED = Integer(ENV.fetch("PAQUETTE_FUZZ_SEED", 20_260_920))

  # Generous by three orders of magnitude next to a real match, and still far
  # below anything that would hold a worker thread.
  SLOWEST_ACCEPTABLE = 1.0

  # The characters these patterns actually pivot on, plus the escapes that
  # Mustermann turns back into them.
  ALPHABET = ["-", ".", "_", "/", "@", "%", "a", "z", "0", "9", "%2F", "%0A", "%40", "~", "!", "+"].freeze

  # Each is a shape built to make a splitting pattern work: runs of the
  # delimiter, near-misses that match to the last character, and repetition of
  # whatever the pattern repeats.
  def pathological_segments(size)
    [
      "-" * size,
      "." * size,
      "a" * size,
      "a-" * size,
      "1-" * size,
      "1." * size,
      ("1.1.1-" * size),
      ("a-" * size) + "1.1.1",
      ("a-" * size) + "1.1.1!",
      ("a-" * size) + "1.1.1.gem",
      ("1.1.1-" * size) + "!",
      ("@" * size),
      ("@a/" * size),
      ("%2F" * size),
      ("%0A" * size),
      ("a" * size) + ".gem",
      ("0" * size) + ".0.0.gem",
      "zip_kit-" + ("6." * size) + "0.gem",
      # The version column is RubyGems' own grammar, which ends in an
      # unbounded run over [0-9A-Za-z-] — so the shapes that stretch it are
      # the platform suffix and the dot-separated groups inside it, each run
      # right up to a last character that cannot match.
      "zip_kit-6.2.0" + ("-a" * size) + ".gem",
      "zip_kit-6.2.0-" + ("a." * size) + "0.gem",
      "zip_kit-6.2.0" + ("-" * size) + ".gem",
      "zip_kit-" + ("1-" * size) + "1.gem",
      "zip_kit-6.2.0" + ("-a" * size) + "!.gem",
      ("a-" * size) + "0.2.gem",
      ("a." * size) + "-0.2.gem"
    ]
  end

  TEMPLATES = [
    "/%s",
    "/gems/%s",
    "/info/%s",
    "/quick/Marshal.4.8/%s.gemspec.rz",
    "/quick/Marshal.4.8/%s",
    "/%s/-/%s",
    "/%s/%s",
    "/-/package/%s/dist-tags",
    "/-/package/%s/dist-tags/%s",
    "/%s/-rev/%s",
    "/api/v1/search.json?query=%s"
  ].freeze

  def setup
    @gems = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    @npm = Paquette::NpmServer::DirectoryNpmRepository.new(FIXTURE_NPM_DIR)
  end

  def test_pathological_segments_are_answered_promptly_by_the_gem_server
    assert_survives(gem_server, pathological_paths)
  end

  def test_pathological_segments_are_answered_promptly_by_the_npm_server
    assert_survives(npm_server, pathological_paths)
  end

  def test_random_segments_are_answered_promptly_by_the_gem_server
    assert_survives(gem_server, random_paths(400))
  end

  def test_random_segments_are_answered_promptly_by_the_npm_server
    assert_survives(npm_server, random_paths(400))
  end

  # The one segment shape that used to be served a 200 it had no business
  # getting: ^..$ matched the first line and let the rest ride along.
  def test_a_newline_never_reaches_a_handler_as_a_valid_name
    app = gem_server

    assert_equal 404, status_of(app, "/gems/zip_kit-6.2.0.gem%0Ajunk")
    assert_equal 404, status_of(app, "/quick/Marshal.4.8/zip_kit-6.2.0%0Ajunk.gemspec.rz")
    assert_equal 200, status_of(app, "/gems/zip_kit-6.2.0.gem")
  end

  # Straight at the splitter rather than through a route, because it is also
  # reached by callers holding a filename off disk. Nothing here is a valid
  # name-version pair; the point is that each is refused outright rather than
  # half-matched, and refused promptly.
  def test_the_gem_filename_splitter_refuses_pathological_segments_promptly
    segments = [1, 8, 64, 512, 4096].flat_map { |size| pathological_segments(size) }

    segments.each do |segment|
      split = nil
      ran_for = elapsed do
        split = Paquette::GemServer.split_gem_filename(segment)
      end

      assert_operator ran_for, :<, SLOWEST_ACCEPTABLE, "#{segment[0, 120].inspect} took #{ran_for}s"
      next if split.nil?

      # A match is allowed, but only a whole one: no half-split that leaves
      # part of a client-chosen segment riding along unexamined.
      name, version = split
      assert_equal segment, "#{name}-#{version}#{Paquette::GemServer::GEM_FILE_EXTENSION}",
        "#{segment[0, 120].inspect} split into pieces that do not add back up"
    end
  end

  # Bytes that are not valid UTF-8 make a regexp raise rather than fail to
  # match, and these arrive from a percent-decoded segment and from tar entry
  # names, neither of which came through a route's own encoding check.
  def test_the_gem_filename_splitter_survives_bytes_that_are_not_utf8
    [
      "%E2",
      "\xE2".b,
      "\xFF".b,
      "zip_kit-6.2.0\xFF.gem".b,
      "zip\xFF_kit-6.2.0.gem".b,
      ("\xFF" * 4096).b,
      ("\xE2" * 4096) + "-6.2.0.gem"
    ].each do |bytes|
      assert_nil Paquette::GemServer.split_gem_filename(bytes), bytes[0, 40].inspect
      assert_nil Paquette::GemServer.split_gem_spec_name(bytes), bytes[0, 40].inspect
    end
  end

  # The same bytes as a path segment, all the way through the server.
  def test_bytes_that_are_not_utf8_in_a_path_are_answered_rather_than_raised
    app = gem_server

    ["/gems/%E2-1.0.0.gem", "/gems/zip_kit-6.2.0%FF.gem", "/info/%E2", "/quick/Marshal.4.8/%FF.gemspec.rz"].each do |path|
      assert_includes 200..499, status_of(app, path), path
    end
  end

  # A segment long enough to be quadratic is refused on its length, which is
  # what the bounded quantifiers are for.
  def test_an_absurdly_long_name_is_refused_rather_than_walked
    app = gem_server
    status = nil
    ran_for = elapsed { status = status_of(app, "/gems/#{"a" * 100_000}-1.2.3.gem") }

    assert_equal 404, status
    assert_operator ran_for, :<, SLOWEST_ACCEPTABLE, "took #{ran_for}s"
  end

  private

  def pathological_paths
    [1, 8, 64, 512, 4096].flat_map { |size| paths_from(pathological_segments(size)) }
  end

  def random_paths(count)
    random = Random.new(SEED)
    segments = Array.new(count) do
      Array.new(random.rand(1..60)) { ALPHABET.sample(random: random) }.join
    end
    paths_from(segments)
  end

  def paths_from(segments)
    segments.flat_map do |segment|
      TEMPLATES.map { |template| template.gsub("%s", segment) }
    end
  end

  def assert_survives(app, paths)
    paths.each do |path|
      status = nil
      ran_for = elapsed { status = status_of(app, path) }

      assert_includes 200..499, status, "#{path[0, 120].inspect} answered #{status}"
      assert_operator ran_for, :<, SLOWEST_ACCEPTABLE, "#{path[0, 120].inspect} took #{ran_for}s"
    end
  end

  # Rack::Test runs the path through URI.parse first, which refuses half of
  # what this test is for. PATH_INFO comes off the wire unvalidated, so it is
  # set the way a server would set it.
  def status_of(app, path)
    path_info, _, query = path.partition("?")
    env = Rack::MockRequest.env_for("/", "QUERY_STRING" => query)
    env["PATH_INFO"] = path_info

    status, _headers, body = app.call(env)
    status
  ensure
    # Closing is what releases the ceiling; leaking it would quietly disarm
    # every later case.
    body&.close if body.respond_to?(:close)
  end

  def gem_server
    Paquette::GemServer.new(@gems)
  end

  def npm_server
    Paquette::NpmServer.new(@npm)
  end
end
