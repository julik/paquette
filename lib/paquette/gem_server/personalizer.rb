require "delegate"
require "fileutils"
require "digest"
require "json"
require "measurometer"

# Wraps a gem repository and serves each gem repacked for one licensee —
# magic comment lines replaced, files injected, the license key stamped
# into the gemspec metadata — with the repacked gems and their checksums
# cached on disk.
class Paquette::GemServer::Personalizer < SimpleDelegator
  # Here for the day the checksum sidecar's shape has to change. Checked by
  # nothing today — the reader keys off the fields it needs.
  CHECKSUM_SIDECAR_FORMAT_VERSION = 1

  # Two rules make the caching sound, and they are the caller's to keep:
  # what `files_for:` returns may depend on the gem file and
  # `personalization_key:` and nothing else, and nil must be a fact about
  # the file alone — it is remembered per file, never per licensee.
  #
  # @param repository [Paquette::GemServer::GemRepository] the repository
  #   to wrap
  # @param license_key [String] stamped into every served gem's metadata
  # @param magic_comment_replacements [Hash{String => String}] whole
  #   comment lines to replace in **/*.rb, marker => replacement
  # @param files [Hash{String => String}] path => content, written into
  #   every gem and added to spec.files — this is what a per-licensee
  #   LICENSE file arrives through, rendered by the caller
  # @param files_for [Proc, nil] the per-gem edition of `files:`, called
  #   with (gem_name, version, original_path); returns a path => content
  #   hash injected on top of `files:`, or nil meaning this gem is served
  #   byte for byte as it sits on disk
  # @param personalization_key [String, nil] everything the personalized
  #   bytes depend on beyond the gem itself — a licensee id, a ref
  # @param cache_dir [String, nil] where personalized gems and opt-out
  #   markers are kept; defaults to the system temp directory, which an
  #   application with a cache directory of its own should override
  def initialize(repository, license_key:, magic_comment_replacements: {}, files: {},
    files_for: nil, personalization_key: nil, cache_dir: nil)
    super(repository)
    @license_key = license_key
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @files_for = files_for
    @personalization_key = personalization_key
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized")
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil] the path of the personalized (or pass-through) gem
  def gem_file_path(gem_name, version)
    original_path = __getobj__.gem_file_path(gem_name, version)
    return original_path unless original_path && File.exist?(original_path)

    personalize_gem(original_path, gem_name, version)
  end

  # The wrapped validator with this personalizer's identity mixed in, so
  # one licensee's cached index can never satisfy another's request. The
  # key is the same digest that names the cached gems on disk, so this is
  # exactly as strong as that cache; `files_for:` itself is not digested —
  # a Proc cannot be, and the initializer's contract means it need not be.
  #
  # @return [String, nil]
  def cache_validator
    inner = Paquette::GemServer::GemRepository.cache_validator_of(__getobj__)
    Paquette::GemServer::GemRepository.derive_validator(inner, "personalizer", personalization_digest)
  end

  # Every byte this serves is baked for one licensee.
  #
  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # The checksum of what this personalizer would hand over — an ETag that
  # disagreed with the index would read as a tampered gem.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil]
  def gem_checksum(gem_name, version)
    original = __getobj__.gem_file_path(gem_name, version)
    served = gem_file_path(gem_name, version)

    if served.nil? || served == original
      return Paquette::GemServer::GemRepository.gem_checksum_of(__getobj__, gem_name, version)
    end
    return nil unless File.exist?(served)

    served_checksum(served)
  end

  # The wrapped repository's lines with the checksum swapped where the
  # served file differs from the one on disk, and only there — a repack
  # touches no other field.
  #
  # @param gem_name [String]
  # @return [Array<String>]
  def compact_info(gem_name)
    Measurometer.instrument("paquette.gem_personalizer.compact_info") do
      __getobj__.compact_info(gem_name).map do |line|
        # The version column, platform suffix and all.
        version = line.split(" ", 2).first
        original = __getobj__.gem_file_path(gem_name, version)
        served = gem_file_path(gem_name, version)
        next line if served.nil? || served == original || !File.exist?(served)

        Paquette::GemServer::GemRepository.replace_checksum(line, served_checksum(served))
      end
    end
  end

  private

  # The cache is keyed by everything that goes INTO the gem, never the gem
  # alone — a per-licensee path is what keeps two racing licensees from
  # receiving each other's copy. Consulted before the gem is ever opened:
  # compact_info asks per version per request.
  #
  # @param original_gem_path [String]
  # @param gem_name [String]
  # @param version [String]
  # @return [String]
  def personalize_gem(original_gem_path, gem_name, version)
    stat = File.stat(original_gem_path)
    personalized_path = cache_path(gem_name, version, stat)
    if File.exist?(personalized_path)
      Measurometer.increment_counter("paquette.gem_personalizer.cache_hit")
      return personalized_path
    end

    if @files_for
      # The marker is licensee-independent — see the contract in the
      # initializer — so one look inside the gem answers for everybody.
      marker = plain_marker_path(gem_name, version, stat)
      return original_gem_path if File.exist?(marker)

      dynamic_files = Measurometer.instrument("paquette.gem_personalizer.files_for") do
        @files_for.call(gem_name, version, original_gem_path)
      end
      if dynamic_files.nil?
        FileUtils.mkdir_p(@cache_dir)
        FileUtils.touch(marker)
        return original_gem_path
      end
    else
      dynamic_files = {}
    end

    Measurometer.increment_counter("paquette.gem_personalizer.cache_miss")
    repack(original_gem_path, personalized_path, dynamic_files)
  end

  # The block form of mktmpdir removes exactly what it created, so nothing
  # in this method ever deletes a path somebody else chose.
  #
  # @param original_gem_path [String]
  # @param personalized_path [String]
  # @param dynamic_files [Hash{String => String}]
  # @return [String]
  def repack(original_gem_path, personalized_path, dynamic_files)
    FileUtils.mkdir_p(@cache_dir)
    Measurometer.instrument("paquette.gem_personalizer.repack") do
      Dir.mktmpdir("paquette_personalize") do |workdir|
        built = Paquette::GemServer::GemRepacker.repack(original_gem_path,
          gemspec_extras: {"paquette.license_key" => @license_key},
          magic_comment_replacements: @magic_comment_replacements,
          files: @files.merge(dynamic_files),
          into: File.join(workdir, File.basename(personalized_path)))

        FileUtils.mv(built, personalized_path)
      end
    end

    personalized_path
  end

  # The SHA256 of a personalized gem, remembered next to it — the bytes at
  # that path are fixed for as long as the path exists. Size and mtime are
  # checked anyway: a stale checksum reads as a tampered gem.
  #
  # @param served [String]
  # @return [String]
  def served_checksum(served)
    Measurometer.instrument("paquette.gem_personalizer.checksum") do
      stat = File.stat(served)
      cached = read_checksum_sidecar(served, stat)
      if cached
        Measurometer.increment_counter("paquette.gem_personalizer.checksum_hit")
        next cached
      end

      Measurometer.increment_counter("paquette.gem_personalizer.checksum_miss")
      checksum = Digest::SHA256.file(served).hexdigest
      write_checksum_sidecar(served, stat, checksum)
      checksum
    end
  end

  # Alongside the gem rather than inside a directory of its own, so the two
  # are removed together by anything that sweeps this cache by age.
  #
  # @param served [String]
  # @return [String]
  def checksum_sidecar_path(served)
    "#{served}.sha256"
  end

  # @param served [String]
  # @param stat [File::Stat]
  # @return [String, nil]
  def read_checksum_sidecar(served, stat)
    fields = JSON.parse(File.read(checksum_sidecar_path(served)))
    return nil unless fields.is_a?(Hash)
    return nil unless fields["size"] == stat.size && fields["mtime_ns"] == mtime_ns(stat)
    return nil unless fields["checksum"].is_a?(String)

    fields["checksum"]
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # Tempfile-and-rename, so a reader never sees half a digest. Failure is
  # ignored on purpose: an unwritable cache costs a hash per request, not
  # a failed request.
  #
  # @param served [String]
  # @param stat [File::Stat]
  # @param checksum [String]
  # @return [void]
  def write_checksum_sidecar(served, stat, checksum)
    tmp_path = "#{served}.#{Process.pid}.#{rand(2**32).to_s(16)}.sha256.tmp"
    File.write(tmp_path, JSON.generate(
      "format_version" => CHECKSUM_SIDECAR_FORMAT_VERSION,
      "checksum" => checksum,
      "size" => stat.size,
      "mtime_ns" => mtime_ns(stat)
    ))
    File.rename(tmp_path, checksum_sidecar_path(served))
  rescue SystemCallError
    begin
      File.unlink(tmp_path)
    rescue SystemCallError
      nil
    end
  end

  # Whole nanoseconds. Float mtimes lose precision on large timestamps, and
  # this is compared for equality.
  #
  # @param stat [File::Stat]
  # @return [Integer]
  def mtime_ns(stat)
    stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec
  end

  # Stat identity in the name, so a replaced source file misses the cache
  # without anything having to be invalidated.
  #
  # @param gem_name [String]
  # @param version [String]
  # @param stat [File::Stat]
  # @return [String]
  def cache_path(gem_name, version, stat)
    digest = Digest::SHA256.hexdigest([
      personalization_digest, stat.mtime.to_f, stat.size
    ].join("\0"))[0, 24]
    File.join(@cache_dir, "#{gem_name}-#{version}-#{digest}.gem")
  end

  # Where "this gem carries nothing to personalize" is written down — an
  # empty file whose presence is the fact. Keyed by the source identity
  # alone, never by the licensee: whether a gem participates is a fact
  # about the gem.
  #
  # @param gem_name [String]
  # @param version [String]
  # @param stat [File::Stat]
  # @return [String]
  def plain_marker_path(gem_name, version, stat)
    digest = Digest::SHA256.hexdigest([stat.mtime.to_f, stat.size].join("\0"))[0, 24]
    File.join(@cache_dir, "#{gem_name}-#{version}-#{digest}.plain")
  end

  # Everything this personalizer would write into a gem, as one short hash.
  # Stable across processes, so a restart does not orphan the cache.
  #
  # @return [String]
  def personalization_digest
    @personalization_digest ||= Digest::SHA256.hexdigest([
      @license_key,
      @magic_comment_replacements.sort.inspect,
      @files.sort.inspect,
      @personalization_key.to_s
    ].join("\0"))[0, 16]
  end
end
