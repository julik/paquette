require "json"
require "fileutils"
require_relative "routes"
require_relative "npm_server/directory_npm_repository"
require_relative "npm_server/gated_npm_repository"

module Paquette
  class NpmServer
    PACKAGES_DIR = File.expand_path("../../packages", __dir__)

    @@routes = Routes.draw do |r|
      # Root endpoint
      r.get "/" do
        text_ok("Paquette NPM Repository")
      end
      
      # NPM API endpoints
      r.get "/-/ping" do
        json_ok({})
      end
      
      r.get "/-/whoami" do
        json_ok({ username: "paquette" })
      end
      
      # Dynamic endpoints with parameters
      r.get "/-/package/:package_name/dist-tags" do |package_name:|
        metadata = @repository.package_metadata(package_name)
        if metadata && metadata[:"dist-tags"]
          json_ok(metadata[:"dist-tags"])
        else
          not_found("Package not found")
        end
      end
      
      r.get "/:package_name" do |package_name:|
        metadata = @repository.package_metadata(package_name)
        if metadata
          json_ok(metadata)
        else
          not_found("Package not found")
        end
      end
      
      r.get "/:package_name/:tarball_name" do |package_name:, tarball_name:|
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
    end

    def initialize(packages_dir = nil)
      packages_dir ||= PACKAGES_DIR
      @dir_repository = DirectoryNpmRepository.new(packages_dir)
    end

    def call(env)
      request = Rack::Request.new(env)
      @repository = GatedNpmRepository.new(@dir_repository) { |name:, version: nil| true }

      if (route = @@routes.match(request))
        @@routes.perform_action(route, self, request)
      else
        not_found("Not Found")
      end
    ensure
      @repository = nil
    end

    private

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
