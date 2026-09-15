require "fileutils"
require "digest"
require "tmpdir"
require "stringio"
require "json"
require_relative "tarball"

module Paquette
  # Rewrites the contents of an npm tarball and packs the result into a new one.
  #
  # The counterpart of GemServer::GemRepacker, and it takes the same options for
  # the same reasons — `magic_comment_replacements` to rewrite a marker line in
  # source files, `files:` to put whole files in, `into:` to say where the result
  # should land — plus `package_json_extras:`, which is where the npm equivalent
  # of the gem's `gemspec_extras` goes.
  #
  # A repack is byte-reproducible: identical inputs produce an identical
  # tarball. Paquette::Tarball explains why that is load-bearing rather than
  # tidy — npm verifies `dist.integrity` against the bytes it receives, so a
  # registry that publishes a hash and then rebuilds the tarball must rebuild it
  # to the same bytes.
  class NpmRepacker
    # Extensions whose contents are eligible for magic-comment replacement. A
    # binary asset or a sourcemap is copied through untouched.
    SOURCE_EXTENSIONS = %w[.js .mjs .cjs .jsx .ts .tsx .mts .cts].freeze

    # `into:` is a file path the caller has somewhere it owns — a directory it
    # made and will take away again. Given one, the finished tarball is written
    # there and this leaves nothing behind. Without it the tarball lands in a
    # fresh directory of ours and cleaning it up becomes the caller's problem.
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

    # With a block, every file in the package is handed to it as
    # (input_io, output_io, relative_path) and whatever the block writes becomes
    # that file's new content — the path being relative to the package root, so
    # a block sees "dist/index.js" rather than "package/dist/index.js".
    #
    # Without a block the options alone do the work, which is how the
    # Personalizer uses this.
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

    # A marker line is replaced by a line, never by more or fewer of them.
    #
    # npm packages ship sourcemaps, and a sourcemap addresses generated code by
    # line and column. Inserting or removing a line shifts every mapping below
    # it, which would silently misalign every stack trace a customer sees in
    # code we personalized. Keeping the replacement to one line means the
    # sourcemaps that came with the package stay correct without being
    # rewritten at all.
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

    # The npm counterpart of the gem repacker's `gemspec_extras`: keys merged
    # into package.json. Merged shallowly at the top level, so a caller can add
    # its own namespaced key without disturbing anything npm reads.
    def apply_package_json_extras(entries, root)
      return entries if @package_json_extras.empty?

      package_json_name = "#{root}/package.json"
      entries.map do |entry|
        next entry unless entry.name == package_json_name

        parsed = JSON.parse(entry.content)
        with_content(entry, JSON.pretty_generate(parsed.merge(@package_json_extras)))
      end
    end

    # {path => content}, with paths relative to the package root. An injected
    # file replaces one already there under the same path, and inherits the
    # mtime the package was built with so that adding a file does not make the
    # tarball depend on when it was added.
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
