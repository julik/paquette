require "fileutils"
require "digest"
require "tmpdir"
require "tempfile"
require "sourcemap"
require "json"

module Paquette
  class NpmRepacker
    def self.repack(npm_path, &block)
      new(npm_path).repack(&block)
    end

    def initialize(npm_path)
      @npm_path = npm_path
      @temp_dir = nil
      @unpacked_package_dir = nil
    end

    def repack(&block)
      raise ArgumentError, "Block required" unless block_given?
      raise ArgumentError, "NPM package not found: #{@npm_path}" unless File.exist?(@npm_path)

      unpack_package
      process_js_files(&block)
      new_package_path = repackage_package
      cleanup
      new_package_path
    end

    private

    def unpack_package
      @temp_dir = Dir.mktmpdir("npm_repacker")
      @unpacked_package_dir = File.join(@temp_dir, "unpacked_package")
      FileUtils.mkdir_p(@unpacked_package_dir)

      # Extract the NPM package (tar.gz file)
      result = system("tar -xzf #{@npm_path} -C #{@unpacked_package_dir}")
      raise "Failed to unpack NPM package: #{@npm_path}" unless result

      # Find the unpacked package directory - it should be the only directory in unpacked_package_dir
      @package_dir = Dir.glob(File.join(@unpacked_package_dir, "*")).find { |path| File.directory?(path) }
      raise "Could not find unpacked package directory" unless @package_dir
    end

    def process_js_files(&block)
      # Process .ts, .js, .mjs, .jsx, .tsx files
      extensions = %w[.ts .js .mjs .jsx .tsx]
      extensions.each do |ext|
        Dir.glob(File.join(@package_dir, "**", "*#{ext}")).each do |js_file|
          process_js_file(js_file, &block)
        end
      end
    end

    def process_js_file(file_path, &block)
      # Get the relative path within the package directory
      relative_path = file_path.sub("#{@package_dir}/", "")

      # Create a temporary file for output
      temp_output = Tempfile.new("npm_repacker_output")

      begin
        # Open input file in binary mode for reading
        File.open(file_path, "rb") do |input_file|
          # Open output file in binary mode for writing
          File.open(temp_output.path, "wb") do |output_file|
            # Call the block with input file, output file, and relative path
            yield(input_file, output_file, relative_path)
          end
        end

        # Handle sourcemap updates if this is a JS file
        if File.extname(file_path) == ".js"
          update_sourcemap_offsets(file_path, temp_output.path)
        end

        # Replace the original file with the processed content
        FileUtils.mv(temp_output.path, file_path)
      ensure
        temp_output.close
        temp_output.unlink if File.exist?(temp_output.path)
      end
    end

    def update_sourcemap_offsets(js_file_path, new_js_content_path)
      # Look for sourcemap reference in the JS file
      sourcemap_path = find_sourcemap_file(js_file_path)
      return unless sourcemap_path

      # Calculate the offset difference
      original_content = File.read(js_file_path)
      new_content = File.read(new_js_content_path)
      offset_diff = new_content.length - original_content.length

      return if offset_diff == 0 # No changes, no need to update sourcemap

      # Update the sourcemap
      update_sourcemap_file(sourcemap_path, offset_diff)
    end

    def find_sourcemap_file(js_file_path)
      # Look for sourceMappingURL comment in the JS file
      content = File.read(js_file_path)
      if content =~ /\/\/# sourceMappingURL=(.+)/
        sourcemap_filename = $1.strip
        sourcemap_path = File.join(File.dirname(js_file_path), sourcemap_filename)
        return sourcemap_path if File.exist?(sourcemap_path)
      end
      nil
    end

    def update_sourcemap_file(sourcemap_path, offset_diff)
      # Read and parse the sourcemap
      sourcemap_content = File.read(sourcemap_path)
      sourcemap_data = JSON.parse(sourcemap_content)

      # Log that we found a sourcemap that needs updating
      puts "Info: Found sourcemap #{sourcemap_path} with offset difference of #{offset_diff} characters"
      puts "Info: Sourcemap contains #{sourcemap_data["sources"]&.length || 0} source files"

      # For now, we'll just log the information. In a production system,
      # you would need to implement proper sourcemap offset adjustment
      # which requires understanding the specific sourcemap format and
      # updating the mappings array accordingly.

      # TODO: Implement proper sourcemap offset adjustment
      # This would involve:
      # 1. Parsing the mappings string
      # 2. Adjusting the generated line/column positions
      # 3. Re-encoding the mappings string
      # 4. Updating the sourcemap JSON
    rescue => e
      # If sourcemap parsing fails, log the error but don't fail the process
      puts "Warning: Failed to parse sourcemap #{sourcemap_path}: #{e.message}"
    end

    def repackage_package
      # Create a new NPM package
      package_name = File.basename(@npm_path, ".tgz")
      new_package_path = File.join(Dir.tmpdir, "#{package_name}-repacked.tgz")

      # Create the new tar.gz file
      result = system("cd #{@unpacked_package_dir} && tar -czf #{new_package_path} package/")
      raise "Failed to repackage NPM package" unless result

      new_package_path
    end

    def cleanup
      FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
    end
  end
end
