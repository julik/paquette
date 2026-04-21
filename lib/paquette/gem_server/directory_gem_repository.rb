require_relative "gem_repository"
require "rubygems/package"
require "tempfile"

module Paquette
  class GemServer
    # Repository implementation that reads gems from a directory
    class DirectoryGemRepository < GemRepository
      class GemAlreadyExists < StandardError; end

      class InvalidGem < StandardError; end

      class GemNotFound < StandardError; end

      class GemYanked < StandardError; end

      def initialize(gems_dir)
        @gems_dir = gems_dir
        FileUtils.mkdir_p(@gems_dir)
      end

      # Persists a .gem file from its raw binary contents. Returns the parsed
      # spec on success. Raises InvalidGem when the payload can't be opened as
      # a gem, or GemAlreadyExists if the name+version is already on disk.
      def add_gem(binary_data)
        raise InvalidGem, "Empty gem payload" if binary_data.nil? || binary_data.empty?

        tmp = Tempfile.new(["paquette_push", ".gem"])
        tmp.binmode
        tmp.write(binary_data)
        tmp.close

        spec = begin
          Gem::Package.new(tmp.path).spec
        rescue Gem::Package::Error, StandardError => e
          raise InvalidGem, "Could not read gem: #{e.message}"
        end

        name = spec.name
        version = spec.version.to_s
        raise GemYanked, "#{name}-#{version} was yanked and cannot be republished" if tomb_exists?(name, version)
        raise GemAlreadyExists, "#{name}-#{version} already exists" if gem_exists?(name, version)

        dest_dir = File.join(@gems_dir, name)
        FileUtils.mkdir_p(dest_dir)
        FileUtils.mv(tmp.path, gem_file_path(name, version))

        spec
      ensure
        tmp&.close unless tmp&.closed?
        File.unlink(tmp.path) if tmp && File.exist?(tmp.path)
      end

      # Yanks a gem by renaming its .gem file to .gem.tomb. The tomb prevents
      # the same name+version from being re-pushed later. Raises GemNotFound
      # when the gem was never present or already yanked.
      def yank_gem(gem_name, version)
        gem_path = gem_file_path(gem_name, version)
        raise GemNotFound, "#{gem_name}-#{version} not found" unless File.exist?(gem_path)

        FileUtils.mv(gem_path, tomb_file_path(gem_name, version))
        nil
      end

      def tomb_file_path(gem_name, version)
        gem_file_path(gem_name, version) + ".tomb"
      end

      def tomb_exists?(gem_name, version)
        File.exist?(tomb_file_path(gem_name, version))
      end

      def gem_names
        Dir.glob(File.join(@gems_dir, "*")).select { |path| File.directory?(path) }.map do |package_path|
          File.basename(package_path)
        end.sort
      end

      def gem_versions
        versions = []
        gem_names.each do |gem_name|
          versions_for_gem(gem_name).each do |version|
            versions << [gem_name, version]
          end
        end
        versions.sort
      end

      def versions_for_gem(gem_name)
        gem_dir = File.join(@gems_dir, gem_name)
        return [] unless Dir.exist?(gem_dir)

        Dir.glob(File.join(gem_dir, "*.gem")).map do |gem_path|
          filename = File.basename(gem_path, ".gem")
          if (match = filename.match(/^#{Regexp.escape(gem_name)}-(\d+\.\d+\.\d+.*)$/))
            match[1]
          end
        end.compact.sort
      end

      def gem_file_path(gem_name, version)
        File.join(@gems_dir, gem_name, "#{gem_name}-#{version}.gem")
      end

      def gem_exists?(gem_name, version)
        File.exist?(gem_file_path(gem_name, version))
      end

      def gem_spec(gem_name, version)
        gem_file = gem_file_path(gem_name, version)
        return nil unless File.exist?(gem_file)

        pkg = Gem::Package.new(gem_file)
        pkg.spec
      end

      def gem_dependencies(gem_name, version)
        spec = gem_spec(gem_name, version)
        return [] unless spec

        # Only include runtime dependencies, not development dependencies
        runtime_deps = spec.dependencies.select { |dep| dep.type == :runtime }
        runtime_deps.map do |dep|
          {
            name: dep.name,
            requirements: dep.requirement.to_s
          }
        end
      end

      def compact_info(gem_name)
        versions = versions_for_gem(gem_name)
        return [] if versions.empty?

        require "digest"

        versions.map do |version|
          spec = gem_spec(gem_name, version)
          next unless spec

          # Calculate SHA256 checksum of the gem file
          gem_file = gem_file_path(gem_name, version)
          checksum = Digest::SHA256.file(gem_file).hexdigest

          # Get required Ruby version from gemspec
          ruby_version = spec.required_ruby_version&.to_s || ">= 0"

          # Format: version |checksum:sha256_checksum,ruby:required_ruby_version
          "#{version} |checksum:#{checksum},ruby:#{ruby_version}"
        end.compact
      end
    end
  end
end
