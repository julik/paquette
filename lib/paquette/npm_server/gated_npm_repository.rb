require "delegate"

module Paquette
  class NpmServer
    class GatedNpmRepository < SimpleDelegator
      def initialize(repository, &entitler)
        super(repository)
        @entitler = entitler
      end

      def package_names
        super.select { |name| @entitler.call(name: name) }
      end

      def package_versions
        super.select do |package_name, version|
          @entitler.call(name: package_name, version: version)
        end
      end

      def versions_for_package(package_name)
        return [] unless @entitler.call(name: package_name)
        super.select do |version|
          @entitler.call(name: package_name, version: version)
        end
      end

      def package_file_path(package_name, version)
        if @entitler.call(name: package_name, version: version)
          super
        end
      end

      def package_metadata(package_name)
        return nil unless @entitler.call(name: package_name)

        # Get the metadata from the underlying repository, but filter by entitled versions
        metadata = super
        return metadata unless metadata

        # Filter versions based on entitlements
        entitled_versions = versions_for_package(package_name)
        
        # Update the versions hash to only include entitled versions
        metadata[:versions] = metadata[:versions].select { |version, _| entitled_versions.include?(version) }
        
        # Update time entries to only include entitled versions
        metadata[:time] = metadata[:time].select { |version, _| entitled_versions.include?(version) }
        
        # Update dist-tags to use the latest entitled version
        if entitled_versions.any?
          latest_entitled = entitled_versions.max_by { |v| Gem::Version.new(v) }
          metadata[:"dist-tags"][:latest] = latest_entitled
        end

        metadata
      end

      def package_exists?(package_name, version)
        if @entitler.call(name: package_name, version: version)
          super
        end
      end
    end
  end
end
