require_relative "repository"
require "rubygems/package"

module Paquette
  # Repository implementation that reads gems from a directory
  class DirectoryRepository < Repository
    def initialize(gems_dir)
      @gems_dir = gems_dir
      FileUtils.mkdir_p(@gems_dir)
    end

    def gem_names
      Dir.glob(File.join(@gems_dir, "*.gem")).map do |gem_path|
        gem_name = File.basename(gem_path, ".gem")
        if (match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/))
          match[1]
        end
      end.compact.uniq.sort
    end

    def gem_versions
      versions = []
      Dir.glob(File.join(@gems_dir, "*.gem")).each do |gem_path|
        gem_name = File.basename(gem_path, ".gem")
        if (match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/))
          name, version = match[1], match[2]
          versions << [name, version]
        end
      end
      versions.sort
    end

    def versions_for_gem(gem_name)
      versions = []
      Dir.glob(File.join(@gems_dir, "#{gem_name}-*.gem")).each do |gem_path|
        filename = File.basename(gem_path, ".gem")
        if (match = filename.match(/^#{Regexp.escape(gem_name)}-(\d+\.\d+\.\d+.*)$/))
          versions << match[1]
        end
      end
      versions.sort
    end

    def gem_file_path(gem_name, version)
      File.join(@gems_dir, "#{gem_name}-#{version}.gem")
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

      versions.map do |version|
        "#{gem_name},#{version},ruby,"
      end
    end
  end
end
