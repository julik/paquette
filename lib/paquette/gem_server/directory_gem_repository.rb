require_relative "gem_repository"
require "rubygems/package"
require "tempfile"
require "fileutils"
require "digest"
require "json"

module Paquette
  class GemServer
    # Repository implementation that reads gems from a directory
    class DirectoryGemRepository < GemRepository
      class GemAlreadyExists < StandardError; end

      class InvalidGem < StandardError; end

      class GemNotFound < StandardError; end

      class GemYanked < StandardError; end

      def initialize(gems_dir)
        @gems_dir = gems_dir
        FileUtils.mkdir_p(@gems_dir)
      end

      # Persists a .gem file from its raw binary contents. Returns the parsed
      # spec on success. Raises InvalidGem when the payload can't be opened as
      # a gem, or GemAlreadyExists if the name+version is already on disk.
      def add_gem(binary_data)
        raise InvalidGem, "Empty gem payload" if binary_data.nil? || binary_data.empty?

        tmp = Tempfile.new(["paquette_push", ".gem"])
        tmp.binmode
        tmp.write(binary_data)
        tmp.close

        spec = begin
          Gem::Package.new(tmp.path).spec
        rescue Gem::Package::Error, StandardError => e
          raise InvalidGem, "Could not read gem: #{e.message}"
        end

        name = spec.name
        version = spec.version.to_s
        raise GemYanked, "#{name}-#{version} was yanked and cannot be republished" if tomb_exists?(name, version)
        raise GemAlreadyExists, "#{name}-#{version} already exists" if gem_exists?(name, version)

        dest_dir = File.join(@gems_dir, name)
        FileUtils.mkdir_p(dest_dir)
        FileUtils.mv(tmp.path, gem_file_path(name, version))

        spec
      ensure
        tmp&.close unless tmp&.closed?
        File.unlink(tmp.path) if tmp && File.exist?(tmp.path)
      end

      # Yanks a gem by renaming its .gem file to .gem.tomb. The tomb prevents
      # the same name+version from being re-pushed later. Raises GemNotFound
      # when the gem was never present or already yanked.
      def yank_gem(gem_name, version)
        gem_path = gem_file_path(gem_name, version)
        raise GemNotFound, "#{gem_name}-#{version} not found" unless File.exist?(gem_path)

        FileUtils.mv(gem_path, tomb_file_path(gem_name, version))

        # Tidying, not correctness. compact_info trusts the *.gem glob and
        # never reads a sidecar whose gem file is gone, so a yanked gem
        # disappears from the index the moment the rename above lands — this
        # just keeps the cache directory from collecting orphans.
        FileUtils.rm_f(sidecar_path(gem_name, version))
        nil
      end

      def tomb_file_path(gem_name, version)
        gem_file_path(gem_name, version) + ".tomb"
      end

      def tomb_exists?(gem_name, version)
        File.exist?(tomb_file_path(gem_name, version))
      end

      def gem_names
        Dir.glob(File.join(@gems_dir, "*")).select { |path| File.directory?(path) }.map do |package_path|
          File.basename(package_path)
        end.sort
      end

      def gem_versions
        versions = []
        gem_names.each do |gem_name|
          versions_for_gem(gem_name).each do |version|
            versions << [gem_name, version]
          end
        end
        versions.sort
      end

      def versions_for_gem(gem_name)
        gem_dir = File.join(@gems_dir, gem_name)
        return [] unless Dir.exist?(gem_dir)

        Dir.glob(File.join(gem_dir, "*.gem")).map do |gem_path|
          filename = File.basename(gem_path, ".gem")
          if (match = filename.match(/^#{Regexp.escape(gem_name)}-(\d+\.\d+\.\d+.*)$/))
            match[1]
          end
        end.compact.sort
      end

      def gem_file_path(gem_name, version)
        File.join(@gems_dir, gem_name, "#{gem_name}-#{version}.gem")
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

      # Where the derived-metadata sidecars live, inside each package
      # directory. The leading dot is what keeps it out of every listing in
      # this class without any listing having to know about it: Dir.glob does
      # not match dotfiles unless asked with FNM_DOTMATCH, so neither the
      # "*.gem" glob in versions_for_gem nor the "*" glob in gem_names can
      # ever see it — and gem_names filters to directories on top of that.
      CACHE_DIR_BASENAME = ".paquette-cache"

      def compact_info(gem_name)
        versions = versions_for_gem(gem_name)
        return [] if versions.empty?

        # The *.gem files are the authority on what exists; the sidecars are
        # only consulted for gems the glob above already vouched for. That
        # order is what makes yank instant — a renamed-away gem file leaves
        # its sidecar orphaned, and an orphaned sidecar is simply never read.
        versions.map do |version|
          gem_file = gem_file_path(gem_name, version)

          stat = begin
            File.stat(gem_file)
          rescue Errno::ENOENT
            # Yanked between the glob and this stat. The gem is gone, so its
            # line is too.
            next
          end

          fields = read_sidecar(gem_name, version, stat) || derive_sidecar(gem_name, version, gem_file, stat)
          next unless fields

          GemRepository.compact_info_line_from_fields(version, fields)
        end.compact
      end

      private

      # A .gem file at a given path never changes: a yank renames it away, and
      # a name+version can never be pushed twice. So everything compact_info
      # derives from one — the spec fields an info line is made of and the
      # SHA256 of the whole file — is derived once, on the first request that
      # needs it, and kept in a JSON file next to the gem. Without this, every
      # /versions request paid a full tar walk, gunzip, checksum verification
      # and YAML parse for every version of every gem in the corpus.
      def sidecar_path(gem_name, version)
        File.join(@gems_dir, gem_name, CACHE_DIR_BASENAME, "#{gem_name}-#{version}.json")
      end

      # Returns the cached fields, or nil for anything short of a usable
      # entry: no sidecar yet, unparseable JSON, a hash missing the keys the
      # renderer needs, or a size/mtime that disagrees with the gem file on
      # disk. A byte-different file at the same path should never happen, but
      # "should never happen" is not a thing to serve stale checksums over —
      # a nil here just means the gem gets parsed again.
      def read_sidecar(gem_name, version, stat)
        fields = JSON.parse(File.read(sidecar_path(gem_name, version)))
        return nil unless fields.is_a?(Hash)
        return nil unless %w[dependencies ruby checksum].all? { |key| fields.key?(key) }
        return nil unless fields["size"] == stat.size && fields["mtime_ns"] == mtime_ns(stat)

        fields
      rescue SystemCallError, JSON::ParserError
        nil
      end

      # Written into every sidecar, and checked by nothing — deliberately.
      # The reader keys off the fields it needs and ignores the rest, so a
      # sidecar from before this constant existed reads exactly as well as
      # one written today, and no migration or version branch is wanted yet.
      # The number is here for the day the format has to change: when it
      # does, the reader will need something on disk to dispatch on, and a
      # file that says "1" can be told apart from whatever comes after it,
      # while a file written before anyone recorded a version is ambiguous
      # forever. So the version goes in now, while writing it costs nothing,
      # instead of at the moment it is needed and every existing sidecar
      # lacks it.
      SIDECAR_FORMAT_VERSION = 1

      def derive_sidecar(gem_name, version, gem_file, stat)
        spec = gem_spec(gem_name, version)
        return nil unless spec

        checksum = Digest::SHA256.file(gem_file).hexdigest
        fields = GemRepository.compact_info_fields(spec, checksum).merge(
          "format_version" => SIDECAR_FORMAT_VERSION,
          "version" => version,
          "size" => stat.size,
          "mtime_ns" => mtime_ns(stat)
        )
        write_sidecar(gem_name, version, fields)
        fields
      end

      # Serialize into a tempfile in the cache directory, then rename over the
      # final name. Rename within one directory is atomic, so a reader sees
      # either the old sidecar or the new one, never a torn write. There is no
      # locking on purpose: two writers racing here derived their content from
      # the same immutable gem file, so whichever rename lands last installed
      # the same bytes the loser would have.
      #
      # The cache is an optimization, never a requirement — on a read-only
      # gems directory every write lands in the rescue and the request is
      # served from source, at the old price but served.
      def write_sidecar(gem_name, version, fields)
        final_path = sidecar_path(gem_name, version)
        cache_dir = File.dirname(final_path)
        FileUtils.mkdir_p(cache_dir)

        tmp_path = File.join(cache_dir, ".#{gem_name}-#{version}.#{Process.pid}.#{rand(2**32).to_s(16)}.tmp")
        File.write(tmp_path, JSON.pretty_generate(fields))
        File.rename(tmp_path, final_path)
        nil
      rescue SystemCallError
        FileUtils.rm_f(tmp_path) if tmp_path
        nil
      end

      # The mtime down to the nanosecond, as one integer. An integer rather
      # than a Float on purpose: the guard is an exact-equality check, and
      # integers survive a trip through JSON without anyone having to reason
      # about float formatting to trust the comparison.
      def mtime_ns(stat)
        mtime = stat.mtime
        (mtime.to_i * 1_000_000_000) + mtime.nsec
      end
    end
  end
end
