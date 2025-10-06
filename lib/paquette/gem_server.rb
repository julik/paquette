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
        [200, { 'Content-Type' => 'text/plain' }, ['Paquette RubyGems Repository']]
        
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
      gems = [gems] if gems.is_a?(String)
      gems ||= []
      return [200, { 'Content-Type' => 'application/json' }, ['[]']] if gems.empty?
      
      dependencies = []
      gems.each do |gem_name|
        gem_versions = find_gem_versions(gem_name)
        gem_versions.each do |version|
          dependencies << {
            name: gem_name,
            number: version,
            platform: 'ruby',
            dependencies: []
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
      # Create specs in the format that Bundler expects
      specs = []
      Dir.glob(File.join(@gems_dir, '*.gem')).each do |gem_path|
        gem_name = File.basename(gem_path, '.gem')
        if match = gem_name.match(/^(.+)-(\d+\.\d+\.\d+.*)$/)
          name, version = match[1], match[2]
          specs << [name, Gem::Version.new(version), 'ruby']
        end
      end
      
      # Use the correct Marshal version that Bundler expects
      # Create a custom marshaler that uses version 4.8
      require 'stringio'
      
      # Create a simple specs format that Bundler can understand
      specs_data = Marshal.dump(specs)
      
      # For .gz requests, compress the data
      if version.include?('.gz') || request.path_info.end_with?('.gz')
        require 'zlib'
        specs_data = Zlib::Deflate.deflate(specs_data)
        [200, { 'Content-Type' => 'application/x-gzip' }, [specs_data]]
      else
        [200, { 'Content-Type' => 'application/octet-stream' }, [specs_data]]
      end
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
  end
end
