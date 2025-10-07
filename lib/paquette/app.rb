require_relative "gem_server"
require_relative "npm_server"

module Paquette
  class App
    def initialize
      @gem_server = GemServer.new
      @npm_server = NpmServer.new
    end

    def call(env)
      # Default behavior: route to gem server for backward compatibility
      # The subdomain routing middleware will handle the actual routing
      @gem_server.call(env)
    end
  end
end
