require_relative "gem_server"
require_relative "npm_server"

module Paquette
  class App
    def initialize(gems_dir = nil)
      @gem_server = GemServer.new(gems_dir)
      @npm_server = NpmServer.new
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info

      # Route to appropriate package server based on path
      if path.start_with?("/gems/", "/api/v1/", "/specs.", "/latest_specs.", "/names", "/versions", "/info/") ||
          path == "/"
        # Route to RubyGems server
        @gem_server.call(env)
      elsif path.start_with?("/npm/", "/@") || path.start_with?("/-/") || path.match?(/^\/[^\/]+$/) || path.match?(/^\/[^\/]+\/[^\/]+\.tgz$/)
        # Route to NPM server (for package names like /express, /@scope/package, NPM API endpoints like /-/ping, and tarball downloads)
        @npm_server.call(env)
      else
        # For now, route unknown paths to gem server for backward compatibility
        # Future: route to other package servers (pypi, etc.)
        @gem_server.call(env)
      end
    end
  end
end
