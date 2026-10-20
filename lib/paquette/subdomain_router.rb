require "measurometer"

# Routes requests to Rack apps by the first label of the Host header, with an
# optional fallback app for unmapped hosts.
class Paquette::SubdomainRouter
  prepend Paquette::RegexpTimeout

  # - the block: for configuring mappings via #map and #fallback
  #
  #: () ?{ (Paquette::SubdomainRouter router) -> void } -> void
  def initialize(&block)
    @mappings = {}
    @fallback = nil

    if block_given?
      block.call(self)
    end
  end

  #: (Paquette::rack_env env) -> Paquette::rack_response
  def call(env)
    request = Rack::Request.new(env)
    host = request.host

    subdomain = extract_subdomain(host.to_s)

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

  # - `to`: a Rack app, or a class that instantiates to one
  #
  #: (String subdomain, to: Paquette::_RackApp) -> void
  def map(subdomain, to:)
    @mappings[subdomain] = to
  end

  # - `to`: a Rack app called when no subdomain matches
  #
  #: (to: Paquette::_RackApp) -> void
  def fallback(to:)
    @fallback = to
  end

  private

  # Returns the first host label, only when it is mapped.
  #
  #: (String host) -> String?
  def extract_subdomain(host)
    host = host.split(":").first if host.include?(":")

    if (match = host.match(/\A([a-z\-\d]+)\./))
      subdomain = match[1]
      @mappings.key?(subdomain) ? subdomain : nil
    end
  end
end
