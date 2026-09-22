require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require "measurometer"
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
      #
      # `files_for:` is the per-package edition of `files:`, for content that
      # cannot be known before the tarball is looked at. Called with
      # (package_name, version, original_path); returns a {path => content}
      # hash to inject on top of `files:`, or nil — and nil means this package
      # does not participate: it is served byte for byte. Without `files_for:`
      # every tarball is personalized, which is what this class always did.
      # The caller keeps the two contracts spelled out on
      # GemServer::Personalizer: the returned content depends only on the
      # tarball and `personalization_key:`, and nil is a fact about the
      # package, never about the licensee.
      #
      # `cache_dir:` is where personalized tarballs and opt-out markers are
      # kept; the system temp directory is only a default, and an application
      # with a cache directory of its own should say so.
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {},
        package_json_extras: nil, files_for: nil, personalization_key: nil, cache_dir: nil)
        NpmRepacker.check_replacements!(magic_comment_replacements)
        super(repository)
        @license_key = license_key
        @magic_comment_replacements = magic_comment_replacements
        @files = files
        @package_json_extras = package_json_extras || {"paquette" => {"licenseKey" => license_key}}
        @files_for = files_for
        @personalization_key = personalization_key
        @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized_npm")
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

        Measurometer.instrument("paquette.npm_personalizer.dist_for") do
          personalized_path = package_file_path(package_name, version)
          next original_dist unless personalized_path && File.exist?(personalized_path)
          # A package files_for opted out of is served as it sits on disk, and
          # the repository's own hashes already describe that file.
          next original_dist if personalized_path == __getobj__.package_file_path(package_name, version)

          original_dist.merge(Tarball.integrity(personalized_path).transform_keys(&:to_s))
        end
      end

      # The underlying `dist` hashes would fail every install.
      # Every version has to be repacked and re-hashed before this document can
      # be handed out, so a personalized metadata read costs a whole package
      # where the plain one costs a cache lookup.
      def package_metadata(package_name)
        metadata = __getobj__.package_metadata(package_name)
        return nil unless metadata

        Measurometer.instrument("paquette.npm_personalizer.package_metadata") do
          versions = metadata["versions"].each_with_object({}) do |(version, doc), acc|
            acc[version] = doc.merge("dist" => dist_for(package_name, version))
          end

          metadata.merge("versions" => versions)
        end
      end

      private

      # Keyed by everything that goes INTO the package: two licensees never
      # share a file. The caches are consulted before the tarball is ever
      # opened — the first request per file pays the look inside, every one
      # after is two stat calls. See GemServer::Personalizer, whose scheme
      # this is.
      def personalize(original_path, package_name, version)
        stat = File.stat(original_path)
        filename = "#{File.basename(package_name)}-#{version}-#{cache_digest(package_name, version, stat)}.tgz"
        personalized_path = File.join(@cache_dir, filename)
        if File.exist?(personalized_path)
          Measurometer.increment_counter("paquette.npm_personalizer.cache_hit")
          return personalized_path
        end

        if @files_for
          marker = plain_marker_path(package_name, version, stat)
          return original_path if File.exist?(marker)

          dynamic_files = @files_for.call(package_name, version, original_path)
          if dynamic_files.nil?
            FileUtils.mkdir_p(@cache_dir)
            FileUtils.touch(marker)
            return original_path
          end
        else
          dynamic_files = {}
        end

        Measurometer.increment_counter("paquette.npm_personalizer.cache_miss")
        FileUtils.mkdir_p(@cache_dir)

        Measurometer.instrument("paquette.npm_personalizer.repack") do
          Dir.mktmpdir("paquette_personalize_npm") do |workdir|
            built = NpmRepacker.repack(original_path,
              package_json_extras: @package_json_extras,
              magic_comment_replacements: @magic_comment_replacements,
              files: @files.merge(dynamic_files),
              into: File.join(workdir, filename))

            FileUtils.mv(built, personalized_path)
          end
        end

        personalized_path
      end

      # The FULL package name — basename keying once served one scope's code as
      # another's. Stat identity, so a replaced tarball invalidates the cache
      # without re-hashing the corpus.
      def cache_digest(package_name, version, stat)
        Digest::SHA256.hexdigest([
          package_name,
          version,
          personalization_digest,
          stat.mtime.to_f,
          stat.size
        ].join("\0"))[0, 24]
      end

      # Where "this package carries nothing to personalize" is written down.
      # Keyed by the package and its source identity alone, never by the
      # licensee — whether a package participates is a fact about the package.
      def plain_marker_path(package_name, version, stat)
        digest = Digest::SHA256.hexdigest([
          package_name, version, stat.mtime.to_f, stat.size
        ].join("\0"))[0, 24]
        File.join(@cache_dir, "#{File.basename(package_name)}-#{version}-#{digest}.plain")
      end

      # Stable across processes, so a restart does not orphan the cache.
      def personalization_digest
        @personalization_digest ||= Digest::SHA256.hexdigest([
          @license_key,
          @magic_comment_replacements.sort.inspect,
          @files.sort.inspect,
          @package_json_extras.sort.inspect,
          @personalization_key.to_s
        ].join("\0"))[0, 16]
      end
    end
  end
end
