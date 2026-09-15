require "fileutils"
require "digest"
require "tmpdir"
require "stringio"
require "json"
require_relative "tarball"

module Paquette
  # Rewrites the contents of an npm tarball into a new one; counterpart of
  # GemServer::GemRepacker, with `package_json_extras:` for `gemspec_extras`.
  # Byte-reproducible — see Paquette::Tarball for why that is load-bearing.
  class NpmRepacker
    class MarkerNotApplied < StandardError; end

    class MultilineReplacement < StandardError; end

    # Binary assets and sourcemaps are copied through untouched.
    SOURCE_EXTENSIONS = %w[.js .mjs .cjs .jsx .ts .tsx .mts .cts].freeze

    # One line in, one line out — the rule the whole personalization scheme
    # rests on, so a pair that cannot honour it is refused rather than bent to
    # fit. A replacement carrying newlines used to have them flattened to
    # spaces, which quietly published something other than what the caller
    # wrote; a marker carrying newlines could never match a single line and
    # would look like a package that simply had no marker in it.
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

    def self.repack(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block)
      new(
        npm_path,
        package_json_extras: package_json_extras,
        magic_comment_replacements: magic_comment_replacements,
        files: files,
        into: into
      ).repack(&block)
    end

    def initialize(npm_path, package_json_extras: {}, magic_comment_replacements: {}, files: {}, into: nil)
      self.class.check_replacements!(magic_comment_replacements)
      @npm_path = npm_path
      @package_json_extras = package_json_extras
      @magic_comment_replacements = magic_comment_replacements
      @files = files
      @into = into
    end

    # The block gets (input_io, output_io, path relative to the package root)
    # and what it writes becomes the new content.
    def repack(&block)
      raise ArgumentError, "NPM package not found: #{@npm_path}" unless File.exist?(@npm_path)

      entries = Tarball.entries(@npm_path)
      raise ArgumentError, "NPM package is empty: #{@npm_path}" if entries.empty?

      root = entries.first.name.split("/").first

      rewritten = entries.map { |entry| rewrite(entry, root, &block) }
      rewritten = apply_package_json_extras(rewritten, root)
      rewritten = inject_files(rewritten, root)

      Tarball.write(destination, rewritten)
    end

    private

    def destination
      path = @into || File.join(Dir.mktmpdir("npm_repacked"), "#{File.basename(@npm_path, ".tgz")}-repacked.tgz")
      FileUtils.mkdir_p(File.dirname(path))
      path
    end

    def rewrite(entry, root, &block)
      relative_path = entry.name.sub(/\A#{Regexp.escape(root)}\//, "")

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

    def replaceable?(relative_path)
      @magic_comment_replacements.any? && SOURCE_EXTENSIONS.include?(File.extname(relative_path))
    end

    # A whole comment line is replaced by a whole comment line. Sourcemaps
    # restart their column counter at every line, so rewriting one line cannot
    # disturb the mappings on any other; keeping the line a comment means no
    # mapped token sits on the one line that did change.
    def apply_magic_comment_replacements(content, relative_path)
      text = content.dup.force_encoding(Encoding::UTF_8)
      return content unless text.valid_encoding?

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

    # A marker still present after the pass was one the line-wise match could
    # not reach — `esbuild --minify` pulls a legal comment onto the end of a
    # code line, and the package would then be served with no license key in it
    # and nothing to say so. A marker that is simply absent is fine: most
    # packages in a corpus carry no marker at all.
    #
    # Replacing it mid-line instead is not the fix. That would put the license
    # text on a line with mapped tokens, which is the one edit that does shift
    # sourcemap columns.
    def verify_markers_applied(text, relative_path)
      @magic_comment_replacements.each_key do |marker|
        next unless text.include?(marker)

        raise MarkerNotApplied,
          "#{relative_path} still contains #{marker.inspect} after personalization: it is not alone on its line " \
          "(minified?), so the license key would have been left out of the served package"
      end
    end

    def apply_package_json_extras(entries, root)
      return entries if @package_json_extras.empty?

      package_json_name = "#{root}/package.json"
      entries.map do |entry|
        next entry unless entry.name == package_json_name

        parsed = JSON.parse(entry.content)
        with_content(entry, JSON.pretty_generate(parsed.merge(@package_json_extras)))
      end
    end

    # Injected files inherit the package's oldest mtime, keeping the tarball
    # independent of when they were added.
    def inject_files(entries, root)
      return entries if @files.empty?

      mtime = entries.map(&:mtime).min || 0
      by_name = entries.each_with_object({}) { |entry, acc| acc[entry.name] = entry }

      @files.each do |relative_path, content|
        name = "#{root}/#{relative_path}"
        by_name[name] = Tarball::Entry.new(name: name, mode: 0o644, mtime: mtime, content: content.to_s)
      end

      by_name.values
    end

    def with_content(entry, content)
      Tarball::Entry.new(name: entry.name, mode: entry.mode, mtime: entry.mtime, content: content)
    end
  end
end
