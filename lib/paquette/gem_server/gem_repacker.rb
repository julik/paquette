require "rubygems"
require "rubygems/package"
require "rubygems/user_interaction"
require "fileutils"
require "digest"
require "tmpdir"
require "tempfile"
require "measurometer"

class Paquette::GemServer::GemRepacker
  autoload :BuildTime, "#{__dir__}/gem_repacker/build_time"
  autoload :RootedPackage, "#{__dir__}/gem_repacker/rooted_package"

  # `into:` is a file path the caller has somewhere it owns — a directory it
  # made and will take away again. Given one, the finished gem is written
  # there and this leaves nothing behind at all.
  #
  # Without it the gem lands in a fresh directory of ours and the caller is
  # handed the path, which makes cleaning that directory the caller's
  # problem. That is a bad bargain and `into:` is how a caller declines it:
  # nobody should be deleting a directory somebody else chose, and a caller
  # that tries ends up calling a recursive delete on whatever it was given —
  # the system temp directory included.
  def self.repack(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil, &block)
    new(gem_path, gemspec_extras: gemspec_extras, magic_comment_replacements: magic_comment_replacements, files: files, into: into).repack(&block)
  end

  def initialize(gem_path, gemspec_extras: {}, magic_comment_replacements: {}, files: {}, into: nil)
    @gem_path = gem_path
    @gemspec_extras = gemspec_extras
    @magic_comment_replacements = magic_comment_replacements
    @files = files
    @into = into
    @temp_dir = nil
    @unpacked_gem_dir = nil
  end

  # Four subprocess-and-disk stages, each timed separately: a repack that
  # got slow is almost always one of them, and the whole-repack number on
  # its own cannot say which.
  def repack
    raise ArgumentError, "Gem file not found: #{@gem_path}" unless File.exist?(@gem_path)

    Measurometer.instrument("paquette.gem_repacker.repack") do
      Measurometer.instrument("paquette.gem_repacker.unpack") { unpack_gem }
      Measurometer.instrument("paquette.gem_repacker.process_ruby_files") { process_ruby_files }
      Measurometer.instrument("paquette.gem_repacker.inject_files") { inject_files }
      Measurometer.instrument("paquette.gem_repacker.repackage") { repackage_gem }
    end
  ensure
    # In an ensure, not after the repackage: a repack that raises — a gem
    # that will not unpack, a full disk — used to leave its working directory
    # in the system temp directory, one per failure, forever.
    cleanup
  end

  private

  # `gem unpack` in the same process. The CLI did exactly this — extract the
  # data member into `target/<full_name>/` — around half a second of Ruby and
  # RubyGems startup, paid per gem. A registry personalizing an index pays it
  # per version of every gem in the corpus, so on a cold cache the boots were
  # the larger half of the request. The span keeps its name: what it measures
  # is the same work, and the graphs that watch it are older than this change.
  def unpack_gem
    @temp_dir = Dir.mktmpdir("gem_repacker")
    @unpacked_gem_dir = File.join(@temp_dir, "unpacked_gem")

    package = Gem::Package.new(@gem_path)
    @gem_dir = File.join(@unpacked_gem_dir, package.spec.full_name)
    FileUtils.mkdir_p(@gem_dir)

    Measurometer.instrument("paquette.gem_repacker.gem_unpack") do
      package.extract_files(@gem_dir)
    end
  rescue Gem::Exception => e
    raise "Failed to unpack gem: #{@gem_path}. Error: #{e.message}"
  end

  def process_ruby_files
    rb_files = Dir.glob(File.join(@gem_dir, "**", "*.rb"))
    Measurometer.add_distribution_value("paquette.gem_repacker.ruby_files", rb_files.length)
    rb_files.each { |rb_file| process_ruby_file(rb_file) }
  end

  def inject_files
    @files.each do |file_path, content|
      # Ensure the file path is relative to the gem directory
      full_path = File.join(@gem_dir, file_path)

      # Create parent directories if they don't exist
      FileUtils.mkdir_p(File.dirname(full_path))

      # Write the file content
      File.write(full_path, content)
    end
  end

  def process_ruby_file(file_path)
    # Create a temporary file for output
    temp_output = Tempfile.new("gem_repacker_output")

    # Open input file in binary mode for reading
    File.open(file_path, "rb") do |input_file|
      # Set temp file to binary mode
      temp_output.binmode

      # Apply magic comment replacements if any are defined
      if @magic_comment_replacements.any?
        apply_magic_comment_replacements(input_file, temp_output)
      else
        # Just copy the file as-is if no magic comment replacements
        IO.copy_stream(input_file, temp_output)
      end

      # Flush the temp file to ensure all data is written
      temp_output.flush
    end

    # Replace the original file with the processed content
    FileUtils.mv(temp_output.path, file_path)
  ensure
    temp_output.close
    temp_output.unlink if File.exist?(temp_output.path)
  end

  def apply_magic_comment_replacements(input_file, output_file)
    input_file.each_line do |line|
      # Check if this line matches any of our magic comment replacements
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

  def repackage_gem
    original_spec = Gem::Package.new(@gem_path).spec

    # Where the caller asked for it, or somewhere of its own. Not
    # "#{gem_name}-repacked.gem" in the shared tmpdir, which is what two
    # repacks of one gem — two licensees, or one licensee and the checksum
    # pass — used to overwrite each other in.
    gem_name = File.basename(@gem_path, ".gem")
    final_gem_path = @into || File.join(Dir.mktmpdir("gem_repacked"), "#{gem_name}-repacked.gem")
    FileUtils.mkdir_p(File.dirname(final_gem_path))

    # The build time is what makes a repack reproducible, and without pinning
    # it this method could not be used for anything a checksum is published
    # for.
    #
    # A .gem is a tar of three gzip members, and a gzip header carries the
    # time it was written. RubyGems takes that time, and the mtimes of the
    # inner tar entries, from the clock unless told otherwise — so the same
    # inputs repacked a second apart came out with different bytes and a
    # different SHA256 while inflating to exactly the same content. Anything
    # that published a checksum and then rebuilt the gem to serve it was
    # therefore publishing a checksum for bytes nobody would ever receive,
    # and `bundle install` reports that as a mismatch, which reads to a
    # customer as a tampered gem.
    #
    # The time is the original gem's own date, so a repack is pinned to the
    # thing it was made from rather than to a build clock: the same source
    # gem and the same personalization produce one answer, on any machine,
    # at any time. How it gets there without ENV, which would make two
    # repacks at once share one timestamp, is BuildTime's business.
    Measurometer.instrument("paquette.gem_repacker.gem_build") do
      Paquette::GemServer::GemRepacker::RootedPackage.build(
        repacked_spec(original_spec), @gem_dir, final_gem_path,
        build_time: original_spec.date
      )
    end

    final_gem_path
  end

  # The original spec with this repack's additions, built in memory.
  #
  # `gem build` needed a .gemspec file on disk to read, and the round trip
  # through Gem::Specification#to_ruby and .load is how this used to make one.
  # Gem::Specification.load memoizes what it loads against the file path it
  # loaded it from, and every repack writes its gemspec to a path of its own —
  # so in a long-running server that cache grew by one whole specification per
  # gem served and never shrank. Building the spec here instead produces the
  # same archive, minus the leak.
  def repacked_spec(spec)
    new_spec = spec.dup

    # dup is shallow and these are the two collections being added to. Left
    # shared, the additions would also land on the spec the caller may still
    # be holding.
    # Sorted, because Gem::Specification#to_ruby sorted it and this used to go
    # through to_ruby — an unsorted merge writes the same information into a
    # different YAML document, and "the same information" is not the bar when
    # the output is hashed.
    new_spec.metadata = spec.metadata.merge(@gemspec_extras).sort.to_h
    files = spec.files.dup
    @files.each_key { |path| files << path unless files.include?(path) }

    # What Gem::Specification validation does before a build, asked against
    # the directory the files are actually in. A source gem whose spec names
    # a file the archive does not carry stays buildable, which is what it was
    # before; the difference is that this cannot silently prune everything.
    new_spec.files = files.select { |path| File.exist?(File.join(@gem_dir, path)) }

    new_spec
  end

  def cleanup
    FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
  end
end
