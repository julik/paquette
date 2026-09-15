require_relative "npm_repository"
require_relative "../tarball"
require "json"
require "tempfile"
require "time"

module Paquette
  class NpmServer
    # Repository implementation that reads NPM packages from a directory.
    #
    # Layout mirrors the gem side — one directory per package, tarballs inside
    # it — with one addition for scopes: "@acme/widgets" lives at
    # packages/npm/@acme/widgets/, so a scope is an ordinary directory holding
    # the packages that belong to it.
    #
    #   packages/npm/lodash/lodash-4.17.21.tgz
    #   packages/npm/@acme/widgets/widgets-1.0.0.tgz
    #   packages/npm/@acme/widgets/dist-tags.json
    class DirectoryNpmRepository < NpmRepository
      class PackageAlreadyExists < StandardError; end

      class InvalidPackage < StandardError; end

      class PackageNotFound < StandardError; end

      class PackageYanked < StandardError; end

      DIST_TAGS_FILE = "dist-tags.json"

      def initialize(packages_dir)
        @packages_dir = packages_dir
        FileUtils.mkdir_p(@packages_dir)
      end

      def package_names
        names = []
        each_child_dir(@packages_dir) do |path, basename|
          if NpmRepository.scoped?(basename)
            each_child_dir(path) { |_, scoped| names << "#{basename}/#{scoped}" }
          else
            names << basename
          end
        end
        names.sort
      end

      def package_versions
        package_names.flat_map do |package_name|
          versions_for_package(package_name).map { |version| [package_name, version] }
        end.sort
      end

      def versions_for_package(package_name)
        dir = package_dir(package_name)
        return [] unless dir && Dir.exist?(dir)

        basename = File.basename(package_name)
        versions = Dir.glob(File.join(dir, "*.tgz")).filter_map do |tarball_path|
          filename = File.basename(tarball_path, ".tgz")
          match = filename.match(/\A#{Regexp.escape(basename)}-(.+)\z/)
          match && match[1]
        end
        NpmRepository.sort_versions(versions)
      end

      def package_file_path(package_name, version)
        dir = package_dir(package_name)
        return nil unless dir

        File.join(dir, NpmRepository.tarball_filename(package_name, version))
      end

      def package_exists?(package_name, version)
        path = package_file_path(package_name, version)
        !!path && File.exist?(path)
      end

      def package_info(package_name, version)
        path = package_file_path(package_name, version)
        return nil unless path && File.exist?(path)

        cached(path) { Tarball.package_json(path) }
      end

      def package_dependencies(package_name, version)
        info = package_info(package_name, version)
        return {} unless info

        info["dependencies"] || {}
      end

      # The dist-tag map. Tags published alongside a tarball are persisted, but
      # "latest" is always recomputed from what is actually on disk: a tag file
      # naming a version that has since been yanked would point npm at a 404,
      # and dropping a tarball into the directory by hand — which the README
      # offers as a way to publish — never writes one at all.
      def dist_tags(package_name)
        versions = versions_for_package(package_name)
        return {} if versions.empty?

        stored = read_dist_tags(package_name).select { |_tag, version| versions.include?(version) }
        {"latest" => NpmRepository.max_release_version(versions)}.merge(stored)
      end

      def package_metadata(package_name)
        versions = versions_for_package(package_name)
        return nil if versions.empty?

        tags = dist_tags(package_name)
        latest_info = package_info(package_name, tags["latest"]) || {}

        version_docs = versions.each_with_object({}) do |version, docs|
          info = package_info(package_name, version)
          next unless info

          docs[version] = NpmRepository.version_doc(info, package_name, version, dist_for(package_name, version))
        end

        # The document-level fields npm and the registry UI read are taken from
        # the latest version's package.json, which is what a real registry does:
        # they describe the package as it stands now, not as its oldest release
        # described itself.
        {
          "_id" => package_name,
          "name" => package_name,
          "dist-tags" => tags,
          "versions" => version_docs,
          "time" => times_for(package_name, versions),
          "description" => latest_info["description"],
          "keywords" => latest_info["keywords"] || [],
          "license" => latest_info["license"],
          "author" => latest_info["author"],
          "maintainers" => latest_info["maintainers"] || [],
          "repository" => latest_info["repository"],
          "bugs" => latest_info["bugs"],
          "homepage" => latest_info["homepage"],
          "readme" => readme_for(package_name, tags["latest"]) || ""
        }.compact
      end

      # The `dist` block for one version, computed from the bytes on disk. The
      # hashes are what npm checks the download against, so they are taken from
      # the file rather than from anything the publisher asserted.
      def dist_for(package_name, version)
        path = package_file_path(package_name, version)
        return {} unless path && File.exist?(path)

        cached(path, :dist) do
          Tarball.integrity(path).transform_keys(&:to_s).merge(
            "tarball" => NpmRepository.tarball_path(package_name, version)
          )
        end
      end

      # Stores a tarball from its raw binary contents. Returns the parsed
      # package.json. Raises InvalidPackage when the payload is not a readable
      # npm tarball, PackageYanked when that version was unpublished before, and
      # PackageAlreadyExists when it is already on disk — npm's own registry
      # refuses a republish of an existing version, and a client that silently
      # got a different tarball for a version it already has in a lockfile would
      # have no way to notice.
      def add_package(binary_data, dist_tags: {})
        raise InvalidPackage, "Empty package payload" if binary_data.nil? || binary_data.empty?

        tmp = Tempfile.new(["paquette_publish", ".tgz"])
        begin
          tmp.binmode
          tmp.write(binary_data)
          tmp.close

          info = begin
            Tarball.package_json(tmp.path)
          rescue Tarball::MalformedTarball => e
            raise InvalidPackage, "Could not read package: #{e.message}"
          end
          raise InvalidPackage, "Package contains no package.json" if info.nil?

          name = info["name"].to_s
          version = info["version"].to_s
          raise InvalidPackage, "package.json has no name" if name.empty?
          raise InvalidPackage, "package.json has no version" if version.empty?
          raise InvalidPackage, "Invalid package name: #{name}" unless NpmRepository.valid_package_name?(name)

          raise PackageYanked, "#{name}@#{version} was unpublished and cannot be republished" if tomb_exists?(name, version)
          raise PackageAlreadyExists, "#{name}@#{version} already exists" if package_exists?(name, version)

          destination = package_file_path(name, version)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.mv(tmp.path, destination)
          FileUtils.chmod(0o644, destination)

          write_dist_tags(name, read_dist_tags(name).merge(dist_tags.select { |_tag, v| v == version }))

          info
        ensure
          tmp.close unless tmp.closed?
          File.unlink(tmp.path) if File.exist?(tmp.path)
        end
      end

      # Unpublishes one version by renaming its tarball to .tgz.tomb, exactly as
      # the gem side yanks. The tomb is what stops the same version being
      # republished with different contents later.
      def yank_package(package_name, version)
        path = package_file_path(package_name, version)
        raise PackageNotFound, "#{package_name}@#{version} not found" unless path && File.exist?(path)

        FileUtils.mv(path, tomb_file_path(package_name, version))
        drop_dist_tags_for(package_name, version)
        nil
      end

      # Points one dist-tag at a version, as `npm dist-tag add` and
      # `npm publish --tag` do. "latest" is not stored — it is always the newest
      # version on disk — so pointing it elsewhere is refused rather than
      # silently ignored.
      def write_dist_tag(package_name, tag, version)
        raise InvalidPackage, "latest always follows the newest published version" if tag.to_s == "latest"
        raise PackageNotFound, "#{package_name}@#{version} not found" unless package_exists?(package_name, version)

        write_dist_tags(package_name, read_dist_tags(package_name).merge(tag.to_s => version))
        dist_tags(package_name)
      end

      def tomb_file_path(package_name, version)
        path = package_file_path(package_name, version)
        path && path + ".tomb"
      end

      def tomb_exists?(package_name, version)
        path = tomb_file_path(package_name, version)
        !!path && File.exist?(path)
      end

      private

      # nil for anything that is not a package name, so that a request for
      # "../../etc" resolves to no package rather than to a path.
      def package_dir(package_name)
        return nil unless NpmRepository.valid_package_name?(package_name)

        File.join(@packages_dir, *package_name.split("/"))
      end

      def each_child_dir(dir)
        Dir.children(dir).sort.each do |basename|
          path = File.join(dir, basename)
          yield path, basename if File.directory?(path)
        end
      rescue Errno::ENOENT
        nil
      end

      # Publication times come from the tarball's mtime. It is the only honest
      # answer a directory of files can give, and unlike Time.now it does not
      # make every request return a different document — which would defeat any
      # caching a client does and make the metadata look perpetually changed.
      def times_for(package_name, versions)
        times = {}
        mtimes = versions.filter_map do |version|
          path = package_file_path(package_name, version)
          next unless path && File.exist?(path)

          mtime = File.mtime(path).utc
          times[version] = mtime.iso8601
          mtime
        end

        unless mtimes.empty?
          times["created"] = mtimes.min.iso8601
          times["modified"] = mtimes.max.iso8601
        end
        times
      end

      def readme_for(package_name, version)
        path = package_file_path(package_name, version)
        return nil unless path && File.exist?(path)

        cached(path, :readme) do
          entry = Tarball.each_entry(path).find do |candidate|
            candidate.name.count("/") == 1 &&
              File.basename(candidate.name).match?(/\AREADME(\.md|\.markdown|\.txt)?\z/i)
          end
          entry&.content
        end
      end

      def dist_tags_path(package_name)
        dir = package_dir(package_name)
        dir && File.join(dir, DIST_TAGS_FILE)
      end

      def read_dist_tags(package_name)
        path = dist_tags_path(package_name)
        return {} unless path && File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def write_dist_tags(package_name, tags)
        path = dist_tags_path(package_name)
        return unless path

        if tags.empty?
          File.unlink(path) if File.exist?(path)
        else
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(tags))
        end
      end

      def drop_dist_tags_for(package_name, version)
        tags = read_dist_tags(package_name).reject { |_tag, tagged| tagged == version }
        write_dist_tags(package_name, tags)
      end

      # Opening a tarball to read one file out of it is the expensive part of
      # rendering metadata, and a metadata request does it once per version. The
      # cache is keyed on the identity of the file rather than its path alone,
      # so a republished or personalized tarball at a path we have seen before
      # is read again rather than answered from a stale entry.
      def cached(path, aspect = :info)
        stat = File.stat(path)
        key = [path, aspect, stat.mtime.to_f, stat.size]
        @cache ||= {}
        return @cache[key] if @cache.key?(key)

        # Bounded, because a long-lived server serving a large corpus would
        # otherwise hold every package.json it has ever read.
        @cache.shift if @cache.size >= 1024
        @cache[key] = yield
      end
    end
  end
end
