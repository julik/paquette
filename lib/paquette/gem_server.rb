require "json"
require "fileutils"
require "rubygems"
require "zlib"
require "stringio"
require "digest"
require "time"
require "measurometer"

class Paquette::GemServer
  autoload :CooldownRepository, "#{__dir__}/gem_server/cooldown_repository"
  autoload :DirectoryGemRepository, "#{__dir__}/gem_server/directory_gem_repository"
  autoload :GemRepacker, "#{__dir__}/gem_server/gem_repacker"
  autoload :GemRepository, "#{__dir__}/gem_server/gem_repository"
  autoload :Personalizer, "#{__dir__}/gem_server/personalizer"
  autoload :ReadGatedRepository, "#{__dir__}/gem_server/read_gated_repository"
  autoload :ReadonlyRepository, "#{__dir__}/gem_server/readonly_repository"

  prepend Paquette::RegexpTimeout
  include Paquette::ConditionalGet

  # \A..\z, not ^..$: Mustermann unescapes %0A into a real newline and line
  # anchors let the rest of the segment ride along. NAME_CHAR is RubyGems'
  # own charset for a name. Bounded so the split point cannot slide across a
  # client-chosen length, which is quadratic on 3.1 — no memoization there.
  NAME_CHAR = "[A-Za-z0-9_.-]"

  # The version column of a "name-version" pair, which is Gem::Version's own
  # grammar and not a guess at it. A hand-written \d+\.\d+\.\d+ looks right
  # and is not: RubyGems publishes two-segment versions, and a corpus holding
  # case_transform-0.2 or rails_twirp-0.17 served them to nobody, because
  # every lookup in this file rejected the filename the push had just
  # written. Borrowing the pattern means the rule cannot drift from the
  # ecosystem again.
  #
  # The trailing NAME_CHAR run is the platform suffix a .gem *filename*
  # carries in this same column — "nokogiri-1.16.0-arm64-darwin" — which is
  # not part of a version and so is not in Gem::Version's pattern.
  VERSION_COLUMN = "#{Gem::Version::VERSION_PATTERN}#{NAME_CHAR}{0,255}"

  # The one pattern that splits a "name-version" pair here. The name is
  # greedy on purpose: the dash is ambiguous ("a-1-1.0.0" is the gem "a-1" at
  # 1.0.0, not "a" at "1-1.0.0"), and taking the longest name that still
  # leaves a whole version behind is the reading that gets those right.
  GEM_SPEC_NAME = /\A(#{NAME_CHAR}{1,255})-(#{VERSION_COLUMN})\z/

  # The bound the pattern cannot carry. Every quantifier this file writes is
  # bounded, but the borrowed one is not — Gem::Version::VERSION_PATTERN ends
  # in "(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?", so a client-chosen run of dashes
  # past the version has no ceiling of its own. Regexp.linear_time? is true
  # for the assembled pattern, which settles 3.2 and up; the gemspec still
  # allows 3.1, which does not memoize, and there the split point sliding
  # across a long segment is quadratic. Checking the length first is the
  # bound, and it is a comparison rather than a rewrite of a grammar that is
  # not ours to restate: name, dash, version column.
  MAX_GEM_SPEC_NAME_BYTES = 255 + 1 + 255

  GEM_FILE_EXTENSION = ".gem"

  @@routes = Paquette::Routes.draw do |r|
    # Root endpoint
    r.get "/" do
      @placeholder_app.call(@request.env)
    end

    # API endpoints
    r.post "/api/v1/gems" do
      handle_push
    end

    r.delete "/api/v1/gems/yank" do
      handle_yank
    end

    r.get "/api/v1/versions" do
      handle_versions
    end

    r.get "/api/v1/names" do
      handle_names
    end

    r.get "/api/v1/search.json" do |query: nil|
      handle_search(query)
    end

    # Specs endpoints
    r.get "/specs.4.8" do
      handle_specs("4.8")
    end

    r.get "/specs.4.8.gz" do
      handle_specs("4.8.gz")
    end

    r.get "/latest_specs.4.8" do
      handle_latest_specs("4.8")
    end

    r.get "/latest_specs.4.8.gz" do
      handle_latest_specs("4.8.gz")
    end

    # Compact index endpoints
    r.get "/names" do
      handle_compact_names
    end

    r.get "/versions" do
      handle_compact_versions
    end

    # Dynamic endpoints with parameters
    r.get "/info/:gem_name" do |gem_name:|
      handle_compact_info(gem_name)
    end

    r.get "/quick/Marshal.4.8/:gem_spec_name.gemspec.rz" do |gem_spec_name:|
      # Parse gem name and version from the spec name (e.g., "zip_kit-6.3.2")
      if (split = Paquette::GemServer.split_gem_spec_name(gem_spec_name))
        gem_name, version = split

        if @repository.gem_exists?(gem_name, version)
          spec = @repository.gem_spec(gem_name, version)
          if spec
            # Marshal the spec and compress it with raw deflate (not gzip)
            compressed_spec = Measurometer.instrument("paquette.gem_server.marshal_quick_spec") do
              Zlib::Deflate.deflate(Marshal.dump(spec))
            end
            [200, {"Content-Type" => "application/octet-stream"}, [compressed_spec]]
          else
            not_found("Spec not found")
          end
        else
          not_found("Gem not found: #{gem_name}-#{version}")
        end
      else
        not_found("Invalid gem spec name: #{gem_spec_name}")
      end
    end

    r.get "/gems/:gem_filename" do |gem_filename:|
      # Extract gem name and version from filename
      if (split = Paquette::GemServer.split_gem_filename(gem_filename))
        handle_gem_download(*split)
      else
        not_found("Invalid gem filename")
      end
    end
  end

  # What a request would dispatch to, without dispatching it: a
  # Routes::Recognition naming the route and carrying the path params, or
  # nil for a request no route wants. For the caller that has to name a
  # request before handling it — set a monitoring action, tag a log line —
  # and has to do so in front of a cache, where the hit must be filed under
  # the same name as the miss beneath it. Without this, every application
  # re-implements the routing table above as a parallel set of regexes that
  # drift the day a route changes. Only the path is read; a request this
  # cannot recognize is one the server itself would refuse.
  def self.route_for(env)
    @@routes.recognize(Rack::Request.new(env))
  rescue Paquette::Routes::BadRequest
    nil
  end

  # How `gem push` speaks OTP: the code arrives in the `OTP` header, and a
  # refusal is a plain 401 carrying one of the two sentences the client
  # expects, word for word.
  module OtpDialect
    module_function

    def code_in(env)
      env["HTTP_OTP"]
    end

    def otp_missing
      [401, {}, ["You have enabled multifactor authentication"]]
    end

    def otp_rejected
      [401, {}, ["OTP verification failed"]]
    end
  end

  # An OtpGate that reads and refuses the way this server's publishing
  # client does. The protocol is this class's knowledge — an application
  # only brings the secret.
  def self.otp_gate(secret:, issuer:, drift: 30)
    Paquette::OtpGate.new(secret: secret, issuer: issuer, drift: drift, dialect: OtpDialect)
  end

  # "zip_kit-6.2.1.gem" into ["zip_kit", "6.2.1"], or nil for a filename
  # that is not one — the same split the download route performs, exposed
  # for callers turning route_for's params into a package and a version.
  # The dash rule is genuinely ambiguous ("a-1-1.0.0.gem"), so nothing
  # outside this class should be guessing at it with a regex of its own —
  # including the repository, which used to build a third pattern of its
  # own and disagree with this one about what a version looks like.
  def self.split_gem_filename(gem_filename)
    filename = gem_filename.to_s
    return nil unless filename.end_with?(GEM_FILE_EXTENSION)

    split_gem_spec_name(filename.delete_suffix(GEM_FILE_EXTENSION))
  end

  # "zip_kit-6.2.1" into ["zip_kit", "6.2.1"], the same split without the
  # extension — what /quick/Marshal.4.8/ is handed. split_gem_filename is
  # this plus the suffix, so there is one dash rule and not two.
  def self.split_gem_spec_name(gem_spec_name)
    spec_name = gem_spec_name.to_s
    # Refused on its length before a pattern ever sees it — see
    # MAX_GEM_SPEC_NAME_BYTES. Bytes, not characters: the ceiling is about
    # how much there is to walk, and the check has to hold for a segment
    # that is not valid UTF-8 and so has no character count to speak of.
    return nil if spec_name.bytesize > MAX_GEM_SPEC_NAME_BYTES
    # A %xx-mangled segment can arrive as bytes that are not valid UTF-8,
    # and a regex run over those raises instead of failing to match.
    return nil unless spec_name.valid_encoding?

    match = GEM_SPEC_NAME.match(spec_name)
    match && [match[1], match[2]]
  end

  # Build a gem server backed by `repository`. Reads, writes, and yanks
  # all flow through this one object — whether writes are accepted depends
  # on the wrapper chain the caller assembled. A ReadGatedRepository, for
  # example, refuses add_gem and yank_gem; a bare DirectoryGemRepository
  # accepts both. Callers typically construct the stack per-request so
  # user-specific state (entitlements, license keys) is captured in
  # plain closures rather than stored on the server.
  # The page a browser gets at the root. Any Rack app will do — see
  # IndexPage, which is the default and takes the sentence to print.
  DEFAULT_BLURB = "This server provides RubyGems packages. Point your gem source at it and bundle as usual."

  def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette gem server"))
    @repository = repository
    @placeholder_app = placeholder_app
  end

  def call(env)
    Measurometer.instrument("paquette.gem_server.call") do
      request = Rack::Request.new(env)
      route = @@routes.match(request)
      next not_found("Not found") unless route

      @request = request
      @@routes.perform_action(route, self, request)
    end
  rescue Paquette::Routes::BadRequest => e
    bad_request(e.message)
  end

  private

  def handle_dependencies(request)
    gems = request.params["gems"]

    # Handle different parameter formats
    if gems.is_a?(String)
      # Split comma-separated gem names
      gems = gems.split(",").map(&:strip)
    elsif gems.nil?
      gems = []
    end

    # If no gems specified, return empty array
    if gems.empty?
      return json_ok([])
    end

    dependencies = []
    Measurometer.instrument("paquette.gem_server.dependencies") do
      gems.each do |gem_name|
        gem_versions = @repository.versions_for_gem(gem_name)
        gem_versions.each do |version|
          gem_dependencies = @repository.gem_dependencies(gem_name, version)
          dependencies << {
            name: gem_name,
            number: version,
            platform: "ruby",
            dependencies: gem_dependencies
          }
        end
      end
    end

    json_ok(dependencies)
  end

  def handle_dependencies_json(request)
    handle_dependencies(request)
  end

  def handle_versions
    versions = []
    # One spec read per version in the corpus — the cost grows with the
    # corpus, not with the request.
    Measurometer.instrument("paquette.gem_server.build_versions") do
      @repository.gem_versions.each do |name, version|
        spec = @repository.gem_spec(name, version)
        versions << {
          name: name,
          number: version,
          platform: spec.platform.to_s,
          authors: spec.authors,
          info: spec.description || "",
          homepage: Paquette::SafeUrl.http_url(spec.homepage) || "",
          description: spec.description || "",
          summary: spec.summary || "",
          metadata: safe_metadata(spec.metadata)
        }
      end
    end

    json_ok(versions)
  end

  # The gemspec metadata hash, with every `*_uri` key filtered through
  # SafeUrl and dropped when it is not an absolute http(s) URL. The rest of
  # the hash passes through: an application can put anything it likes in
  # there through GemRepacker's gemspec_extras (a license key, an
  # entitlement) and an allowlist of rubygems.org's own URI keys would
  # silently eat all of it. The `_uri` suffix is RubyGems' own convention
  # for "this value is a URL", so it is the one part of the hash where the
  # shape is known well enough to enforce.
  def safe_metadata(metadata)
    return {} unless metadata.is_a?(Hash)

    metadata.each_with_object({}) do |(key, value), safe|
      if key.to_s.end_with?("_uri")
        url = Paquette::SafeUrl.http_url(value)
        safe[key] = url if url
      else
        safe[key] = value
      end
    end
  end

  def handle_names
    names = @repository.gem_names
    json_ok(names)
  end

  def handle_push
    gem_data = Measurometer.instrument("paquette.gem_server.read_push_body") { @request.body.read }
    Measurometer.add_distribution_value("paquette.gem_server.push_bytes", gem_data.to_s.bytesize)

    spec = @repository.add_gem(gem_data)
    text_ok("Successfully registered gem: #{spec.name}-#{spec.version}")
  rescue ReadonlyRepository::WriteNotAllowed => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemYanked => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemAlreadyExists => e
    [409, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::InvalidGem => e
    bad_request(e.message)
  end

  def handle_yank
    gem_name = @request.params["gem_name"]
    version = @request.params["version"]

    return bad_request("Missing gem_name") if gem_name.nil? || gem_name.empty?
    return bad_request("Missing version") if version.nil? || version.empty?

    @repository.yank_gem(gem_name, version)
    text_ok("Successfully yanked gem: #{gem_name}-#{version}")
  rescue ReadonlyRepository::WriteNotAllowed => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemNotFound => e
    not_found(e.message)
  end

  def handle_search(query)
    query ||= ""
    results = []

    Measurometer.instrument("paquette.gem_server.search") do
      @repository.gem_versions.each do |name, version|
        next unless name.include?(query)

        results << {
          name: name,
          version: version,
          platform: "ruby",
          authors: ["Unknown"],
          info: "Uploaded to Paquette"
        }
      end
    end

    json_ok(results)
  end

  def handle_specs(version)
    # Generate specs in the format expected by Bundler
    specs = generate_specs_array

    # Use Marshal 4.8 format for compatibility with Bundler
    specs_data = Measurometer.instrument("paquette.gem_server.marshal_specs") { marshal_dump_4_8(specs) }

    # For .gz requests, compress the data
    if version.include?(".gz")
      specs_data = gzip_compress(specs_data)
      [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
    else
      [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
    end
  end

  def handle_compact_names
    etag = etag_for("compact-names")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    cacheable(text_ok(@repository.gem_names.join("\n")), etag)
  end

  # The conditional check is deliberately the first thing here, in front of
  # the Measurometer block and therefore in front of render_compact_versions.
  # A 304 on this endpoint is the whole point of the exercise: the render
  # below walks every gem in the corpus and MD5s the /info/ body it would
  # serve for each, and under a Personalizer that means knowing the SHA256 of
  # a repacked gem per version. Answering "nothing changed" must cost a
  # digest of the corpus fingerprint and not one byte more.
  def handle_compact_versions
    # Weak, and it has to be. The body carries `created_at:` stamped from
    # Time.now at render time, so two renders of an unchanged corpus are
    # semantically the same index and are *not* byte-identical — which is
    # exactly the distinction W/ was invented for. Claiming a strong
    # validator here would be a lie, and a strong ETag is the one a client
    # is entitled to use for If-Range byte arithmetic.
    etag = etag_for("compact-versions", weak: true)
    return not_modified(etag) if if_none_match_satisfied?(etag)

    response = Measurometer.instrument("paquette.gem_server.compact_versions") { render_compact_versions }
    cacheable(response, etag)
  end

  # A 304 here cannot outlive the gem it describes. Every validator on this
  # endpoint folds in the corpus fingerprint, and a yank renames the .gem
  # file away, which moves the fingerprint — so the ETag a client holds for
  # a gem that has since been yanked can never match, and the client is told
  # 404 rather than "unchanged". The gem name is in the validator as well,
  # so one gem's cached info can never answer for another's.
  def handle_compact_info(gem_name)
    etag = etag_for("compact-info", gem_name)
    return not_modified(etag) if if_none_match_satisfied?(etag)

    body = compact_info_body(gem_name)
    return not_found("Not Found") if body.nil?

    cacheable(text_ok(body), etag)
  end

  # Rendered per request, and it renders every /info/ file in the corpus to
  # checksum it — the most expensive read this server serves, and the one
  # worth watching first when /versions gets slow.
  def render_compact_versions
    # Group versions by gem name
    gem_versions = {}
    @repository.gem_versions.each do |name, version|
      gem_versions[name] ||= []
      gem_versions[name] << version
    end

    # Sort versions for each gem
    gem_versions.each { |name, versions| versions.sort! }

    # Generate the content in the official format
    lines = []
    lines << "created_at: #{Time.now.utc.iso8601}"
    lines << "---"

    # The third column is the MD5 of this gem's /info/ file, not of anything
    # about the version list. Bundler compares it against the MD5 of the info
    # file it already has on disk and re-fetches when they differ — so a
    # checksum derived from the versions alone can never tell a client that a
    # gem's *dependencies* changed, and a client would keep resolving against
    # a stale info file. Verified against rubygems.org: the md5 of
    # https://rubygems.org/info/rake is byte-for-byte the third column of the
    # `rake` row in https://rubygems.org/versions.
    #
    # This costs a pass over every gem in the corpus, because the only honest
    # way to checksum what /info/ would return is to render it. That is also
    # what makes it correct under a Personalizer, where each licensee's info
    # file carries their own gem checksums.
    gem_versions.sort.each do |name, versions|
      versions_str = versions.join(",")
      checksum = Measurometer.instrument("paquette.gem_server.compact_info_checksum") do
        Digest::MD5.hexdigest(compact_info_body(name).to_s)
      end
      lines << "#{name} #{versions_str} #{checksum}"
    end

    Measurometer.add_distribution_value("paquette.gem_server.compact_versions_gems", gem_versions.size)

    content = lines.join("\n")

    [200, {"Content-Type" => "text/plain"}, [content]]
  end

  # The body of an /info/ file, or nil when the gem is unknown here.
  #
  # The leading "---" is what rubygems.org serves and what the compact index
  # format describes. Bundler's parser tolerates its absence — it takes
  # everything after the marker only if it finds one — but other clients read
  # these files too, and the byte-exact body is what /versions checksums, so
  # there is one renderer and both endpoints go through it.
  def compact_info_body(gem_name)
    Measurometer.instrument("paquette.gem_server.compact_info_body") do
      info_lines = @repository.compact_info(gem_name)
      next nil if info_lines.nil? || info_lines.empty?

      (["---"] + info_lines).join("\n") + "\n"
    end
  end

  def generate_specs_array
    # Generate specs array in the format expected by RubyGems/Bundler
    # Each spec is [gem_name, version, platform]
    # Use only basic Ruby types to ensure Marshal 4.8 compatibility
    Measurometer.instrument("paquette.gem_server.generate_specs_array") do
      specs = []
      @repository.gem_versions.each do |name, version|
        specs << [name.to_s, version.to_s, "ruby"]
      end
      specs
    end
  end

  def handle_latest_specs(version)
    # Generate latest specs (only the latest version of each gem)
    latest_specs = generate_latest_specs_array

    # Use Marshal 4.8 format for compatibility with Bundler
    specs_data = Measurometer.instrument("paquette.gem_server.marshal_specs") { marshal_dump_4_8(latest_specs) }

    # For .gz requests, compress the data
    if version.include?(".gz")
      specs_data = gzip_compress(specs_data)
      [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
    else
      [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
    end
  end

  def generate_latest_specs_array
    # Generate latest specs array - only the latest version of each gem
    Measurometer.instrument("paquette.gem_server.generate_latest_specs_array") do
      latest_versions = {}
      @repository.gem_versions.each do |name, version|
        if !latest_versions[name] || Gem::Version.new(version) > Gem::Version.new(latest_versions[name])
          latest_versions[name] = version
        end
      end

      specs = []
      latest_versions.each do |name, version|
        specs << [name.to_s, version.to_s, "ruby"]
      end
      specs
    end
  end

  def marshal_dump_4_8(obj)
    # Create Marshal data in format 4.8 for compatibility with Bundler
    # Use only basic Ruby types to ensure compatibility
    specs_array = obj.is_a?(Array) ? obj : []

    # Simple Marshal.dump should work with basic types
    Marshal.dump(specs_array)
  end

  def gzip_compress(data)
    # Create proper gzip format with headers, checksums, etc.
    Measurometer.instrument("paquette.gem_server.gzip_compress") do
      StringIO.open do |io|
        Zlib::GzipWriter.wrap(io) do |gz|
          gz.write(data)
        end
        io.string
      end
    end
  end

  # .gem bytes at a given path never change - a yank renames the file away
  # and a name+version can never be pushed twice - so a download is the one
  # thing this server hands out that is worth an immutable, year-long
  # max-age. Under a Personalizer the path is per-licensee (it is named
  # after everything baked into the gem), so that invariant holds there too;
  # what changes is only who may keep the copy, which is Cache-Control's job
  # and not the validator's.
  def handle_gem_download(gem_name, version)
    return not_found("Gem not found or it is not within your license") unless @repository.gem_exists?(gem_name, version)

    # gem_file_path returns the personalized gem where there is one. nil is
    # a gate refusing after gem_exists? said yes, which a per-version
    # entitler can legitimately do.
    gem_path = @repository.gem_file_path(gem_name, version)
    return not_found("Gem not found or it is not within your license") if gem_path.nil?

    stat = begin
      File.stat(gem_path)
    rescue SystemCallError
      return not_found("Gem not found or it is not within your license")
    end

    serve_gem_file(gem_path, stat, gem_name, version)
  end

  # The .gem bytes at a given path never change - a yank renames the file
  # away and a name+version can never be pushed twice - so this is served
  # immutable. Under a Personalizer the path is per-licensee (it is named
  # after everything baked into the gem), so the invariant holds there too;
  # what changes is only who may keep the copy, which is Cache-Control's
  # job and not the validator's.
  def serve_gem_file(gem_path, stat, gem_name, version)
    serve_immutable_file(gem_path, stat, gem_file_etag(gem_path, stat, gem_name, version))
  end

  # What names these particular bytes. The SHA256 the repository already
  # computed and cached is the honest answer and costs two stat calls
  # rather than a re-hash of a multi-megabyte file - it is the very number
  # the compact index publishes as `checksum:`, so a download ETag can
  # never disagree with the index that sent the client here.
  #
  # Size and mtime are the fallback for a repository that does not
  # implement gem_checksum: weaker, but it still moves when the file does.
  #
  # Note that this needs nothing from the wrapper stack. A digest of the
  # bytes being served *is* the validator, and a personalized gem hashes
  # differently by construction. Who is allowed to keep the copy is a
  # separate question, answered by Cache-Control.
  def gem_file_etag(gem_path, stat, gem_name, version)
    checksum = Paquette::GemServer::GemRepository.gem_checksum_of(@repository, gem_name, version)
    return %("#{checksum}") if checksum

    %("#{stat.size}-#{stat.mtime.to_i}-#{stat.mtime.nsec}")
  end

  # Helper methods for common response patterns
  private

  def json_ok(data)
    [200, {"Content-Type" => "application/json"}, [JSON.pretty_generate(data)]]
  end

  def text_ok(data)
    [200, {"Content-Type" => "text/plain"}, [data]]
  end

  def not_found(message = "Not Found")
    [404, {"Content-Type" => "text/plain"}, [message]]
  end

  def bad_request(message = "Bad Request")
    [400, {"Content-Type" => "text/plain"}, [message]]
  end

  def server_error(message = "Internal Server Error")
    [500, {"Content-Type" => "text/plain"}, [message]]
  end
end
