require_relative "../test_helper"

class PypiServerTest < Minitest::Test
  include Rack::Test::Methods

  PIP_ACCEPT = "application/vnd.pypi.simple.v1+json, application/vnd.pypi.simple.v1+html; q=0.1, text/html; q=0.01"

  def setup
    @dir = Dir.mktmpdir("paquette_pypi_server")
    @repository = Paquette::PypiServer::DirectoryPypiRepository.new(@dir)
    @app = Writable.pypi_server(@repository)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  attr_reader :app

  def test_the_root_is_the_index_page
    get "/"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Python packages"
  end

  def test_the_index_lists_projects_as_html_by_default
    write_wheel(@dir, name: "Acme.Widgets", version: "1.0.0")
    get "/simple/"

    assert_equal 200, last_response.status
    assert_equal "text/html; charset=utf-8", last_response.content_type
    assert_includes last_response.body, %(<a href="acme-widgets/">acme-widgets</a>)
  end

  def test_the_index_answers_pip_in_json
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    header "Accept", PIP_ACCEPT
    get "/simple/"

    assert_equal Paquette::PypiServer::JSON_TYPE, last_response.content_type
    document = JSON.parse(last_response.body)
    assert_equal "1.1", document["meta"]["api-version"]
    assert_equal [{"name" => "widgets"}], document["projects"]
  end

  def test_simple_without_a_slash_redirects
    get "/simple"

    assert_equal 301, last_response.status
    assert_equal "/simple/", last_response.headers["location"]
  end

  def test_a_project_page_links_every_file_with_its_hash
    wheel = write_wheel(@dir, name: "widgets", version: "1.0.0", requires_python: ">=3.8")
    sdist = write_sdist(@dir, name: "widgets", version: "1.0.0")
    get "/simple/widgets/"

    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, %(href="../../files/widgets/widgets-1.0.0-py3-none-any.whl#sha256=#{Digest::SHA256.file(wheel).hexdigest}")
    assert_includes body, %(href="../../files/widgets/widgets-1.0.0.tar.gz#sha256=#{Digest::SHA256.file(sdist).hexdigest}")
    assert_includes body, %(data-requires-python="&gt;=3.8")
    assert_includes body, %(<meta name="pypi:repository-version" content="1.1">)
  end

  def test_a_wheel_advertises_its_metadata_file_and_an_sdist_does_not
    wheel = write_wheel(@dir, name: "widgets", version: "1.0.0")
    write_sdist(@dir, name: "widgets", version: "1.0.0")
    header "Accept", Paquette::PypiServer::JSON_TYPE
    get "/simple/widgets/"

    files = JSON.parse(last_response.body)["files"].to_h { |file| [file["filename"], file] }
    metadata_hash = Digest::SHA256.hexdigest(wheel_file(wheel, "widgets-1.0.0.dist-info/METADATA"))
    assert_equal({"sha256" => metadata_hash}, files["widgets-1.0.0-py3-none-any.whl"]["core-metadata"])
    assert_equal({"sha256" => metadata_hash}, files["widgets-1.0.0-py3-none-any.whl"]["dist-info-metadata"])
    assert_equal false, files["widgets-1.0.0.tar.gz"]["core-metadata"]
  end

  def test_the_json_project_page_carries_versions_sizes_and_upload_times
    path = write_wheel(@dir, name: "widgets", version: "1.0.0")
    File.utime(Time.utc(2025, 3, 4, 5, 6, 7), Time.utc(2025, 3, 4, 5, 6, 7), path)
    write_wheel(@dir, name: "widgets", version: "2.0.0")
    header "Accept", Paquette::PypiServer::JSON_TYPE
    get "/simple/widgets/"

    document = JSON.parse(last_response.body)
    assert_equal ["1.0.0", "2.0.0"], document["versions"].sort
    file = document["files"].find { |candidate| candidate["filename"].start_with?("widgets-1.0.0") }
    assert_equal File.size(path), file["size"]
    assert_equal "2025-03-04T05:06:07.000000Z", file["upload-time"]
    assert_equal "../../files/widgets/widgets-1.0.0-py3-none-any.whl", file["url"]
  end

  def test_a_non_normalized_project_name_redirects_to_the_normalized_one
    write_wheel(@dir, name: "acme-widgets", version: "1.0.0")

    get "/simple/Acme_Widgets/"
    assert_equal 301, last_response.status
    assert_equal "/simple/acme-widgets/", last_response.headers["location"]

    get "/simple/acme-widgets"
    assert_equal 301, last_response.status
    assert_equal "/simple/acme-widgets/", last_response.headers["location"]
  end

  def test_an_unknown_project_is_a_404
    get "/simple/nothing-here/"

    assert_equal 404, last_response.status
  end

  def test_a_file_downloads_with_an_etag_naming_its_hash
    path = write_wheel(@dir, name: "widgets", version: "1.0.0")
    get "/files/widgets/widgets-1.0.0-py3-none-any.whl"

    assert_equal 200, last_response.status
    assert_equal File.binread(path), last_response.body
    etag = %("sha256-#{Digest::SHA256.file(path).hexdigest}")
    assert_equal etag, last_response.headers["etag"]

    header "If-None-Match", etag
    get "/files/widgets/widgets-1.0.0-py3-none-any.whl"
    assert_equal 304, last_response.status
  end

  def test_the_metadata_file_is_the_wheels_own_metadata
    path = write_wheel(@dir, name: "widgets", version: "1.0.0", requires_python: ">=3.9")
    get "/files/widgets/widgets-1.0.0-py3-none-any.whl.metadata"

    assert_equal 200, last_response.status
    assert_equal wheel_file(path, "widgets-1.0.0.dist-info/METADATA"), last_response.body
  end

  def test_an_sdist_has_no_metadata_file
    write_sdist(@dir, name: "widgets", version: "1.0.0")
    get "/files/widgets/widgets-1.0.0.tar.gz.metadata"

    assert_equal 404, last_response.status
  end

  def test_a_file_of_another_project_is_not_served_under_this_one
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    FileUtils.mkdir_p(File.join(@dir, "gadgets"))
    FileUtils.cp(File.join(@dir, "widgets", "widgets-1.0.0-py3-none-any.whl"), File.join(@dir, "gadgets"))

    get "/files/gadgets/widgets-1.0.0-py3-none-any.whl"
    assert_equal 404, last_response.status

    get "/simple/gadgets/"
    assert_equal 404, last_response.status
  end

  def test_a_path_traversal_in_the_filename_is_a_404
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    ["..%2F..%2Fetc%2Fpasswd", "widgets-1.0.0-py3-none-any.whl%2F..%2F..", "%2E%2E"].each do |segment|
      get "/files/widgets/#{segment}"
      assert_equal 404, last_response.status, segment
    end
  end

  def test_a_yanked_file_stays_downloadable_and_says_it_is_yanked
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    write_wheel(@dir, name: "widgets", version: "1.1.0")
    @repository.yank_file("widgets", "widgets-1.0.0-py3-none-any.whl", reason: "broken <build>")
    @repository.yank_file("widgets", "widgets-1.1.0-py3-none-any.whl")

    get "/simple/widgets/"
    assert_includes last_response.body, %(data-yanked="broken &lt;build&gt;")
    assert_includes last_response.body, %(data-yanked="")

    header "Accept", Paquette::PypiServer::JSON_TYPE
    get "/simple/widgets/"
    yanked = JSON.parse(last_response.body)["files"].to_h { |file| [file["filename"], file["yanked"]] }
    assert_equal "broken <build>", yanked["widgets-1.0.0-py3-none-any.whl"]
    assert_equal true, yanked["widgets-1.1.0-py3-none-any.whl"]

    get "/files/widgets/widgets-1.0.0-py3-none-any.whl"
    assert_equal 200, last_response.status
  end

  def test_a_yank_changes_the_project_pages_etag
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    get "/simple/widgets/"
    before = last_response.headers["etag"]

    @repository.yank_file("widgets", "widgets-1.0.0-py3-none-any.whl")
    get "/simple/widgets/"

    refute_nil before
    refute_equal before, last_response.headers["etag"]
  end

  def test_the_project_page_revalidates
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    get "/simple/widgets/"
    etag = last_response.headers["etag"]

    header "If-None-Match", etag
    get "/simple/widgets/"
    assert_equal 304, last_response.status
  end

  # The same URL answers in two formats, so a cache must not hand one to
  # a client that asked for the other
  def test_the_format_is_part_of_the_etag_and_of_vary
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    get "/simple/widgets/"
    html_etag = last_response.headers["etag"]

    header "Accept", Paquette::PypiServer::JSON_TYPE
    get "/simple/widgets/"

    refute_equal html_etag, last_response.headers["etag"]
    assert_includes last_response.headers["vary"], "Accept"
  end

  def test_negotiation_follows_the_q_values
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    {
      PIP_ACCEPT => Paquette::PypiServer::JSON_TYPE,
      "text/html, application/vnd.pypi.simple.v1+json;q=0.5" => "text/html; charset=utf-8",
      "application/vnd.pypi.simple.v1+html" => Paquette::PypiServer::HTML_TYPE,
      "application/vnd.pypi.simple.latest+json" => Paquette::PypiServer::JSON_TYPE,
      "*/*" => "text/html; charset=utf-8",
      "" => "text/html; charset=utf-8"
    }.each do |accept, expected|
      header "Accept", accept
      get "/simple/widgets/"
      assert_equal expected, last_response.content_type, accept
    end
  end

  def test_the_format_query_parameter_wins
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    header "Accept", "text/html"
    get "/simple/widgets/?format=#{Paquette::PypiServer::JSON_TYPE}"

    assert_equal Paquette::PypiServer::JSON_TYPE, last_response.content_type
  end

  def test_nothing_acceptable_is_a_406
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    header "Accept", "application/xml, application/vnd.pypi.simple.v1+json;q=0"
    get "/simple/widgets/"

    assert_equal 406, last_response.status
  end

  def test_an_absurd_accept_header_is_answered_promptly
    write_wheel(@dir, name: "widgets", version: "1.0.0")
    took = elapsed do
      ["," * 100_000, (";q=" * 30_000), ("text/html;" * 10_000), ("a" * 100_000)].each do |accept|
        header "Accept", accept
        get "/simple/widgets/"
        assert_equal 200, last_response.status
      end
    end

    assert took < 1.0, "negotiating took #{took}s"
  end

  def test_an_upload_lands
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl")

    assert_equal 200, last_response.status, last_response.body
    assert_path_exists File.join(@dir, "widgets", "widgets-1.0.0-py3-none-any.whl")
  end

  def test_an_upload_without_the_trailing_slash_lands
    upload(sdist_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0.tar.gz", path: "/legacy")

    assert_equal 200, last_response.status, last_response.body
  end

  def test_an_upload_of_an_existing_filename_is_a_conflict
    2.times { upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl") }

    assert_equal 409, last_response.status
  end

  def test_a_yanked_filename_cannot_be_uploaded_again
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl")
    @repository.yank_file("widgets", "widgets-1.0.0-py3-none-any.whl")
    upload(wheel_bytes(name: "widgets", version: "1.0.0", files: {"widgets/__init__.py" => "evil = 1\n"}),
      "widgets-1.0.0-py3-none-any.whl")

    assert_equal 409, last_response.status
  end

  def test_an_upload_whose_digest_does_not_match_is_refused
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl", sha256_digest: "0" * 64)

    assert_equal 400, last_response.status
    refute_path_exists File.join(@dir, "widgets")
  end

  # The filename is what the index serves it as, so it has to be the name
  # the metadata inside says
  def test_an_upload_whose_metadata_names_another_project_is_refused
    upload(wheel_bytes(name: "widgets", version: "1.0.0", metadata: core_metadata_text("requests", "1.0.0")),
      "widgets-1.0.0-py3-none-any.whl")

    assert_equal 400, last_response.status
    assert_includes last_response.body, "requests"
  end

  def test_an_upload_that_is_not_a_zip_is_refused
    upload("not a zip at all", "widgets-1.0.0-py3-none-any.whl")

    assert_equal 400, last_response.status
  end

  def test_an_upload_with_a_bad_filename_is_refused
    ["widgets.whl", "widgets-1.0.0.zip", "../widgets-1.0.0.tar.gz", "widgets-1.0.0-py3-none.whl", "-1.0.0.tar.gz"].each do |filename|
      upload(wheel_bytes(name: "widgets", version: "1.0.0"), filename)
      assert_equal 400, last_response.status, filename
    end
    assert_empty Dir.children(@dir)
  end

  # The filename comes out of the multipart body, which no route's encoding
  # check ever looked at
  def test_an_upload_filename_that_is_not_utf8_is_refused_rather_than_raised
    ["wid\xFFgets-1.0.0-py3-none-any.whl", "\xE2.whl", "widgets\xE2-1.0.0.tar.gz", "%E2-1.0.0.tar.gz"].each do |filename|
      upload(wheel_bytes(name: "widgets", version: "1.0.0"), filename.b)
      assert_equal 400, last_response.status, filename.inspect
    end
    assert_empty Dir.children(@dir)
  end

  def test_an_upload_with_another_action_is_refused
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl", ":action" => "submit")

    assert_equal 400, last_response.status
  end

  def test_an_upload_past_the_declared_cap_is_refused_before_it_is_read
    @app = Writable.pypi_server(@repository, max_push_bytes: 1024)
    upload(wheel_bytes(name: "widgets", version: "1.0.0", files: {"widgets/__init__.py" => Random.bytes(4096)}),
      "widgets-1.0.0-py3-none-any.whl")

    assert_equal 413, last_response.status
  end

  # A chunked upload says nothing about its length, so the cap has to hold
  # while the multipart parser is reading
  def test_an_upload_past_the_cap_with_no_length_is_cut_off
    server = Writable.pypi_server(@repository, max_push_bytes: 1024)
    body, content_type = multipart_body(wheel_bytes(name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => Random.bytes(4096)}), "widgets-1.0.0-py3-none-any.whl")
    env = Rack::MockRequest.env_for("/legacy/", :method => "POST", "CONTENT_TYPE" => content_type)
    env["rack.input"] = StringIO.new(body)
    env.delete("CONTENT_LENGTH")

    status, _, = server.call(env)
    assert_equal 413, status
    refute_path_exists File.join(@dir, "widgets")
  end

  # Who may write is the authenticator's to say, before any wrapper is asked
  def test_an_upload_through_a_gate_lands
    gated = Paquette::PypiServer::ReadGatedRepository.new(@repository) { |**| false }
    @app = Writable.pypi_server(gated)
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl")

    assert_equal 200, last_response.status, last_response.body
    assert_path_exists File.join(@dir, "widgets", "widgets-1.0.0-py3-none-any.whl")
  end

  def test_an_upload_is_reported_once_it_has_landed
    published = []
    @app = Writable.pypi_server(@repository, on_publish: ->(release, request) { published << [release, request] })
    upload(wheel_bytes(name: "Acme.Widgets", version: "1.0.0"), "acme_widgets-1.0.0-py3-none-any.whl")

    release, request = published.fetch(0)
    assert_equal ["acme-widgets", "1.0.0"], [release.name, release.version]
    assert_equal File.mtime(File.join(@dir, "acme-widgets", "acme_widgets-1.0.0-py3-none-any.whl")).utc, release.released_at
    assert_kind_of Rack::Request, request
  end

  def test_a_refused_upload_is_not_reported
    published = []
    @app = Writable.pypi_server(@repository, on_publish: ->(release, _) { published << release })
    2.times { upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl") }

    assert_equal 409, last_response.status
    assert_equal 1, published.length
  end

  def test_a_server_without_an_authenticator_refuses_uploads
    @app = Paquette::PypiServer.new(@repository)
    upload(wheel_bytes(name: "widgets", version: "1.0.0"), "widgets-1.0.0-py3-none-any.whl")

    assert_equal 401, last_response.status
  end

  def test_the_mount_is_kept_in_redirects
    mounted = Rack::Builder.new do
      map("/@acme") { run Paquette::PypiServer.new(Dir.mktmpdir) }
    end
    response = Rack::MockRequest.new(mounted).get("/@acme/simple/Acme_Widgets/")

    assert_equal 301, response.status
    assert_equal "/@acme/simple/acme-widgets/", response.headers["location"]
  end

  def test_route_for_names_the_route
    recognition = Paquette::PypiServer.route_for(Rack::MockRequest.env_for("/files/widgets/widgets-1.0.0.tar.gz"))

    assert_equal "GET /files/:project/:filename", recognition.name
    assert_equal({project: "widgets", filename: "widgets-1.0.0.tar.gz"}, recognition.params)
  end

  private

  def multipart_body(bytes, filename, **fields)
    boundary = "PaquetteBoundary#{SecureRandom.hex(8)}"
    form = {":action" => "file_upload", "protocol_version" => "1", "name" => "widgets", "version" => "1.0.0"}
      .merge(fields.transform_keys(&:to_s))
    body = +"".b
    form.each do |key, value|
      body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"
    end
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"content\"; filename=\"#{filename}\"\r\n"
    body << "Content-Type: application/octet-stream\r\n\r\n" << bytes.b << "\r\n--#{boundary}--\r\n"
    [body, "multipart/form-data; boundary=#{boundary}"]
  end

  def upload(bytes, filename, path: "/legacy/", **fields)
    body, content_type = multipart_body(bytes, filename, **fields)
    post path, body, "CONTENT_TYPE" => content_type
  end
end
