require "digest"

# How a repository stack names itself to an HTTP cache. Both servers wrap a
# base repository in per-caller gates and personalizers, so a validator
# derived from the corpus alone would let one licensee's cached response
# satisfy another's — the digest rules live here, once, for both servers.
module Paquette::CacheValidation
  module_function

  # The stack's validator. Fails closed (nil) for an object that has never
  # heard of the protocol.
  #
  # The scope is the one package an endpoint is about, or nil for the whole
  # corpus. A gate's validator is a digest of what the caller can see, which
  # costs one entitlement question per package in scope - so an endpoint about
  # one package says so, and pays for that package alone. A repository whose
  # `cache_validator` takes no argument is asked without one.
  #
  # @param repository [Object]
  # @param scope [String, nil]
  # @return [String, nil]
  def validator_of(repository, scope = nil)
    return nil unless repository.respond_to?(:cache_validator)

    if repository.method(:cache_validator).arity.zero?
      repository.cache_validator
    else
      repository.cache_validator(scope)
    end
  end

  # Whether two callers asking the stack the same question can get different
  # answers — which decides whether an anonymous response may be `public`.
  # True for anything that cannot say: being wrong the other way only costs
  # a cache hit.
  #
  # @param repository [Object]
  # @return [Boolean]
  def varies_by_caller?(repository)
    return true unless repository.respond_to?(:varies_by_caller?)

    repository.varies_by_caller? != false
  end

  # How a wrapper mixes itself into the validator of what it wraps. nil in
  # either position gives nil out — the fail-closed rule the whole protocol
  # rests on. The layer name is in the digest so that gating with key "k"
  # and personalizing with key "k" cannot land on the same string.
  #
  # @param inner_validator [String, nil] the wrapped stack's validator
  # @param layer [String] a constant naming the wrapping layer
  # @param key [String, nil] what distinguishes this instance of the layer
  # @return [String, nil]
  def derive_validator(inner_validator, layer, key)
    return nil if inner_validator.nil? || key.nil?

    Digest::SHA256.base64digest([inner_validator, layer, key].join("\0"))
  end

  # The validator for one response. Returns nil, meaning "emit no ETag",
  # whenever the stack refused to name itself.
  #
  # @param repository [Object]
  # @param resource_parts [Array<String>] what distinguishes this endpoint's
  #   body from another's over the same corpus
  # @param scope [String, nil] the one package the endpoint is about, if any
  # @param weak [Boolean]
  # @return [String, nil]
  def etag_for(repository, *resource_parts, scope: nil, weak: false)
    base = validator_of(repository, scope)
    return nil if base.nil?

    tag = %("#{Digest::SHA256.base64digest([base, *resource_parts].join("\0"))}")
    weak ? "W/#{tag}" : tag
  end
end
