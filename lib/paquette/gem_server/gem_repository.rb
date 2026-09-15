require "json"
require "fileutils"

module Paquette
  class GemServer
    # Abstract base class for gem repositories
    class GemRepository
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

      # Returns compact info for a specific gem (all versions)
      def compact_info(gem_name)
        raise NotImplementedError, "Subclasses must implement compact_info"
      end

      # One line of an /info/ file, in the compact index format:
      #
      #   VERSION DEP:REQ,DEP:REQ|checksum:SHA256,ruby:REQ
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

        {
          "dependencies" => deps,
          "ruby" => spec.required_ruby_version&.to_s || ">= 0",
          "checksum" => checksum
        }
      end

      # Renders a line from a fields hash — freshly extracted or read back
      # from a cache, the bytes must come out the same either way, which is
      # why there is one renderer and compact_info_line goes through it.
      # Keys beyond the three this reads are ignored, so a caller may keep
      # bookkeeping of its own (file sizes, mtimes) in the same hash.
      def self.compact_info_line_from_fields(version, fields)
        deps = fields.fetch("dependencies").map { |dep_name, req| "#{dep_name}:#{req}" }.join(",")

        # No space between the dependency list and the pipe, but one after the
        # version — which means a gem without dependencies gets "1.0.0 |...",
        # exactly what rubygems.org serves for such a gem.
        "#{version} #{deps}|checksum:#{fields.fetch("checksum")},ruby:#{fields.fetch("ruby")}"
      end

      # Gem::Requirement#to_s joins several clauses with ", " — but a comma
      # separates *dependencies* in this format, so within one dependency the
      # clauses are joined with "&" instead: ">= 1.0, < 3" becomes ">= 1.0&< 3".
      # The space inside a clause stays; rubygems.org keeps it too.
      def self.requirement_string(requirement)
        requirement.to_s.split(", ").join("&")
      end
    end
  end
end
