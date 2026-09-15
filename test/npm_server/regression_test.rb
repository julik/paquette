require_relative "../test_helper"

# One test per defect found in review, each failing before its fix.
class NpmRegressionTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @dir = Dir.mktmpdir("paquette_npm_regression")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)
    @app = Paquette::NpmServer.new(@repository)
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  attr_reader :app

  # ASCII-8BIT README bytes made JSON.generate raise and the metadata endpoint 500.
  def test_a_non_utf8_readme_does_not_break_the_metadata_endpoint
    write_npm_package(@dir, name: "widgets", version: "1.0.0",
      files: {"README.md" => "# caf\xE8 \xFF\xFE\n".b})

    get "/widgets"
    assert_equal 200, last_response.status
    assert_kind_of String, JSON.parse(last_response.body)["readme"]
  end

  def test_a_non_ascii_description_survives
    write_npm_package(@dir, name: "widgets", version: "1.0.0", description: "Ünicode ✓ description")

    get "/widgets"
    assert_equal 200, last_response.status
    assert_equal "Ünicode ✓ description", JSON.parse(last_response.body)["description"]
  end

  # `npm owner add/rm` PUT no `versions` key; "keep nothing" unpublished everything.
  def test_a_document_put_without_versions_changes_nothing
    write_npm_package(@dir, name: "widgets", version: "1.0.0")
    write_npm_package(@dir, name: "widgets", version: "2.0.0")

    put "/widgets/-rev/1-abc",
      JSON.generate({"_id" => "widgets", "name" => "widgets", "maintainers" => [{"name" => "julik"}]}),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal 200, last_response.status
    assert_equal %w[1.0.0 2.0.0], @repository.versions_for_package("widgets")
    refute @repository.tomb_exists?("widgets", "1.0.0")
  end

  # A document that does carry versions still yanks the ones left out.
  def test_a_document_put_with_versions_still_yanks
    write_npm_package(@dir, name: "widgets", version: "1.0.0")
    write_npm_package(@dir, name: "widgets", version: "2.0.0")

    put "/widgets/-rev/1-abc",
      JSON.generate({"name" => "widgets", "versions" => {"1.0.0" => {}}}),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal %w[1.0.0], @repository.versions_for_package("widgets")
  end

  # Basename-keyed caching answered @alpha/util with @bravo/util's code.
  def test_two_scopes_sharing_a_basename_do_not_share_a_personalized_file
    write_npm_package(@dir, name: "@alpha/util", version: "1.0.0", files: {"index.js" => "ALPHA_SECRET\n"})
    write_npm_package(@dir, name: "@bravo/util", version: "1.0.0", files: {"index.js" => "BRAVO_SECRET\n"})

    # Equal mtimes: the rest of the old cache key was mtime and size.
    stamp = Time.at(1_000_000_000)
    ["@alpha", "@bravo"].each do |scope|
      File.utime(stamp, stamp, @repository.package_file_path("#{scope}/util", "1.0.0"))
    end

    personalizer = Paquette::NpmServer::Personalizer.new(@repository, license_key: "LIC")
    alpha = personalizer.package_file_path("@alpha/util", "1.0.0")
    bravo = personalizer.package_file_path("@bravo/util", "1.0.0")

    refute_equal alpha, bravo
    assert_equal "@bravo/util", JSON.parse(tarball_file(bravo, "package/package.json"))["name"]
    assert_equal "BRAVO_SECRET\n", tarball_file(bravo, "package/index.js")
    assert_equal "ALPHA_SECRET\n", tarball_file(alpha, "package/index.js")
  end

  # Byte-identical tarballs at identical mtimes; only the name differs.
  def test_the_personalized_cache_path_depends_on_the_full_package_name
    write_npm_package(@dir, name: "@alpha/util", version: "1.0.0")
    FileUtils.mkdir_p(File.join(@dir, "@bravo", "util"))
    FileUtils.cp(@repository.package_file_path("@alpha/util", "1.0.0"),
      File.join(@dir, "@bravo", "util", "util-1.0.0.tgz"))
    stamp = Time.at(1_000_000_000)
    ["@alpha", "@bravo"].each do |scope|
      File.utime(stamp, stamp, @repository.package_file_path("#{scope}/util", "1.0.0"))
    end

    personalizer = Paquette::NpmServer::Personalizer.new(@repository, license_key: "LIC")

    refute_equal personalizer.package_file_path("@alpha/util", "1.0.0"),
      personalizer.package_file_path("@bravo/util", "1.0.0")
  end

  # `npm dist-tag add pkg@1.0.0 latest` escaped as an exception, not a 400.
  def test_pointing_latest_elsewhere_is_refused_rather_than_raised
    write_npm_package(@dir, name: "widgets", version: "1.0.0")

    put "/-/package/widgets/dist-tags/latest", '"1.0.0"', {"CONTENT_TYPE" => "application/json"}
    assert_equal 400, last_response.status
    assert JSON.parse(last_response.body)["error"]
  end

  def test_a_dist_tag_for_an_unknown_version_is_refused
    write_npm_package(@dir, name: "widgets", version: "1.0.0")

    put "/-/package/widgets/dist-tags/beta", '"9.9.9"', {"CONTENT_TYPE" => "application/json"}
    assert_equal 404, last_response.status
  end

  # The one body reader that did not rewind after Rack consumed the body.
  def test_a_dist_tag_put_works_whatever_the_content_type
    write_npm_package(@dir, name: "widgets", version: "1.0.0")

    put "/-/package/widgets/dist-tags/beta", '"1.0.0"',
      {"CONTENT_TYPE" => "application/x-www-form-urlencoded"}

    assert_equal 200, last_response.status
    assert_equal "1.0.0", JSON.parse(last_response.body)["beta"]
  end

  # Storing npm's always-sent "latest" tag pinned it to the first publish.
  def test_publishing_does_not_pin_latest_to_the_first_version_published
    put "/widgets", npm_publish_body(name: "widgets", version: "1.0.0"), {"CONTENT_TYPE" => "application/json"}
    put "/widgets", npm_publish_body(name: "widgets", version: "2.0.0"), {"CONTENT_TYPE" => "application/json"}

    get "/-/package/widgets/dist-tags"
    assert_equal "2.0.0", JSON.parse(last_response.body)["latest"]
  end

  # created/modified describe the corpus, not what this caller may see.
  def test_gated_timestamps_do_not_describe_withheld_versions
    write_npm_package(@dir, name: "widgets", version: "1.0.0")
    write_npm_package(@dir, name: "widgets", version: "2.0.0")

    old = Time.utc(2001, 1, 1)
    recent = Time.utc(2020, 1, 1)
    File.utime(old, old, @repository.package_file_path("widgets", "1.0.0"))
    File.utime(recent, recent, @repository.package_file_path("widgets", "2.0.0"))

    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository) do |name:, version: nil|
      version.nil? || version == "1.0.0"
    end
    times = gated.package_metadata("widgets")["time"]

    assert_equal old.iso8601, times["created"]
    assert_equal old.iso8601, times["modified"]
    refute_includes times.values, recent.iso8601
  end

  # A leaner custom repository must be filtered, not crashed on.
  def test_gating_tolerates_a_document_without_versions_or_time
    lean = Class.new do
      def package_metadata(name) = {"name" => name}

      def versions_for_package(name) = ["1.0.0"]

      def dist_tags(name) = {}
    end

    gated = Paquette::NpmServer::ReadGatedRepository.new(lean.new) { |name:, version: nil| true }
    metadata = gated.package_metadata("widgets")

    assert_equal({}, metadata["versions"])
    assert_equal({}, metadata["time"])
  end

  # TarReader ignores PAX records, so a repack stored truncated filenames.
  def test_a_path_too_long_for_ustar_survives_a_repack
    long_name = "src/" + ("deeply-generated-component-name" * 4) + ".js"
    write_npm_package(@dir, name: "widgets", version: "1.0.0",
      files: {long_name => "// long\n"})

    assert_operator File.basename(long_name).bytesize, :>, 100

    personalizer = Paquette::NpmServer::Personalizer.new(@repository, license_key: "LIC")
    path = personalizer.package_file_path("widgets", "1.0.0")

    assert_equal "// long\n", tarball_file(path, "package/#{long_name}")
  end

  def test_system_tar_can_read_a_long_path_we_wrote
    skip "No tar available" if `which tar`.strip.empty?

    long_name = "src/" + ("deeply-generated-component-name" * 4) + ".js"
    write_npm_package(@dir, name: "widgets", version: "1.0.0", files: {long_name => "// long\n"})

    path = @repository.package_file_path("widgets", "1.0.0")
    listing = `tar tzf #{path}`

    assert_equal 0, $?.exitstatus
    assert_includes listing, long_name
  end

  # The app object is shared across threads; the request must not be stored on it.
  def test_concurrent_requests_do_not_share_request_state
    write_npm_package(@dir, name: "widgets", version: "1.0.0")

    hosts = %w[one.example.com two.example.com three.example.com four.example.com]
    results = hosts.map do |host|
      Thread.new do
        20.times.map do
          env = Rack::MockRequest.env_for("http://#{host}/widgets")
          _, _, body = @app.call(env)
          JSON.parse(body.to_a.join)["versions"]["1.0.0"]["dist"]["tarball"]
        end
      end
    end.flat_map(&:value)

    results.each do |tarball_url|
      assert_match %r{\Ahttp://(one|two|three|four)\.example\.com/widgets/-/widgets-1\.0\.0\.tgz\z}, tarball_url
    end

    hosts.each do |host|
      assert_includes results, "http://#{host}/widgets/-/widgets-1.0.0.tgz"
    end
  end
end
