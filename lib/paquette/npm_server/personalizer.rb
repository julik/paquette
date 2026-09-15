require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require_relative "npm_repository"
require_relative "../npm_repacker"
require_relative "../tarball"

module Paquette
  class NpmServer
    # Rewrites each served tarball on the fly to embed the licensee's key;
    # counterpart of GemServer::Personalizer.
    class Personalizer < SimpleDelegator
      # Checked here as well as in the repacker so a bad pair is refused where
      # the stack is built, rather than on the first customer download.
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {}, package_json_extras: nil)
        NpmRepacker.check_replacements!(magic_comment_replacements)
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

      # The hashes must be the personalized tarball's; the URL stays the repository's.
      def dist_for(package_name, version)
        original_dist = __getobj__.dist_for(package_name, version)
        return original_dist if original_dist.empty?

        personalized_path = package_file_path(package_name, version)
        return original_dist unless personalized_path && File.exist?(personalized_path)

        original_dist.merge(Tarball.integrity(personalized_path).transform_keys(&:to_s))
      end

      # The underlying `dist` hashes would fail every install.
      def package_metadata(package_name)
        metadata = __getobj__.package_metadata(package_name)
        return nil unless metadata

        versions = metadata["versions"].each_with_object({}) do |(version, doc), acc|
          acc[version] = doc.merge("dist" => dist_for(package_name, version))
        end

        metadata.merge("versions" => versions)
      end

      private

      # Keyed by everything that goes INTO the package: two licensees never share a file.
      def personalize(original_path, package_name, version)
        personalized_dir = File.join(Dir.tmpdir, "paquette_personalized_npm")
        FileUtils.mkdir_p(personalized_dir)

        filename = "#{File.basename(package_name)}-#{version}-#{cache_digest(package_name, version, original_path)}.tgz"
        personalized_path = File.join(personalized_dir, filename)
        return personalized_path if File.exist?(personalized_path)

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

      # The FULL package name — basename keying once served one scope's code as
      # another's. Stat identity, so a replaced tarball invalidates the cache
      # without re-hashing the corpus.
      def cache_digest(package_name, version, original_path)
        stat = File.stat(original_path)
        Digest::SHA256.hexdigest([
          package_name,
          version,
          personalization_digest,
          stat.mtime.to_f,
          stat.size
        ].join("\0"))[0, 24]
      end

      # Stable across processes, so a restart does not orphan the cache.
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
