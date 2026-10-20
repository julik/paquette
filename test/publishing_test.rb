require_relative "test_helper"

class ReleaseDateTest < Minitest::Test
  TODAY = Date.new(2026, 10, 20)

  def test_a_recent_date_is_a_release_date
    assert_nil validate(Time.utc(2026, 5, 1))
    assert_nil validate(Time.utc(2024, 1, 1))
  end

  def test_the_placeholder_is_refused_with_the_way_out
    error = assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem) do
      validate(Time.at(315_619_200).utc)
    end
    assert_includes error.message, "SOURCE_DATE_EPOCH"
  end

  def test_dates_years_away_are_refused
    [Time.utc(2019, 1, 1), Time.utc(2035, 1, 1)].each do |date|
      assert_raises(Paquette::GemServer::DirectoryGemRepository::InvalidGem, date.to_s) { validate(date) }
    end
  end

  private

  def validate(date)
    spec = Gem::Specification.new do |s|
      s.name = "dated"
      s.version = "1.0.0"
      s.date = date
    end
    Paquette::GemServer::SpecValidator.validate_release_date!(spec, today: TODAY)
  end
end

class PublishHookGemTest < Minitest::Test
  MINUSCULE_FIXTURE = File.join(FIXTURE_GEMS_DIR, "minuscule_test", "minuscule_test-0.1.0.gem")

  def setup
    @dir = Dir.mktmpdir("paquette_publish_hook")
    @published = []
    @repository = Paquette::GemServer::DirectoryGemRepository.new(@dir, require_release_date: true)
    @app = Writable.gem_server(@repository, on_publish: ->(published, request) { @published << [published, request] })
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_push_is_reported_once_it_has_landed
    status, = push(File.binread(MINUSCULE_FIXTURE))

    assert_equal 200, status
    published, request = @published.fetch(0)
    assert_equal ["minuscule_test", "0.1.0"], [published.name, published.version]
    assert_equal Time.utc(2025, 10, 7), published.released_at
    assert_kind_of Rack::Request, request
    assert_equal ["minuscule_test"], @repository.gem_names
  end

  def test_a_refused_push_is_not_reported
    push(File.binread(MINUSCULE_FIXTURE))
    status, = push(File.binread(MINUSCULE_FIXTURE))

    assert_equal 409, status
    assert_equal 1, @published.length
  end

  def test_a_gem_dated_with_the_placeholder_is_refused_before_it_is_stored
    status, _, body = push(gem_dated(Time.at(315_619_200).utc))

    assert_equal 400, status
    assert_includes body.join, "SOURCE_DATE_EPOCH"
    assert_empty @repository.gem_names
    assert_empty @published
  end

  def test_without_the_option_any_date_goes
    lenient = Writable.gem_server(Paquette::GemServer::DirectoryGemRepository.new(@dir))
    env = Rack::MockRequest.env_for("/api/v1/gems", :method => "POST",
      :input => gem_dated(Time.at(315_619_200).utc), "CONTENT_TYPE" => "application/octet-stream")

    assert_equal 200, lenient.call(env)[0]
  end

  private

  def push(bytes)
    @app.call(Rack::MockRequest.env_for("/api/v1/gems", :method => "POST", :input => bytes,
      "CONTENT_TYPE" => "application/octet-stream"))
  end

  def gem_dated(date)
    Dir.mktmpdir("paquette_dated_gem") do |source|
      FileUtils.mkdir_p(File.join(source, "lib"))
      File.write(File.join(source, "lib", "dated.rb"), "module Dated; end\n")
      spec = Gem::Specification.new do |s|
        s.name = "dated"
        s.version = "1.0.0"
        s.summary = "Paquette release date fixture"
        s.authors = ["Paquette"]
        s.files = ["lib/dated.rb"]
        s.date = date
      end
      built = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
        Dir.chdir(source) { Gem::Package.build(spec) }
      end
      File.binread(File.join(source, built))
    end
  end
end

class PublishHookNpmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("paquette_publish_hook_npm")
    @published = []
    @app = Writable.npm_server(Paquette::NpmServer::DirectoryNpmRepository.new(@dir),
      on_publish: ->(published, request) { @published << [published, request] })
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # npm pack stamps 1985-10-26 on every entry, so arrival is the only date there is
  def test_a_publish_is_reported_with_its_arrival_as_its_date
    before = Time.now
    env = Rack::MockRequest.env_for("/gadget", :method => "PUT",
      :input => npm_publish_body(name: "gadget", version: "2.0.0"), "CONTENT_TYPE" => "application/json")

    assert_equal 201, @app.call(env)[0]
    published, request = @published.fetch(0)
    assert_equal ["gadget", "2.0.0"], [published.name, published.version]
    assert_operator published.released_at, :>=, before
    assert_kind_of Rack::Request, request
  end
end
