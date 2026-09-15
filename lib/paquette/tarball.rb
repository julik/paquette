require "rubygems/package"
require "zlib"
require "stringio"
require "digest"
require "json"

module Paquette
  # Reading and writing of npm tarballs (a gzipped tar with everything under a
  # single "package/" directory).
  #
  # Writing is deliberately byte-reproducible: the same entries produce the same
  # file on every run. That is not a nicety. npm records `dist.integrity` (and
  # `dist.shasum`) in the registry metadata and checks the tarball it downloads
  # against them — so a registry that rebuilds a tarball in order to serve it,
  # as the Personalizer does, must rebuild it to the same bytes it published a
  # hash for. A tar that carries the current time, or a gzip header that does,
  # yields a different hash every second while inflating to exactly the same
  # files, and npm reports that to the user as a corrupted package.
  #
  # The tar header is written here rather than through Gem::Package::TarWriter
  # because that writer stamps Time.now as the entry mtime with no way to say
  # otherwise, and patching its output afterwards means parsing back what was
  # just written.
  module Tarball
    class MalformedTarball < StandardError; end

    class NameTooLong < StandardError; end

    Entry = Struct.new(:name, :mode, :mtime, :content, keyword_init: true)

    BLOCK_SIZE = 512

    # gzip's MTIME field is written as zero — "no timestamp available", which is
    # exactly the claim we want to make — and the OS byte as "unknown" rather
    # than the host's, which would otherwise make one machine's tarball differ
    # from another's.
    GZIP_MAGIC = "\x1f\x8b".b
    GZIP_DEFLATE = 8
    GZIP_OS_UNKNOWN = 255

    class << self
      # Yields an Entry for every regular file in the tarball, with the path as
      # recorded (including the leading "package/").
      def each_entry(tarball_path)
        return enum_for(:each_entry, tarball_path) unless block_given?

        # Inflated in one go rather than streamed, because a caller that stops
        # early — package_json wants one entry out of fifty — leaves a
        # GzipReader mid-stream, and closing one of those warns about an
        # unfinished zstream. The contents are read into memory entry by entry
        # regardless, so this costs nothing that was not already being spent.
        tar = StringIO.new(Zlib.gunzip(File.binread(tarball_path)))

        Gem::Package::TarReader.new(tar).each do |tar_entry|
          next unless tar_entry.file?

          yield Entry.new(
            name: tar_entry.full_name,
            mode: tar_entry.header.mode,
            mtime: tar_entry.header.mtime,
            content: tar_entry.read || ""
          )
        end
      rescue Zlib::GzipFile::Error, Zlib::BufError, Zlib::DataError, Gem::Package::TarInvalidError => e
        raise MalformedTarball, "Could not read tarball #{tarball_path}: #{e.message}"
      end

      def entries(tarball_path)
        each_entry(tarball_path).to_a
      end

      # The parsed package.json of a package tarball, or nil when there is none.
      #
      # The entry is found by basename directly under the single root directory
      # rather than by the literal path "package/package.json": npm publishes
      # with that root, but a tarball produced by `git archive` or by some other
      # packing step may use the package's own name, and refusing to read those
      # would be refusing them for no reason.
      def package_json(tarball_path)
        each_entry(tarball_path) do |entry|
          next unless entry.name.count("/") == 1
          next unless File.basename(entry.name) == "package.json"

          begin
            return JSON.parse(entry.content)
          rescue JSON::ParserError => e
            raise MalformedTarball, "package.json in #{tarball_path} is not valid JSON: #{e.message}"
          end
        end
        nil
      end

      # The name of the single root directory inside the tarball ("package" for
      # anything npm produced), or nil for an empty tarball.
      def root_dir(tarball_path)
        each_entry(tarball_path) { |entry| return entry.name.split("/").first }
        nil
      end

      # Writes `entries` as a gzipped tar at `dest_path`, and returns that path.
      #
      # Entries are sorted by name so that the caller's ordering — which for a
      # repack comes out of a Hash, and before that out of a directory listing —
      # cannot change the bytes.
      def write(dest_path, entries)
        tar = +"".b
        entries.sort_by(&:name).each do |entry|
          content = entry.content.to_s.b
          tar << header_for(entry.name, entry.mode, entry.mtime, content.bytesize)
          tar << content
          tar << "\0" * (-content.bytesize % BLOCK_SIZE)
        end
        # Two zero blocks mark the end of the archive.
        tar << "\0" * (BLOCK_SIZE * 2)

        File.binwrite(dest_path, gzip(tar))
        dest_path
      end

      # Raw deflate inside a hand-built gzip envelope. See GZIP_OS_UNKNOWN above
      # for why Zlib::GzipWriter is not used.
      def gzip(data)
        data = data.b
        header = GZIP_MAGIC + [GZIP_DEFLATE, 0, 0, 0, GZIP_OS_UNKNOWN].pack("CCVCC")
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        body = begin
          deflater.deflate(data, Zlib::FINISH)
        ensure
          deflater.close
        end
        header + body + [Zlib.crc32(data), data.bytesize].pack("VV")
      end

      # npm's own hashes for a tarball: sha1 in `dist.shasum` (legacy, but still
      # sent by every client and checked by some) and an SRI string in
      # `dist.integrity`, which is what a modern npm actually verifies.
      def integrity(tarball_path)
        {
          shasum: Digest::SHA1.file(tarball_path).hexdigest,
          integrity: "sha512-" + [Digest::SHA512.file(tarball_path).digest].pack("m0")
        }
      end

      private

      # A ustar header block. uid/gid are zero and uname/gname empty because
      # they describe whoever happened to pack the file rather than anything
      # about the package, and would differ between two machines repacking the
      # same input.
      def header_for(name, mode, mtime, size)
        prefix, name = split_name(name)

        header = +"\0".b * BLOCK_SIZE
        write_field(header, 0, 100, name)
        write_field(header, 100, 8, "%07o" % normalized_mode(mode))
        write_field(header, 108, 8, "%07o" % 0)
        write_field(header, 116, 8, "%07o" % 0)
        write_field(header, 124, 12, "%011o" % size)
        write_field(header, 136, 12, "%011o" % mtime.to_i)
        # The checksum is computed with its own field read as spaces, then
        # written back over them.
        header[148, 8] = " " * 8
        write_field(header, 156, 1, "0") # regular file
        write_field(header, 257, 6, "ustar\0")
        write_field(header, 263, 2, "00")
        write_field(header, 345, 155, prefix)

        header[148, 8] = ("%06o\0 " % header.bytes.sum)
        header
      end

      def write_field(header, offset, length, value)
        value = value.to_s.b
        raise NameTooLong, "Field does not fit in #{length} bytes: #{value.inspect}" if value.bytesize > length
        header[offset, value.bytesize] = value
      end

      # ustar stores a path longer than 100 bytes as a 155-byte prefix plus a
      # 100-byte name, split on a "/". Deep node_modules-ish paths do reach
      # this, so it is handled rather than left to blow up on a real package.
      def split_name(name)
        name = name.to_s.b
        return ["", name] if name.bytesize <= 100

        # The split has to land on a separator, with at most 155 bytes before it
        # and at most 100 after. Any separator satisfying both will do.
        separators = []
        offset = -1
        separators << offset while (offset = name.index("/", offset + 1))

        split_at = separators.find { |at| at <= 155 && (name.bytesize - at - 1) <= 100 }
        raise NameTooLong, "Path cannot be represented in a ustar header: #{name}" if split_at.nil?

        [name[0, split_at], name[(split_at + 1)..]]
      end

      # Only the executable bit is carried over, as 0755 or 0644. A tarball
      # otherwise records the umask of whoever packed it.
      def normalized_mode(mode)
        ((mode.to_i & 0o111) != 0) ? 0o755 : 0o644
      end
    end
  end
end
