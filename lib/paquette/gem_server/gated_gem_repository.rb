require "delegate"

module Paquette
  class GemServer
    class GatedGemRepository < SimpleDelegator
      def initialize(repository, &entitler)
        super(repository)
        @entitler = entitler
      end

      def gem_names
        super.select { |name| @entitler.call(name: name) }
      end

      def gem_versions
        super.select do |gem_name, version|
          @entitler.call(name: gem_name, version: version)
        end
      end

      def versions_for_gem(gem_name)
        return [] unless @entitler.call(name: gem_name)
        super.select do |version|
          @entitler.call(name: gem_name, version: version)
        end
      end

      def gem_file_path(gem_name, version)
        if @entitler.call(name: gem_name, version: version)
          super
        end
      end

      def compact_info(gem_name)
        return nil unless @entitler.call(name: gem_name)

        # Get the compact info from the underlying repository, but filter by entitled versions
        all_info = super
        return all_info unless all_info.is_a?(Array)

        all_info.select do |line|
          version = line.split(" ")[0]
          @entitler.call(name: gem_name, version: version)
        end
      end

      def gem_exists?(gem_name, version)
        if @entitler.call(name: gem_name, version: version)
          super
        end
      end
    end
  end
end
