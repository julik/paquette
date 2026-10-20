require "date"
require "rubygems"

# Everything a pushed gemspec claims about itself, checked before any of it
# is believed: `spec.name`/`spec.version` become a filesystem path, and the
# compact index is line-oriented text, so an unconstrained field is either a
# traversal or a forged index row. Runs before the upload is moved into
# place; gems already on disk are not re-checked.
class Paquette::GemServer::SpecValidator
  # RubyGems' own charset, first character narrowed to alphanumeric so a
  # name can never start with ".". \A..\z, never ^..$: a "$" would happily
  # match the end of the first line of "safe\nforged 9.9.9 …".
  NAME = /\A[A-Za-z0-9]#{Paquette::GemServer::NAME_CHAR}{0,254}\z/

  # A platform becomes a path too and legitimately carries dashes, so it
  # gets its own charset — no path separators, NUL, newline or leading dot.
  # Flat rather than the honest `(?:-seg){0,3}` grammar, which fails
  # Regexp.linear_time? on an uploader-chosen string.
  PLATFORM = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  # Refused outright anywhere in a platform: it is the single string whose
  # meaning changes if anything downstream ever splits the basename on a
  # dash again.
  PLATFORM_DOT_DOT = ".."

  # RubyGems' own — but it accepts "" and a trailing "\n", hence the
  # emptiness check and FORBIDDEN_IN_FIELD over the same string.
  VERSION = Gem::Version::ANCHORED_VERSION_PATTERN #: Regexp

  # The three bytes that turn one field into two index lines, or truncate
  # a path at the filesystem boundary.
  FORBIDDEN_IN_FIELD = /[\r\n\x00]/

  # No field in a gemspec has any business being longer than this, so
  # nothing longer gets as far as an encoding check or a regexp.
  MAX_FIELD_BYTES = 2048

  # The RubyGems placeholder a reproducible build stamps when it is given no
  # date, which says nothing about when the gem was released. Gem's own
  # DEFAULT_SOURCE_DATE_EPOCH is not loaded with rubygems/package, and older
  # RubyGems have none - this is its value.
  PLACEHOLDER_DATE = Time.at(315_619_200).utc.to_date #: Date

  # How far from today a release date may plausibly be, in days.
  RELEASE_DATE_TOLERANCE_DAYS = 3 * 366 #: Integer

  # Refuses a gem whose date cannot be when it was released: the placeholder,
  # or years away from today. For a registry that decides anything by the date
  # a publisher wrote into the gem.
  #
  # Raises `Paquette::GemServer::DirectoryGemRepository::InvalidGem`.
  #
  #: (::Gem::Specification spec, ?today: Date) -> void
  def self.validate_release_date!(spec, today: Date.today)
    day = spec.date&.to_date
    plausible = day && day != PLACEHOLDER_DATE && (day - today).abs <= RELEASE_DATE_TOLERANCE_DAYS
    return if plausible

    invalid!(<<~MESSAGE.strip)
      This registry needs a gem's release date, and #{day || "no date"} does not look like one.
      Rebuild with the release commit's own date and push again:

          SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) gem build #{spec.name}.gemspec

      The build stays byte-for-byte reproducible; it simply stops claiming a date it cannot have.
    MESSAGE
  end

  # One error class deliberately: a client cannot act differently on
  # unreadable versus dishonest.
  #
  # Raises `Paquette::GemServer::DirectoryGemRepository::InvalidGem` always.
  #
  #: (String message) -> bot
  def self.invalid!(message)
    raise Paquette::GemServer::DirectoryGemRepository::InvalidGem, message
  end

  # Checks `spec` and returns the validated triple as plain Strings, so a
  # caller cannot go on using the unvalidated `spec.name`. The platform
  # comes back canonicalized, RubyGems' own spelling.
  #
  # Returns name, version, platform.
  # Raises `Paquette::GemServer::DirectoryGemRepository::InvalidGem`.
  #
  #: (::Gem::Specification spec) -> [String, String, String]
  def self.validate!(spec)
    # The byte scan goes first, so NAME and VERSION only ever match against
    # a string already known to be single-line, valid UTF-8 text.
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

  # The same checks applied to the params of a yank, which name a path
  # exactly as a pushed gemspec's fields do. `platform` may be nil or ""
  # (`gem yank` omits it for a plain-ruby gem); `version` may arrive with
  # the platform already glued on, the column as the index publishes it.
  #
  # Returns name and version column (platform
  # already glued on), the pair the repository is keyed by.
  # Raises `Paquette::GemServer::DirectoryGemRepository::InvalidGem`.
  #
  #: (String gem_name, String version, String? platform) -> [String, String]
  def self.validate_reference!(gem_name, version, platform)
    name = string_field(gem_name, "name")
    version = string_field(version, "version")
    platform = platform.nil? ? "" : string_field(platform, "platform")

    # The re-tagged copies are what go on being used — bytes cannot be
    # matched against a UTF-8 pattern at all.
    pairs = [["name", name], ["version", version], ["platform", platform]] #: Array[[String, String]]
    name, version, platform = pairs.map do |label, value|
      scanned = scannable(label, value)
      invalid!("Gem #{label} contains a newline or a NUL byte") if FORBIDDEN_IN_FIELD.match?(scanned)
      scanned
    end #: [String, String, String]

    invalid!("Gem name #{name.inspect} is not a valid gem name") unless NAME.match?(name)
    invalid!("Gem version is empty") if version.strip.empty?
    invalid!("Gem version #{version.inspect} is not a valid version") unless VERSION.match?(version)
    unless platform.empty? || platform == Gem::Platform::RUBY || valid_platform?(platform)
      invalid!("Gem platform #{platform.inspect} is not a valid platform")
    end

    [name, Paquette::GemServer.version_column(version, platform)]
  end

  # `spec.platform` is the String "ruby" for a plain build, a Gem::Platform
  # otherwise; "ruby" is let through as itself because it is the one value
  # that produces no filename suffix at all.
  #
  #: (::Gem::Specification spec) -> String
  def self.platform_of(spec)
    platform = scannable("platform", spec.platform)
    return Gem::Platform::RUBY if platform.empty? || platform == Gem::Platform::RUBY

    invalid!("Gem platform #{platform.inspect} is not a valid platform") unless valid_platform?(platform)
    platform
  end

  # Every uploader-controlled field that reaches a line of the compact
  # index — the list reads as "what gets interpolated", not "what is safe".
  #
  #: (::Gem::Specification spec) -> Array[[String, String]]
  def self.text_fields(spec)
    fields = [
      ["name", spec.name],
      ["version", spec.version],
      ["platform", spec.platform],
      ["required_ruby_version", spec.required_ruby_version],
      ["required_rubygems_version", spec.required_rubygems_version]
    ] #: Array[[String, untyped]]

    Array(spec.dependencies).each do |dep|
      fields << ["dependency name", dep.name]
      fields << ["dependency requirement", dep.requirement]
    end

    Array(spec.licenses).each { |licence| fields << ["licence", licence] }
    Array(spec.executables).each { |executable| fields << ["executable", executable] }

    fields.map { |label, value| [label, scannable(label, value)] }
  end

  # Bounds, reads as text and re-tags a field as UTF-8 — reinterpreted,
  # not merely asked: a string tagged ASCII-8BIT is *always* "valid", and
  # would blow up later instead of here.
  #
  #: (String label, untyped value) -> String
  def self.scannable(label, value)
    string = begin
      value.to_s
    rescue
      invalid!("Gem #{label} could not be read as text")
    end

    invalid!("Gem #{label} is longer than #{MAX_FIELD_BYTES} bytes") if string.bytesize > MAX_FIELD_BYTES

    as_utf8 = string.dup.force_encoding(Encoding::UTF_8)
    invalid!("Gem #{label} is not valid UTF-8") unless as_utf8.valid_encoding?

    as_utf8
  end

  # The fields that become a path have to be Strings before anything else
  # looks at them; `spec.version` is the exception, parsed into a
  # Gem::Version by RubyGems on the way in.
  #
  #: (untyped value, String label) -> String
  def self.string_field(value, label)
    return value if value.is_a?(String)
    return value.to_s if label == "version" && value.is_a?(Gem::Version)

    invalid!("Gem #{label} is missing or is not a string")
  end

  # The charset and the one shape it cannot express, in one place, so the
  # push path and the yank path cannot come to different conclusions about
  # the same string.
  #
  #: (String platform) -> bool
  def self.valid_platform?(platform)
    PLATFORM.match?(platform) && !platform.include?(PLATFORM_DOT_DOT)
  end

  private_class_method :invalid!, :text_fields, :scannable, :string_field, :platform_of, :valid_platform?
end
