require "rubygems/package"
require "tempfile"
require "stringio"
require "fileutils"
require "digest"
require "json"
require "measurometer"

# Repository implementation that reads gems from a directory
class Paquette::GemServer::DirectoryGemRepository < Paquette::GemServer::GemRepository
  class GemAlreadyExists < StandardError; end

  class InvalidGem < StandardError; end

  class GemTooLarge < StandardError; end

  class GemNotFound < StandardError; end

  class GemYanked < StandardError; end

  def initialize(gems_dir)
    @gems_dir = gems_dir
    FileUtils.mkdir_p(@gems_dir)
  end

  # A digest of what the corpus holds, for callers building HTTP cache
  # validators over it. Paths alone are enough: a push adds one, a yank
  # renames one away to a tomb, and a .gem file at a given path never
  # changes its bytes.
  def fingerprint
    Measurometer.instrument("paquette.gem_repository.fingerprint") do
      d = Digest::SHA256.new
      Dir.glob(File.join(@gems_dir, "**", "*.gem")).sort.each { |path| d << path }
      d.base64digest
    end
  end

  # The corpus fingerprint is this repository's whole contribution to an
  # HTTP validator: it is the one thing here that can change what a
  # response says, because the bytes at a given path never do.
  def cache_validator
    fingerprint
  end

  # A directory of gems is the same directory for everybody. The wrappers
  # above are what make a response caller-specific, and each says so.
  def varies_by_caller?
    false
  end

  # The SHA256 the sidecar already holds, so an ETag on a download costs
  # two stat calls rather than a re-hash of a multi-megabyte file. Goes
  # through exactly the same read-or-derive path compact_info uses, which
  # is what makes the ETag and the checksum the compact index publishes
  # the same number by construction rather than by coincidence.
  def gem_checksum(gem_name, version)
    gem_file = gem_file_path(gem_name, version)

    stat = begin
      File.stat(gem_file)
    rescue SystemCallError
      return nil
    end

    fields = read_sidecar(gem_name, version, stat) || derive_sidecar(gem_name, version, gem_file, stat)
    fields && fields["checksum"]
  end

  # Persists a .gem file from an uploaded payload. Returns the parsed spec
  # on success.
  #
  # `gem_payload` is either an IO to stream from — a Rack request body, say
  # — or a String of raw bytes. The IO form is the one the server uses: a
  # 50MB push should not become a 50MB Ruby String on its way into a
  # tempfile it was always going to be written to anyway. The String form
  # stays because embedders call this directly and a signature change is
  # not worth a major version; it is wrapped and streamed through the same
  # path, so there is one copy loop rather than two.
  #
  # `max_bytes` caps what is copied, and nil means uncapped — the default,
  # so nothing changes for a caller that never asked for a limit. The cap
  # is enforced on the copy rather than on a declared length because a
  # chunked body has no declared length to enforce it on.
  #
  # Raises InvalidGem when the payload can't be opened as a gem or its spec
  # claims something a server should not act on, GemTooLarge past the cap,
  # GemYanked for a tombed name+version+platform, and GemAlreadyExists if
  # that name, version *and* platform is already on disk. The platform is
  # part of all three: "a-0.2.0-java" and "a-0.2.0" are two artifacts, and
  # yanking or re-pushing either has nothing to say about the other.
  def add_gem(gem_payload, max_bytes: nil)
    raise InvalidGem, "Empty gem payload" if gem_payload.nil?

    io = gem_payload.is_a?(String) ? StringIO.new(gem_payload) : gem_payload
    io.rewind if io.respond_to?(:rewind)

    tmp = Tempfile.new(["paquette_push", ".gem"])
    tmp.binmode

    copied = Measurometer.instrument("paquette.gem_repository.write_upload") do
      # One byte past the cap, so an oversized body is caught by having
      # produced that byte rather than by being read to its end to measure
      # it — the point of the cap is to not read the rest.
      max_bytes ? IO.copy_stream(io, tmp, max_bytes + 1) : IO.copy_stream(io, tmp)
    end
    tmp.close

    Measurometer.add_distribution_value("paquette.gem_repository.add_gem_bytes", copied)
    raise InvalidGem, "Empty gem payload" if copied.zero?
    raise GemTooLarge, "Gem payload exceeds the #{max_bytes} byte limit" if max_bytes && copied > max_bytes

    spec = begin
      Measurometer.instrument("paquette.gem_repository.read_uploaded_spec") { read_uploaded_spec(tmp.path) }
    rescue Gem::Package::Error, StandardError => e
      raise InvalidGem, "Could not read gem: #{e.message}"
    end

    # Before anything touches the filesystem with them. Every field below
    # this line came out of a YAML document the uploader wrote.
    name, version, platform = Paquette::GemServer::SpecValidator.validate!(spec)

    # The key, and the filename. A java build and a plain-ruby build of one
    # name and version are two artifacts, not one artifact pushed twice, so
    # everything below — the tomb, the duplicate check, the destination, the
    # sidecar — is keyed by the column rather than by the version alone.
    # For a plain-ruby gem the column *is* the version, so nothing about an
    # existing corpus moves.
    version_column = Paquette::GemServer.version_column(version, platform)

    raise GemYanked, "#{name}-#{version_column} was yanked and cannot be republished" if tomb_exists?(name, version_column)
    raise GemAlreadyExists, "#{name}-#{version_column} already exists" if gem_exists?(name, version_column)

    destination = gem_file_path(name, version_column)
    # Braces to the validator's belt. SpecValidator::NAME and ::PLATFORM
    # both exclude "/" and a leading dot, so this cannot fire today — which
    # is the point: it is the check that keeps holding if either pattern is
    # ever widened, and it costs one expand_path per push.
    unless within_gems_dir?(destination)
      raise InvalidGem, "Gem #{name}-#{version_column} resolves outside the gems directory"
    end

    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.mv(tmp.path, destination)

    spec
  ensure
    tmp&.close unless tmp&.closed?
    File.unlink(tmp.path) if tmp && File.exist?(tmp.path)
  end

  # Serializes the alias flip below. Two concurrent pushes must not have
  # one of them restore the flag while the other is still inside Psych.
  YAML_ALIAS_MUTEX = Mutex.new

  # Reads the spec out of an uploaded .gem with YAML alias expansion off.
  #
  # `Gem::Package#spec` parses the gemspec through Gem::SafeYAML, which
  # permits aliases by default. Aliases are how a small YAML document
  # becomes an enormous object graph — the billion-laughs shape, `&a [*b,
  # *b, *b, …]` — and on an endpoint that accepts uploads from anyone that
  # is a memory-exhaustion DoS for the price of a few hundred bytes.
  # Nothing legitimate needs them here: Gem::Specification#to_yaml has
  # never emitted an alias, so a gemspec that contains one was hand-built.
  #
  # gem.coop turns the flag off once, globally, at boot. It can: it *is*
  # the application. Paquette is a library living inside someone else's
  # process, and Gem::SafeYAML is process-global state that RubyGems and
  # Bundler also read — so flipping it permanently at require time would
  # be this gem quietly changing how its host parses every gemspec it ever
  # loads, with no mention at the call site. That is the kind of thing a
  # library gets blamed for years later.
  #
  # So it is flipped around our own parse and put back, under a mutex.
  # This is not free of consequence either, and the trade is worth naming:
  # for the duration of one parse the flag is off for the whole process,
  # so another thread parsing an alias-using gemspec in that window would
  # see it fail. That is the milder of the two failures — brief, and
  # failing in the safe direction — where the permanent version is silent
  # and forever. Older RubyGems without the accessor simply parse as they
  # always did; the size cap in add_gem is the backstop there.
  def read_uploaded_spec(gem_path)
    # Gem::SafeYAML is only defined once RubyGems has pulled Psych in, and
    # Gem::Package does that lazily on the first spec it reads. Asking for
    # it here means the flag below is looked up on the real module rather
    # than on a NameError.
    Gem.load_yaml
    return Gem::Package.new(gem_path).spec unless Gem::SafeYAML.respond_to?(:aliases_enabled=)

    YAML_ALIAS_MUTEX.synchronize do
      was_enabled = Gem::SafeYAML.aliases_enabled?
      begin
        Gem::SafeYAML.aliases_enabled = false
        Gem::Package.new(gem_path).spec
      ensure
        Gem::SafeYAML.aliases_enabled = was_enabled
      end
    end
  end

  # Whether a path the repository is about to write to is really inside the
  # corpus. expand_path resolves "..", and the trailing separator is what
  # stops a sibling directory whose name merely starts the same way —
  # "/srv/gems-evil" against a root of "/srv/gems" — from passing.
  def within_gems_dir?(path)
    root = File.expand_path(@gems_dir) + File::SEPARATOR
    File.expand_path(path).start_with?(root)
  end

  # Yanks a gem by renaming its .gem file to .gem.tomb. `version` is a
  # version column, so it carries the platform for a platform build and the
  # tomb is per-artifact: yanking "a-0.2.0-java" leaves "a-0.2.0" and
  # "a-0.2.0-x86-mingw32" downloadable, and does not stand in the way of
  # either being pushed later. Raises GemNotFound when the gem was never
  # present or already yanked.
  def yank_gem(gem_name, version)
    gem_path = gem_file_path(gem_name, version)
    # The same braces add_gem puts on its destination, for the same reason
    # and against a worse outcome: nothing upstream of a repository is
    # obliged to have validated anything, and a yank whose name escaped the
    # corpus is a rename of a file that was never ours. GemServer#handle_yank
    # validates its params, so this cannot fire from there.
    raise GemNotFound, "#{gem_name}-#{version} not found" unless within_gems_dir?(gem_path)
    raise GemNotFound, "#{gem_name}-#{version} not found" unless File.exist?(gem_path)

    Measurometer.instrument("paquette.gem_repository.yank_gem") do
      FileUtils.mv(gem_path, tomb_file_path(gem_name, version))

      # Tidying, not correctness. compact_info trusts the *.gem glob and
      # never reads a sidecar whose gem file is gone, so a yanked gem
      # disappears from the index the moment the rename above lands — this
      # just keeps the cache directory from collecting orphans.
      FileUtils.rm_f(sidecar_path(gem_name, version))
    end
    nil
  end

  def tomb_file_path(gem_name, version)
    gem_file_path(gem_name, version) + ".tomb"
  end

  def tomb_exists?(gem_name, version)
    File.exist?(tomb_file_path(gem_name, version))
  end

  # A directory is not a gem; a .gem file in it is. Yanking renames the
  # last .gem away and leaves the directory behind, and listing that
  # directory made /names announce a gem whose /info/ answers 404 — the
  # index disagreeing with itself, which is what rubygems' conformance
  # suite catches. The extra glob per package is the price of the two
  # endpoints agreeing.
  def gem_names
    Measurometer.instrument("paquette.gem_repository.gem_names") do
      Dir.glob(File.join(@gems_dir, "*")).select { |path| File.directory?(path) }.filter_map do |package_path|
        name = File.basename(package_path)
        name unless versions_for_gem(name).empty?
      end.sort
    end
  end

  # A directory listing per gem in the corpus; every whole-index endpoint
  # starts here.
  def gem_versions
    Measurometer.instrument("paquette.gem_repository.gem_versions") do
      versions = []
      gem_names.each do |gem_name|
        versions_for_gem(gem_name).each do |version|
          versions << [gem_name, version]
        end
      end
      Measurometer.add_distribution_value("paquette.gem_repository.gem_version_count", versions.length)
      versions.sort
    end
  end

  def versions_for_gem(gem_name)
    gem_dir = File.join(@gems_dir, gem_name)
    return [] unless Dir.exist?(gem_dir)

    # The split is GemServer's to make, not this class's. Building a
    # pattern here meant a third opinion about what a version looks like,
    # and it disagreed: a gem pushed at "0.2" was written to disk and then
    # matched by nothing, so it existed as a file and as nothing else. It
    # also compiled a regexp per call out of a name that a caller chose,
    # which raises on its own for a name that is not valid UTF-8.
    Measurometer.instrument("paquette.gem_repository.versions_for_gem") do
      Dir.glob(File.join(gem_dir, "*.gem")).map do |gem_path|
        name, version = Paquette::GemServer.split_gem_filename(File.basename(gem_path))
        version if name == gem_name
      end.compact.sort
    end
  end

  # `version` is a version column throughout this class — the number with
  # the platform glued on for a platform build, the bare number for a
  # plain-ruby one — so the path this builds is byte for byte the filename
  # `Gem::Specification#file_name` would have produced for the same gem.
  # That is the whole storage design in one line, and it is why the read
  # side needed no changes: split_gem_filename already takes this apart
  # into a name and a column, and split_version_column takes the column
  # apart into a number and a platform.
  def gem_file_path(gem_name, version)
    File.join(@gems_dir, gem_name, "#{gem_name}-#{version}.gem")
  end

  def gem_exists?(gem_name, version)
    File.exist?(gem_file_path(gem_name, version))
  end

  # Opening a .gem to read its spec means a tar walk, a gunzip and a YAML
  # parse — the single most expensive thing this repository does per gem,
  # and what the sidecar cache below exists to avoid.
  def gem_spec(gem_name, version)
    gem_file = gem_file_path(gem_name, version)
    return nil unless File.exist?(gem_file)

    Measurometer.instrument("paquette.gem_repository.gem_spec") do
      Gem::Package.new(gem_file).spec
    end
  end

  # The publication date out of the sidecar when one is there, and out of
  # the gem itself when it is not. Same answer either way — the sidecar
  # only saves the tar walk and the YAML parse.
  #
  # A sidecar written before "published_at" existed is *not* invalidated
  # over the missing key: everything else in it still describes the gem
  # correctly, and throwing it away would re-checksum the whole corpus on
  # the first request after an upgrade. It falls through to the spec
  # instead, and gets the key the next time the entry is derived for
  # other reasons.
  def published_at(gem_name, version)
    gem_file = gem_file_path(gem_name, version)

    stat = begin
      File.stat(gem_file)
    rescue Errno::ENOENT
      return nil
    end

    cached = read_sidecar(gem_name, version, stat)&.fetch("published_at", nil)
    return Time.at(cached).utc if cached

    gem_spec(gem_name, version)&.date
  end

  def gem_dependencies(gem_name, version)
    spec = gem_spec(gem_name, version)
    return [] unless spec

    # Only include runtime dependencies, not development dependencies
    runtime_deps = spec.dependencies.select { |dep| dep.type == :runtime }
    runtime_deps.map do |dep|
      {
        name: dep.name,
        requirements: dep.requirement.to_s
      }
    end
  end

  # Where the derived-metadata sidecars live, inside each package
  # directory. The leading dot is what keeps it out of every listing in
  # this class without any listing having to know about it: Dir.glob does
  # not match dotfiles unless asked with FNM_DOTMATCH, so neither the
  # "*.gem" glob in versions_for_gem nor the "*" glob in gem_names can
  # ever see it — and gem_names filters to directories on top of that.
  CACHE_DIR_BASENAME = ".paquette-cache"

  def compact_info(gem_name)
    versions = versions_for_gem(gem_name)
    return [] if versions.empty?

    Measurometer.instrument("paquette.gem_repository.compact_info") do
      # The *.gem files are the authority on what exists; the sidecars are
      # only consulted for gems the glob above already vouched for. That
      # order is what makes yank instant — a renamed-away gem file leaves
      # its sidecar orphaned, and an orphaned sidecar is simply never read.
      versions.map do |version|
        gem_file = gem_file_path(gem_name, version)

        stat = begin
          File.stat(gem_file)
        rescue Errno::ENOENT
          # Yanked between the glob and this stat. The gem is gone, so its
          # line is too.
          next
        end

        fields = read_sidecar(gem_name, version, stat)
        if fields
          Measurometer.increment_counter("paquette.gem_repository.sidecar_hit")
        else
          Measurometer.increment_counter("paquette.gem_repository.sidecar_miss")
          fields = derive_sidecar(gem_name, version, gem_file, stat)
        end
        next unless fields

        Paquette::GemServer::GemRepository.compact_info_line_from_fields(version, fields)
      end.compact
    end
  end

  private

  # A .gem file at a given path never changes: a yank renames it away, and
  # a name+version can never be pushed twice. So everything compact_info
  # derives from one — the spec fields an info line is made of and the
  # SHA256 of the whole file — is derived once, on the first request that
  # needs it, and kept in a JSON file next to the gem. Without this, every
  # /versions request paid a full tar walk, gunzip, checksum verification
  # and YAML parse for every version of every gem in the corpus.
  def sidecar_path(gem_name, version)
    File.join(@gems_dir, gem_name, CACHE_DIR_BASENAME, "#{gem_name}-#{version}.json")
  end

  # Returns the cached fields, or nil for anything short of a usable
  # entry: no sidecar yet, unparseable JSON, an entry written by an older
  # format, a hash missing the keys the renderer needs, or a size/mtime
  # that disagrees with the gem file on disk. A byte-different file at the
  # same path should never happen, but "should never happen" is not a
  # thing to serve stale checksums over — a nil here just means the gem
  # gets parsed again.
  def read_sidecar(gem_name, version, stat)
    fields = JSON.parse(File.read(sidecar_path(gem_name, version)))
    return nil unless fields.is_a?(Hash)

    # Anything not stamped with the current format number is discarded
    # rather than served. A sidecar from before the number existed reads
    # as nil here and is re-derived too, which is the case this check was
    # put in for: an entry that predates a field cannot be told from one
    # whose gem genuinely lacks it, and serving it would mean a warm cache
    # quietly emitting yesterday's line forever.
    return nil unless fields["format_version"] == SIDECAR_FORMAT_VERSION
    return nil unless %w[dependencies ruby rubygems checksum].all? { |key| fields.key?(key) }
    return nil unless fields["size"] == stat.size && fields["mtime_ns"] == mtime_ns(stat)

    fields
  rescue SystemCallError, JSON::ParserError
    nil
  end

  # Written into every sidecar, and checked by read_sidecar, which
  # discards anything not stamped with the current number.
  #
  # The day the format had to change arrived with "rubygems", the fourth
  # compact-info field. A cached entry written at version 1 has no such
  # key, and a reader that only looked for the keys it needed could not
  # tell that entry apart from one whose gem simply declares no
  # `required_rubygems_version` — so every deployment with a warm cache
  # would have gone on serving lines without the field, indefinitely and
  # invisibly. Bumping the number is what expires them: a version-1
  # sidecar is re-derived on the first request that reaches it, once,
  # after which the cache is warm again at the new format.
  #
  # Bump this whenever compact_info_fields gains, drops or changes the
  # meaning of a key. It costs each deployment one re-derivation pass
  # spread over ordinary traffic, which is the price of never serving a
  # line the current code would not have rendered.
  # Version 3 changed what "ruby" means: it used to be ">= 0" for a gem
  # with no Ruby constraint and is now nil, so the field is left out of
  # the line entirely. A version-2 sidecar still holds the ">= 0" and
  # would go on rendering it forever, which is exactly the invisible
  # staleness this number exists to end.
  SIDECAR_FORMAT_VERSION = 3

  def derive_sidecar(gem_name, version, gem_file, stat)
    Measurometer.instrument("paquette.gem_repository.derive_sidecar") do
      derive_sidecar_fields(gem_name, version, gem_file, stat)
    end
  end

  def derive_sidecar_fields(gem_name, version, gem_file, stat)
    spec = gem_spec(gem_name, version)
    return nil unless spec

    checksum = Measurometer.instrument("paquette.gem_repository.checksum_gem") do
      Digest::SHA256.file(gem_file).hexdigest
    end

    fields = Paquette::GemServer::GemRepository.compact_info_fields(spec, checksum).merge(
      "format_version" => SIDECAR_FORMAT_VERSION,
      "version" => version,
      "size" => stat.size,
      "mtime_ns" => mtime_ns(stat)
    )
    write_sidecar(gem_name, version, fields)
    fields
  end

  # Serialize into a tempfile in the cache directory, then rename over the
  # final name. Rename within one directory is atomic, so a reader sees
  # either the old sidecar or the new one, never a torn write. There is no
  # locking on purpose: two writers racing here derived their content from
  # the same immutable gem file, so whichever rename lands last installed
  # the same bytes the loser would have.
  #
  # The cache is an optimization, never a requirement — on a read-only
  # gems directory every write lands in the rescue and the request is
  # served from source, at the old price but served.
  def write_sidecar(gem_name, version, fields)
    # Declared out here so the rescue below can still see it: a local first
    # assigned inside the block would not exist by the time we tidy up.
    tmp_path = nil

    Measurometer.instrument("paquette.gem_repository.write_sidecar") do
      final_path = sidecar_path(gem_name, version)
      cache_dir = File.dirname(final_path)
      FileUtils.mkdir_p(cache_dir)

      tmp_path = File.join(cache_dir, ".#{gem_name}-#{version}.#{Process.pid}.#{rand(2**32).to_s(16)}.tmp")
      File.write(tmp_path, JSON.pretty_generate(fields))
      File.rename(tmp_path, final_path)
    end
    nil
  rescue SystemCallError
    FileUtils.rm_f(tmp_path) if tmp_path
    nil
  end

  # The mtime down to the nanosecond, as one integer. An integer rather
  # than a Float on purpose: the guard is an exact-equality check, and
  # integers survive a trip through JSON without anyone having to reason
  # about float formatting to trust the comparison.
  def mtime_ns(stat)
    mtime = stat.mtime
    (mtime.to_i * 1_000_000_000) + mtime.nsec
  end
end
