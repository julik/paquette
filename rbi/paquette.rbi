# typed: strong
module Paquette
  DEFAULT_REGEXP_TIMEOUT = T.let(0.05, T.untyped)
  MAX_PUSH_SIZE_BYTES = T.let(50 * 1024 * 1024, T.untyped)
  VERSION = T.let("0.2.0", T.untyped)

  class << self
    # The regexp timeout every Rack app in this gem installs for the duration
    # of a request, in seconds. `nil` is "no ceiling".
    sig { returns(T.nilable(Float)) }
    attr_accessor :regexp_timeout
  end

  # A small method-and-pattern route table with a per-request matching budget.
  # Both servers dispatch through one of these.
  class Routes
    DEFAULT_MATCH_BUDGET = T.let(0.1, T.untyped)

    # _@param_ `match_budget` — seconds allowed for matching the whole table
    sig { params(match_budget: Float, block: T.untyped).returns(Routes) }
    def self.draw(match_budget: DEFAULT_MATCH_BUDGET, &block); end

    # _@param_ `routes`
    # 
    # _@param_ `match_budget`
    sig { params(routes: T::Array[Route], match_budget: Float).void }
    def initialize(routes, match_budget: DEFAULT_MATCH_BUDGET); end

    # _@param_ `request`
    sig { params(request: Rack::Request).returns(T.nilable(Route)) }
    def match(request); end

    # _@param_ `route`
    # 
    # _@param_ `instance`
    # 
    # _@param_ `request`
    # 
    # _@return_ — a Rack response triplet
    sig { params(route: Route, instance: Object, request: Rack::Request).returns(T::Array[T.untyped]) }
    def perform_action(route, instance, request); end

    # Recognize without performing: only the path is read, never the query
    # parser. A matched path whose segments fail the UTF-8 check still gets
    # its name, with empty params.
    # 
    # _@param_ `request`
    # 
    # _@return_ — nil for a request no route wants
    sig { params(request: Rack::Request).returns(T.nilable(Recognition)) }
    def recognize(request); end

    sig { returns(Float) }
    def now; end

    # For the linear_time? test; the request path does not need it.
    sig { returns(T::Array[Route]) }
    attr_reader :routes

    # Raised when the fault is in the request's own bytes rather than in
    # anything it asked for; whichever server is dispatching turns it into a
    # 400.
    class BadRequest < StandardError
    end

    # Rack could not parse the request. See Route#query_params.
    class MalformedRequest < Paquette::Routes::BadRequest
    end

    # Route matching ran past its budget. See Routes#match.
    class MatchBudgetExceeded < Paquette::Routes::BadRequest
    end

    # One route: an HTTP method, a Mustermann pattern and a handler block.
    class Route
      # _@param_ `method` — the HTTP method, uppercase
      # 
      # _@param_ `pattern` — a Mustermann pattern string
      # 
      # _@param_ `block` — the handler
      sig { params(method: String, pattern: String, block: Proc).void }
      def initialize(method, pattern, block); end

      # _@param_ `request`
      sig { params(request: Rack::Request).returns(T::Boolean) }
      def match?(request); end

      # Rack::Builder#map hands the mount point itself over with an empty
      # PATH_INFO — which is not a path, it is the root of the mount, where
      # the index page lives.
      # 
      # _@param_ `request`
      sig { params(request: Rack::Request).returns(String) }
      def path_of(request); end

      # Mustermann unescapes %xx, so a segment can arrive as invalid UTF-8 —
      # on which every regexp a handler runs raises instead of failing to
      # match. Refused at the door.
      # 
      # _@param_ `request`
      # 
      # _@return_ — the pattern's captures
      sig { params(request: Rack::Request).returns(T::Hash[String, Object]) }
      def params(request); end

      # _@param_ `instance` — the server instance the block runs against
      # 
      # _@param_ `request`
      # 
      # _@return_ — a Rack response triplet
      sig { params(instance: Object, request: Rack::Request).returns(T::Array[T.untyped]) }
      def perform_action(instance, request); end

      # _@param_ `instance`
      # 
      # _@param_ `request`
      # 
      # _@return_ — a Rack response triplet
      sig { params(instance: Object, request: Rack::Request).returns(T::Array[T.untyped]) }
      def call_block(instance, request); end

      # Rack parses the query string *and* the body to answer #params, and a
      # body that does not match its Content-Type makes it raise — the
      # client's fault, not a 500. The bare EOFError is the multipart
      # parser's, untagged, for a body shorter than its Content-Length.
      # 
      # _@param_ `request`
      sig { params(request: Rack::Request).returns(T::Hash[String, Object]) }
      def query_params(request); end

      # The block only gets the keywords it declares: a client's stray query
      # parameter (npm sends ?write=true) must not crash it with ArgumentError.
      # 
      # _@param_ `params`
      sig { params(params: T::Hash[Symbol, Object]).returns(T::Hash[Symbol, Object]) }
      def acceptable(params); end

      sig { returns(String) }
      attr_reader :method

      sig { returns(Mustermann::Pattern) }
      attr_reader :pattern

      sig { returns(Proc) }
      attr_reader :block

      # The pattern as written, not as matched — interpolating the matched
      # path would open a new metric per gem name in the corpus.
      sig { returns(String) }
      attr_reader :metric_name
    end

    # The DSL object yielded by {Routes.draw}.
    class RouteBuilder
      # _@param_ `routes`
      sig { params(routes: T::Array[Route]).void }
      def initialize(routes); end

      # _@param_ `pattern`
      sig { params(pattern: String, block: T.untyped).void }
      def get(pattern, &block); end

      # _@param_ `pattern`
      sig { params(pattern: String, block: T.untyped).void }
      def post(pattern, &block); end

      # _@param_ `pattern`
      sig { params(pattern: String, block: T.untyped).void }
      def put(pattern, &block); end

      # _@param_ `pattern`
      sig { params(pattern: String, block: T.untyped).void }
      def delete(pattern, &block); end

      # _@param_ `pattern`
      sig { params(pattern: String, block: T.untyped).void }
      def patch(pattern, &block); end
    end

    # What a request would dispatch to, named. `name` is the route's
    # metric_name; `params` is what the pattern extracted, symbol-keyed.
    # 
    # @!attribute name
    #   @return [String]
    # @!attribute params
    #   @return [Hash{Symbol => Object}]
    class Recognition < Data
      sig { returns(String) }
      attr_accessor :name

      sig { returns(T::Hash[Symbol, Object]) }
      attr_accessor :params
    end
  end

  # Reading and writing of npm tarballs, hand-rolled rather than built on
  # Gem::Package's TarWriter/TarReader: a repack must come out byte-identical
  # (npm checks dist.integrity), and TarWriter can neither take the entry
  # mtime as an argument nor emit a PAX header for an over-long path.
  module Tarball
    BLOCK_SIZE = T.let(512, T.untyped)
    GZIP_MAGIC = T.let("\x1f\x8b".b, T.untyped)
    GZIP_DEFLATE = T.let(8, T.untyped)
    GZIP_OS_UNKNOWN = T.let(255, T.untyped)

    # Yields every file entry in the tarball.
    # 
    # _@param_ `tarball_path`
    # 
    # _@return_ — an Enumerator when no block is given
    sig { params(tarball_path: String, blk: T.proc.params(entry: Entry).void).returns(T.nilable(T::Enumerator[Entry])) }
    def self.each_entry(tarball_path, &blk); end

    # _@param_ `tarball_path`
    sig { params(tarball_path: String).returns(T::Array[Entry]) }
    def self.entries(tarball_path); end

    # Finds the manifest by basename under the root: a `git archive` tarball
    # may not use "package".
    # 
    # _@param_ `tarball_path`
    # 
    # _@return_ — the parsed package.json
    sig { params(tarball_path: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def self.package_json(tarball_path); end

    # _@param_ `records` — the body of a PAX "x" entry
    # 
    # _@return_ — the "path" record's value
    sig { params(records: String).returns(T.nilable(String)) }
    def self.pax_path(records); end

    # ASCII-8BIT bytes make JSON.generate raise; scrub rather than 500 the metadata.
    # 
    # _@param_ `content`
    sig { params(content: String).returns(String) }
    def self.as_text(content); end

    # _@param_ `tarball_path`
    # 
    # _@return_ — the first path segment of the first entry
    sig { params(tarball_path: String).returns(T.nilable(String)) }
    def self.root_dir(tarball_path); end

    # Writes a gzipped tarball. Entries are sorted by name so caller
    # ordering cannot change the bytes.
    # 
    # _@param_ `dest_path`
    # 
    # _@param_ `entries`
    # 
    # _@return_ — dest_path
    sig { params(dest_path: String, entries: T::Array[Entry]).returns(String) }
    def self.write(dest_path, entries); end

    # Gzip with MTIME zero and OS "unknown". Reproducibility holds per zlib
    # build only, so several Paquettes behind one load balancer must share a
    # zlib.
    # 
    # _@param_ `data`
    sig { params(data: String).returns(String) }
    def self.gzip(data); end

    # _@param_ `tarball_path`
    # 
    # _@return_ — :shasum (SHA1 hex) and :integrity
    # (SRI sha512)
    sig { params(tarball_path: String).returns(T::Hash[Symbol, String]) }
    def self.integrity(tarball_path); end

    # uid/gid/uname/gname are zeroed: they describe the packer, not the package.
    # 
    # _@return_ — one 512-byte ustar header block
    sig do
      params(
        name: T.untyped,
        mode: T.untyped,
        mtime: T.untyped,
        size: T.untyped,
        typeflag: T.untyped
      ).returns(String)
    end
    def self.header_for(name, mode, mtime, size, typeflag: "0"); end

    sig do
      params(
        header: T.untyped,
        offset: T.untyped,
        length: T.untyped,
        value: T.untyped
      ).void
    end
    def self.write_field(header, offset, length, value); end

    # ustar's prefix/name split; nil when no split works (PAX header instead).
    # 
    # _@param_ `name`
    sig { params(name: String).returns(T.nilable([String, String])) }
    def self.split_name(name); end

    # _@param_ `name`
    sig { params(name: String).returns(T::Boolean) }
    def self.ustar_representable?(name); end

    # Also written, or a package that stored fine would fail once personalized.
    # 
    # _@param_ `entry`
    sig { params(entry: Entry).returns(String) }
    def self.pax_header_for(entry); end

    # "LENGTH key=value\n"; LENGTH counts its own digits, so grow until stable.
    # 
    # _@param_ `key`
    # 
    # _@param_ `value`
    sig { params(key: String, value: String).returns(String) }
    def self.pax_record(key, value); end

    # _@param_ `name`
    sig { params(name: String).returns(String) }
    def self.pax_header_name(name); end

    # Only the executable bit survives; anything else is the packer's umask.
    # 
    # _@param_ `mode`
    sig { params(mode: Integer).returns(Integer) }
    def self.normalized_mode(mode); end

    # Raised for anything that cannot be read as a gzipped tarball.
    class MalformedTarball < StandardError
    end

    # Raised when a value does not fit its ustar header field.
    class NameTooLong < StandardError
    end

    # @!attribute name
    #   @return [String]
    # @!attribute mode
    #   @return [Integer]
    # @!attribute mtime
    #   @return [Integer]
    # @!attribute content
    #   @return [String]
    class Entry < Struct
      sig { returns(String) }
      attr_accessor :name

      sig { returns(Integer) }
      attr_accessor :mode

      sig { returns(Integer) }
      attr_accessor :mtime

      sig { returns(String) }
      attr_accessor :content
    end
  end

  # Verifies the one-time password on a publishing request. Protocol specifics
  # (which header carries the code, what a refusal looks like on the wire) live
  # in the `dialect:` collaborator each server class supplies — see
  # GemServer.otp_gate and NpmServer.otp_gate.
  class OtpGate
    # _@param_ `secret` — the TOTP secret
    # 
    # _@param_ `issuer` — the TOTP issuer name
    # 
    # _@param_ `dialect` — answers `code_in(env)` with the code the protocol's header carried (or nil), and `otp_missing` / `otp_rejected`, each a Rack response triplet
    # 
    # _@param_ `drift` — allowed clock drift in seconds, both directions
    sig do
      params(
        secret: String,
        issuer: String,
        dialect: Object,
        drift: Integer
      ).void
    end
    def initialize(secret:, issuer:, dialect:, drift: 30); end

    # _@param_ `env` — the Rack env
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(Outcome) }
    def verify(env); end

    # What the gate decided. `reason` is a short machine-readable word for a
    # log line or a metric tag; `response` is the ready Rack refusal, and its
    # absence is the authorization.
    # 
    # @!attribute reason
    #   @return [String]
    # @!attribute response
    #   @return [Array, nil] a Rack response triplet, or nil when authorized
    class Outcome < Data
      sig { returns(T::Boolean) }
      def authorized?; end

      sig { returns(String) }
      attr_accessor :reason

      # _@return_ — a Rack response triplet, or nil when authorized
      sig { returns(T.nilable(T::Array[T.untyped])) }
      attr_accessor :response
    end
  end

  # Narrows a URL that came out of an uploaded package to the shapes safe to
  # hand to a caller who will render it as a link: an absolute http(s) URL with
  # a host, and nothing else. Package metadata is attacker-controlled, and the
  # embedding application's portal will render these values.
  module SafeUrl
    # Returns the value unchanged when it is an absolute http(s) URL with a
    # non-empty host, `nil` otherwise. Never raises: the field can carry bytes
    # that are not valid UTF-8, on which URI's parser raises rather than
    # declining to match.
    # 
    # _@param_ `value` — the published field value
    # 
    # _@return_ — the original string byte for byte — this is a
    # filter, not a rewriter
    sig { params(value: Object).returns(T.nilable(String)) }
    def http_url(value); end

    # Returns the value unchanged when it is an absolute http(s) URL with a
    # non-empty host, `nil` otherwise. Never raises: the field can carry bytes
    # that are not valid UTF-8, on which URI's parser raises rather than
    # declining to match.
    # 
    # _@param_ `value` — the published field value
    # 
    # _@return_ — the original string byte for byte — this is a
    # filter, not a rewriter
    sig { params(value: Object).returns(T.nilable(String)) }
    def self.http_url(value); end
  end

  # Rack app serving a RubyGems registry — compact index, legacy Marshal
  # indexes, downloads, push and yank — over any GemRepository stack.
  class GemServer
    include Paquette::RegexpTimeout
    include Paquette::ConditionalGet
    NAME_CHAR = T.let("[A-Za-z0-9_.-]", T.untyped)
    VERSION_COLUMN = T.let("#{Gem::Version::VERSION_PATTERN}#{NAME_CHAR}{0,255}", T.untyped)
    GEM_SPEC_NAME = T.let(/\A(#{NAME_CHAR}{1,255})-(#{VERSION_COLUMN})\z/, T.untyped)
    MAX_GEM_SPEC_NAME_BYTES = T.let(255 + 1 + 255, T.untyped)
    GEM_FILE_EXTENSION = T.let(".gem", T.untyped)
    COMPACT_INDEX_CONTENT_TYPE = T.let("text/plain; charset=utf-8", T.untyped)
    DEFAULT_BLURB = T.let("This server provides RubyGems packages. Point your gem source at it and bundle as usual.", T.untyped)
    EMPTY_CORPUS_CREATED_AT = T.let(Time.at(0).utc.iso8601, T.untyped)

    # What a request would dispatch to, without dispatching it — for callers
    # that must name a request (a monitoring action, a log field) without
    # re-implementing the routing table. Only the path is read.
    # 
    # _@param_ `env` — the Rack env
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(Paquette::Routes::Recognition)) }
    def self.route_for(env); end

    # An OtpGate that reads and refuses the way this server's publishing
    # client does — an application only brings the secret.
    # 
    # _@param_ `secret`
    # 
    # _@param_ `issuer`
    # 
    # _@param_ `drift`
    sig { params(secret: String, issuer: String, drift: Integer).returns(Paquette::OtpGate) }
    def self.otp_gate(secret:, issuer:, drift: 30); end

    # "zip_kit-6.2.1.gem" into ["zip_kit", "6.2.1"] — the one dash rule;
    # nothing outside this class should guess at it with a regex of its own.
    # 
    # _@param_ `gem_filename`
    # 
    # _@return_ — nil for a filename that is not one
    sig { params(gem_filename: String).returns(T.nilable([String, String])) }
    def self.split_gem_filename(gem_filename); end

    # "zip_kit-6.2.1" into ["zip_kit", "6.2.1"] — the same split without the
    # extension, so there is one dash rule and not two.
    # 
    # _@param_ `gem_spec_name`
    sig { params(gem_spec_name: String).returns(T.nilable([String, String])) }
    def self.split_gem_spec_name(gem_spec_name); end

    # "1.0.0-java" into ["1.0.0", "java"], a bare column into ["1.0.0",
    # "ruby"]. A published version string can never contain a dash
    # (Gem::Version rewrites "-" into ".pre." on construction), so the first
    # dash is always the one the platform was joined on.
    # 
    # _@param_ `version_column`
    # 
    # _@return_ — version and platform
    sig { params(version_column: String).returns([String, String]) }
    def self.split_version_column(version_column); end

    # The other direction, exactly as Gem::Specification#full_name has it:
    # the plain build is the one whose platform is not written down.
    # 
    # _@param_ `version`
    # 
    # _@param_ `platform`
    sig { params(version: String, platform: T.nilable(String)).returns(String) }
    def self.version_column(version, platform); end

    # Reads, writes and yanks all flow through the repository stack the
    # caller assembled, typically constructed per request.
    # 
    # _@param_ `repository` — the repository stack to serve
    # 
    # _@param_ `placeholder_app` — the Rack app answering the root path
    # 
    # _@param_ `max_push_bytes` — the largest push this server accepts; nil removes the cap, which is a decision to make knowingly
    # 
    # _@param_ `shared_caching` — false keeps every response `private`, as if every request carried a credential — set it when you authorize by something Paquette cannot see (an IP allowlist, mTLS, a VPN)
    sig do
      params(
        repository: Paquette::GemServer::GemRepository,
        placeholder_app: T.untyped,
        max_push_bytes: T.nilable(Integer),
        shared_caching: T::Boolean
      ).void
    end
    def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette gem server"), max_push_bytes: Paquette::MAX_PUSH_SIZE_BYTES, shared_caching: true); end

    # _@param_ `env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(env); end

    # _@param_ `env`
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def dispatch(env); end

    # One entry per name+version+platform, in the shape rubygems.org serves.
    # The platform comes out of the version column, not the spec — a spec
    # read here would cost a tar walk per version on a hot Bundler path.
    # 
    # _@param_ `gems`
    # 
    # _@param_ `as` — :json or :marshal
    # 
    # _@return_ — a Rack response triplet
    sig { params(gems: T.nilable(T.any(String, T::Array[T.untyped])), as: Symbol).returns(T::Array[T.untyped]) }
    def handle_dependencies(gems, as:); end

    # One spec read per version in the corpus — the cost grows with the
    # corpus, not with the request.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_versions; end

    # Every `*_uri` key filtered through SafeUrl; the rest passes through,
    # since gemspec_extras can carry anything an allowlist would eat.
    # 
    # _@param_ `metadata`
    sig { params(metadata: Object).returns(T::Hash[T.untyped, T.untyped]) }
    def safe_metadata(metadata); end

    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_names; end

    # The body goes to the repository as an IO, never a String copy. Two
    # guards: CONTENT_LENGTH refuses an announced oversize for free, and
    # CappedBody is the guarantee for the chunked or dishonest body.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_push; end

    # nil when the client did not announce one — not an error on its own, it
    # only means the copy cap has to do the work.
    sig { returns(T.nilable(Integer)) }
    def declared_content_length; end

    # An absent or blank platform means "ruby", never "all of them". The
    # params are validated before they become a path — they are as
    # client-chosen as a pushed gemspec's fields.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_yank; end

    # The spec is read only for gems whose name matches.
    # 
    # _@param_ `query`
    # 
    # _@return_ — a Rack response triplet
    sig { params(query: T.nilable(String)).returns(T::Array[T.untyped]) }
    def handle_search(query); end

    # _@param_ `version` — "4.8" or "4.8.gz"
    # 
    # _@return_ — a Rack response triplet
    sig { params(version: String).returns(T::Array[T.untyped]) }
    def handle_specs(version); end

    # _@param_ `version` — "4.8" or "4.8.gz"
    # 
    # _@return_ — a Rack response triplet
    sig { params(version: String).returns(T::Array[T.untyped]) }
    def handle_prerelease_specs(version); end

    # The conformance suite asks for "---\na\nb\n" byte for byte, and for
    # "---\n\n" when the corpus is empty — hence join-then-one-newline.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_compact_names; end

    # The conditional check goes first: answering "nothing changed" must
    # cost a corpus fingerprint, not the whole-corpus render below.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def handle_compact_versions; end

    # Every validator folds in the corpus fingerprint (a yank moves it) and
    # the gem name, so a 304 cannot outlive the gem or answer for another's.
    # 
    # _@param_ `gem_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(gem_name: String).returns(T::Array[T.untyped]) }
    def handle_compact_info(gem_name); end

    # Rendered per request, and it renders every /info/ file in the corpus to
    # checksum it — the most expensive read this server serves.
    # 
    # _@return_ — a Rack response triplet
    sig { returns(T::Array[T.untyped]) }
    def render_compact_versions; end

    # The `created_at:` of /versions: the oldest publication time in the
    # corpus, emphatically not Time.now — a clock stamp made every render
    # byte-different, which kept the validator weak and broke ranged fetches.
    # 
    # _@param_ `gem_versions`
    # 
    # _@return_ — an ISO 8601 time
    sig { params(gem_versions: T::Hash[String, T::Array[String]]).returns(String) }
    def compact_index_created_at(gem_versions); end

    # The body of an /info/ file, or nil when the gem is unknown here. One
    # renderer for both endpoints: the byte-exact body is what /versions
    # checksums.
    # 
    # _@param_ `gem_name`
    sig { params(gem_name: String).returns(T.nilable(String)) }
    def compact_info_body(gem_name); end

    # One [name, Gem::Version, platform] triple per gem, as rubygems.org's
    # own specs.4.8 has it. The Gem::Version is not decoration:
    # Gem::SpecFetcher sorts these, and a String sorts "1.10.0" below "1.9.0".
    sig { returns(T::Array[[String, Gem::Version, String]]) }
    def generate_specs_array; end

    # Every prerelease in the corpus. The question is asked of the parsed
    # Gem::Version and never of the column: Gem::Version reads "1.16.0-java"
    # — a java *release* — as the prerelease 1.16.0.pre.java.
    sig { returns(T::Array[[String, Gem::Version, String]]) }
    def generate_prerelease_specs_array; end

    # One row of a legacy index, or nil for a version column Gem::Version
    # will not accept: a file dropped into the gems directory by hand must
    # not take the whole index down with an ArgumentError.
    # 
    # _@param_ `name`
    # 
    # _@param_ `version_column`
    sig { params(name: String, version_column: String).returns(T.nilable([String, Gem::Version, String])) }
    def spec_tuple(name, version_column); end

    # _@param_ `version` — "4.8" or "4.8.gz"
    # 
    # _@return_ — a Rack response triplet
    sig { params(version: String).returns(T::Array[T.untyped]) }
    def handle_latest_specs(version); end

    # The latest version of each gem *per platform*, not per name — one row
    # per name would hide the other builds. Parsed versions are compared,
    # never columns: "1.16.0-java" as a version is a prerelease.
    sig { returns(T::Array[[String, Gem::Version, String]]) }
    def generate_latest_specs_array; end

    # Marshal's own format is 4.8 and has been since 1.8, so this is
    # Marshal.dump with a guard on the shape rather than a format choice.
    # 
    # _@param_ `obj`
    sig { params(obj: Object).returns(String) }
    def marshal_dump_4_8(obj); end

    # _@param_ `data`
    sig { params(data: String).returns(String) }
    def gzip_compress(data); end

    # _@param_ `gem_name`
    # 
    # _@param_ `version`
    # 
    # _@return_ — a Rack response triplet
    sig { params(gem_name: String, version: String).returns(T::Array[T.untyped]) }
    def handle_gem_download(gem_name, version); end

    # The .gem bytes at a given path never change (a yank renames the file
    # away, a Personalizer's path is per-licensee), so a download is served
    # immutable with a year-long max-age.
    # 
    # _@return_ — a Rack response triplet
    sig do
      params(
        gem_path: T.untyped,
        stat: T.untyped,
        gem_name: T.untyped,
        version: T.untyped
      ).returns(T::Array[T.untyped])
    end
    def serve_gem_file(gem_path, stat, gem_name, version); end

    # The SHA256 the repository already computed — the very number the index
    # publishes as `checksum:`, so the two can never disagree. Size and
    # mtime are the weaker fallback for a repository without gem_checksum.
    sig do
      params(
        gem_path: T.untyped,
        stat: T.untyped,
        gem_name: T.untyped,
        version: T.untyped
      ).returns(String)
    end
    def gem_file_etag(gem_path, stat, gem_name, version); end

    # _@param_ `data`
    # 
    # _@return_ — a Rack response triplet
    sig { params(data: Object).returns(T::Array[T.untyped]) }
    def json_ok(data); end

    # _@param_ `data`
    # 
    # _@return_ — a Rack response triplet
    sig { params(data: String).returns(T::Array[T.untyped]) }
    def text_ok(data); end

    # text_ok for a compact index body — the one text/plain this server
    # sends that has to name its charset.
    # 
    # _@param_ `data`
    # 
    # _@return_ — a Rack response triplet
    sig { params(data: String).returns(T::Array[T.untyped]) }
    def compact_ok(data); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def not_found(message = "Not Found"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def bad_request(message = "Bad Request"); end

    # Always with a body: `gem push` prints the response text and an empty
    # 413 reads to the user as a crash rather than as a refusal.
    # 
    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def payload_too_large(message = "Payload Too Large"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def server_error(message = "Internal Server Error"); end

    # The validator for one response. nil (no ETag at all) when the stack
    # refuses to name itself: a wrong ETag on a gated index is worse than
    # serving every request in full.
    # 
    # _@param_ `resource_parts` — what distinguishes this endpoint's body from another's over the same corpus
    # 
    # _@param_ `weak`
    sig { params(resource_parts: T::Array[String], weak: T::Boolean).returns(T.nilable(String)) }
    def etag_for(*resource_parts, weak: false); end

    # `public` only when the embedder allowed shared caching, the request
    # carried no credential and nothing in the stack varies by caller —
    # getting this wrong serves one caller's view to the next. `no-cache`
    # rather than `no-store` so the 304 stays reachable.
    # 
    # _@param_ `max_age`
    sig { params(max_age: T.nilable(Integer)).returns(T::Hash[String, String]) }
    def cache_directives(max_age: nil); end

    sig { returns(T::Boolean) }
    def shareable_response?; end

    # Not sufficient on its own — several CDNs ignore Vary on anything but
    # Accept-Encoding; `private` is what actually stands between two callers.
    sig { returns(String) }
    def vary_header; end

    # What every response leaving either server goes through. Anything a
    # handler did not label is `private, no-store`: it carries no validator,
    # so nothing could revalidate it.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def with_caching_defaults(response); end

    # _@param_ `vary` — the Vary already on the response
    # 
    # _@return_ — that Vary with Authorization merged in
    sig { params(vary: T.nilable(String)).returns(String) }
    def vary_with_authorization(vary); end

    # A 200 with the validator and the caching directives attached. An absent
    # etag (fail-closed) still gets the directives: the response is then
    # simply uncacheable-without-asking rather than mislabelled.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable(response, etag); end

    # `cacheable` plus ranges — what makes Bundler >= 2.5 fetch the compact
    # index incrementally. `Repr-Digest` carries the digest of the *whole*
    # representation even on a 206 (RFC 9530), or Bundler will not append;
    # `Digest:` is the obsolete RFC 3230 spelling some intermediaries read.
    # 
    # _@param_ `response` — a Rack response triplet, body already in hand
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable_with_ranges(response, etag); end

    # The single byte range this request asks for, or nil for "serve the
    # whole thing" — never a 416, which would turn a Bundler that merely
    # guessed the tail wrong into a failed install. Called after the
    # conditional check: a matching If-None-Match is a 304, not a 206.
    # 
    # _@param_ `size` — the body size in bytes
    # 
    # _@param_ `etag`
    sig { params(size: Integer, etag: T.nilable(String)).returns(T.nilable(T::Range[T.untyped])) }
    def requested_byte_range(size, etag); end

    # Absent, If-Range allows the range. Present, only a strong tag equal to
    # ours does: a weak validator says nothing about byte offsets, and a date
    # says nothing about a body that is not a file.
    # 
    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_range_allows_range?(etag); end

    # Parses `bytes=first-last`, with either side optionally empty, and
    # nothing else. String operations rather than a pattern over the whole
    # header, per AGENTS.md.
    # 
    # _@param_ `header`
    # 
    # _@param_ `size`
    sig { params(header: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def parse_byte_range(header, size); end

    # `bytes=-N` asks for the final N bytes. A bare `bytes=-` names no number
    # and `bytes=-0` asks for nothing; neither is satisfiable, so both get the
    # whole body.
    # 
    # _@param_ `last`
    # 
    # _@param_ `size`
    sig { params(last: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def suffix_byte_range(last, size); end

    # A 304 repeats the validator and the directives — a shared cache
    # updates its stored headers from it.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `extra` — extra headers
    # 
    # _@return_ — a Rack response triplet
    sig { params(etag: T.nilable(String), extra: T::Hash[String, String]).returns(T::Array[T.untyped]) }
    def not_modified(etag, extra: {}); end

    # A response that must never be stored by anything, for content that is
    # the caller's identity itself.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def uncacheable(response); end

    # If-None-Match wins over If-Modified-Since when both are present, which
    # is what RFC 9110 requires.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `mtime`
    sig { params(etag: T.nilable(String), mtime: Time).returns(T.nilable(T::Boolean)) }
    def conditional_hit?(etag, mtime); end

    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_none_match_satisfied?(etag); end

    # Weak comparison, which is what If-None-Match on a GET calls for: a
    # W/"x" a client holds matches the "x" we would send. String operations
    # rather than a regexp because the value is client-chosen and arbitrarily
    # long (see AGENTS.md).
    # 
    # _@param_ `value`
    sig { params(value: String).returns(String) }
    def opaque_tag(value); end

    # An unparseable date is not a match; second resolution is all an HTTP
    # date has.
    # 
    # _@param_ `mtime`
    sig { params(mtime: Time).returns(T::Boolean) }
    def if_modified_since_satisfied?(mtime); end

    # Rack::Files, so the range machinery is Rack's rather than ours. A nil
    # root: #serving takes an absolute path and never reads @root, and the
    # path is the repository's to decide.
    sig { returns(Rack::Files) }
    def package_file_server; end

    # Serves one immutable artifact off disk — a .gem or .tgz at a given
    # path never changes; yank and unpublish rename away.
    # 
    # _@param_ `path` — absolute path of the file
    # 
    # _@param_ `stat`
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(path: String, stat: File::Stat, etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def serve_immutable_file(path, stat, etag); end

    # The request as Rack::Files should see it: If-Modified-Since comes out
    # because we already answered it (Rack::Files would 304 bare, dropping
    # ETag and Cache-Control), and If-Range is answered here by dropping the
    # Range header, because Rack::Files does not implement it at all.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(etag: T.nilable(String), stat: File::Stat).returns(Rack::Request) }
    def rack_files_request(etag, stat); end

    # An If-Range carries either an entity tag or an HTTP date. A tag is
    # compared strongly — a weak validator says nothing about byte offsets,
    # which is the only thing this comparison is for.
    # 
    # _@param_ `if_range`
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(if_range: String, etag: T.nilable(String), stat: File::Stat).returns(T::Boolean) }
    def if_range_matches?(if_range, etag, stat); end

    # How `gem push` speaks OTP: the code arrives in the `OTP` header, and a
    # refusal is a plain 401 carrying one of the two sentences the client
    # expects, word for word.
    module OtpDialect
      # _@param_ `env` — the Rack env
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
      def code_in(env); end

      # _@param_ `env` — the Rack env
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
      def self.code_in(env); end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def otp_missing; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def self.otp_missing; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def otp_rejected; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def self.otp_rejected; end
    end

    # The request body handed to the repository on a push: it refuses to
    # yield more than `max_bytes`, since the repository owns the copy loop.
    class CappedBody
      # _@param_ `io`
      # 
      # _@param_ `max_bytes`
      sig { params(io: IO, max_bytes: Integer).void }
      def initialize(io, max_bytes); end

      # The one method IO.copy_stream requires of a non-IO source; raises the
      # moment the count passes the cap.
      sig { params(args: T.untyped).returns(T.nilable(String)) }
      def read(*args); end

      # The count starts over with every rewind so that "read twice" is not
      # mistaken for "twice as large".
      sig { void }
      def rewind; end

      class TooLarge < StandardError
      end
    end

    # Rewrites the contents of a .gem into a new, byte-reproducible .gem —
    # replacing magic comment lines, merging gemspec metadata and injecting files.
    class GemRepacker
      # One-shot convenience for {#initialize} + {#repack}.
      # 
      # _@param_ `gem_path`
      # 
      # _@param_ `gemspec_extras`
      # 
      # _@param_ `magic_comment_replacements`
      # 
      # _@param_ `files`
      # 
      # _@param_ `into`
      # 
      # _@return_ — the path of the repacked gem
      sig do
        params(
          gem_path: String,
          gemspec_extras: T::Hash[String, String],
          magic_comment_replacements: T::Hash[String, String],
          files: T::Hash[String, String],
          into: T.nilable(String),
          block: T.untyped
        ).returns(String)
      end
      def self.repack(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block); end

      # _@param_ `gem_path` — path of the source .gem
      # 
      # _@param_ `gemspec_extras` — keys merged into the gemspec metadata
      # 
      # _@param_ `magic_comment_replacements` — whole comment lines to replace, marker => replacement
      # 
      # _@param_ `files` — files to inject, path relative to the gem root => content
      # 
      # _@param_ `into` — destination path; without it the gem lands in a fresh tmpdir whose cleanup becomes the caller's problem.
      sig do
        params(
          gem_path: String,
          gemspec_extras: T::Hash[String, String],
          magic_comment_replacements: T::Hash[String, String],
          files: T::Hash[String, String],
          into: T.nilable(String)
        ).void
      end
      def initialize(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil); end

      # Four subprocess-and-disk stages, each timed separately: a repack that
      # got slow is almost always one of them.
      # 
      # _@return_ — the path of the repacked gem
      sig { returns(String) }
      def repack; end

      # `gem unpack` in-process: shelling out cost ~0.5s of RubyGems boot per
      # gem. The span keeps its old name; the graphs watching it are older.
      sig { void }
      def unpack_gem; end

      sig { void }
      def process_ruby_files; end

      sig { void }
      def inject_files; end

      # _@param_ `file_path`
      sig { params(file_path: String).void }
      def process_ruby_file(file_path); end

      # _@param_ `input_file`
      # 
      # _@param_ `output_file`
      sig { params(input_file: IO, output_file: IO).void }
      def apply_magic_comment_replacements(input_file, output_file); end

      # _@return_ — the path of the finished gem
      sig { returns(String) }
      def repackage_gem; end

      # The original spec with this repack's additions, built in memory rather
      # than via a .gemspec on disk: Gem::Specification.load memoizes per file
      # path forever, which leaked one spec per gem served.
      # 
      # _@param_ `spec`
      sig { params(spec: Gem::Specification).returns(Gem::Specification) }
      def repacked_spec(spec); end

      sig { void }
      def cleanup; end

      # Pins the timestamp RubyGems stamps into a repacked gem, so that repeated
      # repacks of the same gem are byte-identical. RubyGems only offers
      # ENV["SOURCE_DATE_EPOCH"] for this, which is process-wide and thus unsafe
      # with concurrent repacks; this overrides the reader instead.
      module BuildTime
        KEY = T.let(:paquette_gem_repacker_source_date_epoch, T.untyped)

        # Runs the block with the given build timestamp pinned. Fiber-local rather
        # than thread-local, deliberately: a build runs to completion inside the
        # fiber that started it, so this stays per-request under both a thread pool
        # and a fiber scheduler.
        # 
        # _@param_ `time` — the timestamp to stamp into archive entries
        # 
        # _@return_ — the return value of the block
        sig { params(time: T.any(Time, Integer)).returns(Object) }
        def self.with(time); end

        # _@return_ — the pinned epoch, or whatever RubyGems would have used
        sig { returns(String) }
        def source_date_epoch_string; end
      end

      # Gem::Package that reads the files it packs from a directory of the
      # caller's choosing instead of from the working directory, silently.
      # `gem build` only works because the CLI chdir's into the unpacked gem
      # first — and chdir is process-global, so a server cannot do that. Only the
      # two methods that reach outside are overridden; the .gem format itself
      # stays RubyGems'.
      class RootedPackage < Gem::Package
        # Validation is deliberately skipped, and not to save time: it resolves
        # spec.files against the working directory and *prunes* to what it finds —
        # run from the wrong directory it quietly builds a gem with no files in
        # it. The caller prunes against +root+ instead.
        # 
        # _@param_ `spec`
        # 
        # _@param_ `root` — the directory spec.files are relative to
        # 
        # _@param_ `file_name` — where the finished gem is written
        # 
        # _@param_ `build_time` — the timestamp stamped into the archive — see BuildTime for why this is a block around the build, not an argument
        # 
        # _@return_ — file_name
        sig do
          params(
            spec: Gem::Specification,
            root: String,
            file_name: String,
            build_time: Time
          ).returns(String)
        end
        def self.build(spec, root, file_name, build_time:); end

        # The RubyGems original with @root joined onto every path it looks at. The
        # names written into the tar stay relative, which is what a .gem holds.
        # 
        # _@param_ `tar`
        sig { params(tar: Gem::Package::TarWriter).void }
        def add_files(tar); end

        # Gem::Package#build reports on stdout, which is what a person running
        # `gem build` asked for and not what a request asked for.
        sig { void }
        def say; end

        sig { returns(String) }
        attr_accessor :root
      end
    end

    # Wraps a gem repository and serves each gem repacked for one licensee —
    # magic comment lines replaced, files injected, the license key stamped
    # into the gemspec metadata — with the repacked gems and their checksums
    # cached on disk.
    class Personalizer < SimpleDelegator
      CHECKSUM_SIDECAR_FORMAT_VERSION = T.let(1, T.untyped)

      # Two rules make the caching sound, and they are the caller's to keep:
      # what `files_for:` returns may depend on the gem file and
      # `personalization_key:` and nothing else, and nil must be a fact about
      # the file alone — it is remembered per file, never per licensee.
      # 
      # _@param_ `repository` — the repository to wrap
      # 
      # _@param_ `license_key` — stamped into every served gem's metadata
      # 
      # _@param_ `magic_comment_replacements` — whole comment lines to replace in **/*.rb, marker => replacement
      # 
      # _@param_ `files` — path => content, written into every gem and added to spec.files — this is what a per-licensee LICENSE file arrives through, rendered by the caller
      # 
      # _@param_ `files_for` — the per-gem edition of `files:`, called with (gem_name, version, original_path); returns a path => content hash injected on top of `files:`, or nil meaning this gem is served byte for byte as it sits on disk
      # 
      # _@param_ `personalization_key` — everything the personalized bytes depend on beyond the gem itself — a licensee id, a ref
      # 
      # _@param_ `cache_dir` — where personalized gems and opt-out markers are kept; defaults to the system temp directory, which an application with a cache directory of its own should override
      sig do
        params(
          repository: Paquette::GemServer::GemRepository,
          license_key: String,
          magic_comment_replacements: T::Hash[String, String],
          files: T::Hash[String, String],
          files_for: T.nilable(Proc),
          personalization_key: T.nilable(String),
          cache_dir: T.nilable(String)
        ).void
      end
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {}, files_for: nil, personalization_key: nil, cache_dir: nil); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the path of the personalized (or pass-through) gem
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_file_path(gem_name, version); end

      # The wrapped validator with this personalizer's identity mixed in, so
      # one licensee's cached index can never satisfy another's request. The
      # key is the same digest that names the cached gems on disk, so this is
      # exactly as strong as that cache; `files_for:` itself is not digested —
      # a Proc cannot be, and the initializer's contract means it need not be.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # Every byte this serves is baked for one licensee.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # The checksum of what this personalizer would hand over — an ETag that
      # disagreed with the index would read as a tampered gem.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_checksum(gem_name, version); end

      # The wrapped repository's lines with the checksum swapped where the
      # served file differs from the one on disk, and only there — a repack
      # touches no other field.
      # 
      # _@param_ `gem_name`
      sig { params(gem_name: String).returns(T::Array[String]) }
      def compact_info(gem_name); end

      # The cache is keyed by everything that goes INTO the gem, never the gem
      # alone — a per-licensee path is what keeps two racing licensees from
      # receiving each other's copy. Consulted before the gem is ever opened:
      # compact_info asks per version per request.
      # 
      # _@param_ `original_gem_path`
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(original_gem_path: String, gem_name: String, version: String).returns(String) }
      def personalize_gem(original_gem_path, gem_name, version); end

      # The block form of mktmpdir removes exactly what it created, so nothing
      # in this method ever deletes a path somebody else chose.
      # 
      # _@param_ `original_gem_path`
      # 
      # _@param_ `personalized_path`
      # 
      # _@param_ `dynamic_files`
      sig { params(original_gem_path: String, personalized_path: String, dynamic_files: T::Hash[String, String]).returns(String) }
      def repack(original_gem_path, personalized_path, dynamic_files); end

      # The SHA256 of a personalized gem, remembered next to it — the bytes at
      # that path are fixed for as long as the path exists. Size and mtime are
      # checked anyway: a stale checksum reads as a tampered gem.
      # 
      # _@param_ `served`
      sig { params(served: String).returns(String) }
      def served_checksum(served); end

      # Alongside the gem rather than inside a directory of its own, so the two
      # are removed together by anything that sweeps this cache by age.
      # 
      # _@param_ `served`
      sig { params(served: String).returns(String) }
      def checksum_sidecar_path(served); end

      # _@param_ `served`
      # 
      # _@param_ `stat`
      sig { params(served: String, stat: File::Stat).returns(T.nilable(String)) }
      def read_checksum_sidecar(served, stat); end

      # Tempfile-and-rename, so a reader never sees half a digest. Failure is
      # ignored on purpose: an unwritable cache costs a hash per request, not
      # a failed request.
      # 
      # _@param_ `served`
      # 
      # _@param_ `stat`
      # 
      # _@param_ `checksum`
      sig { params(served: String, stat: File::Stat, checksum: String).void }
      def write_checksum_sidecar(served, stat, checksum); end

      # Whole nanoseconds. Float mtimes lose precision on large timestamps, and
      # this is compared for equality.
      # 
      # _@param_ `stat`
      sig { params(stat: File::Stat).returns(Integer) }
      def mtime_ns(stat); end

      # Stat identity in the name, so a replaced source file misses the cache
      # without anything having to be invalidated.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `stat`
      sig { params(gem_name: String, version: String, stat: File::Stat).returns(String) }
      def cache_path(gem_name, version, stat); end

      # Where "this gem carries nothing to personalize" is written down — an
      # empty file whose presence is the fact. Keyed by the source identity
      # alone, never by the licensee: whether a gem participates is a fact
      # about the gem.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `stat`
      sig { params(gem_name: String, version: String, stat: File::Stat).returns(String) }
      def plain_marker_path(gem_name, version, stat); end

      # Everything this personalizer would write into a gem, as one short hash.
      # Stable across processes, so a restart does not orphan the cache.
      sig { returns(String) }
      def personalization_digest; end
    end

    # Abstract base class for gem repositories
    class GemRepository
      sig { void }
      def initialize; end

      # _@return_ — the gem names available in the repository
      sig { returns(T::Array[String]) }
      def gem_names; end

      # _@return_ — [name, version] pairs for all gems
      sig { returns(T::Array[[String, String]]) }
      def gem_versions; end

      # _@param_ `gem_name`
      # 
      # _@return_ — the versions of the gem
      sig { params(gem_name: String).returns(T::Array[String]) }
      def versions_for_gem(gem_name); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the path of the .gem file
      sig { params(gem_name: String, version: String).returns(String) }
      def gem_file_path(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def gem_exists?(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(Gem::Specification)) }
      def gem_spec(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the gem's dependencies
      sig { params(gem_name: String, version: String).returns(T::Array[T.untyped]) }
      def gem_dependencies(gem_name, version); end

      # When the given version was published; CooldownRepository asks this.
      # Subclasses override only to put a cache in front of it.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — nil when it cannot be established
      sig { params(gem_name: String, version: String).returns(T.nilable(Time)) }
      def published_at(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@return_ — the /info/ document for the gem, all versions
      sig { params(gem_name: String).returns(T.nilable(String)) }
      def compact_info(gem_name); end

      # A short string that changes whenever anything this repository would
      # serve changes — wrappers included. A wrapper that cannot describe
      # itself must return nil, "do not cache this", which propagates outward.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # Whether two callers can get different answers out of this repository —
      # false permits `public` responses. True is the only safe default for a
      # repository nobody here has seen.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # The SHA256 of the .gem file this repository would actually serve —
      # under a Personalizer, not the bytes on disk.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — nil when unknown or when the gem is not there
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_checksum(gem_name, version); end

      # The caching questions, asked of an object that may have never heard of
      # the protocol. The rules live in Paquette::CacheValidation, shared with
      # the npm side.
      # 
      # _@param_ `repository`
      sig { params(repository: Object).returns(T.nilable(String)) }
      def self.cache_validator_of(repository); end

      # _@param_ `repository`
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(repository: Object, gem_name: String, version: String).returns(T.nilable(String)) }
      def self.gem_checksum_of(repository, gem_name, version); end

      # _@param_ `inner_validator`
      # 
      # _@param_ `layer`
      # 
      # _@param_ `key`
      sig { params(inner_validator: T.nilable(String), layer: String, key: T.nilable(String)).returns(T.nilable(String)) }
      def self.derive_validator(inner_validator, layer, key); end

      # One line of an /info/ file, in the compact index format:
      # 
      #   VERSION DEP:REQ,DEP:REQ|checksum:SHA256,ruby:REQ,rubygems:REQ
      # 
      # A class method on purpose: some repositories are SimpleDelegators, and
      # an instance method would be forwarded to the wrapped repository.
      # 
      # _@param_ `version`
      # 
      # _@param_ `spec`
      # 
      # _@param_ `checksum`
      sig { params(version: String, spec: Gem::Specification, checksum: String).returns(String) }
      def self.compact_info_line(version, spec, checksum); end

      # The spec boiled down to plain strings and arrays — this hash is what a
      # repository may cache on disk, and strings deserialize into no surprises.
      # 
      # _@param_ `spec`
      # 
      # _@param_ `checksum`
      sig { params(spec: Gem::Specification, checksum: String).returns(T::Hash[String, Object]) }
      def self.compact_info_fields(spec, checksum); end

      # Renders a line from a fields hash — freshly extracted or read back from
      # a cache, the bytes must come out the same either way. Keys beyond the
      # ones this reads are ignored.
      # 
      # _@param_ `version`
      # 
      # _@param_ `fields`
      sig { params(version: String, fields: T::Hash[String, Object]).returns(String) }
      def self.compact_info_line_from_fields(version, fields); end

      # An already-rendered line with only its checksum replaced, for
      # repositories that serve rewritten gem files. Lives here because this
      # class owns the line format; the pattern cannot stray into a
      # neighbouring field.
      # 
      # _@param_ `line`
      # 
      # _@param_ `checksum`
      sig { params(line: String, checksum: String).returns(String) }
      def self.replace_checksum(line, checksum); end

      # A comma separates *dependencies* in this format, so within one
      # dependency the clauses are joined with "&": ">= 1.0, < 3" becomes
      # ">= 1.0&< 3".
      # 
      # _@param_ `requirement`
      sig { params(requirement: Gem::Requirement).returns(String) }
      def self.requirement_string(requirement); end
    end

    # Everything a pushed gemspec claims about itself, checked before any of it
    # is believed: `spec.name`/`spec.version` become a filesystem path, and the
    # compact index is line-oriented text, so an unconstrained field is either a
    # traversal or a forged index row. Runs before the upload is moved into
    # place; gems already on disk are not re-checked.
    class SpecValidator
      NAME = T.let(/\A[A-Za-z0-9]#{Paquette::GemServer::NAME_CHAR}{0,254}\z/, T.untyped)
      PLATFORM = T.let(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/, T.untyped)
      PLATFORM_DOT_DOT = T.let("..", T.untyped)
      VERSION = T.let(Gem::Version::ANCHORED_VERSION_PATTERN, T.untyped)
      FORBIDDEN_IN_FIELD = T.let(/[\r\n\x00]/, T.untyped)
      MAX_FIELD_BYTES = T.let(2048, T.untyped)

      # One error class deliberately: a client cannot act differently on
      # unreadable versus dishonest.
      # 
      # _@param_ `message`
      sig { params(message: String).returns(T.untyped) }
      def self.invalid!(message); end

      # Checks `spec` and returns the validated triple as plain Strings, so a
      # caller cannot go on using the unvalidated `spec.name`. The platform
      # comes back canonicalized, RubyGems' own spelling.
      # 
      # _@param_ `spec`
      # 
      # _@return_ — name, version, platform
      sig { params(spec: Gem::Specification).returns([String, String, String]) }
      def self.validate!(spec); end

      # The same checks applied to the params of a yank, which name a path
      # exactly as a pushed gemspec's fields do. `platform` may be nil or ""
      # (`gem yank` omits it for a plain-ruby gem); `version` may arrive with
      # the platform already glued on, the column as the index publishes it.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `platform`
      # 
      # _@return_ — name and version column (platform
      # already glued on), the pair the repository is keyed by
      sig { params(gem_name: String, version: String, platform: T.nilable(String)).returns([String, String]) }
      def self.validate_reference!(gem_name, version, platform); end

      # `spec.platform` is the String "ruby" for a plain build, a Gem::Platform
      # otherwise; "ruby" is let through as itself because it is the one value
      # that produces no filename suffix at all.
      # 
      # _@param_ `spec`
      sig { params(spec: Gem::Specification).returns(String) }
      def self.platform_of(spec); end

      # Every uploader-controlled field that reaches a line of the compact
      # index — the list reads as "what gets interpolated", not "what is safe".
      # 
      # _@param_ `spec`
      sig { params(spec: Gem::Specification).returns(T::Array[[String, String]]) }
      def self.text_fields(spec); end

      # Bounds, reads as text and re-tags a field as UTF-8 — reinterpreted,
      # not merely asked: a string tagged ASCII-8BIT is *always* "valid", and
      # would blow up later instead of here.
      # 
      # _@param_ `label`
      # 
      # _@param_ `value`
      sig { params(label: String, value: Object).returns(String) }
      def self.scannable(label, value); end

      # The fields that become a path have to be Strings before anything else
      # looks at them; `spec.version` is the exception, parsed into a
      # Gem::Version by RubyGems on the way in.
      # 
      # _@param_ `value`
      # 
      # _@param_ `label`
      sig { params(value: Object, label: String).returns(String) }
      def self.string_field(value, label); end

      # The charset and the one shape it cannot express, in one place, so the
      # push path and the yank path cannot come to different conclusions about
      # the same string.
      # 
      # _@param_ `platform`
      sig { params(platform: String).returns(T::Boolean) }
      def self.valid_platform?(platform); end
    end

    # Wraps a gem repository and hides every version that was published less
    # than `interval` seconds ago, giving a publisher a window to yank a
    # compromised or broken release before anybody can pick it up. Read-only:
    # a push into a delayed view would land and then immediately vanish from
    # the view that accepted it.
    class CooldownRepository < Paquette::GemServer::ReadonlyRepository
      # _@param_ `repository` — the repository to wrap
      # 
      # _@param_ `interval` — the cooldown, in seconds
      # 
      # _@param_ `published_at` — called with `name:` and `version:`, returns a Time — or nil for "I do not know". Defaults to the repository's own published_at (the gemspec date).
      # 
      # _@param_ `published_at_validator` — only with `published_at:`: a zero-argument callable returning a string that changes whenever any answer `published_at:` would give changes, or nil for "I cannot say". Without one, a view over a custom source emits no validator.
      # 
      # _@param_ `clock` — returns the current Time; here so tests do not have to sleep
      sig do
        params(
          repository: Paquette::GemServer::GemRepository,
          interval: T.any(Integer, T.untyped),
          published_at: T.nilable(Proc),
          published_at_validator: T.nilable(Proc),
          clock: Proc
        ).void
      end
      def initialize(repository, interval:, published_at: nil, published_at_validator: nil, clock: -> { Time.now }); end

      # The inner validator alone would 304 a client out of exactly the
      # release the channel exists to deliver — but the servable set only
      # moves when a version crosses the boundary, and versions cross in
      # publication order, so the set is named by how many known publish times
      # are at least `interval` old. That count is digested with the inner
      # validator and the interval; the sorted publish times are memoized
      # under the inner validator, fail-closed as everywhere else.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # A gem with no servable version disappears from /names altogether —
      # Bundler treats a listed name as resolvable.
      sig { returns(T::Array[String]) }
      def gem_names; end

      sig { returns(T::Array[[String, String]]) }
      def gem_versions; end

      # _@param_ `gem_name`
      sig { params(gem_name: String).returns(T::Array[String]) }
      def versions_for_gem(gem_name); end

      # _@param_ `gem_name`
      sig { params(gem_name: String).returns(T.any(T::Array[String], Object)) }
      def compact_info(gem_name); end

      # The download path has to agree with the index: a cooling version 404s.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_file_path(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def gem_exists?(gem_name, version); end

      # True when the version has been published for at least `interval`
      # seconds. An unknown publication time fails **open**: a cooldown is a
      # delay policy, not an authorization boundary — that is
      # ReadGatedRepository's job — and failing closed would break `bundle
      # install` over a missing timestamp.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def servable?(gem_name, version); end

      # The one comparison both servable? and cache_validator make, so the two
      # cannot disagree about which side of the boundary a version is on.
      # 
      # _@param_ `published`
      # 
      # _@param_ `now`
      sig { params(published: Time, now: Time).returns(T::Boolean) }
      def cooled?(published, now); end

      # The known publish times of every version the inner repository lists,
      # sorted; rebuilt only when `key` changes, under the lock.
      # 
      # _@param_ `key`
      sig { params(key: T::Array[T.untyped]).returns(T::Array[Time]) }
      def publish_times_for(key); end

      # The default source is `spec.date`: intrinsic to the immutable gem
      # bytes, where an mtime or a cache-minted "first seen" would put the
      # whole corpus into cooldown on any rsync or restore. Its weakness — it
      # records the publisher's build time — is what `published_at:` is for.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(Time)) }
      def published_time(gem_name, version); end
    end

    # Forbids package pushes
    class ReadonlyRepository < SimpleDelegator
      sig { returns(T.untyped) }
      def add_gem; end

      sig { returns(T.untyped) }
      def yank_gem; end

      # Raised by every write on a readonly repository.
      class WriteNotAllowed < StandardError
      end
    end

    # Wraps a gem repository and filters every read through an entitler block:
    # non-entitled gems disappear from listings, return nil paths, and report
    # as non-existent. Writes always raise — gating reads blocks writes, full
    # stop; a more nuanced policy belongs in its own wrapper.
    class ReadGatedRepository < Paquette::GemServer::ReadonlyRepository
      # _@param_ `repository` — the repository to wrap
      # 
      # _@param_ `gate_key` — what this gate is called, for HTTP caching: the identity the entitler consults plus everything the answers depend on. Left out, the whole stack emits no ETag and serves every request in full — the intended fail-closed default, because a wrong ETag hands one customer another's entitlements.
      sig { params(repository: Paquette::GemServer::GemRepository, gate_key: T.nilable(String), entitler: T.untyped).void }
      def initialize(repository, gate_key: nil, &entitler); end

      # nil without a gate_key — derive_validator does the refusing.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # A gate may decide by something Paquette never sees — an IP, a header —
      # so even two anonymous callers can get different views. Never `public`.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # Asked through the class method rather than with `super` so that an
      # inner repository predating this protocol answers nil instead of
      # raising NoMethodError out of Delegator#method_missing.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_checksum(gem_name, version); end

      sig { returns(T::Array[String]) }
      def gem_names; end

      sig { returns(T::Array[[String, String]]) }
      def gem_versions; end

      # _@param_ `gem_name`
      sig { params(gem_name: String).returns(T::Array[String]) }
      def versions_for_gem(gem_name); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_file_path(gem_name, version); end

      # _@param_ `gem_name`
      sig { params(gem_name: String).returns(T.any(T::Array[String], Object)) }
      def compact_info(gem_name); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def gem_exists?(gem_name, version); end

      # The entitler is the caller's, and a listing calls it once per gem in
      # the corpus — an entitler that reaches for a database on every call is
      # the usual reason a gated index is slower than an ungated one.
      # 
      # _@param_ `criteria`
      # 
      # _@return_ — truthy when entitled
      sig { params(criteria: T::Hash[T.untyped, T.untyped]).returns(Object) }
      def entitled?(**criteria); end
    end

    # Repository implementation that reads gems from a directory
    class DirectoryGemRepository < Paquette::GemServer::GemRepository
      YAML_ALIAS_MUTEX = T.let(Mutex.new, T.untyped)
      CACHE_DIR_BASENAME = T.let(".paquette-cache", T.untyped)
      SIDECAR_FORMAT_VERSION = T.let(3, T.untyped)

      # _@param_ `gems_dir` — the corpus root, created if absent
      sig { params(gems_dir: String).void }
      def initialize(gems_dir); end

      # A digest of what the corpus holds. Paths alone are enough: a push adds
      # one, a yank renames one away to a tomb, and a .gem file at a given path
      # never changes its bytes.
      sig { returns(String) }
      def fingerprint; end

      sig { returns(String) }
      def cache_validator; end

      # A directory of gems is the same directory for everybody; the wrappers
      # above are what make a response caller-specific.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # The SHA256 the sidecar already holds, so an ETag on a download costs
      # two stat calls rather than a re-hash. Goes through the same
      # read-or-derive path compact_info uses, which makes the ETag and the
      # published checksum the same number by construction.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(String)) }
      def gem_checksum(gem_name, version); end

      # Persists a .gem file from an uploaded payload. No size cap on purpose:
      # that is the server's rule, enforced by the body it hands over.
      # 
      # _@param_ `gem_payload` — an IO to stream from (the form the server uses — a 50MB push should not become a 50MB Ruby String) or raw bytes
      # 
      # _@return_ — the parsed spec
      sig { params(gem_payload: T.any(IO, String)).returns(Gem::Specification) }
      def add_gem(gem_payload); end

      # Reads the spec out of an uploaded .gem with YAML alias expansion off:
      # aliases are the billion-laughs DoS, and no real gemspec carries one.
      # Gem::SafeYAML is process-global state RubyGems and Bundler also read,
      # so it is flipped around our own parse and put back, under a mutex,
      # never permanently at require time.
      # 
      # _@param_ `gem_path`
      sig { params(gem_path: String).returns(Gem::Specification) }
      def read_uploaded_spec(gem_path); end

      # Whether a path the repository is about to write to is really inside the
      # corpus. The trailing separator stops a sibling directory whose name
      # merely starts the same way — "/srv/gems-evil" against "/srv/gems".
      # 
      # _@param_ `path`
      sig { params(path: String).returns(T::Boolean) }
      def within_gems_dir?(path); end

      # Yanks a gem by renaming its .gem file to a per-artifact .gem.tomb:
      # yanking "a-0.2.0-java" leaves "a-0.2.0" downloadable.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version` — a version column
      sig { params(gem_name: String, version: String).void }
      def yank_gem(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(String) }
      def tomb_file_path(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def tomb_exists?(gem_name, version); end

      # A directory is not a gem; a .gem file in it is. Yanking the last .gem
      # leaves the directory behind, and listing it would make /names announce
      # a gem whose /info/ answers 404.
      sig { returns(T::Array[String]) }
      def gem_names; end

      # A directory listing per gem in the corpus; every whole-index endpoint
      # starts here.
      sig { returns(T::Array[[String, String]]) }
      def gem_versions; end

      # _@param_ `gem_name`
      # 
      # _@return_ — version columns
      sig { params(gem_name: String).returns(T::Array[String]) }
      def versions_for_gem(gem_name); end

      # `version` is a version column, so this is byte for byte the filename
      # Gem::Specification#file_name would have produced.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(String) }
      def gem_file_path(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T::Boolean) }
      def gem_exists?(gem_name, version); end

      # Opening a .gem to read its spec means a tar walk, a gunzip and a YAML
      # parse — the single most expensive thing this repository does per gem,
      # and what the sidecar cache exists to avoid.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(Gem::Specification)) }
      def gem_spec(gem_name, version); end

      # The publication date out of the sidecar when one is there, and out of
      # the gem itself when it is not — same answer either way.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(T.nilable(Time)) }
      def published_at(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — runtime dependencies only
      sig { params(gem_name: String, version: String).returns(T::Array[T::Hash[Symbol, String]]) }
      def gem_dependencies(gem_name, version); end

      # _@param_ `gem_name`
      # 
      # _@return_ — one compact index line per version
      sig { params(gem_name: String).returns(T::Array[String]) }
      def compact_info(gem_name); end

      # A .gem file at a given path never changes, so what compact_info
      # derives from one is derived once and kept in a JSON file next to it —
      # without this, /versions paid a tar walk and YAML parse per version.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      sig { params(gem_name: String, version: String).returns(String) }
      def sidecar_path(gem_name, version); end

      # The cached fields, or nil for anything short of a usable entry — nil
      # just means the gem gets parsed again.
      # 
      # _@param_ `gem_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `stat`
      sig { params(gem_name: String, version: String, stat: File::Stat).returns(T.nilable(T::Hash[String, Object])) }
      def read_sidecar(gem_name, version, stat); end

      sig do
        params(
          gem_name: T.untyped,
          version: T.untyped,
          gem_file: T.untyped,
          stat: T.untyped
        ).returns(T.nilable(T::Hash[String, Object]))
      end
      def derive_sidecar(gem_name, version, gem_file, stat); end

      sig do
        params(
          gem_name: T.untyped,
          version: T.untyped,
          gem_file: T.untyped,
          stat: T.untyped
        ).returns(T.nilable(T::Hash[String, Object]))
      end
      def derive_sidecar_fields(gem_name, version, gem_file, stat); end

      # Tempfile-and-rename, so a reader never sees a torn write; no locking,
      # since two racing writers derived the same bytes. The cache is an
      # optimization — on a read-only directory the rescue eats every write.
      sig { params(gem_name: T.untyped, version: T.untyped, fields: T.untyped).void }
      def write_sidecar(gem_name, version, fields); end

      # An integer rather than a Float on purpose: the guard is an
      # exact-equality check, and integers survive a trip through JSON.
      # 
      # _@param_ `stat`
      sig { params(stat: File::Stat).returns(Integer) }
      def mtime_ns(stat); end

      # Raised on a push of a name+version+platform already on disk.
      class GemAlreadyExists < StandardError
      end

      # Raised when a payload cannot be read as a gem, or its spec claims
      # something a server should not act on.
      class InvalidGem < StandardError
      end

      # Raised on a yank of a gem that is not there.
      class GemNotFound < StandardError
      end

      # Raised on a push of a tombed name+version+platform.
      class GemYanked < StandardError
      end
    end
  end

  # The Rack app a browser gets at the root of a registry — the default for
  # the `placeholder_app:` keyword both servers take. Swap in any Rack app to
  # get your own root. The blurb is HTML-escaped on the way in: a caller
  # wanting markup is a caller wanting their own index app.
  class IndexPage
    TEMPLATE_PATH = T.let(File.join(__dir__, "index_page", "page.html"), T.untyped)
    MASTHEAD_PATH = T.let(File.join(__dir__, "index_page", "masthead.svg"), T.untyped)
    XML_DECLARATION = T.let(/\A<\?xml[^>]{0,255}\?>\s*/, T.untyped)

    # Read once per process rather than once per request: the root is what
    # every uptime check hits.
    sig { returns(String) }
    def self.template; end

    # _@return_ — the masthead SVG, prepared for inlining into HTML
    sig { returns(String) }
    def self.masthead; end

    # _@param_ `blurb` — one sentence describing the registry
    # 
    # _@param_ `title`
    sig { params(blurb: String, title: String).void }
    def initialize(blurb, title: "Paquette"); end

    # _@param_ `_env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(_env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(_env); end

    # The rendered page, built once at construction. Public because it is the
    # useful half for anyone wrapping this in their own Rack response.
    sig { returns(String) }
    def render; end

    sig { returns(String) }
    attr_reader :blurb

    sig { returns(String) }
    attr_reader :title
  end

  # Rack app serving an npm registry — packuments, tarballs, dist-tags,
  # publish and unpublish — over any NpmRepository stack.
  class NpmServer
    include Paquette::RegexpTimeout
    include Paquette::ConditionalGet
    SCOPED_PATH = T.let(%r{\A(/(?:-/package/)?)(@[^/%]+)/([^/]+)(/.*)?\z}, T.untyped)
    DEFAULT_BLURB = T.let("This server provides npm packages. Point your registry at it and install as usual.", T.untyped)
    GatedNpmRepository = T.let(Paquette::NpmServer::ReadGatedRepository, T.untyped)

    # What a request would dispatch to, without dispatching it — the npm twin
    # of GemServer.route_for. The scoped-name normalization is applied first,
    # so a package_name param comes back in one spelling ("@scope/name")
    # whichever way npm sent it. Only the path is read.
    # 
    # _@param_ `env` — the Rack env
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(Paquette::Routes::Recognition)) }
    def self.route_for(env); end

    # npm sends the scope separator percent-encoded for metadata but plain in
    # tarball URLs; normalizing makes a package name one path segment.
    # 
    # _@param_ `path`
    sig { params(path: String).returns(String) }
    def self.normalize_scoped_path(path); end

    # An OtpGate that reads and refuses the way npm does — see the gem-side
    # twin.
    # 
    # _@param_ `secret`
    # 
    # _@param_ `issuer`
    # 
    # _@param_ `drift`
    sig { params(secret: String, issuer: String, drift: Integer).returns(Paquette::OtpGate) }
    def self.otp_gate(secret:, issuer:, drift: 30); end

    # "helpers-1.0.0.tgz" under "@stanquette/helpers" is version "1.0.0".
    # Strips a prefix and a suffix rather than matching: a name interpolated
    # into a regexp raised out of the compile on invalid UTF-8.
    # 
    # _@param_ `package_name`
    # 
    # _@param_ `tarball_name`
    sig { params(package_name: String, tarball_name: String).returns(T.nilable(String)) }
    def self.version_from_tarball_name(package_name, tarball_name); end

    # _@param_ `repository` — the repository stack to serve, or a directory path to wrap in a DirectoryNpmRepository
    # 
    # _@param_ `placeholder_app` — the Rack app answering the root path
    # 
    # _@param_ `max_push_bytes` — the largest request body this server will read — a publish carries the whole tarball base64-encoded in JSON, so this is the push cap; nil removes it, which is a decision to make knowingly
    # 
    # _@param_ `shared_caching` — false keeps every response `private` — see the same option on GemServer
    sig do
      params(
        repository: T.any(Paquette::NpmServer::NpmRepository, String),
        placeholder_app: T.untyped,
        max_push_bytes: T.nilable(Integer),
        shared_caching: T::Boolean
      ).void
    end
    def initialize(repository, placeholder_app: Paquette::IndexPage.new(DEFAULT_BLURB, title: "Paquette npm registry"), max_push_bytes: Paquette::MAX_PUSH_SIZE_BYTES, shared_caching: true); end

    # _@param_ `env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(env); end

    # _@param_ `env`
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def dispatch(env); end

    # _@param_ `path`
    sig { params(path: String).returns(String) }
    def normalize_scoped_path(path); end

    # The hot read path for `npm install`. The validator folds in the
    # request's base URL because absolutize_tarballs rewrites every
    # dist.tarball from it — scheme, unlike host, is not part of an HTTP
    # cache key.
    # 
    # _@param_ `package_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String).returns(T::Array[T.untyped]) }
    def handle_metadata(package_name); end

    # dist-tags move without any path moving — the file is rewritten in
    # place — which the repository fingerprint accounts for by folding in
    # that file's mtime.
    # 
    # _@param_ `package_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String).returns(T::Array[T.untyped]) }
    def handle_dist_tags(package_name); end

    # _@param_ `package_name`
    # 
    # _@param_ `tarball_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String, tarball_name: String).returns(T::Array[T.untyped]) }
    def handle_tarball(package_name, tarball_name); end

    # The very value the packument publishes as dist.integrity, so a
    # download ETag can never disagree with the document that sent npm here —
    # npm hard-fails an install when those two disagree.
    sig do
      params(
        package_name: T.untyped,
        version: T.untyped,
        path: T.untyped,
        stat: T.untyped
      ).returns(String)
    end
    def tarball_etag(package_name, version, path, stat); end

    # _@param_ `package_name`
    # 
    # _@param_ `version`
    sig { params(package_name: String, version: String).returns(T.nilable(String)) }
    def dist_integrity(package_name, version); end

    # The base absolutize_tarballs will build its URLs from — the same
    # expression, kept in one place so the validator and the document cannot
    # disagree about what went into the body.
    sig { returns(String) }
    def metadata_base_url; end

    # Only the `_attachments` tarball is used; the rest is derived from it.
    # 
    # _@param_ `package_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String).returns(T::Array[T.untyped]) }
    def handle_publish(package_name); end

    # _@param_ `package_name`
    # 
    # _@param_ `document`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String, document: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T::Array[T.untyped]) }
    def handle_document_put(package_name, document = nil); end

    # _@param_ `package_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String).returns(T::Array[T.untyped]) }
    def handle_unpublish_all(package_name); end

    # The preceding document PUT usually removed the version, so missing is success.
    # 
    # _@param_ `package_name`
    # 
    # _@param_ `tarball_name`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String, tarball_name: String).returns(T::Array[T.untyped]) }
    def handle_unpublish_version(package_name, tarball_name); end

    # _@param_ `package_name`
    # 
    # _@param_ `tag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(package_name: String, tag: String).returns(T::Array[T.untyped]) }
    def handle_dist_tag_put(package_name, tag); end

    # _@param_ `package_name`
    # 
    # _@param_ `tarball_name`
    sig { params(package_name: String, tarball_name: String).returns(T.nilable(String)) }
    def version_from_tarball_name(package_name, tarball_name); end

    # _@param_ `metadata`
    sig { params(metadata: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def with_absolute_tarballs(metadata); end

    # The forwarded headers keep the URLs correct behind a TLS proxy.
    # SCRIPT_NAME keeps them correct under a mount: a registry served at
    # /@acme must hand out tarball URLs that still say /@acme.
    # 
    # _@param_ `metadata`
    sig { params(metadata: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def absolutize_tarballs(metadata); end

    # npm's unpublish flow needs a `_rev`; derived, since nothing is locked.
    # 
    # _@param_ `package_name`
    sig { params(package_name: String).returns(String) }
    def revision_for(package_name); end

    # A publish body carries the whole tarball base64-encoded, so the cap is
    # enforced on the read itself. Two guards, as on the gem side: the
    # declared length refuses an announced oversize for free, and the read
    # stops one byte past the cap for the body that declared nothing.
    sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def parse_json_body; end

    # nil when the client did not announce one — not an error on its own, it
    # only means the capped read has to do the work.
    sig { returns(T.nilable(Integer)) }
    def declared_content_length; end

    sig { returns(String) }
    def username; end

    # A package document with many versions is the largest thing this server
    # serializes, and it is serialized on every metadata request.
    # 
    # _@param_ `data`
    # 
    # _@param_ `status`
    # 
    # _@return_ — a Rack response triplet
    sig { params(data: Object, status: Integer).returns(T::Array[T.untyped]) }
    def json_ok(data, status: 200); end

    # _@param_ `data`
    # 
    # _@return_ — a Rack response triplet
    sig { params(data: String).returns(T::Array[T.untyped]) }
    def text_ok(data); end

    # npm surfaces the `error` key of a JSON body to the user.
    # 
    # _@param_ `status`
    # 
    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(status: Integer, message: String).returns(T::Array[T.untyped]) }
    def json_error(status, message); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def not_found(message = "Not Found"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def bad_request(message = "Bad Request"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def forbidden(message = "Forbidden"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def conflict(message = "Conflict"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def payload_too_large(message = "Payload Too Large"); end

    # _@param_ `message`
    # 
    # _@return_ — a Rack response triplet
    sig { params(message: String).returns(T::Array[T.untyped]) }
    def server_error(message = "Internal Server Error"); end

    # The validator for one response. nil (no ETag at all) when the stack
    # refuses to name itself: a wrong ETag on a gated index is worse than
    # serving every request in full.
    # 
    # _@param_ `resource_parts` — what distinguishes this endpoint's body from another's over the same corpus
    # 
    # _@param_ `weak`
    sig { params(resource_parts: T::Array[String], weak: T::Boolean).returns(T.nilable(String)) }
    def etag_for(*resource_parts, weak: false); end

    # `public` only when the embedder allowed shared caching, the request
    # carried no credential and nothing in the stack varies by caller —
    # getting this wrong serves one caller's view to the next. `no-cache`
    # rather than `no-store` so the 304 stays reachable.
    # 
    # _@param_ `max_age`
    sig { params(max_age: T.nilable(Integer)).returns(T::Hash[String, String]) }
    def cache_directives(max_age: nil); end

    sig { returns(T::Boolean) }
    def shareable_response?; end

    # Not sufficient on its own — several CDNs ignore Vary on anything but
    # Accept-Encoding; `private` is what actually stands between two callers.
    sig { returns(String) }
    def vary_header; end

    # What every response leaving either server goes through. Anything a
    # handler did not label is `private, no-store`: it carries no validator,
    # so nothing could revalidate it.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def with_caching_defaults(response); end

    # _@param_ `vary` — the Vary already on the response
    # 
    # _@return_ — that Vary with Authorization merged in
    sig { params(vary: T.nilable(String)).returns(String) }
    def vary_with_authorization(vary); end

    # A 200 with the validator and the caching directives attached. An absent
    # etag (fail-closed) still gets the directives: the response is then
    # simply uncacheable-without-asking rather than mislabelled.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable(response, etag); end

    # `cacheable` plus ranges — what makes Bundler >= 2.5 fetch the compact
    # index incrementally. `Repr-Digest` carries the digest of the *whole*
    # representation even on a 206 (RFC 9530), or Bundler will not append;
    # `Digest:` is the obsolete RFC 3230 spelling some intermediaries read.
    # 
    # _@param_ `response` — a Rack response triplet, body already in hand
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable_with_ranges(response, etag); end

    # The single byte range this request asks for, or nil for "serve the
    # whole thing" — never a 416, which would turn a Bundler that merely
    # guessed the tail wrong into a failed install. Called after the
    # conditional check: a matching If-None-Match is a 304, not a 206.
    # 
    # _@param_ `size` — the body size in bytes
    # 
    # _@param_ `etag`
    sig { params(size: Integer, etag: T.nilable(String)).returns(T.nilable(T::Range[T.untyped])) }
    def requested_byte_range(size, etag); end

    # Absent, If-Range allows the range. Present, only a strong tag equal to
    # ours does: a weak validator says nothing about byte offsets, and a date
    # says nothing about a body that is not a file.
    # 
    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_range_allows_range?(etag); end

    # Parses `bytes=first-last`, with either side optionally empty, and
    # nothing else. String operations rather than a pattern over the whole
    # header, per AGENTS.md.
    # 
    # _@param_ `header`
    # 
    # _@param_ `size`
    sig { params(header: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def parse_byte_range(header, size); end

    # `bytes=-N` asks for the final N bytes. A bare `bytes=-` names no number
    # and `bytes=-0` asks for nothing; neither is satisfiable, so both get the
    # whole body.
    # 
    # _@param_ `last`
    # 
    # _@param_ `size`
    sig { params(last: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def suffix_byte_range(last, size); end

    # A 304 repeats the validator and the directives — a shared cache
    # updates its stored headers from it.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `extra` — extra headers
    # 
    # _@return_ — a Rack response triplet
    sig { params(etag: T.nilable(String), extra: T::Hash[String, String]).returns(T::Array[T.untyped]) }
    def not_modified(etag, extra: {}); end

    # A response that must never be stored by anything, for content that is
    # the caller's identity itself.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def uncacheable(response); end

    # If-None-Match wins over If-Modified-Since when both are present, which
    # is what RFC 9110 requires.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `mtime`
    sig { params(etag: T.nilable(String), mtime: Time).returns(T.nilable(T::Boolean)) }
    def conditional_hit?(etag, mtime); end

    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_none_match_satisfied?(etag); end

    # Weak comparison, which is what If-None-Match on a GET calls for: a
    # W/"x" a client holds matches the "x" we would send. String operations
    # rather than a regexp because the value is client-chosen and arbitrarily
    # long (see AGENTS.md).
    # 
    # _@param_ `value`
    sig { params(value: String).returns(String) }
    def opaque_tag(value); end

    # An unparseable date is not a match; second resolution is all an HTTP
    # date has.
    # 
    # _@param_ `mtime`
    sig { params(mtime: Time).returns(T::Boolean) }
    def if_modified_since_satisfied?(mtime); end

    # Rack::Files, so the range machinery is Rack's rather than ours. A nil
    # root: #serving takes an absolute path and never reads @root, and the
    # path is the repository's to decide.
    sig { returns(Rack::Files) }
    def package_file_server; end

    # Serves one immutable artifact off disk — a .gem or .tgz at a given
    # path never changes; yank and unpublish rename away.
    # 
    # _@param_ `path` — absolute path of the file
    # 
    # _@param_ `stat`
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(path: String, stat: File::Stat, etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def serve_immutable_file(path, stat, etag); end

    # The request as Rack::Files should see it: If-Modified-Since comes out
    # because we already answered it (Rack::Files would 304 bare, dropping
    # ETag and Cache-Control), and If-Range is answered here by dropping the
    # Range header, because Rack::Files does not implement it at all.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(etag: T.nilable(String), stat: File::Stat).returns(Rack::Request) }
    def rack_files_request(etag, stat); end

    # An If-Range carries either an entity tag or an HTTP date. A tag is
    # compared strongly — a weak validator says nothing about byte offsets,
    # which is the only thing this comparison is for.
    # 
    # _@param_ `if_range`
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(if_range: String, etag: T.nilable(String), stat: File::Stat).returns(T::Boolean) }
    def if_range_matches?(if_range, etag, stat); end

    # A request body past `max_push_bytes:`, answered 413 before the JSON
    # parse — and before most of the read.
    class PayloadTooLarge < StandardError
    end

    # How npm speaks OTP: the code arrives in the `npm-otp` header (plain
    # `OTP` accepted as a curl fallback), and a refusal is a 401 challenge —
    # `www-authenticate: OTP` plus "one-time pass" in the body — so npm
    # prompts for a fresh code instead of reporting a failed login.
    module OtpDialect
      # _@param_ `env` — the Rack env
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
      def code_in(env); end

      # _@param_ `env` — the Rack env
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
      def self.code_in(env); end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def otp_missing; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def self.otp_missing; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def otp_rejected; end

      # _@return_ — a Rack response triplet
      sig { returns(T::Array[T.untyped]) }
      def self.otp_rejected; end

      # _@param_ `message`
      # 
      # _@return_ — a Rack response triplet
      sig { params(message: String).returns(T::Array[T.untyped]) }
      def challenge(message); end

      # _@param_ `message`
      # 
      # _@return_ — a Rack response triplet
      sig { params(message: String).returns(T::Array[T.untyped]) }
      def self.challenge(message); end
    end

    # Rewrites each served tarball on the fly to embed the licensee's key;
    # counterpart of GemServer::Personalizer.
    class Personalizer < SimpleDelegator
      # The caller keeps the two contracts spelled out on
      # GemServer::Personalizer: what `files_for:` returns depends only on the
      # tarball and `personalization_key:`, and nil is a fact about the
      # package, never about the licensee.
      # 
      # _@param_ `repository` — the repository to wrap
      # 
      # _@param_ `license_key`
      # 
      # _@param_ `magic_comment_replacements` — checked here as well as in the repacker, so a bad pair is refused where the stack is built rather than on the first customer download
      # 
      # _@param_ `files` — files injected into every tarball
      # 
      # _@param_ `package_json_extras` — merged into package.json; defaults to a "paquette" key carrying the license key
      # 
      # _@param_ `files_for` — per-package files, called with (package_name, version, original_path); nil return means the package is served byte for byte
      # 
      # _@param_ `personalization_key` — everything the personalized bytes depend on beyond the tarball itself
      # 
      # _@param_ `cache_dir` — where personalized tarballs and opt-out markers are kept; the system temp directory is only a default
      sig do
        params(
          repository: Paquette::NpmServer::NpmRepository,
          license_key: String,
          magic_comment_replacements: T::Hash[String, String],
          files: T::Hash[String, String],
          package_json_extras: T.nilable(T::Hash[T.untyped, T.untyped]),
          files_for: T.nilable(Proc),
          personalization_key: T.nilable(String),
          cache_dir: T.nilable(String)
        ).void
      end
      def initialize(repository, license_key:, magic_comment_replacements: {}, files: {}, package_json_extras: nil, files_for: nil, personalization_key: nil, cache_dir: nil); end

      # The wrapped validator with this personalizer's identity mixed in — the
      # packument carries per-licensee integrity hashes in the document
      # itself. The key is the same digest that names the cached tarballs on
      # disk, so the validator is exactly as strong as that cache.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # Every byte — and every dist.integrity — is baked for one licensee.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the personalized (or pass-through) tarball path
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def package_file_path(package_name, version); end

      # The hashes must be the personalized tarball's; the URL stays the repository's.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Hash[String, String]) }
      def dist_for(package_name, version); end

      # The underlying `dist` hashes would fail every install. Every version
      # has to be repacked and re-hashed before this document can be handed
      # out, so a personalized metadata read costs a whole package where the
      # plain one costs a cache lookup.
      # 
      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_metadata(package_name); end

      # Keyed by everything that goes INTO the package: two licensees never
      # share a file. See GemServer::Personalizer, whose scheme this is.
      # 
      # _@param_ `original_path`
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(original_path: String, package_name: String, version: String).returns(String) }
      def personalize(original_path, package_name, version); end

      # The FULL package name — basename keying once served one scope's code as
      # another's. Stat identity, so a replaced tarball invalidates the cache
      # without re-hashing the corpus.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `stat`
      sig { params(package_name: String, version: String, stat: File::Stat).returns(String) }
      def cache_digest(package_name, version, stat); end

      # Where "this package carries nothing to personalize" is written down.
      # Keyed by the package and its source identity alone, never by the
      # licensee — whether a package participates is a fact about the package.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `stat`
      sig { params(package_name: String, version: String, stat: File::Stat).returns(String) }
      def plain_marker_path(package_name, version, stat); end

      # Stable across processes, so a restart does not orphan the cache.
      sig { returns(String) }
      def personalization_digest; end
    end

    # Abstract base class for NPM package repositories; mirrors GemRepository.
    class NpmRepository
      SEGMENT = T.let(/\A[a-z0-9][a-z0-9._-]*\z/, T.untyped)
      VERSION = T.let(/\A[0-9][0-9A-Za-z.+-]{0,63}\z/, T.untyped)

      sig { void }
      def initialize; end

      sig { returns(T::Array[String]) }
      def package_names; end

      # _@return_ — [name, version] pairs
      sig { returns(T::Array[[String, String]]) }
      def package_versions; end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Array[String]) }
      def versions_for_package(package_name); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the path of the .tgz file
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def package_file_path(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Boolean) }
      def package_exists?(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@return_ — the version's package.json document
      sig { params(package_name: String, version: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_info(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Hash[String, String]) }
      def package_dependencies(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@return_ — the packument
      sig { params(package_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_metadata(package_name); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Hash[String, String]) }
      def dist_tags(package_name); end

      # A short string that changes whenever anything this repository would
      # serve changes, or nil for "do not cache this". A packument replayed to
      # the wrong licensee carries integrity hashes that cannot match the
      # tarball they download — npm treats that as tampering.
      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # Whether two callers can get different answers out of this repository —
      # true is the safe default; see GemRepository#varies_by_caller?.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      # _@param_ `binary_data` — the tarball bytes
      # 
      # _@param_ `dist_tags`
      # 
      # _@return_ — the stored version's info
      sig { params(binary_data: String, dist_tags: T::Hash[String, String]).returns(T::Hash[T.untyped, T.untyped]) }
      def add_package(binary_data, dist_tags: {}); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).void }
      def yank_package(package_name, version); end

      # The registry-convention shape; lockfiles record it verbatim.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(String) }
      def self.tarball_path(package_name, version); end

      # Drops the scope: a scoped package lives in a directory named for it.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(String) }
      def self.tarball_filename(package_name, version); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Boolean) }
      def self.scoped?(package_name); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Boolean) }
      def self.valid_package_name?(package_name); end

      # _@param_ `version`
      sig { params(version: String).returns(T::Boolean) }
      def self.valid_version?(version); end

      # Not Gem::Version: it mangles prereleases and rejects "+build" metadata.
      # 
      # _@param_ `versions`
      sig { params(versions: T::Array[String]).returns(T::Array[String]) }
      def self.sort_versions(versions); end

      # _@param_ `versions`
      sig { params(versions: T::Array[String]).returns(T.nilable(String)) }
      def self.max_version(versions); end

      # _@param_ `version`
      sig { params(version: String).returns(T::Boolean) }
      def self.prerelease?(version); end

      # Newest stable release, or plain installs would get prereleases.
      # 
      # _@param_ `versions`
      sig { params(versions: T::Array[String]).returns(T.nilable(String)) }
      def self.max_release_version(versions); end

      # Semver: a prerelease sorts *below* the same version without one.
      # 
      # _@param_ `a`
      # 
      # _@param_ `b`
      sig { params(a: String, b: String).returns(Integer) }
      def self.compare_versions(a, b); end

      # _@param_ `version`
      # 
      # _@return_ — release segments and
      # prerelease identifiers
      sig { params(version: String).returns([T::Array[Integer], T::Array[String]]) }
      def self.split_version(version); end

      # _@param_ `a`
      # 
      # _@param_ `b`
      sig { params(a: T::Array[String], b: T::Array[String]).returns(Integer) }
      def self.compare_prerelease(a, b); end

      # Passed through whole: a curated subset breaks whichever field it forgot.
      # 
      # _@param_ `package_json`
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      # 
      # _@param_ `dist`
      sig do
        params(
          package_json: T::Hash[T.untyped, T.untyped],
          package_name: String,
          version: String,
          dist: T::Hash[T.untyped, T.untyped]
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def self.version_doc(package_json, package_name, version, dist); end
    end

    # Filters every read through an entitler block; non-entitled packages do
    # not exist. Writes always raise: a gated caller may not mutate the corpus.
    class ReadGatedRepository < SimpleDelegator
      # _@param_ `repository` — the repository to wrap
      # 
      # _@param_ `gate_key` — names this gate for HTTP caching — see the gem-side ReadGatedRepository for the full contract: name the identity the entitler consults and everything the answers depend on, or leave it out and the whole stack emits no ETag (the intended fail-closed default — a wrong ETag on a gated packument is one customer holding another's entitlements).
      sig { params(repository: Paquette::NpmServer::NpmRepository, gate_key: T.nilable(String), entitler: T.untyped).void }
      def initialize(repository, gate_key: nil, &entitler); end

      sig { returns(T.nilable(String)) }
      def cache_validator; end

      # A gate may decide by something Paquette never sees — an IP, a header —
      # so even two anonymous callers can get different views. Never `public`.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      sig { returns(T::Array[String]) }
      def package_names; end

      sig { returns(T::Array[[String, String]]) }
      def package_versions; end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Array[String]) }
      def versions_for_package(package_name); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def package_file_path(package_name, version); end

      # false rather than nil: callers treat this as a boolean.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Boolean) }
      def package_exists?(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_info(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Hash[String, String]) }
      def package_dependencies(package_name, version); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Hash[String, String]) }
      def dist_tags(package_name); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_metadata(package_name); end

      # Recomputed so created/modified do not leak withheld publication dates.
      # 
      # _@param_ `times`
      # 
      # _@param_ `entitled`
      sig { params(times: T.nilable(T::Hash[T.untyped, T.untyped]), entitled: T::Array[String]).returns(T::Hash[String, String]) }
      def entitled_times(times, entitled); end

      # The entitler is the caller's, and a listing calls it once per package
      # in the corpus — an entitler that reaches for a database on every call
      # is the usual reason a gated index is slower than an ungated one.
      # 
      # _@param_ `criteria`
      # 
      # _@return_ — truthy when entitled
      sig { params(criteria: T::Hash[T.untyped, T.untyped]).returns(Object) }
      def entitled?(**criteria); end

      sig { returns(T.untyped) }
      def add_package; end

      sig { returns(T.untyped) }
      def yank_package; end

      sig { returns(T.untyped) }
      def write_dist_tag; end

      # Raised by every write on a gated repository.
      class WriteNotAllowed < StandardError
      end
    end

    # Reads NPM packages from a directory; a scope is an ordinary directory:
    #   packages/npm/@acme/widgets/widgets-1.0.0.tgz
    class DirectoryNpmRepository < Paquette::NpmServer::NpmRepository
      DIST_TAGS_FILE = T.let("dist-tags.json", T.untyped)
      SEGMENT = T.let(/\A[a-z0-9][a-z0-9._-]*\z/, T.untyped)
      VERSION = T.let(/\A[0-9][0-9A-Za-z.+-]{0,63}\z/, T.untyped)

      # _@param_ `packages_dir` — the corpus root, created if absent
      sig { params(packages_dir: String).void }
      def initialize(packages_dir); end

      # A digest of what the corpus holds — see the gem-side twin. Tarball
      # paths carry publishes and unpublishes, but a dist-tag write edits
      # dist-tags.json in place: no path moves, so the write shows only in the
      # file's own mtime.
      sig { returns(String) }
      def fingerprint; end

      # Whole nanoseconds rather than a Float, which loses precision at the top
      # of the range: two dist-tag writes landing inside one float tick would
      # digest identically — a client keeping a 304 for a tag that has moved.
      # 
      # _@param_ `path`
      sig { params(path: String).returns(Integer) }
      def mtime_ns(path); end

      sig { returns(String) }
      def cache_validator; end

      # A directory of packages is the same directory for everybody; the
      # wrappers are what make a response caller-specific.
      sig { returns(T::Boolean) }
      def varies_by_caller?; end

      sig { returns(T::Array[String]) }
      def package_names; end

      # A directory listing per package in the corpus.
      sig { returns(T::Array[[String, String]]) }
      def package_versions; end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Array[String]) }
      def versions_for_package(package_name); end

      # nil rather than a path for anything that is not a name and a version —
      # the version is a path component too, and checking it only on the
      # publish path would leave the read path free to compose "1/../../secret".
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def package_file_path(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Boolean) }
      def package_exists?(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_info(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Hash[String, String]) }
      def package_dependencies(package_name, version); end

      # "latest" is recomputed from disk: a stored tag can outlive its version.
      # 
      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Hash[String, String]) }
      def dist_tags(package_name); end

      # Assembling this means reading the package.json out of every version's
      # tarball and hashing every one of them; the cache below is what keeps a
      # second request from paying for it again.
      # 
      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def package_metadata(package_name); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def build_metadata(package_name); end

      # Hashes are computed from the file, never taken from the publisher.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Hash[String, String]) }
      def dist_for(package_name, version); end

      # A republished version must never silently carry different bytes.
      # 
      # _@param_ `binary_data` — the tarball bytes
      # 
      # _@param_ `dist_tags`
      # 
      # _@return_ — the stored version's package.json
      sig { params(binary_data: String, dist_tags: T::Hash[String, String]).returns(T::Hash[T.untyped, T.untyped]) }
      def add_package(binary_data, dist_tags: {}); end

      # The tomb stops the version being republished with different contents.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).void }
      def yank_package(package_name, version); end

      # "latest" follows the newest release on disk; pointing it elsewhere is refused.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `tag`
      # 
      # _@param_ `version`
      sig { params(package_name: String, tag: String, version: String).returns(T::Hash[String, String]) }
      def write_dist_tag(package_name, tag, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def tomb_file_path(package_name, version); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T::Boolean) }
      def tomb_exists?(package_name, version); end

      # nil for a non-name, so "../../etc" resolves to no package, not a path.
      # 
      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(String)) }
      def package_dir(package_name); end

      # _@param_ `dir`
      sig { params(dir: String, blk: T.proc.params(path: String, basename: String).void).void }
      def each_child_dir(dir, &blk); end

      # mtimes, unlike Time.now, keep the document stable between requests.
      # 
      # _@param_ `package_name`
      # 
      # _@param_ `versions`
      sig { params(package_name: String, versions: T::Array[String]).returns(T::Hash[String, String]) }
      def times_for(package_name, versions); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).returns(T.nilable(String)) }
      def readme_for(package_name, version); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T.nilable(String)) }
      def dist_tags_path(package_name); end

      # _@param_ `package_name`
      sig { params(package_name: String).returns(T::Hash[String, String]) }
      def read_dist_tags(package_name); end

      # _@param_ `package_name`
      # 
      # _@param_ `tags`
      sig { params(package_name: String, tags: T::Hash[String, String]).void }
      def write_dist_tags(package_name, tags); end

      # _@param_ `package_name`
      # 
      # _@param_ `version`
      sig { params(package_name: String, version: String).void }
      def drop_dist_tags_for(package_name, version); end

      # Keyed on mtime + size so a replaced tarball is not served stale.
      # 
      # _@param_ `path`
      # 
      # _@param_ `aspect`
      # 
      # _@return_ — the cached block result
      sig { params(path: String, aspect: Symbol).returns(Object) }
      def cached(path, aspect = :info); end

      # Raised on a publish of a name@version already on disk.
      class PackageAlreadyExists < StandardError
      end

      # Raised when a payload cannot be read as a package, or its
      # package.json claims something a server should not act on.
      class InvalidPackage < StandardError
      end

      # Raised on an unpublish of a package that is not there.
      class PackageNotFound < StandardError
      end

      # Raised on a publish of a tombed name@version.
      class PackageYanked < StandardError
      end
    end
  end

  # Rewrites the contents of an npm tarball into a new one; counterpart of
  # GemServer::GemRepacker, with `package_json_extras:` for `gemspec_extras`.
  # Byte-reproducible — see Paquette::Tarball for why that is load-bearing.
  class NpmRepacker
    SOURCE_EXTENSIONS = T.let(%w[.js .mjs .cjs .jsx .ts .tsx .mts .cts].freeze, T.untyped)

    # One line in, one line out — the rule the whole personalization scheme
    # rests on (a changed line count shifts every sourcemap mapping below it),
    # so a pair that cannot honour it is refused rather than bent to fit.
    # 
    # _@param_ `replacements`
    sig { params(replacements: T::Hash[String, String]).void }
    def self.check_replacements!(replacements); end

    # One-shot convenience for {#initialize} + {#repack}.
    # 
    # _@param_ `npm_path`
    # 
    # _@param_ `package_json_extras`
    # 
    # _@param_ `magic_comment_replacements`
    # 
    # _@param_ `files`
    # 
    # _@param_ `into`
    # 
    # _@return_ — the path of the repacked tarball
    sig do
      params(
        npm_path: String,
        package_json_extras: T::Hash[String, Object],
        magic_comment_replacements: T::Hash[String, String],
        files: T::Hash[String, String],
        into: T.nilable(String),
        block: T.untyped
      ).returns(String)
    end
    def self.repack(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block); end

    # _@param_ `npm_path` — path of the source tarball
    # 
    # _@param_ `package_json_extras` — keys merged into package.json
    # 
    # _@param_ `magic_comment_replacements` — whole comment lines to replace, marker => replacement
    # 
    # _@param_ `files` — files to inject, path relative to the package root => content
    # 
    # _@param_ `into` — destination path; a tmpdir when nil
    sig do
      params(
        npm_path: String,
        package_json_extras: T::Hash[String, Object],
        magic_comment_replacements: T::Hash[String, String],
        files: T::Hash[String, String],
        into: T.nilable(String)
      ).void
    end
    def initialize(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil); end

    # _@return_ — the path of the repacked tarball
    sig { params(block: T.proc.params(input: StringIO, output: StringIO, relative_path: String).void).returns(String) }
    def repack(&block); end

    sig { returns(String) }
    def destination; end

    # _@param_ `entry`
    # 
    # _@param_ `root`
    sig { params(entry: Paquette::Tarball::Entry, root: String, block: T.untyped).returns(Paquette::Tarball::Entry) }
    def rewrite(entry, root, &block); end

    # _@param_ `relative_path`
    sig { params(relative_path: String).returns(T::Boolean) }
    def replaceable?(relative_path); end

    # A whole comment line is replaced by a whole comment line: sourcemaps
    # restart their column counter at every line, so rewriting one line cannot
    # disturb the mappings on any other.
    # 
    # _@param_ `content`
    # 
    # _@param_ `relative_path`
    sig { params(content: String, relative_path: String).returns(String) }
    def apply_magic_comment_replacements(content, relative_path); end

    # A marker still present after the pass was one the line-wise match could
    # not reach — `esbuild --minify` pulls a legal comment onto the end of a
    # code line — and the package would then be served with no license key in
    # it and nothing to say so. Replacing it mid-line instead would shift
    # sourcemap columns, which is exactly what the line-wise rule avoids.
    # 
    # _@param_ `text`
    # 
    # _@param_ `relative_path`
    sig { params(text: String, relative_path: String).void }
    def verify_markers_applied(text, relative_path); end

    # _@param_ `entries`
    # 
    # _@param_ `root`
    sig { params(entries: T::Array[Paquette::Tarball::Entry], root: String).returns(T::Array[Paquette::Tarball::Entry]) }
    def apply_package_json_extras(entries, root); end

    # Injected files inherit the package's oldest mtime, keeping the tarball
    # independent of when they were added.
    # 
    # _@param_ `entries`
    # 
    # _@param_ `root`
    sig { params(entries: T::Array[Paquette::Tarball::Entry], root: String).returns(T::Array[Paquette::Tarball::Entry]) }
    def inject_files(entries, root); end

    # _@param_ `entry`
    # 
    # _@param_ `content`
    sig { params(entry: Paquette::Tarball::Entry, content: String).returns(Paquette::Tarball::Entry) }
    def with_content(entry, content); end

    # Raised when a marker survives the pass — see #verify_markers_applied.
    class MarkerNotApplied < StandardError
    end

    # Raised for a marker or replacement spanning several lines.
    class MultilineReplacement < StandardError
    end
  end

  # Ceiling on any single regexp match, held for the duration of a request —
  # every path here meets a regexp with a client-chosen string on the other
  # side. Prepended into every Rack app in this gem; an application wanting a
  # different ceiling sets `Paquette.regexp_timeout` once, at boot.
  module RegexpTimeout
    SUPPORTED = T.let(Regexp.respond_to?(:timeout=), T.untyped)
    TimedOut = T.let(SUPPORTED ? Regexp::TimeoutError : Class.new(StandardError), T.untyped)

    # Arms the process-wide regexp ceiling for one request.
    sig { void }
    def self.acquire; end

    # Releases one request's hold; the last one out restores the ambient
    # timeout.
    sig { void }
    def self.release; end

    # A 400, not a 500: it ran out of time on bytes the client sent.
    # 
    # _@param_ `error`
    # 
    # _@return_ — a Rack response triplet
    sig { params(error: Exception).returns(T::Array[T.untyped]) }
    def self.timed_out(error); end

    # _@param_ `env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(env); end
  end

  # Conditional GET and cache directives, shared by both servers so the
  # security-critical answers cannot drift between them. The including class
  # supplies `@request` (the Rack::Request being served), `@repository` (the
  # wrapper stack) and `@shared_caching`.
  module ConditionalGet
    IMMUTABLE_MAX_AGE = T.let(31_536_000, T.untyped)
    CREDENTIAL_HEADERS = T.let(%w[HTTP_AUTHORIZATION HTTP_COOKIE].freeze, T.untyped)
    MAX_RANGE_HEADER_BYTES = T.let(128, T.untyped)
    BYTE_OFFSET = T.let(/\A[0-9]{1,19}\z/, T.untyped)

    # The validator for one response. nil (no ETag at all) when the stack
    # refuses to name itself: a wrong ETag on a gated index is worse than
    # serving every request in full.
    # 
    # _@param_ `resource_parts` — what distinguishes this endpoint's body from another's over the same corpus
    # 
    # _@param_ `weak`
    sig { params(resource_parts: T::Array[String], weak: T::Boolean).returns(T.nilable(String)) }
    def etag_for(*resource_parts, weak: false); end

    # `public` only when the embedder allowed shared caching, the request
    # carried no credential and nothing in the stack varies by caller —
    # getting this wrong serves one caller's view to the next. `no-cache`
    # rather than `no-store` so the 304 stays reachable.
    # 
    # _@param_ `max_age`
    sig { params(max_age: T.nilable(Integer)).returns(T::Hash[String, String]) }
    def cache_directives(max_age: nil); end

    sig { returns(T::Boolean) }
    def shareable_response?; end

    # Not sufficient on its own — several CDNs ignore Vary on anything but
    # Accept-Encoding; `private` is what actually stands between two callers.
    sig { returns(String) }
    def vary_header; end

    # What every response leaving either server goes through. Anything a
    # handler did not label is `private, no-store`: it carries no validator,
    # so nothing could revalidate it.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def with_caching_defaults(response); end

    # _@param_ `vary` — the Vary already on the response
    # 
    # _@return_ — that Vary with Authorization merged in
    sig { params(vary: T.nilable(String)).returns(String) }
    def vary_with_authorization(vary); end

    # A 200 with the validator and the caching directives attached. An absent
    # etag (fail-closed) still gets the directives: the response is then
    # simply uncacheable-without-asking rather than mislabelled.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable(response, etag); end

    # `cacheable` plus ranges — what makes Bundler >= 2.5 fetch the compact
    # index incrementally. `Repr-Digest` carries the digest of the *whole*
    # representation even on a 206 (RFC 9530), or Bundler will not append;
    # `Digest:` is the obsolete RFC 3230 spelling some intermediaries read.
    # 
    # _@param_ `response` — a Rack response triplet, body already in hand
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped], etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def cacheable_with_ranges(response, etag); end

    # The single byte range this request asks for, or nil for "serve the
    # whole thing" — never a 416, which would turn a Bundler that merely
    # guessed the tail wrong into a failed install. Called after the
    # conditional check: a matching If-None-Match is a 304, not a 206.
    # 
    # _@param_ `size` — the body size in bytes
    # 
    # _@param_ `etag`
    sig { params(size: Integer, etag: T.nilable(String)).returns(T.nilable(T::Range[T.untyped])) }
    def requested_byte_range(size, etag); end

    # Absent, If-Range allows the range. Present, only a strong tag equal to
    # ours does: a weak validator says nothing about byte offsets, and a date
    # says nothing about a body that is not a file.
    # 
    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_range_allows_range?(etag); end

    # Parses `bytes=first-last`, with either side optionally empty, and
    # nothing else. String operations rather than a pattern over the whole
    # header, per AGENTS.md.
    # 
    # _@param_ `header`
    # 
    # _@param_ `size`
    sig { params(header: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def parse_byte_range(header, size); end

    # `bytes=-N` asks for the final N bytes. A bare `bytes=-` names no number
    # and `bytes=-0` asks for nothing; neither is satisfiable, so both get the
    # whole body.
    # 
    # _@param_ `last`
    # 
    # _@param_ `size`
    sig { params(last: String, size: Integer).returns(T.nilable(T::Range[T.untyped])) }
    def suffix_byte_range(last, size); end

    # A 304 repeats the validator and the directives — a shared cache
    # updates its stored headers from it.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `extra` — extra headers
    # 
    # _@return_ — a Rack response triplet
    sig { params(etag: T.nilable(String), extra: T::Hash[String, String]).returns(T::Array[T.untyped]) }
    def not_modified(etag, extra: {}); end

    # A response that must never be stored by anything, for content that is
    # the caller's identity itself.
    # 
    # _@param_ `response` — a Rack response triplet
    # 
    # _@return_ — a Rack response triplet
    sig { params(response: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def uncacheable(response); end

    # If-None-Match wins over If-Modified-Since when both are present, which
    # is what RFC 9110 requires.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `mtime`
    sig { params(etag: T.nilable(String), mtime: Time).returns(T.nilable(T::Boolean)) }
    def conditional_hit?(etag, mtime); end

    # _@param_ `etag`
    sig { params(etag: T.nilable(String)).returns(T::Boolean) }
    def if_none_match_satisfied?(etag); end

    # Weak comparison, which is what If-None-Match on a GET calls for: a
    # W/"x" a client holds matches the "x" we would send. String operations
    # rather than a regexp because the value is client-chosen and arbitrarily
    # long (see AGENTS.md).
    # 
    # _@param_ `value`
    sig { params(value: String).returns(String) }
    def opaque_tag(value); end

    # An unparseable date is not a match; second resolution is all an HTTP
    # date has.
    # 
    # _@param_ `mtime`
    sig { params(mtime: Time).returns(T::Boolean) }
    def if_modified_since_satisfied?(mtime); end

    # Rack::Files, so the range machinery is Rack's rather than ours. A nil
    # root: #serving takes an absolute path and never reads @root, and the
    # path is the repository's to decide.
    sig { returns(Rack::Files) }
    def package_file_server; end

    # Serves one immutable artifact off disk — a .gem or .tgz at a given
    # path never changes; yank and unpublish rename away.
    # 
    # _@param_ `path` — absolute path of the file
    # 
    # _@param_ `stat`
    # 
    # _@param_ `etag`
    # 
    # _@return_ — a Rack response triplet
    sig { params(path: String, stat: File::Stat, etag: T.nilable(String)).returns(T::Array[T.untyped]) }
    def serve_immutable_file(path, stat, etag); end

    # The request as Rack::Files should see it: If-Modified-Since comes out
    # because we already answered it (Rack::Files would 304 bare, dropping
    # ETag and Cache-Control), and If-Range is answered here by dropping the
    # Range header, because Rack::Files does not implement it at all.
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(etag: T.nilable(String), stat: File::Stat).returns(Rack::Request) }
    def rack_files_request(etag, stat); end

    # An If-Range carries either an entity tag or an HTTP date. A tag is
    # compared strongly — a weak validator says nothing about byte offsets,
    # which is the only thing this comparison is for.
    # 
    # _@param_ `if_range`
    # 
    # _@param_ `etag`
    # 
    # _@param_ `stat`
    sig { params(if_range: String, etag: T.nilable(String), stat: File::Stat).returns(T::Boolean) }
    def if_range_matches?(if_range, etag, stat); end
  end

  # How a repository stack names itself to an HTTP cache. Both servers wrap a
  # base repository in per-caller gates and personalizers, so a validator
  # derived from the corpus alone would let one licensee's cached response
  # satisfy another's — the digest rules live here, once, for both servers.
  module CacheValidation
    # The stack's validator. Fails closed (nil) for an object that has never
    # heard of the protocol.
    # 
    # _@param_ `repository`
    sig { params(repository: Object).returns(T.nilable(String)) }
    def validator_of(repository); end

    # The stack's validator. Fails closed (nil) for an object that has never
    # heard of the protocol.
    # 
    # _@param_ `repository`
    sig { params(repository: Object).returns(T.nilable(String)) }
    def self.validator_of(repository); end

    # Whether two callers asking the stack the same question can get different
    # answers — which decides whether an anonymous response may be `public`.
    # True for anything that cannot say: being wrong the other way only costs
    # a cache hit.
    # 
    # _@param_ `repository`
    sig { params(repository: Object).returns(T::Boolean) }
    def varies_by_caller?(repository); end

    # Whether two callers asking the stack the same question can get different
    # answers — which decides whether an anonymous response may be `public`.
    # True for anything that cannot say: being wrong the other way only costs
    # a cache hit.
    # 
    # _@param_ `repository`
    sig { params(repository: Object).returns(T::Boolean) }
    def self.varies_by_caller?(repository); end

    # How a wrapper mixes itself into the validator of what it wraps. nil in
    # either position gives nil out — the fail-closed rule the whole protocol
    # rests on. The layer name is in the digest so that gating with key "k"
    # and personalizing with key "k" cannot land on the same string.
    # 
    # _@param_ `inner_validator` — the wrapped stack's validator
    # 
    # _@param_ `layer` — a constant naming the wrapping layer
    # 
    # _@param_ `key` — what distinguishes this instance of the layer
    sig { params(inner_validator: T.nilable(String), layer: String, key: T.nilable(String)).returns(T.nilable(String)) }
    def derive_validator(inner_validator, layer, key); end

    # How a wrapper mixes itself into the validator of what it wraps. nil in
    # either position gives nil out — the fail-closed rule the whole protocol
    # rests on. The layer name is in the digest so that gating with key "k"
    # and personalizing with key "k" cannot land on the same string.
    # 
    # _@param_ `inner_validator` — the wrapped stack's validator
    # 
    # _@param_ `layer` — a constant naming the wrapping layer
    # 
    # _@param_ `key` — what distinguishes this instance of the layer
    sig { params(inner_validator: T.nilable(String), layer: String, key: T.nilable(String)).returns(T.nilable(String)) }
    def self.derive_validator(inner_validator, layer, key); end

    # The validator for one response. Returns nil, meaning "emit no ETag",
    # whenever the stack refused to name itself.
    # 
    # _@param_ `repository`
    # 
    # _@param_ `resource_parts` — what distinguishes this endpoint's body from another's over the same corpus
    # 
    # _@param_ `weak`
    sig { params(repository: Object, resource_parts: T::Array[String], weak: T::Boolean).returns(T.nilable(String)) }
    def etag_for(repository, *resource_parts, weak: false); end

    # The validator for one response. Returns nil, meaning "emit no ETag",
    # whenever the stack refused to name itself.
    # 
    # _@param_ `repository`
    # 
    # _@param_ `resource_parts` — what distinguishes this endpoint's body from another's over the same corpus
    # 
    # _@param_ `weak`
    sig { params(repository: Object, resource_parts: T::Array[String], weak: T::Boolean).returns(T.nilable(String)) }
    def self.etag_for(repository, *resource_parts, weak: false); end
  end

  # Routes requests to Rack apps by the first label of the Host header, with an
  # optional fallback app for unmapped hosts.
  class SubdomainRouter
    include Paquette::RegexpTimeout

    sig { params(block: T.untyped).void }
    def initialize(&block); end

    # _@param_ `env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(env); end

    # _@param_ `subdomain`
    # 
    # _@param_ `to` — a Rack app, or a class that instantiates to one
    sig { params(subdomain: String, to: Object).void }
    def map(subdomain, to:); end

    # _@param_ `to` — a Rack app called when no subdomain matches
    sig { params(to: Object).void }
    def fallback(to:); end

    # _@param_ `host`
    # 
    # _@return_ — the first host label, only when it is mapped
    sig { params(host: String).returns(T.nilable(String)) }
    def extract_subdomain(host); end
  end

  # Rack authentication handler that extracts an opaque access token from
  # either a Bearer header or a Basic auth header with the token as username
  # (the GitHub registry convention) — so machine clients like Bundler and npm,
  # which only speak Basic auth, can authenticate with just a token in their
  # config. The resolved identity is stored in env["paquette.identity"].
  class TokenAuthorization < Rack::Auth::AbstractHandler
    include Paquette::RegexpTimeout
    BEARER_SENTINEL = T.let("x-oauth-token", T.untyped)

    # _@param_ `app` — the downstream Rack app
    # 
    # _@param_ `realm` — the authentication realm (used in WWW-Authenticate)
    sig { params(app: T.untyped, realm: String, authenticator: T.proc.returns(T.nilable(Object))).void }
    def initialize(app, realm = "Paquette", &authenticator); end

    # _@param_ `env` — the Rack env
    # 
    # _@return_ — a Rack response triplet
    sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }
    def call(env); end

    sig { returns(String) }
    def challenge; end

    class Request < Rack::Auth::AbstractRequest
      # _@return_ — the token, whichever scheme carried it
      sig { returns(T.nilable(String)) }
      def token; end

      # _@return_ — username and password
      sig { returns(T.any([String, String], [String])) }
      def credentials; end
    end
  end
end
