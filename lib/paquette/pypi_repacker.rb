require "fileutils"
require "tmpdir"
require "json"
require "measurometer"

# Rewrites the contents of a wheel or an sdist into a new one for one caller:
# every marker line filled with the caller's value (see Paquette::Markers),
# the values written to paquette.json, files injected. The Python counterpart
# of Paquette::NpmRepacker. Byte-reproducible, since pip checks the sha256 the
# index published for the file.
#
# A wheel has its RECORD rewritten to match, and loses any signature over the
# old one. An sdist only gets its files changed - whatever wheel pip builds
# from it is pip's.
class Paquette::PypiRepacker
  # Bumped whenever the same source file and the same arguments would repack
  # into different bytes, so a cache keyed on the inputs can include it.
  # 2: markers, in every entry; paquette.json carries all the values.
  #
  # @return [Integer]
  FORMAT_VERSION = 2

  # Where the values go: next to METADATA in a wheel, where
  # `importlib.metadata.distribution(name).read_text("paquette.json")` finds
  # them, and at the root of an sdist.
  #
  # @return [String]
  STAMP_FILE = "paquette.json"

  # @return [Array<String>]
  RECORD_SIGNATURES = %w[RECORD.jws RECORD.p7s].freeze

  # @param path [String]
  # @param filename [String] the distribution filename, which says which
  #   kind of archive this is
  # @param values [Hash{String => String}]
  # @param files [Hash{String => String}] path relative to the archive root =>
  #   content - the root of a wheel is site-packages
  # @param into [String, nil]
  # @return [String] the path of the repacked file
  def self.repack(path, filename:, values:, files: {}, into: nil)
    new(path, filename: filename, values: values, files: files, into: into).repack
  end

  # The keys of every marker in the archive, whichever kind it is. Empty for
  # a file that asks for nothing, which is how a personalizer knows to serve
  # it as it is.
  #
  # @param path [String]
  # @param filename [String]
  # @return [Array<String>]
  def self.marker_keys(path, filename:)
    Measurometer.instrument("paquette.pypi_repacker.marker_keys") do
      entries = Paquette::PypiServer::PypiRepository.wheel?(filename) ? Paquette::Wheel.entries(path) : Paquette::Tarball.entries(path)
      entries.flat_map { |entry| Paquette::Markers.keys_in(entry.content.to_s) }.uniq
    end
  end

  # @param path [String]
  # @param filename [String]
  # @param values [Hash{String => String}] the caller's values: each marker
  #   line for a key is filled with its value, and all of them land in
  #   paquette.json
  # @param files [Hash{String => String}] with markers in the content filled in too
  # @param into [String, nil]
  def initialize(path, filename:, values:, files: {}, into: nil)
    # The one-line rule has no sourcemaps to protect here, but it does keep
    # every traceback line number the same as in the source the publisher saw
    Paquette::Markers.check_values!(values)
    @path = path
    @filename = filename
    @values = values
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

    injected = injected_files { |relative_path| relative_path }
    injected << ["#{dist_info}/#{STAMP_FILE}", stamp]
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

    injected = injected_files { |relative_path| "#{root}/#{relative_path}" }
    injected << ["#{root}/#{STAMP_FILE}", stamp]
    entries = inject(entries, injected) { |name, mode, content| Paquette::Tarball::Entry.new(name: name, mode: mode, mtime: mtime, content: content) }

    Paquette::Tarball.write(destination, entries)
  end

  # @return [String]
  def stamp
    JSON.pretty_generate(@values)
  end

  # The injected files with their markers filled in, named by the block.
  #
  # @yieldparam relative_path [String]
  # @return [Array<Array(String, String)>]
  def injected_files
    @files.map do |relative_path, content|
      [yield(relative_path), Paquette::Markers.substitute(content.to_s, @values, described_as: relative_path)]
    end
  end

  # Either kind of entry - both structs answer to the same four fields. Every
  # entry, not only the sources: Markers leaves a binary alone itself.
  #
  # @param entry [Paquette::Wheel::Entry, Paquette::Tarball::Entry]
  # @param relative_path [String]
  # @return [Paquette::Wheel::Entry, Paquette::Tarball::Entry]
  def rewrite(entry, relative_path)
    filled = Measurometer.instrument("paquette.pypi_repacker.replace_magic_comments") do
      Paquette::Markers.substitute(entry.content, @values, described_as: relative_path)
    end
    return entry if filled.equal?(entry.content)

    entry.dup.tap { |copy| copy.content = filled }
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
end
