require "delegate"
require "fileutils"
require "digest"

module Paquette
  class GemServer
    class Personalizer < SimpleDelegator
      # `files:` is a {path => content} hash written into every gem this
      # personalizer serves, exactly as GemRepacker takes it. It is what a
      # per-licensee LICENSE file arrives through: the content is rendered by
      # the caller, which is the only party that knows who the licensee is, and
      # handed over already finished.
      #
      # Unlike `magic_comment_replacements`, which rewrites a line inside
      # **/*.rb, this puts whole files in and adds them to spec.files — so it
      # can carry a .txt, which a magic comment never could.
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {})
        super(repository)
        @license_key = license_key
        @magic_comment_replacements = magic_comment_replacements
        @files = files
      end

      def gem_file_path(gem_name, version)
        original_path = __getobj__.gem_file_path(gem_name, version)
        return original_path unless File.exist?(original_path)

        # Create personalized version
        personalize_gem(original_path, gem_name, version)
      end

      def compact_info(gem_name)
        # Override compact_info to use personalized gems for checksums
        versions = __getobj__.versions_for_gem(gem_name)
        return [] if versions.empty?

        versions.map do |version|
          spec = __getobj__.gem_spec(gem_name, version)
          next unless spec

          # Use personalized gem file for checksum calculation
          personalized_gem_file = gem_file_path(gem_name, version)
          checksum = Digest::SHA256.file(personalized_gem_file).hexdigest

          # The checksum is the personalized gem's, but the dependencies are the
          # original spec's — repacking never touches them, and a line that
          # disagreed with the gem it points at is exactly the failure this
          # format exists to prevent.
          GemRepository.compact_info_line(version, spec, checksum)
        end.compact
      end

      private

      # Keyed by everything that goes INTO the gem, not by the gem alone.
      #
      # It used to be "#{gem_name}-#{version}-personalized.gem", which is the
      # same path for every licensee: two of them racing on one download meant
      # one customer receiving the other's copy, and what is personalized into
      # it is by definition the other customer's. The digest below is what makes
      # the cache a cache rather than a collision — same inputs, same file;
      # different licensee, different file.
      #
      # It is also the reason repacking twice is cheap: identical inputs produce
      # a byte-identical gem, so the second request for the same licensee finds
      # the file already there and the checksum in the compact index still
      # describes it.
      def personalize_gem(original_gem_path, gem_name, version)
        personalized_dir = File.join(Dir.tmpdir, "paquette_personalized")
        FileUtils.mkdir_p(personalized_dir)

        personalized_path = File.join(personalized_dir, "#{gem_name}-#{version}-#{personalization_digest}.gem")
        return personalized_path if File.exist?(personalized_path)

        # A directory we make here and give back here. The block form removes
        # exactly what it created, so nothing in this method ever deletes a path
        # somebody else chose — which is the only safe rule when the path came
        # out of another object. Reaching for File.dirname of whatever you were
        # handed and deleting it recursively is how a tidy-up ends up walking
        # the system temp directory.
        Dir.mktmpdir("paquette_personalize") do |workdir|
          built = Paquette::GemServer::GemRepacker.repack(original_gem_path,
            gemspec_extras: {"paquette.license_key" => @license_key},
            magic_comment_replacements: @magic_comment_replacements,
            files: @files,
            into: File.join(workdir, File.basename(personalized_path)))

          FileUtils.mv(built, personalized_path)
        end

        personalized_path
      end

      # Everything this personalizer would write into a gem, as one short hash.
      # Stable across processes, so a restart does not orphan the cache.
      def personalization_digest
        @personalization_digest ||= Digest::SHA256.hexdigest([
          @license_key,
          @magic_comment_replacements.sort.inspect,
          @files.sort.inspect
        ].join("\0"))[0, 16]
      end
    end
  end
end
