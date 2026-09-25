require "rubygems"

# Everything a pushed gemspec claims about itself, checked before any of it
# is believed.
#
# A .gem is a tarball carrying a YAML document the uploader wrote, and
# `Gem::Package#spec` hands that document back as a Gem::Specification
# without asking whether the values in it are ones a server should act on.
# Two things downstream act on them anyway:
#
#   - the repository turns `spec.name` and `spec.version` into a path, so a
#     name of "../../pwned" writes the upload outside the gems root;
#   - the compact index is a line-oriented text format, so a "\n" anywhere
#     in a name, a version, a requirement or a dependency forges an index
#     row — a version that does not exist, carrying a checksum the forger
#     chose, which Bundler will then resolve and install against.
#
# Neither is a bug in the *format*: both are what happens when a field that
# was never constrained reaches a place that assumes it was. So the
# constraint lives here, in one class, in front of both — rather than as a
# guard inlined in whichever method happened to need it first.
#
# This runs before the upload is moved into place and before a sidecar is
# derived from it, which means the corpus only ever contains specs that
# passed. Gems already on disk from before this existed are not re-checked;
# the fix is for the door, not for the room.
class Paquette::GemServer::SpecValidator
  # RubyGems' own charset for a name, with the first character narrowed to
  # alphanumeric. Bare NAME_CHAR would admit a leading ".", and ".." is a
  # path component with a meaning of its own — the containment check in the
  # repository would catch it, but a name that can never be a traversal in
  # the first place is the cheaper half of the belt and braces. gem.coop
  # applies the same rule. Anchored with \A..\z, never ^..$: a "$" would
  # happily match the end of the first line of "safe\nforged 9.9.9 …".
  # Bounded rather than "+" because a gem name has a real-world maximum.
  NAME = /\A[A-Za-z0-9]#{Paquette::GemServer::NAME_CHAR}{0,254}\z/

  # A platform is the third thing that becomes a path — "a-0.2.0-java.gem"
  # — and it cannot reuse NAME's charset, because a legitimate platform is
  # full of dashes: "x86_64-linux", "universal-darwin-20", "x64-mingw-ucrt".
  # So it gets a charset of its own, and the interesting part is what is
  # *not* in it. No "/" and no backslash, so a platform can never introduce a path
  # separator; no NUL and no newline, so it can neither truncate a path at
  # the filesystem boundary nor forge a second compact-index row; and the
  # first character is alphanumeric, which rules out a leading dot and
  # therefore a component that is "." or "..".
  #
  # Flat rather than spelled out as "segments joined by dashes", which is
  # what a Gem::Platform actually is. A nested `(?:-seg){0,3}` is the
  # honest grammar and Regexp.linear_time? says no to it — the bounded
  # repetition inside a bounded repetition is exactly the shape that can
  # backtrack — and this pattern runs on a string an uploader chose. The
  # one thing the flat form gives up is rejecting "a--b" and "a-.b", and
  # neither of those is dangerous: a platform cannot leave its path
  # component, so the only spellings worth refusing are the ones that
  # *are* a path component, which PLATFORM_DOT_DOT below covers explicitly.
  #
  # 64 bytes: the longest platform RubyGems publishes is well under half
  # that, and the ceiling is what keeps the suffix from stretching the
  # filename past what split_gem_spec_name will read back.
  PLATFORM = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  # The one shape the charset cannot express and the pattern above
  # deliberately does not try to. ".." anywhere in a platform is refused
  # outright rather than reasoned about: it cannot be a traversal on its
  # own — the platform is glued into a basename, not a path — but it is
  # the single string whose meaning changes if anything downstream ever
  # splits that basename on a dash again.
  PLATFORM_DOT_DOT = ".."

  # RubyGems' own, and anchored and linear as it ships — but it is written
  # to accept what Gem::Version accepts, not to be a filename filter, so it
  # is not sufficient on its own in two ways this class covers separately.
  # The whole version group is optional, so "" matches; and the \s* at both
  # ends means a trailing "\n" matches too. Hence the emptiness check below
  # and FORBIDDEN_IN_FIELD over the same string.
  VERSION = Gem::Version::ANCHORED_VERSION_PATTERN

  # The three bytes that turn one field into two lines, or truncate a path
  # at the filesystem boundary. Checked across every field the index
  # interpolates, not just the name: `/info/` carries the ruby requirement
  # and each dependency's requirement verbatim, and those are as
  # uploader-chosen as the name is.
  FORBIDDEN_IN_FIELD = /[\r\n\x00]/

  # No field in a gemspec has any business being longer than this, so
  # nothing longer gets as far as an encoding check or a regexp.
  MAX_FIELD_BYTES = 2048

  # Raised for anything here, deliberately: `GemServer#handle_push` already
  # maps InvalidGem to a 400 with the message as the body, and a rejected
  # push is a rejected push whether the spec was unreadable or merely
  # dishonest. A client cannot act differently on the distinction, so
  # there is no second error class for it to fail to handle.
  def self.invalid!(message)
    raise Paquette::GemServer::DirectoryGemRepository::InvalidGem, message
  end

  # Checks `spec` and returns [name, version, platform] as plain Strings —
  # the validated triple, so a caller cannot accidentally go on using the
  # unvalidated `spec.name` next to the check that just passed. Raises
  # InvalidGem otherwise.
  #
  # The platform comes back canonicalized, because that is what
  # `spec.platform.to_s` already is: RubyGems parses whatever the gemspec
  # declared into a Gem::Platform and prints it back in its own spelling,
  # so "x86_64-darwin20" and "x86_64-darwin-20" both arrive here as
  # "x86_64-darwin-20". Two uploads spelling the same platform differently
  # therefore claim the same filename and the second is a duplicate — which
  # is the correct answer, and the reason the *canonical* string is what
  # gets returned rather than whatever the YAML said.
  def self.validate!(spec)
    # The byte scan goes first. It is the one check that holds for every
    # field, including the two below, and running it first means NAME and
    # VERSION are only ever matched against a string already known to be
    # single-line, valid UTF-8 text.
    text_fields(spec).each do |label, value|
      invalid!("Gem #{label} contains a newline or a NUL byte") if FORBIDDEN_IN_FIELD.match?(value)
    end

    name = string_field(spec.name, "name")
    version = string_field(spec.version, "version")

    invalid!("Gem name #{name.inspect} is not a valid gem name") unless NAME.match?(name)
    invalid!("Gem version is empty") if version.strip.empty?
    invalid!("Gem version #{version.inspect} is not a valid version") unless VERSION.match?(version)

    [name, version, platform_of(spec)]
  end

  # The same three checks applied to the params of a yank, which name a
  # path exactly as a pushed gemspec's fields do — they just arrive as
  # form-encoded strings a client chose rather than out of a YAML document
  # an uploader chose, which is not a meaningful difference to File.join.
  # Without this, `gem_name=../../etc` reached File.join unexamined and a
  # yank was a rename of any .gem file on the box.
  #
  # Returns [name, version_column]: the pair the repository is keyed by,
  # with the platform already glued on, so the caller never assembles it a
  # second way. `platform` may be nil or "" — `gem yank` omits it for a
  # plain-ruby gem — and both mean "ruby", which is the build whose column
  # carries no suffix at all.
  #
  # `version` is allowed to arrive with the platform already glued to it
  # ("1.16.0-java" with no platform param), because that is the column as
  # the index publishes it and a client reading the index and yanking what
  # it read should not have to take it apart first. Gem::Version's own
  # pattern accepts that form — the dash is its prerelease separator —
  # and every byte it admits is one a filename can hold.
  def self.validate_reference!(gem_name, version, platform)
    name = string_field(gem_name, "name")
    version = string_field(version, "version")
    platform = platform.nil? ? "" : string_field(platform, "platform")

    # Length, encoding and the three bytes that forge an index row or
    # truncate a path — the same scan a pushed spec's fields get, before a
    # pattern is matched against any of them. The re-tagged copies are what
    # go on being used: a param that arrived as bytes rather than as UTF-8
    # text cannot be matched against a UTF-8 pattern at all.
    name, version, platform = [["name", name], ["version", version], ["platform", platform]].map do |label, value|
      scanned = scannable(label, value)
      invalid!("Gem #{label} contains a newline or a NUL byte") if FORBIDDEN_IN_FIELD.match?(scanned)
      scanned
    end

    invalid!("Gem name #{name.inspect} is not a valid gem name") unless NAME.match?(name)
    invalid!("Gem version is empty") if version.strip.empty?
    invalid!("Gem version #{version.inspect} is not a valid version") unless VERSION.match?(version)
    unless platform.empty? || platform == Gem::Platform::RUBY || valid_platform?(platform)
      invalid!("Gem platform #{platform.inspect} is not a valid platform")
    end

    [name, Paquette::GemServer.version_column(version, platform)]
  end

  # `spec.platform` is whatever RubyGems made of the gemspec's `platform:`
  # — the String "ruby" for a plain build, a Gem::Platform otherwise — so
  # it is read through to_s and then held to PLATFORM before it is allowed
  # anywhere near a filename. "ruby" is let through as itself rather than
  # matched: it is the one value that produces no suffix at all.
  def self.platform_of(spec)
    platform = scannable("platform", spec.platform)
    return Gem::Platform::RUBY if platform.empty? || platform == Gem::Platform::RUBY

    invalid!("Gem platform #{platform.inspect} is not a valid platform") unless valid_platform?(platform)
    platform
  end

  # Every uploader-controlled field that reaches a line of the compact
  # index, `/names` or `/versions`. Name and version are in here too even
  # though NAME and VERSION already exclude the three bytes — the list is
  # meant to be read as "what gets interpolated", and leaving them out
  # would make it read as "what is safe", which is a different and much
  # easier list to get wrong later.
  def self.text_fields(spec)
    fields = [
      ["name", spec.name],
      ["version", spec.version],
      ["platform", spec.platform],
      ["required_ruby_version", spec.required_ruby_version],
      ["required_rubygems_version", spec.required_rubygems_version]
    ]

    Array(spec.dependencies).each do |dep|
      fields << ["dependency name", dep.name]
      fields << ["dependency requirement", dep.requirement]
    end

    Array(spec.licenses).each { |licence| fields << ["licence", licence] }
    Array(spec.executables).each { |executable| fields << ["executable", executable] }

    fields.map { |label, value| [label, scannable(label, value)] }
  end

  # A spec field is whatever the YAML said it was, so `to_s` may land on
  # anything — and the result may be bytes that are not valid UTF-8, which
  # makes a regexp match *raise* ArgumentError rather than return false.
  # Refusing those outright is the only answer that does not depend on
  # which encoding the next reader guesses at.
  def self.scannable(label, value)
    string = begin
      value.to_s
    rescue
      invalid!("Gem #{label} could not be read as text")
    end

    invalid!("Gem #{label} is longer than #{MAX_FIELD_BYTES} bytes") if string.bytesize > MAX_FIELD_BYTES

    # Reinterpreted as UTF-8 before the check, not merely asked whether it
    # is valid in whatever encoding it arrived tagged with: a string
    # tagged ASCII-8BIT is *always* "valid", so a spec field carrying a
    # truncated multi-byte sequence would sail through as binary and then
    # blow up later in JSON.pretty_generate when the sidecar is written,
    # or be matched against as raw bytes. UTF-8 is what these fields are
    # rendered as, so UTF-8 is what they have to be well-formed in.
    as_utf8 = string.dup.force_encoding(Encoding::UTF_8)
    invalid!("Gem #{label} is not valid UTF-8") unless as_utf8.valid_encoding?

    # The re-tagged copy is what goes back, so the caller's scan runs on a
    # string the UTF-8 pattern can be compared against at all — matching a
    # UTF-8 regexp against an ASCII-8BIT string holding high bytes raises
    # Encoding::CompatibilityError rather than returning false.
    as_utf8
  end

  # The two fields that become a path have to be Strings before anything
  # else looks at them — a name that is a Hash or an Integer would sail
  # through a `to_s` and arrive at File.join as something nobody intended.
  # `spec.version` is the exception: RubyGems parses it into a Gem::Version
  # on the way in, so it is the only field read through its object.
  def self.string_field(value, label)
    return value if value.is_a?(String)
    return value.to_s if label == "version" && value.is_a?(Gem::Version)

    invalid!("Gem #{label} is missing or is not a string")
  end

  # The charset and the one shape it cannot express, in one place, so the
  # push path and the yank path cannot come to different conclusions about
  # the same string.
  def self.valid_platform?(platform)
    PLATFORM.match?(platform) && !platform.include?(PLATFORM_DOT_DOT)
  end

  private_class_method :invalid!, :text_fields, :scannable, :string_field, :platform_of, :valid_platform?
end
