require "delegate"
require "fileutils"
require "digest"
require "measurometer"

class Paquette::GemServer::Personalizer < SimpleDelegator
  # `files:` is a {path => content} hash written into every gem this
  # personalizer serves, exactly as GemRepacker takes it. It is what a
  # per-licensee LICENSE file arrives through: the content is rendered by
  # the caller, which is the only party that knows who the licensee is, and
  # handed over already finished.
  #
  # Unlike `magic_comment_replacements`, which rewrites a line inside
  # **/*.rb, this puts whole files in and adds them to spec.files — so it
  # can carry a .txt, which a magic comment never could.
  #
  # `files_for:` is the per-gem edition of `files:`, for content that
  # cannot be known before the gem is looked at — a licensee header put
  # above the agreement each version shipped, which differs gem by gem.
  # It is called with (gem_name, version, original_path) and returns a
  # {path => content} hash to inject on top of `files:`, or nil — and nil
  # means this gem does not participate: it is served byte for byte as it
  # sits on disk. Without `files_for:` every gem is personalized, which is
  # what this class always did.
  #
  # Two rules make the caching below sound, and they are the caller's to
  # keep. What `files_for:` returns may depend on the gem file and on
  # `personalization_key:` and on nothing else — the key is the cache's
  # name for "who this is for", so anything else the content depends on
  # (a licensee's name, a ref) belongs in it. And whether it returns nil
  # at all must be decided by the file alone: nil says the *package* opted
  # out, which cannot vary by licensee, and is remembered per file so the
  # question is never asked twice.
  #
  # `cache_dir:` is where the personalized gems (and the opt-out markers)
  # are kept. The default is the system temp directory, which survives as
  # a default only because it always worked; an application that has a
  # cache directory of its own should say so, or these accumulate in a
  # place nothing tends.
  def initialize(repository, license_key:, magic_comment_replacements: {}, files: {},
    files_for: nil, personalization_key: nil, cache_dir: nil)
    super(repository)
    @license_key = license_key
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @files_for = files_for
    @personalization_key = personalization_key
    @cache_dir = cache_dir || File.join(Dir.tmpdir, "paquette_personalized")
  end

  def gem_file_path(gem_name, version)
    original_path = __getobj__.gem_file_path(gem_name, version)
    return original_path unless original_path && File.exist?(original_path)

    personalize_gem(original_path, gem_name, version)
  end

  # The wrapped repository's lines with the checksum swapped where the
  # served file differs from the one on disk, and only there. The other
  # fields of a line still describe the gem — repacking touches neither
  # dependencies nor requirements — so re-deriving them from the spec per
  # request, as this used to, paid the whole-corpus parse the sidecar
  # cache underneath exists to avoid.
  def compact_info(gem_name)
    Measurometer.instrument("paquette.gem_personalizer.compact_info") do
      __getobj__.compact_info(gem_name).map do |line|
        # The version column, platform suffix and all — the same
        # first-column read ReadGatedRepository filters these lines by.
        version = line.split(" ", 2).first
        original = __getobj__.gem_file_path(gem_name, version)
        served = gem_file_path(gem_name, version)
        next line if served.nil? || served == original || !File.exist?(served)

        checksum = Measurometer.instrument("paquette.gem_personalizer.checksum") do
          Digest::SHA256.file(served).hexdigest
        end
        Paquette::GemServer::GemRepository.replace_checksum(line, checksum)
      end
    end
  end

  private

  # Keyed by everything that goes INTO the gem, not by the gem alone.
  #
  # It used to be "#{gem_name}-#{version}-personalized.gem", which is the
  # same path for every licensee: two of them racing on one download meant
  # one customer receiving the other's copy, and what is personalized into
  # it is by definition the other customer's. The digest below is what makes
  # the cache a cache rather than a collision — same inputs, same file;
  # different licensee, different file.
  #
  # It is also the reason repacking twice is cheap: identical inputs produce
  # a byte-identical gem, so the second request for the same licensee finds
  # the file already there and the checksum in the compact index still
  # describes it.
  #
  # The caches are consulted before the gem is ever opened, and that order
  # is load-bearing: compact_info above asks this question per line, so a
  # registry serving an index asks it per version per request, and an
  # answer that opened the gem each time would cost an unpack per line.
  # The first request per gem file pays the look inside; every one after
  # is two stat calls.
  def personalize_gem(original_gem_path, gem_name, version)
    stat = File.stat(original_gem_path)
    personalized_path = cache_path(gem_name, version, stat)
    if File.exist?(personalized_path)
      Measurometer.increment_counter("paquette.gem_personalizer.cache_hit")
      return personalized_path
    end

    if @files_for
      # The marker is licensee-independent — see the contract in the
      # initializer — so one look inside the gem answers for everybody.
      marker = plain_marker_path(gem_name, version, stat)
      return original_gem_path if File.exist?(marker)

      dynamic_files = @files_for.call(gem_name, version, original_gem_path)
      if dynamic_files.nil?
        FileUtils.mkdir_p(@cache_dir)
        FileUtils.touch(marker)
        return original_gem_path
      end
    else
      dynamic_files = {}
    end

    Measurometer.increment_counter("paquette.gem_personalizer.cache_miss")
    repack(original_gem_path, personalized_path, dynamic_files)
  end

  # A directory we make here and give back here. The block form removes
  # exactly what it created, so nothing in this method ever deletes a path
  # somebody else chose — which is the only safe rule when the path came
  # out of another object. Reaching for File.dirname of whatever you were
  # handed and deleting it recursively is how a tidy-up ends up walking
  # the system temp directory.
  def repack(original_gem_path, personalized_path, dynamic_files)
    FileUtils.mkdir_p(@cache_dir)
    Measurometer.instrument("paquette.gem_personalizer.repack") do
      Dir.mktmpdir("paquette_personalize") do |workdir|
        built = Paquette::GemServer::GemRepacker.repack(original_gem_path,
          gemspec_extras: {"paquette.license_key" => @license_key},
          magic_comment_replacements: @magic_comment_replacements,
          files: @files.merge(dynamic_files),
          into: File.join(workdir, File.basename(personalized_path)))

        FileUtils.mv(built, personalized_path)
      end
    end

    personalized_path
  end

  # Stat identity in the name, so a replaced source file misses the cache
  # without anything having to be invalidated.
  def cache_path(gem_name, version, stat)
    digest = Digest::SHA256.hexdigest([
      personalization_digest, stat.mtime.to_f, stat.size
    ].join("\0"))[0, 24]
    File.join(@cache_dir, "#{gem_name}-#{version}-#{digest}.gem")
  end

  # Where "this gem carries nothing to personalize" is written down — an
  # empty file whose presence is the fact. Keyed by the source identity
  # alone, never by the licensee: whether a gem participates is a fact
  # about the gem.
  def plain_marker_path(gem_name, version, stat)
    digest = Digest::SHA256.hexdigest([stat.mtime.to_f, stat.size].join("\0"))[0, 24]
    File.join(@cache_dir, "#{gem_name}-#{version}-#{digest}.plain")
  end

  # Everything this personalizer would write into a gem, as one short hash.
  # Stable across processes, so a restart does not orphan the cache.
  def personalization_digest
    @personalization_digest ||= Digest::SHA256.hexdigest([
      @license_key,
      @magic_comment_replacements.sort.inspect,
      @files.sort.inspect,
      @personalization_key.to_s
    ].join("\0"))[0, 16]
  end
end
