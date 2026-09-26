require "json"
require "fileutils"
require "rubygems"
require "zlib"
require "stringio"
require "digest"
require "time"
require "measurometer"

# Rack app serving a RubyGems registry — compact index, legacy Marshal
# indexes, downloads, push and yank — over any GemRepository stack.
class Paquette::GemServer
  autoload :CooldownRepository, "#{__dir__}/gem_server/cooldown_repository"
  autoload :DirectoryGemRepository, "#{__dir__}/gem_server/directory_gem_repository"
  autoload :GemRepacker, "#{__dir__}/gem_server/gem_repacker"
  autoload :GemRepository, "#{__dir__}/gem_server/gem_repository"
  autoload :Personalizer, "#{__dir__}/gem_server/personalizer"
  autoload :ReadGatedRepository, "#{__dir__}/gem_server/read_gated_repository"
  autoload :ReadonlyRepository, "#{__dir__}/gem_server/readonly_repository"
  autoload :SpecValidator, "#{__dir__}/gem_server/spec_validator"

  prepend Paquette::RegexpTimeout
  include Paquette::ConditionalGet

  # RubyGems' own charset for a name.
  NAME_CHAR = "[A-Za-z0-9_.-]"

  # Gem::Version's own grammar plus the platform suffix a .gem *filename*
  # carries in this same column — "nokogiri-1.16.0-arm64-darwin".
  VERSION_COLUMN = "#{Gem::Version::VERSION_PATTERN}#{NAME_CHAR}{0,255}"

  # Splits a "name-version" pair. The name is greedy on purpose: the dash
  # is ambiguous ("a-1-1.0.0" is the gem "a-1" at 1.0.0). \A..\z, not
  # ^..$: Mustermann unescapes %0A into a real newline.
  GEM_SPEC_NAME = /\A(#{NAME_CHAR}{1,255})-(#{VERSION_COLUMN})\z/

  # The bound the pattern cannot carry: Gem::Version's borrowed pattern has
  # unbounded quantifiers, and on Ruby 3.1 (no regexp memoization) the
  # split point sliding across a client-chosen segment is quadratic.
  MAX_GEM_SPEC_NAME_BYTES = 255 + 1 + 255

  GEM_FILE_EXTENSION = ".gem"

  # An unqualified text/plain is US-ASCII per RFC 2046, and these bodies
  # are UTF-8; the conformance suite checks this string byte for byte.
  COMPACT_INDEX_CONTENT_TYPE = "text/plain; charset=utf-8"

  @@routes = Paquette::Routes.draw do |r|
    r.get "/" do
      @placeholder_app.call(@request.env)
    end

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

    # The legacy dependency API. The unsuffixed path must answer Marshal:
    # Bundler raises JSON out of Marshal.load.
    r.get "/api/v1/dependencies" do |gems: nil|
      handle_dependencies(gems, as: :marshal)
    end

    r.get "/api/v1/dependencies.json" do |gems: nil|
      handle_dependencies(gems, as: :json)
    end

    r.get "/api/v1/search.json" do |query: nil|
      handle_search(query)
    end

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

    r.get "/prerelease_specs.4.8" do
      handle_prerelease_specs("4.8")
    end

    r.get "/prerelease_specs.4.8.gz" do
      handle_prerelease_specs("4.8.gz")
    end

    r.get "/names" do
      handle_compact_names
    end

    r.get "/versions" do
      handle_compact_versions
    end

    r.get "/info/:gem_name" do |gem_name:|
      handle_compact_info(gem_name)
    end

    r.get "/quick/Marshal.4.8/:gem_spec_name.gemspec.rz" do |gem_spec_name:|
      if (split = Paquette::GemServer.split_gem_spec_name(gem_spec_name))
        gem_name, version = split

        if @repository.gem_exists?(gem_name, version)
          spec = @repository.gem_spec(gem_name, version)
          if spec
            # Raw deflate, not gzip — that is what the .rz suffix means.
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
      if (split = Paquette::GemServer.split_gem_filename(gem_filename))
        handle_gem_download(*split)
      else
        not_found("Invalid gem filename")
      end
    end
  end

  # What a request would dispatch to, without dispatching it — for callers
  # that must name a request (a monitoring action, a log field) without
  # re-implementing the routing table. Only the path is read.
  #
  # @param env [Hash] the Rack env
  # @return [Paquette::Routes::Recognition, nil]
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

    # @param env [Hash] the Rack env
    # @return [String, nil]
    def code_in(env)
      env["HTTP_OTP"]
    end

    # @return [Array] a Rack response triplet
    def otp_missing
      [401, {}, ["You have enabled multifactor authentication"]]
    end

    # @return [Array] a Rack response triplet
    def otp_rejected
      [401, {}, ["OTP verification failed"]]
    end
  end

  # An OtpGate that reads and refuses the way this server's publishing
  # client does — an application only brings the secret.
  #
  # @param secret [String]
  # @param issuer [String]
  # @param drift [Integer]
  # @return [Paquette::OtpGate]
  def self.otp_gate(secret:, issuer:, drift: 30)
    Paquette::OtpGate.new(secret: secret, issuer: issuer, drift: drift, dialect: OtpDialect)
  end

  # "zip_kit-6.2.1.gem" into ["zip_kit", "6.2.1"] — the one dash rule;
  # nothing outside this class should guess at it with a regex of its own.
  #
  # @param gem_filename [String]
  # @return [Array(String, String), nil] nil for a filename that is not one
  def self.split_gem_filename(gem_filename)
    filename = gem_filename.to_s
    return nil unless filename.end_with?(GEM_FILE_EXTENSION)

    split_gem_spec_name(filename.delete_suffix(GEM_FILE_EXTENSION))
  end

  # "zip_kit-6.2.1" into ["zip_kit", "6.2.1"] — the same split without the
  # extension, so there is one dash rule and not two.
  #
  # @param gem_spec_name [String]
  # @return [Array(String, String), nil]
  def self.split_gem_spec_name(gem_spec_name)
    spec_name = gem_spec_name.to_s
    # Length and encoding checked before a pattern ever runs: a regex over
    # invalid UTF-8 raises rather than failing to match.
    return nil if spec_name.bytesize > MAX_GEM_SPEC_NAME_BYTES
    return nil unless spec_name.valid_encoding?

    match = GEM_SPEC_NAME.match(spec_name)
    match && [match[1], match[2]]
  end

  # "1.0.0-java" into ["1.0.0", "java"], a bare column into ["1.0.0",
  # "ruby"]. A published version string can never contain a dash
  # (Gem::Version rewrites "-" into ".pre." on construction), so the first
  # dash is always the one the platform was joined on.
  #
  # @param version_column [String]
  # @return [Array(String, String)] version and platform
  def self.split_version_column(version_column)
    number, platform = version_column.to_s.split("-", 2)
    [number.to_s, (platform.nil? || platform.empty?) ? Gem::Platform::RUBY : platform]
  end

  # The other direction, exactly as Gem::Specification#full_name has it:
  # the plain build is the one whose platform is not written down.
  #
  # @param version [String]
  # @param platform [String, nil]
  # @return [String]
  def self.version_column(version, platform)
    platform = platform.to_s
    return version.to_s if platform.empty? || platform == Gem::Platform::RUBY

    "#{version}-#{platform}"
  end

  DEFAULT_BLURB = "This server provides RubyGems packages. Point your gem source at it and bundle as usual."

  # The request body handed to the repository on a push: it refuses to
  # yield more than `max_bytes`, since the repository owns the copy loop.
  class CappedBody
    class TooLarge < StandardError; end

    # @param io [IO]
    # @param max_bytes [Integer]
    def initialize(io, max_bytes)
      @io = io
      @max_bytes = max_bytes
      @bytes_read = 0
    end

    # The one method IO.copy_stream requires of a non-IO source; raises the
    # moment the count passes the cap.
    #
    # @return [String, nil]
    # @raise [TooLarge]
    def read(*args)
      chunk = @io.read(*args)
      if chunk
        @bytes_read += chunk.bytesize
        raise TooLarge, "Gem payload exceeds the #{@max_bytes} byte limit" if @bytes_read > @max_bytes
      end
      chunk
    end

    # The count starts over with every rewind so that "read twice" is not
    # mistaken for "twice as large".
    #
    # @return [void]
    def rewind
      @bytes_read = 0
      @io.rewind if @io.respond_to?(:rewind)
    end
  end

  # Reads, writes and yanks all flow through the repository stack the
  # caller assembled, typically constructed per request.
  #
  # @param repository [Paquette::GemServer::GemRepository] the repository
  #   stack to serve
  # @param placeholder_app [#call] the Rack app answering the root path
  # @param max_push_bytes [Integer, nil] the largest push this server
  #   accepts; nil removes the cap, which is a decision to make knowingly
  # @param shared_caching [Boolean] false keeps every response `private`,
  #   as if every request carried a credential — set it when you authorize
  #   by something Paquette cannot see (an IP allowlist, mTLS, a VPN)
  def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette gem server"),
    max_push_bytes: Paquette::MAX_PUSH_SIZE_BYTES, shared_caching: true)
    @repository = repository
    @placeholder_app = placeholder_app
    @max_push_bytes = max_push_bytes
    @shared_caching = shared_caching
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    with_caching_defaults(dispatch(env))
  end

  private

  # @param env [Hash]
  # @return [Array] a Rack response triplet
  def dispatch(env)
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

  # One entry per name+version+platform, in the shape rubygems.org serves.
  # The platform comes out of the version column, not the spec — a spec
  # read here would cost a tar walk per version on a hot Bundler path.
  #
  # @param gems [String, Array, nil]
  # @param as [Symbol] :json or :marshal
  # @return [Array] a Rack response triplet
  def handle_dependencies(gems, as:)
    names = case gems
    when String then gems.split(",").map(&:strip).reject(&:empty?)
    when Array then gems.map { |name| name.to_s.strip }.reject(&:empty?)
    else []
    end

    dependencies = []
    Measurometer.instrument("paquette.gem_server.dependencies") do
      names.each do |gem_name|
        @repository.versions_for_gem(gem_name).each do |version_column|
          number, platform = Paquette::GemServer.split_version_column(version_column)
          dependencies << {
            name: gem_name,
            number: number,
            platform: platform,
            # Pairs, not hashes: Bundler reads this as
            # `Gem::Dependency.new(dep[0], dep[1])` straight off the array.
            dependencies: @repository.gem_dependencies(gem_name, version_column).map do |dep|
              [dep[:name], dep[:requirements]]
            end
          }
        end
      end
    end

    return json_ok(dependencies) if as == :json

    [200, {"Content-Type" => "application/octet-stream"}, [Marshal.dump(dependencies)]]
  end

  # One spec read per version in the corpus — the cost grows with the
  # corpus, not with the request.
  #
  # @return [Array] a Rack response triplet
  def handle_versions
    versions = []
    Measurometer.instrument("paquette.gem_server.build_versions") do
      @repository.gem_versions.each do |name, version|
        spec = @repository.gem_spec(name, version)
        versions << {
          name: name,
          # The spec's own version, not the column it is filed under: the
          # column carries the platform suffix, and this endpoint has a
          # `platform` field to put it in.
          number: spec.version.to_s,
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

  # Every `*_uri` key filtered through SafeUrl; the rest passes through,
  # since gemspec_extras can carry anything an allowlist would eat.
  #
  # @param metadata [Object]
  # @return [Hash]
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

  # @return [Array] a Rack response triplet
  def handle_names
    names = @repository.gem_names
    json_ok(names)
  end

  # The body goes to the repository as an IO, never a String copy. Two
  # guards: CONTENT_LENGTH refuses an announced oversize for free, and
  # CappedBody is the guarantee for the chunked or dishonest body.
  #
  # @return [Array] a Rack response triplet
  def handle_push
    declared = declared_content_length
    if @max_push_bytes && declared && declared > @max_push_bytes
      return payload_too_large("Gem payload exceeds the #{@max_push_bytes} byte limit")
    end

    Measurometer.add_distribution_value("paquette.gem_server.push_bytes", declared) if declared

    body = @max_push_bytes ? CappedBody.new(@request.body, @max_push_bytes) : @request.body
    spec = Measurometer.instrument("paquette.gem_server.read_push_body") do
      @repository.add_gem(body)
    end
    # full_name rather than name-version: it is the platform build that was
    # registered.
    text_ok("Successfully registered gem: #{spec.full_name}")
  rescue ReadonlyRepository::WriteNotAllowed => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemYanked => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemAlreadyExists => e
    [409, {"Content-Type" => "text/plain"}, [e.message]]
  rescue CappedBody::TooLarge => e
    payload_too_large(e.message)
  rescue DirectoryGemRepository::InvalidGem => e
    bad_request(e.message)
  end

  # nil when the client did not announce one — not an error on its own, it
  # only means the copy cap has to do the work.
  #
  # @return [Integer, nil]
  def declared_content_length
    raw = @request.get_header("CONTENT_LENGTH")
    return nil if raw.nil? || raw.to_s.empty?

    Integer(raw, 10)
  rescue ArgumentError, TypeError
    nil
  end

  # An absent or blank platform means "ruby", never "all of them". The
  # params are validated before they become a path — they are as
  # client-chosen as a pushed gemspec's fields.
  #
  # @return [Array] a Rack response triplet
  def handle_yank
    gem_name = @request.params["gem_name"]
    version = @request.params["version"]
    platform = @request.params["platform"]

    return bad_request("Missing gem_name") if gem_name.nil? || gem_name.to_s.empty?
    return bad_request("Missing version") if version.nil? || version.to_s.empty?

    gem_name, version_column = SpecValidator.validate_reference!(gem_name, version, platform)

    @repository.yank_gem(gem_name, version_column)
    text_ok("Successfully yanked gem: #{gem_name}-#{version_column}")
  rescue ReadonlyRepository::WriteNotAllowed => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemNotFound => e
    not_found(e.message)
  rescue DirectoryGemRepository::InvalidGem => e
    bad_request(e.message)
  end

  # The spec is read only for gems whose name matches.
  #
  # @param query [String, nil]
  # @return [Array] a Rack response triplet
  def handle_search(query)
    query ||= ""
    results = []

    Measurometer.instrument("paquette.gem_server.search") do
      @repository.gem_versions.each do |name, version_column|
        next unless name.include?(query)

        spec = @repository.gem_spec(name, version_column)
        next unless spec

        results << {
          name: name,
          version: spec.version.to_s,
          platform: spec.platform.to_s,
          authors: Array(spec.authors),
          info: spec.description || spec.summary || ""
        }
      end
    end

    json_ok(results)
  end

  # @param version [String] "4.8" or "4.8.gz"
  # @return [Array] a Rack response triplet
  def handle_specs(version)
    specs = generate_specs_array

    specs_data = Measurometer.instrument("paquette.gem_server.marshal_specs") { marshal_dump_4_8(specs) }

    if version.include?(".gz")
      specs_data = gzip_compress(specs_data)
      [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
    else
      [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
    end
  end

  # @param version [String] "4.8" or "4.8.gz"
  # @return [Array] a Rack response triplet
  def handle_prerelease_specs(version)
    specs = generate_prerelease_specs_array

    specs_data = Measurometer.instrument("paquette.gem_server.marshal_specs") { marshal_dump_4_8(specs) }

    if version.include?(".gz")
      specs_data = gzip_compress(specs_data)
      [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
    else
      [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
    end
  end

  # The conformance suite asks for "---\na\nb\n" byte for byte, and for
  # "---\n\n" when the corpus is empty — hence join-then-one-newline.
  #
  # @return [Array] a Rack response triplet
  def handle_compact_names
    etag = etag_for("compact-names")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    cacheable_with_ranges(compact_ok("---\n#{@repository.gem_names.join("\n")}\n"), etag)
  end

  # The conditional check goes first: answering "nothing changed" must
  # cost a corpus fingerprint, not the whole-corpus render below.
  #
  # @return [Array] a Rack response triplet
  def handle_compact_versions
    # Strong — a client may do byte arithmetic against it, which is what
    # makes range serving worth anything. See compact_index_created_at.
    etag = etag_for("compact-versions")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    response = Measurometer.instrument("paquette.gem_server.compact_versions") { render_compact_versions }
    cacheable_with_ranges(response, etag)
  end

  # Every validator folds in the corpus fingerprint (a yank moves it) and
  # the gem name, so a 304 cannot outlive the gem or answer for another's.
  #
  # @param gem_name [String]
  # @return [Array] a Rack response triplet
  def handle_compact_info(gem_name)
    etag = etag_for("compact-info", gem_name)
    return not_modified(etag) if if_none_match_satisfied?(etag)

    body = compact_info_body(gem_name)
    return not_found("Not Found") if body.nil?

    cacheable_with_ranges(compact_ok(body), etag)
  end

  # Rendered per request, and it renders every /info/ file in the corpus to
  # checksum it — the most expensive read this server serves.
  #
  # @return [Array] a Rack response triplet
  def render_compact_versions
    gem_versions = {}
    @repository.gem_versions.each do |name, version|
      gem_versions[name] ||= []
      gem_versions[name] << version
    end

    gem_versions.each { |name, versions| versions.sort! }

    # The third column is the MD5 of this gem's /info/ file, which Bundler
    # compares against the copy it holds — so the only honest way to
    # compute it is to render the /info/ body, per gem, per request.
    rows = gem_versions.sort.map do |name, versions|
      versions_str = versions.join(",")
      checksum = Measurometer.instrument("paquette.gem_server.compact_info_checksum") do
        Digest::MD5.hexdigest(compact_info_body(name).to_s)
      end
      "#{name} #{versions_str} #{checksum}"
    end

    Measurometer.add_distribution_value("paquette.gem_server.compact_versions_gems", gem_versions.size)

    # Header last: rendering the rows first leaves the per-version sidecar
    # warm for the publication-time reads.
    lines = ["created_at: #{compact_index_created_at(gem_versions)}", "---", *rows]

    # Terminated, not merely separated: a ranged fetch appends what it
    # gets, and the next chunk must not land on the end of the last row.
    content = lines.join("\n") + "\n"

    [200, {"Content-Type" => COMPACT_INDEX_CONTENT_TYPE}, [content]]
  end

  # A corpus with nothing in it, and one whose publication times nobody can
  # establish, both get the epoch.
  EMPTY_CORPUS_CREATED_AT = Time.at(0).utc.iso8601

  # The `created_at:` of /versions: the oldest publication time in the
  # corpus, emphatically not Time.now — a clock stamp made every render
  # byte-different, which kept the validator weak and broke ranged fetches.
  #
  # @param gem_versions [Hash{String => Array<String>}]
  # @return [String] an ISO 8601 time
  def compact_index_created_at(gem_versions)
    return EMPTY_CORPUS_CREATED_AT unless @repository.respond_to?(:published_at)

    oldest = Measurometer.instrument("paquette.gem_server.compact_versions_created_at") do
      times = gem_versions.flat_map do |name, versions|
        versions.map { |version| @repository.published_at(name, version) }
      end
      times.compact.min
    end
    return EMPTY_CORPUS_CREATED_AT if oldest.nil?

    oldest.to_time.getutc.iso8601
  end

  # The body of an /info/ file, or nil when the gem is unknown here. One
  # renderer for both endpoints: the byte-exact body is what /versions
  # checksums.
  #
  # @param gem_name [String]
  # @return [String, nil]
  def compact_info_body(gem_name)
    Measurometer.instrument("paquette.gem_server.compact_info_body") do
      info_lines = @repository.compact_info(gem_name)
      next nil if info_lines.nil? || info_lines.empty?

      (["---"] + info_lines).join("\n") + "\n"
    end
  end

  # One [name, Gem::Version, platform] triple per gem, as rubygems.org's
  # own specs.4.8 has it. The Gem::Version is not decoration:
  # Gem::SpecFetcher sorts these, and a String sorts "1.10.0" below "1.9.0".
  #
  # @return [Array<Array(String, Gem::Version, String)>]
  def generate_specs_array
    Measurometer.instrument("paquette.gem_server.generate_specs_array") do
      @repository.gem_versions.filter_map do |name, version_column|
        tuple = spec_tuple(name, version_column)
        tuple unless tuple.nil? || tuple[1].prerelease?
      end
    end
  end

  # Every prerelease in the corpus. The question is asked of the parsed
  # Gem::Version and never of the column: Gem::Version reads "1.16.0-java"
  # — a java *release* — as the prerelease 1.16.0.pre.java.
  #
  # @return [Array<Array(String, Gem::Version, String)>]
  def generate_prerelease_specs_array
    Measurometer.instrument("paquette.gem_server.generate_prerelease_specs_array") do
      @repository.gem_versions.filter_map do |name, version_column|
        tuple = spec_tuple(name, version_column)
        tuple if tuple && tuple[1].prerelease?
      end
    end
  end

  # One row of a legacy index, or nil for a version column Gem::Version
  # will not accept: a file dropped into the gems directory by hand must
  # not take the whole index down with an ArgumentError.
  #
  # @param name [String]
  # @param version_column [String]
  # @return [Array(String, Gem::Version, String), nil]
  def spec_tuple(name, version_column)
    number, platform = Paquette::GemServer.split_version_column(version_column)
    return nil unless Gem::Version.correct?(number)

    [name.to_s, Gem::Version.new(number), platform]
  end

  # @param version [String] "4.8" or "4.8.gz"
  # @return [Array] a Rack response triplet
  def handle_latest_specs(version)
    latest_specs = generate_latest_specs_array

    specs_data = Measurometer.instrument("paquette.gem_server.marshal_specs") { marshal_dump_4_8(latest_specs) }

    if version.include?(".gz")
      specs_data = gzip_compress(specs_data)
      [200, {"Content-Type" => "application/x-gzip"}, [specs_data]]
    else
      [200, {"Content-Type" => "application/octet-stream"}, [specs_data]]
    end
  end

  # The latest version of each gem *per platform*, not per name — one row
  # per name would hide the other builds. Parsed versions are compared,
  # never columns: "1.16.0-java" as a version is a prerelease.
  #
  # @return [Array<Array(String, Gem::Version, String)>]
  def generate_latest_specs_array
    Measurometer.instrument("paquette.gem_server.generate_latest_specs_array") do
      latest = {}
      @repository.gem_versions.each do |name, version_column|
        tuple = spec_tuple(name, version_column)
        next if tuple.nil? || tuple[1].prerelease?

        key = [tuple[0], tuple[2]]
        latest[key] = tuple if !latest[key] || tuple[1] > latest[key][1]
      end
      latest.values
    end
  end

  # Marshal's own format is 4.8 and has been since 1.8, so this is
  # Marshal.dump with a guard on the shape rather than a format choice.
  #
  # @param obj [Object]
  # @return [String]
  def marshal_dump_4_8(obj)
    Marshal.dump(obj.is_a?(Array) ? obj : [])
  end

  # @param data [String]
  # @return [String]
  def gzip_compress(data)
    Measurometer.instrument("paquette.gem_server.gzip_compress") do
      StringIO.open do |io|
        Zlib::GzipWriter.wrap(io) do |gz|
          gz.write(data)
        end
        io.string
      end
    end
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Array] a Rack response triplet
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

  # The .gem bytes at a given path never change (a yank renames the file
  # away, a Personalizer's path is per-licensee), so a download is served
  # immutable with a year-long max-age.
  #
  # @return [Array] a Rack response triplet
  def serve_gem_file(gem_path, stat, gem_name, version)
    serve_immutable_file(gem_path, stat, gem_file_etag(gem_path, stat, gem_name, version))
  end

  # The SHA256 the repository already computed — the very number the index
  # publishes as `checksum:`, so the two can never disagree. Size and
  # mtime are the weaker fallback for a repository without gem_checksum.
  #
  # @return [String]
  def gem_file_etag(gem_path, stat, gem_name, version)
    checksum = Paquette::GemServer::GemRepository.gem_checksum_of(@repository, gem_name, version)
    return %("#{checksum}") if checksum

    %("#{stat.size}-#{stat.mtime.to_i}-#{stat.mtime.nsec}")
  end

  private

  # @param data [Object]
  # @return [Array] a Rack response triplet
  def json_ok(data)
    [200, {"Content-Type" => "application/json"}, [JSON.pretty_generate(data)]]
  end

  # @param data [String]
  # @return [Array] a Rack response triplet
  def text_ok(data)
    [200, {"Content-Type" => "text/plain"}, [data]]
  end

  # text_ok for a compact index body — the one text/plain this server
  # sends that has to name its charset.
  #
  # @param data [String]
  # @return [Array] a Rack response triplet
  def compact_ok(data)
    [200, {"Content-Type" => COMPACT_INDEX_CONTENT_TYPE}, [data]]
  end

  # @param message [String]
  # @return [Array] a Rack response triplet
  def not_found(message = "Not Found")
    [404, {"Content-Type" => "text/plain"}, [message]]
  end

  # @param message [String]
  # @return [Array] a Rack response triplet
  def bad_request(message = "Bad Request")
    [400, {"Content-Type" => "text/plain"}, [message]]
  end

  # Always with a body: `gem push` prints the response text and an empty
  # 413 reads to the user as a crash rather than as a refusal.
  #
  # @param message [String]
  # @return [Array] a Rack response triplet
  def payload_too_large(message = "Payload Too Large")
    [413, {"Content-Type" => "text/plain"}, [message]]
  end

  # @param message [String]
  # @return [Array] a Rack response triplet
  def server_error(message = "Internal Server Error")
    [500, {"Content-Type" => "text/plain"}, [message]]
  end
end
