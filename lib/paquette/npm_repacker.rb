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
    # Binary assets and sourcemaps are copied through untouched.
    SOURCE_EXTENSIONS = %w[.js .mjs .cjs .jsx .ts .tsx .mts .cts].freeze

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

      content = apply_magic_comment_replacements(content) if replaceable?(relative_path)

      with_content(entry, content)
    end

    def replaceable?(relative_path)
      @magic_comment_replacements.any? && SOURCE_EXTENSIONS.include?(File.extname(relative_path))
    end

    # One line replaced by one line, or sourcemap mappings would silently misalign.
    def apply_magic_comment_replacements(content)
      text = content.dup.force_encoding(Encoding::UTF_8)
      return content unless text.valid_encoding?

      replaced = text.lines.map do |line|
        stripped = line.chomp
        replacement = @magic_comment_replacements.find { |marker, _| stripped == marker }
        next line unless replacement

        ending = line.end_with?("\n") ? "\n" : ""
        "// #{replacement[1].to_s.tr("\r\n", " ")}#{ending}"
      end.join

      replaced.b
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
