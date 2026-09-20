require "json"
require "fileutils"
require "digest"
require "measurometer"

require_relative "routes"
require_relative "npm_server/npm_repository"
require_relative "npm_server/directory_npm_repository"
require_relative "npm_server/read_gated_repository"
require_relative "npm_server/personalizer"

module Paquette
  class NpmServer
    # npm sends the scope separator percent-encoded for metadata but plain in
    # tarball URLs; normalizing makes a package name one path segment.
    SCOPED_PATH = %r{\A(/(?:-/package/)?)(@[^/%]+)/([^/]+)(/.*)?\z}

    @@routes = Routes.draw do |r|
      r.get "/" do
        text_ok("Paquette NPM Repository")
      end

      r.get "/-/ping" do
        json_ok({})
      end

      r.get "/-/whoami" do
        json_ok({username: username})
      end

      r.get "/-/package/:package_name/dist-tags" do |package_name:|
        tags = @repository.dist_tags(package_name)
        if tags.empty?
          not_found("Package not found")
        else
          json_ok(tags)
        end
      end

      r.put "/-/package/:package_name/dist-tags/:tag" do |package_name:, tag:|
        handle_dist_tag_put(package_name, tag)
      end

      # npm unpublishes via a document PUT then a tarball DELETE; the rev is
      # CouchDB locking, which this registry does not do — see revision_for.
      r.put "/:package_name/-rev/:rev" do |package_name:, rev: nil|
        handle_document_put(package_name)
      end

      r.delete "/:package_name/-rev/:rev" do |package_name:, rev: nil|
        handle_unpublish_all(package_name)
      end

      r.delete "/:package_name/-/:tarball_name/-rev/:rev" do |package_name:, tarball_name:, rev: nil|
        handle_unpublish_version(package_name, tarball_name)
      end

      r.put "/:package_name" do |package_name:|
        handle_publish(package_name)
      end

      r.get "/:package_name/-/:tarball_name" do |package_name:, tarball_name:|
        handle_tarball(package_name, tarball_name)
      end

      # Pre-registry-convention path, kept so old lockfiles still resolve.
      r.get "/:package_name/:tarball_name" do |package_name:, tarball_name:|
        handle_tarball(package_name, tarball_name)
      end

      r.get "/:package_name" do |package_name:|
        handle_metadata(package_name)
      end
    end

    def initialize(repository)
      @repository = if repository.is_a?(String)
        DirectoryNpmRepository.new(repository)
      else
        repository
      end
    end

    def call(env)
      Measurometer.instrument("paquette.npm_server.call") do
        env = env.dup
        env["PATH_INFO"] = normalize_scoped_path(env["PATH_INFO"].to_s)

        request = Rack::Request.new(env)
        route = @@routes.match(request)
        next not_found("Not Found") unless route

        # Shared across Rack threads: the request lives on a per-request clone.
        handler = clone
        handler.instance_variable_set(:@request, request)
        @@routes.perform_action(route, handler, request)
      end
    rescue Routes::BadRequest => e
      bad_request(e.message)
    end

    private

    def normalize_scoped_path(path)
      match = SCOPED_PATH.match(path)
      return path unless match

      prefix, scope, name, rest = match.captures
      "#{prefix}#{scope}%2F#{name}#{rest}"
    end

    # The hot read path for `npm install`: one document covering every version
    # of the package, rebuilt per request.
    def handle_metadata(package_name)
      Measurometer.instrument("paquette.npm_server.metadata") do
        metadata = @repository.package_metadata(package_name)
        next not_found("Package not found") unless metadata

        json_ok(with_absolute_tarballs(metadata))
      end
    end

    def handle_tarball(package_name, tarball_name)
      version = version_from_tarball_name(package_name, tarball_name)
      return not_found("Invalid package filename") unless version
      return not_found("Package not found or it is not within your license") unless @repository.package_exists?(package_name, version)

      # Under a Personalizer this call is where the tarball gets repacked, so
      # it is not the plain path lookup it looks like.
      path = Measurometer.instrument("paquette.npm_server.tarball_path") do
        @repository.package_file_path(package_name, version)
      end
      return not_found("Package not found or it is not within your license") unless path && File.exist?(path)

      size = File.size(path)
      Measurometer.add_distribution_value("paquette.npm_server.tarball_bytes", size)
      headers = {
        "Content-Type" => "application/octet-stream",
        "Content-Length" => size.to_s
      }
      [200, headers, File.open(path, "rb")]
    end

    # Only the `_attachments` tarball is used; the rest is derived from it.
    def handle_publish(package_name)
      document = parse_json_body
      return bad_request("Request body is not valid JSON") unless document

      attachments = document["_attachments"]
      # A PUT with no attachment is a document update (npm's unpublish flow).
      return handle_document_put(package_name, document) if attachments.nil? || attachments.empty?

      _, attachment = attachments.first
      data = attachment.is_a?(Hash) ? attachment["data"] : nil
      return bad_request("Attachment carries no data") if data.nil?

      # unpack1("m"): base64 stopped being a default gem in Ruby 3.4.
      tarball = Measurometer.instrument("paquette.npm_server.decode_attachment") { data.to_s.unpack1("m") }
      Measurometer.add_distribution_value("paquette.npm_server.publish_bytes", tarball.bytesize)

      info = Measurometer.instrument("paquette.npm_server.publish") do
        @repository.add_package(tarball, dist_tags: document["dist-tags"] || {})
      end
      json_ok({success: true, id: info["name"], rev: revision_for(info["name"])}, status: 201)
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageYanked => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageAlreadyExists => e
      conflict(e.message)
    rescue DirectoryNpmRepository::InvalidPackage => e
      bad_request(e.message)
    end

    def handle_document_put(package_name, document = nil)
      document ||= parse_json_body
      return bad_request("Request body is not valid JSON") unless document

      # `npm owner add/rm` PUT no `versions` key; "keep nothing" would tombstone all.
      kept = document["versions"]
      return json_ok({success: true, id: package_name, rev: revision_for(package_name)}) unless kept.is_a?(Hash)

      Measurometer.instrument("paquette.npm_server.document_put") do
        removed = @repository.versions_for_package(package_name) - kept.keys
        removed.each { |version| @repository.yank_package(package_name, version) }
      end

      json_ok({success: true, id: package_name, rev: revision_for(package_name)})
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    def handle_unpublish_all(package_name)
      versions = @repository.versions_for_package(package_name)
      return not_found("Package not found") if versions.empty?

      Measurometer.instrument("paquette.npm_server.unpublish_all") do
        versions.each { |version| @repository.yank_package(package_name, version) }
      end
      json_ok({success: true, id: package_name})
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    # The preceding document PUT usually removed the version, so missing is success.
    def handle_unpublish_version(package_name, tarball_name)
      version = version_from_tarball_name(package_name, tarball_name)
      return not_found("Invalid package filename") unless version

      @repository.yank_package(package_name, version) if @repository.package_exists?(package_name, version)
      json_ok({success: true, id: package_name})
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    def handle_dist_tag_put(package_name, tag)
      # Rack consumed the body if Routes parsed form-encoded params.
      @request.body.rewind if @request.body.respond_to?(:rewind)
      version = @request.body.read.to_s.delete('"').strip
      return bad_request("Request body is not a version") if version.empty?
      return not_found("Package not found") unless @repository.package_exists?(package_name, version)

      @repository.write_dist_tag(package_name, tag, version)
      json_ok(@repository.dist_tags(package_name))
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::InvalidPackage => e
      bad_request(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    # Strip a prefix and a suffix. Interpolating the name into a regexp meant
    # compiling one per call, and a name Regexp.escape could not make safe —
    # invalid UTF-8 from a %xx — raised out of the compile itself.
    def version_from_tarball_name(package_name, tarball_name)
      prefix = "#{File.basename(package_name.to_s)}-"
      name = tarball_name.to_s
      return nil unless name.start_with?(prefix) && name.end_with?(".tgz")

      version = name.delete_suffix(".tgz")[prefix.length..]
      version unless version.empty?
    end

    # The request's forwarded headers keep the URLs correct behind a TLS proxy.
    def with_absolute_tarballs(metadata)
      Measurometer.instrument("paquette.npm_server.absolutize_tarballs") { absolutize_tarballs(metadata) }
    end

    def absolutize_tarballs(metadata)
      base = @request.base_url
      versions = (metadata["versions"] || {}).each_with_object({}) do |(version, doc), acc|
        dist = doc["dist"]
        acc[version] = if dist.is_a?(Hash) && dist["tarball"].to_s.start_with?("/")
          doc.merge("dist" => dist.merge("tarball" => base + dist["tarball"]))
        else
          doc
        end
      end

      metadata.merge("versions" => versions, "_rev" => revision_for(metadata["name"]))
    end

    # npm's unpublish flow needs a `_rev`; derived, since nothing is locked.
    def revision_for(package_name)
      Measurometer.instrument("paquette.npm_server.revision_for") do
        versions = @repository.versions_for_package(package_name)
        "#{versions.length}-#{Digest::MD5.hexdigest(versions.join(","))}"
      end
    end

    # A publish body carries the whole tarball base64-encoded, so both the read
    # and the parse are sized by the package, not by the request.
    def parse_json_body
      @request.body.rewind if @request.body.respond_to?(:rewind)
      body = Measurometer.instrument("paquette.npm_server.read_body") { @request.body.read.to_s }
      return nil if body.empty?

      Measurometer.add_distribution_value("paquette.npm_server.body_bytes", body.bytesize)
      Measurometer.instrument("paquette.npm_server.parse_body") { JSON.parse(body) }
    rescue JSON::ParserError
      nil
    end

    def username
      identity = @request.env["paquette.identity"]
      identity.respond_to?(:username) ? identity.username : "paquette"
    end

    # A package document with many versions is the largest thing this server
    # serializes, and it is serialized on every metadata request.
    def json_ok(data, status: 200)
      body = Measurometer.instrument("paquette.npm_server.generate_json") { JSON.pretty_generate(data) }
      [status, {"Content-Type" => "application/json"}, [body]]
    end

    def text_ok(data)
      [200, {"Content-Type" => "text/plain"}, [data]]
    end

    # npm surfaces the `error` key of a JSON body to the user.
    def json_error(status, message)
      [status, {"Content-Type" => "application/json"}, [JSON.pretty_generate({error: message})]]
    end

    def not_found(message = "Not Found")
      json_error(404, message)
    end

    def bad_request(message = "Bad Request")
      json_error(400, message)
    end

    def forbidden(message = "Forbidden")
      json_error(403, message)
    end

    def conflict(message = "Conflict")
      json_error(409, message)
    end

    def server_error(message = "Internal Server Error")
      json_error(500, message)
    end
  end
end
