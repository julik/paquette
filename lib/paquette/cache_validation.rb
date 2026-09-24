require "digest"

# How a repository stack names itself to an HTTP cache.
#
# Both servers in this gem are built the same way: a base repository
# wrapped per request in a gate (each licensee sees a different subset of
# the corpus) and a personalizer (each licensee gets different bytes, and
# on the npm side a different *document* - the packument carries per-version
# integrity hashes that are computed per licensee). A validator derived from
# the corpus alone would therefore let one licensee's cached response
# satisfy another licensee's request, which is a confidentiality bug and
# strictly worse than not caching at all.
#
# The rules live here, in one place, rather than once per server. Two
# servers are two chances to get a security-critical digest subtly
# different from each other, and there is nothing package-format-specific
# about any of this - GemRepository and NpmRepository each expose these
# under their own names and both land here.
module Paquette::CacheValidation
  module_function

  # The stack's validator, asked of an object that may implement the
  # protocol, may be a SimpleDelegator wrapping one, or may be somebody's
  # duck-typed stand-in that has never heard of it. Fail closed in that
  # last case rather than assuming.
  def validator_of(repository)
    repository.cache_validator if repository.respond_to?(:cache_validator)
  end

  # How a wrapper mixes itself into the validator of what it wraps: one
  # digest over the inner validator, a constant naming the layer, and the
  # key that distinguishes one instance of that layer from another.
  #
  # nil in either position gives nil out, which is the fail-closed rule the
  # whole protocol rests on - an inner layer that refused to name itself
  # cannot be named from outside, and a layer with no key of its own is
  # exactly the case where guessing leaks one caller's view to the next.
  # The layer name is in the digest so that gating with key "k" and
  # personalizing with key "k" cannot land on the same string.
  def derive_validator(inner_validator, layer, key)
    return nil if inner_validator.nil? || key.nil?

    Digest::SHA256.base64digest([inner_validator, layer, key].join("\0"))
  end

  # The validator for one response, given the stack's validator and
  # whatever distinguishes this endpoint's body from another's over the
  # same corpus - the route, the package name, the base URL the document
  # embeds. Returns nil, meaning "emit no ETag", whenever the stack
  # refused to name itself.
  def etag_for(repository, *resource_parts, weak: false)
    base = validator_of(repository)
    return nil if base.nil?

    tag = %("#{Digest::SHA256.base64digest([base, *resource_parts].join("\0"))}")
    weak ? "W/#{tag}" : tag
  end
end
