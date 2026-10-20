require "zip_kit"
require "zlib"
require "digest"
require "measurometer"

# Reading and writing of wheels - zip archives - for the PyPI side, the
# counterpart of Paquette::Tarball. zip_kit's FileReader finds the entries;
# the inflate is ours, because its own reader has no ceiling and zip_kit says
# as much about reading archives other people wrote.
module Paquette::Wheel
  # Raised for anything that cannot be read as a zip archive, or that is
  # bigger than this module is willing to inflate.
  class MalformedWheel < StandardError; end

  # One member of a wheel.
  #
  # @!attribute name
  #   @return [String]
  # @!attribute mode
  #   @return [Integer] unix permission bits
  # @!attribute mtime
  #   @return [Time]
  # @!attribute content
  #   @return [String]
  Entry = Struct.new(:name, :mode, :mtime, :content, keyword_init: true)

  # A wheel with more members than this is not one anybody built by hand.
  #
  # @return [Integer]
  MAX_ENTRIES = 100_000

  # The ceiling on a whole wheel inflated into memory for a repack.
  #
  # @return [Integer]
  MAX_INFLATED_BYTES = 1024 * 1024 * 1024

  # Compressed bytes per inflate step. Deflate tops out near 1:1032, so one
  # step can overshoot a ceiling by four megabytes and no more.
  #
  # @return [Integer]
  INFLATE_STEP = 4096

  # The earliest moment a DOS timestamp can carry
  #
  # @return [Time]
  DOS_EPOCH = Time.utc(1980, 1, 1)

  # The ZIP code for deflate
  #
  # @return [Integer]
  DEFLATED = 8
  # @return [Integer]
  STORED = 0

  class << self
    # The bytes of one member, or nil when there is no such member.
    #
    # @param wheel_path [String]
    # @param name [String]
    # @param limit [Integer] refuse to inflate past this many bytes
    # @return [String, nil]
    # @raise [MalformedWheel]
    def read_entry(wheel_path, name, limit:)
      Measurometer.instrument("paquette.wheel.read_entry") do
        with_structure(wheel_path) do |io, entries|
          entry = entries.find { |candidate| candidate.filename == name }
          entry && inflate(io, entry, limit)
        end
      end
    end

    # The member names, in the order they sit in the central directory.
    #
    # @param wheel_path [String]
    # @return [Array<String>]
    # @raise [MalformedWheel]
    def entry_names(wheel_path)
      with_structure(wheel_path) { |_io, entries| entries.map(&:filename) }
    end

    # Every file member, inflated. Directory members are dropped - a wheel
    # does not need them and pip does not look for them.
    #
    # @param wheel_path [String]
    # @return [Array<Entry>]
    # @raise [MalformedWheel]
    def entries(wheel_path)
      Measurometer.instrument("paquette.wheel.entries") do
        with_structure(wheel_path) do |io, entries|
          budget = MAX_INFLATED_BYTES
          entries.reject { |entry| entry.filename.end_with?("/") }.map do |entry|
            content = inflate(io, entry, budget)
            budget -= content.bytesize
            Entry.new(name: entry.filename, mode: unix_mode(entry), mtime: dos_time(entry), content: content)
          end
        end
      end
    end

    # Writes a wheel. Same entries in, same bytes out - pip checks the
    # sha256 the index published - so the order is the caller's, every
    # timestamp comes from the entry and nothing is stamped with the clock.
    # Byte-identical per zlib build, as with Paquette::Tarball.
    #
    # @param dest_path [String]
    # @param entries [Array<Entry>]
    # @return [String] dest_path
    def write(dest_path, entries)
      Measurometer.instrument("paquette.wheel.write") do
        File.open(dest_path, "wb") do |file|
          ZipKit::Streamer.open(file) do |zip|
            entries.each do |entry|
              content = entry.content.to_s.b
              compressed = deflate(content)
              zip.add_deflated_entry(filename: entry.name, modification_time: entry.mtime,
                compressed_size: compressed.bytesize, uncompressed_size: content.bytesize,
                crc32: Zlib.crc32(content), unix_permissions: normalized_mode(entry.mode))
              zip << compressed
            end
          end
        end
        dest_path
      end
    end

    # A RECORD line's hash: urlsafe base64 sha256 without the padding,
    # per the binary distribution format.
    #
    # @param content [String]
    # @return [String]
    def record_hash(content)
      "sha256=" + [Digest::SHA256.digest(content.to_s.b)].pack("m0").tr("+/", "-_").delete("=")
    end

    # A fresh RECORD for these entries. The signature files the old one may
    # have listed are the caller's to drop: whatever they signed is gone.
    #
    # @param entries [Array<Entry>]
    # @param record_name [String]
    # @return [String]
    def record_for(entries, record_name)
      lines = entries.reject { |entry| entry.name == record_name }.map do |entry|
        [csv_field(entry.name), record_hash(entry.content), entry.content.to_s.bytesize].join(",")
      end
      (lines + ["#{csv_field(record_name)},,"]).join("\n") + "\n"
    end

    private

    # @param wheel_path [String]
    # @yieldparam io [::File]
    # @yieldparam entries [Array<ZipKit::FileReader::ZipEntry>]
    # @return [Object] what the block returns
    # @raise [MalformedWheel]
    def with_structure(wheel_path)
      File.open(wheel_path, "rb") do |io|
        entries = Measurometer.instrument("paquette.wheel.read_structure") do
          ZipKit::FileReader.read_zip_structure(io: io)
        end
        raise MalformedWheel, "#{File.basename(wheel_path)} has more than #{MAX_ENTRIES} members" if entries.length > MAX_ENTRIES

        yield io, entries
      end
    rescue ZipKit::FileReader::ReadError, ZipKit::FileReader::UnsupportedFeature, ZipKit::FileReader::MissingEOCD,
      ZipKit::FileReader::LocalHeaderPending, Zlib::Error, RangeError => e
      raise MalformedWheel, "Could not read #{File.basename(wheel_path)}: #{e.message}"
    end

    # @param io [::File]
    # @param entry [ZipKit::FileReader::ZipEntry]
    # @param limit [Integer]
    # @return [String]
    # @raise [MalformedWheel]
    def inflate(io, entry, limit)
      if entry.uncompressed_size > limit
        raise MalformedWheel, "#{entry.filename} inflates to more than #{limit} bytes"
      end

      io.seek(entry.compressed_data_offset, IO::SEEK_SET)
      remaining = entry.compressed_size
      out = +"".b

      case entry.storage_mode
      when STORED
        out << io.read([remaining, limit + 1].min).to_s
      when DEFLATED
        inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        begin
          # The declared size is the uploader's word, so the ceiling is
          # checked against what actually comes out
          while remaining > 0 && !inflater.finished?
            chunk = io.read([INFLATE_STEP, remaining].min)
            break if chunk.nil?

            remaining -= chunk.bytesize
            out << inflater.inflate(chunk)
            raise MalformedWheel, "#{entry.filename} inflates to more than #{limit} bytes" if out.bytesize > limit
          end
        ensure
          inflater.close
        end
      else
        raise MalformedWheel, "#{entry.filename} uses storage mode #{entry.storage_mode}, which is not stored or deflated"
      end

      raise MalformedWheel, "#{entry.filename} inflates to more than #{limit} bytes" if out.bytesize > limit
      out
    end

    # @param data [String]
    # @return [String]
    def deflate(data)
      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      deflater.deflate(data, Zlib::FINISH)
    ensure
      deflater.close
    end

    # @param entry [ZipKit::FileReader::ZipEntry]
    # @return [Integer]
    def unix_mode(entry)
      (entry.external_attrs.to_i >> 16) & 0o777
    end

    # Only the executable bit survives, as in Paquette::Tarball
    #
    # @param mode [Integer]
    # @return [Integer]
    def normalized_mode(mode)
      ((mode.to_i & 0o111) != 0) ? 0o755 : 0o644
    end

    # The member's own DOS timestamp, so a repack keeps the dates it was built with.
    #
    # @param entry [ZipKit::FileReader::ZipEntry]
    # @return [Time]
    def dos_time(entry)
      date = entry.dos_date.to_i
      time = entry.dos_time.to_i
      Time.utc(1980 + (date >> 9), (date >> 5) & 0x0f, date & 0x1f, time >> 11, (time >> 5) & 0x3f, (time & 0x1f) * 2)
    rescue ArgumentError
      DOS_EPOCH
    end

    # RECORD is CSV, so a path with a comma or a quote in it gets quoted
    #
    # @param value [String]
    # @return [String]
    def csv_field(value)
      return value unless value.include?(",") || value.include?('"') || value.include?("\n")

      '"' + value.gsub('"', '""') + '"'
    end
  end
end
