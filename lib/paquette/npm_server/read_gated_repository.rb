require "delegate"
require_relative "npm_repository"

module Paquette
  class NpmServer
    # Wraps an NPM repository and filters every read through an entitler block.
    # The block receives `name:` (and optionally `version:`) and returns truthy
    # when the caller is allowed to see that package/version. Non-entitled
    # packages disappear from listings, return nil paths, and report as
    # non-existent.
    #
    # Writes (add_package, yank_package) always raise WriteNotAllowed, on the
    # same reasoning as the gem side's ReadGatedRepository: gating a read path
    # says this caller is not the right party to mutate the corpus. A more
    # nuanced policy belongs in a different wrapper.
    class ReadGatedRepository < SimpleDelegator
      class WriteNotAllowed < StandardError; end

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

      # false rather than nil. The callers treat this as a boolean and one of
      # them puts it straight into a response, so a nil here is a nil the rest
      # of the server has to keep apologising for.
      def package_exists?(package_name, version)
        if @entitler.call(name: package_name, version: version)
          !!super
        else
          false
        end
      end

      def package_info(package_name, version)
        if @entitler.call(name: package_name, version: version)
          super
        end
      end

      def package_dependencies(package_name, version)
        if @entitler.call(name: package_name, version: version)
          super
        else
          {}
        end
      end

      def dist_tags(package_name)
        return {} unless @entitler.call(name: package_name)

        entitled = versions_for_package(package_name)
        tags = super.select { |_tag, version| entitled.include?(version) }
        # "latest" has to keep pointing somewhere installable: if the newest
        # release is outside this caller's entitlement, their latest is the
        # newest one that is inside it. Without this, `npm install pkg` resolves
        # to a version the very next request refuses to serve.
        tags = tags.merge("latest" => NpmRepository.max_release_version(entitled)) if entitled.any?
        tags
      end

      def package_metadata(package_name)
        return nil unless @entitler.call(name: package_name)

        metadata = super
        return metadata unless metadata

        entitled = versions_for_package(package_name)
        # A package whose every version is gated away does not exist as far as
        # this caller is concerned — an empty `versions` map would otherwise be
        # served as a real package that happens to be uninstallable.
        return nil if entitled.empty?

        # The repository contract does not promise these keys, so a custom
        # NpmRepository that renders a leaner document is filtered rather than
        # crashed on.
        versions = metadata["versions"].is_a?(Hash) ? metadata["versions"].slice(*entitled) : {}

        metadata.merge(
          "versions" => versions,
          "time" => entitled_times(metadata["time"], entitled),
          "dist-tags" => dist_tags(package_name)
        )
      end

      # created/modified describe the corpus, and the corpus is not what this
      # caller can see — carried over unchanged they report the publication
      # dates of versions being withheld. They are recomputed from the entitled
      # versions instead.
      def entitled_times(times, entitled)
        return {} unless times.is_a?(Hash)

        entitled_times = times.slice(*entitled)
        return entitled_times if entitled_times.empty?

        stamps = entitled_times.values.sort
        entitled_times.merge("created" => stamps.first, "modified" => stamps.last)
      end

      def add_package(*, **)
        raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
      end

      def yank_package(*, **)
        raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
      end

      def write_dist_tag(*, **)
        raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
      end
    end

    # The name this wrapper had before it grew a write policy and a matching
    # name on the gem side. Kept so existing stacks keep building.
    GatedNpmRepository = ReadGatedRepository
  end
end
