require "delegate"
require "measurometer"

# Filters every read through an entitler block; non-entitled packages do
# not exist. Writes always raise: a gated caller may not mutate the corpus.
class Paquette::NpmServer::ReadGatedRepository < SimpleDelegator
  # Raised by every write on a gated repository.
  class WriteNotAllowed < StandardError; end

  # @param repository [Paquette::NpmServer::NpmRepository] the repository
  #   to wrap
  # @param gate_key [String, nil] names this gate for HTTP caching — see
  #   the gem-side ReadGatedRepository for the full contract: name the
  #   identity the entitler consults and everything the answers depend on,
  #   or leave it out and the whole stack emits no ETag (the intended
  #   fail-closed default — a wrong ETag on a gated packument is one
  #   customer holding another's entitlements).
  # @yield [name:, version:] the entitler; returns truthy when the caller
  #   may see that package/version
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  # @return [String, nil]
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "read-gate", @gate_key)
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

    metadata.merge(
      "versions" => versions,
      "time" => entitled_times(metadata["time"], entitled),
      "dist-tags" => dist_tags(package_name)
    )
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
    Measurometer.instrument("paquette.npm_read_gate.entitled") { @entitler.call(**criteria) }
  end

  # @raise [WriteNotAllowed] always
  def add_package(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  # @raise [WriteNotAllowed] always
  def yank_package(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  # @raise [WriteNotAllowed] always
  def write_dist_tag(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end
end

# Former name, kept so existing stacks keep building.
Paquette::NpmServer::GatedNpmRepository = Paquette::NpmServer::ReadGatedRepository
