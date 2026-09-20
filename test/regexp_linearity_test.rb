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

  # Includes the ones assembled per call out of a name, built here with the most
  # regexp-ish name Regexp.escape has to deal with.
  def test_every_pattern_a_request_can_reach_is_linear_time
    awkward = "a.-_b"

    patterns = {
      "GemServer::GEM_SPEC_NAME" => Paquette::GemServer::GEM_SPEC_NAME,
      "GemServer::GEM_FILENAME" => Paquette::GemServer::GEM_FILENAME,
      "NpmServer::SCOPED_PATH" => Paquette::NpmServer::SCOPED_PATH,
      "NpmRepository::SEGMENT" => Paquette::NpmServer::NpmRepository::SEGMENT,
      "versions_for_gem" => /\A#{Regexp.escape(awkward)}-(\d+\.\d+\.\d+#{Paquette::GemServer::NAME_CHAR}{0,255})\z/,
      "readme" => /\AREADME(\.md|\.markdown|\.txt)?\z/i,
      "subdomain" => /\A([a-z\-\d]+)\./,
      "numeric identifier" => /\A\d+\z/,
      "repacker marker" => /[\r\n]/
    }

    patterns.each do |name, regexp|
      assert Regexp.linear_time?(regexp), "#{name} can backtrack: #{regexp.inspect}"
    end
  end

  # The bounds are the easy part to drop by accident.
  def test_gem_name_patterns_refuse_an_absurdly_long_segment
    filename = ("a" * 600) + "-1.2.3.gem"

    assert_nil Paquette::GemServer::GEM_FILENAME.match(filename)
    assert Paquette::GemServer::GEM_FILENAME.match("zip_kit-6.2.0.gem")
  end

  def test_gem_name_patterns_are_anchored_against_an_injected_newline
    assert_nil Paquette::GemServer::GEM_FILENAME.match("zip_kit-6.2.0.gem\n/etc/passwd")
    assert_nil Paquette::GemServer::GEM_SPEC_NAME.match("zip_kit-6.2.0\nanything")
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
