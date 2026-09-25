require_relative "../test_helper"

# The compact info line renderer, on its own. Every repository that serves
# /info/ goes through these class methods, and /versions MD5s what they
# produce — so the unit under test here is the exact byte sequence, not
# "something that looks like a line".
class GemRepositoryTest < Minitest::Test
  CHECKSUM = "a" * 64

  def test_renders_a_line_without_dependencies
    line = Paquette::GemServer::GemRepository.compact_info_line("1.0.0", spec, CHECKSUM)

    assert_equal "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6", line
  end

  # rubygems.org writes nothing at all for a gem whose
  # required_rubygems_version is the ">= 0" RubyGems defaults it to — see
  # https://rubygems.org/info/rake, where 13.4.2 carries a "ruby:" field
  # and no "rubygems:" one. An empty or ">= 0" field would be a different
  # line, and a different /versions digest, for no information gained.
  def test_omits_rubygems_for_the_default_requirement
    refute_includes Paquette::GemServer::GemRepository.compact_info_line("1.0.0", spec, CHECKSUM), "rubygems:"

    explicitly_default = spec { |s| s.required_rubygems_version = ">= 0" }
    refute_includes Paquette::GemServer::GemRepository.compact_info_line("1.0.0", explicitly_default, CHECKSUM), "rubygems:"
  end

  # The field sits after "ruby:", which is where rubygems.org puts it:
  #
  #   13.0.3 |checksum:c728…,ruby:>= 2.2,rubygems:>= 1.3.2,created_at:…
  #
  # (from https://rubygems.org/info/rake). The trailing "created_at:" is
  # rubygems.org bookkeeping Paquette has never served.
  def test_renders_rubygems_after_ruby
    with_rubygems = spec { |s| s.required_rubygems_version = ">= 1.3.2" }

    assert_equal "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6,rubygems:>= 1.3.2",
      Paquette::GemServer::GemRepository.compact_info_line("1.0.0", with_rubygems, CHECKSUM)
  end

  def test_renders_rubygems_alongside_dependencies
    with_both = spec do |s|
      s.add_dependency("rack", ">= 2.0")
      s.required_rubygems_version = "> 1.3.1"
    end

    assert_equal "1.0.0 rack:>= 2.0|checksum:#{CHECKSUM},ruby:>= 2.6,rubygems:> 1.3.1",
      Paquette::GemServer::GemRepository.compact_info_line("1.0.0", with_both, CHECKSUM)
  end

  # A comma separates fields here, so the clauses of one requirement are
  # joined with "&" — the same rule the dependency column follows, and the
  # one CompactIndex::GemVersion#join_multiple applies to all three.
  # Clause order is the gemspec's, not sorted; see the note on
  # requirement_string.
  def test_joins_multiple_rubygems_clauses_with_an_ampersand
    multi = spec { |s| s.required_rubygems_version = [">= 1.3.2", "< 4"] }
    line = Paquette::GemServer::GemRepository.compact_info_line("1.0.0", multi, CHECKSUM)

    assert_equal "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6,rubygems:>= 1.3.2&< 4", line
    # The join is the point: a "," here would read as the start of another
    # field rather than as more of this one.
    refute_includes line.split("rubygems:").fetch(1), ","
  end

  def test_fields_are_plain_json_safe_values
    fields = Paquette::GemServer::GemRepository.compact_info_fields(spec { |s| s.required_rubygems_version = ">= 1.3.2" }, CHECKSUM)

    assert_equal ">= 1.3.2", fields.fetch("rubygems")
    assert_equal fields, JSON.parse(JSON.generate(fields))
  end

  # nil, not "" and not ">= 0": the sidecar cache stores this hash, and the
  # renderer keys off the nil to leave the field out.
  def test_fields_carry_the_rubygems_key_even_when_there_is_no_constraint
    fields = Paquette::GemServer::GemRepository.compact_info_fields(spec, CHECKSUM)

    assert fields.key?("rubygems")
    assert_nil fields.fetch("rubygems")
  end

  # "ruby:" follows the same rule "rubygems:" does, and for the same
  # reason: a gem that constrains no Ruby version has nothing to say in
  # that field. RubyGems defaults required_ruby_version to ">= 0", so
  # without this every line in the index carried a constraint the gemspec
  # never made — and rubygems' own conformance suite asks for the line
  # without it.
  def test_omits_ruby_for_the_default_requirement
    unconstrained = spec { |s| s.required_ruby_version = ">= 0" }
    line = Paquette::GemServer::GemRepository.compact_info_line("1.0.0", unconstrained, CHECKSUM)

    assert_equal "1.0.0 |checksum:#{CHECKSUM}", line
    refute_includes line, "ruby:"
  end

  # And the field is nil in the cached hash rather than absent, so a
  # sidecar written from it round-trips through JSON and still says "no
  # constraint" when it is read back.
  def test_fields_carry_the_ruby_key_even_when_there_is_no_constraint
    fields = Paquette::GemServer::GemRepository.compact_info_fields(spec { |s| s.required_ruby_version = ">= 0" }, CHECKSUM)

    assert fields.key?("ruby")
    assert_nil fields.fetch("ruby")
  end

  # A comma in this column would read as the start of another field, so
  # the clauses of a multi-clause Ruby requirement join with "&" — the
  # same rule the dependency and "rubygems:" columns already followed.
  def test_joins_multiple_ruby_clauses_with_an_ampersand
    multi = spec { |s| s.required_ruby_version = [">= 3.1", "< 4"] }
    line = Paquette::GemServer::GemRepository.compact_info_line("1.0.0", multi, CHECKSUM)

    assert_equal "1.0.0 |checksum:#{CHECKSUM},ruby:>= 3.1&< 4", line
    refute_includes line.split("ruby:").fetch(1), ","
  end

  # A fields hash from somewhere other than compact_info_fields still
  # renders the line it rendered before this field existed, rather than
  # raising a KeyError on a request.
  def test_renders_from_a_fields_hash_that_predates_the_rubygems_key
    fields = {"dependencies" => [], "ruby" => ">= 2.6", "checksum" => CHECKSUM}

    assert_equal "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6",
      Paquette::GemServer::GemRepository.compact_info_line_from_fields("1.0.0", fields)
  end

  # The personalizer rewrites only the checksum of an already-rendered
  # line, and "rubygems:" now sits downstream of the field it is looking
  # for. [0-9a-f] stops at the comma that ends the digest, so a
  # requirement further along the line is never in reach.
  def test_replace_checksum_leaves_the_rubygems_field_alone
    line = "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6,rubygems:>= 1.3.2"
    replaced = Paquette::GemServer::GemRepository.replace_checksum(line, "b" * 64)

    assert_equal "1.0.0 |checksum:#{"b" * 64},ruby:>= 2.6,rubygems:>= 1.3.2", replaced
  end

  # The digest of a gem whose name is all hex is still only found where a
  # "checksum:" prefix sits, and only once.
  def test_replace_checksum_matches_only_the_checksum_field
    line = "1.0.0 beefcafe:>= 1.0|checksum:#{CHECKSUM},ruby:>= 2.6,rubygems:>= 1.3.2"
    replaced = Paquette::GemServer::GemRepository.replace_checksum(line, "c" * 64)

    assert_equal "1.0.0 beefcafe:>= 1.0|checksum:#{"c" * 64},ruby:>= 2.6,rubygems:>= 1.3.2", replaced
  end

  # Anchorless by design — the pattern names its own prefix — so the thing
  # to prove is that a line carrying newlines cannot smuggle a second
  # substitution in, and that a run of hex long enough to make a
  # backtracking matcher sweat does not.
  def test_replace_checksum_survives_pathological_input
    hex_flood = "f" * 200_000
    line = "1.0.0 |checksum:#{hex_flood},ruby:>= 2.6,rubygems:>= 1.3.2"

    elapsed_seconds = elapsed do
      replaced = Paquette::GemServer::GemRepository.replace_checksum(line, "d" * 64)
      assert_equal "1.0.0 |checksum:#{"d" * 64},ruby:>= 2.6,rubygems:>= 1.3.2", replaced
    end
    assert_operator elapsed_seconds, :<, 1.0, "replace_checksum should not backtrack over a long hex run"
  end

  def test_replace_checksum_does_not_ride_over_an_injected_newline
    line = "1.0.0 |checksum:#{CHECKSUM},ruby:>= 2.6\n9.9.9 |checksum:#{"e" * 64},ruby:>= 2.6"
    replaced = Paquette::GemServer::GemRepository.replace_checksum(line, "d" * 64)

    assert_equal "1.0.0 |checksum:#{"d" * 64},ruby:>= 2.6\n9.9.9 |checksum:#{"e" * 64},ruby:>= 2.6", replaced
  end

  # A percent-decoded segment can arrive as invalid UTF-8, and a match
  # against one raises ArgumentError rather than returning nil.
  def test_replace_checksum_survives_invalid_encoding
    line = "1.0.0 \xFF|checksum:#{CHECKSUM},ruby:>= 2.6".force_encoding(Encoding::UTF_8)
    refute line.valid_encoding?

    assert_raises(ArgumentError) { Paquette::GemServer::GemRepository.replace_checksum(line, "d" * 64) }
  end

  private

  # A Gem::Specification is enough for the renderer; nothing here opens a
  # .gem file.
  def spec
    Gem::Specification.new do |s|
      s.name = "fixture"
      s.version = "1.0.0"
      s.summary = "Paquette test fixture"
      s.authors = ["Paquette"]
      s.required_ruby_version = ">= 2.6"
      yield s if block_given?
    end
  end
end
