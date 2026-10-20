# Abstract base class for Python package repositories; mirrors NpmRepository.
#
# A project is addressed by its PEP 503 normalized name ("acme-widgets"), and
# what it holds are distribution files - wheels and sdists - each named the way
# PyPA's specifications name them. The version is read out of the filename.
class Paquette::PypiServer::PypiRepository
  # What the Simple API says about one file.
  #
  # - `sha256`: hex digest of the bytes served
  # - `yanked`: the yank reason, possibly empty, or false
  # - `core_metadata_sha256`: hex digest of the PEP 658 metadata file, nil
  #   when there is none to serve
  DistributionFile = Struct.new(
    :filename, #: String
    :version, #: String
    :sha256, #: String
    :size, #: Integer
    :requires_python, #: String?
    :upload_time, #: Time?
    :yanked, #: String | false
    :core_metadata_sha256, #: String?
    keyword_init: true
  )

  def initialize
    raise NotImplementedError, "PypiRepository is an abstract class"
  end

  # Returns normalized project names.
  #
  #: () -> Array[String]
  def project_names
    raise NotImplementedError, "Subclasses must implement project_names"
  end

  # - `project`: a normalized project name
  #
  # Returns distribution filenames, sorted.
  #
  #: (String project) -> Array[String]
  def filenames_for_project(project)
    raise NotImplementedError, "Subclasses must implement filenames_for_project"
  end

  # Returns the path of the file on disk.
  #
  #: (String project, String filename) -> String?
  def file_path(project, filename)
    raise NotImplementedError, "Subclasses must implement file_path"
  end

  #: (String project, String filename) -> bool
  def file_exists?(project, filename)
    raise NotImplementedError, "Subclasses must implement file_exists?"
  end

  #: (String project, String filename) -> DistributionFile?
  def file_info(project, filename)
    raise NotImplementedError, "Subclasses must implement file_info"
  end

  # The bytes of a wheel's METADATA, served next to it per PEP 658.
  #
  #: (String project, String filename) -> String?
  def core_metadata(project, filename)
    raise NotImplementedError, "Subclasses must implement core_metadata"
  end

  # - `source_path`: where the uploaded bytes are
  # - `filename`: what the uploader called them
  #
  #: (String source_path, String filename) -> DistributionFile
  def add_file(source_path, filename)
    raise NotImplementedError, "Subclasses must implement add_file"
  end

  # PEP 592: the file stays downloadable for a pinned install, but no
  # resolver picks it otherwise.
  #
  #: (String project, String filename, ?reason: String) -> void
  def yank_file(project, filename, reason: "")
    raise NotImplementedError, "Subclasses must implement yank_file"
  end

  # The versions the project's files carry, in no meaningful order -
  # sorting PEP 440 versions is the installer's business, not ours.
  #
  #: (String project) -> Array[String]
  def versions_for_project(project)
    filenames_for_project(project).filter_map { |filename| self.class.version_from_filename(filename) }.uniq
  end

  # A short string that changes whenever anything this repository would
  # serve changes, or nil for "do not cache this" - see Paquette::CacheValidation.
  #
  #: () -> String?
  def cache_validator
    nil
  end

  #: () -> bool
  def varies_by_caller?
    true
  end

  # PEP 503 normalization. Several spellings reach one project, and the
  # directory on disk is named by this one.
  #
  # Returns nil for anything that is not a project name.
  #
  #: (String name) -> String?
  def self.normalize_name(name)
    string = name.to_s
    return nil unless string.valid_encoding?
    return nil if string.empty? || string.bytesize > MAX_NAME_BYTES

    normalized = string.downcase.gsub(NAME_SEPARATORS, "-")
    normalized if valid_project_name?(normalized)
  end

  MAX_NAME_BYTES = 200

  # The separators PEP 503 folds into one dash
  NAME_SEPARATORS = /[-_.]+/

  # A normalized name, which is also a directory under the packages root:
  # no dots, so nothing in it can climb out.
  NORMALIZED_NAME = /\A[a-z0-9-]{1,200}\z/

  #: (String project) -> bool
  def self.valid_project_name?(project)
    string = project.to_s
    return false unless string.valid_encoding?
    return false if string.start_with?("-") || string.end_with?("-")

    NORMALIZED_NAME.match?(string)
  end

  # The distribution name as wheel filenames spell it. Older wheels keep a dot.
  DISTRIBUTION = /\A[A-Za-z0-9._]{1,200}\z/

  # sdists from before PEP 625 can carry dashes in the name, so this one
  # admits them and the split falls on the last dash.
  SDIST_DISTRIBUTION = /\A[A-Za-z0-9._-]{1,200}\z/

  # A version as a filename carries it - PEP 440 normalized, which in a
  # wheel name has any dash turned into an underscore.
  VERSION = /\A[0-9][0-9A-Za-z.!+_]{0,63}\z/

  BUILD_TAG = /\A[0-9][0-9A-Za-z_]{0,31}\z/

  # Compressed tag sets join with dots: "py2.py3", "manylinux_2_17_x86_64.manylinux2014_x86_64"
  WHEEL_TAG = /\A[A-Za-z0-9._]{1,255}\z/

  MAX_FILENAME_BYTES = 1024

  # Splits a distribution filename into its parts, refusing anything the
  # specifications would not have produced. String operations do the
  # splitting, the patterns above only ever see one part.
  #
  # Returns :distribution, :version, :filetype
  # ("bdist_wheel" or "sdist")
  #
  #: (String filename) -> Hash[Symbol, String]?
  def self.parse_filename(filename)
    string = filename.to_s
    return nil unless string.valid_encoding?
    return nil if string.bytesize > MAX_FILENAME_BYTES

    if string.end_with?(".whl")
      parse_wheel_filename(string)
    elsif string.end_with?(".tar.gz")
      parse_sdist_filename(string)
    end
  end

  # {distribution}-{version}(-{build tag})?-{python tag}-{abi tag}-{platform tag}.whl
  #
  #: (String filename) -> Hash[Symbol, String]?
  def self.parse_wheel_filename(filename)
    parts = filename.delete_suffix(".whl").split("-", -1)
    return nil unless parts.length == 5 || parts.length == 6

    distribution = parts[0] #: String
    version = parts[1] #: String
    rest = parts.drop(2)
    tags = rest.last(3)
    return nil unless DISTRIBUTION.match?(distribution) && VERSION.match?(version)
    return nil if rest.length == 4 && !BUILD_TAG.match?(rest.first)
    return nil unless tags.all? { |tag| WHEEL_TAG.match?(tag) }

    {distribution: distribution, version: version, filetype: "bdist_wheel"}
  end
  private_class_method :parse_wheel_filename

  #: (String filename) -> Hash[Symbol, String]?
  def self.parse_sdist_filename(filename)
    stem = filename.delete_suffix(".tar.gz")
    distribution, dash, version = stem.rpartition("-")
    return nil if dash.empty?
    return nil unless SDIST_DISTRIBUTION.match?(distribution) && VERSION.match?(version)

    {distribution: distribution, version: version, filetype: "sdist"}
  end
  private_class_method :parse_sdist_filename

  #: (String filename) -> String?
  def self.version_from_filename(filename)
    parse_filename(filename)&.fetch(:version)
  end

  # The normalized project a file belongs to, read from its name alone.
  #
  #: (String filename) -> String?
  def self.project_for_filename(filename)
    parsed = parse_filename(filename)
    parsed && normalize_name(parsed[:distribution])
  end

  #: (String filename) -> bool
  def self.wheel?(filename)
    filename.to_s.end_with?(".whl")
  end

  # The longest METADATA or PKG-INFO this will read. Real ones are a few
  # kilobytes; a long README inlined as the description is what gets near this.
  MAX_METADATA_BYTES = 4 * 1024 * 1024 #: Integer

  # Reads the headers of a core metadata file - RFC 822, near enough - up to
  # the blank line that starts the description. Repeated fields keep the first.
  # Lines, not a pattern: this is publisher-written text.
  #
  # Returns lowercased field name => value.
  #
  #: (String text) -> Hash[String, String]
  def self.parse_core_metadata(text)
    fields = {}
    last_key = nil
    Paquette::Tarball.as_text(text).each_line do |line|
      line = line.chomp
      break if line.empty?

      if line.start_with?(" ", "\t")
        fields[last_key] = "#{fields[last_key]}\n#{line.strip}" if last_key && fields[last_key]
        next
      end

      key, colon, value = line.partition(":")
      next if colon.empty?

      key = key.strip.downcase
      last_key = fields.key?(key) ? nil : key
      fields[key] ||= value.strip
    end
    fields
  end

  # The core metadata of a wheel or an sdist: METADATA out of the wheel's
  # .dist-info, PKG-INFO out of the sdist's root.
  #
  # Raises `Paquette::Wheel::MalformedWheel` or `Paquette::Tarball::MalformedTarball`.
  #
  #: (String path, String filename) -> String?
  def self.distribution_metadata(path, filename)
    wheel?(filename) ? wheel_metadata(path, filename) : sdist_metadata(path)
  end

  # The specification puts it in "{distribution}-{version}.dist-info", but
  # older tools spelled that directory their own way, so a lone top-level
  # .dist-info is taken too. Two of them and it is anybody's guess, so neither.
  #
  # Raises `Paquette::Wheel::MalformedWheel`.
  #
  #: (String path, String filename) -> String?
  def self.wheel_metadata(path, filename)
    parsed = parse_filename(filename)
    return nil unless parsed

    names = Paquette::Wheel.entry_names(path)
    expected = "#{parsed[:distribution]}-#{parsed[:version]}.dist-info/METADATA"
    name = if names.include?(expected)
      expected
    else
      candidates = names.select { |candidate| candidate.count("/") == 1 && candidate.end_with?(".dist-info/METADATA") }
      candidates.first if candidates.length == 1
    end
    name && Paquette::Wheel.read_entry(path, name, limit: MAX_METADATA_BYTES)
  end

  # Raises `Paquette::Tarball::MalformedTarball`.
  #
  #: (String path) -> String?
  def self.sdist_metadata(path)
    Paquette::Tarball.each_entry(path) do |entry|
      next unless entry.name.count("/") == 1 && File.basename(entry.name) == "PKG-INFO"
      return nil if entry.content.bytesize > MAX_METADATA_BYTES

      return entry.content
    end
    nil
  end
end
