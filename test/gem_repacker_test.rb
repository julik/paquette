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
    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path) do |input_file, output_file, file_path|
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

  def test_repack_with_metadata_keys
    skip "Test gem not found" unless File.exist?(@test_gem_path)
    
    # Test adding metadata keys to the gemspec
    additional_metadata = {
      "paquette.license_key" => "TEST-LICENSE-123",
      "paquette.custom_field" => "custom_value"
    }
    
    new_gem_path = Paquette::GemServer::GemRepacker.repack(@test_gem_path, additional_metadata_keys: additional_metadata) do |input_file, output_file, file_path|
      # Just copy files without modification for this test
      IO.copy_stream(input_file, output_file)
    end
    
    assert File.exist?(new_gem_path)
    assert new_gem_path.end_with?('-repacked.gem')
    
    # Verify the metadata was added to the gem spec
    verify_metadata_in_gem(new_gem_path, additional_metadata)
    
    # Clean up
    File.delete(new_gem_path) if File.exist?(new_gem_path)
  end

  def test_repack_with_personalizer_metadata
    skip "Test gem not found" unless File.exist?(@test_gem_path)
    
    # Test that Personalizer-style metadata addition works
    personalized_gem_path = create_personalized_gem
    
    # Verify the metadata was added
    verify_metadata_in_gem(personalized_gem_path, { "paquette.license_key" => "TEST-LICENSE-456" })
    
    # Clean up
    File.delete(personalized_gem_path) if File.exist?(personalized_gem_path)
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

  def create_personalized_gem
    # Create a personalized gem using the Personalizer approach
    personalized_dir = File.join(Dir.tmpdir, "paquette_personalized")
    FileUtils.mkdir_p(personalized_dir)
    
    personalized_path = File.join(personalized_dir, "minuscule_test-0.1.0-personalized.gem")
    
    Paquette::GemServer::GemRepacker.repack(@test_gem_path, additional_metadata_keys: { "paquette.license_key" => "TEST-LICENSE-456" }) do |input_file, output_file, file_path|
      unless File.extname(file_path) == ".rb"
        IO.copy_stream(input_file, output_file)
        next
      end

      input_file.each_line do |line|
        if line.chomp == '# paquette_license_info'
          output_file.puts("# TEST-LICENSE-456\n")
          IO.copy_stream(input_file, output_file) # Copy the rest
          next
        else
          output_file.write(line)
        end
      end
    end
    
    # Move the repacked gem to our personalized location
    temp_personalized = File.join(Dir.tmpdir, "minuscule_test-0.1.0-repacked.gem")
    if File.exist?(temp_personalized)
      FileUtils.mv(temp_personalized, personalized_path)
    end
    
    personalized_path
  end

  def verify_metadata_in_gem(gem_path, expected_metadata)
    # Read the gem specification directly from the gem file
    gem_package = Gem::Package.new(gem_path)
    spec = gem_package.spec
    
    # Verify each expected metadata key is present in the spec
    expected_metadata.each do |key, value|
      assert_equal value, spec.metadata[key], "Expected metadata key '#{key}' to have value '#{value}', but got '#{spec.metadata[key]}'"
    end
  end
end
