require "json"
require "fileutils"
require "rubygems"
require "zlib"
require "stringio"
require "mustermann"
require_relative "gem_server/directory_gem_repository"
require_relative "gem_server/gated_gem_repository"

module Paquette
  class GemServer
    GEMS_DIR = File.expand_path("../../gems", __dir__)

    def initialize(gems_dir = nil)
      gems_dir ||= GEMS_DIR
      @dir_repository = DirectoryGemRepository.new(gems_dir)
      setup_routes
    end

    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      method = request.request_method
      @repository = GatedGemRepository.new(@dir_repository) { |name:, version: nil| true }

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
        
        # API endpoints
        { method: "GET", pattern: Mustermann.new("/api/v1/dependencies"), handler: :handle_dependencies_not_supported },
        { method: "GET", pattern: Mustermann.new("/api/v1/dependencies.json"), handler: :handle_dependencies_not_supported },
        { method: "POST", pattern: Mustermann.new("/api/v1/gems"), handler: :handle_gem_upload },
        { method: "GET", pattern: Mustermann.new("/api/v1/versions"), handler: :handle_versions },
        { method: "GET", pattern: Mustermann.new("/api/v1/names"), handler: :handle_names },
        { method: "GET", pattern: Mustermann.new("/api/v1/search.json"), handler: :handle_search },
        
        # Specs endpoints
        { method: "GET", pattern: Mustermann.new("/specs.4.8"), handler: :handle_specs_4_8 },
        { method: "GET", pattern: Mustermann.new("/specs.4.8.gz"), handler: :handle_specs_4_8_gz },
        { method: "GET", pattern: Mustermann.new("/latest_specs.4.8"), handler: :handle_latest_specs_4_8 },
        { method: "GET", pattern: Mustermann.new("/latest_specs.4.8.gz"), handler: :handle_latest_specs_4_8_gz },
        
        # Compact index endpoints
        { method: "GET", pattern: Mustermann.new("/names"), handler: :handle_compact_names },
        { method: "GET", pattern: Mustermann.new("/versions"), handler: :handle_compact_versions },
        
        # Dynamic endpoints with parameters
        { method: "GET", pattern: Mustermann.new("/info/:gem_name"), handler: :handle_compact_info },
        { method: "GET", pattern: Mustermann.new("/quick/Marshal.4.8/:gem_spec_name.gemspec.rz"), handler: :handle_quick_gemspec },
        { method: "GET", pattern: Mustermann.new("/gems/:gem_filename"), handler: :handle_gem_download }
      ]
    end

    def handle_root(request, params)
      text_ok("Paquette RubyGems Repository")
    end

    def handle_dependencies_not_supported(request, params)
      not_found("Dependencies API not supported")
    end

    def handle_specs_4_8(request, params)
      handle_specs("4.8", request)
    end

    def handle_specs_4_8_gz(request, params)
      handle_specs("4.8.gz", request)
    end

    def handle_latest_specs_4_8(request, params)
      handle_latest_specs("4.8", request)
    end

    def handle_latest_specs_4_8_gz(request, params)
      handle_latest_specs("4.8.gz", request)
    end

    def handle_compact_info(request, params)
      gem_name = params["gem_name"]
      info_lines = @repository.compact_info(gem_name)

      if info_lines.empty?
        not_found("Not Found")
      else
        text_ok(info_lines.join("\n"))
      end
    end

    def handle_quick_gemspec(request, params)
      gem_spec_name = params["gem_spec_name"]
      # Parse gem name and version from the spec name (e.g., "zip_kit-6.3.2")
      if (match = gem_spec_name.match(/^(.+?)-(\d+\.\d+\.\d+.*)$/))
        gem_name, version = match[1], match[2]

        if @repository.gem_exists?(gem_name, version)
          spec = @repository.gem_spec(gem_name, version)
          if spec
            # Marshal the spec and compress it with raw deflate (not gzip)
            marshaled_spec = Marshal.dump(spec)
            compressed_spec = Zlib::Deflate.deflate(marshaled_spec)
            [200, {"Content-Type" => "application/octet-stream"}, [compressed_spec]]
          else
            not_found("Spec not found")
          end
        else
          not_found("Gem not found: #{gem_name}-#{version}")
        end
      else
        not_found("Invalid gem spec name: #{gem_spec_name}")
      end
    end

    def handle_gem_download(request, params)
      gem_filename = params["gem_filename"]
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


    def handle_gem_upload(request, params)
      [400, {}, ["Gem upload is not supported yet"]]
    end

    def handle_versions(request, params)
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

    def handle_names(request, params)
      names = @repository.gem_names
      json_ok(names)
    end

    def handle_search(request, params)
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

    def handle_compact_names(request, params)
      names = @repository.gem_names
      text_ok(names.join("\n"))
    end

    def handle_compact_versions(request, params)
      require "digest"
      require "time"

      # Group versions by gem name
      gem_versions = {}
      @repository.gem_versions.each do |name, version|
        gem_versions[name] ||= []
        gem_versions[name] << version
      end

      # Sort versions for each gem
      gem_versions.each { |name, versions| versions.sort! }

      # Generate the content in the official format
      lines = []
      lines << "created_at: #{Time.now.utc.iso8601}"
      lines << "---"

      # Add each gem with its versions and checksum
      gem_versions.sort.each do |name, versions|
        versions_str = versions.join(",")
        # Create a checksum for this gem's versions
        version_data = "#{name} #{versions.join(" ")}"
        checksum = Digest::MD5.hexdigest(version_data)
        lines << "#{name} #{versions_str} #{checksum}"
      end

      content = lines.join("\n")

      # Calculate overall checksum for the entire content
      overall_checksum = Digest::MD5.hexdigest(content)

      [200, {"Content-Type" => "text/plain", "X-Checksum-Sha256" => overall_checksum}, [content]]
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
