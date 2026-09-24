require_relative "../test_helper"
require "rubygems/package"

class CooldownRepositoryTest < Minitest::Test
  include Rack::Test::Methods

  DAY = 24 * 60 * 60
  WEEK = 7 * DAY

  # The clock every test runs against. A fixed instant rather than
  # Time.now: the fixtures are dated relative to it, and a suite that
  # drifts over midnight would otherwise start disagreeing with itself.
  NOW = Time.utc(2025, 6, 15, 12, 0, 0)

  def setup
    @tmpdir = Dir.mktmpdir("paquette_cooldown")
    @gems_dir = File.join(@tmpdir, "gems")
    FileUtils.mkdir_p(@gems_dir)

    # aged: one version well past the week, one a day old.
    build_gem("aged_gem", "1.0.0", date: NOW - (30 * DAY))
    build_gem("aged_gem", "1.1.0", date: NOW - DAY)

    # Every version of this one is still cooling.
    build_gem("brand_new_gem", "0.1.0", date: NOW - DAY)

    @repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
  end

  # Rack::Test asks for this; the endpoint tests set @app first.
  attr_reader :app

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def cooldown(repository = @repository, interval: WEEK, at: NOW, **kwargs)
    Paquette::GemServer::CooldownRepository.new(repository, interval: interval, clock: -> { at }, **kwargs)
  end

  def test_versions_for_gem_drops_versions_still_cooling
    assert_equal ["1.0.0", "1.1.0"], @repository.versions_for_gem("aged_gem")
    assert_equal ["1.0.0"], cooldown.versions_for_gem("aged_gem")
  end

  def test_versions_for_gem_of_a_fully_cooling_gem_is_empty
    assert_equal [], cooldown.versions_for_gem("brand_new_gem")
  end

  def test_gem_versions_drops_versions_still_cooling
    assert_equal [["aged_gem", "1.0.0"]], cooldown.gem_versions
  end

  def test_gem_names_omits_a_gem_whose_every_version_is_cooling
    assert_equal ["aged_gem", "brand_new_gem"], @repository.gem_names
    assert_equal ["aged_gem"], cooldown.gem_names
  end

  def test_gem_names_keeps_a_gem_with_at_least_one_served_version
    # Nothing has cooled down yet at a month-long interval.
    # aged_gem 1.0.0 is dated 30 days before NOW and spec.date rounds the
    # date down to midnight, so its age at NOW is 30 days and a half.
    assert_equal [], cooldown(interval: 31 * DAY).gem_names
    assert_equal ["aged_gem"], cooldown(interval: 30 * DAY).gem_names
  end

  def test_compact_info_filters_per_line
    lines = cooldown.compact_info("aged_gem")
    assert_equal 1, lines.length
    assert_equal "1.0.0", lines.first.split(" ").first

    # Filtered per line and not by rewriting them: the surviving line is
    # byte for byte the one the wrapped repository rendered.
    assert_includes @repository.compact_info("aged_gem"), lines.first
  end

  def test_compact_info_of_a_fully_cooling_gem_is_empty
    assert_equal [], cooldown.compact_info("brand_new_gem")
  end

  def test_gem_exists_and_gem_file_path_refuse_a_cooling_version
    repository = cooldown

    assert repository.gem_exists?("aged_gem", "1.0.0")
    refute_nil repository.gem_file_path("aged_gem", "1.0.0")

    assert_equal false, repository.gem_exists?("aged_gem", "1.1.0")
    assert_nil repository.gem_file_path("aged_gem", "1.1.0")
  end

  def test_version_just_inside_and_just_outside_the_window
    published = @repository.published_at("aged_gem", "1.1.0")

    # spec.date is normalised to midnight UTC of the day it names, so the
    # published instant is asked for rather than assumed.
    one_second_short = cooldown(interval: WEEK, at: published + WEEK - 1)
    assert_equal ["1.0.0"], one_second_short.versions_for_gem("aged_gem")
    assert_equal false, one_second_short.gem_exists?("aged_gem", "1.1.0")

    just_past = cooldown(interval: WEEK, at: published + WEEK + 1)
    assert_includes just_past.versions_for_gem("aged_gem"), "1.1.0"
  end

  def test_boundary_is_exact_and_inclusive
    published = @repository.published_at("aged_gem", "1.1.0")

    # Exactly the interval old: served. The cooldown is the time you have
    # to wait, not a time you have to exceed.
    exactly = cooldown(interval: WEEK, at: published + WEEK)
    assert exactly.gem_exists?("aged_gem", "1.1.0")
    assert_includes exactly.versions_for_gem("aged_gem"), "1.1.0"
  end

  def test_zero_interval_serves_everything
    repository = cooldown(interval: 0)
    assert_equal ["1.0.0", "1.1.0"], repository.versions_for_gem("aged_gem")
    assert_equal ["aged_gem", "brand_new_gem"], repository.gem_names
  end

  def test_interval_accepts_anything_responding_to_to_i
    seconds = Struct.new(:to_i).new(WEEK)
    assert_equal ["1.0.0"], cooldown(interval: seconds).versions_for_gem("aged_gem")
  end

  def test_published_at_override_is_used_instead_of_the_spec_date
    # The override says 1.1.0 is ancient and 1.0.0 is brand new - the
    # opposite of what the gemspecs say, so a pass-through would show.
    dates = {"1.0.0" => NOW - DAY, "1.1.0" => NOW - (30 * DAY)}
    repository = cooldown(published_at: ->(name:, version:) { dates[version] })

    assert_equal ["1.1.0"], repository.versions_for_gem("aged_gem")
    assert_equal false, repository.gem_exists?("aged_gem", "1.0.0")
    assert repository.gem_exists?("aged_gem", "1.1.0")
  end

  def test_published_at_override_receives_name_and_version
    seen = []
    repository = cooldown(published_at: ->(name:, version:) {
      seen << [name, version]
      NOW - (30 * DAY)
    })
    repository.versions_for_gem("aged_gem")

    assert_equal [["aged_gem", "1.0.0"], ["aged_gem", "1.1.0"]], seen.sort
  end

  def test_nil_from_the_override_fails_open
    # An unknown publication date serves the version: a cooldown is a
    # delay policy, not an authorization boundary, and failing closed
    # would break installs over a missing timestamp.
    # An empty body, which is a lambda returning nil for every version.
    repository = cooldown(published_at: ->(name:, version:) {})

    assert_equal ["1.0.0", "1.1.0"], repository.versions_for_gem("aged_gem")
    assert_equal ["aged_gem", "brand_new_gem"], repository.gem_names
    assert repository.gem_exists?("brand_new_gem", "0.1.0")
  end

  def test_nil_for_one_version_only_fails_open_for_that_version
    repository = cooldown(published_at: ->(name:, version:) { (version == "1.1.0") ? nil : NOW })

    assert_equal ["1.1.0"], repository.versions_for_gem("aged_gem")
  end

  def test_published_at_comes_out_of_the_sidecar_once_it_is_written
    # Rendering the info file is what derives and writes a sidecar.
    @repository.compact_info("aged_gem")

    sidecar = sidecar_fields("aged_gem", "1.1.0")
    # spec.date is the midnight of the day the gemspec names.
    assert_equal Time.utc(2025, 6, 14).to_i, sidecar.fetch("published_at")
    assert_equal @repository.published_at("aged_gem", "1.1.0"), Time.at(sidecar.fetch("published_at")).utc
  end

  def test_published_at_survives_a_sidecar_written_before_the_key_existed
    @repository.compact_info("aged_gem")

    # An older Paquette's sidecar: every other field intact, no
    # published_at. It must be read, not discarded, and the date must
    # still be right.
    %w[1.0.0 1.1.0].each { |version| rewrite_sidecar(version) { |fields| fields.delete("published_at") } }

    assert_equal Time.utc(2025, 6, 14), @repository.published_at("aged_gem", "1.1.0")
    assert_equal ["1.0.0"], cooldown.versions_for_gem("aged_gem")

    # And the lines are still the ones the cache holds, not re-derived
    # into something different.
    lines = cooldown.compact_info("aged_gem")
    assert_equal 1, lines.length
    assert_match(/\Achecksum:[a-f0-9]{64}\z/, lines.first.split("|").last.split(",").first)
  end

  def test_published_at_is_nil_for_a_gem_that_is_not_there
    assert_nil @repository.published_at("aged_gem", "9.9.9")
    assert_nil @repository.published_at("no_such_gem", "1.0.0")
  end

  def test_writes_are_refused
    repository = cooldown

    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) { repository.add_gem("anything") }
    assert_raises(Paquette::GemServer::ReadonlyRepository::WriteNotAllowed) { repository.yank_gem("aged_gem", "1.0.0") }
  end

  def test_unfiltered_reads_still_delegate
    repository = cooldown

    spec = repository.gem_spec("aged_gem", "1.0.0")
    assert_equal "aged_gem", spec.name
    assert repository.gem_dependencies("aged_gem", "1.0.0").is_a?(Array)
  end

  def test_works_over_a_repository_without_published_at
    # A duck-typed repository from outside this gem need not implement
    # published_at; the wrapper falls back to reading the spec.
    bare = Class.new(SimpleDelegator) do
      def respond_to?(name, include_all = false)
        return false if name.to_sym == :published_at
        super
      end

      # Raises rather than answers: the wrapper must not call what the
      # repository does not advertise, and a fallback that happens to
      # produce the same answer would hide that.
      def published_at(*)
        raise "asked a repository that does not advertise published_at"
      end
    end.new(@repository)

    assert_equal ["1.0.0"], cooldown(bare).versions_for_gem("aged_gem")
  end

  # --- Endpoint-level: the index and the download path have to agree ---

  def test_served_index_and_downloads_agree
    @app = Paquette::GemServer.new(cooldown)

    get "/names"
    assert_equal "aged_gem", last_response.body.strip

    get "/info/aged_gem"
    assert_equal ["---", "1.0.0"], last_response.body.lines.map { |line| line.split(" ").first }

    get "/gems/aged_gem-1.0.0.gem"
    assert_equal 200, last_response.status

    get "/gems/aged_gem-1.1.0.gem"
    assert_equal 404, last_response.status

    # The cooling gem has no info file at all, and nothing to download.
    get "/info/brand_new_gem"
    assert_equal 404, last_response.status
    get "/gems/brand_new_gem-0.1.0.gem"
    assert_equal 404, last_response.status

    # /quick is gated by gem_exists?, so it follows.
    get "/quick/Marshal.4.8/aged_gem-1.1.0.gemspec.rz"
    assert_equal 404, last_response.status
  end

  def test_latest_specs_names_the_latest_served_version
    @app = Paquette::GemServer.new(cooldown)

    get "/latest_specs.4.8"
    assert_equal [["aged_gem", "1.0.0", "ruby"]], Marshal.load(last_response.body)

    get "/specs.4.8"
    assert_equal [["aged_gem", "1.0.0", "ruby"]], Marshal.load(last_response.body)
  end

  def test_versions_checksum_describes_the_info_file_that_is_served
    @app = Paquette::GemServer.new(cooldown)
    assert_versions_checksums_match
  end

  # The corpus does not change when a version comes out of cooldown - the
  # clock does. A validator passed through from the wrapped repository would
  # keep answering 304 to a client holding yesterday's index, and the
  # version that just became servable would reach nobody until somebody
  # happened to push something else.
  def test_a_version_coming_out_of_cooldown_is_not_hidden_behind_a_304
    # Two apps rather than @app reassigned: Rack::Test builds its session
    # around the first app it is handed and keeps it.
    today = Paquette::GemServer.new(cooldown)
    next_week = Paquette::GemServer.new(cooldown(at: NOW + WEEK))

    {
      "/names" => "brand_new_gem",
      "/versions" => "brand_new_gem 0.1.0",
      "/info/aged_gem" => "1.1.0 "
    }.each do |path, newly_served|
      etag = today.call(Rack::MockRequest.env_for(path))[1]["ETag"]

      status, _, body = next_week.call(Rack::MockRequest.env_for(path, "HTTP_IF_NONE_MATCH" => etag || "*"))
      assert_equal 200, status, path
      assert_includes body.to_a.join, newly_served, path
    end
  end

  # --- Stacking with the other wrappers, in both orders ---

  def test_stacks_with_read_gating_outside
    gated = Paquette::GemServer::ReadGatedRepository.new(cooldown) { |name:, version: nil| name == "aged_gem" }
    assert_stack_is_consistent(gated, expect: {"aged_gem" => ["1.0.0"]})
  end

  def test_stacks_with_read_gating_inside
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "aged_gem" }
    assert_stack_is_consistent(cooldown(gated), expect: {"aged_gem" => ["1.0.0"]})
  end

  def test_read_gating_and_cooldown_intersect_rather_than_override
    # Gating allows 1.1.0 only; cooldown withholds it. Nothing is left.
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository) do |name:, version: nil|
      name == "aged_gem" && (version.nil? || version == "1.1.0")
    end
    assert_stack_is_consistent(cooldown(gated), expect: {})
  end

  def test_stacks_with_personalizer_outside
    personalized = personalizer(cooldown)
    assert_stack_is_consistent(personalized, expect: {"aged_gem" => ["1.0.0"]})
  end

  def test_stacks_with_personalizer_inside
    assert_stack_is_consistent(cooldown(personalizer(@repository)), expect: {"aged_gem" => ["1.0.0"]})
  end

  def test_stacks_with_both_wrappers
    gated = Paquette::GemServer::ReadGatedRepository.new(@repository) { |name:, version: nil| true }
    assert_stack_is_consistent(personalizer(cooldown(gated)), expect: {"aged_gem" => ["1.0.0"]})
  end

  private

  def personalizer(repository)
    Paquette::GemServer::Personalizer.new(repository,
      license_key: "COOLDOWN-TEST",
      personalization_key: "cooldown-test",
      cache_dir: File.join(@tmpdir, "personalized"),
      magic_comment_replacements: {"# paquette_license_info" => "COOLDOWN-TEST"})
  end

  # Everything a client can ask this repository has to tell the same
  # story: the names, the info files, what downloads, and the /versions
  # checksums Bundler re-fetches on.
  def assert_stack_is_consistent(repository, expect:)
    @app = Paquette::GemServer.new(repository)

    get "/names"
    assert_equal expect.keys.sort, last_response.body.split("\n").reject(&:empty?).sort

    expect.each do |gem_name, versions|
      get "/info/#{gem_name}"
      assert_equal 200, last_response.status
      served = last_response.body.lines.drop(1).map { |line| line.split(" ").first }
      assert_equal versions, served

      versions.each do |version|
        get "/gems/#{gem_name}-#{version}.gem"
        assert_equal 200, last_response.status, "#{gem_name}-#{version} is in the index but does not download"
      end
    end

    # Anything the index left out must not download either.
    @repository.gem_versions.each do |gem_name, version|
      next if expect.fetch(gem_name, []).include?(version)

      get "/gems/#{gem_name}-#{version}.gem"
      assert_equal 404, last_response.status, "#{gem_name}-#{version} is not in the index but downloads"
    end

    assert_versions_checksums_match
  end

  # The third column of /versions is the MD5 of the gem's /info/ body. If
  # one wrapper filters compact_info and another does not, that checksum
  # stops describing what /info/ serves and Bundler loops re-fetching it.
  def assert_versions_checksums_match
    get "/versions"
    assert_equal 200, last_response.status

    rows = last_response.body.lines.drop_while { |line| line.strip != "---" }.drop(1)
    rows.each do |row|
      gem_name, versions, md5 = row.split(" ")
      get "/info/#{gem_name}"
      assert_equal 200, last_response.status, "#{gem_name} is listed in /versions but has no info file"
      assert_equal Digest::MD5.hexdigest(last_response.body), md5, "the /versions checksum for #{gem_name} does not describe its info file"

      served = last_response.body.lines.drop(1).map { |line| line.split(" ").first }
      assert_equal versions.split(","), served, "/versions lists versions #{gem_name}'s info file does not"
    end
  end

  def sidecar_path(gem_name, version)
    File.join(@gems_dir, gem_name, Paquette::GemServer::DirectoryGemRepository::CACHE_DIR_BASENAME, "#{gem_name}-#{version}.json")
  end

  def sidecar_fields(gem_name, version)
    JSON.parse(File.read(sidecar_path(gem_name, version)))
  end

  def rewrite_sidecar(version, gem_name: "aged_gem")
    path = sidecar_path(gem_name, version)
    fields = JSON.parse(File.read(path))
    yield(fields)
    File.write(path, JSON.pretty_generate(fields))
  end

  def build_gem(name, version, date:)
    source_dir = File.join(@tmpdir, "src", "#{name}-#{version}")
    FileUtils.mkdir_p(File.join(source_dir, "lib"))
    File.write(File.join(source_dir, "lib", "#{name}.rb"), "# paquette_license_info\nmodule #{name.split("_").map(&:capitalize).join}; end\n")

    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = version
      s.summary = "Paquette cooldown fixture"
      s.authors = ["Paquette"]
      s.files = ["lib/#{name}.rb"]
      s.require_paths = ["lib"]
      s.date = date
    end

    built = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Dir.chdir(source_dir) { Gem::Package.build(spec) }
    end

    FileUtils.mkdir_p(File.join(@gems_dir, name))
    FileUtils.mv(File.join(source_dir, built), File.join(@gems_dir, name, "#{name}-#{version}.gem"))
  end
end
