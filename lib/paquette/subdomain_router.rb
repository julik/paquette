require "measurometer"

require_relative "gem_server"
require_relative "npm_server"
require_relative "regexp_timeout"

module Paquette
  class SubdomainRouter
    prepend RegexpTimeout

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
        # Named after the subdomain, which is mapped and therefore bounded —
        # the host header is attacker-controlled and would be one metric per
        # probe.
        Measurometer.instrument("paquette.subdomain_router.#{subdomain}") do
          if app.respond_to?(:call)
            app.call(env)
          else
            # If it's a class, instantiate it
            app.new.call(env)
          end
        end
      elsif @fallback
        Measurometer.instrument("paquette.subdomain_router.fallback") { @fallback.call(env) }
      else
        Measurometer.increment_counter("paquette.subdomain_router.unmapped")
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
      if (match = host.match(/\A([a-z\-\d]+)\./))
        subdomain = match[1]
        # Only return if this subdomain is actually mapped
        @mappings.key?(subdomain) ? subdomain : nil
      end
    end
  end
end
