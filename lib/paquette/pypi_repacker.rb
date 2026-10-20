require "fileutils"
require "tmpdir"
require "json"
require "measurometer"

# Rewrites the contents of a wheel or an sdist into a new one; the Python
# counterpart of Paquette::NpmRepacker. Byte-reproducible, since pip checks
# the sha256 the index published for the file.
#
# A wheel has its RECORD rewritten to match, and loses any signature over the
# old one. An sdist only gets its files changed - whatever wheel pip builds
# from it is pip's.
class Paquette::PypiRepacker
  # Bumped whenever the same source file and the same arguments would repack
  # into different bytes, so a cache keyed on the inputs can include it.
  #
  # @return [Integer]
  FORMAT_VERSION = 1

  # @return [Array<String>]
  SOURCE_EXTENSIONS = %w[.py .pyi].freeze

  # Where the license key goes: next to METADATA in a wheel, where
  # `importlib.metadata.distribution(name).read_text("paquette.json")` finds
  # it, and at the root of an sdist.
  #
  # @return [String]
  STAMP_FILE = "paquette.json"

  # @return [Array<String>]
  RECORD_SIGNATURES = %w[RECORD.jws RECORD.p7s].freeze

  # @param path [String]
  # @param filename [String] the distribution filename, which says which
  #   kind of archive this is
  # @param stamp [Hash, nil] written as paquette.json; nil writes none
  # @param magic_comment_replacements [Hash{String => String}]
  # @param files [Hash{String => String}] path relative to the archive root =>
  #   content - the root of a wheel is site-packages
  # @param into [String, nil]
  # @return [String] the path of the repacked file
  def self.repack(path, filename:, stamp: nil, magic_comment_replacements: {}, files: {}, into: nil)
    new(path, filename: filename, stamp: stamp, magic_comment_replacements: magic_comment_replacements,
      files: files, into: into).repack
  end

  # @param path [String]
  # @param filename [String]
  # @param stamp [Hash, nil]
  # @param magic_comment_replacements [Hash{String => String}]
  # @param files [Hash{String => String}]
  # @param into [String, nil]
  def initialize(path, filename:, stamp: nil, magic_comment_replacements: {}, files: {}, into: nil)
    # The one-line rule has no sourcemaps to protect here, but it does keep
    # every traceback line number the same as in the source the publisher saw
    Paquette::NpmRepacker.check_replacements!(magic_comment_replacements)
    @path = path
    @filename = filename
    @stamp = stamp
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @into = into
  end

  # @return [String] the path of the repacked file
  def repack
    raise ArgumentError, "Distribution not found: #{@path}" unless File.exist?(@path)

    Measurometer.instrument("paquette.pypi_repacker.repack") do
      Paquette::PypiServer::PypiRepository.wheel?(@filename) ? repack_wheel : repack_sdist
    end
  end

  private

  # @return [String]
  def destination
    path = @into || File.join(Dir.mktmpdir("pypi_repacked"), @filename)
    FileUtils.mkdir_p(File.dirname(path))
    path
  end

  # @return [String]
  def repack_wheel
    entries = Paquette::Wheel.entries(@path)
    raise ArgumentError, "Wheel is empty: #{@path}" if entries.empty?

    record_name = record_name_in(entries)
    dist_info = File.dirname(record_name)
    mtime = entries.map(&:mtime).min

    entries = entries.reject { |entry| RECORD_SIGNATURES.include?(entry.name.delete_prefix("#{dist_info}/")) }
    entries = entries.map { |entry| rewrite(entry, entry.name) }

    injected = @files.map { |relative_path, content| [relative_path, content.to_s] }
    injected << ["#{dist_info}/#{STAMP_FILE}", JSON.pretty_generate(@stamp)] if @stamp
    entries = inject(entries, injected) { |name, mode, content| Paquette::Wheel::Entry.new(name: name, mode: mode, mtime: mtime, content: content) }

    # The binary distribution format wants .dist-info last, and RECORD with it
    others, record = entries.partition { |entry| entry.name != record_name }
    record = Paquette::Wheel::Entry.new(name: record_name, mode: record.first&.mode || 0o644, mtime: record.first&.mtime || mtime, content: "")
    record.content = Paquette::Wheel.record_for(others, record_name)

    Paquette::Wheel.write(destination, others + [record])
  end

  # @param entries [Array<Paquette::Wheel::Entry>]
  # @return [String]
  def record_name_in(entries)
    parsed = Paquette::PypiServer::PypiRepository.parse_filename(@filename)
    expected = "#{parsed[:distribution]}-#{parsed[:version]}.dist-info/RECORD"
    return expected if entries.any? { |entry| entry.name == expected }

    candidates = entries.map(&:name).select { |name| name.count("/") == 1 && name.end_with?(".dist-info/RECORD") }
    raise ArgumentError, "Cannot tell which .dist-info is #{@filename}'s" unless candidates.length == 1

    candidates.first
  end

  # @return [String]
  def repack_sdist
    entries = Paquette::Tarball.entries(@path)
    raise ArgumentError, "sdist is empty: #{@path}" if entries.empty?

    root = entries.first.name.split("/").first
    mtime = entries.map(&:mtime).min || 0

    entries = entries.map do |entry|
      # delete_prefix, not a regexp: the name comes out of an uploaded tarball
      rewrite(entry, entry.name.delete_prefix("#{root}/"))
    end

    injected = @files.map { |relative_path, content| ["#{root}/#{relative_path}", content.to_s] }
    injected << ["#{root}/#{STAMP_FILE}", JSON.pretty_generate(@stamp)] if @stamp
    entries = inject(entries, injected) { |name, mode, content| Paquette::Tarball::Entry.new(name: name, mode: mode, mtime: mtime, content: content) }

    Paquette::Tarball.write(destination, entries)
  end

  # Either kind of entry - both structs answer to the same four fields
  #
  # @param entry [Paquette::Wheel::Entry, Paquette::Tarball::Entry]
  # @param relative_path [String]
  # @return [Paquette::Wheel::Entry, Paquette::Tarball::Entry]
  def rewrite(entry, relative_path)
    return entry unless @magic_comment_replacements.any? && SOURCE_EXTENSIONS.include?(File.extname(relative_path))

    replaced = apply_magic_comment_replacements(entry.content, relative_path)
    entry.dup.tap { |copy| copy.content = replaced }
  end

  # An injected file that replaces a shipped one keeps that one's place and mode.
  #
  # @param entries [Array]
  # @param injected [Array<Array(String, String)>]
  # @yieldparam name [String]
  # @yieldparam mode [Integer]
  # @yieldparam content [String]
  # @return [Array]
  def inject(entries, injected)
    by_name = entries.each_with_object({}) { |entry, acc| acc[entry.name] = entry }
    injected.each do |name, content|
      by_name[name] = yield(name, by_name[name]&.mode || 0o644, content)
    end
    by_name.values
  end

  # A whole comment line is replaced by a whole comment line, indentation and all
  #
  # @param content [String]
  # @param relative_path [String]
  # @return [String]
  # @raise [Paquette::NpmRepacker::MarkerNotApplied]
  def apply_magic_comment_replacements(content, relative_path)
    text = content.dup.force_encoding(Encoding::UTF_8)
    return content unless text.valid_encoding?

    Measurometer.instrument("paquette.pypi_repacker.replace_magic_comments") do
      replaced = text.lines.map do |line|
        stripped = line.chomp
        indent = stripped[0, stripped.length - stripped.lstrip.length]
        replacement = @magic_comment_replacements.find { |marker, _| stripped.lstrip == marker }
        next line unless replacement

        "#{indent}# #{replacement[1]}#{line[stripped.length..]}"
      end.join

      @magic_comment_replacements.each_key do |marker|
        next unless replaced.include?(marker)

        raise Paquette::NpmRepacker::MarkerNotApplied,
          "#{relative_path} still contains #{marker.inspect} after personalization: it is not alone on its line, " \
          "so the license key would have been left out of the served package"
      end
      replaced.b
    end
  end
end
