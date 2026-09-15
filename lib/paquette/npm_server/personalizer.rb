require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require_relative "npm_repository"
require_relative "../npm_repacker"
require_relative "../tarball"

module Paquette
  class NpmServer
    # Wraps an NPM repository and rewrites each served tarball on the fly to
    # embed the licensee's key. The counterpart of GemServer::Personalizer, with
    # the same options and the same caching rules.
    #
    # `files:` is a {path => content} hash written into every package this
    # personalizer serves — the path being relative to the package root, so
    # "LICENSE.txt" lands next to package.json. It is what a per-licensee
    # LICENSE file arrives through: the content is rendered by the caller, which
    # is the only party that knows who the licensee is, and handed over already
    # finished.
    #
    # `package_json_extras:` is the npm equivalent of `gemspec_extras`. It
    # defaults to a "paquette" key carrying the license key, which puts the key
    # somewhere a customer can find it without it having to appear in code.
    class Personalizer < SimpleDelegator
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {}, package_json_extras: nil)
        super(repository)
        @license_key = license_key
        @magic_comment_replacements = magic_comment_replacements
        @files = files
        @package_json_extras = package_json_extras || {"paquette" => {"licenseKey" => license_key}}
      end

      def package_file_path(package_name, version)
        original_path = __getobj__.package_file_path(package_name, version)
        return original_path unless original_path && File.exist?(original_path)

        personalize(original_path, package_name, version)
      end

      # The hashes npm will check the download against have to be the
      # personalized tarball's, because the personalized tarball is what npm
      # downloads. The tarball URL stays the repository's — personalization does
      # not move a package.
      def dist_for(package_name, version)
        original_dist = __getobj__.dist_for(package_name, version)
        return original_dist if original_dist.empty?

        personalized_path = package_file_path(package_name, version)
        return original_dist unless personalized_path && File.exist?(personalized_path)

        original_dist.merge(Tarball.integrity(personalized_path).transform_keys(&:to_s))
      end

      # Rebuilt rather than delegated, because the `dist` blocks inside it are
      # the whole point: a document carrying the underlying repository's hashes
      # would describe a tarball this personalizer never serves, and npm would
      # reject every install with an integrity failure.
      def package_metadata(package_name)
        metadata = __getobj__.package_metadata(package_name)
        return nil unless metadata

        versions = metadata["versions"].each_with_object({}) do |(version, doc), acc|
          acc[version] = doc.merge("dist" => dist_for(package_name, version))
        end

        metadata.merge("versions" => versions)
      end

      private

      # Keyed by everything that goes INTO the package, not by the package
      # alone. Two licensees downloading the same version at the same moment
      # must not be handed one file, because what is personalized into it is by
      # definition the other licensee's.
      #
      # It is also what makes repacking twice cheap: identical inputs produce a
      # byte-identical tarball, so the second request for the same licensee
      # finds the file already there — and the integrity published in the
      # metadata still describes it.
      def personalize(original_path, package_name, version)
        personalized_dir = File.join(Dir.tmpdir, "paquette_personalized_npm")
        FileUtils.mkdir_p(personalized_dir)

        filename = "#{File.basename(package_name)}-#{version}-#{personalization_digest}-#{source_digest(original_path)}.tgz"
        personalized_path = File.join(personalized_dir, filename)
        return personalized_path if File.exist?(personalized_path)

        # A directory we make here and take away here. The block form removes
        # exactly what it created, so nothing in this method deletes a path
        # somebody else chose.
        Dir.mktmpdir("paquette_personalize_npm") do |workdir|
          built = NpmRepacker.repack(original_path,
            package_json_extras: @package_json_extras,
            magic_comment_replacements: @magic_comment_replacements,
            files: @files,
            into: File.join(workdir, filename))

          FileUtils.mv(built, personalized_path)
        end

        personalized_path
      end

      # The identity of the tarball being personalized, so that replacing one on
      # disk — which the README offers as a way to publish — invalidates what
      # was built from it. Without this the cache would keep serving a repack of
      # a file that is no longer there, and the integrity published alongside it
      # would describe neither.
      #
      # Taken from the stat rather than from the contents because this runs on
      # every download and on every version of a metadata request, and re-hashing
      # a whole corpus of tarballs to discover that none of them moved is a poor
      # trade for a case that a tomb already prevents through the API.
      def source_digest(path)
        stat = File.stat(path)
        Digest::SHA256.hexdigest("#{stat.mtime.to_f}-#{stat.size}")[0, 12]
      end

      # Everything this personalizer would write into a package, as one short
      # hash. Stable across processes, so a restart does not orphan the cache.
      def personalization_digest
        @personalization_digest ||= Digest::SHA256.hexdigest([
          @license_key,
          @magic_comment_replacements.sort.inspect,
          @files.sort.inspect,
          @package_json_extras.sort.inspect
        ].join("\0"))[0, 16]
      end
    end
  end
end
