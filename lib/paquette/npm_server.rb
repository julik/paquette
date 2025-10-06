require "json"
require "fileutils"

module Paquette
  class NpmServer
    def initialize(packages_dir = nil)
      @packages_dir = packages_dir || File.expand_path("../../packages", __dir__)
      FileUtils.mkdir_p(@packages_dir)
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      method = request.request_method

      case [method, path]
      when ["GET", "/"]
        [200, {"Content-Type" => "text/plain"}, ["Paquette NPM Repository"]]

      else
        if method == "GET" && path.match?(/^\/.+$/)
          package_name = path[1..] # Remove leading slash
          # Handle /npm/package-name format
          package_name = package_name[4..] if package_name.start_with?("npm/")
          handle_package_info(package_name)
        else
          [404, {"Content-Type" => "text/plain"}, ["Not Found"]]
        end
      end
    end

    private

    def handle_package_info(package_name)
      # Future: implement NPM package serving
      [200, {"Content-Type" => "application/json"}, ['{"name": "' + package_name + '", "versions": {}}']]
    end
  end
end
