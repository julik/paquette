require "delegate"
require "measurometer"

# Wraps a gem repository and filters every read through an entitler block:
# non-entitled gems disappear from listings, return nil paths, and report
# as non-existent. Writes pass through - who may write is the authenticator's
# to say, and the server asks it before any repository is touched.
class Paquette::GemServer::ReadGatedRepository < SimpleDelegator
  # - `repository`: the repository to wrap
  # - `gate_key`: what this gate is called, for HTTP caching: the identity the
  #   entitler consults plus everything the answers depend on. Left out, the
  #   whole stack emits no ETag and serves every request in full — the
  #   intended fail-closed default, because a wrong ETag hands one customer
  #   another's entitlements.
  # - the block: the entitler; returns truthy when the caller may see that
  #   gem/version
  #
  #: (Paquette::GemServer::GemRepository repository, ?gate_key: String?) { (name: String, ?version: String?) -> boolish } -> void
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  # nil without a gate_key — derive_validator does the refusing.
  #
  #: () -> String?
  def cache_validator
    inner = Paquette::GemServer::GemRepository.cache_validator_of(__getobj__)
    Paquette::GemServer::GemRepository.derive_validator(inner, "read-gate", @gate_key)
  end

  # A gate may decide by something Paquette never sees — an IP, a header —
  # so even two anonymous callers can get different views. Never `public`.
  #
  #: () -> bool
  def varies_by_caller?
    true
  end

  # Asked through the class method rather than with `super` so that an
  # inner repository predating this protocol answers nil instead of
  # raising NoMethodError out of Delegator#method_missing.
  #
  #: (String gem_name, String version) -> String?
  def gem_checksum(gem_name, version)
    return nil unless entitled?(name: gem_name, version: version)

    Paquette::GemServer::GemRepository.gem_checksum_of(__getobj__, gem_name, version)
  end

  #: () -> Array[String]
  def gem_names
    super.select { |name| entitled?(name: name) }
  end

  #: () -> Array[[String, String]]
  def gem_versions
    super.select do |gem_name, version|
      entitled?(name: gem_name, version: version)
    end
  end

  #: (String gem_name) -> Array[String]
  def versions_for_gem(gem_name)
    return [] unless entitled?(name: gem_name)
    super.select do |version|
      entitled?(name: gem_name, version: version)
    end
  end

  #: (String gem_name, String version) -> String?
  def gem_file_path(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    end
  end

  #: (String gem_name) -> untyped
  def compact_info(gem_name)
    return [] unless entitled?(name: gem_name)

    all_info = super
    return all_info unless all_info.is_a?(Array)

    all_info.select do |line|
      version = line.split(" ")[0]
      entitled?(name: gem_name, version: version)
    end
  end

  #: (String gem_name, String version) -> bool
  def gem_exists?(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    else
      false
    end
  end

  # The entitler is the caller's, and a listing calls it once per gem in
  # the corpus — an entitler that reaches for a database on every call is
  # the usual reason a gated index is slower than an ungated one.
  #
  # Returns truthy when entitled.
  #
  #: (**untyped criteria) -> untyped
  def entitled?(**criteria)
    Measurometer.instrument("paquette.gem_read_gate.entitled") { @entitler.call(**criteria) }
  end
end
