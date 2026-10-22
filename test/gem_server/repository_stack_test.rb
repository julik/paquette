require_relative "../test_helper"
require "digest"

class RepositoryStackTest < Minitest::Test
  VALUES = {"licensee" => "TEST-LICENSE-123"}.freeze

  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @dir_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @cache_dir = Dir.mktmpdir("repository_stack")
  end

  def teardown
    FileUtils.remove_entry(@cache_dir)
  end

  def test_repository_stack_setup
    # The stack as GemServer builds it: the gate outside, the personalizer
    # around the corpus
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository, cache_dir: @cache_dir)
    gated_repository = Paquette::GemServer::ReadGatedRepository.new(personalized_repository, EntitlingAuthenticator.new { |**| true })

    as_licensee do
      assert gated_repository.gem_names.include?("minuscule_test")
      assert gated_repository.versions_for_gem("minuscule_test").include?("0.1.0")
      assert gated_repository.gem_exists?("minuscule_test", "0.1.0")

      gem_path = gated_repository.gem_file_path("minuscule_test", "0.1.0")
      assert File.exist?(gem_path)

      original_path = @dir_repository.gem_file_path("minuscule_test", "0.1.0")
      refute_equal original_path, gem_path
      refute_equal Digest::SHA256.file(original_path).hexdigest, Digest::SHA256.file(gem_path).hexdigest
    end
  end

  def test_stack_delegation
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository, cache_dir: @cache_dir)
    gated_repository = Paquette::GemServer::ReadGatedRepository.new(personalized_repository, EntitlingAuthenticator.new { |**| true })

    as_licensee do
      assert_equal @dir_repository.gem_names, gated_repository.gem_names
      assert_equal @dir_repository.gem_versions, gated_repository.gem_versions

      personalized_info = gated_repository.compact_info("minuscule_test")
      original_info = @dir_repository.compact_info("minuscule_test")

      assert_equal original_info.length, personalized_info.length
      refute_equal extract_checksum(original_info.first), extract_checksum(personalized_info.first)
    end
  end

  # The same stack, with nobody to personalize for, is the corpus as it is.
  def test_the_stack_serves_vanilla_bytes_to_a_caller_without_personalization
    personalized_repository = Paquette::GemServer::Personalizer.new(@dir_repository, cache_dir: @cache_dir)

    Paquette::Authenticator.with(Paquette::Authenticator.new(nil)) do
      assert_equal @dir_repository.gem_file_path("minuscule_test", "0.1.0"), personalized_repository.gem_file_path("minuscule_test", "0.1.0")
      assert_equal @dir_repository.compact_info("minuscule_test"), personalized_repository.compact_info("minuscule_test")
    end
  end

  private

  def as_licensee(&block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, VALUES), &block)
  end

  def extract_checksum(info_line)
    if (match = info_line.match(/checksum:([a-f0-9]+)/))
      match[1]
    end
  end
end
