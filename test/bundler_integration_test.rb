require_relative "test_helper"
require_relative "server_manager"
require "fileutils"

class BundlerIntegrationTest < RackIntegrationTest
  def setup
    super
    ServerManager.start_server
    clean_test_directory
  end

  def test_bundler_can_install_gems_from_paquette
    # Test that Bundler can install gems from Paquette
    result = run_bundler_install

    # Verify the installation was successful
    assert_equal 0, result[:exit_code], "Bundle install failed: #{result[:stderr]}"
    assert_includes result[:stdout], "Bundle complete!"
    assert_includes result[:stdout], "test-gem"
  end

  private

  def clean_test_directory
    test_dir = File.expand_path("bundler_integration", __dir__)
    
    # Remove files that might interfere with bundler
    FileUtils.rm_f(File.join(test_dir, "Gemfile.lock"))
    FileUtils.rm_rf(File.join(test_dir, "vendor"))
    FileUtils.rm_rf(File.join(test_dir, ".bundle"))
  end

  def run_bundler_install
    test_dir = File.expand_path("bundler_integration", __dir__)

    # Update the Gemfile to use the correct port
    update_gemfile_with_port(test_dir)

    # Run bundle install
    stdout, stderr, status = Open3.capture3(
      "cd #{test_dir} && bundle install",
      chdir: test_dir
    )

    {
      stdout: stdout,
      stderr: stderr,
      exit_code: status.exitstatus
    }
  end

  def update_gemfile_with_port(test_dir)
    gemfile_path = File.join(test_dir, "Gemfile")
    gemfile_content = File.read(gemfile_path)
    # Replace any existing port with the current server port
    updated_content = gemfile_content.gsub(/127\.0\.0\.1:\d+/, "127.0.0.1:#{ServerManager.server_port}")
    File.write(gemfile_path, updated_content)
  end
end
