require_relative "test_helper"

class RepositoryStackTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
  end

  def test_repository_stack_setup
    # Test the exact stack setup as used in GemServer
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository,
      license_key: "TEST-LICENSE-123",
      magic_comment_replacements: {"# paquette_license_info" => "TEST-LICENSE-123"})
    gated_repository = Paquette::GemServer::GatedGemRepository.new(personalized_repository) { |name:, version: nil| true }

    # Verify the stack works end-to-end
    assert gated_repository.gem_names.include?("minuscule_test")
    assert gated_repository.versions_for_gem("minuscule_test").include?("0.1.0")
    assert gated_repository.gem_exists?("minuscule_test", "0.1.0")

    # Test that personalization happens through the stack
    skip "Test gem not found" unless gated_repository.gem_exists?("minuscule_test", "0.1.0")

    gem_path = gated_repository.gem_file_path("minuscule_test", "0.1.0")
    assert File.exist?(gem_path)

    # Should be a personalized gem (different from original)
    original_path = @dir_repository.gem_file_path("minuscule_test", "0.1.0")
    refute_equal original_path, gem_path

    # Should have different checksums
    require "digest"
    original_checksum = Digest::SHA256.file(original_path).hexdigest
    personalized_checksum = Digest::SHA256.file(gem_path).hexdigest
    refute_equal original_checksum, personalized_checksum
  end

  def test_stack_delegation
    # Test that all methods are properly delegated through the stack
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository,
      license_key: "TEST-LICENSE-123",
      magic_comment_replacements: {"# paquette_license_info" => "TEST-LICENSE-123"})
    gated_repository = Paquette::GemServer::GatedGemRepository.new(personalized_repository) { |name:, version: nil| true }

    # Test that methods are delegated correctly
    assert_equal @dir_repository.gem_names, gated_repository.gem_names
    assert_equal @dir_repository.gem_versions, gated_repository.gem_versions

    # Test that personalization is applied
    skip "Test gem not found" unless gated_repository.gem_exists?("minuscule_test", "0.1.0")

    # compact_info should use personalized checksums
    personalized_info = gated_repository.compact_info("minuscule_test")
    original_info = @dir_repository.compact_info("minuscule_test")

    assert_equal original_info.length, personalized_info.length

    # But checksums should be different
    original_checksum = extract_checksum(original_info.first)
    personalized_checksum = extract_checksum(personalized_info.first)
    refute_equal original_checksum, personalized_checksum
  end

  private

  def extract_checksum(info_line)
    if (match = info_line.match(/checksum:([a-f0-9]+)/))
      match[1]
    end
  end
end
