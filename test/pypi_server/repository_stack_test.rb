require_relative "../test_helper"

# The repository and the wrappers around it, below the HTTP layer
class PypiRepositoryStackTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_pypi_stack")
    @cache_dir = Dir.mktmpdir("paquette_pypi_stack_cache")
    @repository = Paquette::PypiServer::DirectoryPypiRepository.new(@dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
    FileUtils.rm_rf(@cache_dir)
  end

  attr_accessor :app

  def test_the_directory_lists_projects_and_files
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    write_sdist(@dir, name: "widgets", version: "1.0.0")
    write_wheel(@dir, name: "Acme.Gadgets", version: "2.0.0")

    assert_equal ["acme-gadgets", "widgets"], @repository.project_names
    assert_equal ["widgets-1.0.0-py3-none-any.whl", "widgets-1.0.0.tar.gz"], @repository.filenames_for_project("widgets")
    assert_equal ["1.0.0"], @repository.versions_for_project("widgets")
  end

  def test_file_info_describes_the_file
    path = write_wheel(@dir, name: "widgets", version: "1.0.0", requires_python: ">=3.9, <4")
    info = @repository.file_info("widgets", "widgets-1.0.0-py3-none-any.whl")

    assert_equal "1.0.0", info.version
    assert_equal Digest::SHA256.file(path).hexdigest, info.sha256
    assert_equal File.size(path), info.size
    assert_equal ">=3.9, <4", info.requires_python
    assert_equal false, info.yanked
  end

  def test_an_sdist_reads_requires_python_out_of_pkg_info
    write_sdist(@dir, name: "widgets", version: "1.0.0", requires_python: ">=3.10")

    assert_equal ">=3.10", @repository.file_info("widgets", "widgets-1.0.0.tar.gz").requires_python
  end

  # Older tools named the .dist-info their own way
  def test_a_lone_dist_info_with_another_spelling_is_still_found
    write_distribution(@dir, "widgets", "widgets-1.0.0-py3-none-any.whl",
      wheel_bytes(name: "widgets", version: "1.0.0", dist_info: "Widgets-1.0.0.dist-info"))

    assert_includes @repository.core_metadata("widgets", "widgets-1.0.0-py3-none-any.whl"), "Name: widgets"
  end

  # The declared size is the uploader's to choose; what comes out of the
  # inflate is what the ceiling is held against
  def test_a_metadata_bomb_is_refused_rather_than_inflated
    bomb = core_metadata_text("widgets", "1.0.0") + ("A" * (Paquette::PypiServer::PypiRepository::MAX_METADATA_BYTES + 10))
    source = File.join(@cache_dir, "upload.whl")
    File.binwrite(source, wheel_bytes(name: "widgets", version: "1.0.0", metadata: bomb))

    error = assert_raises(Paquette::PypiServer::DirectoryPypiRepository::InvalidDistribution) do
      @repository.add_file(source, "widgets-1.0.0-py3-none-any.whl")
    end
    assert_includes error.message, "inflates to more than"
  end

  def test_an_upload_without_metadata_is_refused
    source = File.join(@cache_dir, "upload.tar.gz")
    Paquette::Tarball.write(source, [Paquette::Tarball::Entry.new(name: "widgets-1.0.0/setup.py", mode: 0o644, mtime: 0, content: "")])

    assert_raises(Paquette::PypiServer::DirectoryPypiRepository::InvalidDistribution) do
      @repository.add_file(source, "widgets-1.0.0.tar.gz")
    end
  end

  def test_the_fingerprint_moves_with_an_upload_and_a_yank
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    before = @repository.fingerprint
    write_wheel(@dir, name: "widgets", version: "1.1.0")
    after_upload = @repository.fingerprint
    @repository.yank_file("widgets", "widgets-1.1.0-py3-none-any.whl")

    refute_equal before, after_upload
    refute_equal after_upload, @repository.fingerprint
  end

  def test_the_gate_hides_projects_and_versions
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    write_wheel(@dir, name: "widgets", version: "2.0.0")
    write_wheel(@dir, name: "secret", version: "1.0.0")
    gated = Paquette::PypiServer::ReadGatedRepository.new(@repository) do |name:, version: nil|
      name == "widgets" && (version.nil? || version.start_with?("1."))
    end

    assert_equal ["widgets"], gated.project_names
    assert_equal ["widgets-1.0.0-py3-none-any.whl"], gated.filenames_for_project("widgets")
    assert_nil gated.file_path("widgets", "widgets-2.0.0-py3-none-any.whl")
    assert_nil gated.file_info("widgets", "widgets-2.0.0-py3-none-any.whl")
    assert_nil gated.core_metadata("widgets", "widgets-2.0.0-py3-none-any.whl")
    assert_nil gated.file_info("secret", "secret-1.0.0-py3-none-any.whl")
  end

  def test_a_gated_download_outside_the_entitlement_is_a_404
    write_wheel(@dir, name: "secret", version: "1.0.0")
    self.app = Paquette::PypiServer.new(Paquette::PypiServer::ReadGatedRepository.new(@repository) { |**| false })

    get "/files/secret/secret-1.0.0-py3-none-any.whl"
    assert_equal 404, last_response.status
    get "/files/secret/secret-1.0.0-py3-none-any.whl.metadata"
    assert_equal 404, last_response.status
    get "/simple/secret/"
    assert_equal 404, last_response.status
  end

  # Nothing that differs per caller may be stored `public`, and a gate
  # without a key names no ETag at all
  def test_a_keyless_gate_emits_no_etag_and_stays_private
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    self.app = Paquette::PypiServer.new(Paquette::PypiServer::ReadGatedRepository.new(@repository) { |**| true })
    get "/simple/widgets/"

    assert_nil last_response.headers["etag"]
    assert_includes last_response.headers["cache-control"], "private"
  end

  def test_two_gate_keys_name_two_etags
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    etags = ["alice", "bob"].map do |key|
      server = Paquette::PypiServer.new(Paquette::PypiServer::ReadGatedRepository.new(@repository, gate_key: key) { |**| true })
      Rack::MockRequest.new(server).get("/simple/widgets/").headers["etag"]
    end

    assert_equal 2, etags.compact.uniq.length
  end

  # MockRequest rather than Rack::Test, which sends a Cookie header - and a
  # request with one is rightly never answered `public`
  def test_an_ungated_anonymous_page_is_public
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    response = Rack::MockRequest.new(Paquette::PypiServer.new(@repository)).get("/simple/widgets/")

    assert_includes response.headers["cache-control"], "public"
  end

  def test_the_cooldown_withholds_a_fresh_file
    old = write_wheel(@dir, name: "widgets", version: "1.0.0")
    File.utime(Time.now - 3600, Time.now - 3600, old)
    write_wheel(@dir, name: "widgets", version: "1.1.0")
    write_wheel(@dir, name: "fresh", version: "1.0.0")
    cooled = Paquette::PypiServer::CooldownRepository.new(@repository, interval: 600)

    assert_equal ["widgets"], cooled.project_names
    assert_equal ["widgets-1.0.0-py3-none-any.whl"], cooled.filenames_for_project("widgets")
    assert_nil cooled.file_path("widgets", "widgets-1.1.0-py3-none-any.whl")
  end

  def test_an_upload_through_the_cooldown_lands_and_stays_out_of_view
    source = File.join(@cache_dir, "upload.whl")
    File.binwrite(source, wheel_bytes(name: "widgets", version: "1.0.0"))
    cooled = Paquette::PypiServer::CooldownRepository.new(@repository, interval: 600)
    cooled.add_file(source, "widgets-1.0.0-py3-none-any.whl")

    assert_equal ["widgets-1.0.0-py3-none-any.whl"], @repository.filenames_for_project("widgets")
    assert_empty cooled.filenames_for_project("widgets")
  end

  def test_the_cooldown_validator_moves_when_a_file_cools
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    now = Time.now
    clock = -> { now }
    cooled = Paquette::PypiServer::CooldownRepository.new(@repository, interval: 600, clock: clock)
    before = cooled.cache_validator
    now += 601

    refute_nil before
    refute_equal before, cooled.cache_validator
  end

  def test_the_cooldown_can_read_its_times_from_elsewhere
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    asked = []
    cooled = Paquette::PypiServer::CooldownRepository.new(@repository, interval: 600,
      published_at: ->(name:, version:, filename:) { asked << [name, version, filename] && Time.now })

    assert_empty cooled.filenames_for_project("widgets")
    assert_includes asked, ["widgets", "1.0.0", "widgets-1.0.0-py3-none-any.whl"]
    assert_nil cooled.cache_validator
  end

  def test_the_personalizer_repacks_a_wheel_with_a_record_that_checks_out
    write_wheel(@dir, name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "# paquette_license_info\nVERSION = '1.0.0'\n"})
    path = personalizer.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")

    assert_includes wheel_file(path, "widgets/__init__.py"), "# licensed to LIC-1"
    assert_equal "Licensed.", wheel_file(path, "widgets/LICENSE.txt")
    assert_equal({"license_key" => "LIC-1"}, JSON.parse(wheel_file(path, "widgets-1.0.0.dist-info/paquette.json")))

    record = wheel_file(path, "widgets-1.0.0.dist-info/RECORD").lines.map { |line| line.chomp.split(",") }
    names = Paquette::Wheel.entry_names(path)
    assert_equal names.sort, record.map(&:first).sort
    record.reject { |name, _, _| name.end_with?("/RECORD") }.each do |name, hash, size|
      content = wheel_file(path, name)
      assert_equal Paquette::Wheel.record_hash(content), hash, name
      assert_equal content.bytesize.to_s, size, name
    end
    assert names.last.end_with?(".dist-info/RECORD"), "RECORD is not the last member: #{names.inspect}"
  end

  # pip checks the sha256 the page published, and a second process has to
  # land on the same bytes the first one hashed
  def test_the_personalized_wheel_is_byte_reproducible
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    first = File.binread(personalizer.file_path("widgets", "widgets-1.0.0-py3-none-any.whl"))
    second = File.binread(personalizer(cache_dir: Dir.mktmpdir("paquette_second_cache")).file_path("widgets", "widgets-1.0.0-py3-none-any.whl"))

    assert_equal Digest::SHA256.hexdigest(first), Digest::SHA256.hexdigest(second)
  end

  def test_the_personalized_page_describes_the_personalized_file
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    stack = personalizer
    info = stack.file_info("widgets", "widgets-1.0.0-py3-none-any.whl")
    served = stack.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")

    assert_equal Digest::SHA256.file(served).hexdigest, info.sha256
    assert_equal File.size(served), info.size
    refute_equal @repository.file_info("widgets", "widgets-1.0.0-py3-none-any.whl").sha256, info.sha256
    # METADATA is untouched, so its hash is still the repository's
    assert_equal @repository.file_info("widgets", "widgets-1.0.0-py3-none-any.whl").core_metadata_sha256,
      info.core_metadata_sha256
  end

  def test_two_licensees_never_share_a_file_or_an_etag
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    alice = personalizer(license_key: "LIC-A")
    bob = personalizer(license_key: "LIC-B")

    refute_equal alice.file_path("widgets", "widgets-1.0.0-py3-none-any.whl"), bob.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")
    refute_equal alice.cache_validator, bob.cache_validator
  end

  def test_signatures_over_the_old_record_are_dropped
    signed = wheel_bytes(name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "", "widgets-1.0.0.dist-info/RECORD.jws" => "signature"})
    write_distribution(@dir, "widgets", "widgets-1.0.0-py3-none-any.whl", signed)
    path = personalizer.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")

    refute_includes Paquette::Wheel.entry_names(path), "widgets-1.0.0.dist-info/RECORD.jws"
  end

  def test_the_personalizer_repacks_an_sdist
    write_sdist(@dir, name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "  # paquette_license_info\n"})
    path = personalizer.file_path("widgets", "widgets-1.0.0.tar.gz")

    assert_equal "  # licensed to LIC-1\n", tarball_file(path, "widgets-1.0.0/widgets/__init__.py")
    assert_equal({"license_key" => "LIC-1"}, JSON.parse(tarball_file(path, "widgets-1.0.0/paquette.json")))
  end

  # A marker the line-wise pass cannot reach would have shipped the file
  # with no key in it and nothing to say so
  def test_a_marker_not_alone_on_its_line_refuses_the_repack
    write_wheel(@dir, name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "VERSION = 1  # paquette_license_info\n"})

    assert_raises(Paquette::NpmRepacker::MarkerNotApplied) do
      personalizer.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")
    end
  end

  def test_a_multiline_replacement_is_refused_up_front
    assert_raises(Paquette::NpmRepacker::MultilineReplacement) do
      Paquette::PypiServer::Personalizer.new(@repository, license_key: "x", magic_comment_replacements: {"# x" => "a\nb"})
    end
  end

  def test_files_for_returning_nil_serves_the_file_as_it_is
    path = write_wheel(@dir, name: "widgets", version: "1.0.0")
    stack = personalizer(files_for: ->(_project, _filename, _path) {})

    assert_equal path, stack.file_path("widgets", "widgets-1.0.0-py3-none-any.whl")
    assert_equal @repository.file_info("widgets", "widgets-1.0.0-py3-none-any.whl").sha256,
      stack.file_info("widgets", "widgets-1.0.0-py3-none-any.whl").sha256
  end

  private

  def personalizer(license_key: "LIC-1", cache_dir: @cache_dir, **options)
    Paquette::PypiServer::Personalizer.new(@repository,
      license_key: license_key,
      magic_comment_replacements: {"# paquette_license_info" => "licensed to #{license_key}"},
      files: {"widgets/LICENSE.txt" => "Licensed."},
      cache_dir: cache_dir, **options)
  end
end
