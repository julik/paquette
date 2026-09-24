require "rubygems/package"
require "tempfile"
require "fileutils"
require "digest"
require "json"
require "measurometer"

# Repository implementation that reads gems from a directory
class Paquette::GemServer::DirectoryGemRepository < Paquette::GemServer::GemRepository
  class GemAlreadyExists < StandardError; end

  class InvalidGem < StandardError; end

  class GemNotFound < StandardError; end

  class GemYanked < StandardError; end

  def initialize(gems_dir)
    @gems_dir = gems_dir
    FileUtils.mkdir_p(@gems_dir)
  end

  # A digest of what the corpus holds, for callers building HTTP cache
  # validators over it. Paths alone are enough: a push adds one, a yank
  # renames one away to a tomb, and a .gem file at a given path never
  # changes its bytes.
  def fingerprint
    Measurometer.instrument("paquette.gem_repository.fingerprint") do
      d = Digest::SHA256.new
      Dir.glob(File.join(@gems_dir, "**", "*.gem")).sort.each { |path| d << path }
      d.base64digest
    end
  end

  # The corpus fingerprint is this repository's whole contribution to an
  # HTTP validator: it is the one thing here that can change what a
  # response says, because the bytes at a given path never do.
  def cache_validator
    fingerprint
  end

  # A directory of gems is the same directory of gems for everybody. The
  # wrappers above are what make a response caller-specific, and each of
  # them says so for itself.
  def private_to_caller?
    false
  end

  # The SHA256 the sidecar already holds, so an ETag on a download costs
  # two stat calls rather than a re-hash of a multi-megabyte file. Goes
  # through exactly the same read-or-derive path compact_info uses, which
  # is what makes the ETag and the checksum the compact index publishes
  # the same number by construction rather than by coincidence.
  def gem_checksum(gem_name, version)
    gem_file = gem_file_path(gem_name, version)

    stat = begin
      File.stat(gem_file)
    rescue SystemCallError
      return nil
    end

    fields = read_sidecar(gem_name, version, stat) || derive_sidecar(gem_name, version, gem_file, stat)
    fields && fields["checksum"]
  end

  # Persists a .gem file from its raw binary contents. Returns the parsed
  # spec on success. Raises InvalidGem when the payload can't be opened as
  # a gem, or GemAlreadyExists if the name+version is already on disk.
  def add_gem(binary_data)
    raise InvalidGem, "Empty gem payload" if binary_data.nil? || binary_data.empty?

    Measurometer.add_distribution_value("paquette.gem_repository.add_gem_bytes", binary_data.bytesize)

    tmp = Tempfile.new(["paquette_push", ".gem"])
    tmp.binmode
    Measurometer.instrument("paquette.gem_repository.write_upload") { tmp.write(binary_data) }
    tmp.close

    spec = begin
      Measurometer.instrument("paquette.gem_repository.read_uploaded_spec") { Gem::Package.new(tmp.path).spec }
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

    Measurometer.instrument("paquette.gem_repository.yank_gem") do
      FileUtils.mv(gem_path, tomb_file_path(gem_name, version))

      # Tidying, not correctness. compact_info trusts the *.gem glob and
      # never reads a sidecar whose gem file is gone, so a yanked gem
      # disappears from the index the moment the rename above lands — this
      # just keeps the cache directory from collecting orphans.
      FileUtils.rm_f(sidecar_path(gem_name, version))
    end
    nil
  end

  def tomb_file_path(gem_name, version)
    gem_file_path(gem_name, version) + ".tomb"
  end

  def tomb_exists?(gem_name, version)
    File.exist?(tomb_file_path(gem_name, version))
  end

  def gem_names
    Measurometer.instrument("paquette.gem_repository.gem_names") do
      Dir.glob(File.join(@gems_dir, "*")).select { |path| File.directory?(path) }.map do |package_path|
        File.basename(package_path)
      end.sort
    end
  end

  # A directory listing per gem in the corpus; every whole-index endpoint
  # starts here.
  def gem_versions
    Measurometer.instrument("paquette.gem_repository.gem_versions") do
      versions = []
      gem_names.each do |gem_name|
        versions_for_gem(gem_name).each do |version|
          versions << [gem_name, version]
        end
      end
      Measurometer.add_distribution_value("paquette.gem_repository.gem_version_count", versions.length)
      versions.sort
    end
  end

  def versions_for_gem(gem_name)
    gem_dir = File.join(@gems_dir, gem_name)
    return [] unless Dir.exist?(gem_dir)

    # Once, not once per .gem: gem_versions walks this for the whole corpus.
    versioned = /\A#{Regexp.escape(gem_name)}-(\d+\.\d+\.\d+#{Paquette::GemServer::NAME_CHAR}{0,255})\z/

    Measurometer.instrument("paquette.gem_repository.versions_for_gem") do
      Dir.glob(File.join(gem_dir, "*.gem")).map do |gem_path|
        filename = File.basename(gem_path, ".gem")
        if (match = filename.match(versioned))
          match[1]
        end
      end.compact.sort
    end
  end

  def gem_file_path(gem_name, version)
    File.join(@gems_dir, gem_name, "#{gem_name}-#{version}.gem")
  end

  def gem_exists?(gem_name, version)
    File.exist?(gem_file_path(gem_name, version))
  end

  # Opening a .gem to read its spec means a tar walk, a gunzip and a YAML
  # parse — the single most expensive thing this repository does per gem,
  # and what the sidecar cache below exists to avoid.
  def gem_spec(gem_name, version)
    gem_file = gem_file_path(gem_name, version)
    return nil unless File.exist?(gem_file)

    Measurometer.instrument("paquette.gem_repository.gem_spec") do
      Gem::Package.new(gem_file).spec
    end
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

    Measurometer.instrument("paquette.gem_repository.compact_info") do
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

        fields = read_sidecar(gem_name, version, stat)
        if fields
          Measurometer.increment_counter("paquette.gem_repository.sidecar_hit")
        else
          Measurometer.increment_counter("paquette.gem_repository.sidecar_miss")
          fields = derive_sidecar(gem_name, version, gem_file, stat)
        end
        next unless fields

        Paquette::GemServer::GemRepository.compact_info_line_from_fields(version, fields)
      end.compact
    end
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
  # entry: no sidecar yet, unparseable JSON, an entry written by an older
  # format, a hash missing the keys the renderer needs, or a size/mtime
  # that disagrees with the gem file on disk. A byte-different file at the
  # same path should never happen, but "should never happen" is not a
  # thing to serve stale checksums over — a nil here just means the gem
  # gets parsed again.
  def read_sidecar(gem_name, version, stat)
    fields = JSON.parse(File.read(sidecar_path(gem_name, version)))
    return nil unless fields.is_a?(Hash)

    # Anything not stamped with the current format number is discarded
    # rather than served. A sidecar from before the number existed reads
    # as nil here and is re-derived too, which is the case this check was
    # put in for: an entry that predates a field cannot be told from one
    # whose gem genuinely lacks it, and serving it would mean a warm cache
    # quietly emitting yesterday's line forever.
    return nil unless fields["format_version"] == SIDECAR_FORMAT_VERSION
    return nil unless %w[dependencies ruby rubygems checksum].all? { |key| fields.key?(key) }
    return nil unless fields["size"] == stat.size && fields["mtime_ns"] == mtime_ns(stat)

    fields
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # Written into every sidecar, and checked by read_sidecar, which
  # discards anything not stamped with the current number.
  #
  # The day the format had to change arrived with "rubygems", the fourth
  # compact-info field. A cached entry written at version 1 has no such
  # key, and a reader that only looked for the keys it needed could not
  # tell that entry apart from one whose gem simply declares no
  # `required_rubygems_version` — so every deployment with a warm cache
  # would have gone on serving lines without the field, indefinitely and
  # invisibly. Bumping the number is what expires them: a version-1
  # sidecar is re-derived on the first request that reaches it, once,
  # after which the cache is warm again at the new format.
  #
  # Bump this whenever compact_info_fields gains, drops or changes the
  # meaning of a key. It costs each deployment one re-derivation pass
  # spread over ordinary traffic, which is the price of never serving a
  # line the current code would not have rendered.
  SIDECAR_FORMAT_VERSION = 2

  def derive_sidecar(gem_name, version, gem_file, stat)
    Measurometer.instrument("paquette.gem_repository.derive_sidecar") do
      derive_sidecar_fields(gem_name, version, gem_file, stat)
    end
  end

  def derive_sidecar_fields(gem_name, version, gem_file, stat)
    spec = gem_spec(gem_name, version)
    return nil unless spec

    checksum = Measurometer.instrument("paquette.gem_repository.checksum_gem") do
      Digest::SHA256.file(gem_file).hexdigest
    end

    fields = Paquette::GemServer::GemRepository.compact_info_fields(spec, checksum).merge(
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
    # Declared out here so the rescue below can still see it: a local first
    # assigned inside the block would not exist by the time we tidy up.
    tmp_path = nil

    Measurometer.instrument("paquette.gem_repository.write_sidecar") do
      final_path = sidecar_path(gem_name, version)
      cache_dir = File.dirname(final_path)
      FileUtils.mkdir_p(cache_dir)

      tmp_path = File.join(cache_dir, ".#{gem_name}-#{version}.#{Process.pid}.#{rand(2**32).to_s(16)}.tmp")
      File.write(tmp_path, JSON.pretty_generate(fields))
      File.rename(tmp_path, final_path)
    end
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
