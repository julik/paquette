module Paquette
  VERSION = "0.1.0"

  require_relative "paquette/routes"
  require_relative "paquette/gem_server/gem_repository"
  require_relative "paquette/gem_server/directory_gem_repository"
  require_relative "paquette/gem_server"
  require_relative "paquette/npm_server"
  require_relative "paquette/subdomain_router"
  require_relative "paquette/gem_repacker"
  require_relative "paquette/npm_repacker"
end
