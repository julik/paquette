require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require "measurometer"

# Serves each wheel and sdist repacked for the caller - every marker line
# filled with the value the caller's authenticator gave for it (see
# Paquette::Markers), the values written to paquette.json, files injected -
# with the repacked files cached on disk. Counterpart of
# NpmServer::Personalizer.
#
# Built once and shared: who the caller is comes from
# Paquette::Authenticator.current, which the server sets for the request. A
# caller whose authenticator gives no `personalization`, and a file with no
# marker in it, are both served byte for byte.
class Paquette::PypiServer::Personalizer < SimpleDelegator
  # @param repository [Paquette::PypiServer::PypiRepository] the repository
  #   to wrap
  # @param files [Hash{String => String}] injected into every file that
  #   carries a marker, path relative to the archive root - site-packages,
  #   for a wheel - with markers in the content filled in
  # @param cache_dir [String, nil] where personalized files and opt-out
  #   markers are kept
  def initialize(repository, files: {}, cache_dir: nil)
    super(repository)
    @files = files
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized_pypi")
  end

  # The wrapped validator with what this caller gets written into their files
  # mixed in - see the gem-side Personalizer. A caller who gets vanilla bytes
  # gets the wrapped validator as it is.
  #
  # @param scope [String, nil] forwarded to the wrapped repository
  # @return [String, nil]
  def cache_validator(scope = nil)
    inner = Paquette::CacheValidation.validator_of(__getobj__, scope)
    values = personalization
    return inner if values.nil?

    Paquette::CacheValidation.derive_validator(inner, "personalizer", personalization_digest(values))
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

    values = personalization
    return original_path if values.nil?

    personalize(original_path, project, filename, values)
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

  # The current caller's values. nil when there is nobody to personalize for.
  #
  # @return [Hash{String => String}, nil]
  def personalization
    authenticator = Paquette::Authenticator.current
    return nil unless authenticator.respond_to?(:personalization)

    values = authenticator.personalization
    return nil if values.nil? || values.empty?

    Paquette::Markers.check_values!(values)
    values
  end

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

  # Keyed by everything that goes INTO the file: two callers never share one.
  # Consulted before the file is ever opened.
  #
  # @param original_path [String]
  # @param project [String]
  # @param filename [String]
  # @param values [Hash{String => String}]
  # @return [String]
  def personalize(original_path, project, filename, values)
    stat = File.stat(original_path)
    # The served filename is the original one - pip reads the tags out of
    # it - so the digest goes into a directory instead
    personalized_path = File.join(@cache_dir, cache_digest(project, filename, stat, values), filename)
    if File.exist?(personalized_path)
      Measurometer.increment_counter("paquette.pypi_personalizer.cache_hit")
      return personalized_path
    end

    # Whether a file carries a marker is a fact about the file, so one look
    # inside it answers for everybody.
    marker = plain_marker_path(project, filename, stat)
    return original_path if File.exist?(marker)

    if Paquette::PypiRepacker.marker_keys(original_path, filename: filename).empty?
      FileUtils.mkdir_p(File.dirname(marker))
      FileUtils.touch(marker)
      return original_path
    end

    Measurometer.increment_counter("paquette.pypi_personalizer.cache_miss")
    FileUtils.mkdir_p(File.dirname(personalized_path))

    Measurometer.instrument("paquette.pypi_personalizer.repack") do
      Dir.mktmpdir("paquette_personalize_pypi") do |workdir|
        built = Paquette::PypiRepacker.repack(original_path,
          filename: filename,
          values: values,
          files: @files,
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
  # @param values [Hash{String => String}]
  # @return [String]
  def cache_digest(project, filename, stat, values)
    Digest::SHA256.hexdigest([project, filename, personalization_digest(values), stat.mtime.to_r, stat.size].join("\0"))[0, 24]
  end

  # Keyed by the file alone, never the caller - see NpmServer::Personalizer.
  #
  # @param project [String]
  # @param filename [String]
  # @param stat [::File::Stat]
  # @return [String]
  def plain_marker_path(project, filename, stat)
    digest = Digest::SHA256.hexdigest([project, filename, stat.mtime.to_r, stat.size].join("\0"))[0, 24]
    File.join(@cache_dir, "plain", "#{digest}.plain")
  end

  # Everything that would be written into a file for this caller, and the
  # repacker format it is written with. Values only ever come in as data, so
  # the digest sees all of them - there is nothing to declare.
  #
  # @param values [Hash{String => String}]
  # @return [String]
  def personalization_digest(values)
    Digest::SHA256.hexdigest([
      Paquette::PypiRepacker::FORMAT_VERSION,
      values.sort.inspect,
      @files.sort.inspect
    ].join("\0"))[0, 16]
  end
end
