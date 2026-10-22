require "fileutils"
require "digest"
require "securerandom"
require "measurometer"

# Reads Python distributions from a directory, one per normalized project name:
#   packages/pypi/acme-widgets/acme_widgets-1.0.0-py3-none-any.whl
#   packages/pypi/acme-widgets/acme_widgets-1.0.0.tar.gz
#
# A yanked file keeps its place and gains a `.yanked` sidecar holding the reason.
class Paquette::PypiServer::DirectoryPypiRepository < Paquette::PypiServer::PypiRepository
  # Raised on an upload of a filename already on disk - yanked or not, PyPI
  # never lets a filename carry different bytes.
  class FileAlreadyExists < StandardError; end

  # Raised when an upload cannot be read as the distribution its name says it is.
  class InvalidDistribution < StandardError; end

  # Raised on a yank of a file that is not there.
  class FileNotFound < StandardError; end

  # @return [String]
  YANKED_SUFFIX = ".yanked"

  # @param packages_dir [String] the corpus root, created if absent
  def initialize(packages_dir)
    @packages_dir = packages_dir
    FileUtils.mkdir_p(@packages_dir)
  end

  # A digest of the paths in the corpus, plus the mtimes of the yank
  # sidecars - a yank edits what a page says without adding a distribution.
  #
  # @return [String]
  def fingerprint
    Measurometer.instrument("paquette.pypi_repository.fingerprint") do
      d = Digest::SHA256.new
      Dir.glob(File.join(@packages_dir, "*", "*")).sort.each do |path|
        d << path
        d << File.mtime(path).to_r.to_s if path.end_with?(YANKED_SUFFIX)
      end
      d.base64digest
    end
  end

  # @param scope [String, nil]
  # @return [String]
  def cache_validator(scope = nil)
    fingerprint
  end

  # @return [Boolean]
  def varies_by_caller?
    false
  end

  # @return [Array<String>]
  def project_names
    Measurometer.instrument("paquette.pypi_repository.project_names") do
      Dir.children(@packages_dir).select do |name|
        self.class.valid_project_name?(name) && File.directory?(File.join(@packages_dir, name))
      end.sort
    end
  rescue Errno::ENOENT
    []
  end

  # Files whose names belong to a different project are left out: a stray
  # copy must not be served under a name it does not carry.
  #
  # @param project [String]
  # @return [Array<String>]
  def filenames_for_project(project)
    dir = project_dir(project)
    return [] unless dir && Dir.exist?(dir)

    Dir.children(dir).select do |filename|
      self.class.project_for_filename(filename) == project && File.file?(File.join(dir, filename))
    end.sort
  end

  # nil for anything that is not a file of this project, so "../../secret"
  # resolves to nothing rather than to a path.
  #
  # @param project [String]
  # @param filename [String]
  # @return [String, nil]
  def file_path(project, filename)
    dir = project_dir(project)
    return nil unless dir
    return nil unless self.class.project_for_filename(filename) == project

    File.join(dir, filename)
  end

  # @param project [String]
  # @param filename [String]
  # @return [Boolean]
  def file_exists?(project, filename)
    path = file_path(project, filename)
    !!path && File.file?(path)
  end

  # @param project [String]
  # @param filename [String]
  # @return [Paquette::PypiServer::PypiRepository::DistributionFile, nil]
  def file_info(project, filename)
    path = file_path(project, filename)
    return nil unless path && File.file?(path)

    described = cached(path, :describe) { describe(path, filename) }
    described.merge(yanked: yank_reason(path), upload_time: File.mtime(path).utc).then do |fields|
      DistributionFile.new(**fields)
    end
  end

  # @param project [String]
  # @param filename [String]
  # @return [String, nil]
  def core_metadata(project, filename)
    return nil unless self.class.wheel?(filename)

    path = file_path(project, filename)
    return nil unless path && File.file?(path)

    cached(path, :core_metadata) { self.class.wheel_metadata(path, filename) }
  end

  # The moment the file landed here. An rsync or a restore that does not
  # keep mtimes moves this, which is what the cooldown reads by default.
  #
  # @param project [String]
  # @param filename [String]
  # @return [Time, nil]
  def published_at(project, filename)
    path = file_path(project, filename)
    (path && File.file?(path)) ? File.mtime(path) : nil
  end

  # The name in the metadata has to be the name on the file: a wheel
  # uploaded as acme_widgets must not turn out to install something else.
  #
  # @param source_path [String]
  # @param filename [String]
  # @return [Paquette::PypiServer::PypiRepository::DistributionFile]
  # @raise [InvalidDistribution]
  # @raise [FileAlreadyExists]
  def add_file(source_path, filename)
    parsed = self.class.parse_filename(filename)
    raise InvalidDistribution, "Not a wheel or sdist filename: #{filename.to_s.scrub.inspect}" unless parsed

    project = self.class.normalize_name(parsed[:distribution])
    raise InvalidDistribution, "Invalid project name in #{filename}" unless project

    metadata = begin
      self.class.distribution_metadata(source_path, filename)
    rescue Paquette::Wheel::MalformedWheel, Paquette::Tarball::MalformedTarball => e
      raise InvalidDistribution, e.message
    end
    raise InvalidDistribution, "#{filename} carries no core metadata" unless metadata

    fields = self.class.parse_core_metadata(metadata)
    if self.class.normalize_name(fields["name"]) != project
      raise InvalidDistribution, "#{filename} says its name is #{fields["name"].to_s.inspect}"
    end

    destination = file_path(project, filename)
    FileUtils.mkdir_p(File.dirname(destination))
    # The link refuses a destination that exists, so two racing uploads of
    # one filename cannot both land
    begin
      File.link(source_path, destination)
    rescue Errno::EEXIST
      raise FileAlreadyExists, "#{filename} already exists"
    rescue Errno::EXDEV, Errno::EPERM, Errno::ENOTSUP
      link_copy(source_path, destination, filename)
    end
    FileUtils.chmod(0o644, destination)

    file_info(project, filename)
  end

  # @param project [String]
  # @param filename [String]
  # @param reason [String]
  # @return [void]
  # @raise [FileNotFound]
  def yank_file(project, filename, reason: "")
    path = file_path(project, filename)
    raise FileNotFound, "#{filename} not found" unless path && File.file?(path)

    File.write(path + YANKED_SUFFIX, reason.to_s)
    nil
  end

  private

  # A tempfile on another filesystem cannot be linked, so a copy is made on
  # this one first - and linked into place, keeping the refusal above.
  #
  # @param source_path [String]
  # @param destination [String]
  # @param filename [String]
  # @return [void]
  # @raise [FileAlreadyExists]
  def link_copy(source_path, destination, filename)
    partial = "#{destination}.#{SecureRandom.hex(8)}.partial"
    FileUtils.cp(source_path, partial)
    File.link(partial, destination)
  rescue Errno::EEXIST
    raise FileAlreadyExists, "#{filename} already exists"
  ensure
    File.unlink(partial) if partial && File.exist?(partial)
  end

  # @param project [String]
  # @return [String, nil]
  def project_dir(project)
    return nil unless self.class.valid_project_name?(project)

    File.join(@packages_dir, project)
  end

  # @param path [String]
  # @return [String, false]
  def yank_reason(path)
    sidecar = path + YANKED_SUFFIX
    File.exist?(sidecar) ? Paquette::Tarball.as_text(File.read(sidecar)) : false
  end

  # Everything about a file that only changes when its bytes do.
  #
  # @param path [String]
  # @param filename [String]
  # @return [Hash{Symbol => Object}]
  def describe(path, filename)
    Measurometer.instrument("paquette.pypi_repository.describe") do
      metadata = begin
        self.class.distribution_metadata(path, filename)
      rescue Paquette::Wheel::MalformedWheel, Paquette::Tarball::MalformedTarball
        nil
      end
      fields = metadata ? self.class.parse_core_metadata(metadata) : {}
      requires_python = fields["requires-python"]

      {
        filename: filename,
        version: self.class.version_from_filename(filename),
        sha256: Digest::SHA256.file(path).hexdigest,
        size: File.size(path),
        requires_python: (requires_python.nil? || requires_python.empty?) ? nil : requires_python,
        core_metadata_sha256: (self.class.wheel?(filename) && metadata) ? Digest::SHA256.hexdigest(metadata) : nil
      }
    end
  end

  # Keyed on mtime + size so a replaced file is not described stale.
  #
  # @param path [String]
  # @param aspect [Symbol]
  # @return [Object] the cached block result
  def cached(path, aspect)
    stat = File.stat(path)
    key = [path, aspect, stat.mtime.to_r, stat.size]
    @cache ||= {}
    if @cache.key?(key)
      Measurometer.increment_counter("paquette.pypi_repository.cache_hit.#{aspect}")
      return @cache[key]
    end
    Measurometer.increment_counter("paquette.pypi_repository.cache_miss.#{aspect}")

    # Bounded, or a long-lived server would hold every METADATA ever read
    @cache.shift if @cache.size >= 1024
    @cache[key] = yield
  end
end
