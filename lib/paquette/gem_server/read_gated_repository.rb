require "delegate"

module Paquette
  class GemServer
    # Wraps a gem repository and filters every read through an entitler block.
    # The block receives `name:` (and optionally `version:`) and returns truthy
    # when the caller is allowed to see that gem/version. Non-entitled gems
    # disappear from listings, return nil paths, and report as non-existent.
    #
    # Writes (add_gem, yank_gem) always raise WriteNotAllowed. Gating a read
    # path implies the caller is not the right party to mutate the corpus —
    # if you want a more nuanced story (e.g. read-gated but write-allowed
    # for authenticated admins), write a different wrapper with its own
    # policy. This one is deliberately opinionated: gating reads blocks
    # writes, full stop.
    class ReadGatedRepository < SimpleDelegator
      class WriteNotAllowed < StandardError; end

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
        return [] unless @entitler.call(name: gem_name)

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
        else
          false
        end
      end

      def add_gem(*)
        raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
      end

      def yank_gem(*)
        raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
      end
    end
  end
end
