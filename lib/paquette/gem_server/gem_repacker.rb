require "rubygems"
require "rubygems/package"
require "fileutils"
require "digest"
require "tmpdir"
require "tempfile"
require "open3"

module Paquette
  class GemServer
    class GemRepacker
      def self.repack(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, &block)
        new(gem_path, gemspec_extras: gemspec_extras, magic_comment_replacements: magic_comment_replacements, files: files).repack(&block)
      end

      def initialize(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {})
        @gem_path = gem_path
        @gemspec_extras = gemspec_extras
        @magic_comment_replacements = magic_comment_replacements
        @files = files
        @temp_dir = nil
        @unpacked_gem_dir = nil
      end

      def repack
        raise ArgumentError, "Gem file not found: #{@gem_path}" unless File.exist?(@gem_path)

        unpack_gem
        process_ruby_files
        inject_files
        new_gem_path = repackage_gem
        cleanup
        new_gem_path
      end

      private

      def unpack_gem
        @temp_dir = Dir.mktmpdir("gem_repacker")
        @unpacked_gem_dir = File.join(@temp_dir, "unpacked_gem")
        FileUtils.mkdir_p(@unpacked_gem_dir)

        # Use gem unpack command to extract the gem
        _, stderr, status = Open3.capture3("gem unpack #{@gem_path} --target=#{@unpacked_gem_dir}")
        unless status.success?
          raise "Failed to unpack gem: #{@gem_path}. Error: #{stderr}"
        end

        # Find the unpacked gem directory - it should be the only directory in unpacked_gem_dir
        @gem_dir = Dir.glob(File.join(@unpacked_gem_dir, "*")).find { |path| File.directory?(path) }
        raise "Could not find unpacked gem directory" unless @gem_dir
      end

      def process_ruby_files
        Dir.glob(File.join(@gem_dir, "**", "*.rb")).each do |rb_file|
          process_ruby_file(rb_file)
        end
      end

      def inject_files
        @files.each do |file_path, content|
          # Ensure the file path is relative to the gem directory
          full_path = File.join(@gem_dir, file_path)
          
          # Create parent directories if they don't exist
          FileUtils.mkdir_p(File.dirname(full_path))
          
          # Write the file content
          File.write(full_path, content)
        end
      end

      def process_ruby_file(file_path)
        # Create a temporary file for output
        temp_output = Tempfile.new("gem_repacker_output")

        # Open input file in binary mode for reading
        File.open(file_path, "rb") do |input_file|
          # Set temp file to binary mode
          temp_output.binmode

          # Apply magic comment replacements if any are defined
          if @magic_comment_replacements.any?
            apply_magic_comment_replacements(input_file, temp_output)
          else
            # Just copy the file as-is if no magic comment replacements
            IO.copy_stream(input_file, temp_output)
          end

          # Flush the temp file to ensure all data is written
          temp_output.flush
        end

        # Replace the original file with the processed content
        FileUtils.mv(temp_output.path, file_path)
      ensure
        temp_output.close
        temp_output.unlink if File.exist?(temp_output.path)
      end

      def apply_magic_comment_replacements(input_file, output_file)
        input_file.each_line do |line|
          # Check if this line matches any of our magic comment replacements
          replacement_found = false
          @magic_comment_replacements.each do |magic_comment, replacement_value|
            if line.chomp == magic_comment
              output_file.puts("# #{replacement_value}\n")
              IO.copy_stream(input_file, output_file) # Copy the rest
              replacement_found = true
              break
            end
          end

          unless replacement_found
            output_file.write(line)
          end
        end
      end

      def repackage_gem
        # Get the original gem specification
        original_spec = Gem::Package.new(@gem_path).spec

        # Create a gemspec file from the original specification
        gemspec_path = File.join(@gem_dir, "#{original_spec.name}.gemspec")
        create_gemspec_file(gemspec_path, original_spec)

        # Build the new gem using gem build command
        _, stderr, status = Open3.capture3("gem", "build", File.basename(gemspec_path), chdir: @gem_dir)
        unless status.success?
          raise "Failed to build gem. Error: #{stderr}"
        end

        # Find the newly created gem file
        gem_name = File.basename(@gem_path, ".gem")
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
        @gemspec_extras.each do |key, value|
          new_spec.metadata[key] = value
        end

        # Add injected files to the files list
        @files.each do |file_path, _content|
          new_spec.files << file_path unless new_spec.files.include?(file_path)
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
