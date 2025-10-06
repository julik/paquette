require "json"
require "fileutils"
require "mustermann"
require_relative "npm_server/directory_npm_repository"
require_relative "npm_server/gated_npm_repository"

module Paquette
  class NpmServer
    PACKAGES_DIR = File.expand_path("../../packages", __dir__)

    def initialize(packages_dir = nil)
      packages_dir ||= PACKAGES_DIR
      @dir_repository = DirectoryNpmRepository.new(packages_dir)
      setup_routes
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      method = request.request_method
      @repository = GatedNpmRepository.new(@dir_repository) { |name:, version: nil| true }

      # Try to match against our routes
      @routes.each do |route|
        if route[:method] == method && route[:pattern].match(path)
          params = route[:pattern].params(path)
          return send(route[:handler], request, params)
        end
      end

      not_found("Not Found")
    ensure
      @repository = nil
    end

    private

    def setup_routes
      @routes = [
        # Root endpoint
        { method: "GET", pattern: Mustermann.new("/"), handler: :handle_root },
        
        # NPM API endpoints
        { method: "GET", pattern: Mustermann.new("/-/ping"), handler: :handle_ping },
        { method: "GET", pattern: Mustermann.new("/-/whoami"), handler: :handle_whoami },
        
        # Dynamic endpoints with parameters
        { method: "GET", pattern: Mustermann.new("/-/package/:package_name/dist-tags"), handler: :handle_dist_tags },
        { method: "GET", pattern: Mustermann.new("/:package_name"), handler: :handle_package_metadata },
        { method: "GET", pattern: Mustermann.new("/:package_name/:tarball_name"), handler: :handle_package_download }
      ]
    end

    def handle_root(request, params)
      text_ok("Paquette NPM Repository")
    end

    def handle_ping(request, params)
      json_ok({})
    end

    def handle_whoami(request, params)
      json_ok({ username: "paquette" })
    end

    def handle_dist_tags(request, params)
      package_name = params["package_name"]
      metadata = @repository.package_metadata(package_name)
      if metadata && metadata[:"dist-tags"]
        json_ok(metadata[:"dist-tags"])
      else
        not_found("Package not found")
      end
    end

    def handle_package_metadata(request, params)
      package_name = params["package_name"]
      metadata = @repository.package_metadata(package_name)
      if metadata
        json_ok(metadata)
      else
        not_found("Package not found")
      end
    end

    def handle_package_download(request, params)
      package_name = params["package_name"]
      tarball_name = params["tarball_name"]
      
      # Extract version from tarball name (e.g., "package-1.0.0.tgz")
      if (match = tarball_name.match(/^#{Regexp.escape(package_name)}-(\d+\.\d+\.\d+.*)\.tgz$/))
        version = match[1]
        package_path = @repository.package_file_path(package_name, version)

        if @repository.package_exists?(package_name, version)
          [200, {"Content-Type" => "application/octet-stream"}, [File.read(package_path)]]
        else
          not_found("Package not found")
        end
      else
        not_found("Invalid package filename")
      end
    end

    # Helper methods for common response patterns
    def json_ok(data)
      [200, {"Content-Type" => "application/json"}, [JSON.pretty_generate(data)]]
    end

    def text_ok(data)
      [200, {"Content-Type" => "text/plain"}, [data]]
    end

    def not_found(message = "Not Found")
      [404, {"Content-Type" => "text/plain"}, [message]]
    end

    def bad_request(message = "Bad Request")
      [400, {"Content-Type" => "text/plain"}, [message]]
    end

    def server_error(message = "Internal Server Error")
      [500, {"Content-Type" => "text/plain"}, [message]]
    end
  end
end
