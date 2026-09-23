require_relative "test_helper"

# Instrumentation is only worth having if it actually fires on the paths it was
# put there for, and Measurometer is silent by default — with no driver
# attached every `instrument` call is a bare yield, so a span that was never
# added and a span that was added both produce nothing at all. This driver is
# what tells the two apart.
class InstrumentationTest < Minitest::Test
  class RecordingDriver
    attr_reader :spans, :counters, :distributions

    def initialize
      @spans = []
      @counters = []
      @distributions = []
    end

    def instrument(name)
      @spans << name
      yield
    end

    def increment_counter(path, by = 1, tags = {})
      @counters << [path, by, tags]
    end

    def add_distribution_value(path, value, tags = {})
      @distributions << [path, value, tags]
    end

    def set_gauge(name, value, tags = {})
    end
  end

  def setup
    @driver = RecordingDriver.new
    Measurometer.drivers << @driver

    @packages_dir = Dir.mktmpdir("paquette_instrumentation")
    write_npm_package(@packages_dir, name: "widgets", version: "1.0.0")
  end

  def teardown
    Measurometer.drivers.delete(@driver)
    FileUtils.rm_rf(@packages_dir) if @packages_dir
  end

  def test_gem_metadata_request_is_instrumented_down_to_the_repository
    repo = Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)
    Paquette::GemServer.new(repo).call(Rack::MockRequest.env_for("/versions"))

    assert_includes @driver.spans, "paquette.gem_server.call"
    assert_includes @driver.spans, "paquette.route.GET /versions"
    assert_includes @driver.spans, "paquette.gem_server.compact_versions"
    assert_includes @driver.spans, "paquette.gem_repository.gem_versions"
    assert_includes @driver.spans, "paquette.gem_repository.compact_info"
  end

  def test_sidecar_cache_records_a_miss_and_then_a_hit
    Dir.mktmpdir("paquette_sidecars") do |gems_dir|
      FileUtils.cp_r(File.join(FIXTURE_GEMS_DIR, "minuscule_test"), gems_dir)
      repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

      repo.compact_info("minuscule_test")
      assert_includes counter_paths, "paquette.gem_repository.sidecar_miss"
      assert_includes @driver.spans, "paquette.gem_repository.derive_sidecar"

      repo.compact_info("minuscule_test")
      assert_includes counter_paths, "paquette.gem_repository.sidecar_hit"
    end
  end

  # The block a caller hands to `files_for:` is the personalizer's hot spot on
  # a cold cache: it is asked per version of every gem an index covers, and it
  # is somebody else's code, so how long it takes is not something this library
  # can reason about — only report. It went unreported for a while, and what
  # that cost was a 145-second /versions whose profile had a large unexplained
  # gap in the middle of it and no span to hang the blame on.
  def test_the_callers_files_for_block_is_timed
    Dir.mktmpdir("paquette_files_for") do |cache_dir|
      personalizer = Paquette::GemServer::Personalizer.new(
        Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR),
        license_key: "L-1",
        files_for: ->(_name, _version, _path) { {"NOTE.txt" => "for one licensee\n"} },
        cache_dir: cache_dir
      )

      personalizer.gem_file_path("minuscule_test", "0.1.0")

      assert_includes @driver.spans, "paquette.gem_personalizer.files_for"
    end
  end

  # A personalized gem's checksum is what /versions and /info/ publish, and
  # hashing a multi-megabyte gem per version per request is what the sidecar
  # beside it exists to avoid. Both halves are counted, because "the cache is
  # being consulted" and "the cache is answering" are different facts and only
  # the second one is worth having.
  def test_a_personalized_gems_checksum_is_hashed_once_and_then_remembered
    Dir.mktmpdir("paquette_checksums") do |cache_dir|
      personalizer = lambda do
        Paquette::GemServer::Personalizer.new(
          Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR),
          license_key: "L-1",
          files_for: ->(_name, _version, _path) { {"NOTE.txt" => "for one licensee\n"} },
          cache_dir: cache_dir
        )
      end

      personalizer.call.compact_info("minuscule_test")
      assert_includes @driver.spans, "paquette.gem_personalizer.checksum"
      assert_includes counter_paths, "paquette.gem_personalizer.checksum_miss"
      refute_includes counter_paths, "paquette.gem_personalizer.checksum_hit"

      personalizer.call.compact_info("minuscule_test")
      assert_includes counter_paths, "paquette.gem_personalizer.checksum_hit"
    end
  end

  def test_npm_metadata_request_is_instrumented_down_to_the_tarball
    app = Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))
    app.call(Rack::MockRequest.env_for("/widgets"))

    assert_includes @driver.spans, "paquette.npm_server.call"
    assert_includes @driver.spans, "paquette.npm_server.metadata"
    assert_includes @driver.spans, "paquette.npm_repository.package_metadata"
    assert_includes @driver.spans, "paquette.tarball.package_json"
    assert_includes @driver.spans, "paquette.tarball.gunzip"
    assert_includes @driver.spans, "paquette.tarball.integrity"
  end

  # The expensive one: serving a personalized tarball repacks it, and a second
  # request for the same licensee must come out of the cache instead.
  def test_npm_personalization_records_a_repack_and_then_a_cache_hit
    repository = Paquette::NpmServer::Personalizer.new(
      Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir),
      license_key: "key-for-one-licensee"
    )

    repository.package_file_path("widgets", "1.0.0")
    assert_includes @driver.spans, "paquette.npm_personalizer.repack"
    assert_includes @driver.spans, "paquette.npm_repacker.repack"
    assert_includes @driver.spans, "paquette.tarball.write"
    assert_includes counter_paths, "paquette.npm_personalizer.cache_miss"

    repository.package_file_path("widgets", "1.0.0")
    assert_includes counter_paths, "paquette.npm_personalizer.cache_hit"
  end

  def test_the_entitler_of_a_read_gated_repository_is_timed
    gated = Paquette::NpmServer::ReadGatedRepository.new(
      Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    ) { |name:, version: nil| true }

    gated.package_names

    assert_includes @driver.spans, "paquette.npm_read_gate.entitled"
  end

  def test_publishing_records_the_size_of_what_was_pushed
    app = Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))
    body = npm_publish_body(name: "gadgets", version: "1.0.0")
    app.call(Rack::MockRequest.env_for("/gadgets",
      :method => "PUT", :input => body, "CONTENT_TYPE" => "application/json"))

    published = @driver.distributions.find { |path, _, _| path == "paquette.npm_server.publish_bytes" }
    assert published, "expected the published tarball size to be recorded"
    assert_operator published[1], :>, 0
  end

  # Measurometer wraps the block in a lambda per driver, and a `next` or a
  # `return` inside an instrumented block has to keep working across that.
  def test_an_instrumented_block_still_returns_its_own_value
    app = Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))
    status, _headers, body = app.call(Rack::MockRequest.env_for("/no-such-package"))

    assert_equal 404, status
    assert_equal "Package not found", JSON.parse(body.first)["error"]
  end

  private

  def counter_paths
    @driver.counters.map(&:first)
  end
end
