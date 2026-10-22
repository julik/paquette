require_relative "../test_helper"

# The caller's values land in the gemspec metadata of every gem that carries
# a marker, under paquette.<key>, so `gem spec` on a leaked gem names its
# licensee.
class PersonalizerMetadataTest < Minitest::Test
  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @cache_dir = Dir.mktmpdir("personalizer_metadata")
    @personalizer = Paquette::GemServer::Personalizer.new(@dir_repository, cache_dir: @cache_dir)
  end

  def teardown
    FileUtils.remove_entry(@cache_dir)
  end

  def test_personalizer_stamps_every_value_into_the_gem_spec
    personalized_gem_path = as("TEST-LICENSE-789", "Acme BV") { @personalizer.gem_file_path("minuscule_test", "0.1.0") }
    assert File.exist?(personalized_gem_path)

    spec = Gem::Package.new(personalized_gem_path).spec
    assert_equal "TEST-LICENSE-789", spec.metadata["paquette.license_key"]
    assert_equal "Acme BV", spec.metadata["paquette.licensee"]

    original_spec = Gem::Package.new(@dir_repository.gem_file_path("minuscule_test", "0.1.0")).spec
    assert_nil original_spec.metadata["paquette.license_key"], "Original gem should not have paquette.license_key metadata"
    assert_nil original_spec.metadata["paquette.licensee"]
  end

  def test_metadata_persistence_through_repository_stack
    gated_repository = Paquette::GemServer::ReadGatedRepository.new(@personalizer, EntitlingAuthenticator.new { |**| true })

    gem_path = as("STACK-TEST-123", "Acme BV") { gated_repository.gem_file_path("minuscule_test", "0.1.0") }
    assert File.exist?(gem_path)

    spec = Gem::Package.new(gem_path).spec
    assert_equal "STACK-TEST-123", spec.metadata["paquette.license_key"], "Expected paquette.license_key metadata to be set through repository stack"
  end

  # No marker, no stamp: the gem is the one on disk, byte for byte.
  def test_a_gem_without_a_marker_is_not_stamped
    path = as("TEST-LICENSE-789", "Acme BV") { @personalizer.gem_file_path("zip_kit", "6.2.0") }

    assert_equal @dir_repository.gem_file_path("zip_kit", "6.2.0"), path
    assert_nil Gem::Package.new(path).spec.metadata["paquette.license_key"]
  end

  private

  def as(license_key, licensee, &block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, {"license_key" => license_key, "licensee" => licensee}), &block)
  end
end
