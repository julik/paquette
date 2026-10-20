require "rubygems/package"
require "tempfile"
require "stringio"
require "fileutils"
require "digest"
require "json"
require "measurometer"

# Repository implementation that reads gems from a directory
class Paquette::GemServer::DirectoryGemRepository < Paquette::GemServer::GemRepository
  # Raised on a push of a name+version+platform already on disk.
  class GemAlreadyExists < StandardError; end

  # Raised when a payload cannot be read as a gem, or its spec claims
  # something a server should not act on.
  class InvalidGem < StandardError; end

  # Raised on a yank of a gem that is not there.
  class GemNotFound < StandardError; end

  # Raised on a push of a tombed name+version+platform.
  class GemYanked < StandardError; end

  # - `gems_dir`: the corpus root, created if absent
  # - `require_release_date`: refuse a push whose gemspec date is the RubyGems
  #   placeholder or years from today - see
  #   SpecValidator.validate_release_date!
  #
  #: (String gems_dir, ?require_release_date: bool) -> void
  def initialize(gems_dir, require_release_date: false)
    @gems_dir = gems_dir
    @require_release_date = require_release_date
    FileUtils.mkdir_p(@gems_dir)
  end

  # A digest of what the corpus holds. Paths alone are enough: a push adds
  # one, a yank renames one away to a tomb, and a .gem file at a given path
  # never changes its bytes.
  #
  #: () -> String
  def fingerprint
    Measurometer.instrument("paquette.gem_repository.fingerprint") do
      d = Digest::SHA256.new
      Dir.glob(File.join(@gems_dir, "**", "*.gem")).sort.each { |path| d << path }
      d.base64digest
    end
  end

  #: () -> String
  def cache_validator
    fingerprint
  end

  # A directory of gems is the same directory for everybody; the wrappers
  # above are what make a response caller-specific.
  #
  #: () -> bool
  def varies_by_caller?
    false
  end

  # The SHA256 the sidecar already holds, so an ETag on a download costs
  # two stat calls rather than a re-hash. Goes through the same
  # read-or-derive path compact_info uses, which makes the ETag and the
  # published checksum the same number by construction.
  #
  #: (String gem_name, String version) -> String?
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

  # Persists a .gem file from an uploaded payload. No size cap on purpose:
  # that is the server's rule, enforced by the body it hands over.
  #
  # - `gem_payload`: an IO to stream from (the form the server uses — a 50MB
  #   push should not become a 50MB Ruby String) or raw bytes
  #
  # Returns the parsed spec.
  # Raises `InvalidGem` when the payload cannot be opened as a gem or its
  # spec claims something a server should not act on.
  # Raises `GemYanked` for a tombed name+version+platform.
  # Raises `GemAlreadyExists` when that name, version *and* platform is
  # already on disk — "a-0.2.0-java" and "a-0.2.0" are two artifacts.
  #
  #: ((IO | String) gem_payload) -> ::Gem::Specification
  def add_gem(gem_payload)
    raise InvalidGem, "Empty gem payload" if gem_payload.nil?

    io = gem_payload.is_a?(String) ? StringIO.new(gem_payload) : gem_payload
    io.rewind if io.respond_to?(:rewind)

    tmp = Tempfile.new(["paquette_push", ".gem"])
    upload_path = tmp.path #: String
    tmp.binmode

    copied = Measurometer.instrument("paquette.gem_repository.write_upload") do
      IO.copy_stream(io, tmp)
    end
    tmp.close

    Measurometer.add_distribution_value("paquette.gem_repository.add_gem_bytes", copied)
    raise InvalidGem, "Empty gem payload" if copied.zero?

    spec = begin
      Measurometer.instrument("paquette.gem_repository.read_uploaded_spec") { read_uploaded_spec(upload_path) }
    rescue Gem::Package::Error, StandardError => e
      raise InvalidGem, "Could not read gem: #{e.message}"
    end

    # Before anything touches the filesystem with them. Every field below
    # this line came out of a YAML document the uploader wrote.
    name, version, platform = Paquette::GemServer::SpecValidator.validate!(spec)
    Paquette::GemServer::SpecValidator.validate_release_date!(spec) if @require_release_date

    # The key, and the filename: a java build and a plain-ruby build are
    # two artifacts, so everything below is keyed by the column.
    version_column = Paquette::GemServer.version_column(version, platform)

    raise GemYanked, "#{name}-#{version_column} was yanked and cannot be republished" if tomb_exists?(name, version_column)
    raise GemAlreadyExists, "#{name}-#{version_column} already exists" if gem_exists?(name, version_column)

    destination = gem_file_path(name, version_column)
    # Braces to the validator's belt: SpecValidator's patterns make this
    # unreachable today, and this is the check that keeps holding if either
    # pattern is ever widened.
    unless within_gems_dir?(destination)
      raise InvalidGem, "Gem #{name}-#{version_column} resolves outside the gems directory"
    end

    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.mv(upload_path, destination)

    spec
  ensure
    tmp&.close unless tmp&.closed?
    File.unlink(tmp.path) if tmp && File.exist?(tmp.path)
  end

  # Serializes the alias flip below. Two concurrent pushes must not have
  # one of them restore the flag while the other is still inside Psych.
  YAML_ALIAS_MUTEX = Mutex.new #: Thread::Mutex

  # Reads the spec out of an uploaded .gem with YAML alias expansion off:
  # aliases are the billion-laughs DoS, and no real gemspec carries one.
  # Gem::SafeYAML is process-global state RubyGems and Bundler also read,
  # so it is flipped around our own parse and put back, under a mutex,
  # never permanently at require time.
  #
  #: (String gem_path) -> ::Gem::Specification
  def read_uploaded_spec(gem_path)
    # Gem::SafeYAML is only defined once RubyGems has pulled Psych in,
    # which Gem::Package does lazily.
    Gem.load_yaml
    return Gem::Package.new(gem_path).spec unless Gem::SafeYAML.respond_to?(:aliases_enabled=)

    YAML_ALIAS_MUTEX.synchronize do
      was_enabled = Gem::SafeYAML.aliases_enabled?
      begin
        Gem::SafeYAML.aliases_enabled = false
        Gem::Package.new(gem_path).spec
      ensure
        Gem::SafeYAML.aliases_enabled = was_enabled
      end
    end
  end

  # Whether a path the repository is about to write to is really inside the
  # corpus. The trailing separator stops a sibling directory whose name
  # merely starts the same way — "/srv/gems-evil" against "/srv/gems".
  #
  #: (String path) -> bool
  def within_gems_dir?(path)
    root = File.expand_path(@gems_dir) + File::SEPARATOR
    File.expand_path(path).start_with?(root)
  end

  # Yanks a gem by renaming its .gem file to a per-artifact .gem.tomb:
  # yanking "a-0.2.0-java" leaves "a-0.2.0" downloadable.
  #
  # - `version`: a version column
  #
  # Raises `GemNotFound` when never present or already yanked.
  #
  #: (String gem_name, String version) -> nil
  def yank_gem(gem_name, version)
    gem_path = gem_file_path(gem_name, version)
    # Nothing upstream is obliged to have validated anything, and a yank
    # that escaped the corpus would rename a file that was never ours.
    raise GemNotFound, "#{gem_name}-#{version} not found" unless within_gems_dir?(gem_path)
    raise GemNotFound, "#{gem_name}-#{version} not found" unless File.exist?(gem_path)

    Measurometer.instrument("paquette.gem_repository.yank_gem") do
      FileUtils.mv(gem_path, tomb_file_path(gem_name, version))

      # Tidying, not correctness: compact_info trusts the *.gem glob and
      # never reads a sidecar whose gem file is gone.
      FileUtils.rm_f(sidecar_path(gem_name, version))
    end
    nil
  end

  #: (String gem_name, String version) -> String
  def tomb_file_path(gem_name, version)
    gem_file_path(gem_name, version) + ".tomb"
  end

  #: (String gem_name, String version) -> bool
  def tomb_exists?(gem_name, version)
    File.exist?(tomb_file_path(gem_name, version))
  end

  # A directory is not a gem; a .gem file in it is. Yanking the last .gem
  # leaves the directory behind, and listing it would make /names announce
  # a gem whose /info/ answers 404.
  #
  #: () -> Array[String]
  def gem_names
    Measurometer.instrument("paquette.gem_repository.gem_names") do
      Dir.glob(File.join(@gems_dir, "*")).select { |path| File.directory?(path) }.filter_map do |package_path|
        name = File.basename(package_path)
        name unless versions_for_gem(name).empty?
      end.sort
    end
  end

  # A directory listing per gem in the corpus; every whole-index endpoint
  # starts here.
  #
  #: () -> Array[[String, String]]
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

  # Returns version columns.
  #
  #: (String gem_name) -> Array[String]
  def versions_for_gem(gem_name)
    gem_dir = File.join(@gems_dir, gem_name)
    return [] unless Dir.exist?(gem_dir)

    # The filename split is GemServer's to make: a pattern built here was
    # a third opinion about what a version looks like, and it disagreed.
    Measurometer.instrument("paquette.gem_repository.versions_for_gem") do
      Dir.glob(File.join(gem_dir, "*.gem")).map do |gem_path|
        name, version = Paquette::GemServer.split_gem_filename(File.basename(gem_path))
        version if name == gem_name
      end.compact.sort
    end
  end

  # `version` is a version column, so this is byte for byte the filename
  # Gem::Specification#file_name would have produced.
  #
  #: (String gem_name, String version) -> String
  def gem_file_path(gem_name, version)
    File.join(@gems_dir, gem_name, "#{gem_name}-#{version}.gem")
  end

  #: (String gem_name, String version) -> bool
  def gem_exists?(gem_name, version)
    File.exist?(gem_file_path(gem_name, version))
  end

  # Opening a .gem to read its spec means a tar walk, a gunzip and a YAML
  # parse — the single most expensive thing this repository does per gem,
  # and what the sidecar cache exists to avoid.
  #
  #: (String gem_name, String version) -> ::Gem::Specification?
  def gem_spec(gem_name, version)
    gem_file = gem_file_path(gem_name, version)
    return nil unless File.exist?(gem_file)

    Measurometer.instrument("paquette.gem_repository.gem_spec") do
      Gem::Package.new(gem_file).spec
    end
  end

  # The publication date out of the sidecar when one is there, and out of
  # the gem itself when it is not — same answer either way.
  #
  #: (String gem_name, String version) -> Time?
  def published_at(gem_name, version)
    gem_file = gem_file_path(gem_name, version)

    stat = begin
      File.stat(gem_file)
    rescue Errno::ENOENT
      return nil
    end

    cached = read_sidecar(gem_name, version, stat)&.fetch("published_at", nil)
    return Time.at(cached).utc if cached

    gem_spec(gem_name, version)&.date
  end

  # Returns runtime dependencies only.
  #
  #: (String gem_name, String version) -> Array[Hash[Symbol, String]]
  def gem_dependencies(gem_name, version)
    spec = gem_spec(gem_name, version)
    return [] unless spec

    runtime_deps = spec.dependencies.select { |dep| dep.type == :runtime }
    runtime_deps.map do |dep|
      {
        name: dep.name,
        requirements: dep.requirement.to_s
      }
    end
  end

  # Where the derived-metadata sidecars live. The leading dot keeps it out
  # of every glob in this class: Dir.glob skips dotfiles unless asked.
  CACHE_DIR_BASENAME = ".paquette-cache"

  # Returns one compact index line per version.
  #
  #: (String gem_name) -> Array[String]
  def compact_info(gem_name)
    versions = versions_for_gem(gem_name)
    return [] if versions.empty?

    Measurometer.instrument("paquette.gem_repository.compact_info") do
      # The *.gem files are the authority on what exists; an orphaned
      # sidecar is simply never read, which is what makes yank instant.
      versions.map do |version|
        gem_file = gem_file_path(gem_name, version)

        stat = begin
          File.stat(gem_file)
        rescue Errno::ENOENT
          # Yanked between the glob and this stat.
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

  # A .gem file at a given path never changes, so what compact_info
  # derives from one is derived once and kept in a JSON file next to it —
  # without this, /versions paid a tar walk and YAML parse per version.
  #
  #: (String gem_name, String version) -> String
  def sidecar_path(gem_name, version)
    File.join(@gems_dir, gem_name, CACHE_DIR_BASENAME, "#{gem_name}-#{version}.json")
  end

  # The cached fields, or nil for anything short of a usable entry — nil
  # just means the gem gets parsed again.
  #
  #: (String gem_name, String version, ::File::Stat stat) -> Hash[String, untyped]?
  def read_sidecar(gem_name, version, stat)
    fields = JSON.parse(File.read(sidecar_path(gem_name, version)))
    return nil unless fields.is_a?(Hash)

    # An entry that predates a field cannot be told from one whose gem
    # genuinely lacks it, so an old format number is re-derived, not served.
    return nil unless fields["format_version"] == SIDECAR_FORMAT_VERSION
    return nil unless %w[dependencies ruby rubygems checksum].all? { |key| fields.key?(key) }
    return nil unless fields["size"] == stat.size && fields["mtime_ns"] == mtime_ns(stat)

    fields
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # Bump this whenever compact_info_fields gains, drops or changes the
  # meaning of a key: a warm cache would otherwise quietly serve
  # yesterday's line forever.
  SIDECAR_FORMAT_VERSION = 3

  #: (String gem_name, String version, String gem_file, ::File::Stat stat) -> Hash[String, untyped]?
  def derive_sidecar(gem_name, version, gem_file, stat)
    Measurometer.instrument("paquette.gem_repository.derive_sidecar") do
      derive_sidecar_fields(gem_name, version, gem_file, stat)
    end
  end

  #: (String gem_name, String version, String gem_file, ::File::Stat stat) -> Hash[String, untyped]?
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

  # Tempfile-and-rename, so a reader never sees a torn write; no locking,
  # since two racing writers derived the same bytes. The cache is an
  # optimization — on a read-only directory the rescue eats every write.
  #
  #: (String gem_name, String version, Hash[String, untyped] fields) -> nil
  def write_sidecar(gem_name, version, fields)
    # Declared out here so the rescue below can still see it.
    tmp_path = nil #: String?

    Measurometer.instrument("paquette.gem_repository.write_sidecar") do
      final_path = sidecar_path(gem_name, version)
      cache_dir = File.dirname(final_path)
      FileUtils.mkdir_p(cache_dir)

      staged = File.join(cache_dir, ".#{gem_name}-#{version}.#{Process.pid}.#{rand(2**32).to_s(16)}.tmp")
      tmp_path = staged
      File.write(staged, JSON.pretty_generate(fields))
      File.rename(staged, final_path)
    end
    nil
  rescue SystemCallError
    FileUtils.rm_f(tmp_path) if tmp_path
    nil
  end

  # An integer rather than a Float on purpose: the guard is an
  # exact-equality check, and integers survive a trip through JSON.
  #
  #: (::File::Stat stat) -> Integer
  def mtime_ns(stat)
    mtime = stat.mtime
    (mtime.to_i * 1_000_000_000) + mtime.nsec
  end
end
