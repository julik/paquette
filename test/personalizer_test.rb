require_relative "test_helper"

class PersonalizerTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./packages/gems", Dir.pwd)
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @personalizer = Paquette::GemServer::Personalizer.new(@dir_repository,
      license_key: "TEST-LICENSE-123",
      magic_comment_replacements: {"# paquette_license_info" => "TEST-LICENSE-123"})
  end

  def test_personalizer_delegates_to_repository
    # Test that basic repository methods still work
    assert @personalizer.gem_names.include?("minuscule_test")
    assert @personalizer.versions_for_gem("minuscule_test").include?("0.1.0")
    assert @personalizer.gem_exists?("minuscule_test", "0.1.0")
  end

  def test_gem_file_path_returns_personalized_gem
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Get the personalized gem path
    personalized_path = @personalizer.gem_file_path("minuscule_test", "0.1.0")

    # Should be a different path than the original
    original_path = @dir_repository.gem_file_path("minuscule_test", "0.1.0")
    refute_equal original_path, personalized_path

    # Should exist and be a file
    assert File.exist?(personalized_path)
    assert File.file?(personalized_path)

    # Should have a different checksum than the original
    require "digest"
    original_checksum = Digest::SHA256.file(original_path).hexdigest
    personalized_checksum = Digest::SHA256.file(personalized_path).hexdigest
    refute_equal original_checksum, personalized_checksum
  end

  def test_compact_info_uses_personalized_checksums
    skip "Test gem not found" unless @personalizer.gem_exists?("minuscule_test", "0.1.0")

    # Get compact info from personalizer
    personalized_info = @personalizer.compact_info("minuscule_test")

    # Get compact info from original repository
    original_info = @dir_repository.compact_info("minuscule_test")

    # Should have same number of versions
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
