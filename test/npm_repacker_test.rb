require_relative "test_helper"

class NpmRepackerTest < Minitest::Test
  def setup
    @test_package_path = File.expand_path("./packages/npm/react-dropzone/react-dropzone-14.3.8.tgz", Dir.pwd)
  end

  def test_repack_with_text_replacement
    skip "Test package not found" unless File.exist?(@test_package_path)

    # Replace the first occurrence of 'Dropzone' with 'Liftzone' in JS/TS files
    new_package_path = Paquette::NpmRepacker.repack(@test_package_path) do |input_file, output_file, file_path|
      unless File.extname(file_path).match?(/\.(ts|js|mjs|jsx|tsx)$/)
        IO.copy_stream(input_file, output_file)
        next
      end

      # Read the entire content
      content = input_file.read

      # Replace ALL occurrences of 'Dropzone' with 'Liftzone'
      if content.include?("Dropzone")
        content = content.gsub("Dropzone", "Liftzone")
      end

      # Write the processed content
      output_file.write(content)
    end

    assert File.exist?(new_package_path)
    assert new_package_path.end_with?("-repacked.tgz")

    # Unpack the produced package and verify the replacement
    verify_repacking(new_package_path)

    # Clean up
    File.delete(new_package_path) if File.exist?(new_package_path)
  end

  def test_repack_requires_block
    skip "Test package not found" unless File.exist?(@test_package_path)

    assert_raises(ArgumentError) do
      Paquette::NpmRepacker.repack(@test_package_path)
    end
  end

  def test_repack_with_nonexistent_package
    nonexistent_path = "/nonexistent/path.tgz"

    assert_raises(ArgumentError) do
      Paquette::NpmRepacker.repack(nonexistent_path) { |input_file, output_file, file_path| }
    end
  end

  def test_repack_creates_new_package_with_different_checksum
    skip "Test package not found" unless File.exist?(@test_package_path)

    original_checksum = Digest::SHA256.file(@test_package_path).hexdigest

    new_package_path = Paquette::NpmRepacker.repack(@test_package_path) do |input_file, output_file, file_path|
      unless File.extname(file_path).match?(/\.(ts|js|mjs|jsx|tsx)$/)
        IO.copy_stream(input_file, output_file)
        next
      end

      content = input_file.read
      content = content.gsub("Dropzone", "Liftzone") if content.include?("Dropzone")
      output_file.write(content)
    end

    new_checksum = Digest::SHA256.file(new_package_path).hexdigest

    assert File.exist?(new_package_path)
    refute_equal original_checksum, new_checksum

    # Clean up
    File.delete(new_package_path) if File.exist?(new_package_path)
  end

  private

  def verify_repacking(package_path)
    # Create a temporary directory to unpack the new package
    temp_dir = Dir.mktmpdir("verify_npm_repacking")
    unpacked_dir = File.join(temp_dir, "unpacked")
    FileUtils.mkdir_p(unpacked_dir)

    begin
      # Unpack the new package
      result = system("tar -xzf #{package_path} -C #{unpacked_dir}")
      assert result, "Failed to unpack the repacked package"

      # Find the unpacked package directory
      package_dir = Dir.glob(File.join(unpacked_dir, "*")).find { |path| File.directory?(path) }
      assert package_dir, "Could not find unpacked package directory"

      # Check JS/TS files for the replacement
      found_replacement = false
      extensions = %w[.ts .js .mjs .jsx .tsx]
      extensions.each do |ext|
        Dir.glob(File.join(package_dir, "**", "*#{ext}")).each do |js_file|
          content = File.read(js_file)
          if content.include?("Liftzone")
            found_replacement = true
          end
          # Ensure the original word is gone (all occurrences)
          refute content.include?("Dropzone"), "Original word 'Dropzone' still present in #{js_file}"
        end
      end

      assert found_replacement, "Replacement word 'Liftzone' not found in any JS/TS file"
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
