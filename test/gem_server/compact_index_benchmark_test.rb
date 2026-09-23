require_relative "../test_helper"
require "rubygems/package"
require "rubygems/user_interaction"
require "digest"
require "json"

# A compact index over a personalized repository, at the size a real corpus
# reaches.
#
# /versions publishes the MD5 of each gem's /info/ file, and under a
# Personalizer an /info/ file carries the licensee's own gem checksums — so
# rendering one means knowing the SHA256 of the personalized gem for every
# version of every gem the caller can see. That is the most expensive thing
# this library does per request, it is the thing a corpus makes worse, and a
# two-version fixture cannot show it: what broke in production was 200
# versions on a cold cache, which is what this builds.
#
# This is a benchmark and a correctness test at once, and the correctness half
# is the more important one. A fast /versions that publishes a checksum for
# bytes nobody receives is worse than a slow one, because `bundle install`
# reports it as a tampered gem.
class CompactIndexBenchmarkTest < Minitest::Test
  # Split the way the corpus this was written for splits: a gem that ships an
  # agreement and is therefore repacked per licensee, and one that ships none
  # and is served byte for byte. Both walk the whole version list on every
  # /versions; only one of them repacks, and a regression in either path shows
  # up as the other's cost.
  PERSONALIZED_GEM = "bench_personalized"
  PLAIN_GEM = "bench_plain"
  VERSIONS_PER_GEM = 100

  LICENSE_FILE = "LICENSE-COMMERCIAL.txt"

  # Generous on purpose. The number that matters is the shape: repacking
  # in-process costs tens of milliseconds a gem, and shelling out to
  # `gem unpack` and `gem build` cost about half a second each — so a
  # regression to subprocesses puts 200 versions near two minutes and lands
  # nowhere near this, while a slow CI box stays comfortably inside it.
  COLD_BUDGET_SECONDS = 30

  class RecordingDriver
    attr_reader :counters

    def initialize
      @counters = Hash.new(0)
    end

    def instrument(name)
      yield
    end

    def increment_counter(path, by = 1, tags = {})
      @counters[path] += by
    end

    def add_distribution_value(path, value, tags = {})
    end

    def set_gauge(name, value, tags = {})
    end
  end

  def setup
    @driver = RecordingDriver.new
    Measurometer.drivers << @driver

    @gems_dir = Dir.mktmpdir("paquette_bench_gems")
    @cache_dir = Dir.mktmpdir("paquette_bench_cache")

    building = elapsed do
      1.upto(VERSIONS_PER_GEM) do |n|
        write_dummy_gem(PERSONALIZED_GEM, "0.#{n}.0", files: {LICENSE_FILE => "The agreement, as shipped.\n"})
        write_dummy_gem(PLAIN_GEM, "0.#{n}.0")
      end
    end
    report("built #{2 * VERSIONS_PER_GEM} gems", building)
  end

  def teardown
    Measurometer.drivers.delete(@driver)
    FileUtils.remove_entry(@gems_dir) if @gems_dir
    FileUtils.remove_entry(@cache_dir) if @cache_dir
  end

  def test_a_personalized_compact_index_over_two_hundred_versions
    cold = elapsed { @cold_response = get("/versions") }
    report("cold /versions", cold)

    assert_equal 200, @cold_response[0]
    assert_operator cold, :<, COLD_BUDGET_SECONDS,
      "a cold /versions over #{2 * VERSIONS_PER_GEM} versions took #{cold.round(1)}s"

    # Every version of both gems is listed, or the index is not what is being
    # measured.
    listed = versions_lines(@cold_response)
    assert_equal VERSIONS_PER_GEM, listed.fetch(PERSONALIZED_GEM).length
    assert_equal VERSIONS_PER_GEM, listed.fetch(PLAIN_GEM).length

    # The gem that ships an agreement was repacked once per version, the one
    # that does not was not repacked at all.
    assert_equal VERSIONS_PER_GEM, @driver.counters["paquette.gem_personalizer.cache_miss"]

    warm = elapsed { @warm_response = get("/versions") }
    report("warm /versions", warm)

    assert_equal 200, @warm_response[0]
    assert_equal body_of(@cold_response).sub(/\Acreated_at:.*\n/, ""),
      body_of(@warm_response).sub(/\Acreated_at:.*\n/, ""),
      "the same corpus and the same licensee must give the same index"

    # Nothing was repacked and nothing was hashed the second time round: the
    # personalized gems were already on disk and their checksums beside them.
    # This is the assertion that the caches are doing their job — a timing
    # comparison would say the same thing and say it flakily.
    assert_equal VERSIONS_PER_GEM, @driver.counters["paquette.gem_personalizer.cache_miss"],
      "a warm /versions repacked something"
    assert_equal VERSIONS_PER_GEM, @driver.counters["paquette.gem_personalizer.cache_hit"]
    assert_equal VERSIONS_PER_GEM, @driver.counters["paquette.gem_personalizer.checksum_hit"]
  end

  # The point of the whole exercise. Every checksum the index publishes has to
  # be the checksum of the file the client will actually be handed, for both
  # the repacked gem and the one that passes through.
  def test_every_published_checksum_describes_the_gem_that_is_served
    [PERSONALIZED_GEM, PLAIN_GEM].each do |gem_name|
      info = get("/info/#{gem_name}")
      assert_equal 200, info[0], "no /info/ for #{gem_name}"

      published = info_checksums(body_of(info))
      assert_equal VERSIONS_PER_GEM, published.length

      published.each do |version, checksum|
        served = get("/gems/#{gem_name}-#{version}.gem")
        assert_equal 200, served[0], "no gem for #{gem_name} #{version}"
        assert_equal checksum, Digest::SHA256.hexdigest(body_of(served)),
          "#{gem_name} #{version}: /info/ publishes a checksum for bytes nobody receives"
      end
    end
  end

  private

  def server
    repository = Paquette::GemServer::DirectoryGemRepository.new(@gems_dir)
    personalized = Paquette::GemServer::Personalizer.new(repository,
      license_key: "BENCH-1",
      personalization_key: "Licensee One\nBENCH-1",
      files_for: ->(gem_name, _version, gem_path) { agreement_files(gem_name, gem_path) },
      cache_dir: @cache_dir)

    Paquette::GemServer.new(personalized)
  end

  def get(path)
    server.call(Rack::MockRequest.env_for(path))
  end

  def body_of(response)
    buffer = +""
    response[2].each { |chunk| buffer << chunk }
    buffer
  end

  # The shop's own rule, and the shape that matters here: a gem that ships no
  # agreement returns nil and is served as it sits on disk. Asking the spec
  # rather than unpacking the gem is the whole difference between this costing
  # a millisecond and costing a tenth of a second per version.
  def agreement_files(gem_name, gem_path)
    spec = Gem::Package.new(gem_path).spec
    return nil unless spec.files.include?(LICENSE_FILE)

    {LICENSE_FILE => "Licensed to Licensee One.\n\nThe agreement, as shipped.\n"}
  end

  # {"gem_name" => ["0.1.0", ...]} out of a /versions body.
  def versions_lines(response)
    body_of(response).split("\n").drop_while { |line| line != "---" }.drop(1).to_h do |line|
      name, versions, _checksum = line.split(" ")
      [name, versions.split(",")]
    end
  end

  # {"0.1.0" => "<sha256>"} out of an /info/ body. The checksum is the value of
  # the `checksum:` field in the requirement column.
  def info_checksums(body)
    body.split("\n").drop_while { |line| line != "---" }.drop(1).to_h do |line|
      version = line.split(" ", 2).first
      checksum = line[/checksum:([0-9a-f]{64})/, 1]
      refute_nil checksum, "no checksum in info line: #{line.inspect}"
      [version, checksum]
    end
  end

  # A .gem on disk in the layout DirectoryGemRepository expects. Built with
  # RubyGems directly, from a working directory of its own, so the fixtures do
  # not depend on the repacking this test is measuring.
  def write_dummy_gem(name, version, files: {})
    contents = {
      "lib/#{name}.rb" => "module #{name.split("_").map(&:capitalize).join}\n  VERSION = #{version.inspect}\nend\n",
      "README.md" => "# #{name} #{version}\n"
    }.merge(files)

    gem_dir = File.join(@gems_dir, name)
    FileUtils.mkdir_p(gem_dir)

    Dir.mktmpdir("paquette_bench_build") do |workdir|
      contents.each do |path, content|
        FileUtils.mkdir_p(File.join(workdir, File.dirname(path)))
        File.write(File.join(workdir, path), content)
      end

      spec = Gem::Specification.new do |s|
        s.name = name
        s.version = version
        s.summary = "A gem for measuring compact index rendering"
        s.authors = ["Paquette"]
        s.files = contents.keys
        s.require_paths = ["lib"]
        # Fixed, so a rebuilt fixture is the same gem and the repacker's
        # SOURCE_DATE_EPOCH has something stable to pin to.
        s.date = Time.utc(2020, 1, 1)
      end

      built = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
        Dir.chdir(workdir) { Gem::Package.build(spec) }
      end
      FileUtils.mv(File.join(workdir, built), File.join(gem_dir, "#{name}-#{version}.gem"))
    end
  end

  def report(what, seconds)
    return if ENV["QUIET_BENCH"]

    warn format("  [compact index bench] %-28s %8.2fs", what, seconds)
  end
end
