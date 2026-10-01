require "measurometer"

require_relative "paquette/version"

# Rack building blocks for serving RubyGems and npm packages out of a
# directory, with the index formats, conditional GETs and push endpoints the
# two clients expect.
module Paquette
  # The default ceiling on any single regexp match, in seconds. Lives here
  # rather than next to RegexpTimeout so that setting it at boot does not
  # load the rest of the gem.
  #
  # @return [Float]
  DEFAULT_REGEXP_TIMEOUT = 0.05

  class << self
    # The regexp timeout every Rack app in this gem installs for the duration
    # of a request, in seconds. `nil` is "no ceiling".
    #
    # @return [Float, nil]
    attr_accessor :regexp_timeout
  end

  self.regexp_timeout = DEFAULT_REGEXP_TIMEOUT

  # The largest package push either server accepts, in bytes — the default
  # for the `max_push_bytes:` keyword both take. `nil` removes the cap.
  #
  # @return [Integer]
  MAX_PUSH_SIZE_BYTES = 50 * 1024 * 1024

  # Autoloaded rather than required: an application embedding the gem server
  # should not pay for the npm side. Absolute paths because config.ru and
  # bin/dev reach this file through require_relative, which does not put
  # lib/ on the load path.
  autoload :Access, "#{__dir__}/paquette/access"
  autoload :Authentication, "#{__dir__}/paquette/authentication"
  autoload :CacheValidation, "#{__dir__}/paquette/cache_validation"
  autoload :ConditionalGet, "#{__dir__}/paquette/conditional_get"
  autoload :GemServer, "#{__dir__}/paquette/gem_server"
  autoload :IndexPage, "#{__dir__}/paquette/index_page"
  autoload :NpmRepacker, "#{__dir__}/paquette/npm_repacker"
  autoload :NpmServer, "#{__dir__}/paquette/npm_server"
  autoload :RegexpTimeout, "#{__dir__}/paquette/regexp_timeout"
  autoload :Routes, "#{__dir__}/paquette/routes"
  autoload :SafeUrl, "#{__dir__}/paquette/safe_url"
  autoload :SubdomainRouter, "#{__dir__}/paquette/subdomain_router"
  autoload :Tarball, "#{__dir__}/paquette/tarball"
end
