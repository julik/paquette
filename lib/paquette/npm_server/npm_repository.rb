require "json"
require "fileutils"

module Paquette
  class NpmServer
    # Abstract base class for NPM package repositories
    class NpmRepository
      def initialize
        raise NotImplementedError, "NpmRepository is an abstract class"
      end

      # Returns an array of package names available in the repository
      def package_names
        raise NotImplementedError, "Subclasses must implement package_names"
      end

      # Returns an array of [name, version] pairs for all packages
      def package_versions
        raise NotImplementedError, "Subclasses must implement package_versions"
      end

      # Returns an array of versions for a specific package
      def versions_for_package(package_name)
        raise NotImplementedError, "Subclasses must implement versions_for_package"
      end

      # Returns the package file path for a specific package and version
      def package_file_path(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_file_path"
      end

      # Returns whether a package file exists for the given name and version
      def package_exists?(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_exists?"
      end

      # Returns the package.json for a specific package and version
      def package_info(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_info"
      end

      # Returns dependencies for a specific package and version
      def package_dependencies(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_dependencies"
      end

      # Returns the full package metadata for NPM registry format
      def package_metadata(package_name)
        raise NotImplementedError, "Subclasses must implement package_metadata"
      end
    end
  end
end
