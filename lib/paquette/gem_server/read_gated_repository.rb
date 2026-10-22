require "delegate"
require "digest"
require "measurometer"

# Wraps a gem repository and filters every read through the caller's
# authenticator: a gem the caller is not entitled to disappears from
# listings, returns nil paths, and reports as non-existent. Writes pass
# through - who may write is the authenticator's to say, and the server asks
# it before any repository is touched.
#
# The server puts one of these around its repository for every request whose
# authenticator answers `entitled?`, so an application never builds one.
class Paquette::GemServer::ReadGatedRepository < SimpleDelegator
  # @param repository [Paquette::GemServer::GemRepository] the repository
  #   to wrap
  # @param authenticator [Paquette::Authenticator] the caller's, answering
  #   `entitled?(name:, version: nil)` - truthy when they may see that gem,
  #   or that version of it
  def initialize(repository, authenticator)
    super(repository)
    @authenticator = authenticator
  end

  # The wrapped validator with what this caller can see mixed in: the names
  # and versions the gate lets through, within the scope. Exact by
  # construction - the ETag moves when and only when the visible set does -
  # at the price of one entitlement question per package in scope, which is
  # the same question rendering the body asks. A caller who can see nothing
  # gets no validator: their response is empty and cheap, and an ETag over it
  # would still move with the corpus beneath the gate, telling a stranger
  # when gems they cannot see are published.
  #
  # @param scope [String, nil] one gem name, or nil for the whole corpus
  # @return [String, nil]
  def cache_validator(scope = nil)
    inner = Paquette::GemServer::GemRepository.cache_validator_of(__getobj__, scope)
    return nil if inner.nil?

    visible = if scope
      versions_for_gem(scope).map { |version| [scope, version] }
    else
      gem_names.zip + gem_versions
    end
    return nil if visible.empty?

    Paquette::GemServer::GemRepository.derive_validator(inner, "read-gate", Digest::SHA256.hexdigest(visible.sort.join("\0")))
  end

  # A gate may decide by something Paquette never sees — an IP, a header —
  # so even two anonymous callers can get different views. Never `public`.
  #
  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # Asked through the class method rather than with `super` so that an
  # inner repository predating this protocol answers nil instead of
  # raising NoMethodError out of Delegator#method_missing.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil]
  def gem_checksum(gem_name, version)
    return nil unless entitled?(name: gem_name, version: version)

    Paquette::GemServer::GemRepository.gem_checksum_of(__getobj__, gem_name, version)
  end

  # @return [Array<String>]
  def gem_names
    super.select { |name| entitled?(name: name) }
  end

  # @return [Array<Array(String, String)>]
  def gem_versions
    super.select do |gem_name, version|
      entitled?(name: gem_name, version: version)
    end
  end

  # @param gem_name [String]
  # @return [Array<String>]
  def versions_for_gem(gem_name)
    return [] unless entitled?(name: gem_name)
    super.select do |version|
      entitled?(name: gem_name, version: version)
    end
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil]
  def gem_file_path(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    end
  end

  # @param gem_name [String]
  # @return [Array<String>, Object]
  def compact_info(gem_name)
    return [] unless entitled?(name: gem_name)

    all_info = super
    return all_info unless all_info.is_a?(Array)

    all_info.select do |line|
      version = line.split(" ")[0]
      entitled?(name: gem_name, version: version)
    end
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Boolean]
  def gem_exists?(gem_name, version)
    if entitled?(name: gem_name, version: version)
      super
    else
      false
    end
  end

  # The authenticator is the caller's, and a listing asks it once per gem in
  # the corpus — one that reaches for a database on every call, instead of
  # remembering what it learned for the request, is the usual reason a gated
  # index is slower than an ungated one.
  #
  # @param criteria [Hash]
  # @return [Object] truthy when entitled
  def entitled?(**criteria)
    Measurometer.instrument("paquette.gem_read_gate.entitled") { @authenticator.entitled?(**criteria) }
  end
end
