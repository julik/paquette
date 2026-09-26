require "measurometer"

# Routes requests to Rack apps by the first label of the Host header, with an
# optional fallback app for unmapped hosts.
class Paquette::SubdomainRouter
  prepend Paquette::RegexpTimeout

  # @yield [self] for configuring mappings via {#map} and {#fallback}
  def initialize(&block)
    @mappings = {}
    @fallback = nil

    if block_given?
      block.call(self)
    end
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    request = Rack::Request.new(env)
    host = request.host

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

  # @param subdomain [String]
  # @param to [Object] a Rack app, or a class that instantiates to one
  # @return [void]
  def map(subdomain, to:)
    @mappings[subdomain] = to
  end

  # @param to [Object] a Rack app called when no subdomain matches
  # @return [void]
  def fallback(to:)
    @fallback = to
  end

  private

  # @param host [String]
  # @return [String, nil] the first host label, only when it is mapped
  def extract_subdomain(host)
    host = host.split(":").first if host.include?(":")

    if (match = host.match(/\A([a-z\-\d]+)\./))
      subdomain = match[1]
      @mappings.key?(subdomain) ? subdomain : nil
    end
  end
end
