require "uri"

# Narrows a URL that came out of an uploaded package to the shapes safe to
# hand to a caller who will render it as a link: an absolute http(s) URL with
# a host, and nothing else. Package metadata is attacker-controlled, and the
# embedding application's portal will render these values.
module Paquette::SafeUrl
  module_function

  # Returns the value unchanged when it is an absolute http(s) URL with a
  # non-empty host, `nil` otherwise. Never raises: the field can carry bytes
  # that are not valid UTF-8, on which URI's parser raises rather than
  # declining to match.
  #
  # @param value [Object] the published field value
  # @return [String, nil] the original string byte for byte — this is a
  #   filter, not a rewriter
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
