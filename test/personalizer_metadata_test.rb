require_relative "test_helper"

class PersonalizerMetadataTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @personalizer = Paquette::GemServer::Personalizer.new(@dir_repository, license_key: "TEST-LICENSE-789")
  end

  def test_personalizer_adds_license_metadata_to_gem_spec
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Get the personalized gem path
    personalized_gem_path = @personalizer.gem_file_path("minuscule_test", "0.1.0")
    assert File.exist?(personalized_gem_path)

    # Read the gem specification and verify the license key metadata
    gem_package = Gem::Package.new(personalized_gem_path)
    spec = gem_package.spec

    # Verify the license key is in the metadata
    assert_equal "TEST-LICENSE-789", spec.metadata["paquette.license_key"], "Expected paquette.license_key metadata to be set"

    # Verify the original gem doesn't have this metadata
    original_gem_path = @dir_repository.gem_file_path("minuscule_test", "0.1.0")
    original_gem_package = Gem::Package.new(original_gem_path)
    original_spec = original_gem_package.spec

    assert_nil original_spec.metadata["paquette.license_key"], "Original gem should not have paquette.license_key metadata"
  end

  def test_metadata_persistence_through_repository_stack
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Test that the metadata persists through the repository stack
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository, license_key: "STACK-TEST-123")
    gated_repository = Paquette::GemServer::GatedGemRepository.new(personalized_repository) { |name:, version: nil| true }

    # Get gem through the stack
    gem_path = gated_repository.gem_file_path("minuscule_test", "0.1.0")
    assert File.exist?(gem_path)

    # Verify metadata is present
    gem_package = Gem::Package.new(gem_path)
    spec = gem_package.spec

    assert_equal "STACK-TEST-123", spec.metadata["paquette.license_key"], "Expected paquette.license_key metadata to be set through repository stack"
  end
end
