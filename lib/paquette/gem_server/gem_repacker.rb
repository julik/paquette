require "rubygems"
require "rubygems/package"
require "rubygems/user_interaction"
require "fileutils"
require "digest"
require "tmpdir"
require "tempfile"
require "zlib"
require "measurometer"

# Rewrites the contents of a .gem into a new, byte-reproducible .gem —
# replacing magic comment lines, merging gemspec metadata and injecting files.
class Paquette::GemServer::GemRepacker
  autoload :BuildTime, "#{__dir__}/gem_repacker/build_time"
  autoload :RootedPackage, "#{__dir__}/gem_repacker/rooted_package"

  # Bumped whenever the same source gem and the same arguments would repack
  # into different bytes, so a cache keyed on the inputs can include it.
  # 2: file modes come from the source gem rather than the unpacked copy.
  #
  # @return [Integer]
  FORMAT_VERSION = 2

  # What `gem build` records for a plain file on a umask-022 machine, given
  # to a file the source gem did not have.
  #
  # @return [Integer]
  INJECTED_FILE_MODE = 0o100644

  # One-shot convenience for {#initialize} + {#repack}.
  #
  # @param gem_path [String]
  # @param gemspec_extras [Hash{String => String}]
  # @param magic_comment_replacements [Hash{String => String}]
  # @param files [Hash{String => String}]
  # @param into [String, nil]
  # @return [String] the path of the repacked gem
  def self.repack(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block)
    new(gem_path, gemspec_extras: gemspec_extras, magic_comment_replacements: magic_comment_replacements, files: files, into: into).repack(&block)
  end

  # @param gem_path [String] path of the source .gem
  # @param gemspec_extras [Hash{String => String}] keys merged into the
  #   gemspec metadata
  # @param magic_comment_replacements [Hash{String => String}] whole comment
  #   lines to replace, marker => replacement
  # @param files [Hash{String => String}] files to inject, path relative to
  #   the gem root => content
  # @param into [String, nil] destination path; without it the gem lands
  #   in a fresh tmpdir whose cleanup becomes the caller's problem.
  def initialize(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil)
    @gem_path = gem_path
    @gemspec_extras = gemspec_extras
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @into = into
    @temp_dir = nil
    @unpacked_gem_dir = nil
    @entry_modes = nil
  end

  # Four subprocess-and-disk stages, each timed separately: a repack that
  # got slow is almost always one of them.
  #
  # @return [String] the path of the repacked gem
  def repack
    raise ArgumentError, "Gem file not found: #{@gem_path}" unless File.exist?(@gem_path)

    Measurometer.instrument("paquette.gem_repacker.repack") do
      Measurometer.instrument("paquette.gem_repacker.unpack") { unpack_gem }
      Measurometer.instrument("paquette.gem_repacker.process_ruby_files") { process_ruby_files }
      Measurometer.instrument("paquette.gem_repacker.inject_files") { inject_files }
      Measurometer.instrument("paquette.gem_repacker.repackage") { repackage_gem }
    end
  ensure
    # In an ensure: a repack that raises used to leave its working directory
    # in the system temp directory, one per failure, forever.
    cleanup
  end

  private

  # `gem unpack` in-process: shelling out cost ~0.5s of RubyGems boot per
  # gem. The span keeps its old name; the graphs watching it are older.
  #
  # @return [void]
  def unpack_gem
    @temp_dir = Dir.mktmpdir("gem_repacker")
    @unpacked_gem_dir = File.join(@temp_dir, "unpacked_gem")

    package = Gem::Package.new(@gem_path)
    @gem_dir = File.join(@unpacked_gem_dir, package.spec.full_name)
    FileUtils.mkdir_p(@gem_dir)

    Measurometer.instrument("paquette.gem_repacker.gem_unpack") do
      package.extract_files(@gem_dir)
    end
    @entry_modes = source_entry_modes
  rescue Gem::Exception => e
    raise "Failed to unpack gem: #{@gem_path}. Error: #{e.message}"
  end

  # @return [void]
  def process_ruby_files
    rb_files = Dir.glob(File.join(@gem_dir, "**", "*.rb"))
    Measurometer.add_distribution_value("paquette.gem_repacker.ruby_files", rb_files.length)
    rb_files.each { |rb_file| process_ruby_file(rb_file) }
  end

  # The mode of every entry in the source gem's data.tar.gz, as its packer
  # wrote it. The repack writes these back rather than what is on disk:
  # extraction masks each mode with this process's umask, and the .rb files
  # are rewritten through a Tempfile created 0600, so the disk says more
  # about the server than about the gem.
  #
  # @return [Hash{String => Integer}] entry name => mode
  def source_entry_modes
    modes = {}
    File.open(@gem_path, "rb") do |io|
      Gem::Package::TarReader.new(io).each do |entry|
        next unless entry.full_name == "data.tar.gz"
        Zlib::GzipReader.wrap(entry) do |gz|
          Gem::Package::TarReader.new(gz).each { |file| modes[file.full_name] = file.header.mode }
        end
      end
    end
    modes
  end

  # A file that replaces one the gem shipped keeps that file's mode. Removed
  # before it is written, because the one it replaces may have been shipped
  # read-only.
  #
  # @return [void]
  def inject_files
    @files.each do |file_path, content|
      full_path = File.join(@gem_dir, file_path)
      FileUtils.mkdir_p(File.dirname(full_path))
      FileUtils.rm_f(full_path)
      File.write(full_path, content)
      @entry_modes[file_path] ||= INJECTED_FILE_MODE
    end
  end

  # @param file_path [String]
  # @return [void]
  def process_ruby_file(file_path)
    temp_output = Tempfile.new("gem_repacker_output")

    File.open(file_path, "rb") do |input_file|
      temp_output.binmode

      if @magic_comment_replacements.any?
        apply_magic_comment_replacements(input_file, temp_output)
      else
        IO.copy_stream(input_file, temp_output)
      end

      temp_output.flush
    end

    FileUtils.mv(temp_output.path, file_path)
  ensure
    temp_output.close
    temp_output.unlink if File.exist?(temp_output.path)
  end

  # @param input_file [IO]
  # @param output_file [IO]
  # @return [void]
  def apply_magic_comment_replacements(input_file, output_file)
    input_file.each_line do |line|
      replacement_found = false
      @magic_comment_replacements.each do |magic_comment, replacement_value|
        if line.chomp == magic_comment
          output_file.puts("# #{replacement_value}\n")
          IO.copy_stream(input_file, output_file) # Copy the rest
          replacement_found = true
          break
        end
      end

      unless replacement_found
        output_file.write(line)
      end
    end
  end

  # @return [String] the path of the finished gem
  def repackage_gem
    original_spec = Gem::Package.new(@gem_path).spec

    # Not "#{gem_name}-repacked.gem" in the shared tmpdir, which is what two
    # repacks of one gem used to overwrite each other in.
    gem_name = File.basename(@gem_path, ".gem")
    final_gem_path = @into || File.join(Dir.mktmpdir("gem_repacked"), "#{gem_name}-repacked.gem")
    FileUtils.mkdir_p(File.dirname(final_gem_path))

    # Pinning the build time to the source gem's own date is what makes a
    # repack reproducible — RubyGems otherwise stamps the clock into the
    # gzip headers and tar mtimes. See BuildTime.
    Measurometer.instrument("paquette.gem_repacker.gem_build") do
      Paquette::GemServer::GemRepacker::RootedPackage.build(
        repacked_spec(original_spec), @gem_dir, final_gem_path,
        build_time: original_spec.date,
        modes: @entry_modes
      )
    end

    final_gem_path
  end

  # The original spec with this repack's additions, built in memory rather
  # than via a .gemspec on disk: Gem::Specification.load memoizes per file
  # path forever, which leaked one spec per gem served.
  #
  # @param spec [::Gem::Specification]
  # @return [::Gem::Specification]
  def repacked_spec(spec)
    new_spec = spec.dup

    # dup is shallow and these are the two collections being added to.
    # Sorted, because the output is hashed and an unsorted merge writes the
    # same information into different bytes.
    new_spec.metadata = spec.metadata.merge(@gemspec_extras).sort.to_h
    files = spec.files.dup
    @files.each_key { |path| files << path unless files.include?(path) }

    # The prune Gem::Specification validation would do, asked against the
    # directory the files are actually in.
    new_spec.files = files.select { |path| File.exist?(File.join(@gem_dir, path)) }

    new_spec
  end

  # @return [void]
  def cleanup
    FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
  end
end
