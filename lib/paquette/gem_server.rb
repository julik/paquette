require 'json'
require 'fileutils'
require 'rubygems'

module Paquette
  class GemServer
    GEMS_DIR = File.expand_path('../../gems', __dir__)
    
    def initialize(gems_dir = nil)
      @gems_dir = gems_dir || GEMS_DIR
      FileUtils.mkdir_p(@gems_dir)
    end
    
    def call(env)
      request = Rack::Request.new(env)
      path = request.path_info
      method = request.request_method
      
      case [method, path]
      when ['GET', '/']
        handle_specs('4.8', request)
        
      when ['GET', '/api/v1/dependencies']
        handle_dependencies(request)
        
      when ['GET', '/api/v1/dependencies.json']
        handle_dependencies_json(request)
        
      when ['POST', '/api/v1/gems']
        handle_gem_upload(request)
        
      when ['GET', '/api/v1/versions']
        handle_versions
        
      when ['GET', '/api/v1/names']
        handle_names
        
      when ['GET', '/api/v1/search.json']
        handle_search(request)
        
      when ['GET', '/specs.4.8']
        handle_specs('4.8', request)
      when ['GET', '/specs.4.8.gz']
        handle_specs('4.8.gz', request)
        
      when ['GET', '/names']
        handle_compact_names
        
      when ['GET', '/versions']
        handle_compact_versions
        
      else
        if method == 'GET' && path.start_with?('/info/')
          gem_name = path[6..-1] # Remove '/info/' prefix
          handle_compact_info(gem_name)
        elsif method == 'GET' && path.start_with?('/gems/') && path.end_with?('.gem')
          gem_filename = path[6..-1] # Remove '/gems/' prefix
          handle_gem_download(gem_filename)
        else
          [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
        end
      end
    end
    
    private
    
    def handle_dependencies(request)
      gems = request.params['gems']
      
      # Handle different parameter formats
      if gems.is_a?(String)
        # Split comma-separated gem names
        gems = gems.split(',').map(&:strip)
      elsif gems.nil?
        gems = []
      end
      
      # If no gems specified, return dependencies for all gems
      if gems.empty?
        gems = Dir.glob(File.join(@gems_dir, '*.gem')).map do |gem_path|
          gem_name = File.basename(gem_path, '.gem')
          if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
            match[1]
          end
        end.compact.uniq
      end
      
      dependencies = []
      gems.each do |gem_name|
        gem_versions = find_gem_versions(gem_name)
        gem_versions.each do |version|
          gem_dependencies = extract_gem_dependencies(gem_name, version)
          dependencies << {
            name: gem_name,
            number: version,
            platform: 'ruby',
            dependencies: gem_dependencies
          }
        end
      end
      
      [200, { 'Content-Type' => 'application/json' }, [dependencies.to_json]]
    end
    
    def handle_dependencies_json(request)
      handle_dependencies(request)
    end
    
    def handle_gem_download(gem_filename)
      gem_path = File.join(@gems_dir, gem_filename)
      
      if File.exist?(gem_path)
        [200, { 'Content-Type' => 'application/octet-stream' }, [File.read(gem_path)]]
      else
        [404, { 'Content-Type' => 'text/plain' }, ['Gem not found']]
      end
    end
    
    def handle_gem_upload(request)
      # For now, just return success - actual upload would need multipart handling
      [200, { 'Content-Type' => 'application/json' }, ['{"status": "success"}']]
    end
    
    def handle_versions
      versions = []
      Dir.glob(File.join(@gems_dir, '*.gem')).each do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        # Extract version from filename (assuming format: name-version.gem)
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          name, version = match[1], match[2]
          versions << {
            name: name,
            number: version,
            platform: 'ruby',
            authors: ['Unknown'],
            info: 'Uploaded to Paquette',
            homepage: '',
            description: '',
            summary: '',
            metadata: {}
          }
        end
      end
      
      [200, { 'Content-Type' => 'application/json' }, [versions.to_json]]
    end
    
    def handle_names
      names = Dir.glob(File.join(@gems_dir, '*.gem')).map do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          match[1]
        end
      end.compact.uniq
      
      [200, { 'Content-Type' => 'application/json' }, [names.to_json]]
    end
    
    def handle_search(request)
      query = request.params['query'] || ''
      results = []
      
      Dir.glob(File.join(@gems_dir, '*.gem')).each do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          name, version = match[1], match[2]
          if name.include?(query)
            results << {
              name: name,
              version: version,
              platform: 'ruby',
              authors: ['Unknown'],
              info: 'Uploaded to Paquette'
            }
          end
        end
      end
      
      [200, { 'Content-Type' => 'application/json' }, [results.to_json]]
    end
    
    def handle_specs(version, request)
      # Return a simple response that Bundler can understand
      # This avoids the Marshal format issues
      [200, { 'Content-Type' => 'text/plain' }, ['']]
    end
    
    def find_gem_versions(gem_name)
      versions = []
      Dir.glob(File.join(@gems_dir, "#{gem_name}-*.gem")).each do |gem_path|
        filename = File.basename(gem_path, '.gem')
        if match = filename.match(/^#{Regexp.escape(gem_name)}-(\d+\.\d+\.\d+.*)$/)
          versions << match[1]
        end
      end
      versions.sort
    end
    
    def handle_compact_names
      names = Dir.glob(File.join(@gems_dir, '*.gem')).map do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          match[1]
        end
      end.compact.uniq.sort
      
      [200, { 'Content-Type' => 'text/plain' }, [names.join("\n")]]
    end
    
    def handle_compact_versions
      versions = []
      Dir.glob(File.join(@gems_dir, '*.gem')).each do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          name, version = match[1], match[2]
          versions << "#{name} #{version}"
        end
      end
      
      [200, { 'Content-Type' => 'text/plain' }, [versions.sort.join("\n")]]
    end
    
    def handle_compact_info(gem_name)
      versions = find_gem_versions(gem_name)
      
      if versions.empty?
        [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
      else
        # Return compact info format: gem_name,version,platform,checksum
        info_lines = versions.map do |version|
          "#{gem_name},#{version},ruby,"
        end
        
        [200, { 'Content-Type' => 'text/plain' }, [info_lines.join("\n")]]
      end
    end
    
    def create_compatible_marshal(specs)
      # Create a Marshal format that's compatible with Bundler
      # This is a simplified approach - in production you'd want to use
      # a proper Marshal 4.8 format
      Marshal.dump(specs)
    end
    
    def extract_gem_dependencies(gem_name, version)
      gem_file = File.join(@gems_dir, "#{gem_name}-#{version}.gem")
      return [] unless File.exist?(gem_file)
      
      begin
        # Use RubyGems to extract the gem specification
        require 'rubygems/package'
        
        # Use the public API to open the gem package
        pkg = Gem::Package.new(gem_file)
        spec = pkg.spec
        # Only include runtime dependencies, not development dependencies
        runtime_deps = spec.dependencies.select { |dep| dep.type == :runtime }
        return runtime_deps.map do |dep|
          {
            name: dep.name,
            requirements: dep.requirement.to_s
          }
        end
      rescue => e
        # If we can't extract dependencies, return empty array
        puts "Warning: Could not extract dependencies for #{gem_name}-#{version}: #{e.message}"
        []
      end
    end
  end
end
