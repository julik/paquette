require "delegate"
require "fileutils"
require "digest"
require "tmpdir"
require "measurometer"

# Rewrites each served tarball on the fly to embed the licensee's key;
# counterpart of GemServer::Personalizer.
class Paquette::NpmServer::Personalizer < SimpleDelegator
  # The caller keeps the two contracts spelled out on
  # GemServer::Personalizer: what `files_for:` returns depends only on the
  # tarball and `personalization_key:`, and nil is a fact about the
  # package, never about the licensee.
  #
  # - `repository`: the repository to wrap
  # - `magic_comment_replacements`: checked here as well as in the repacker,
  #   so a bad pair is refused where the stack is built rather than on the
  #   first customer download
  # - `files`: files injected into every tarball
  # - `package_json_extras`: merged into package.json; defaults to a
  #   "paquette" key carrying the license key
  # - `files_for`: per-package files, called with (package_name, version,
  #   original_path); nil return means the package is served byte for byte
  # - `personalization_key`: everything the personalized bytes depend on
  #   beyond the tarball itself
  # - `cache_dir`: where personalized tarballs and opt-out markers are kept;
  #   the system temp directory is only a default
  #
  #: (Paquette::NpmServer::NpmRepository repository, license_key: String, ?magic_comment_replacements: Hash[String, String], ?files: Hash[String, String], ?package_json_extras: Hash[String, untyped]?, ?files_for: Proc?, ?personalization_key: String?, ?cache_dir: String?) -> void
  def initialize(repository, license_key:, magic_comment_replacements: {}, files: {},
    package_json_extras: nil, files_for: nil, personalization_key: nil, cache_dir: nil)
    Paquette::NpmRepacker.check_replacements!(magic_comment_replacements)
    super(repository)
    @license_key = license_key
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @package_json_extras = package_json_extras || {"paquette" => {"licenseKey" => license_key}}
    @files_for = files_for
    @personalization_key = personalization_key
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized_npm")
  end

  # The wrapped validator with this personalizer's identity mixed in — the
  # packument carries per-licensee integrity hashes in the document
  # itself. The key is the same digest that names the cached tarballs on
  # disk, so the validator is exactly as strong as that cache.
  #
  #: () -> String?
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "personalizer", personalization_digest)
  end

  # Every byte — and every dist.integrity — is baked for one licensee.
  #
  #: () -> bool
  def varies_by_caller?
    true
  end

  # Returns the personalized (or pass-through) tarball path.
  #
  #: (String package_name, String version) -> String?
  def package_file_path(package_name, version)
    original_path = __getobj__.package_file_path(package_name, version)
    return original_path unless original_path && File.exist?(original_path)

    personalize(original_path, package_name, version)
  end

  # The hashes must be the personalized tarball's; the URL stays the repository's.
  #
  #: (String package_name, String version) -> Hash[String, String]
  def dist_for(package_name, version)
    original_dist = __getobj__.dist_for(package_name, version)
    return original_dist if original_dist.empty?

    Measurometer.instrument("paquette.npm_personalizer.dist_for") do
      personalized_path = package_file_path(package_name, version)
      next original_dist unless personalized_path && File.exist?(personalized_path)
      # A package files_for opted out of is served as it sits on disk, and
      # the repository's own hashes already describe that file.
      next original_dist if personalized_path == __getobj__.package_file_path(package_name, version)

      original_dist.merge(Paquette::Tarball.integrity(personalized_path).transform_keys(&:to_s))
    end
  end

  # The underlying `dist` hashes would fail every install. Every version
  # has to be repacked and re-hashed before this document can be handed
  # out, so a personalized metadata read costs a whole package where the
  # plain one costs a cache lookup.
  #
  #: (String package_name) -> Hash[untyped, untyped]?
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
  # share a file. See GemServer::Personalizer, whose scheme this is.
  #
  #: (String original_path, String package_name, String version) -> String
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
        built = Paquette::NpmRepacker.repack(original_path,
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
  #
  #: (String package_name, String version, ::File::Stat stat) -> String
  def cache_digest(package_name, version, stat)
    Digest::SHA256.hexdigest([
      package_name,
      version,
      personalization_digest,
      stat.mtime.to_f,
      stat.size
    ].join("\0"))[0, 24] #: String
  end

  # Where "this package carries nothing to personalize" is written down.
  # Keyed by the package and its source identity alone, never by the
  # licensee — whether a package participates is a fact about the package.
  #
  #: (String package_name, String version, ::File::Stat stat) -> String
  def plain_marker_path(package_name, version, stat)
    digest = Digest::SHA256.hexdigest([
      package_name, version, stat.mtime.to_f, stat.size
    ].join("\0"))[0, 24]
    File.join(@cache_dir, "#{File.basename(package_name)}-#{version}-#{digest}.plain")
  end

  # Everything this personalizer would write into a tarball, and the
  # repacker format it writes it with. Stable across processes, so a restart
  # does not orphan the cache; a new repacker format does, on purpose.
  #
  #: () -> String
  def personalization_digest
    @personalization_digest ||= Digest::SHA256.hexdigest([
      Paquette::NpmRepacker::FORMAT_VERSION,
      @license_key,
      @magic_comment_replacements.sort.inspect,
      @files.sort.inspect,
      @package_json_extras.sort.inspect,
      @personalization_key.to_s
    ].join("\0"))[0, 16] #: String
  end
end
