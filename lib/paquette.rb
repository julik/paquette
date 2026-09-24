require "measurometer"

require_relative "paquette/version"

module Paquette
  # The default ceiling on any single regexp match — see RegexpTimeout for
  # what installs it and why. It lives here rather than next to the module so
  # that setting it costs nothing: an application configures this at boot,
  # before it has touched anything that would load the rest of the gem.
  DEFAULT_REGEXP_TIMEOUT = 0.05

  class << self
    # The ceiling every Rack app in this gem installs for the duration of a
    # request, in seconds. Set it at boot; a change under live requests takes
    # effect on the next one. `nil` is "no ceiling", which is Ruby's own
    # default and a decision to make knowingly.
    attr_accessor :regexp_timeout
  end

  self.regexp_timeout = DEFAULT_REGEXP_TIMEOUT

  # Autoloaded rather than required: an application embedding the gem server
  # should not pay for the npm side, and nothing here needs a load order.
  # Absolute paths because config.ru and bin/dev reach this file through
  # require_relative, which does not put lib/ on the load path.
  autoload :CacheValidation, "#{__dir__}/paquette/cache_validation"
  autoload :ConditionalGet, "#{__dir__}/paquette/conditional_get"
  autoload :GemServer, "#{__dir__}/paquette/gem_server"
  autoload :IndexPage, "#{__dir__}/paquette/index_page"
  autoload :NpmRepacker, "#{__dir__}/paquette/npm_repacker"
  autoload :NpmServer, "#{__dir__}/paquette/npm_server"
  autoload :OtpGate, "#{__dir__}/paquette/otp_gate"
  autoload :RegexpTimeout, "#{__dir__}/paquette/regexp_timeout"
  autoload :Routes, "#{__dir__}/paquette/routes"
  autoload :SubdomainRouter, "#{__dir__}/paquette/subdomain_router"
  autoload :Tarball, "#{__dir__}/paquette/tarball"
  autoload :TokenAuthorization, "#{__dir__}/paquette/token_authorization"
end
