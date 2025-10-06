require_relative "npm_repository"
require "json"

module Paquette
  class NpmServer
    # Repository implementation that reads NPM packages from a directory
    class DirectoryNpmRepository < NpmRepository
      def initialize(packages_dir)
        @packages_dir = packages_dir
        FileUtils.mkdir_p(@packages_dir)
      end

      def package_names
        Dir.glob(File.join(@packages_dir, "*")).select { |path| File.directory?(path) }.map do |package_path|
          File.basename(package_path)
        end.sort
      end

      def package_versions
        versions = []
        package_names.each do |package_name|
          versions_for_package(package_name).each do |version|
            versions << [package_name, version]
          end
        end
        versions.sort
      end

      def versions_for_package(package_name)
        package_dir = File.join(@packages_dir, package_name)
        return [] unless Dir.exist?(package_dir)

        Dir.glob(File.join(package_dir, "*.tgz")).map do |tgz_path|
          filename = File.basename(tgz_path, ".tgz")
          if (match = filename.match(/^#{Regexp.escape(package_name)}-(\d+\.\d+\.\d+.*)$/))
            match[1]
          end
        end.compact.sort
      end

      def package_file_path(package_name, version)
        File.join(@packages_dir, package_name, "#{package_name}-#{version}.tgz")
      end

      def package_exists?(package_name, version)
        File.exist?(package_file_path(package_name, version))
      end

      def package_info(package_name, version)
        package_file = package_file_path(package_name, version)
        return nil unless File.exist?(package_file)

        # For now, return basic package info
        # In a real implementation, you'd extract the package.json from the .tgz file
        {
          name: package_name,
          version: version,
          description: "Package #{package_name} version #{version}",
          main: "index.js",
          scripts: {},
          dependencies: {},
          devDependencies: {}
        }
      end

      def package_dependencies(package_name, version)
        info = package_info(package_name, version)
        return {} unless info

        (info[:dependencies] || {}).merge(info[:devDependencies] || {})
      end

      def package_metadata(package_name)
        versions = versions_for_package(package_name)
        return nil if versions.empty?

        # Get the latest version
        latest_version = versions.max_by { |v| Gem::Version.new(v) }

        metadata = {
          name: package_name,
          versions: {},
          "dist-tags": {
            latest: latest_version
          },
          time: {},
          maintainers: [],
          description: "Package #{package_name}",
          keywords: [],
          license: "MIT",
          repository: {},
          bugs: {},
          homepage: "",
          readme: "",
          readmeFilename: "README.md"
        }

        # Add version-specific metadata
        versions.each do |version|
          info = package_info(package_name, version)
          next unless info

          metadata[:versions][version] = {
            name: package_name,
            version: version,
            description: info[:description],
            main: info[:main],
            scripts: info[:scripts] || {},
            dependencies: info[:dependencies] || {},
            devDependencies: info[:devDependencies] || {},
            dist: {
              shasum: "dummy-sha", # In real implementation, calculate actual shasum
              tarball: "#{package_name}/#{package_name}-#{version}.tgz"
            }
          }

          metadata[:time][version] = Time.now.iso8601
        end

        metadata[:time][:created] = Time.now.iso8601
        metadata[:time][:modified] = Time.now.iso8601

        metadata
      end
    end
  end
end
