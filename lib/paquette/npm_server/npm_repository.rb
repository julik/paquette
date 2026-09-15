require "json"
require "fileutils"

module Paquette
  class NpmServer
    # Abstract base class for NPM package repositories.
    #
    # The contract mirrors GemRepository: reads return plain data, writes raise
    # on refusal, and every method takes the package name as npm spells it —
    # "lodash" or "@acme/widgets".
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

      # Returns the tarball path for a specific package and version
      def package_file_path(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_file_path"
      end

      # Returns whether a tarball exists for the given name and version
      def package_exists?(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_exists?"
      end

      # Returns the parsed package.json for a specific package and version
      def package_info(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_info"
      end

      # Returns dependencies for a specific package and version
      def package_dependencies(package_name, version)
        raise NotImplementedError, "Subclasses must implement package_dependencies"
      end

      # Returns the full package metadata document in NPM registry format
      def package_metadata(package_name)
        raise NotImplementedError, "Subclasses must implement package_metadata"
      end

      # Returns the dist-tag => version map for a package
      def dist_tags(package_name)
        raise NotImplementedError, "Subclasses must implement dist_tags"
      end

      # Stores a tarball from its raw binary contents
      def add_package(binary_data, dist_tags: {})
        raise NotImplementedError, "Subclasses must implement add_package"
      end

      # Removes one version of a package
      def yank_package(package_name, version)
        raise NotImplementedError, "Subclasses must implement yank_package"
      end

      # The path under which a tarball is served, as it appears in
      # `dist.tarball` before the server makes it absolute.
      #
      # This is the shape every real registry uses — /@acme/widgets/-/widgets-1.0.0.tgz,
      # with the scope kept on the package but dropped from the filename. npm
      # does not parse the URL, it follows it, but lockfiles record it verbatim
      # and tooling that rewrites registry hosts assumes this layout.
      def self.tarball_path(package_name, version)
        "/#{package_name}/-/#{File.basename(package_name)}-#{version}.tgz"
      end

      # The filename a tarball is stored under, which drops the scope: a scoped
      # package already lives in a directory named for its scope.
      def self.tarball_filename(package_name, version)
        "#{File.basename(package_name)}-#{version}.tgz"
      end

      def self.scoped?(package_name)
        package_name.to_s.start_with?("@")
      end

      # npm's own rules, tightened: one optional @scope segment, then the name.
      # Anything that could climb out of the packages directory — a "..", an
      # absolute path, a stray separator — is not a package name here.
      SEGMENT = /\A[a-z0-9][a-z0-9._-]*\z/
      def self.valid_package_name?(package_name)
        name = package_name.to_s
        return false if name.empty? || name.length > 214

        if scoped?(name)
          scope, _, rest = name[1..].partition("/")
          !rest.empty? && scope.match?(SEGMENT) && rest.match?(SEGMENT)
        else
          name.match?(SEGMENT)
        end
      end

      # Sorting versions is done here rather than with Gem::Version because the
      # two schemes disagree in exactly the place that matters. Gem::Version
      # reads "1.0.0-beta.1" by rewriting the dash to ".pre.", and it rejects
      # the "+build" metadata semver allows outright — so a corpus containing
      # one prerelease could pick the wrong `latest`, or raise while listing.
      def self.sort_versions(versions)
        versions.sort { |a, b| compare_versions(a, b) }
      end

      def self.max_version(versions)
        sort_versions(versions).last
      end

      def self.prerelease?(version)
        !split_version(version)[1].empty?
      end

      # What "latest" means, which is not the same as the highest version.
      #
      # 2.0.0-beta.1 sorts above 1.2.0 and npm would happily install it, but a
      # registry that points latest at it hands every `npm install pkg` a
      # prerelease. npm's own registry never does that: latest follows the
      # newest stable release, and falls back to a prerelease only when the
      # package has never had a stable one.
      def self.max_release_version(versions)
        stable = versions.reject { |version| prerelease?(version) }
        max_version(stable.empty? ? versions : stable)
      end

      # Semver precedence: numeric release parts compare numerically, a version
      # with a prerelease is *lower* than the same version without one, and
      # build metadata is ignored entirely.
      def self.compare_versions(a, b)
        release_a, pre_a = split_version(a)
        release_b, pre_b = split_version(b)

        by_release = release_a <=> release_b
        return by_release unless by_release.zero?

        return 0 if pre_a.empty? && pre_b.empty?
        return 1 if pre_a.empty?
        return -1 if pre_b.empty?

        compare_prerelease(pre_a, pre_b)
      end

      def self.split_version(version)
        core, _, prerelease = version.to_s.split("+").first.to_s.partition("-")
        release = core.split(".").map { |part| part.to_i }
        # Pad so that "1.0" and "1.0.0" compare equal rather than by length.
        release += [0] * [0, 3 - release.length].max
        [release, prerelease.empty? ? [] : prerelease.split(".")]
      end

      def self.compare_prerelease(a, b)
        a.zip(b).each do |left, right|
          # A longer prerelease chain wins when the shared prefix is equal:
          # 1.0.0-alpha < 1.0.0-alpha.1
          return 1 if right.nil?

          numeric_left = left.match?(/\A\d+\z/)
          numeric_right = right.match?(/\A\d+\z/)

          result = if numeric_left && numeric_right
            left.to_i <=> right.to_i
          elsif numeric_left
            -1 # numeric identifiers always have lower precedence
          elsif numeric_right
            1
          else
            left <=> right
          end
          return result unless result.zero?
        end
        a.length <=> b.length
      end

      # One entry of a metadata document's `versions` map: the package's own
      # package.json, plus the `dist` block npm verifies the download against.
      #
      # The package.json is passed through whole rather than cherry-picked.
      # npm reads `bin`, `engines`, `peerDependencies`, `exports`, `os`, `cpu`
      # and more out of this document to decide what to install and how to link
      # it, and a registry that publishes a curated subset is a registry that
      # silently breaks whichever field it forgot.
      def self.version_doc(package_json, package_name, version, dist)
        package_json.merge(
          "name" => package_name,
          "version" => version,
          "_id" => "#{package_name}@#{version}",
          "dist" => dist
        )
      end
    end
  end
end
