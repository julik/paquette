require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require "measurometer"

# Rewrites each served tarball on the fly for the caller: every marker line
# filled with the value the caller's authenticator gave for it (see
# Paquette::Markers), the values stamped into package.json, files injected -
# with the repacked tarballs cached on disk. Counterpart of
# GemServer::Personalizer.
#
# Built once and shared: who the caller is comes from
# Paquette::Authenticator.current, which the server sets for the request. A
# caller whose authenticator gives no `personalization`, and a package with
# no marker in it, are both served byte for byte - with the repository's own
# integrity hashes, which describe exactly that file.
class Paquette::NpmServer::Personalizer < SimpleDelegator
  # @param repository [Paquette::NpmServer::NpmRepository] the repository
  #   to wrap
  # @param files [Hash{String => String}] path => content, written into every
  #   tarball that carries a marker, with markers in the content filled in
  # @param cache_dir [String, nil] where personalized tarballs and opt-out
  #   markers are kept; the system temp directory is only a default
  def initialize(repository, files: {}, cache_dir: nil)
    super(repository)
    @files = files
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized_npm")
  end

  # The wrapped validator with what this caller gets written into their
  # tarballs mixed in — the packument carries per-caller integrity hashes in
  # the document itself. The key is the same digest that names the cached
  # tarballs on disk, so the validator is exactly as strong as that cache. A
  # caller who gets vanilla bytes gets the wrapped validator as it is.
  #
  # @param scope [String, nil] forwarded to the wrapped repository
  # @return [String, nil]
  def cache_validator(scope = nil)
    inner = Paquette::CacheValidation.validator_of(__getobj__, scope)
    values = personalization
    return inner if values.nil?

    Paquette::CacheValidation.derive_validator(inner, "personalizer", personalization_digest(values))
  end

  # Every byte — and every dist.integrity — is baked for one caller.
  #
  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # @param package_name [String]
  # @param version [String]
  # @return [String, nil] the personalized (or pass-through) tarball path
  def package_file_path(package_name, version)
    original_path = __getobj__.package_file_path(package_name, version)
    return original_path unless original_path && File.exist?(original_path)

    values = personalization
    return original_path if values.nil?

    personalize(original_path, package_name, version, values)
  end

  # The hashes must be the personalized tarball's; the URL stays the repository's.
  #
  # @param package_name [String]
  # @param version [String]
  # @return [Hash{String => String}]
  def dist_for(package_name, version)
    original_dist = __getobj__.dist_for(package_name, version)
    return original_dist if original_dist.empty?

    Measurometer.instrument("paquette.npm_personalizer.dist_for") do
      personalized_path = package_file_path(package_name, version)
      next original_dist unless personalized_path && File.exist?(personalized_path)
      # A package served as it sits on disk is already described by the
      # repository's own hashes.
      next original_dist if personalized_path == __getobj__.package_file_path(package_name, version)

      original_dist.merge(Paquette::Tarball.integrity(personalized_path).transform_keys(&:to_s))
    end
  end

  # The underlying `dist` hashes would fail every install. Every version
  # has to be repacked and re-hashed before this document can be handed
  # out, so a personalized metadata read costs a whole package where the
  # plain one costs a cache lookup.
  #
  # @param package_name [String]
  # @return [Hash, nil]
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

  # Keyed by everything that goes INTO the package: two callers never share
  # a file. See GemServer::Personalizer, whose scheme this is.
  #
  # @param original_path [String]
  # @param package_name [String]
  # @param version [String]
  # @param values [Hash{String => String}]
  # @return [String]
  def personalize(original_path, package_name, version, values)
    stat = File.stat(original_path)
    filename = "#{File.basename(package_name)}-#{version}-#{cache_digest(package_name, version, stat, values)}.tgz"
    personalized_path = File.join(@cache_dir, filename)
    if File.exist?(personalized_path)
      Measurometer.increment_counter("paquette.npm_personalizer.cache_hit")
      return personalized_path
    end

    # Whether a package carries a marker is a fact about the package, so one
    # look inside it answers for everybody.
    marker = plain_marker_path(package_name, version, stat)
    return original_path if File.exist?(marker)

    if Paquette::NpmRepacker.marker_keys(original_path).empty?
      FileUtils.mkdir_p(@cache_dir)
      FileUtils.touch(marker)
      return original_path
    end

    Measurometer.increment_counter("paquette.npm_personalizer.cache_miss")
    FileUtils.mkdir_p(@cache_dir)

    Measurometer.instrument("paquette.npm_personalizer.repack") do
      Dir.mktmpdir("paquette_personalize_npm") do |workdir|
        built = Paquette::NpmRepacker.repack(original_path,
          values: values,
          files: @files,
          into: File.join(workdir, filename))

        FileUtils.mv(built, personalized_path)
      end
    end

    personalized_path
  end

  # The FULL package name — basename keying once served one scope's code as
  # another's. Stat identity, so a replaced tarball invalidates the cache
  # without re-hashing the corpus.
  #
  # @param package_name [String]
  # @param version [String]
  # @param stat [::File::Stat]
  # @param values [Hash{String => String}]
  # @return [String]
  def cache_digest(package_name, version, stat, values)
    Digest::SHA256.hexdigest([
      package_name,
      version,
      personalization_digest(values),
      stat.mtime.to_f,
      stat.size
    ].join("\0"))[0, 24]
  end

  # Where "this package carries nothing to personalize" is written down.
  # Keyed by the package and its source identity alone, never by the
  # caller — whether a package participates is a fact about the package.
  #
  # @param package_name [String]
  # @param version [String]
  # @param stat [::File::Stat]
  # @return [String]
  def plain_marker_path(package_name, version, stat)
    digest = Digest::SHA256.hexdigest([
      package_name, version, stat.mtime.to_f, stat.size
    ].join("\0"))[0, 24]
    File.join(@cache_dir, "#{File.basename(package_name)}-#{version}-#{digest}.plain")
  end

  # Everything that would be written into a tarball for this caller, and the
  # repacker format it is written with. Stable across processes, so a restart
  # does not orphan the cache; a new repacker format does, on purpose. Values
  # only ever come in as data, so the digest sees all of them.
  #
  # @param values [Hash{String => String}]
  # @return [String]
  def personalization_digest(values)
    Digest::SHA256.hexdigest([
      Paquette::NpmRepacker::FORMAT_VERSION,
      values.sort.inspect,
      @files.sort.inspect
    ].join("\0"))[0, 16]
  end
end
