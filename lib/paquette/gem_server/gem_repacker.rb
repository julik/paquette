require 'rubygems'
require 'rubygems/package'
require 'fileutils'
require 'digest'
require 'tmpdir'
require 'tempfile'

module Paquette
  class GemServer
    class GemRepacker
      def self.repack(gem_path, additional_metadata_keys: {}, &block)
        new(gem_path, additional_metadata_keys: additional_metadata_keys).repack(&block)
      end

      def initialize(gem_path, additional_metadata_keys: {})
        @gem_path = gem_path
        @additional_metadata_keys = additional_metadata_keys
        @temp_dir = nil
        @unpacked_gem_dir = nil
      end

      def repack(&block)
        raise ArgumentError, "Block required" unless block_given?
        raise ArgumentError, "Gem file not found: #{@gem_path}" unless File.exist?(@gem_path)

        unpack_gem
        process_ruby_files(&block)
        new_gem_path = repackage_gem
        cleanup
        new_gem_path
      end

      private

      def unpack_gem
        @temp_dir = Dir.mktmpdir('gem_repacker')
        @unpacked_gem_dir = File.join(@temp_dir, 'unpacked_gem')
        FileUtils.mkdir_p(@unpacked_gem_dir)
        
        # Use gem unpack command to extract the gem
        result = system("gem unpack #{@gem_path} --target=#{@unpacked_gem_dir}")
        raise "Failed to unpack gem: #{@gem_path}" unless result
        
        # Find the unpacked gem directory - it should be the only directory in unpacked_gem_dir
        @gem_dir = Dir.glob(File.join(@unpacked_gem_dir, '*')).select { |path| File.directory?(path) }.first
        raise "Could not find unpacked gem directory" unless @gem_dir
      end

      def process_ruby_files(&block)
        Dir.glob(File.join(@gem_dir, '**', '*.rb')).each do |rb_file|
          process_ruby_file(rb_file, &block)
        end
      end

      def process_ruby_file(file_path, &block)
        # Get the relative path within the gem directory
        relative_path = file_path.sub("#{@gem_dir}/", '')
        
        # Create a temporary file for output
        temp_output = Tempfile.new('gem_repacker_output')
        
        begin
          # Open input file in binary mode for reading
          File.open(file_path, 'rb') do |input_file|
            # Open output file in binary mode for writing
            File.open(temp_output.path, 'wb') do |output_file|
              # Call the block with input file, output file, and relative path
              yield(input_file, output_file, relative_path)
            end
          end
          
          # Replace the original file with the processed content
          FileUtils.mv(temp_output.path, file_path)
        ensure
          temp_output.close
          temp_output.unlink if File.exist?(temp_output.path)
        end
      end

      def repackage_gem
        # Get the original gem specification
        original_spec = Gem::Package.new(@gem_path).spec
        
        # Create a gemspec file from the original specification
        gemspec_path = File.join(@gem_dir, "#{original_spec.name}.gemspec")
        create_gemspec_file(gemspec_path, original_spec)
        
        # Build the new gem using gem build command
        result = system("cd #{@gem_dir} && gem build #{File.basename(gemspec_path)}")
        raise "Failed to build gem" unless result
        
        # Find the newly created gem file
        gem_name = File.basename(@gem_path, '.gem')
        new_gem_path = File.join(@gem_dir, "#{gem_name}.gem")
        
        # Move to a more permanent location
        final_gem_path = File.join(Dir.tmpdir, "#{gem_name}-repacked.gem")
        FileUtils.mv(new_gem_path, final_gem_path)
        
        final_gem_path
      end

      def create_gemspec_file(gemspec_path, spec)
        # Create a new spec with additional metadata
        new_spec = spec.dup
        
        # Add additional metadata keys
        @additional_metadata_keys.each do |key, value|
          new_spec.metadata[key] = value
        end
        
        # Use the built-in to_ruby method to safely serialize the specification
        gemspec_content = new_spec.to_ruby
        
        File.write(gemspec_path, gemspec_content)
      end

      def cleanup
        FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
      end
    end
  end
end
