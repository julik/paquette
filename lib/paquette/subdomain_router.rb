require_relative "gem_server"
require_relative "npm_server"

module Paquette
  class SubdomainRouter
    def initialize(&block)
      @mappings = {}
      @fallback = nil

      if block_given?
        block.call(self)
      end
    end

    def call(env)
      request = Rack::Request.new(env)
      host = request.host

      # Extract subdomain from host
      subdomain = extract_subdomain(host)

      if subdomain && @mappings[subdomain]
        app = @mappings[subdomain]
        if app.respond_to?(:call)
          app.call(env)
        else
          # If it's a class, instantiate it
          app.new.call(env)
        end
      elsif @fallback
        @fallback.call(env)
      else
        [404, {}, ["Subdomain not found"]]
      end
    end

    def map(subdomain, to:)
      @mappings[subdomain] = to
    end

    def fallback(to:)
      @fallback = to
    end

    private

    def extract_subdomain(host)
      # Handle localhost with port (e.g., localhost:9292)
      host = host.split(":").first if host.include?(":")

      # Extract the first part of the hostname (subdomain)
      if (match = host.match(/^([a-z\-\d]+)\./))
        subdomain = match[1]
        # Only return if this subdomain is actually mapped
        @mappings.key?(subdomain) ? subdomain : nil
      end
    end
  end
end
