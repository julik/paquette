require "rubygems/package"

# Gem::Package that reads the files it packs from a directory of the
# caller's choosing instead of from the working directory, silently.
# `gem build` only works because the CLI chdir's into the unpacked gem
# first — and chdir is process-global, so a server cannot do that. Only the
# two methods that reach outside are overridden; the .gem format itself
# stays RubyGems'.
class Paquette::GemServer::GemRepacker::RootedPackage < Gem::Package
  # Validation is deliberately skipped, and not to save time: it resolves
  # spec.files against the working directory and *prunes* to what it finds —
  # run from the wrong directory it quietly builds a gem with no files in
  # it. The caller prunes against +root+ instead.
  #
  # @param spec [Gem::Specification]
  # @param root [String] the directory spec.files are relative to
  # @param file_name [String] where the finished gem is written
  # @param build_time [Time] the timestamp stamped into the archive — see
  #   BuildTime for why this is a block around the build, not an argument
  # @return [String] file_name
  def self.build(spec, root, file_name, build_time:)
    Paquette::GemServer::GemRepacker::BuildTime.with(build_time) do
      package = new(file_name, nil)
      package.root = root
      package.spec = spec
      package.build(true)
    end

    file_name
  end

  # @return [String]
  attr_accessor :root

  # The RubyGems original with @root joined onto every path it looks at. The
  # names written into the tar stay relative, which is what a .gem holds.
  #
  # @param tar [Gem::Package::TarWriter]
  # @return [void]
  def add_files(tar)
    @spec.files.each do |file|
      source = File.join(@root, file)
      stat = File.lstat(source)

      if stat.symlink?
        tar.add_symlink file, File.readlink(source), stat.mode
      end

      next unless stat.file?

      tar.add_file_simple file, stat.mode, stat.size do |dst_io|
        File.open source, "rb" do |src_io|
          copy_stream(src_io, dst_io)
        end
      end
    end
  end

  # Gem::Package#build reports on stdout, which is what a person running
  # `gem build` asked for and not what a request asked for.
  #
  # @return [void]
  def say(*)
  end
end
