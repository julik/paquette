require "fileutils"
require "digest"
require "tmpdir"
require "stringio"
require "json"
require "measurometer"

# Rewrites the contents of an npm tarball into a new one for one caller: every
# marker line filled with the caller's value (see Paquette::Markers), the
# values stamped into package.json under "paquette", files injected.
# Counterpart of GemServer::GemRepacker. Byte-reproducible — see
# Paquette::Tarball for why that is load-bearing.
class Paquette::NpmRepacker
  # Bumped whenever the same source tarball and the same arguments would
  # repack into different bytes, so a cache keyed on the inputs can include
  # it — the counterpart of GemServer::GemRepacker::FORMAT_VERSION.
  # 2: a file that replaces a shipped one keeps that file's mode.
  # 3: markers, in every text entry; values stamped under "paquette".
  #
  # @return [Integer]
  FORMAT_VERSION = 3

  # The package.json key the values land under.
  #
  # @return [String]
  STAMP_KEY = "paquette"

  # One-shot convenience for {#initialize} + {#repack}.
  #
  # @param npm_path [String]
  # @param values [Hash{String => String}]
  # @param files [Hash{String => String}]
  # @param into [String, nil]
  # @return [String] the path of the repacked tarball
  def self.repack(npm_path, values:, files: {}, into: nil, &block)
    new(npm_path, values: values, files: files, into: into).repack(&block)
  end

  # The keys of every marker in the tarball. Empty for a package that asks
  # for nothing, which is how a personalizer knows to serve it as it is.
  #
  # @param npm_path [String]
  # @return [Array<String>]
  def self.marker_keys(npm_path)
    Measurometer.instrument("paquette.npm_repacker.marker_keys") do
      Paquette::Tarball.entries(npm_path).flat_map { |entry| Paquette::Markers.keys_in(entry.content.to_s) }.uniq
    end
  end

  # @param npm_path [String] path of the source tarball
  # @param values [Hash{String => String}] the caller's values: each marker
  #   line for a key is filled with its value, and all of them land in
  #   package.json under "paquette"
  # @param files [Hash{String => String}] files to inject, path relative to
  #   the package root => content, with markers in the content filled in too
  # @param into [String, nil] destination path; a tmpdir when nil
  def initialize(npm_path, values:, files: {}, into: nil)
    Paquette::Markers.check_values!(values)
    @npm_path = npm_path
    @values = values
    @files = files
    @into = into
  end

  # @yieldparam input [StringIO] an entry's content
  # @yieldparam output [StringIO] what is written here becomes the new content
  # @yieldparam relative_path [String] path relative to the package root
  # @return [String] the path of the repacked tarball
  def repack(&block)
    raise ArgumentError, "NPM package not found: #{@npm_path}" unless File.exist?(@npm_path)

    Measurometer.instrument("paquette.npm_repacker.repack") do
      entries = Paquette::Tarball.entries(@npm_path)
      raise ArgumentError, "NPM package is empty: #{@npm_path}" if entries.empty?

      root = entries.first.name.split("/").first

      rewritten = Measurometer.instrument("paquette.npm_repacker.rewrite_entries") do
        entries.map { |entry| rewrite(entry, root, &block) }
      end
      rewritten = stamp(rewritten, root)
      rewritten = inject_files(rewritten, root)

      Paquette::Tarball.write(destination, rewritten)
    end
  end

  private

  # @return [String]
  def destination
    path = @into || File.join(Dir.mktmpdir("npm_repacked"), "#{File.basename(@npm_path, ".tgz")}-repacked.tgz")
    FileUtils.mkdir_p(File.dirname(path))
    path
  end

  # Every entry, not only the source files: a LICENSE carries a marker as
  # readily as a module does. Binaries are left alone by Markers itself.
  #
  # @param entry [Paquette::Tarball::Entry]
  # @param root [String]
  # @return [Paquette::Tarball::Entry]
  def rewrite(entry, root, &block)
    # delete_prefix, not a regexp: a tar entry name comes from an uploaded
    # tarball, so it reaches here before anything has vetted its bytes, and
    # a regexp built around it would raise out of its own compile.
    relative_path = entry.name.delete_prefix("#{root}/")

    content = if block
      output = StringIO.new(+"".b)
      input = StringIO.new(entry.content.dup)
      input.binmode
      output.binmode
      block.call(input, output, relative_path)
      output.string
    else
      entry.content
    end

    content = Measurometer.instrument("paquette.npm_repacker.replace_magic_comments") do
      Paquette::Markers.substitute(content, @values, described_as: relative_path)
    end

    with_content(entry, content)
  end

  # @param entries [Array<Paquette::Tarball::Entry>]
  # @param root [String]
  # @return [Array<Paquette::Tarball::Entry>]
  def stamp(entries, root)
    return entries if @values.empty?

    Measurometer.instrument("paquette.npm_repacker.package_json_extras") do
      package_json_name = "#{root}/package.json"
      entries.map do |entry|
        next entry unless entry.name == package_json_name

        parsed = JSON.parse(entry.content)
        with_content(entry, JSON.pretty_generate(parsed.merge(STAMP_KEY => @values)))
      end
    end
  end

  # Injected files inherit the package's oldest mtime, keeping the tarball
  # independent of when they were added. One that replaces a shipped file
  # keeps that file's mode, so replacing a bin script leaves it executable.
  # Markers in the injected content are filled in like any other.
  #
  # @param entries [Array<Paquette::Tarball::Entry>]
  # @param root [String]
  # @return [Array<Paquette::Tarball::Entry>]
  def inject_files(entries, root)
    return entries if @files.empty?

    mtime = entries.map(&:mtime).min || 0
    by_name = entries.each_with_object({}) { |entry, acc| acc[entry.name] = entry }

    @files.each do |relative_path, content|
      name = "#{root}/#{relative_path}"
      mode = by_name[name]&.mode || 0o644
      filled = Paquette::Markers.substitute(content.to_s, @values, described_as: relative_path)
      by_name[name] = Paquette::Tarball::Entry.new(name: name, mode: mode, mtime: mtime, content: filled)
    end

    by_name.values
  end

  # @param entry [Paquette::Tarball::Entry]
  # @param content [String]
  # @return [Paquette::Tarball::Entry]
  def with_content(entry, content)
    Paquette::Tarball::Entry.new(name: entry.name, mode: entry.mode, mtime: entry.mtime, content: content)
  end
end
