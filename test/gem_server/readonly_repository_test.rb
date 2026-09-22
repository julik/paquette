require_relative "../test_helper"

class ReadonlyRepositoryTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @gems_dir = FIXTURE_GEMS_DIR
    @directory_repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    @repository = Paquette::GemServer::ReadonlyRepository.new(@directory_repository)
  end

  def app
    Paquette::GemServer.new(@repository)
  end

  def test_add_gem_raises_write_not_allowed
    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) do
      @repository.add_gem("anything")
    end
  end

  def test_yank_gem_raises_write_not_allowed
    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) do
      @repository.yank_gem("zip_kit", "6.2.0")
    end
  end

  # The writes raise before reaching the wrapped repository, which is the whole
  # point — a refused push must not leave anything behind on disk.
  def test_refused_write_does_not_touch_the_wrapped_repository
    Dir.mktmpdir("readonly_repository") do |dir|
      writable = Paquette::GemServer::DirectoryGemRepository.new(dir)
      repository = Paquette::GemServer::ReadonlyRepository.new(writable)
      gem_binary = File.binread(File.join(@gems_dir, "minuscule_test", "minuscule_test-0.1.0.gem"))

      assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) do
        repository.add_gem(gem_binary)
      end

      assert_empty writable.gem_names
      assert_empty Dir.glob(File.join(dir, "**", "*.gem"))
    end
  end

  def test_reads_pass_through_untouched
    assert_equal ["minuscule_test", "zip_kit"], @repository.gem_names.sort
    assert_includes @repository.versions_for_gem("zip_kit"), "6.2.0"
    assert @repository.gem_exists?("zip_kit", "6.2.0")
    assert_equal "zip_kit", @repository.gem_spec("zip_kit", "6.2.0").name
    assert @repository.gem_dependencies("zip_kit", "6.2.0").is_a?(Array)
    assert_equal @directory_repository.gem_file_path("zip_kit", "6.2.0"),
      @repository.gem_file_path("zip_kit", "6.2.0")
    assert_equal @directory_repository.compact_info("zip_kit"), @repository.compact_info("zip_kit")
  end

  # Methods this wrapper never heard of — fingerprint among them — have to keep
  # reaching the wrapped repository, or a readonly stack would answer
  # differently from the same corpus served directly.
  def test_unknown_methods_still_delegate
    assert_equal @directory_repository.fingerprint, @repository.fingerprint
    assert_same @directory_repository, @repository.__getobj__
    assert_respond_to @repository, :fingerprint
  end

  def test_wrapping_is_stackable
    repository = Paquette::GemServer::ReadonlyRepository.new(
      Paquette::GemServer::ReadGatedRepository.new(@directory_repository) { |name:, version: nil| name == "zip_kit" }
    )

    assert_equal ["zip_kit"], repository.gem_names
    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) do
      repository.add_gem("anything")
    end
  end

  # ReadGatedRepository inherits its writes from here, so both names have to go
  # on denoting the same exception — the server's rescue clauses name one of
  # them and have to catch the other.
  def test_read_gated_repository_shares_the_exception
    assert_same(
      Paquette::GemServer::ReadonlyRepository::WriteNotAllowed,
      Paquette::GemServer::ReadGatedRepository::WriteNotAllowed
    )
    assert_operator Paquette::GemServer::ReadGatedRepository, :<, Paquette::GemServer::ReadonlyRepository
  end

  def test_server_answers_403_to_a_push
    gem_binary = File.binread(File.join(@gems_dir, "minuscule_test", "minuscule_test-0.1.0.gem"))
    post "/api/v1/gems", gem_binary, "CONTENT_TYPE" => "application/octet-stream"

    assert_equal 403, last_response.status
    assert_includes last_response.body, "not allowed"
  end

  def test_server_answers_403_to_a_yank
    delete "/api/v1/gems/yank", {"gem_name" => "zip_kit", "version" => "6.2.0"}

    assert_equal 403, last_response.status
    assert_includes last_response.body, "not allowed"
  end

  def test_server_still_serves_reads
    get "/api/v1/names"

    assert_equal 200, last_response.status
    assert_includes JSON.parse(last_response.body), "zip_kit"
  end
end
