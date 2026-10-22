require "delegate"
require "digest"
require "measurometer"

# Filters every read through the caller's authenticator; non-entitled packages
# do not exist. Writes pass through - see the gem-side twin, which the server
# applies the same way: for every request whose authenticator answers
# `entitled?`.
class Paquette::NpmServer::ReadGatedRepository < SimpleDelegator
  # @param repository [Paquette::NpmServer::NpmRepository] the repository
  #   to wrap
  # @param authenticator [Paquette::Authenticator] the caller's, answering
  #   `entitled?(name:, version: nil)`
  def initialize(repository, authenticator)
    super(repository)
    @authenticator = authenticator
  end

  # What this caller can see within the scope, digested into the wrapped
  # validator - see the gem-side twin for why, and for why a caller who sees
  # nothing gets none.
  #
  # @param scope [String, nil] one package name, or nil for the whole corpus
  # @return [String, nil]
  def cache_validator(scope = nil)
    inner = Paquette::CacheValidation.validator_of(__getobj__, scope)
    return nil if inner.nil?

    visible = if scope
      versions_for_package(scope).map { |version| [scope, version] }
    else
      package_names.zip + package_versions
    end
    return nil if visible.empty?

    Paquette::CacheValidation.derive_validator(inner, "read-gate", Digest::SHA256.hexdigest(visible.sort.join("\0")))
  end

  # A gate may decide by something Paquette never sees — an IP, a header —
  # so even two anonymous callers can get different views. Never `public`.
  #
  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # @return [Array<String>]
  def package_names
    super.select { |name| entitled?(name: name) }
  end

  # @return [Array<Array(String, String)>]
  def package_versions
    super.select do |package_name, version|
      entitled?(name: package_name, version: version)
    end
  end

  # @param package_name [String]
  # @return [Array<String>]
  def versions_for_package(package_name)
    return [] unless entitled?(name: package_name)

    super.select do |version|
      entitled?(name: package_name, version: version)
    end
  end

  # @param package_name [String]
  # @param version [String]
  # @return [String, nil]
  def package_file_path(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  # false rather than nil: callers treat this as a boolean.
  #
  # @param package_name [String]
  # @param version [String]
  # @return [Boolean]
  def package_exists?(package_name, version)
    if entitled?(name: package_name, version: version)
      !!super
    else
      false
    end
  end

  # @param package_name [String]
  # @param version [String]
  # @return [Hash, nil]
  def package_info(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  # @param package_name [String]
  # @param version [String]
  # @return [Hash{String => String}]
  def package_dependencies(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    else
      {}
    end
  end

  # @param package_name [String]
  # @return [Hash{String => String}]
  def dist_tags(package_name)
    return {} unless entitled?(name: package_name)

    entitled = versions_for_package(package_name)
    tags = super.select { |_tag, version| entitled.include?(version) }
    # "latest" must point at a version this caller may actually download.
    tags = tags.merge("latest" => Paquette::NpmServer::NpmRepository.max_release_version(entitled)) if entitled.any?
    tags
  end

  # @param package_name [String]
  # @return [Hash, nil]
  def package_metadata(package_name)
    return nil unless entitled?(name: package_name)

    metadata = super
    return metadata unless metadata

    entitled = versions_for_package(package_name)
    # A fully gated package does not exist for this caller.
    return nil if entitled.empty?

    # A leaner custom repository is filtered, not crashed on.
    versions = metadata["versions"].is_a?(Hash) ? metadata["versions"].slice(*entitled) : {}

    newest = Paquette::NpmServer::NpmRepository.max_release_version(entitled)
    metadata.except(*Paquette::NpmServer::NpmRepository::SUMMARY_FIELDS).merge(summary_of(package_name, newest)).merge(
      "versions" => versions,
      "time" => entitled_times(metadata["time"], entitled),
      "dist-tags" => dist_tags(package_name)
    )
  end

  # A repository predating package_summary gets no summary at all rather than
  # the newest release's.
  #
  # @param package_name [String]
  # @param version [String]
  # @return [Hash{String => Object}]
  def summary_of(package_name, version)
    inner = __getobj__
    inner.respond_to?(:package_summary) ? inner.package_summary(package_name, version) : {}
  end

  # Recomputed so created/modified do not leak withheld publication dates.
  #
  # @param times [Hash, nil]
  # @param entitled [Array<String>]
  # @return [Hash{String => String}]
  def entitled_times(times, entitled)
    return {} unless times.is_a?(Hash)

    entitled_times = times.slice(*entitled)
    return entitled_times if entitled_times.empty?

    stamps = entitled_times.values.sort
    entitled_times.merge("created" => stamps.first, "modified" => stamps.last)
  end

  # The entitler is the caller's, and a listing calls it once per package
  # in the corpus — an entitler that reaches for a database on every call
  # is the usual reason a gated index is slower than an ungated one.
  #
  # @param criteria [Hash]
  # @return [Object] truthy when entitled
  def entitled?(**criteria)
    Measurometer.instrument("paquette.npm_read_gate.entitled") { @authenticator.entitled?(**criteria) }
  end
end
