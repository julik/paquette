require_relative "test_helper"
require "rack/cache"
require "securerandom"

# The README tells embedders to put rack-cache (or Rails' Rack::Cache) in
# front of Paquette, with their own gate between the two. rack-cache is a
# shared cache keyed on the URL, and the embedder serves the same URL to a
# caller its gate lets through and to one it does not. The only thing
# keeping the second from being answered out of the first one's response is
# Paquette never saying `public`, which is the directive that overrides
# RFC 9111's rule that a response to an authorized request is not a shared
# cache's to store.
#
# This runs the real thing: an authorized download, then the same URL
# without credentials. The gate has to run the second time, and the cache
# must not have answered it.
class RackCacheTest < Minitest::Test
  PACKAGE = "widgets"

  def setup
    @npm_dir = Dir.mktmpdir("paquette_rack_cache_npm")
    write_npm_package(@npm_dir, name: PACKAGE, version: "1.0.0")
    @backend_calls = 0
  end

  def teardown
    FileUtils.rm_rf(@npm_dir)
  end

  def test_an_authorized_gem_download_is_not_replayed_to_an_anonymous_caller
    app = cached(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)))

    ["/gems/zip_kit-6.2.0.gem", "/versions", "/info/zip_kit", "/names"].each do |path|
      assert_not_replayed(app, path)
    end
  end

  def test_an_authorized_npm_tarball_is_not_replayed_to_an_anonymous_caller
    app = cached(Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@npm_dir)))

    ["/#{PACKAGE}/-/#{PACKAGE}-1.0.0.tgz", "/#{PACKAGE}", "/-/package/#{PACKAGE}/dist-tags"].each do |path|
      assert_not_replayed(app, path)
    end
  end

  private

  def assert_not_replayed(app, path)
    calls_before = @backend_calls

    status, headers, body = app.call(env_for(path, "HTTP_AUTHORIZATION" => "Bearer publisher"))
    body.close if body.respond_to?(:close)
    assert_equal 200, status, path
    refute_includes headers["x-rack-cache"].to_s, "store", "#{path} was stored by a shared cache"

    status, headers, body = app.call(env_for(path))
    body.close if body.respond_to?(:close)
    assert_equal 401, status, "#{path} was answered without the gate running"
    refute_includes headers["x-rack-cache"].to_s, "fresh", path
    assert_equal calls_before + 2, @backend_calls, "#{path} did not reach the backend both times"
  end

  # rack-cache, then the embedder's gate, then Paquette - the order the
  # README describes. Fresh heap stores per test, so no two tests share one.
  def cached(server)
    gate = lambda do |env|
      @backend_calls += 1
      next [401, {"content-type" => "text/plain"}, ["Unauthorized"]] unless env["HTTP_AUTHORIZATION"]

      server.call(env)
    end

    store = SecureRandom.hex(8)
    Rack::Cache.new(gate,
      metastore: "heap:/#{store}/meta",
      entitystore: "heap:/#{store}/body",
      verbose: false)
  end

  def env_for(path, env = {})
    Rack::MockRequest.env_for("http://registry.example.com#{path}", env)
  end
end
