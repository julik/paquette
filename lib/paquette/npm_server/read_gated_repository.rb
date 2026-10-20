require "delegate"
require "measurometer"

# Filters every read through an entitler block; non-entitled packages do
# not exist. Writes pass through - see the gem-side twin.
class Paquette::NpmServer::ReadGatedRepository < SimpleDelegator
  # - `repository`: the repository to wrap
  # - `gate_key`: names this gate for HTTP caching — see the gem-side
  #   ReadGatedRepository for the full contract: name the identity the
  #   entitler consults and everything the answers depend on, or leave it out
  #   and the whole stack emits no ETag (the intended fail-closed default — a
  #   wrong ETag on a gated packument is one customer holding another's
  #   entitlements).
  # - the block: the entitler; returns truthy when the caller may see that
  #   package/version
  #
  #: (Paquette::NpmServer::NpmRepository repository, ?gate_key: String?) { (name: String, ?version: String?) -> boolish } -> void
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  #: () -> String?
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "read-gate", @gate_key)
  end

  # A gate may decide by something Paquette never sees — an IP, a header —
  # so even two anonymous callers can get different views. Never `public`.
  #
  #: () -> bool
  def varies_by_caller?
    true
  end

  #: () -> Array[String]
  def package_names
    super.select { |name| entitled?(name: name) }
  end

  #: () -> Array[[String, String]]
  def package_versions
    super.select do |package_name, version|
      entitled?(name: package_name, version: version)
    end
  end

  #: (String package_name) -> Array[String]
  def versions_for_package(package_name)
    return [] unless entitled?(name: package_name)

    super.select do |version|
      entitled?(name: package_name, version: version)
    end
  end

  #: (String package_name, String version) -> String?
  def package_file_path(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  # false rather than nil: callers treat this as a boolean.
  #
  #: (String package_name, String version) -> bool
  def package_exists?(package_name, version)
    if entitled?(name: package_name, version: version)
      !!super
    else
      false
    end
  end

  #: (String package_name, String version) -> Hash[untyped, untyped]?
  def package_info(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  #: (String package_name, String version) -> Hash[String, String]
  def package_dependencies(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    else
      {}
    end
  end

  #: (String package_name) -> Hash[String, String]
  def dist_tags(package_name)
    return {} unless entitled?(name: package_name)

    entitled = versions_for_package(package_name)
    tags = super.select { |_tag, version| entitled.include?(version) }
    # "latest" must point at a version this caller may actually download.
    tags = tags.merge("latest" => Paquette::NpmServer::NpmRepository.max_release_version(entitled)) if entitled.any?
    tags
  end

  #: (String package_name) -> Hash[untyped, untyped]?
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
  #: (String package_name, String? version) -> Hash[String, untyped]
  def summary_of(package_name, version)
    inner = __getobj__
    inner.respond_to?(:package_summary) ? inner.package_summary(package_name, version) : {}
  end

  # Recomputed so created/modified do not leak withheld publication dates.
  #
  #: (Hash[untyped, untyped]? times, Array[String] entitled) -> Hash[String, String]
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
  # Returns truthy when entitled.
  #
  #: (**untyped criteria) -> untyped
  def entitled?(**criteria)
    Measurometer.instrument("paquette.npm_read_gate.entitled") { @entitler.call(**criteria) }
  end
end

# Former name, kept so existing stacks keep building.
Paquette::NpmServer::GatedNpmRepository = Paquette::NpmServer::ReadGatedRepository

# @rbs!
#   class Paquette::NpmServer::GatedNpmRepository = Paquette::NpmServer::ReadGatedRepository
