require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require "measurometer"

# Serves each wheel and sdist repacked for one licensee - magic comment lines
# replaced, files injected, the license key stamped into paquette.json - with
# the repacked files cached on disk. Counterpart of NpmServer::Personalizer,
# and the same two contracts about `files_for:` apply.
class Paquette::PypiServer::Personalizer < SimpleDelegator
  # @param repository [Paquette::PypiServer::PypiRepository] the repository
  #   to wrap
  # @param license_key [String]
  # @param magic_comment_replacements [Hash{String => String}] whole comment
  #   lines in *.py and *.pyi to replace, marker => replacement
  # @param files [Hash{String => String}] injected into every file, path
  #   relative to the archive root - site-packages, for a wheel
  # @param stamp [Hash, nil] written as paquette.json into the wheel's
  #   .dist-info and the sdist's root; defaults to the license key
  # @param files_for [Proc, nil] per-file extras, called with (project,
  #   filename, original_path); nil means the file is served byte for byte
  # @param personalization_key [String, nil] everything the personalized
  #   bytes depend on beyond the file itself
  # @param cache_dir [String, nil] where personalized files and opt-out
  #   markers are kept
  def initialize(repository, license_key:, magic_comment_replacements: {}, files: {}, stamp: nil,
    files_for: nil, personalization_key: nil, cache_dir: nil)
    Paquette::NpmRepacker.check_replacements!(magic_comment_replacements)
    super(repository)
    @license_key = license_key
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @stamp = stamp || {"license_key" => license_key}
    @files_for = files_for
    @personalization_key = personalization_key
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized_pypi")
  end

  # @return [String, nil]
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "personalizer", personalization_digest)
  end

  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # @param project [String]
  # @param filename [String]
  # @return [String, nil]
  def file_path(project, filename)
    original_path = __getobj__.file_path(project, filename)
    return original_path unless original_path && File.exist?(original_path)

    personalize(original_path, project, filename)
  end

  # The hash and size have to be the personalized file's, or pip refuses
  # it. METADATA is never touched, so its hash stays the repository's.
  #
  # @param project [String]
  # @param filename [String]
  # @return [Paquette::PypiServer::PypiRepository::DistributionFile, nil]
  def file_info(project, filename)
    info = __getobj__.file_info(project, filename)
    return nil unless info

    Measurometer.instrument("paquette.pypi_personalizer.file_info") do
      served = file_path(project, filename)
      next info if served.nil? || served == __getobj__.file_path(project, filename)

      info.dup.tap do |personalized|
        personalized.sha256 = served_sha256(served)
        personalized.size = File.size(served)
      end
    end
  end

  private

  # A project page lists every file, and the stack is built per request, so
  # the hash is kept next to the file it describes. The path names everything
  # that went into the file, which is what makes the sidecar safe to trust.
  #
  # @param served [String]
  # @return [String]
  def served_sha256(served)
    sidecar = "#{served}.sha256"
    cached = File.read(sidecar) if File.exist?(sidecar)
    return cached if cached&.bytesize == 64

    Digest::SHA256.file(served).hexdigest.tap do |hex|
      partial = "#{sidecar}.#{Process.pid}.#{Thread.current.object_id}"
      File.write(partial, hex)
      File.rename(partial, sidecar)
    end
  end

  # Keyed by everything that goes INTO the file: two licensees never share one.
  #
  # @param original_path [String]
  # @param project [String]
  # @param filename [String]
  # @return [String]
  def personalize(original_path, project, filename)
    stat = File.stat(original_path)
    # The served filename is the original one - pip reads the tags out of
    # it - so the digest goes into a directory instead
    personalized_path = File.join(@cache_dir, cache_digest(project, filename, stat), filename)
    if File.exist?(personalized_path)
      Measurometer.increment_counter("paquette.pypi_personalizer.cache_hit")
      return personalized_path
    end

    if @files_for
      marker = plain_marker_path(project, filename, stat)
      return original_path if File.exist?(marker)

      dynamic_files = @files_for.call(project, filename, original_path)
      if dynamic_files.nil?
        FileUtils.mkdir_p(File.dirname(marker))
        FileUtils.touch(marker)
        return original_path
      end
    else
      dynamic_files = {}
    end

    Measurometer.increment_counter("paquette.pypi_personalizer.cache_miss")
    FileUtils.mkdir_p(File.dirname(personalized_path))

    Measurometer.instrument("paquette.pypi_personalizer.repack") do
      Dir.mktmpdir("paquette_personalize_pypi") do |workdir|
        built = Paquette::PypiRepacker.repack(original_path,
          filename: filename,
          stamp: @stamp,
          magic_comment_replacements: @magic_comment_replacements,
          files: @files.merge(dynamic_files),
          into: File.join(workdir, filename))

        # A rename is atomic, so a racing request sees a whole file or none
        FileUtils.mv(built, personalized_path)
      end
    end

    personalized_path
  end

  # @param project [String]
  # @param filename [String]
  # @param stat [::File::Stat]
  # @return [String]
  def cache_digest(project, filename, stat)
    Digest::SHA256.hexdigest([project, filename, personalization_digest, stat.mtime.to_r, stat.size].join("\0"))[0, 24]
  end

  # Keyed by the file alone, never the licensee - see NpmServer::Personalizer.
  #
  # @param project [String]
  # @param filename [String]
  # @param stat [::File::Stat]
  # @return [String]
  def plain_marker_path(project, filename, stat)
    digest = Digest::SHA256.hexdigest([project, filename, stat.mtime.to_r, stat.size].join("\0"))[0, 24]
    File.join(@cache_dir, "plain", "#{digest}.plain")
  end

  # @return [String]
  def personalization_digest
    @personalization_digest ||= Digest::SHA256.hexdigest([
      Paquette::PypiRepacker::FORMAT_VERSION,
      @license_key,
      @magic_comment_replacements.sort.inspect,
      @files.sort.inspect,
      @stamp.sort.inspect,
      @personalization_key.to_s
    ].join("\0"))[0, 16]
  end
end
