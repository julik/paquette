# What a request turned out to be about, left in the env for the application's
# log line and its monitoring:
#
#   env["paquette.served"] # => {route: "GET /info/:gem_name", package: "zip_kit", version: nil}
#
# The route is there for every request a route matched, refused ones too. The
# package and version only when the server actually served or wrote that
# package - a 2xx, or a 304 on a validator the client held - so a scanner
# probing for names it made up cannot turn each probe into a new tag value.
module Paquette::Served
  # @return [String]
  KEY = "paquette.served"

  # @param env [Hash] the Rack env
  # @param route [Paquette::Routes::Route]
  # @return [void]
  def self.route(env, route)
    env[KEY] = {route: route.metric_name}
  end

  # @param env [Hash] the Rack env
  # @param package [Array(String, String), Array(String), nil] name and version
  # @param status [Integer] the response status
  # @return [void]
  def self.package(env, package, status)
    return unless env[KEY] && package && served?(env, status)

    name, version = package
    env[KEY][:package] = name
    env[KEY][:version] = version if version
  end

  # `If-None-Match: *` matches whatever is asked for, existing or not
  #
  # @param env [Hash]
  # @param status [Integer]
  # @return [Boolean]
  def self.served?(env, status)
    return true if (200..299).cover?(status)

    status == 304 && env["HTTP_IF_NONE_MATCH"].to_s.strip != "*"
  end
  private_class_method :served?
end
