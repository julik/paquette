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
    end
  end
end
