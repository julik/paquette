require "rubygems/package"

# Gem::Package that reads the files it packs from a directory of the caller's
# choosing instead of from the working directory, and says nothing while it
# does it.
#
# This exists because Gem::Package#add_files calls `File.lstat file` on each
# entry of spec.files, and those entries are relative — so `gem build` only
# works because the CLI has chdir'd into the unpacked gem first. A server
# cannot do that. The working directory is process-global, and a repack that
# chdir's for the length of a build moves every other thread in the process
# with it: a concurrent request resolving a relative path during those
# milliseconds resolves it inside somebody's gem.
#
# Overriding the two methods that reach outside — the one that opens files and
# the one that writes to stdout — keeps everything else RubyGems': the metadata
# member, the checksums member, the gzip framing, the tar headers. Nothing here
# re-implements the .gem format, which is the part that must not drift, because
# what a drifting .gem format looks like from a customer's terminal is a
# checksum mismatch on a gem they paid for.
class Paquette::GemServer::GemRepacker::RootedPackage < Gem::Package
  # +root+ is the directory spec.files are relative to, +file_name+ is where
  # the finished gem is written, and +build_time+ is the timestamp stamped into
  # the archive — see BuildTime for why that is a block around the build rather
  # than an argument RubyGems takes.
  #
  # Validation is deliberately skipped, and not to save time: Gem::Specification
  # validation also resolves file names against the working directory, and it
  # *prunes* spec.files to what it finds there rather than failing. Run from the
  # wrong directory it does not raise — it quietly builds a gem with no files in
  # it. The caller prunes against +root+ instead, which is the same check asked
  # in the right place.
  def self.build(spec, root, file_name, build_time:)
    Paquette::GemServer::GemRepacker::BuildTime.with(build_time) do
      package = new(file_name, nil)
      package.root = root
      package.spec = spec
      package.build(true)
    end

    file_name
  end

  attr_accessor :root

  # The RubyGems original with @root joined onto every path it looks at. The
  # names written into the tar stay relative, which is what a .gem holds.
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

  # Gem::Package#build reports what it built on stdout, which is what a person
  # running `gem build` asked for and not what a request asked for. Swallowed
  # here rather than by swapping Gem's UI out around the call, because that UI
  # is another process-global and this is a method call.
  def say(*)
  end
end
