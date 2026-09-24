require_relative "test_helper"
require "rack/cache"
require "securerandom"

# rack-cache (or Rails' Rack::Cache) in front of Paquette, with the
# embedder's gate between the two. rack-cache is a shared cache keyed on the
# URL, and the embedder serves the same URL to a caller its gate lets
# through and to one it does not. The only thing keeping the second from
# being answered out of the first one's response is Paquette never saying
# `public` to a request that carried a credential - `public` is the
# directive that overrides RFC 9111's rule that a response to an authorized
# request is not a shared cache's to store.
#
# The first tests run the real thing: an authorized download, then the same
# URL without credentials. The gate has to run the second time, and the
# cache must not have answered it. The rest show the other side - an open
# registry, asked anonymously, is what a shared cache is for.
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

  # The other half: an open registry - no credential, nothing gated - is
  # what `public` is for, and a shared cache in front should get to keep it.
  def test_an_anonymous_download_over_an_open_registry_is_kept
    gems = cached(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)), open: true)
    npm = cached(Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@npm_dir)), open: true)

    [[gems, "/gems/zip_kit-6.2.0.gem"], [npm, "/#{PACKAGE}/-/#{PACKAGE}-1.0.0.tgz"]].each do |app, path|
      first = request(app, path)
      assert_equal 200, first[0], path
      assert_includes first[1]["x-rack-cache"], "store", path

      calls_before = @backend_calls
      second = request(app, path)
      assert_equal 200, second[0], path
      assert_includes second[1]["x-rack-cache"], "fresh", path
      assert_equal calls_before, @backend_calls, "#{path} should have been answered by the cache"
    end
  end

  # An index document is `no-cache`: kept, but revalidated on every use,
  # which the server answers with a 304 off the corpus fingerprint.
  def test_an_anonymous_index_over_an_open_registry_is_kept_and_revalidated
    gems = cached(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)), open: true)
    npm = cached(Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@npm_dir)), open: true)

    [[gems, "/versions"], [npm, "/#{PACKAGE}"]].each do |app, path|
      first = request(app, path)
      assert_includes first[1]["x-rack-cache"], "store", path

      second = request(app, path)
      assert_equal 200, second[0], path
      assert_includes second[1]["x-rack-cache"], "valid", path
      assert_equal first[2], second[2], path
    end
  end

  # A copy stored for an anonymous caller must not answer a caller holding
  # a credential, who may be entitled to a different view of the same URL.
  # What keeps it from doing so in Rack::Cache is Vary: its lookup ignores
  # whether a request is private and matches stored entries on the Vary
  # headers alone - see the next test.
  def test_an_anonymous_copy_is_not_handed_to_an_authorized_caller
    gems = cached(Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR)), open: true)
    npm = cached(Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(@npm_dir)), open: true)

    [[gems, "/gems/zip_kit-6.2.0.gem"], [npm, "/#{PACKAGE}/-/#{PACKAGE}-1.0.0.tgz"]].each do |app, path|
      assert_includes request(app, path)[1]["x-rack-cache"], "store", path

      ["Bearer publisher", nil].each do |authorization|
        env = authorization ? {"HTTP_AUTHORIZATION" => authorization} : {"HTTP_COOKIE" => "session=abc"}
        calls_before = @backend_calls
        response = request(app, path, env)

        assert_equal 200, response[0], path
        refute_includes response[1]["x-rack-cache"], "fresh", "#{path} #{env.keys.first}"
        assert_equal calls_before + 1, @backend_calls, "#{path} #{env.keys.first} did not reach the backend"
        # Rack::Cache reorders the directives on the way through.
        assert_includes response[1]["cache-control"], "private", path
        refute_includes response[1]["cache-control"], "public", path
      end
    end
  end

  # The control for the test above, so that it cannot pass by accident:
  # with Vary stripped off the very same responses, Rack::Cache does hand
  # the anonymous copy to an authorized caller. This is also what a CDN
  # that ignores Vary does - which is why nothing a credentialed request is
  # answered with is ever `public`.
  def test_without_vary_rack_cache_would_hand_the_anonymous_copy_over
    server = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR))
    without_vary = lambda do |env|
      status, headers, body = server.call(env)
      headers = Rack::Headers[headers]
      headers.delete("vary")
      [status, headers, body]
    end
    app = cached(without_vary, open: true)

    request(app, "/gems/zip_kit-6.2.0.gem")
    response = request(app, "/gems/zip_kit-6.2.0.gem", "HTTP_AUTHORIZATION" => "Bearer publisher")
    assert_includes response[1]["x-rack-cache"], "fresh"
  end

  private

  def request(app, path, env = {})
    status, headers, body = app.call(env_for(path, env))
    buffer = +""
    body.each { |chunk| buffer << chunk }
    body.close if body.respond_to?(:close)
    [status, headers, buffer]
  end

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
  # README describes. `open: true` is a registry with no gate at all.
  # Fresh heap stores per call, so no two tests share one.
  def cached(server, open: false)
    gate = lambda do |env|
      @backend_calls += 1
      next [401, {"content-type" => "text/plain"}, ["Unauthorized"]] unless open || env["HTTP_AUTHORIZATION"]

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
