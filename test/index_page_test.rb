require_relative "test_helper"

class IndexPageTest < Minitest::Test
  include Rack::Test::Methods

  def test_renders_the_blurb_and_the_masthead
    page = Paquette::IndexPage.new("This server provides widgets.")
    status, headers, body = page.call({})

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers["Content-Type"]
    html = body.join
    assert_equal html.bytesize.to_s, headers["Content-Length"]
    assert_includes html, "This server provides widgets."
    assert_includes html, %(<svg class="masthead")
    refute_includes html, "<?xml"
  end

  def test_escapes_the_blurb_and_the_title
    page = Paquette::IndexPage.new(%(<script>alert("x")</script>), title: "a & b")
    html = page.render

    refute_includes html, "<script>alert"
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "<title>a &amp; b</title>"
  end

  # The version is the one thing deliberately absent: it names the exploits
  # that work here.
  def test_does_not_disclose_the_version
    html = Paquette::IndexPage.new("Hello.").render
    refute_includes html, Paquette::VERSION
  end

  # The plug: anything Rack-callable is a root, including a lambda.
  def test_servers_take_any_rack_app_as_their_index
    redirect = ->(_env) { [302, {"location" => "/docs"}, []] }

    [
      Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(FIXTURE_GEMS_DIR), index: redirect),
      Paquette::NpmServer.new(Paquette::NpmServer::DirectoryNpmRepository.new(FIXTURE_NPM_DIR), index: redirect)
    ].each do |server|
      status, headers, _ = server.call(Rack::MockRequest.env_for("http://example.com/"))
      assert_equal 302, status
      assert_equal "/docs", headers["location"]
    end
  end
end
