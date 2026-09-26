require "json"
require "fileutils"
require "digest"

# Abstract base class for gem repositories
class Paquette::GemServer::GemRepository
  def initialize
    raise NotImplementedError, "GemRepository is an abstract class"
  end

  # @return [Array<String>] the gem names available in the repository
  def gem_names
    raise NotImplementedError, "Subclasses must implement gem_names"
  end

  # @return [Array<Array(String, String)>] [name, version] pairs for all gems
  def gem_versions
    raise NotImplementedError, "Subclasses must implement gem_versions"
  end

  # @param gem_name [String]
  # @return [Array<String>] the versions of the gem
  def versions_for_gem(gem_name)
    raise NotImplementedError, "Subclasses must implement versions_for_gem"
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [String] the path of the .gem file
  def gem_file_path(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_file_path"
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Boolean]
  def gem_exists?(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_exists?"
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Gem::Specification, nil]
  def gem_spec(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_spec"
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Array] the gem's dependencies
  def gem_dependencies(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_dependencies"
  end

  # When the given version was published; CooldownRepository asks this.
  # Subclasses override only to put a cache in front of it.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [Time, nil] nil when it cannot be established
  def published_at(gem_name, version)
    gem_spec(gem_name, version)&.date
  end

  # @param gem_name [String]
  # @return [String, nil] the /info/ document for the gem, all versions
  def compact_info(gem_name)
    raise NotImplementedError, "Subclasses must implement compact_info"
  end

  # ---------------------------------------------------------------------
  # The HTTP caching protocol. Unlike everything above, these three have
  # defaults instead of raising: a repository that has never heard of them
  # must degrade to "no caching", not raise mid-request. The defaults are
  # the answers that are safe when nothing is known.
  # ---------------------------------------------------------------------

  # A short string that changes whenever anything this repository would
  # serve changes — wrappers included. A wrapper that cannot describe
  # itself must return nil, "do not cache this", which propagates outward.
  #
  # @return [String, nil]
  def cache_validator
    nil
  end

  # Whether two callers can get different answers out of this repository —
  # false permits `public` responses. True is the only safe default for a
  # repository nobody here has seen.
  #
  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # The SHA256 of the .gem file this repository would actually serve —
  # under a Personalizer, not the bytes on disk.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil] nil when unknown or when the gem is not there
  def gem_checksum(gem_name, version)
    nil
  end

  # The caching questions, asked of an object that may have never heard of
  # the protocol. The rules live in Paquette::CacheValidation, shared with
  # the npm side.
  #
  # @param repository [Object]
  # @return [String, nil]
  def self.cache_validator_of(repository)
    Paquette::CacheValidation.validator_of(repository)
  end

  # @param repository [Object]
  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil]
  def self.gem_checksum_of(repository, gem_name, version)
    repository.gem_checksum(gem_name, version) if repository.respond_to?(:gem_checksum)
  end

  # @param inner_validator [String, nil]
  # @param layer [String]
  # @param key [String, nil]
  # @return [String, nil]
  def self.derive_validator(inner_validator, layer, key)
    Paquette::CacheValidation.derive_validator(inner_validator, layer, key)
  end

  # One line of an /info/ file, in the compact index format:
  #
  #   VERSION DEP:REQ,DEP:REQ|checksum:SHA256,ruby:REQ,rubygems:REQ
  #
  # A class method on purpose: some repositories are SimpleDelegators, and
  # an instance method would be forwarded to the wrapped repository.
  #
  # @param version [String]
  # @param spec [Gem::Specification]
  # @param checksum [String]
  # @return [String]
  def self.compact_info_line(version, spec, checksum)
    compact_info_line_from_fields(version, compact_info_fields(spec, checksum))
  end

  # The spec boiled down to plain strings and arrays — this hash is what a
  # repository may cache on disk, and strings deserialize into no surprises.
  #
  # @param spec [Gem::Specification]
  # @param checksum [String]
  # @return [Hash{String => Object}]
  def self.compact_info_fields(spec, checksum)
    # Development dependencies are not part of the resolution and
    # rubygems.org does not publish them.
    deps = spec.dependencies.select { |dep| dep.type == :runtime }.sort_by(&:name).map do |dep|
      [dep.name, requirement_string(dep.requirement)]
    end

    # nil rather than ">= 0" when there is no constraint — rubygems.org
    # omits the field entirely, and the renderer keys off the nil.
    required_rubygems = spec.required_rubygems_version
    rubygems = requirement_string(required_rubygems) if required_rubygems && required_rubygems.to_s != ">= 0"

    required_ruby = spec.required_ruby_version
    ruby = requirement_string(required_ruby) if required_ruby && required_ruby.to_s != ">= 0"

    {
      "dependencies" => deps,
      "ruby" => ruby,
      "rubygems" => rubygems,
      "checksum" => checksum,
      # Not rendered into any line; cached alongside so CooldownRepository
      # never has to open the gem. Epoch seconds survive JSON as-is.
      "published_at" => spec.date&.to_i
    }
  end

  # Renders a line from a fields hash — freshly extracted or read back from
  # a cache, the bytes must come out the same either way. Keys beyond the
  # ones this reads are ignored.
  #
  # @param version [String]
  # @param fields [Hash{String => Object}]
  # @return [String]
  def self.compact_info_line_from_fields(version, fields)
    deps = fields.fetch("dependencies").map { |dep_name, req| "#{dep_name}:#{req}" }.join(",")

    # A gem without dependencies gets "1.0.0 |...", exactly what
    # rubygems.org serves.
    line = "#{version} #{deps}|checksum:#{fields.fetch("checksum")}"

    # Absent, not ">= 0", for a gem that constrains nothing; [] rather
    # than fetch() so an older cached fields hash still renders.
    ruby = fields["ruby"]
    line << ",ruby:#{ruby}" if ruby

    rubygems = fields["rubygems"]
    line << ",rubygems:#{rubygems}" if rubygems

    line
  end

  # An already-rendered line with only its checksum replaced, for
  # repositories that serve rewritten gem files. Lives here because this
  # class owns the line format; the pattern cannot stray into a
  # neighbouring field.
  #
  # @param line [String]
  # @param checksum [String]
  # @return [String]
  def self.replace_checksum(line, checksum)
    line.sub(/checksum:[0-9a-f]+/) { "checksum:#{checksum}" }
  end

  # A comma separates *dependencies* in this format, so within one
  # dependency the clauses are joined with "&": ">= 1.0, < 3" becomes
  # ">= 1.0&< 3".
  #
  # @param requirement [Gem::Requirement]
  # @return [String]
  def self.requirement_string(requirement)
    requirement.to_s.split(", ").join("&")
  end
end
