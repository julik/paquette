module Paquette
  require "measurometer"

  require_relative "paquette/version"

  require_relative "paquette/regexp_timeout"
  require_relative "paquette/routes"
  require_relative "paquette/index_page"
  require_relative "paquette/tarball"
  require_relative "paquette/gem_server/gem_repository"
  require_relative "paquette/gem_server/directory_gem_repository"
  require_relative "paquette/gem_server"
  require_relative "paquette/npm_server/npm_repository"
  require_relative "paquette/npm_server/directory_npm_repository"
  require_relative "paquette/npm_server"
  require_relative "paquette/subdomain_router"
  require_relative "paquette/gem_server/gem_repacker"
  require_relative "paquette/npm_repacker"
  require_relative "paquette/token_authorization"
  require_relative "paquette/otp_gate"
end
