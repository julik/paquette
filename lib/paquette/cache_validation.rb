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
  # @param repository [Object]
  # @return [String, nil]
  def validator_of(repository)
    repository.cache_validator if repository.respond_to?(:cache_validator)
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
  # @param weak [Boolean]
  # @return [String, nil]
  def etag_for(repository, *resource_parts, weak: false)
    base = validator_of(repository)
    return nil if base.nil?

    tag = %("#{Digest::SHA256.base64digest([base, *resource_parts].join("\0"))}")
    weak ? "W/#{tag}" : tag
  end
end
