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

  # Checks `spec` and returns [name, version] as plain Strings — the
  # validated pair, so a caller cannot accidentally go on using the
  # unvalidated `spec.name` next to the check that just passed. Raises
  # InvalidGem otherwise.
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

    [name, version]
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

  private_class_method :invalid!, :text_fields, :scannable, :string_field
end
