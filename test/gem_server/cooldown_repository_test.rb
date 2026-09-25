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
    assert_equal "---\naged_gem\n", last_response.body

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

    # A Gem::Version in the middle column, which is what rubygems.org's own
    # legacy index carries and what Gem::SpecFetcher sorts tuples by.
    get "/latest_specs.4.8"
    assert_equal [["aged_gem", Gem::Version.new("1.0.0"), "ruby"]], Marshal.load(last_response.body)

    get "/specs.4.8"
    assert_equal [["aged_gem", Gem::Version.new("1.0.0"), "ruby"]], Marshal.load(last_response.body)
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
      refute_nil etag, path

      status, _, body = next_week.call(Rack::MockRequest.env_for(path, "HTTP_IF_NONE_MATCH" => etag))
      assert_equal 200, status, path
      assert_includes body.to_a.join, newly_served, path
    end
  end

  # --- The validator ---

  # aged_gem 1.1.0 and brand_new_gem 0.1.0 are both dated the midnight
  # before NOW, so the next thing to cool does so at that midnight plus a
  # week - five and a half days after NOW.
  def next_crossing
    @repository.published_at("aged_gem", "1.1.0") + WEEK
  end

  def test_validator_is_stable_while_nothing_crosses_the_boundary
    validator = cooldown.cache_validator
    refute_nil validator

    assert_equal validator, cooldown(at: NOW + DAY).cache_validator
    assert_equal validator, cooldown(at: next_crossing - 1).cache_validator
  end

  def test_validator_changes_the_moment_a_version_cools
    refute_equal cooldown(at: next_crossing - 1).cache_validator, cooldown(at: next_crossing).cache_validator

    # And once it has, it holds still again until the next one.
    assert_equal cooldown(at: next_crossing).cache_validator, cooldown(at: next_crossing + DAY).cache_validator
  end

  def test_validator_differs_from_the_inner_one
    refute_equal @repository.cache_validator, cooldown.cache_validator
  end

  def test_validator_is_nil_when_the_inner_one_is
    keyless = Paquette::GemServer::ReadGatedRepository.new(@repository) { |name:, version: nil| true }
    assert_nil cooldown(keyless).cache_validator
  end

  def test_a_different_interval_gives_a_different_validator
    # Neither interval moves anything across the boundary relative to the
    # other, so only the interval itself can tell these two apart.
    refute_equal cooldown(interval: WEEK).cache_validator, cooldown(interval: WEEK + 1).cache_validator
  end

  def test_a_push_changes_the_validator
    repository = cooldown
    before = repository.cache_validator

    # Cooled long ago, and still it moves: the corpus did.
    build_gem("aged_gem", "0.9.0", date: NOW - (60 * DAY))
    refute_equal before, repository.cache_validator
  end

  def test_a_push_of_a_cooling_version_changes_the_validator
    repository = cooldown
    before = repository.cache_validator

    build_gem("aged_gem", "1.2.0", date: NOW)
    refute_equal before, repository.cache_validator
  end

  def test_a_yank_changes_the_validator
    repository = cooldown
    before = repository.cache_validator

    @repository.yank_gem("aged_gem", "1.0.0")
    refute_equal before, repository.cache_validator
  end

  def test_versions_with_no_known_publish_time_do_not_move_the_validator
    # brand_new_gem is undated; the rest cooled long ago. Nothing can cross
    # the boundary any more, however far the clock runs.
    source = ->(name:, version:) { (name == "brand_new_gem") ? nil : NOW - (60 * DAY) }
    at = ->(time) { cooldown(at: time, published_at: source, published_at_validator: -> { "v1" }).cache_validator }

    refute_nil at.call(NOW)
    assert_equal at.call(NOW), at.call(NOW + (1000 * DAY))
  end

  def test_a_custom_source_without_a_validator_emits_none
    repository = cooldown(published_at: ->(name:, version:) { NOW - (30 * DAY) })
    assert_nil repository.cache_validator

    @app = Paquette::GemServer.new(repository)
    get "/versions"
    assert_equal 200, last_response.status
    assert_nil last_response.headers["ETag"]
  end

  def test_a_custom_source_with_a_validator_emits_one_that_follows_it
    state = "v1"
    dates = {"1.0.0" => NOW - (30 * DAY), "1.1.0" => NOW - DAY}
    repository = cooldown(published_at: ->(name:, version:) { dates[version] }, published_at_validator: -> { state })

    first = repository.cache_validator
    refute_nil first
    assert_equal first, repository.cache_validator

    # The table changes and the corpus does not: 1.1.0 turns out to have
    # been published a month ago. The owner says so by moving the state.
    dates["1.1.0"] = NOW - (30 * DAY)
    state = "v2"
    refute_equal first, repository.cache_validator
    assert_equal ["1.0.0", "1.1.0"], repository.versions_for_gem("aged_gem")
  end

  def test_a_custom_source_validator_answering_nil_emits_none
    repository = cooldown(published_at: ->(name:, version:) { NOW }, published_at_validator: -> {})
    assert_nil repository.cache_validator
  end

  def test_a_source_validator_without_a_source_is_refused
    assert_raises(ArgumentError) { cooldown(published_at_validator: -> { "v1" }) }
  end

  def test_publish_times_are_walked_once_per_inner_validator
    counting = counting_repository(@repository)
    now = NOW
    repository = Paquette::GemServer::CooldownRepository.new(counting, interval: WEEK, clock: -> { now })

    repository.cache_validator
    assert_equal 3, counting.published_at_calls

    # Asked again, and across a boundary: the clock is not part of the key.
    repository.cache_validator
    now = next_crossing + DAY
    repository.cache_validator
    assert_equal 3, counting.published_at_calls

    # A push moves the inner validator, and the list is rebuilt once.
    build_gem("aged_gem", "0.9.0", date: NOW - (60 * DAY))
    repository.cache_validator
    repository.cache_validator
    assert_equal 3 + 4, counting.published_at_calls
  end

  def test_a_custom_source_is_walked_once_per_source_validator
    calls = 0
    state = "v1"
    source = ->(name:, version:) {
      calls += 1
      NOW - (30 * DAY)
    }
    repository = cooldown(published_at: source, published_at_validator: -> { state })

    2.times { repository.cache_validator }
    assert_equal 3, calls

    state = "v2"
    2.times { repository.cache_validator }
    assert_equal 6, calls
  end

  def test_concurrent_requests_walk_the_corpus_once
    counting = counting_repository(@repository)
    repository = cooldown(counting)

    validators = 8.times.map { Thread.new { repository.cache_validator } }.map(&:value)
    assert_equal 1, validators.uniq.length
    assert_equal 3, counting.published_at_calls
  end

  def test_conditional_get_across_a_cooling_boundary
    now = NOW
    repository = Paquette::GemServer::CooldownRepository.new(@repository, interval: WEEK, clock: -> { now })
    @app = Paquette::GemServer.new(repository)

    get "/info/aged_gem"
    etag = last_response.headers["ETag"]
    refute_nil etag
    refute_includes last_response.body, "1.1.0 "

    # A day on, nothing has crossed: the same ETag, and a 304.
    now = NOW + DAY
    get "/info/aged_gem", {}, {"HTTP_IF_NONE_MATCH" => etag}
    assert_equal 304, last_response.status
    assert_equal etag, last_response.headers["ETag"]

    # 1.1.0 cools. The ETag the client holds must not match any more, and
    # the body has to carry the version that just became servable.
    now = next_crossing
    get "/info/aged_gem", {}, {"HTTP_IF_NONE_MATCH" => etag}
    assert_equal 200, last_response.status
    assert_includes last_response.body, "1.1.0 "
    refute_equal etag, last_response.headers["ETag"]
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

  # Counts the published_at calls reaching the repository underneath, and
  # delegates everything else - cache_validator included.
  def counting_repository(repository)
    Class.new(SimpleDelegator) do
      attr_reader :published_at_calls

      def initialize(*)
        super
        @published_at_calls = 0
        @lock = Mutex.new
      end

      def published_at(gem_name, version)
        @lock.synchronize { @published_at_calls += 1 }
        __getobj__.published_at(gem_name, version)
      end
    end.new(repository)
  end

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
    # Past the format's "---" marker, which /names carries like every other
    # file in the compact index.
    assert_equal expect.keys.sort, last_response.body.split("\n").drop(1).reject(&:empty?).sort

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
