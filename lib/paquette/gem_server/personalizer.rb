require "delegate"
require "fileutils"
require "digest"

module Paquette
  class GemServer
    class Personalizer < SimpleDelegator
      def initialize(repository, license_key:)
        super(repository)
        @license_key = license_key
      end

      def gem_file_path(gem_name, version)
        original_path = __getobj__.gem_file_path(gem_name, version)
        return original_path unless File.exist?(original_path)
        
        # Create personalized version
        personalize_gem(original_path, gem_name, version)
      end

      def compact_info(gem_name)
        # Override compact_info to use personalized gems for checksums
        versions = __getobj__.versions_for_gem(gem_name)
        return [] if versions.empty?

        versions.map do |version|
          spec = __getobj__.gem_spec(gem_name, version)
          next unless spec

          # Use personalized gem file for checksum calculation
          personalized_gem_file = gem_file_path(gem_name, version)
          checksum = Digest::SHA256.file(personalized_gem_file).hexdigest

          # Get required Ruby version from gemspec
          ruby_version = spec.required_ruby_version&.to_s || ">= 0"

          # Format: version |checksum:sha256_checksum,ruby:required_ruby_version
          "#{version} |checksum:#{checksum},ruby:#{ruby_version}"
        end.compact
      end

      private

      def personalize_gem(original_gem_path, gem_name, version)
        # Create a unique path for the personalized gem
        personalized_dir = File.join(Dir.tmpdir, "paquette_personalized")
        FileUtils.mkdir_p(personalized_dir)
        
        personalized_path = File.join(personalized_dir, "#{gem_name}-#{version}-personalized.gem")
        
        Paquette::GemServer::GemRepacker.repack(original_gem_path, additional_metadata_keys: { "paquette.license_key" => @license_key }) do |input_file, output_file, file_path|
          unless File.extname(file_path) == ".rb"
            IO.copy_stream(input_file, output_file)
            next
          end

          input_file.each_line do |line|
            if line.chomp == '# paquette_license_info'
              output_file.puts("# #{@license_key}\n")
              IO.copy_stream(input_file, output_file) # Copy the rest
              next
            else
              output_file.write(line)
            end
          end
        end
        
        # Move the repacked gem to our personalized location
        temp_personalized = File.join(Dir.tmpdir, "#{gem_name}-#{version}-repacked.gem")
        if File.exist?(temp_personalized)
          FileUtils.mv(temp_personalized, personalized_path)
        end
        
        personalized_path
      end
    end
  end
end
