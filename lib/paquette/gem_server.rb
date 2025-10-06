require "json"
require "fileutils"
require "rubygems"
require "zlib"
require "stringio"
require_relative "directory_repository"

module Paquette
  class GemServer
    GEMS_DIR = File.expand_path("../../gems", __dir__)

    def initialize(gems_dir = nil)
      gems_dir ||= GEMS_DIR
      @repository = DirectoryRepository.new(gems_dir)
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      method = request.request_method

      case [method, path]
      when ["GET", "/"]
        text_ok("Paquette RubyGems Repository")

      when ["GET", "/api/v1/dependencies"]
        # Disable dependencies API to force Bundler to use specs format
        not_found("Dependencies API not supported")

      when ["GET", "/api/v1/dependencies.json"]
        # Disable dependencies API to force Bundler to use specs format
        not_found("Dependencies API not supported")

      when ["POST", "/api/v1/gems"]
        handle_gem_upload(request)

      when ["GET", "/api/v1/versions"]
        handle_versions

      when ["GET", "/api/v1/names"]
        handle_names

      when ["GET", "/api/v1/search.json"]
        handle_search(request)

      when ["GET", "/specs.4.8"]
        handle_specs("4.8", request)
      when ["GET", "/specs.4.8.gz"]
        handle_specs("4.8.gz", request)
      when ["GET", "/latest_specs.4.8"]
        handle_latest_specs("4.8", request)
      when ["GET", "/latest_specs.4.8.gz"]
        handle_latest_specs("4.8.gz", request)

      when ["GET", "/names"]
        handle_compact_names

      when ["GET", "/versions"]
        handle_compact_versions

      else
        if method == "GET" && path.start_with?("/info/")
          gem_name = path[6..] # Remove '/info/' prefix
          handle_compact_info(gem_name)
        elsif method == "GET" && path.start_with?("/gems/") && path.end_with?(".gem")
          gem_filename = path[6..] # Remove '/gems/' prefix
          handle_gem_download(gem_filename)
        else
          not_found("Not Found")
        end
      end
    end

    private

    def handle_dependencies(request)
      gems = request.params["gems"]

      # Handle different parameter formats
      if gems.is_a?(String)
        # Split comma-separated gem names
        gems = gems.split(",").map(&:strip)
      elsif gems.nil?
        gems = []
      end

      # If no gems specified, return empty array
      if gems.empty?
        return json_ok([])
      end

      dependencies = []
      gems.each do |gem_name|
        gem_versions = @repository.versions_for_gem(gem_name)
        gem_versions.each do |version|
          gem_dependencies = @repository.gem_dependencies(gem_name, version)
          dependencies << {
            name: gem_name,
            number: version,
            platform: "ruby",
            dependencies: gem_dependencies
          }
        end
      end

      json_ok(dependencies)
    end

    def handle_dependencies_json(request)
      handle_dependencies(request)
    end

    def handle_gem_download(gem_filename)
      # Extract gem name and version from filename
      if (match = gem_filename.match(/^(.+)-(\d+\.\d+\.\d+.*)\.gem$/))
        gem_name, version = match[1], match[2]
        gem_path = @repository.gem_file_path(gem_name, version)

        if @repository.gem_exists?(gem_name, version)
          [200, {"Content-Type" => "application/octet-stream"}, [File.read(gem_path)]]
        else
          not_found("Gem not found")
        end
      else
        not_found("Invalid gem filename")
      end
    end

    def handle_gem_upload(request)
      [400, {}, ["Gem upload is not supported yet"]]
    end

    def handle_versions
      versions = []
      @repository.gem_versions.each do |name, version|
        spec = @repository.gem_spec(name, version)
        versions << {
          name: name,
          number: version,
          platform: spec.platform.to_s,
          authors: spec.authors,
          info: spec.description || "",
          homepage: spec.homepage || "",
          description: spec.description || "",
          summary: spec.summary || "",
          metadata: spec.metadata || {}
        }
      end

      json_ok(versions)
    end

    def handle_names
      names = @repository.gem_names
      json_ok(names)
    end

    def handle_search(request)
      query = request.params["query"] || ""
      results = []

      @repository.gem_versions.each do |name, version|
        if name.include?(query)
          results << {
            name: name,
            version: version,
            platform: "ruby",
            authors: ["Unknown"],
            info: "Uploaded to Paquette"
          }
        end
      end

      json_ok(results)
    end

    def handle_specs(version, request)
      # Generate specs in the format expected by Bundler
      specs = generate_specs_array

      # Use Marshal 4.8 format for compatibility with Bundler
      specs_data = marshal_dump_4_8(specs)

      # For .gz requests, compress the data
      if version.include?(".gz") || request&.path_info&.end_with?(".gz")
        specs_data = gzip_compress(specs_data)
        [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
      else
        [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
      end
    end

    def handle_compact_names
      names = @repository.gem_names
      text_ok(names.join("\n"))
    end

    def handle_compact_versions
      versions = @repository.gem_versions.map { |name, version| "#{name} #{version}" }
      text_ok(versions.sort.join("\n"))
    end

    def handle_compact_info(gem_name)
      info_lines = @repository.compact_info(gem_name)

      if info_lines.empty?
        not_found("Not Found")
      else
        text_ok(info_lines.join("\n"))
      end
    end

    def generate_specs_array
      # Generate specs array in the format expected by RubyGems/Bundler
      # Each spec is [gem_name, version, platform]
      # Use only basic Ruby types to ensure Marshal 4.8 compatibility
      specs = []
      @repository.gem_versions.each do |name, version|
        specs << [name.to_s, version.to_s, "ruby"]
      end
      specs
    end

    def handle_latest_specs(version, request)
      # Generate latest specs (only the latest version of each gem)
      latest_specs = generate_latest_specs_array

      # Use Marshal 4.8 format for compatibility with Bundler
      specs_data = marshal_dump_4_8(latest_specs)

      # For .gz requests, compress the data
      if version.include?(".gz") || request&.path_info&.end_with?(".gz")
        specs_data = gzip_compress(specs_data)
        [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
      else
        [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
      end
    end

    def generate_latest_specs_array
      # Generate latest specs array - only the latest version of each gem
      latest_versions = {}
      @repository.gem_versions.each do |name, version|
        if !latest_versions[name] || Gem::Version.new(version) > Gem::Version.new(latest_versions[name])
          latest_versions[name] = version
        end
      end

      specs = []
      latest_versions.each do |name, version|
        specs << [name.to_s, version.to_s, "ruby"]
      end
      specs
    end

    def marshal_dump_4_8(obj)
      # Create Marshal data in format 4.8 for compatibility with Bundler
      # Use only basic Ruby types to ensure compatibility
      specs_array = obj.is_a?(Array) ? obj : []

      # Simple Marshal.dump should work with basic types
      Marshal.dump(specs_array)
    end

    def gzip_compress(data)
      # Create proper gzip format with headers, checksums, etc.
      StringIO.open do |io|
        Zlib::GzipWriter.wrap(io) do |gz|
          gz.write(data)
        end
        io.string
      end
    end

    # Helper methods for common response patterns
    private

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
