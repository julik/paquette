require "measurometer"

require_relative "paquette/version"

module Paquette
  # The default ceiling on any single regexp match, in seconds. Lives here
  # rather than next to RegexpTimeout so that setting it at boot does not
  # load the rest of the gem.
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
  MAX_PUSH_SIZE_BYTES = 50 * 1024 * 1024

  # Autoloaded rather than required: an application embedding the gem server
  # should not pay for the npm side. Absolute paths because config.ru and
  # bin/dev reach this file through require_relative, which does not put
  # lib/ on the load path.
  autoload :CacheValidation, "#{__dir__}/paquette/cache_validation"
  autoload :ConditionalGet, "#{__dir__}/paquette/conditional_get"
  autoload :GemServer, "#{__dir__}/paquette/gem_server"
  autoload :IndexPage, "#{__dir__}/paquette/index_page"
  autoload :NpmRepacker, "#{__dir__}/paquette/npm_repacker"
  autoload :NpmServer, "#{__dir__}/paquette/npm_server"
  autoload :OtpGate, "#{__dir__}/paquette/otp_gate"
  autoload :RegexpTimeout, "#{__dir__}/paquette/regexp_timeout"
  autoload :Routes, "#{__dir__}/paquette/routes"
  autoload :SafeUrl, "#{__dir__}/paquette/safe_url"
  autoload :SubdomainRouter, "#{__dir__}/paquette/subdomain_router"
  autoload :Tarball, "#{__dir__}/paquette/tarball"
  autoload :TokenAuthorization, "#{__dir__}/paquette/token_authorization"
end
