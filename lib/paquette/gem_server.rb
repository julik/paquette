require 'json'
require 'fileutils'
require 'rubygems'
require_relative 'directory_repository'

module Paquette
  class GemServer
    GEMS_DIR = File.expand_path('../../gems', __dir__)
    
    def initialize(gems_dir = nil)
      gems_dir ||= GEMS_DIR
      @repository = DirectoryRepository.new(gems_dir)
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
      
      # Handle different parameter formats
      if gems.is_a?(String)
        # Split comma-separated gem names
        gems = gems.split(',').map(&:strip)
      elsif gems.nil?
        gems = []
      end
      
      # If no gems specified, return empty array
      if gems.empty?
        return [200, { 'Content-Type' => 'application/json' }, ['[]']]
      end
      
      dependencies = []
      gems.each do |gem_name|
        gem_versions = @repository.versions_for_gem(gem_name)
        gem_versions.each do |version|
          gem_dependencies = @repository.gem_dependencies(gem_name, version)
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
      # Extract gem name and version from filename
      if match = gem_filename.match(/^(.+)-(\d+\.\d+\.\d+.*)\.gem$/)
        gem_name, version = match[1], match[2]
        gem_path = @repository.gem_file_path(gem_name, version)
        
        if @repository.gem_exists?(gem_name, version)
          [200, { 'Content-Type' => 'application/octet-stream' }, [File.read(gem_path)]]
        else
          [404, { 'Content-Type' => 'text/plain' }, ['Gem not found']]
        end
      else
        [404, { 'Content-Type' => 'text/plain' }, ['Invalid gem filename']]
      end
    end
    
    def handle_gem_upload(request)
      # For now, just return success - actual upload would need multipart handling
      [200, { 'Content-Type' => 'application/json' }, ['{"status": "success"}']]
    end
    
    def handle_versions
      versions = []
      @repository.gem_versions.each do |name, version|
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
      
      [200, { 'Content-Type' => 'application/json' }, [versions.to_json]]
    end
    
    def handle_names
      names = @repository.gem_names
      [200, { 'Content-Type' => 'application/json' }, [names.to_json]]
    end
    
    def handle_search(request)
      query = request.params['query'] || ''
      results = []
      
      @repository.gem_versions.each do |name, version|
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
      
      [200, { 'Content-Type' => 'application/json' }, [results.to_json]]
    end
    
    def handle_specs(version, request)
      # Return empty specs - Bundler will use the dependencies API instead
      specs_data = Marshal.dump([])
      
      # For .gz requests, compress the data
      if version.include?('.gz') || request.path_info.end_with?('.gz')
        require 'zlib'
        specs_data = Zlib::Deflate.deflate(specs_data)
        [200, { 'Content-Type' => 'application/x-gzip' }, [specs_data]]
      else
        [200, { 'Content-Type' => 'application/octet-stream' }, [specs_data]]
      end
    end
    
    
    def handle_compact_names
      names = @repository.gem_names
      [200, { 'Content-Type' => 'text/plain' }, [names.join("\n")]]
    end
    
    def handle_compact_versions
      versions = @repository.gem_versions.map { |name, version| "#{name} #{version}" }
      [200, { 'Content-Type' => 'text/plain' }, [versions.sort.join("\n")]]
    end
    
    def handle_compact_info(gem_name)
      info_lines = @repository.compact_info(gem_name)
      
      if info_lines.empty?
        [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]
      else
        [200, { 'Content-Type' => 'text/plain' }, [info_lines.join("\n")]]
      end
    end
    
    def create_compatible_marshal(specs)
      # Create a Marshal format that's compatible with Bundler
      # This is a simplified approach - in production you'd want to use
      # a proper Marshal 4.8 format
      Marshal.dump(specs)
    end
    
  end
end
