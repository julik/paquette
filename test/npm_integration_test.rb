require_relative "test_helper"

class NpmIntegrationTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    # Create a temporary directory for test packages
    @test_packages_dir = Dir.mktmpdir("paquette_npm_test")
    @app = Paquette::NpmServer.new(@test_packages_dir)

    # Create some test packages
    create_test_packages
  end

  def teardown
    FileUtils.rm_rf(@test_packages_dir) if @test_packages_dir
  end

  attr_reader :app

  def test_root_endpoint
    get "/"
    assert_equal 200, last_response.status
    assert_equal "Paquette NPM Repository", last_response.body
  end

  def test_ping_endpoint
    get "/-/ping"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    response = JSON.parse(last_response.body)
    assert_equal({}, response)
  end

  def test_whoami_endpoint
    get "/-/whoami"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    response = JSON.parse(last_response.body)
    assert_equal "paquette", response["username"]
  end

  def test_package_metadata
    get "/test-package"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    metadata = JSON.parse(last_response.body)
    assert_equal "test-package", metadata["name"]
    assert metadata["versions"].is_a?(Hash)
    assert metadata["versions"].key?("1.0.0")
    assert metadata["versions"].key?("1.1.0")
    assert_equal "1.1.0", metadata["dist-tags"]["latest"]
    assert metadata["time"].is_a?(Hash)
    assert metadata["time"].key?("1.0.0")
    assert metadata["time"].key?("1.1.0")
  end

  def test_package_metadata_nonexistent
    get "/nonexistent-package"
    assert_equal 404, last_response.status
  end

  def test_dist_tags
    get "/-/package/test-package/dist-tags"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dist_tags = JSON.parse(last_response.body)
    assert_equal "1.1.0", dist_tags["latest"]
  end

  def test_dist_tags_nonexistent
    get "/-/package/nonexistent-package/dist-tags"
    assert_equal 404, last_response.status
  end

  def test_package_download
    get "/test-package/test-package-1.0.0.tgz"
    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert last_response.body.length > 0
  end

  def test_package_download_nonexistent
    get "/test-package/test-package-999.0.0.tgz"
    assert_equal 404, last_response.status
  end

  def test_package_download_invalid_filename
    get "/test-package/invalid-filename.tgz"
    assert_equal 404, last_response.status
  end

  def test_multiple_packages
    get "/another-package"
    assert_equal 200, last_response.status

    metadata = JSON.parse(last_response.body)
    assert_equal "another-package", metadata["name"]
    assert metadata["versions"].key?("2.0.0")
    assert_equal "2.0.0", metadata["dist-tags"]["latest"]
  end

  def test_package_versions_structure
    get "/test-package"
    metadata = JSON.parse(last_response.body)

    # Check version structure
    version_1_0_0 = metadata["versions"]["1.0.0"]
    assert_equal "test-package", version_1_0_0["name"]
    assert_equal "1.0.0", version_1_0_0["version"]
    assert version_1_0_0["dist"].is_a?(Hash)
    assert_equal "test-package/test-package-1.0.0.tgz", version_1_0_0["dist"]["tarball"]

    version_1_1_0 = metadata["versions"]["1.1.0"]
    assert_equal "test-package", version_1_1_0["name"]
    assert_equal "1.1.0", version_1_1_0["version"]
    assert_equal "test-package/test-package-1.1.0.tgz", version_1_1_0["dist"]["tarball"]
  end

  private

  def create_test_packages
    # Create test-package with versions 1.0.0 and 1.1.0
    package_dir = File.join(@test_packages_dir, "test-package")
    FileUtils.mkdir_p(package_dir)

    # Create dummy .tgz files
    File.write(File.join(package_dir, "test-package-1.0.0.tgz"), "dummy tarball content 1.0.0")
    File.write(File.join(package_dir, "test-package-1.1.0.tgz"), "dummy tarball content 1.1.0")

    # Create another-package with version 2.0.0
    another_package_dir = File.join(@test_packages_dir, "another-package")
    FileUtils.mkdir_p(another_package_dir)
    File.write(File.join(another_package_dir, "another-package-2.0.0.tgz"), "dummy tarball content 2.0.0")
  end
end
