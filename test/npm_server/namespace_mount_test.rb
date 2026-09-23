require_relative "../test_helper"

# The npm twin of the gem server's namespace test. npm registries are mounted
# under a prefix the same way a gem.coop namespace is — the client is given a
# URL and appends to it — but with one difference that matters: a package
# document carries the tarball URL *inside it*, absolute. The gem index never
# says where a .gem lives, so a mount costs it nothing; here the server is the
# one writing the URL down, and it has to write the mount point into it.
class NpmNamespaceMountTest < Minitest::Test
  include Rack::Test::Methods

  NAMESPACE = "/@acme"

  def setup
    @packages_dir = Dir.mktmpdir("paquette_npm_namespace")
    repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    npm_server = Paquette::NpmServer.new(repository)

    write_npm_package(@packages_dir, name: "widgets", version: "1.0.0")
    write_npm_package(@packages_dir, name: "@scope/thing", version: "2.0.0")

    @app = Rack::Builder.new do
      map(NAMESPACE) { run npm_server }
      run ->(_env) { [404, {"Content-Type" => "text/plain"}, ["No namespace"]] }
    end.to_app
  end

  def teardown
    FileUtils.rm_rf(@packages_dir) if @packages_dir
  end

  attr_reader :app

  def test_package_metadata_is_served_under_the_namespace
    get "#{NAMESPACE}/widgets"

    assert_equal 200, last_response.status
    assert_equal "widgets", JSON.parse(last_response.body)["name"]
  end

  def test_tarball_urls_carry_the_mount_point
    get "#{NAMESPACE}/widgets"
    dist = JSON.parse(last_response.body).dig("versions", "1.0.0", "dist")

    assert_equal "http://example.org#{NAMESPACE}/widgets/-/widgets-1.0.0.tgz", dist["tarball"]
  end

  # The URL the document just handed out has to be a URL this registry
  # answers. Fetching it is the only way to know the two agree.
  def test_the_advertised_tarball_url_is_downloadable
    get "#{NAMESPACE}/widgets"
    tarball = JSON.parse(last_response.body).dig("versions", "1.0.0", "dist", "tarball")

    get URI(tarball).path

    assert_equal 200, last_response.status
    assert_equal "application/octet-stream", last_response.content_type
    assert_equal File.binread(File.join(@packages_dir, "widgets", "widgets-1.0.0.tgz")), last_response.body
  end

  def test_scoped_packages_keep_the_mount_point_too
    get "#{NAMESPACE}/@scope%2Fthing"
    dist = JSON.parse(last_response.body).dig("versions", "2.0.0", "dist")

    assert_equal "http://example.org#{NAMESPACE}/@scope/thing/-/thing-2.0.0.tgz", dist["tarball"]

    get URI(dist["tarball"]).path
    assert_equal 200, last_response.status
  end

  # A terminating proxy and a mount at once: the forwarded scheme and host
  # come from the headers, the prefix from SCRIPT_NAME.
  def test_a_proxy_and_a_mount_compose
    get "#{NAMESPACE}/widgets", {}, {"HTTP_X_FORWARDED_PROTO" => "https", "HTTP_X_FORWARDED_HOST" => "npm.example.com"}
    dist = JSON.parse(last_response.body).dig("versions", "1.0.0", "dist")

    assert_equal "https://npm.example.com#{NAMESPACE}/widgets/-/widgets-1.0.0.tgz", dist["tarball"]
  end

  def test_the_same_paths_outside_the_namespace_are_not_the_registry
    get "/widgets"

    assert_equal 404, last_response.status
    assert_equal "No namespace", last_response.body
  end
end
