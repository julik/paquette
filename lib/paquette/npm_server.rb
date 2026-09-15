require "json"
require "fileutils"
require "digest"

require_relative "routes"
require_relative "npm_server/npm_repository"
require_relative "npm_server/directory_npm_repository"
require_relative "npm_server/read_gated_repository"
require_relative "npm_server/personalizer"

module Paquette
  class NpmServer
    # A scoped package reaches us two ways. npm asks for metadata with the
    # separator percent-encoded — /@acme%2Fwidgets — but follows tarball URLs
    # with it left alone, and other clients encode neither. Normalizing to the
    # encoded form here means the routes below can treat a package name as one
    # path segment, which is the only way `/:package_name/-/:tarball_name` can
    # be written at all.
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

      # npm unpublishes in three steps: fetch the document, PUT it back without
      # the versions being removed, then DELETE the tarball. The rev in the path
      # is part of CouchDB's optimistic locking, which this registry does not
      # implement — see `revision_for`.
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

      # The shape Paquette served before it followed the registry convention.
      # Kept so a lockfile written against an older Paquette still resolves.
      r.get "/:package_name/:tarball_name" do |package_name:, tarball_name:|
        handle_tarball(package_name, tarball_name)
      end

      r.get "/:package_name" do |package_name:|
        handle_metadata(package_name)
      end
    end

    # Build an NPM server backed by `repository`. Reads, publishes, and
    # unpublishes all flow through this one object — whether writes are accepted
    # depends on the wrapper chain the caller assembled, exactly as on the gem
    # side. A ReadGatedRepository refuses add_package and yank_package; a bare
    # DirectoryNpmRepository accepts both.
    #
    # A directory path is still accepted, and means "an ungated repository over
    # this directory" — the shorthand this server used to be built with.
    def initialize(repository)
      @repository = if repository.is_a?(String)
        DirectoryNpmRepository.new(repository)
      else
        repository
      end
    end

    def call(env)
      env = env.dup
      env["PATH_INFO"] = normalize_scoped_path(env["PATH_INFO"].to_s)

      request = Rack::Request.new(env)
      route = @@routes.match(request)
      return not_found("Not Found") unless route

      @request = request
      @@routes.perform_action(route, self, request)
    end

    private

    def normalize_scoped_path(path)
      match = SCOPED_PATH.match(path)
      return path unless match

      prefix, scope, name, rest = match.captures
      "#{prefix}#{scope}%2F#{name}#{rest}"
    end

    def handle_metadata(package_name)
      metadata = @repository.package_metadata(package_name)
      return not_found("Package not found") unless metadata

      json_ok(with_absolute_tarballs(metadata))
    end

    def handle_tarball(package_name, tarball_name)
      version = version_from_tarball_name(package_name, tarball_name)
      return not_found("Invalid package filename") unless version
      return not_found("Package not found or it is not within your license") unless @repository.package_exists?(package_name, version)

      path = @repository.package_file_path(package_name, version)
      return not_found("Package not found or it is not within your license") unless path && File.exist?(path)

      headers = {
        "Content-Type" => "application/octet-stream",
        "Content-Length" => File.size(path).to_s
      }
      [200, headers, File.open(path, "rb")]
    end

    # `npm publish` PUTs the whole metadata document with the tarball inlined as
    # base64 under `_attachments`. Everything else in the document — the version
    # doc, the dist hashes the client computed — is ignored: the tarball is the
    # only thing the publisher can assert that we cannot derive ourselves, and
    # deriving the rest is what keeps the metadata honest about the bytes on
    # disk.
    def handle_publish(package_name)
      document = parse_json_body
      return bad_request("Request body is not valid JSON") unless document

      attachments = document["_attachments"]
      # A PUT with no attachment is a document update, which is how npm's
      # unpublish flow removes versions.
      return handle_document_put(package_name, document) if attachments.nil? || attachments.empty?

      _, attachment = attachments.first
      data = attachment.is_a?(Hash) ? attachment["data"] : nil
      return bad_request("Attachment carries no data") if data.nil?

      # unpack1("m") rather than the base64 library, which stopped being a
      # default gem in Ruby 3.4, and in its lenient form because npm has been
      # known to send line-wrapped base64.
      tarball = data.to_s.unpack1("m")

      info = @repository.add_package(tarball, dist_tags: document["dist-tags"] || {})
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

    # The document PUT of npm's unpublish flow: whatever versions the client
    # left out of the document are the ones it wants gone.
    def handle_document_put(package_name, document = nil)
      document ||= parse_json_body
      return bad_request("Request body is not valid JSON") unless document

      kept = (document["versions"] || {}).keys
      removed = @repository.versions_for_package(package_name) - kept
      removed.each { |version| @repository.yank_package(package_name, version) }

      json_ok({success: true, id: package_name, rev: revision_for(package_name)})
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    def handle_unpublish_all(package_name)
      versions = @repository.versions_for_package(package_name)
      return not_found("Package not found") if versions.empty?

      versions.each { |version| @repository.yank_package(package_name, version) }
      json_ok({success: true, id: package_name})
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    rescue DirectoryNpmRepository::PackageNotFound => e
      not_found(e.message)
    end

    # The tarball DELETE that ends npm's unpublish flow. The version is usually
    # gone already, removed by the document PUT that preceded this — so a
    # missing version is success rather than a 404, which is what lets
    # `npm unpublish` finish without reporting an error it cannot act on.
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
      version = @request.body.read.to_s.delete('"').strip
      return bad_request("Request body is not a version") if version.empty?
      return not_found("Package not found") unless @repository.package_exists?(package_name, version)

      @repository.write_dist_tag(package_name, tag, version)
      json_ok(@repository.dist_tags(package_name))
    rescue ReadGatedRepository::WriteNotAllowed => e
      forbidden(e.message)
    end

    def version_from_tarball_name(package_name, tarball_name)
      basename = File.basename(package_name.to_s)
      match = tarball_name.to_s.match(/\A#{Regexp.escape(basename)}-(.+)\.tgz\z/)
      match && match[1]
    end

    # `dist.tarball` must be a URL npm can fetch, and the repository has no idea
    # what host it is being served under — so it renders a path and the absolute
    # form is built here, from the request. Rack resolves the forwarded headers,
    # so this stays correct behind a TLS-terminating proxy, where the scheme the
    # client used is not the scheme we were spoken to in.
    def with_absolute_tarballs(metadata)
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

    # npm's unpublish flow reads `_rev` out of the document and puts it back in
    # the URL, so one has to be there. It is derived from what is on disk rather
    # than stored: this registry does not do optimistic locking — a directory of
    # files has nothing to lock against — and a rev that changes when the corpus
    # changes is the honest version of that.
    def revision_for(package_name)
      versions = @repository.versions_for_package(package_name)
      "#{versions.length}-#{Digest::MD5.hexdigest(versions.join(","))}"
    end

    def parse_json_body
      @request.body.rewind if @request.body.respond_to?(:rewind)
      body = @request.body.read.to_s
      return nil if body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def username
      identity = @request.env["paquette.identity"]
      identity.respond_to?(:username) ? identity.username : "paquette"
    end

    def json_ok(data, status: 200)
      [status, {"Content-Type" => "application/json"}, [JSON.pretty_generate(data)]]
    end

    def text_ok(data)
      [200, {"Content-Type" => "text/plain"}, [data]]
    end

    # npm surfaces the `error` key of a JSON body to the user, so an error that
    # says what went wrong reaches the person running the install rather than
    # being flattened into "404 Not Found".
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
