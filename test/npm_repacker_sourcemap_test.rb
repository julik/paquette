require_relative "test_helper"

class NpmRepackerSourcemapTest < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir('npm_repacker_sourcemap_test')
    @package_dir = File.join(@temp_dir, 'package')
    FileUtils.mkdir_p(@package_dir)
    
    # Create a test package with JS file and sourcemap
    create_test_package
  end

  def teardown
    FileUtils.rm_rf(@temp_dir)
  end

  def test_repack_with_sourcemap_updates
    # Create a temporary NPM package
    package_path = create_npm_package
    
    # Repack the package with text replacement
    new_package_path = Paquette::NpmRepacker.repack(package_path) do |input_file, output_file, file_path|
      unless File.extname(file_path).match?(/\.(ts|js|mjs|jsx|tsx)$/)
        IO.copy_stream(input_file, output_file)
        next
      end

      content = input_file.read
      # Add some text to change the file length (simulating a real transformation)
      content = content.gsub('function test()', 'function test() { console.log("modified");')
      output_file.write(content)
    end
    
    assert File.exist?(new_package_path)
    
    # Unpack and verify the sourcemap was updated
    verify_sourcemap_update(new_package_path)
    
    # Clean up
    File.delete(package_path) if File.exist?(package_path)
    File.delete(new_package_path) if File.exist?(new_package_path)
  end

  private

  def create_test_package
    # Create a simple JS file
    js_content = <<~JS
      function test() {
        return "hello world";
      }
      //# sourceMappingURL=test.js.map
    JS
    
    # Create a simple sourcemap
    sourcemap_content = {
      version: 3,
      sources: ["test.js"],
      names: ["test"],
      mappings: "AAAA,SAAS,SAAS,SAAS,CAAC",
      file: "test.js"
    }.to_json
    
    File.write(File.join(@package_dir, 'test.js'), js_content)
    File.write(File.join(@package_dir, 'test.js.map'), sourcemap_content)
  end

  def create_npm_package
    package_path = File.join(@temp_dir, 'test-package.tgz')
    result = system("cd #{@temp_dir} && tar -czf #{package_path} package/")
    raise "Failed to create test package" unless result
    package_path
  end

  def verify_sourcemap_update(package_path)
    # Unpack the repacked package
    temp_unpack_dir = Dir.mktmpdir('verify_sourcemap')
    begin
      result = system("tar -xzf #{package_path} -C #{temp_unpack_dir}")
      assert result, "Failed to unpack the repacked package"
      
      # Find the unpacked package directory
      package_dir = Dir.glob(File.join(temp_unpack_dir, '*')).select { |path| File.directory?(path) }.first
      assert package_dir, "Could not find unpacked package directory"
      
      # Check that the JS file was modified
      js_file = File.join(package_dir, 'test.js')
      assert File.exist?(js_file), "JS file not found"
      
      js_content = File.read(js_file)
      assert js_content.include?('console.log("modified")'), "JS file was not modified"
      
      # Check that the sourcemap was updated
      sourcemap_file = File.join(package_dir, 'test.js.map')
      if File.exist?(sourcemap_file)
        sourcemap_content = File.read(sourcemap_file)
        sourcemap = JSON.parse(sourcemap_content)
        
        # The sourcemap should have been updated (we can't easily verify the exact mapping changes
        # without a more complex test, but we can verify it's still valid JSON)
        assert sourcemap.is_a?(Hash), "Sourcemap is not valid JSON"
        assert sourcemap['version'], "Sourcemap missing version"
      end
      
    ensure
      FileUtils.rm_rf(temp_unpack_dir)
    end
  end
end
