require "rubygems"
require "rubygems/package"
require "fileutils"
require "digest"
require "tmpdir"
require "tempfile"
require "open3"
require "measurometer"

module Paquette
  class GemServer
    class GemRepacker
      # `into:` is a file path the caller has somewhere it owns — a directory it
      # made and will take away again. Given one, the finished gem is written
      # there and this leaves nothing behind at all.
      #
      # Without it the gem lands in a fresh directory of ours and the caller is
      # handed the path, which makes cleaning that directory the caller's
      # problem. That is a bad bargain and `into:` is how a caller declines it:
      # nobody should be deleting a directory somebody else chose, and a caller
      # that tries ends up calling a recursive delete on whatever it was given —
      # the system temp directory included.
      def self.repack(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block)
        new(gem_path, gemspec_extras: gemspec_extras, magic_comment_replacements: magic_comment_replacements, files: files, into: into).repack(&block)
      end

      def initialize(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil)
        @gem_path = gem_path
        @gemspec_extras = gemspec_extras
        @magic_comment_replacements = magic_comment_replacements
        @files = files
        @into = into
        @temp_dir = nil
        @unpacked_gem_dir = nil
      end

      # Four subprocess-and-disk stages, each timed separately: a repack that
      # got slow is almost always one of them, and the whole-repack number on
      # its own cannot say which.
      def repack
        raise ArgumentError, "Gem file not found: #{@gem_path}" unless File.exist?(@gem_path)

        Measurometer.instrument("paquette.gem_repacker.repack") do
          Measurometer.instrument("paquette.gem_repacker.unpack") { unpack_gem }
          Measurometer.instrument("paquette.gem_repacker.process_ruby_files") { process_ruby_files }
          Measurometer.instrument("paquette.gem_repacker.inject_files") { inject_files }
          new_gem_path = Measurometer.instrument("paquette.gem_repacker.repackage") { repackage_gem }
          cleanup
          new_gem_path
        end
      end

      private

      def unpack_gem
        @temp_dir = Dir.mktmpdir("gem_repacker")
        @unpacked_gem_dir = File.join(@temp_dir, "unpacked_gem")
        FileUtils.mkdir_p(@unpacked_gem_dir)

        # Use gem unpack command to extract the gem
        _, stderr, status = Measurometer.instrument("paquette.gem_repacker.gem_unpack") do
          Open3.capture3("gem unpack #{@gem_path} --target=#{@unpacked_gem_dir}")
        end
        unless status.success?
          raise "Failed to unpack gem: #{@gem_path}. Error: #{stderr}"
        end

        # Find the unpacked gem directory - it should be the only directory in unpacked_gem_dir
        @gem_dir = Dir.glob(File.join(@unpacked_gem_dir, "*")).find { |path| File.directory?(path) }
        raise "Could not find unpacked gem directory" unless @gem_dir
      end

      def process_ruby_files
        rb_files = Dir.glob(File.join(@gem_dir, "**", "*.rb"))
        Measurometer.add_distribution_value("paquette.gem_repacker.ruby_files", rb_files.length)
        rb_files.each { |rb_file| process_ruby_file(rb_file) }
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

        # SOURCE_DATE_EPOCH is what makes a repack reproducible, and without it
        # this method could not be used for anything a checksum is published
        # for.
        #
        # A .gem is a tar of three gzip members, and a gzip header carries the
        # time it was written. RubyGems takes that time, and the mtimes of the
        # inner tar entries, from Time.now unless SOURCE_DATE_EPOCH says
        # otherwise — so the same inputs repacked a second apart came out with
        # different bytes and a different SHA256 while inflating to exactly the
        # same content. Anything that published a checksum and then rebuilt the
        # gem to serve it was therefore publishing a checksum for bytes nobody
        # would ever receive, and `bundle install` reports that as a mismatch,
        # which reads to a customer as a tampered gem.
        #
        # The epoch is the original gem's own date, so a repack is pinned to the
        # thing it was made from rather than to a build clock: the same source
        # gem and the same personalization produce one answer, on any machine,
        # at any time.
        build_env = {"SOURCE_DATE_EPOCH" => Gem::Package.new(@gem_path).spec.date.to_i.to_s}
        _, stderr, status = Measurometer.instrument("paquette.gem_repacker.gem_build") do
          Open3.capture3(build_env, "gem", "build", File.basename(gemspec_path), chdir: @gem_dir)
        end
        unless status.success?
          raise "Failed to build gem. Error: #{stderr}"
        end

        # Find the newly created gem file
        gem_name = File.basename(@gem_path, ".gem")
        new_gem_path = File.join(@gem_dir, "#{gem_name}.gem")

        # Where the caller asked for it, or somewhere of its own. Not
        # "#{gem_name}-repacked.gem" in the shared tmpdir, which is what two
        # repacks of one gem — two licensees, or one licensee and the checksum
        # pass — used to overwrite each other in.
        final_gem_path = @into || File.join(Dir.mktmpdir("gem_repacked"), "#{gem_name}-repacked.gem")
        FileUtils.mkdir_p(File.dirname(final_gem_path))
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
