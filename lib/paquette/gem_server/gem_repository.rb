require "json"
require "fileutils"
require "digest"

# Abstract base class for gem repositories
class Paquette::GemServer::GemRepository
  def initialize
    raise NotImplementedError, "GemRepository is an abstract class"
  end

  # Returns an array of gem names available in the repository
  def gem_names
    raise NotImplementedError, "Subclasses must implement gem_names"
  end

  # Returns an array of [name, version] pairs for all gems
  def gem_versions
    raise NotImplementedError, "Subclasses must implement gem_versions"
  end

  # Returns an array of versions for a specific gem
  def versions_for_gem(gem_name)
    raise NotImplementedError, "Subclasses must implement versions_for_gem"
  end

  # Returns the gem file path for a specific gem and version
  def gem_file_path(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_file_path"
  end

  # Returns whether a gem file exists for the given name and version
  def gem_exists?(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_exists?"
  end

  # Returns the gem specification for a specific gem and version
  def gem_spec(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_spec"
  end

  # Returns dependencies for a specific gem and version
  def gem_dependencies(gem_name, version)
    raise NotImplementedError, "Subclasses must implement gem_dependencies"
  end

  # When the given version was published, as a Time, or nil when that
  # cannot be established. CooldownRepository asks this.
  #
  # The default answer is the date recorded in the gemspec. It is a
  # property of the immutable gem bytes, which is what makes it survive an
  # rsync, a container rebuild or a restore from backup — see the long
  # note in CooldownRepository for why every other obvious source does
  # not. Subclasses override this only to put a cache in front of it, not
  # to change the answer; a caller wanting a different source passes
  # `published_at:` to the wrapper.
  def published_at(gem_name, version)
    gem_spec(gem_name, version)&.date
  end

  # Returns compact info for a specific gem (all versions)
  def compact_info(gem_name)
    raise NotImplementedError, "Subclasses must implement compact_info"
  end

  # ---------------------------------------------------------------------
  # The HTTP caching protocol.
  #
  # Unlike everything above, these three have defaults instead of raising.
  # They were added after repositories outside this gem already existed,
  # and the thing a repository that has never heard of them must do is
  # degrade to "no caching" — not raise NotImplementedError out of the
  # middle of a request. So the defaults are the answers that are safe
  # when nothing is known, which for a cache means: refuse to name the
  # response, and assume its bytes belong to one caller.
  # ---------------------------------------------------------------------

  # A short string that changes whenever anything this repository would
  # serve changes — including anything a *wrapper* would change about it.
  # The server turns it into an ETag; two requests that get the same
  # validator are promised the same bytes.
  #
  # That promise is the whole difficulty, because a repository here is
  # almost never one object: it is a base repository wrapped in a gate
  # (each licensee sees a different subset) and a personalizer (each
  # licensee gets different bytes). A validator derived from the corpus
  # alone would let one licensee's cached index answer another licensee's
  # request, which is a confidentiality bug and strictly worse than no
  # caching. So every wrapper that changes what a caller sees must mix
  # itself in, and a wrapper that *cannot* describe itself must return
  # nil. nil means "do not cache this" and propagates outward through
  # every layer above it — see ReadGatedRepository, which cannot
  # fingerprint the arbitrary block it gates with.
  def cache_validator
    nil
  end

  # Whether two callers can get different answers out of this repository.
  # An anonymous response over a stack that says false may be `public`,
  # which lets a CDN keep it and hand it to anyone. True is the default
  # because it is the only safe answer for a repository nobody here has
  # seen; DirectoryGemRepository says false, and a wrapper that does not
  # change what a caller sees delegates the question to what it wraps.
  def varies_by_caller?
    true
  end

  # The SHA256 of the .gem file this repository would actually serve for
  # `gem_name` and `version` — the bytes the client receives, which under
  # a Personalizer are not the bytes on disk. nil when unknown or when
  # the gem is not there.
  #
  # This is the same number that already goes into the `checksum:` field
  # of a compact info line, and both sides of the protocol cache it, so
  # asking for it is a couple of stat calls rather than a re-hash.
  def gem_checksum(gem_name, version)
    nil
  end

  # The three questions above, asked of an object that may be any of: a
  # repository implementing the protocol, a SimpleDelegator wrapping one,
  # or somebody's duck-typed stand-in that has never heard of any of this.
  # The rules themselves live in Paquette::CacheValidation, shared with the
  # npm side - two servers are two chances to get a security-critical
  # digest subtly different from each other.
  def self.cache_validator_of(repository)
    Paquette::CacheValidation.validator_of(repository)
  end

  def self.gem_checksum_of(repository, gem_name, version)
    repository.gem_checksum(gem_name, version) if repository.respond_to?(:gem_checksum)
  end

  def self.derive_validator(inner_validator, layer, key)
    Paquette::CacheValidation.derive_validator(inner_validator, layer, key)
  end

  # One line of an /info/ file, in the compact index format:
  #
  #   VERSION DEP:REQ,DEP:REQ|checksum:SHA256,ruby:REQ,rubygems:REQ
  #
  # The dependency section is what Bundler resolves against, and the gem it
  # later downloads is checked against it — a line that claims no
  # dependencies for a gem that has them makes that gem uninstallable with
  # "revealed dependencies not in the API", because Bundler will not silently
  # accept a spec that disagrees with the index it resolved from.
  #
  # This is a class method on purpose. Every repository that renders compact
  # info needs it, and some of them are SimpleDelegators — an instance
  # method here would be forwarded to the wrapped repository, which is
  # harmless for pure formatting but invites the mistake of putting a
  # *reading* method next to it and having the wrapper silently bypassed.
  #
  # `version` is passed rather than read off the spec because the version
  # column may carry a platform suffix ("1.0.0-x86_64-linux"), which the
  # spec's own version does not have, and the repository is the thing that
  # knows which version string it publishes.
  def self.compact_info_line(version, spec, checksum)
    compact_info_line_from_fields(version, compact_info_fields(spec, checksum))
  end

  # The spec boiled down to exactly what a compact info line is made of,
  # as plain strings and arrays. Plain on purpose: this hash is what a
  # repository may cache on disk, and a cache of Gem::Specification
  # objects is a cache of whatever Marshal happened to capture of a class
  # that changes between RubyGems releases. Strings do not deserialize
  # into surprises.
  def self.compact_info_fields(spec, checksum)
    # Development dependencies are not part of the resolution and rubygems.org
    # does not publish them; sending them would make Bundler resolve gems a
    # consumer never asked for.
    deps = spec.dependencies.select { |dep| dep.type == :runtime }.sort_by(&:name).map do |dep|
      [dep.name, requirement_string(dep.requirement)]
    end

    # The same failure mode as a missing dependency, one field over: a gem
    # that declares `required_rubygems_version` and does not say so in the
    # index resolves cleanly and then refuses to install, because the
    # client only meets the constraint once it holds the real gemspec.
    #
    # nil rather than ">= 0" when there is no constraint — rubygems.org
    # omits the field entirely in that case (compare
    # https://rubygems.org/info/rake, where 13.4.2 carries `ruby:` and no
    # `rubygems:`), and the renderer keys off the nil to leave it out.
    required_rubygems = spec.required_rubygems_version
    rubygems = requirement_string(required_rubygems) if required_rubygems && required_rubygems.to_s != ">= 0"

    # And the same for "ruby:". A gem that constrains no Ruby version has
    # nothing to say in that field, and ">= 0" is not a quieter way of
    # saying nothing — it is a constraint the client then carries around.
    required_ruby = spec.required_ruby_version
    ruby = requirement_string(required_ruby) if required_ruby && required_ruby.to_s != ">= 0"

    {
      "dependencies" => deps,
      "ruby" => ruby,
      "rubygems" => rubygems,
      "checksum" => checksum,
      # Not part of any rendered line — compact_info_line_from_fields
      # ignores every key past the four it reads — but it is derived
      # from the same spec, so a repository that caches this hash caches
      # the publication date with it and CooldownRepository never has to
      # open the gem. Epoch seconds rather than a formatted string: an
      # integer survives a round trip through JSON without anybody having
      # to agree on a format first. Nil for a spec without a date, which
      # the reader then knows to treat as unknown rather than as 1970.
      "published_at" => spec.date&.to_i
    }
  end

  # Renders a line from a fields hash — freshly extracted or read back
  # from a cache, the bytes must come out the same either way, which is
  # why there is one renderer and compact_info_line goes through it.
  # Keys beyond the ones this reads are ignored, so a caller may keep
  # bookkeeping of its own (file sizes, mtimes) in the same hash.
  def self.compact_info_line_from_fields(version, fields)
    deps = fields.fetch("dependencies").map { |dep_name, req| "#{dep_name}:#{req}" }.join(",")

    # No space between the dependency list and the pipe, but one after the
    # version — which means a gem without dependencies gets "1.0.0 |...",
    # exactly what rubygems.org serves for such a gem.
    line = "#{version} #{deps}|checksum:#{fields.fetch("checksum")}"

    # "ruby:" is absent, not ">= 0", for a gem that constrains nothing —
    # the same rule "rubygems:" below already followed, and for the same
    # reason: rubygems.org omits the field and rubygems' own conformance
    # suite asks for the line without it. Read with [] rather than fetch()
    # so a fields hash assembled before this distinction existed still
    # renders; a nil there now means "no constraint" rather than "key
    # missing", which is what the sidecar format number is for.
    ruby = fields["ruby"]
    line << ",ruby:#{ruby}" if ruby

    # "rubygems:" comes after "ruby:" and before the "created_at:" that
    # rubygems.org appends and Paquette does not, and it is absent — not
    # empty, not ">= 0" — for a gem with no constraint. Fetched with [] and
    # not fetch() so a fields hash assembled by something other than
    # compact_info_fields still renders the line it would have rendered
    # before this field existed.
    rubygems = fields["rubygems"]
    line << ",rubygems:#{rubygems}" if rubygems

    line
  end

  # An already-rendered line with only its checksum replaced, for
  # repositories that serve rewritten gem files. Every other field still
  # describes the gem — a repack touches neither dependencies nor
  # requirements — so a wrapper may keep the line a sidecar cache already
  # paid for instead of re-deriving it from the spec. Lives here because
  # this class owns the line format: the one place that renders
  # "checksum:" is the one place allowed to find it again.
  #
  # The pattern cannot stray into a neighbouring field: no other field name
  # ends in "checksum" (the match is not anchored, but "ruby:" and
  # "rubygems:" share no suffix with it), and the value class [0-9a-f]
  # stops dead at the "," that ends the hex digest, so a requirement like
  # ">= 1.3.2" sitting after it is never in reach. sub, not gsub, so only
  # the first occurrence is touched even if a digest somehow repeated.
  def self.replace_checksum(line, checksum)
    line.sub(/checksum:[0-9a-f]+/) { "checksum:#{checksum}" }
  end

  # Gem::Requirement#to_s joins several clauses with ", " — but a comma
  # separates *dependencies* in this format, so within one dependency the
  # clauses are joined with "&" instead: ">= 1.0, < 3" becomes ">= 1.0&< 3".
  # The space inside a clause stays; rubygems.org keeps it too.
  #
  # The same join applies to "ruby:" and "rubygems:", which sit in the
  # comma-separated metadata segment for the same reason — see
  # CompactIndex::GemVersion#join_multiple, which rubygems.org renders with
  # and which uses one helper for all three.
  #
  # One divergence, noted rather than fixed here: join_multiple also sorts
  # the clauses, so rubygems.org renders ">= 1.3.2, < 4" as "< 4&>= 1.3.2"
  # where this renders it in the gemspec's own order. Nothing resolves
  # differently for it — a requirement is a set — and sorting would change
  # the bytes of every existing multi-clause dependency line, which is a
  # /versions digest shift for a corpus that has not changed. It belongs in
  # its own change, not smuggled into one about a missing field.
  def self.requirement_string(requirement)
    requirement.to_s.split(", ").join("&")
  end
end
