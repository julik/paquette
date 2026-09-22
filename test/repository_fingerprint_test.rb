require_relative "test_helper"

# fingerprint exists so an application can build an HTTP cache validator over
# the corpus without knowing how the repository keeps it — which files there
# are, and that a dist-tag write edits a file in place instead of moving one.
class RepositoryFingerprintTest < Minitest::Test
  def test_gem_fingerprint_is_stable_and_moves_with_pushes_and_yanks
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), dir)
      repository = Paquette::GemServer::DirectoryGemRepository.new(dir)

      first = repository.fingerprint
      assert_equal first, repository.fingerprint

      repository.add_gem(File.binread(File.join(FIXTURE_GEMS_DIR, "zip_kit", "zip_kit-6.2.1.gem")))
      after_push = repository.fingerprint
      refute_equal first, after_push

      repository.yank_gem("zip_kit", "6.2.1")
      refute_equal after_push, repository.fingerprint
    end
  end

  def test_npm_fingerprint_moves_with_publishes_dist_tags_and_unpublishes
    Dir.mktmpdir do |dir|
      repository = Paquette::NpmServer::DirectoryNpmRepository.new(dir)
      write_npm_package(dir, name: "@acme/widgets", version: "1.0.0")
      write_npm_package(dir, name: "@acme/widgets", version: "1.1.0")

      first = repository.fingerprint
      assert_equal first, repository.fingerprint

      repository.add_package(npm_tarball_bytes(name: "@acme/widgets", version: "1.2.0"))
      after_publish = repository.fingerprint
      refute_equal first, after_publish

      # The first tag write creates dist-tags.json; the second edits it in
      # place, which is the case the mtime in the digest exists for.
      repository.write_dist_tag("@acme/widgets", "beta", "1.0.0")
      after_first_tag = repository.fingerprint
      refute_equal after_publish, after_first_tag

      sleep 0.01
      repository.write_dist_tag("@acme/widgets", "beta", "1.1.0")
      after_moved_tag = repository.fingerprint
      refute_equal after_first_tag, after_moved_tag

      repository.yank_package("@acme/widgets", "1.2.0")
      refute_equal after_moved_tag, repository.fingerprint
    end
  end
end
