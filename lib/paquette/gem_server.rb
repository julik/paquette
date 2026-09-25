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
  autoload :SpecValidator, "#{__dir__}/gem_server/spec_validator"

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

  # The three compact index endpoints say their charset out loud, which
  # `text/plain` on its own does not: RFC 2046 makes an unqualified
  # text/plain US-ASCII, and a gem name, a licence or a requirement in one
  # of these bodies is UTF-8. rubygems.org sends this exact string, and
  # rubygems' own conformance suite checks for it byte for byte.
  COMPACT_INDEX_CONTENT_TYPE = "text/plain; charset=utf-8"

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

    # The legacy dependency API, which Bundler falls back to when the
    # compact index is not available and which `gem` still asks for. The
    # unsuffixed path answers Marshal and the .json one answers JSON,
    # which is how rubygems.org distinguishes them — a Bundler that gets
    # JSON out of the unsuffixed path raises out of Marshal.load, so the
    # two cannot share a body.
    r.get "/api/v1/dependencies" do |gems: nil|
      handle_dependencies(gems, as: :marshal)
    end

    r.get "/api/v1/dependencies.json" do |gems: nil|
      handle_dependencies(gems, as: :json)
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

    r.get "/prerelease_specs.4.8" do
      handle_prerelease_specs("4.8")
    end

    r.get "/prerelease_specs.4.8.gz" do
      handle_prerelease_specs("4.8.gz")
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

  # The version column split into the two things it actually holds:
  # "1.0.0-java" into ["1.0.0", "java"], and a column carrying no platform
  # into ["1.0.0", "ruby"].
  #
  # This lives here rather than in the repository for the same reason the
  # two splits above do. The version column is this class's question, and
  # a repository holding a second opinion about it is what once made a gem
  # pushed at "0.2" invisible to every endpoint. So the repository goes on
  # publishing the glued column — the compact index wants it glued, that
  # is the correct wire format there, and gem_file_path is named after it
  # — and every reader that needs the halves apart asks here. One place,
  # one rule, whichever direction it is being read in.
  #
  # There is no pattern, and that is deliberate rather than lazy: no
  # regexp can make this split, because "1.0.0-java" is a perfectly good
  # *version* as far as Gem::Version::VERSION_PATTERN is concerned — the
  # dash is its prerelease separator. What settles it is the other end:
  # Gem::Version#initialize rewrites "-" into ".pre." the moment a version
  # is constructed, so the version string a published spec carries can
  # never contain a dash, and the first dash in the column is therefore
  # always the one the platform was joined on. A plain split on that dash
  # is not an approximation of the rule; it is the rule.
  #
  # The authority on a stored gem's platform is still spec.platform, and
  # callers that are holding a spec anyway use that. This is for the
  # callers that are not — the whole-corpus index endpoints, where a spec
  # read per version would be a tar walk and a YAML parse per gem.
  def self.split_version_column(version_column)
    number, platform = version_column.to_s.split("-", 2)
    [number.to_s, (platform.nil? || platform.empty?) ? Gem::Platform::RUBY : platform]
  end

  # The other direction: a bare version and a platform back into the one
  # column both the filename and the compact index carry. "1.0.0" plus
  # "java" is "1.0.0-java", and "1.0.0" plus "ruby" — or nil, or "" — is
  # "1.0.0", because the plain build is the one whose platform is not
  # written down anywhere.
  #
  # That asymmetry is not a quirk to paper over, it is the format: this
  # is exactly what Gem::Specification#full_name does, so a push writing
  # its gem at this column writes it at the filename RubyGems itself
  # would have produced, and a corpus predating platform support keeps
  # every path it already had.
  #
  # Pairs with split_version_column, and lives beside it for the same
  # reason: one class holds the rule, whichever direction it is read in.
  def self.version_column(version, platform)
    platform = platform.to_s
    return version.to_s if platform.empty? || platform == Gem::Platform::RUBY

    "#{version}-#{platform}"
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

  # The largest push this server will accept, in bytes. 50MB is what
  # rubygems.org allows and comfortably more than any gem anyone has a
  # reason to publish — the number is here to bound what one request can
  # make the process do, not to be a quota. `nil` removes the cap, which
  # is a decision to make knowingly.
  DEFAULT_MAX_PUSH_BYTES = 50 * 1024 * 1024

  #
  # `shared_caching: false` keeps every response `private`, as if every
  # request carried a credential. Set it when you authorize by something
  # Paquette cannot see - an IP allowlist, mTLS, a header checked in your
  # own middleware, a VPN - in front of an ungated repository. Left at
  # true, an anonymous request over an ungated, unpersonalized repository
  # is answered `public` so a CDN may keep it; see ConditionalGet.
  def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette gem server"),
    max_push_bytes: DEFAULT_MAX_PUSH_BYTES, shared_caching: true)
    @repository = repository
    @placeholder_app = placeholder_app
    @max_push_bytes = max_push_bytes
    @shared_caching = shared_caching
  end

  def call(env)
    with_caching_defaults(dispatch(env))
  end

  private

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

  # One entry per name+version+platform the caller asked about, in the
  # shape rubygems.org serves: `:number` is the bare version and
  # `:platform` is its own field, and the two are never glued together the
  # way the compact index glues them. A client handed "1.0.0-java" as a
  # number has been handed a version string nothing can resolve.
  #
  # The platform comes out of the version column rather than out of the
  # spec on purpose. gem_dependencies reads the spec, but it reads it
  # behind the repository protocol and hands back only the dependencies,
  # so taking spec.platform here would mean a second tar walk and YAML
  # parse per version on a path Bundler hits with every gem in a Gemfile
  # at once. The column already carries the platform the push wrote into
  # the filename, which is spec.platform by construction.
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
            # Pairs, not the repository's hashes: Bundler reads this as
            # `Gem::Dependency.new(dep[0], dep[1])` straight off the
            # unmarshalled array, and rubygems.org's JSON says the same
            # thing in the same shape.
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

  def handle_versions
    versions = []
    # One spec read per version in the corpus — the cost grows with the
    # corpus, not with the request.
    Measurometer.instrument("paquette.gem_server.build_versions") do
      @repository.gem_versions.each do |name, version|
        spec = @repository.gem_spec(name, version)
        versions << {
          name: name,
          # The spec's own version, not the column it is filed under: the
          # column carries the platform suffix for a platform gem, and
          # this endpoint already has a `platform` field to put it in.
          # The spec is read here anyway, so it is the authority for both.
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

  # The body is handed to the repository as an IO rather than read into a
  # String first. It was always going to be written to a tempfile, and the
  # String in between was a whole copy of the upload resident per concurrent
  # push for no gain.
  #
  # Two guards, because one is not enough. CONTENT_LENGTH is checked before
  # a single byte is read, which is what keeps an announced 2GB push from
  # costing anything at all — but a chunked body declares no length, and a
  # dishonest one declares whatever it likes, so the repository caps the
  # actual copy too. The header check is the optimization; the copy cap is
  # the guarantee.
  def handle_push
    declared = declared_content_length
    if @max_push_bytes && declared && declared > @max_push_bytes
      return payload_too_large("Gem payload exceeds the #{@max_push_bytes} byte limit")
    end

    Measurometer.add_distribution_value("paquette.gem_server.push_bytes", declared) if declared

    spec = Measurometer.instrument("paquette.gem_server.read_push_body") do
      @repository.add_gem(@request.body, max_bytes: @max_push_bytes)
    end
    # full_name rather than name-version: it is the platform build that was
    # registered, and saying "a-0.2.0" for all three of them would report
    # the same success three times over.
    text_ok("Successfully registered gem: #{spec.full_name}")
  rescue ReadonlyRepository::WriteNotAllowed => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemYanked => e
    [403, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemAlreadyExists => e
    [409, {"Content-Type" => "text/plain"}, [e.message]]
  rescue DirectoryGemRepository::GemTooLarge => e
    payload_too_large(e.message)
  rescue DirectoryGemRepository::InvalidGem => e
    bad_request(e.message)
  end

  # nil when the client did not announce one — a chunked upload, or a
  # header that is not a number. Not an error on its own: it only means
  # the cheap check cannot be made and the copy cap has to do the work.
  def declared_content_length
    raw = @request.get_header("CONTENT_LENGTH")
    return nil if raw.nil? || raw.to_s.empty?

    Integer(raw, 10)
  rescue ArgumentError, TypeError
    nil
  end

  # `gem yank a -v 1.0.0 --platform java` sends the platform as its own
  # param and omits it entirely for a plain-ruby gem, so an absent or blank
  # platform means "ruby" — and "ruby" is the build whose column carries no
  # suffix. Getting that wrong in either direction destroys the wrong
  # artifact: treating a missing platform as "all of them" would take the
  # java and arm64 builds down with the plain one.
  #
  # The params are validated before they become a path. They are as
  # client-chosen as a pushed gemspec's fields are, and until this was here
  # a gem_name of "../../../srv/other" was handed straight to File.join.
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

  # The spec is read for every gem whose name matches, which is what makes
  # the platform, the authors and the summary the gem's own rather than a
  # placeholder. The read is confined to the matches: a query nothing
  # matches costs a directory listing, and only a query matching the whole
  # corpus costs what /api/v1/versions costs.
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
          # Bare, with the platform beside it — the same split
          # /api/v1/versions makes, and for the same reason.
          version: spec.version.to_s,
          platform: spec.platform.to_s,
          authors: Array(spec.authors),
          # The same field /api/v1/versions serves under this name.
          info: spec.description || spec.summary || ""
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

  # The same "---" marker and trailing newline every other file in this
  # format carries. It used to send the bare names, which is what a reader
  # that splits on newlines and ignores what it does not recognise would
  # never notice — and rubygems' conformance suite is not that reader: it
  # asks for "---\na\nb\n" byte for byte, and for "---\n\n" when the corpus
  # is empty. The empty case is why the names are joined and then given one
  # newline rather than each getting one of their own: an empty corpus still
  # owes the marker a line of its own plus the empty line after it.
  def handle_compact_names
    etag = etag_for("compact-names")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    cacheable_with_ranges(compact_ok("---\n#{@repository.gem_names.join("\n")}\n"), etag)
  end

  # The conditional check is deliberately the first thing here, in front of
  # the Measurometer block and therefore in front of render_compact_versions.
  # A 304 on this endpoint is the whole point of the exercise: the render
  # below walks every gem in the corpus and MD5s the /info/ body it would
  # serve for each, and under a Personalizer that means knowing the SHA256 of
  # a repacked gem per version. Answering "nothing changed" must cost a
  # digest of the corpus fingerprint and not one byte more.
  def handle_compact_versions
    # Strong, which it was not until `created_at:` stopped coming from the
    # clock (see compact_index_created_at). Two renders of an unchanged
    # corpus are now byte-identical, so the validator can promise byte
    # equality — and a strong validator is the one a client is entitled to
    # do byte arithmetic against, which is what makes the range serving
    # below worth anything.
    etag = etag_for("compact-versions")
    return not_modified(etag) if if_none_match_satisfied?(etag)

    response = Measurometer.instrument("paquette.gem_server.compact_versions") { render_compact_versions }
    cacheable_with_ranges(response, etag)
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

    cacheable_with_ranges(compact_ok(body), etag)
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
    rows = gem_versions.sort.map do |name, versions|
      versions_str = versions.join(",")
      checksum = Measurometer.instrument("paquette.gem_server.compact_info_checksum") do
        Digest::MD5.hexdigest(compact_info_body(name).to_s)
      end
      "#{name} #{versions_str} #{checksum}"
    end

    Measurometer.add_distribution_value("paquette.gem_server.compact_versions_gems", gem_versions.size)

    # The header goes on last so the publication times are read after the
    # rows have been rendered: on a DirectoryGemRepository both come out of
    # the same per-version sidecar, and rendering first leaves it warm.
    lines = ["created_at: #{compact_index_created_at(gem_versions)}", "---", *rows]

    # Terminated, not merely separated. The compact index is a line-oriented
    # format and every line in it ends with a newline — including the last
    # one, and including the "---" of an otherwise empty index. A client that
    # fetches this file in ranges and appends what it gets is the one that
    # notices: without the final newline the next chunk lands on the end of
    # the previous row.
    content = lines.join("
") + "
"

    [200, {"Content-Type" => COMPACT_INDEX_CONTENT_TYPE}, [content]]
  end

  # A corpus with nothing in it, and a corpus whose publication times
  # nobody here can establish, both get the epoch: a constant is what
  # "derived from the corpus" comes to when the corpus says nothing.
  EMPTY_CORPUS_CREATED_AT = Time.at(0).utc.iso8601

  # The `created_at:` of /versions, which is the oldest publication time in
  # the corpus and emphatically not Time.now.
  #
  # This line used to be stamped from the clock at render time, and that
  # single field is what kept the /versions validator weak: two renders of
  # an unchanged corpus differed in their first line, so the server could
  # not honestly promise byte equality. It also made byte ranges worse than
  # useless. Bundler >= 2.5 keeps its copy of this document, asks for the
  # tail with `Range: bytes=N-`, appends it and checks the result against
  # Repr-Digest — and a body whose *prefix* moves on every render fails that
  # check every time, so the client would re-download the whole index after
  # doing the ranged request first.
  #
  # rubygems.org can stamp a real creation time because its /versions is a
  # materialized, append-only file; the time it records is the time that
  # file came into being, and it does not move as gems are pushed. Paquette
  # renders the document per request from the corpus, and building such a
  # file is a different feature. The oldest publication time is the nearest
  # honest reading of the same idea — the index has existed, in the sense
  # that it has had something in it, since its oldest gem was published —
  # and it has the property this needs: it is a pure function of the corpus,
  # and it does not move when a gem is pushed, because a push is nearly
  # always newer than the oldest gem already there. So the common change
  # leaves the header alone and only the rows below it move.
  #
  # `published_at` is the repository protocol's own answer, so a wrapper
  # that hides versions (CooldownRepository) or one that reads publication
  # times out of a table of its own is followed here rather than
  # second-guessed. A repository that has never heard of it gets the epoch.
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

  # One [name, Gem::Version, platform] triple per gem in the corpus, which
  # is what rubygems.org's own specs.4.8 unmarshals to — verified against
  # a fetched index, where every row is [String, Gem::Version, String].
  #
  # The Gem::Version is not decoration. Gem::SpecFetcher turns each row
  # into a Gem::NameTuple and then sorts and compares tuples, and a String
  # in that slot compares as a String: "1.10.0" sorts below "1.9.0" and
  # the client resolves to the wrong gem. Marshal carries a Gem::Version
  # as its own string anyway (marshal_dump is `[@version]`), so the wire
  # cost is a few bytes and every client that reads this file has the
  # class loaded already.
  #
  # The platform is split off the version column rather than read off a
  # spec: this endpoint walks the whole corpus and has never opened a gem
  # to do it, and adding a tar walk and a YAML parse per version here
  # would make the cheap index the expensive one. See split_version_column
  # for why the split is exact.
  def generate_specs_array
    Measurometer.instrument("paquette.gem_server.generate_specs_array") do
      @repository.gem_versions.filter_map do |name, version_column|
        tuple = spec_tuple(name, version_column)
        tuple unless tuple.nil? || tuple[1].prerelease?
      end
    end
  end

  # Every prerelease in the corpus, in the same [name, version, platform]
  # shape the other two specs endpoints use. rubygems.org partitions the
  # legacy index this way: specs.4.8 and latest_specs.4.8 carry releases
  # only, prerelease_specs.4.8 carries everything else, and a gem whose
  # every version is a prerelease appears only here.
  #
  # The prerelease question is asked of the Gem::Version spec_tuple parsed
  # and never of the version column it came from. "1.16.0-java" is a java
  # *release*, and Gem::Version reads that column as the prerelease
  # 1.16.0.pre.java — so splitting the platform off first is the whole of
  # what keeps every platform build out of this document.
  def generate_prerelease_specs_array
    Measurometer.instrument("paquette.gem_server.generate_prerelease_specs_array") do
      @repository.gem_versions.filter_map do |name, version_column|
        tuple = spec_tuple(name, version_column)
        tuple if tuple && tuple[1].prerelease?
      end
    end
  end

  # One row of a legacy index, or nil for a version column Gem::Version
  # will not accept. The column is whatever the filename on disk said, and
  # a push cannot write a malformed one — SpecValidator refuses it — but a
  # file dropped into the gems directory by hand can be anything, and one
  # such file must not take the whole index down with an ArgumentError.
  def spec_tuple(name, version_column)
    number, platform = Paquette::GemServer.split_version_column(version_column)
    return nil unless Gem::Version.correct?(number)

    [name.to_s, Gem::Version.new(number), platform]
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

  # The latest version of each gem *per platform*, not per name. A corpus
  # holding nokogiri 1.16.0 for ruby, java and arm64-darwin publishes
  # three rows here, exactly as rubygems.org's latest_specs.4.8 does — one
  # row per name would hide two of those builds from every client that
  # resolves off this index, and which two would depend on the sort.
  #
  # Comparing Gem::Version objects rather than the version columns they
  # came from is the other half of the same fix: "1.16.0-java" parses as
  # 1.16.0.pre.java, a *prerelease*, so a glued column compared as a
  # version ranks every platform build below the plain one.
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
  # The only class in the graph beyond Array and String is Gem::Version,
  # which every client reading these files has loaded before it asks —
  # see generate_specs_array for why it is there.
  def marshal_dump_4_8(obj)
    Marshal.dump(obj.is_a?(Array) ? obj : [])
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

  # text_ok for a compact index body, which is the one text/plain this
  # server sends that has to name its charset. Separate from text_ok rather
  # than a flag on it, because everything else text_ok answers - a push
  # receipt, a refusal - is a sentence for a human and not a file a client
  # parses.
  def compact_ok(data)
    [200, {"Content-Type" => COMPACT_INDEX_CONTENT_TYPE}, [data]]
  end

  def not_found(message = "Not Found")
    [404, {"Content-Type" => "text/plain"}, [message]]
  end

  def bad_request(message = "Bad Request")
    [400, {"Content-Type" => "text/plain"}, [message]]
  end

  # Always with a body: `gem push` prints the response text and Bundler
  # raises on a push response that has none, so an empty 413 reads to the
  # user as a crash rather than as a refusal.
  def payload_too_large(message = "Payload Too Large")
    [413, {"Content-Type" => "text/plain"}, [message]]
  end

  def server_error(message = "Internal Server Error")
    [500, {"Content-Type" => "text/plain"}, [message]]
  end
end
