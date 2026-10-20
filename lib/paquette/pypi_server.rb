require "json"
require "cgi"
require "erb"
require "measurometer"

# Rack app serving a Python package index - the Simple API of PEP 503 and
# PEP 691, with PEP 658 metadata files, PEP 592 yanks and PEP 700 upload
# times - plus the upload endpoint twine speaks, over any PypiRepository stack.
class Paquette::PypiServer
  autoload :CooldownRepository, "#{__dir__}/pypi_server/cooldown_repository"
  autoload :DirectoryPypiRepository, "#{__dir__}/pypi_server/directory_pypi_repository"
  autoload :Personalizer, "#{__dir__}/pypi_server/personalizer"
  autoload :PypiRepository, "#{__dir__}/pypi_server/pypi_repository"
  autoload :ReadGatedRepository, "#{__dir__}/pypi_server/read_gated_repository"

  prepend Paquette::RegexpTimeout
  include Paquette::ConditionalGet
  include Paquette::Authentication

  # An upload body past `max_push_bytes:`, answered 413 - from inside the
  # multipart parse if it has to be, which is where the bytes get read.
  class PayloadTooLarge < StandardError; end

  JSON_TYPE = "application/vnd.pypi.simple.v1+json"
  HTML_TYPE = "application/vnd.pypi.simple.v1+html"
  TEXT_HTML_TYPE = "text/html"

  # The media types PEP 691 names, and the format each one is. "latest"
  # is v1 for as long as v1 is all there is.
  MEDIA_TYPES = {
    JSON_TYPE => [:json, JSON_TYPE],
    "application/vnd.pypi.simple.latest+json" => [:json, JSON_TYPE],
    HTML_TYPE => [:html, HTML_TYPE],
    "application/vnd.pypi.simple.latest+html" => [:html, HTML_TYPE],
    TEXT_HTML_TYPE => [:html, "text/html; charset=utf-8"]
  }.freeze #: Hash[String, [Symbol, String]]

  # pip sends three media types; anything much longer is not a client
  # negotiating, and is read as no preference at all.
  MAX_ACCEPT_BYTES = 1024

  API_VERSION = "1.1"

  # The core metadata file of PEP 658 is the distribution's URL plus this
  METADATA_SUFFIX = ".metadata"

  @@routes = Paquette::Routes.draw do |r| #$ Paquette::PypiServer
    r.get "/" do
      @placeholder_app.call(@request.env)
    end

    r.get "/simple" do
      redirect("/simple/")
    end

    r.get "/simple/" do
      handle_index
    end

    r.get "/simple/:project/" do |project:|
      handle_project(project)
    end

    # PEP 503 asks for the slash to be added rather than the page served twice
    r.get "/simple/:project" do |project:|
      normalized = Paquette::PypiServer::PypiRepository.normalize_name(project)
      next not_found("Project not found") unless normalized

      redirect("/simple/#{normalized}/")
    end

    r.get "/files/:project/:filename" do |project:, filename:|
      handle_file(project, filename)
    end

    # The field names twine sends (":action", "protocol_version") are not
    # Ruby keywords, so the block takes the whole lot.
    r.post "/legacy/" do |**params|
      handle_upload(params)
    end

    r.post "/legacy" do |**params|
      handle_upload(params)
    end
  end

  # What a request would dispatch to, without dispatching it - the twin of
  # GemServer.route_for. Only the path is read.
  #
  #: (Paquette::rack_env env) -> Paquette::Routes::Recognition?
  def self.route_for(env)
    @@routes.recognize(Rack::Request.new(env))
  rescue Paquette::Routes::BadRequest
    nil
  end

  DEFAULT_BLURB = "This server provides Python packages. Point pip at /simple/ and install as usual."

  # - `repository`: the repository stack to serve, or a directory path to wrap
  #   in a DirectoryPypiRepository
  # - `placeholder_app`: the Rack app answering the root path
  # - `max_push_bytes`: the largest upload body this server will read; nil
  #   removes the cap
  # - `shared_caching`: false keeps every response `private` - see the same
  #   option on GemServer
  # - `authenticator`: answers `read_permitted?`, `write_permitted?` and
  #   `check_otp!` - see Paquette::Authentication. Without one, everyone reads
  #   and nobody writes
  # - `on_publish`: called with a Paquette::Published and the Rack::Request
  #   once an upload has landed - see the same option on GemServer
  #
  #: ((Paquette::PypiServer::PypiRepository | String) repository, ?placeholder_app: Paquette::_RackApp, ?max_push_bytes: Integer?, ?shared_caching: bool, ?authenticator: Paquette::Authentication::_Authenticator?, ?on_publish: (^(Paquette::Published, ::Rack::Request) -> void)?) -> void
  def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette Python package index"),
    max_push_bytes: Paquette::MAX_PUSH_SIZE_BYTES, shared_caching: true, authenticator: nil, on_publish: nil)
    @on_publish = on_publish
    @repository = if repository.is_a?(String)
      DirectoryPypiRepository.new(repository)
    else
      repository
    end
    setup_authentication(authenticator)
    @placeholder_app = placeholder_app
    @max_push_bytes = max_push_bytes
    @shared_caching = shared_caching
  end

  #: (Paquette::rack_env env) -> Paquette::rack_response
  def call(env)
    with_caching_defaults(dispatch(env))
  end

  private

  #: (Paquette::rack_env env) -> Paquette::rack_response
  def dispatch(env)
    Measurometer.instrument("paquette.pypi_server.call") do
      request_env = env.dup
      request = Rack::Request.new(request_env)
      route = @@routes.match(request)
      # Outcomes go into the env the application holds, not the dup
      Paquette::Served.route(env, route) if route
      refusal = authentication_refusal(route, env)
      next refusal if refusal
      next not_found("Not Found") unless route

      if route.write?
        refusal = cap_request_body(request_env)
        next refusal if refusal
      end

      # Shared across Rack threads: the request lives on a per-request clone
      handler = clone
      handler.instance_variable_set(:@request, request)
      response = @@routes.perform_action(route, handler, request)
      Paquette::Served.package(env, handler.send(:served_package, route.params(request)), response[0])
      response
    end
  rescue Paquette::Routes::BadRequest => e
    bad_request(e.message)
  rescue PayloadTooLarge => e
    payload_too_large(e.message)
  end

  # The project a request was about, and the version when a file names one -
  # or what an upload wrote, since that names its project in the body only.
  # A misspelled project is a redirect, so only the normalized name is ever named.
  #
  #: (Hash[String, untyped] params) -> ([String, String] | [String])?
  def served_package(params)
    return @written if @written

    project = params["project"]
    return nil unless project

    filename = params["filename"]&.delete_suffix(METADATA_SUFFIX)
    version = filename && Paquette::PypiServer::PypiRepository.version_from_filename(filename)
    version ? [project, version] : [project]
  end

  # The multipart parse reads the body before any handler sees it, so the
  # cap goes under the parser: refused outright when the length says so,
  # and cut off mid-read when it did not say.
  #
  # - `env`: the request env, changed in place
  #
  # Returns a refusal.
  #
  #: (Paquette::rack_env env) -> Paquette::rack_response?
  def cap_request_body(env)
    return nil unless @max_push_bytes

    declared = Integer(env["CONTENT_LENGTH"].to_s, 10, exception: false)
    return payload_too_large("Request body exceeds the #{@max_push_bytes} byte limit") if declared && declared > @max_push_bytes

    env["rack.input"] = CappedInput.new(env["rack.input"], @max_push_bytes) if env["rack.input"]
    nil
  end

  # An input stream that raises once more than `limit` bytes have come out of it.
  class CappedInput
    #: (untyped io, Integer limit) -> void
    def initialize(io, limit)
      @io = io
      @limit = limit
      @read = 0
    end

    # Raises `PayloadTooLarge`.
    #
    #: (?Integer? length, ?String? outbuf) -> String?
    def read(length = nil, outbuf = nil)
      # One past the cap is enough to know the cap was passed
      length = @limit - @read + 1 if length.nil? || length > @limit - @read + 1
      chunk = outbuf ? @io.read(length, outbuf) : @io.read(length)
      @read += chunk.bytesize if chunk
      raise PayloadTooLarge, "Request body exceeds the #{@limit} byte limit" if @read > @limit

      chunk
    end

    #: () -> void
    def rewind
      @io.rewind if @io.respond_to?(:rewind)
      @read = 0
    end

    #: () -> void
    def close
      @io.close if @io.respond_to?(:close)
    end
  end

  # twine has nowhere to put a code but the username - see
  # Paquette::AuthToken::OTP_USERNAME. The `OTP` header is for curl.
  #
  #: (Paquette::rack_env env) -> String?
  def otp_code(env)
    env["HTTP_OTP"] || Paquette::AuthToken.otp_from_env(env)
  end

  # twine prints only the status line unless run with --verbose, which is
  # where this body shows up
  #
  #: () -> Paquette::rack_response
  def otp_missing
    [401, {"Content-Type" => "text/plain"},
      ["This registry requires a one-time password with every upload. Send the current code as the username " \
       "and the token as the password: twine upload -u 123456 -p TOKEN"]]
  end

  #: () -> Paquette::rack_response
  def otp_rejected
    [401, {"Content-Type" => "text/plain"}, ["The one-time password was not accepted. Retry with a fresh code."]]
  end

  # Basic rather than Bearer: Basic is the only scheme pip and twine answer
  #
  #: () -> Paquette::rack_response
  def unauthorized
    [401, {"Content-Type" => "text/plain", "www-authenticate" => %(Basic realm="Paquette")}, ["Unauthorized"]]
  end

  # The format the page is in decides the body, so a cache has to know it
  #
  #: () -> String
  def vary_header
    "Authorization, Cookie, Accept-Encoding, Accept"
  end

  #: () -> Paquette::rack_response
  def handle_index
    negotiated = negotiate
    return not_acceptable unless negotiated

    format, content_type = negotiated

    etag = etag_for("simple-index", content_type)
    return not_modified(etag) if if_none_match_satisfied?(etag)

    Measurometer.instrument("paquette.pypi_server.index") do
      projects = @repository.project_names
      body = if format == :json
        JSON.generate({"meta" => {"api-version" => API_VERSION}, "projects" => projects.map { |name| {"name" => name} }})
      else
        links = projects.map { |name| %(    <a href="#{h(url_segment(name))}/">#{h(name)}</a><br>) }
        html_page("Simple index", links)
      end
      cacheable([200, {"Content-Type" => content_type}, [body]], etag)
    end
  end

  #: (String project) -> Paquette::rack_response
  def handle_project(project)
    normalized = Paquette::PypiServer::PypiRepository.normalize_name(project)
    return not_found("Project not found") unless normalized
    return redirect("/simple/#{normalized}/") unless normalized == project

    negotiated = negotiate
    return not_acceptable unless negotiated

    format, content_type = negotiated

    etag = etag_for("simple-project", project, content_type)
    return not_modified(etag) if if_none_match_satisfied?(etag)

    Measurometer.instrument("paquette.pypi_server.project") do
      files = @repository.filenames_for_project(project).filter_map { |filename| @repository.file_info(project, filename) }
      next not_found("Project not found") if files.empty?

      body = (format == :json) ? project_json(project, files) : project_html(project, files)
      cacheable([200, {"Content-Type" => content_type}, [body]], etag)
    end
  end

  # Relative URLs, which pip resolves against the page: the page stays the
  # same behind a proxy and under a mount, and so does its ETag.
  #
  #: (String project, String filename) -> String
  def file_url(project, filename)
    "../../files/#{url_segment(project)}/#{url_segment(filename)}"
  end

  #: (String project, Array[Paquette::PypiServer::PypiRepository::DistributionFile] files) -> String
  def project_json(project, files)
    JSON.generate({
      "meta" => {"api-version" => API_VERSION},
      "name" => project,
      "versions" => files.map(&:version).uniq,
      "files" => files.map do |file|
        core_metadata = file.core_metadata_sha256 ? {"sha256" => file.core_metadata_sha256} : false
        {
          "filename" => file.filename,
          "url" => file_url(project, file.filename),
          "hashes" => {"sha256" => file.sha256},
          "requires-python" => file.requires_python,
          "core-metadata" => core_metadata,
          # PEP 714's old spelling, for the pip versions that only know it
          "dist-info-metadata" => core_metadata,
          "yanked" => (file.yanked == "") ? true : file.yanked,
          "size" => file.size,
          "upload-time" => file.upload_time&.utc&.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
        }.compact
      end
    })
  end

  #: (String project, Array[Paquette::PypiServer::PypiRepository::DistributionFile] files) -> String
  def project_html(project, files)
    links = files.map do |file|
      attributes = [%(href="#{h(file_url(project, file.filename))}#sha256=#{h(file.sha256)}")]
      attributes << %(data-requires-python="#{h(file.requires_python)}") if file.requires_python
      if file.core_metadata_sha256
        attributes << %(data-dist-info-metadata="sha256=#{h(file.core_metadata_sha256)}")
        attributes << %(data-core-metadata="sha256=#{h(file.core_metadata_sha256)}")
      end
      attributes << %(data-yanked="#{h(file.yanked)}") if file.yanked
      %(    <a #{attributes.join(" ")}>#{h(file.filename)}</a><br>)
    end
    html_page("Links for #{project}", links)
  end

  #: (String title, Array[String] links) -> String
  def html_page(title, links)
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <meta name="pypi:repository-version" content="#{API_VERSION}">
          <title>#{h(title)}</title>
        </head>
        <body>
          <h1>#{h(title)}</h1>
      #{links.join("\n")}
        </body>
      </html>
    HTML
  end

  # Serves a distribution, or with ".metadata" on the end its core metadata
  #
  #: (String project, String filename) -> Paquette::rack_response
  def handle_file(project, filename)
    return handle_core_metadata(project, filename.delete_suffix(METADATA_SUFFIX)) if filename.end_with?(METADATA_SUFFIX)

    info = @repository.file_info(project, filename)
    return not_found("File not found or it is not within your license") unless info

    # Under a Personalizer this is where the file gets repacked
    path = Measurometer.instrument("paquette.pypi_server.file_path") { @repository.file_path(project, filename) }
    stat = begin
      path && File.stat(path)
    rescue SystemCallError
      nil
    end
    return not_found("File not found or it is not within your license") unless stat

    Measurometer.add_distribution_value("paquette.pypi_server.file_bytes", stat.size)
    serve_immutable_file(path, stat, %("sha256-#{info.sha256}"))
  end

  #: (String project, String filename) -> Paquette::rack_response
  def handle_core_metadata(project, filename)
    info = @repository.file_info(project, filename)
    return not_found("Metadata not found") unless info&.core_metadata_sha256

    etag = %("sha256-#{info.core_metadata_sha256}")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    metadata = @repository.core_metadata(project, filename)
    return not_found("Metadata not found") unless metadata

    headers = Rack::Headers["Content-Type" => "text/plain; charset=utf-8", "etag" => etag]
    headers.merge!(cache_directives(max_age: IMMUTABLE_MAX_AGE))
    [200, headers, [metadata]]
  end

  # The fields twine sends besides the file describe it, and are not
  # believed: the file is read for its name and metadata. A digest it sent
  # is checked, so a body mangled in transit is refused rather than stored.
  #
  #: (Hash[Symbol, untyped] params) -> Paquette::rack_response
  def handle_upload(params)
    return bad_request("Unsupported :action") unless params[:":action"] == "file_upload"

    content = params[:content]
    return bad_request("Upload carries no content") unless content.is_a?(Hash) && content[:tempfile]

    filename = File.basename(content[:filename].to_s)
    parsed = Paquette::PypiServer::PypiRepository.parse_filename(filename)
    return bad_request("Invalid distribution filename") unless parsed

    tempfile = content[:tempfile]
    tempfile.flush if tempfile.respond_to?(:flush)
    Measurometer.add_distribution_value("paquette.pypi_server.upload_bytes", File.size(tempfile.path))

    digest = params[:sha256_digest].to_s
    if !digest.empty? && !digest.casecmp?(Digest::SHA256.file(tempfile.path).hexdigest)
      return bad_request("sha256_digest does not match the uploaded file")
    end

    info = Measurometer.instrument("paquette.pypi_server.upload") { @repository.add_file(tempfile.path, filename) }
    project = Paquette::PypiServer::PypiRepository.normalize_name(parsed[:distribution]) #: String
    @written = [project, info.version]
    # A wheel carries no date worth trusting either, so this is the moment of arrival
    @on_publish&.call(Paquette::Published.new(name: project, version: info.version, released_at: info.upload_time || Time.now), @request)
    text_ok("OK")
  rescue DirectoryPypiRepository::FileAlreadyExists => e
    # 409 is what `twine upload --skip-existing` reads as "already there"
    conflict(e.message)
  rescue DirectoryPypiRepository::InvalidDistribution => e
    bad_request(e.message)
  end

  # The format the client asked for, by q-value, and the Content-Type to
  # answer with. A `?format=` query parameter wins, per PEP 691. No Accept
  # at all is HTML, which is what a client from before PEP 691 expects.
  #
  # Returns nil when nothing on offer is acceptable.
  #
  #: () -> [Symbol, String]?
  def negotiate
    # PEP 691 writes its example with a bare "+", which a query string
    # decodes to a space - and no media type has a space in it
    requested = @request.GET["format"]
    return MEDIA_TYPES[requested.to_s.strip.tr(" ", "+").downcase] if requested

    accept = @request.get_header("HTTP_ACCEPT").to_s
    return MEDIA_TYPES[TEXT_HTML_TYPE] if accept.strip.empty? || accept.bytesize > MAX_ACCEPT_BYTES

    best = nil #: [Float, Integer, [Symbol, String]]?
    accept.split(",").each_with_index do |range, position|
      media_type, *parameters = range.split(";").map(&:strip)
      quality = 1.0
      parameters.each do |parameter|
        key, _, value = parameter.partition("=")
        quality = Float(value.strip, exception: false) || 0.0 if key.strip.casecmp?("q")
      end
      next if quality <= 0

      candidate = MEDIA_TYPES[media_type.to_s.downcase]
      candidate = MEDIA_TYPES[TEXT_HTML_TYPE] if candidate.nil? && ["*/*", "text/*"].include?(media_type)
      next unless candidate

      # Higher q wins, and on a tie whatever the client listed first
      best = [quality, -position, candidate] if best.nil? || quality > best[0]
    end
    best&.last
  end

  # Relative to the mount, so a registry served at /@acme redirects within it
  #
  #: (String path) -> Paquette::rack_response
  def redirect(path)
    location = @request.script_name + path
    [301, {"Content-Type" => "text/plain", "Location" => location}, ["Moved to #{location}"]]
  end

  #: (String string) -> String
  def url_segment(string)
    ERB::Util.url_encode(string.to_s)
  end

  #: (String string) -> String
  def h(string)
    CGI.escapeHTML(string.to_s)
  end

  #: (String data) -> Paquette::rack_response
  def text_ok(data)
    [200, {"Content-Type" => "text/plain"}, [data]]
  end

  #: (Integer status, String message) -> Paquette::rack_response
  def text_error(status, message)
    [status, {"Content-Type" => "text/plain"}, [message]]
  end

  #: (?String message) -> Paquette::rack_response
  def not_found(message = "Not Found")
    text_error(404, message)
  end

  #: (?String message) -> Paquette::rack_response
  def bad_request(message = "Bad Request")
    text_error(400, message)
  end

  #: (?String message) -> Paquette::rack_response
  def conflict(message = "Conflict")
    text_error(409, message)
  end

  #: () -> Paquette::rack_response
  def not_acceptable
    text_error(406, "This index serves #{MEDIA_TYPES.keys.join(", ")}")
  end

  #: (?String message) -> Paquette::rack_response
  def payload_too_large(message = "Payload Too Large")
    text_error(413, message)
  end
end
