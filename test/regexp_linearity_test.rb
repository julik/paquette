require_relative "test_helper"

# Regexp.linear_time? says whether 3.2 can memoize a pattern's backtracking away.
# A no means the client picks the running time. This test fails when someone adds
# one. It does not replace Paquette::RegexpTimeout, which is the ceiling for 3.1
# and for the day the property stops holding.
class RegexpLinearityTest < Minitest::Test
  def setup
    skip "Regexp.linear_time? arrived in Ruby 3.2" unless Regexp.respond_to?(:linear_time?)
  end

  def test_every_route_pattern_is_linear_time
    route_patterns.each do |metric_name, regexp|
      assert Regexp.linear_time?(regexp), "route #{metric_name} compiles to a pattern that can backtrack: #{regexp.inspect}"
    end
  end

  def test_the_route_table_is_not_silently_empty
    refute_empty route_patterns
  end

  def test_every_pattern_a_request_can_reach_is_linear_time
    patterns = {
      "GemServer::GEM_SPEC_NAME" => Paquette::GemServer::GEM_SPEC_NAME,
      "NpmServer::SCOPED_PATH" => Paquette::NpmServer::SCOPED_PATH,
      "NpmRepository::SEGMENT" => Paquette::NpmServer::NpmRepository::SEGMENT,
      "readme" => /\AREADME(\.md|\.markdown|\.txt)?\z/i,
      "subdomain" => /\A([a-z\-\d]+)\./,
      "numeric identifier" => /\A\d+\z/,
      "repacker marker" => /[\r\n]/,
      # Runs over a compact info line once per version per personalized
      # /info/ request, and the line now carries a "rubygems:" field after
      # the one it is looking for.
      "GemRepository.replace_checksum" => /checksum:[0-9a-f]+/
    }

    patterns.each do |name, regexp|
      assert Regexp.linear_time?(regexp), "#{name} can backtrack: #{regexp.inspect}"
    end
  end

  # GEM_SPEC_NAME borrows its version column from Gem::Version rather than
  # spelling out a guess at one, so the property has to be asserted about the
  # borrowed pattern too — an upstream release could put a backreference in it
  # and this is what would notice.
  def test_the_borrowed_rubygems_version_pattern_is_linear_time
    borrowed = Regexp.new("\\A(#{Gem::Version::VERSION_PATTERN})\\z")
    column = Regexp.new("\\A(#{Paquette::GemServer::VERSION_COLUMN})\\z")

    assert Regexp.linear_time?(borrowed),
      "Gem::Version::VERSION_PATTERN can backtrack: #{Gem::Version::VERSION_PATTERN.inspect}"
    assert Regexp.linear_time?(column), "VERSION_COLUMN can backtrack: #{column.inspect}"
  end

  # There is exactly one pattern now. A second one built per call out of a
  # caller-chosen name is what versions_for_gem used to do, and the whole
  # reason a gem at "0.2" was invisible: two patterns, two opinions.
  def test_the_repository_does_not_build_a_pattern_of_its_own
    source = File.read(File.expand_path("../lib/paquette/gem_server/directory_gem_repository.rb", __dir__))

    refute_match(/Regexp\.escape/, source)
    refute_match(/Regexp\.new/, source)
  end

  # The bounds are the easy part to drop by accident.
  def test_gem_name_patterns_refuse_an_absurdly_long_segment
    assert_nil Paquette::GemServer.split_gem_filename(("a" * 600) + "-1.2.3.gem")
    assert_equal ["zip_kit", "6.2.0"], Paquette::GemServer.split_gem_filename("zip_kit-6.2.0.gem")
  end

  # The borrowed half of the pattern has no bound of its own: RubyGems' own
  # version grammar ends in an unbounded run, so a client could stretch the
  # platform suffix past the version as far as it liked. The length check in
  # front of the match is what stops that, and this is the test that notices
  # if it goes away.
  def test_the_version_column_refuses_an_absurdly_long_platform_suffix
    assert_nil Paquette::GemServer.split_gem_filename("zip_kit-6.2.0-" + ("a" * 600) + ".gem")
    assert_equal ["zip_kit", "6.2.0-arm64-darwin"],
      Paquette::GemServer.split_gem_filename("zip_kit-6.2.0-arm64-darwin.gem")
  end

  # Either side of the ceiling, so the bound is a real edge and not a
  # coincidence of some other refusal further along.
  def test_the_length_ceiling_is_where_it_says_it_is
    max = Paquette::GemServer::MAX_GEM_SPEC_NAME_BYTES
    name = "a" * 255
    # The unbounded half of the pattern, stretched right up to the ceiling:
    # a version and then a platform suffix as long as the budget allows.
    prefix = "#{name}-6.2.0-"
    column = "6.2.0-" + ("a" * (max - prefix.bytesize))
    assert_equal max, "#{name}-#{column}".bytesize

    assert_equal [name, column], Paquette::GemServer.split_gem_spec_name("#{name}-#{column}")
    assert_nil Paquette::GemServer.split_gem_spec_name("#{name}-#{column}a")
  end

  # The ceiling is counted in bytes, so a segment of multi-byte characters
  # cannot buy itself more of them than an ASCII one gets.
  def test_the_length_ceiling_counts_bytes_not_characters
    max = Paquette::GemServer::MAX_GEM_SPEC_NAME_BYTES

    assert_nil Paquette::GemServer.split_gem_spec_name(("é" * max) + "-6.2.0")
  end

  def test_gem_name_patterns_are_anchored_against_an_injected_newline
    assert_nil Paquette::GemServer.split_gem_filename("zip_kit-6.2.0.gem\n/etc/passwd")
    assert_nil Paquette::GemServer.split_gem_spec_name("zip_kit-6.2.0\nanything")
    assert_nil Paquette::GemServer.split_gem_spec_name("\nzip_kit-6.2.0")
    assert_nil Paquette::GemServer::GEM_SPEC_NAME.match("zip_kit-6.2.0\nanything")
  end

  # The shapes the previous pattern threw away, none of which are exotic:
  # case_transform-0.2 and rails_twirp-0.17 are published gems.
  def test_versions_that_are_not_three_segments_still_split
    {
      "case_transform-0.2.gem" => ["case_transform", "0.2"],
      "rails_twirp-0.17.gem" => ["rails_twirp", "0.17"],
      "foo-1.0.pre.gem" => ["foo", "1.0.pre"],
      "foo-1.gem" => ["foo", "1"],
      "foo-1.2.3.4.gem" => ["foo", "1.2.3.4"],
      "nokogiri-1.16.0-arm64-darwin.gem" => ["nokogiri", "1.16.0-arm64-darwin"],
      "nokogiri-1.16.0-x86_64-linux.gem" => ["nokogiri", "1.16.0-x86_64-linux"],
      "net-http-0.4.1.gem" => ["net-http", "0.4.1"],
      "a-1-1.0.0.gem" => ["a-1", "1.0.0"]
    }.each do |filename, expected|
      assert_equal expected, Paquette::GemServer.split_gem_filename(filename), filename
    end
  end

  def test_things_that_are_not_a_name_version_pair_are_refused
    [
      "no-version-here.gem",
      "-1.2.3.gem",
      "1.2.3.gem",
      "foo-.gem",
      "foo-1.2.3",
      "foo-1.2.3.gem.gem.tomb",
      "foo-1.2.3.tomb",
      "",
      ".gem"
    ].each do |filename|
      assert_nil Paquette::GemServer.split_gem_filename(filename), filename.inspect
    end
  end

  # A percent-decoded segment arrives as bytes, and a regexp run over bytes
  # that are not valid UTF-8 raises rather than failing to match.
  def test_bytes_that_are_not_valid_utf8_come_back_nil_rather_than_raising
    [
      "zip\xFF_kit-1.0.0.gem".b,
      "\xFF".b,
      "\xE2".b,
      "zip_kit-1.0.0\xE2.gem".b,
      ("\xFF" * 600).b
    ].each do |bytes|
      assert_nil Paquette::GemServer.split_gem_filename(bytes), bytes.inspect
      assert_nil Paquette::GemServer.split_gem_spec_name(bytes), bytes.inspect
    end
  end

  private

  def route_patterns
    [Paquette::GemServer, Paquette::NpmServer].flat_map do |server|
      server.class_variable_get(:@@routes).routes.map do |route|
        [route.metric_name, route.pattern.to_regexp]
      end
    end
  end
end
