require "rubygems/package"
require "zlib"
require "stringio"
require "digest"
require "json"
require "measurometer"

module Paquette
  # Reading and writing of npm tarballs, hand-rolled rather than built on
  # Gem::Package::TarWriter/TarReader:
  # - A repack must come out byte-identical, because npm checks dist.integrity
  #   against what it downloads and the Personalizer repacks per licensee.
  #   TarWriter takes its entry mtime from Gem.source_date_epoch, a
  #   process-global env var rather than an argument, which a threaded server
  #   cannot vary per request and which would flatten every entry to one
  #   timestamp instead of keeping the source's. Zlib::GzipWriter likewise
  #   writes the host OS byte into the header.
  # - Neither side speaks PAX: TarWriter raises TooLongFileName instead of
  #   emitting an extended header, and TarReader ignores one when reading, so a
  #   path too long for ustar cannot survive a repack.
  module Tarball
    class MalformedTarball < StandardError; end

    class NameTooLong < StandardError; end

    Entry = Struct.new(:name, :mode, :mtime, :content, keyword_init: true)

    BLOCK_SIZE = 512

    GZIP_MAGIC = "\x1f\x8b".b
    GZIP_DEFLATE = 8
    GZIP_OS_UNKNOWN = 255

    class << self
      def each_entry(tarball_path)
        return enum_for(:each_entry, tarball_path) unless block_given?

        # Inflated in one go: a caller stopping early would leave a GzipReader mid-stream.
        # Only the inflate is timed: the tar walk below yields to the caller, and
        # timing that would charge the caller's work to this method.
        inflated = Measurometer.instrument("paquette.tarball.gunzip") { Zlib.gunzip(File.binread(tarball_path)) }
        Measurometer.add_distribution_value("paquette.tarball.inflated_bytes", inflated.bytesize)
        tar = StringIO.new(inflated)

        # TarReader hands PAX "x" records through as ordinary entries; honored here.
        pending_path = nil

        Gem::Package::TarReader.new(tar).each do |tar_entry|
          if tar_entry.header.typeflag == "x"
            pending_path = pax_path(tar_entry.read.to_s)
            next
          end

          name = pending_path || tar_entry.full_name
          pending_path = nil

          next unless tar_entry.file?

          yield Entry.new(
            name: name,
            mode: tar_entry.header.mode,
            mtime: tar_entry.header.mtime,
            content: tar_entry.read || ""
          )
        end
      rescue Zlib::GzipFile::Error, Zlib::BufError, Zlib::DataError, Gem::Package::TarInvalidError => e
        raise MalformedTarball, "Could not read tarball #{tarball_path}: #{e.message}"
      end

      def entries(tarball_path)
        Measurometer.instrument("paquette.tarball.entries") do
          each_entry(tarball_path).to_a.tap do |all|
            Measurometer.add_distribution_value("paquette.tarball.entry_count", all.length)
          end
        end
      end

      # By basename under the root: a `git archive` tarball may not use "package".
      def package_json(tarball_path)
        Measurometer.instrument("paquette.tarball.package_json") do
          each_entry(tarball_path) do |entry|
            next unless entry.name.count("/") == 1
            next unless File.basename(entry.name) == "package.json"

            begin
              return JSON.parse(as_text(entry.content))
            rescue JSON::ParserError => e
              raise MalformedTarball, "package.json in #{tarball_path} is not valid JSON: #{e.message}"
            end
          end
          nil
        end
      end

      def pax_path(records)
        offset = 0
        while offset < records.bytesize
          space = records.index(" ", offset)
          break unless space

          length = records[offset...space].to_i
          break if length <= 0

          record = records[(space + 1), length - (space - offset) - 2].to_s
          key, _, value = record.partition("=")
          return value if key == "path"

          offset += length
        end
        nil
      end

      # ASCII-8BIT bytes make JSON.generate raise; scrub rather than 500 the metadata.
      def as_text(content)
        content.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def root_dir(tarball_path)
        Measurometer.instrument("paquette.tarball.root_dir") do
          each_entry(tarball_path) { |entry| return entry.name.split("/").first }
          nil
        end
      end

      # Entries are sorted by name so caller ordering cannot change the bytes.
      def write(dest_path, entries)
        Measurometer.instrument("paquette.tarball.write") do
          tar = +"".b
          entries.sort_by(&:name).each do |entry|
            content = entry.content.to_s.b
            tar << pax_header_for(entry) unless ustar_representable?(entry.name)
            tar << header_for(entry.name, entry.mode, entry.mtime, content.bytesize)
            tar << content
            tar << "\0" * (-content.bytesize % BLOCK_SIZE)
          end
          tar << "\0" * (BLOCK_SIZE * 2)

          File.binwrite(dest_path, gzip(tar))
          dest_path
        end
      end

      # MTIME zero, OS "unknown". Reproducibility holds per zlib build only, so
      # several Paquettes behind one load balancer must share a zlib.
      def gzip(data)
        Measurometer.instrument("paquette.tarball.gzip") do
          data = data.b
          Measurometer.add_distribution_value("paquette.tarball.deflated_bytes", data.bytesize)
          header = GZIP_MAGIC + [GZIP_DEFLATE, 0, 0, 0, GZIP_OS_UNKNOWN].pack("CCVCC")
          deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
          body = begin
            deflater.deflate(data, Zlib::FINISH)
          ensure
            deflater.close
          end
          header + body + [Zlib.crc32(data), data.bytesize].pack("VV")
        end
      end

      def integrity(tarball_path)
        Measurometer.instrument("paquette.tarball.integrity") do
          {
            shasum: Digest::SHA1.file(tarball_path).hexdigest,
            integrity: "sha512-" + [Digest::SHA512.file(tarball_path).digest].pack("m0")
          }
        end
      end

      private

      # uid/gid/uname/gname are zeroed: they describe the packer, not the package.
      def header_for(name, mode, mtime, size, typeflag: "0")
        # An over-long name is already in a PAX record; this tail is the fallback.
        prefix, name = split_name(name) || ["", name.to_s.b[-100..]]

        header = +"\0".b * BLOCK_SIZE
        write_field(header, 0, 100, name)
        write_field(header, 100, 8, "%07o" % normalized_mode(mode))
        write_field(header, 108, 8, "%07o" % 0)
        write_field(header, 116, 8, "%07o" % 0)
        write_field(header, 124, 12, "%011o" % size)
        write_field(header, 136, 12, "%011o" % mtime.to_i)
        header[148, 8] = " " * 8
        write_field(header, 156, 1, typeflag)
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

      # ustar's prefix/name split; nil when no split works (PAX header instead).
      def split_name(name)
        name = name.to_s.b
        return ["", name] if name.bytesize <= 100

        separators = []
        offset = -1
        separators << offset while (offset = name.index("/", offset + 1))

        split_at = separators.find { |at| at <= 155 && (name.bytesize - at - 1) <= 100 }
        return nil if split_at.nil?

        [name[0, split_at], name[(split_at + 1)..]]
      end

      def ustar_representable?(name)
        !split_name(name).nil?
      end

      # Also written, or a package that stored fine would fail once personalized.
      def pax_header_for(entry)
        record = pax_record("path", entry.name)
        header = header_for(pax_header_name(entry.name), 0o644, entry.mtime, record.bytesize, typeflag: "x")
        header + record + "\0" * (-record.bytesize % BLOCK_SIZE)
      end

      # "LENGTH key=value\n"; LENGTH counts its own digits, so grow until stable.
      def pax_record(key, value)
        body = " #{key}=#{value}\n".b
        digits = body.bytesize.to_s.bytesize
        digits += 1 while (body.bytesize + digits).to_s.bytesize > digits

        (body.bytesize + digits).to_s.b + body
      end

      def pax_header_name(name)
        "PaxHeader/#{File.basename(name.to_s.b)}"[0, 100]
      end

      # Only the executable bit survives; anything else is the packer's umask.
      def normalized_mode(mode)
        ((mode.to_i & 0o111) != 0) ? 0o755 : 0o644
      end
    end
  end
end
