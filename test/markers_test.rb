require_relative "test_helper"

# The one mechanism every personalizer writes with, fed the strings a package
# author would write and the ones a hostile package would.
class MarkersTest < Minitest::Test
  VALUES = {"licensee" => "Acme BV", "customer" => "Customer C-1"}.freeze

  def test_a_marker_is_the_key_after_the_prefix_on_a_line_of_its_own
    assert_equal "licensee", Paquette::Markers.key_of("paquette:licensee")
    assert_equal "licensee", Paquette::Markers.key_of("  # paquette:licensee\n")
    assert_equal "licensee", Paquette::Markers.key_of("\t// paquette:licensee\r\n")
    assert_equal "a_1", Paquette::Markers.key_of("-- paquette:a_1")
    assert_equal "x", Paquette::Markers.key_of("; paquette:x")
    assert_equal "x", Paquette::Markers.key_of("% paquette:x")
    assert_equal "x", Paquette::Markers.key_of(" * paquette:x")
  end

  def test_a_line_that_is_more_than_a_marker_is_not_one
    assert_nil Paquette::Markers.key_of("code(); // paquette:licensee")
    assert_nil Paquette::Markers.key_of("# paquette:licensee and more")
    assert_nil Paquette::Markers.key_of("# Licensed to paquette:licensee")
    assert_nil Paquette::Markers.key_of("paquette:")
    assert_nil Paquette::Markers.key_of("paquette:Licensee")
    assert_nil Paquette::Markers.key_of("paquette:lic-ensee")
    assert_nil Paquette::Markers.key_of("<!-- paquette:x -->")
    assert_nil Paquette::Markers.key_of("")
    assert_nil Paquette::Markers.key_of("# paquette:#{"k" * 65}")
  end

  def test_substitute_keeps_indentation_leader_and_line_ending
    text = "  # frozen\n\t// paquette:licensee\r\n    paquette:customer\n# paquette:unknown\n"
    filled = Paquette::Markers.substitute(text, VALUES)

    assert_equal "  # frozen\n\t// Acme BV\r\n    Customer C-1\n# paquette:unknown\n", filled
  end

  def test_substitute_returns_the_very_same_object_when_nothing_changes
    text = "nothing here\n"
    assert_same text, Paquette::Markers.substitute(text, VALUES)
    assert_same text, Paquette::Markers.substitute(text, {})
  end

  def test_a_marker_for_a_supplied_key_that_is_not_alone_on_its_line_is_refused
    error = assert_raises(Paquette::Markers::NotApplied) do
      Paquette::Markers.substitute("function e(){}// paquette:licensee\n", VALUES, described_as: "index.js")
    end
    assert_includes error.message, "index.js"
  end

  def test_keys_in_lists_each_marker_once_in_order
    assert_equal ["licensee", "customer"], Paquette::Markers.keys_in("# paquette:licensee\n// paquette:customer\n# paquette:licensee\n")
  end

  # Loose on the way in, strict on the way out: the package is asking, and
  # substitute will refuse it rather than leave the hole
  def test_keys_in_sees_a_marker_that_is_not_alone_on_its_line
    assert_equal ["licensee"], Paquette::Markers.keys_in("function e(){}// paquette:licensee\n")
    assert_equal ["licensee"], Paquette::Markers.keys_in("see paquette:licensee, above\n")
    assert_equal [], Paquette::Markers.keys_in("paquette:Licensee\n")
    assert_equal [], Paquette::Markers.keys_in("paquette:\n")
  end

  def test_binaries_are_left_alone
    binary = "\x00\x01# paquette:licensee\n".b
    assert_same binary, Paquette::Markers.substitute(binary, VALUES)
    assert_equal [], Paquette::Markers.keys_in(binary)

    invalid = "\xFF# paquette:licensee\n".b
    assert_same invalid, Paquette::Markers.substitute(invalid, VALUES)
    assert_equal [], Paquette::Markers.keys_in(invalid)
  end

  def test_the_filled_text_keeps_the_encoding_it_came_in
    binary_read = "# paquette:licensee\n".b
    filled = Paquette::Markers.substitute(binary_read, VALUES)
    assert_equal Encoding::BINARY, filled.encoding
    assert_equal "# Acme BV\n", filled
  end

  def test_values_must_be_single_line_strings_under_valid_keys
    assert_raises(Paquette::Markers::MultilineValue) { Paquette::Markers.check_values!({"k" => "a\nb"}) }
    assert_raises(Paquette::Markers::MultilineValue) { Paquette::Markers.check_values!({"k" => "a\rb"}) }
    assert_raises(ArgumentError) { Paquette::Markers.check_values!({"K" => "a"}) }
    assert_raises(ArgumentError) { Paquette::Markers.check_values!({"k" => 1}) }
    assert_raises(ArgumentError) { Paquette::Markers.check_values!([["k", "v"]]) }
    assert_nil Paquette::Markers.check_values!({"k" => "v"})
  end

  # No regexp anywhere in the module, so there is nothing for a client to make
  # backtrack - but the string work still has to stay linear on the lines a
  # hostile package can put in front of it.
  def test_pathological_lines_are_handled_promptly_and_refused
    long_leader = ("#" * 1_000_000) + " paquette:licensee"
    long_indent = (" " * 1_000_000) + "paquette:licensee"
    many_prefixes = "paquette:" * 200_000
    near_miss = "# paquette:" + ("a" * 1_000_000)
    deep = ("// paquette:licensee\n" * 100_000)

    elapsed = seconds_taken do
      assert_nil Paquette::Markers.key_of(long_leader)
      assert_equal "licensee", Paquette::Markers.key_of(long_indent)
      assert_nil Paquette::Markers.key_of(many_prefixes)
      assert_nil Paquette::Markers.key_of(near_miss)
      assert_equal ["paquette"], Paquette::Markers.keys_in(many_prefixes)
      assert_equal [], Paquette::Markers.keys_in(near_miss)
      assert_equal ["licensee"], Paquette::Markers.keys_in(long_leader)
      assert_equal "// Acme BV\n" * 100_000, Paquette::Markers.substitute(deep, VALUES)
    end
    assert_operator elapsed, :<, 2.0
  end

  def test_a_newline_inside_the_marker_line_is_two_lines
    assert_equal ["licensee"], Paquette::Markers.keys_in("junk\n# paquette:licensee\nmore")
    assert_equal "junk\n# Acme BV\nmore", Paquette::Markers.substitute("junk\n# paquette:licensee\nmore", VALUES)
  end

  private

  def seconds_taken
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
  end
end
