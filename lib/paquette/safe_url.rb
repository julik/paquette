require "uri"

# A URL that came out of an uploaded package, narrowed to the shapes that are
# safe to hand to a caller who will render it as a link.
#
# Neither `gem build` nor `npm publish` looks at the scheme of a homepage
# field, so a crafted package can carry `javascript:` or `data:` there and
# Paquette will happily echo it out of `/api/v1/versions`. Paquette renders no
# package metadata of its own, so this is not an exploitable hole here — but
# the endpoint is public and the whole premise of this gem is that it gets
# embedded in somebody else's application, whose customer-facing portal will
# render these values without it ever occurring to its author that they are
# attacker-controlled. Filtering at the source is the only place that reader
# gets protected.
#
# The rule is the one gem.coop settled on: an absolute http(s) URL with a
# host, and nothing else. Scheme-relative (`//evil.test`) and relative values
# are refused too — a browser resolves them against whatever page they land
# on, so "where does this point" is not answerable from the value alone.
module Paquette::SafeUrl
  module_function

  # The value unchanged when it is an absolute http(s) URL with a non-empty
  # host, `nil` otherwise. Returns the original string byte for byte rather
  # than URI's normalization of it: this is a filter, not a rewriter, and a
  # URL that survives should reach the client exactly as it was published.
  #
  # Never raises. A gemspec field carries whatever bytes the uploader put
  # there, including bytes that are not valid UTF-8 — the same hazard
  # `GemServer.split_gem_filename` guards against — and URI's parser raises
  # on those rather than declining to match.
  def http_url(value)
    str = value.to_s
    return nil unless str.valid_encoding?
    return nil if str.empty?

    # URI::HTTPS subclasses URI::HTTP, so this covers both and nothing else.
    uri = URI.parse(str)
    return nil unless uri.is_a?(URI::HTTP)
    return nil if uri.host.nil? || uri.host.empty?

    str
  rescue URI::InvalidURIError, ArgumentError, Encoding::CompatibilityError
    nil
  end
end
