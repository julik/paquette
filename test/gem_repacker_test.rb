require_relative "test_helper"

class GemRepackerTest < Minitest::Test
  def setup
    @test_gem_path = File.expand_path("./packages/gems/minuscule_test/minuscule_test-0.1.0.gem", Dir.pwd)
  end

  def test_repack_with_line_transformation
    skip "Test gem not found" unless File.exist?(@test_gem_path)
    
    # Generate random characters for the replacement
    random_chars = (0...8).map { ('a'..'z').to_a[rand(26)] }.join
    
    # Replace lines that chomp to '# paquette_license_info' with '# LIC#{random_chars}'
    new_gem_path = Paquette::GemRepacker.repack(@test_gem_path) do |input_file, output_file, file_path|
      unless File.extname(file_path) == ".rb"
        IO.copy_stream(input_file, output_file)
        next
      end

      input_file.each_line do |line|
        if line.chomp == '# paquette_license_info'
          output_file.puts("# LIC#{random_chars}\n")
          IO.copy_stream(input_file, output_file) # Copy the rest
          next  
        else
          output_file.write(line)
        end
      end
    end
    
    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?('-repacked.gem')
    
    # Unpack the produced gem and verify the replacement
    verify_repacking(new_gem_path, random_chars)
    
    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  private

  def verify_repacking(gem_path, expected_random_chars)
    # Create a temporary directory to unpack the new gem
    temp_dir = Dir.mktmpdir('verify_repacking')
    unpacked_dir = File.join(temp_dir, 'unpacked')
    FileUtils.mkdir_p(unpacked_dir)
    
    begin
      # Unpack the new gem
      result = system("gem unpack #{gem_path} --target=#{unpacked_dir}")
      assert result, "Failed to unpack the repacked gem"
      
      # Find the unpacked gem directory
      gem_dir = Dir.glob(File.join(unpacked_dir, '*')).select { |path| File.directory?(path) }.first
      assert gem_dir, "Could not find unpacked gem directory"
      
      # Check all Ruby files for the replacement
      found_replacement = false
      Dir.glob(File.join(gem_dir, '**', '*.rb')).each do |rb_file|
        File.readlines(rb_file).each do |line|
          if line.chomp == "# LIC#{expected_random_chars}"
            found_replacement = true
          end
          # Ensure the original line is gone
          refute_equal line.chomp, '# paquette_license_info', "Original line still present in #{rb_file}"
        end
      end
      
      assert found_replacement, "Replacement line '# LIC#{expected_random_chars}' not found in any Ruby file"
      
    ensure
      FileUtils.rm_rf(temp_dir)
    end
  end
end
