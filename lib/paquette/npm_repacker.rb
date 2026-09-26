require "fileutils"
require "digest"
require "tmpdir"
require "stringio"
require "json"
require "measurometer"

# Rewrites the contents of an npm tarball into a new one; counterpart of
# GemServer::GemRepacker, with `package_json_extras:` for `gemspec_extras`.
# Byte-reproducible — see Paquette::Tarball for why that is load-bearing.
class Paquette::NpmRepacker
  # Raised when a marker survives the pass — see #verify_markers_applied.
  class MarkerNotApplied < StandardError; end

  # Raised for a marker or replacement spanning several lines.
  class MultilineReplacement < StandardError; end

  # Binary assets and sourcemaps are copied through untouched.
  SOURCE_EXTENSIONS = %w[.js .mjs .cjs .jsx .ts .tsx .mts .cts].freeze

  # One line in, one line out — the rule the whole personalization scheme
  # rests on (a changed line count shifts every sourcemap mapping below it),
  # so a pair that cannot honour it is refused rather than bent to fit.
  #
  # @param replacements [Hash{String => String}]
  # @return [void]
  # @raise [MultilineReplacement]
  def self.check_replacements!(replacements)
    replacements.each do |marker, replacement|
      if marker.to_s.match?(/[\r\n]/)
        raise MultilineReplacement, "Marker #{marker.inspect} spans several lines; a marker must be one whole line"
      end

      if replacement.to_s.match?(/[\r\n]/)
        raise MultilineReplacement,
          "Replacement for #{marker.inspect} spans several lines. Changing the line count shifts every sourcemap " \
          "mapping below it, so a replacement must be a single line"
      end
    end
  end

  # One-shot convenience for {#initialize} + {#repack}.
  #
  # @param npm_path [String]
  # @param package_json_extras [Hash{String => Object}]
  # @param magic_comment_replacements [Hash{String => String}]
  # @param files [Hash{String => String}]
  # @param into [String, nil]
  # @return [String] the path of the repacked tarball
  def self.repack(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block)
    new(
      npm_path,
      package_json_extras: package_json_extras,
      magic_comment_replacements: magic_comment_replacements,
      files: files,
      into: into
    ).repack(&block)
  end

  # @param npm_path [String] path of the source tarball
  # @param package_json_extras [Hash{String => Object}] keys merged into
  #   package.json
  # @param magic_comment_replacements [Hash{String => String}] whole comment
  #   lines to replace, marker => replacement
  # @param files [Hash{String => String}] files to inject, path relative to
  #   the package root => content
  # @param into [String, nil] destination path; a tmpdir when nil
  def initialize(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil)
    self.class.check_replacements!(magic_comment_replacements)
    @npm_path = npm_path
    @package_json_extras = package_json_extras
    @magic_comment_replacements = magic_comment_replacements
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
      rewritten = apply_package_json_extras(rewritten, root)
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

    content = apply_magic_comment_replacements(content, relative_path) if replaceable?(relative_path)

    with_content(entry, content)
  end

  # @param relative_path [String]
  # @return [Boolean]
  def replaceable?(relative_path)
    @magic_comment_replacements.any? && SOURCE_EXTENSIONS.include?(File.extname(relative_path))
  end

  # A whole comment line is replaced by a whole comment line: sourcemaps
  # restart their column counter at every line, so rewriting one line cannot
  # disturb the mappings on any other.
  #
  # @param content [String]
  # @param relative_path [String]
  # @return [String]
  def apply_magic_comment_replacements(content, relative_path)
    text = content.dup.force_encoding(Encoding::UTF_8)
    return content unless text.valid_encoding?

    Measurometer.instrument("paquette.npm_repacker.replace_magic_comments") do
      replaced = text.lines.map do |line|
        stripped = line.chomp
        replacement = @magic_comment_replacements.find { |marker, _| stripped == marker }
        next line unless replacement

        ending = line.end_with?("\n") ? "\n" : ""
        "// #{replacement[1]}#{ending}"
      end.join

      verify_markers_applied(replaced, relative_path)
      replaced.b
    end
  end

  # A marker still present after the pass was one the line-wise match could
  # not reach — `esbuild --minify` pulls a legal comment onto the end of a
  # code line — and the package would then be served with no license key in
  # it and nothing to say so. Replacing it mid-line instead would shift
  # sourcemap columns, which is exactly what the line-wise rule avoids.
  #
  # @param text [String]
  # @param relative_path [String]
  # @return [void]
  # @raise [MarkerNotApplied]
  def verify_markers_applied(text, relative_path)
    @magic_comment_replacements.each_key do |marker|
      next unless text.include?(marker)

      raise MarkerNotApplied,
        "#{relative_path} still contains #{marker.inspect} after personalization: it is not alone on its line " \
        "(minified?), so the license key would have been left out of the served package"
    end
  end

  # @param entries [Array<Paquette::Tarball::Entry>]
  # @param root [String]
  # @return [Array<Paquette::Tarball::Entry>]
  def apply_package_json_extras(entries, root)
    return entries if @package_json_extras.empty?

    Measurometer.instrument("paquette.npm_repacker.package_json_extras") do
      package_json_name = "#{root}/package.json"
      entries.map do |entry|
        next entry unless entry.name == package_json_name

        parsed = JSON.parse(entry.content)
        with_content(entry, JSON.pretty_generate(parsed.merge(@package_json_extras)))
      end
    end
  end

  # Injected files inherit the package's oldest mtime, keeping the tarball
  # independent of when they were added.
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
      by_name[name] = Paquette::Tarball::Entry.new(name: name, mode: 0o644, mtime: mtime, content: content.to_s)
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
