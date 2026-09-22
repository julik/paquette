require_relative "../test_helper"

class NpmServerTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    @test_packages_dir = Dir.mktmpdir("paquette_npm_test")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@test_packages_dir)
    @app = Paquette::NpmServer.new(@repository)

    write_npm_package(@test_packages_dir, name: "test-package", version: "1.0.0")
    write_npm_package(@test_packages_dir, name: "test-package", version: "1.1.0",
      dependencies: {"left-pad" => "^1.3.0"}, bin: {"test-package" => "cli.js"})
    write_npm_package(@test_packages_dir, name: "another-package", version: "2.0.0")
    write_npm_package(@test_packages_dir, name: "@acme/widgets", version: "3.1.0")
  end

  def teardown
    FileUtils.rm_rf(@test_packages_dir) if @test_packages_dir
  end

  attr_reader :app

  def test_root_endpoint
    get "/"
    assert_equal 200, last_response.status
    assert_equal "text/html", last_response.content_type.split(";").first
    assert_includes last_response.body, Paquette::NpmServer::DEFAULT_BLURB
  end

  # A scanner sending a multipart Content-Type with no body: the client's
  # mistake, not ours, and it used to come back as a 500.
  def test_unparseable_request_body_is_a_bad_request
    status, _headers, body = app.call(malformed_multipart_env("/"))
    assert_equal 400, status
    assert_includes JSON.parse(body.first)["error"], "Could not parse request parameters"
  end

  def test_truncated_request_body_is_a_bad_request
    status, = app.call(malformed_multipart_env("/", body: "", content_length: "10"))
    assert_equal 400, status
  end

  def test_ping_endpoint
    get "/-/ping"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal({}, JSON.parse(last_response.body))
  end

  def test_whoami_endpoint
    get "/-/whoami"
    assert_equal 200, last_response.status
    assert_equal "paquette", JSON.parse(last_response.body)["username"]
  end

  def test_whoami_reports_the_authenticated_identity
    identity = Struct.new(:username).new("julik")
    get "/-/whoami", {}, {"paquette.identity" => identity}
    assert_equal "julik", JSON.parse(last_response.body)["username"]
  end

  def test_package_metadata
    get "/test-package"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    metadata = JSON.parse(last_response.body)
    assert_equal "test-package", metadata["name"]
    assert_equal %w[1.0.0 1.1.0], metadata["versions"].keys.sort
    assert_equal "1.1.0", metadata["dist-tags"]["latest"]
    assert metadata["time"].key?("1.0.0")
    assert metadata["time"].key?("created")
  end

  def test_package_metadata_nonexistent
    get "/nonexistent-package"
    assert_equal 404, last_response.status
    assert_equal "Package not found", JSON.parse(last_response.body)["error"]
  end

  def test_version_document_carries_the_real_package_json
    get "/test-package"
    version = JSON.parse(last_response.body)["versions"]["1.1.0"]

    assert_equal "test-package", version["name"]
    assert_equal "1.1.0", version["version"]
    assert_equal({"left-pad" => "^1.3.0"}, version["dependencies"])
    assert_equal({"test-package" => "cli.js"}, version["bin"])
    assert_equal "index.js", version["main"]
    assert_equal "test-package@1.1.0", version["_id"]
  end

  # npm checks these against the bytes it downloads.
  def test_dist_hashes_match_the_served_tarball
    get "/test-package"
    dist = JSON.parse(last_response.body)["versions"]["1.1.0"]["dist"]

    get "/test-package/-/test-package-1.1.0.tgz"
    assert_equal 200, last_response.status
    body = last_response.body

    assert_equal Digest::SHA1.hexdigest(body), dist["shasum"]
    assert_equal "sha512-" + [Digest::SHA512.digest(body)].pack("m0"), dist["integrity"]
  end

  def test_tarball_url_is_absolute_and_follows_the_registry_convention
    get "/test-package"
    dist = JSON.parse(last_response.body)["versions"]["1.1.0"]["dist"]

    assert_equal "http://example.org/test-package/-/test-package-1.1.0.tgz", dist["tarball"]
  end

  def test_tarball_url_honours_a_terminating_proxy
    get "/test-package", {}, {"HTTP_X_FORWARDED_PROTO" => "https", "HTTP_HOST" => "npm.example.com"}
    dist = JSON.parse(last_response.body)["versions"]["1.1.0"]["dist"]

    assert_equal "https://npm.example.com/test-package/-/test-package-1.1.0.tgz", dist["tarball"]
  end

  def test_metadata_is_stable_between_requests
    get "/test-package"
    first = last_response.body
    get "/test-package"

    assert_equal first, last_response.body
  end

  def test_dist_tags
    get "/-/package/test-package/dist-tags"
    assert_equal 200, last_response.status
    assert_equal "1.1.0", JSON.parse(last_response.body)["latest"]
  end

  def test_dist_tags_nonexistent
    get "/-/package/nonexistent-package/dist-tags"
    assert_equal 404, last_response.status
  end

  def test_package_download
    get "/test-package/-/test-package-1.0.0.tgz"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal last_response.body.bytesize.to_s, last_response.headers["Content-Length"]
  end

  # Old lockfiles record the pre-convention URL.
  def test_package_download_through_the_legacy_path
    get "/test-package/test-package-1.0.0.tgz"
    assert_equal 200, last_response.status
  end

  def test_package_download_nonexistent
    get "/test-package/-/test-package-999.0.0.tgz"
    assert_equal 404, last_response.status
  end

  def test_package_download_invalid_filename
    get "/test-package/-/invalid-filename.tgz"
    assert_equal 404, last_response.status
  end

  def test_multiple_packages
    get "/another-package"
    metadata = JSON.parse(last_response.body)
    assert_equal "another-package", metadata["name"]
    assert_equal "2.0.0", metadata["dist-tags"]["latest"]
  end

  def test_scoped_package_metadata_with_encoded_separator
    get "/@acme%2Fwidgets"
    assert_equal 200, last_response.status
    assert_equal "@acme/widgets", JSON.parse(last_response.body)["name"]
  end

  def test_scoped_package_metadata_with_plain_separator
    get "/@acme/widgets"
    assert_equal 200, last_response.status
    assert_equal "@acme/widgets", JSON.parse(last_response.body)["name"]
  end

  def test_scoped_tarball_url_and_download
    get "/@acme/widgets"
    dist = JSON.parse(last_response.body)["versions"]["3.1.0"]["dist"]
    assert_equal "http://example.org/@acme/widgets/-/widgets-3.1.0.tgz", dist["tarball"]

    get "/@acme/widgets/-/widgets-3.1.0.tgz"
    assert_equal 200, last_response.status
    assert_equal Digest::SHA1.hexdigest(last_response.body), dist["shasum"]
  end

  # npm appends ?write=true before a publish or unpublish.
  def test_unexpected_query_parameters_are_tolerated
    get "/test-package?write=true"
    assert_equal 200, last_response.status
  end

  def test_prerelease_does_not_become_latest
    write_npm_package(@test_packages_dir, name: "test-package", version: "2.0.0-beta.1")

    get "/-/package/test-package/dist-tags"
    assert_equal "1.1.0", JSON.parse(last_response.body)["latest"]

    get "/test-package"
    assert_includes JSON.parse(last_response.body)["versions"].keys, "2.0.0-beta.1"
  end

  def test_publish
    put "/new-package", npm_publish_body(name: "new-package", version: "1.0.0"),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal 201, last_response.status
    assert JSON.parse(last_response.body)["success"]

    get "/new-package"
    assert_equal 200, last_response.status
    assert_equal "1.0.0", JSON.parse(last_response.body)["dist-tags"]["latest"]
  end

  def test_publish_a_scoped_package
    put "/@acme%2Fgadget", npm_publish_body(name: "@acme/gadget", version: "1.0.0"),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal 201, last_response.status
    assert_path_exists File.join(@test_packages_dir, "@acme", "gadget", "gadget-1.0.0.tgz")
  end

  def test_publish_refuses_a_version_that_already_exists
    put "/test-package", npm_publish_body(name: "test-package", version: "1.0.0"),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal 409, last_response.status
  end

  def test_publish_rejects_a_payload_that_is_not_a_tarball
    body = JSON.generate({
      "name" => "junk",
      "_attachments" => {"junk-1.0.0.tgz" => {"data" => ["not a tarball"].pack("m0")}}
    })
    put "/junk", body, {"CONTENT_TYPE" => "application/json"}

    assert_equal 400, last_response.status
  end

  def test_publish_with_a_custom_dist_tag
    put "/tagged", npm_publish_body(name: "tagged", version: "1.0.0-beta.1", dist_tags: {"beta" => "1.0.0-beta.1"}),
      {"CONTENT_TYPE" => "application/json"}
    assert_equal 201, last_response.status

    get "/-/package/tagged/dist-tags"
    tags = JSON.parse(last_response.body)
    assert_equal "1.0.0-beta.1", tags["beta"]
  end

  # npm PUTs the document back without the version, then deletes the tarball.
  def test_unpublish_one_version
    put "/test-package/-rev/1-abc",
      JSON.generate({"name" => "test-package", "versions" => {"1.0.0" => {}}}),
      {"CONTENT_TYPE" => "application/json"}
    assert_equal 200, last_response.status

    delete "/test-package/-/test-package-1.1.0.tgz/-rev/1-abc"
    assert_equal 200, last_response.status

    get "/test-package"
    assert_equal %w[1.0.0], JSON.parse(last_response.body)["versions"].keys
  end

  def test_unpublish_everything
    delete "/test-package/-rev/1-abc"
    assert_equal 200, last_response.status

    get "/test-package"
    assert_equal 404, last_response.status
  end

  def test_an_unpublished_version_cannot_be_republished
    delete "/test-package/-rev/1-abc"

    put "/test-package", npm_publish_body(name: "test-package", version: "1.0.0"),
      {"CONTENT_TYPE" => "application/json"}

    assert_equal 403, last_response.status
  end

  # npm's unpublish flow reads _rev out of the document.
  def test_metadata_carries_a_revision
    get "/test-package"
    assert_match(/\A2-/, JSON.parse(last_response.body)["_rev"])
  end

  def test_writes_are_refused_through_a_read_gated_repository
    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository) { |name:, version: nil| true }
    @app = Paquette::NpmServer.new(gated)

    put "/new-package", npm_publish_body(name: "new-package", version: "1.0.0"),
      {"CONTENT_TYPE" => "application/json"}
    assert_equal 403, last_response.status

    delete "/test-package/-rev/1-abc"
    assert_equal 403, last_response.status
  end

  def test_a_directory_path_still_builds_a_server
    @app = Paquette::NpmServer.new(@test_packages_dir)

    get "/test-package"
    assert_equal 200, last_response.status
  end
end
