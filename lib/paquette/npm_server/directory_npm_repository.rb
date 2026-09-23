require "json"
require "tempfile"
require "time"
require "measurometer"
require "digest"

# Reads NPM packages from a directory; a scope is an ordinary directory:
#   packages/npm/@acme/widgets/widgets-1.0.0.tgz
class Paquette::NpmServer::DirectoryNpmRepository < Paquette::NpmServer::NpmRepository
  class PackageAlreadyExists < StandardError; end

  class InvalidPackage < StandardError; end

  class PackageNotFound < StandardError; end

  class PackageYanked < StandardError; end

  DIST_TAGS_FILE = "dist-tags.json"

  def initialize(packages_dir)
    @packages_dir = packages_dir
    FileUtils.mkdir_p(@packages_dir)
  end

  # A digest of what the corpus holds — see the gem-side twin. Tarball
  # paths carry publishes and unpublishes (an unpublish renames to a
  # tomb), but a dist-tag write edits dist-tags.json in place: no path
  # moves, so the write shows only in the file's own mtime.
  def fingerprint
    Measurometer.instrument("paquette.npm_repository.fingerprint") do
      d = Digest::SHA256.new
      Dir.glob(File.join(@packages_dir, "**", "*.tgz")).sort.each { |path| d << path }
      Dir.glob(File.join(@packages_dir, "**", DIST_TAGS_FILE)).sort.each do |path|
        d << path << File.mtime(path).to_f.to_s
      end
      d.base64digest
    end
  end

  def package_names
    Measurometer.instrument("paquette.npm_repository.package_names") do
      names = []
      each_child_dir(@packages_dir) do |path, basename|
        if Paquette::NpmServer::NpmRepository.scoped?(basename)
          each_child_dir(path) { |_, scoped| names << "#{basename}/#{scoped}" }
        else
          names << basename
        end
      end
      names.sort
    end
  end

  # A directory listing per package in the corpus.
  def package_versions
    Measurometer.instrument("paquette.npm_repository.package_versions") do
      package_names.flat_map do |package_name|
        versions_for_package(package_name).map { |version| [package_name, version] }
      end.sort
    end
  end

  def versions_for_package(package_name)
    dir = package_dir(package_name)
    return [] unless dir && Dir.exist?(dir)

    Measurometer.instrument("paquette.npm_repository.versions_for_package") do
      prefix = "#{File.basename(package_name)}-"
      versions = Dir.glob(File.join(dir, "*.tgz")).filter_map do |tarball_path|
        version = File.basename(tarball_path, ".tgz").delete_prefix(prefix)
        version unless version.empty? || version == File.basename(tarball_path, ".tgz")
      end
      Paquette::NpmServer::NpmRepository.sort_versions(versions)
    end
  end

  def package_file_path(package_name, version)
    dir = package_dir(package_name)
    return nil unless dir

    File.join(dir, Paquette::NpmServer::NpmRepository.tarball_filename(package_name, version))
  end

  def package_exists?(package_name, version)
    path = package_file_path(package_name, version)
    !!path && File.exist?(path)
  end

  def package_info(package_name, version)
    path = package_file_path(package_name, version)
    return nil unless path && File.exist?(path)

    cached(path) { Paquette::Tarball.package_json(path) }
  end

  def package_dependencies(package_name, version)
    info = package_info(package_name, version)
    return {} unless info

    info["dependencies"] || {}
  end

  # "latest" is recomputed from disk: a stored tag can outlive its version.
  def dist_tags(package_name)
    versions = versions_for_package(package_name)
    return {} if versions.empty?

    stored = read_dist_tags(package_name).select { |_tag, version| versions.include?(version) }
    {"latest" => Paquette::NpmServer::NpmRepository.max_release_version(versions)}.merge(stored)
  end

  # Assembling this means reading the package.json out of every version's
  # tarball and hashing every one of them; the cache below is what keeps a
  # second request from paying for it again.
  def package_metadata(package_name)
    Measurometer.instrument("paquette.npm_repository.package_metadata") { build_metadata(package_name) }
  end

  def build_metadata(package_name)
    versions = versions_for_package(package_name)
    return nil if versions.empty?

    Measurometer.add_distribution_value("paquette.npm_repository.metadata_versions", versions.length)

    tags = dist_tags(package_name)
    latest_info = package_info(package_name, tags["latest"]) || {}

    version_docs = versions.each_with_object({}) do |version, docs|
      info = package_info(package_name, version)
      next unless info

      docs[version] = Paquette::NpmServer::NpmRepository.version_doc(info, package_name, version, dist_for(package_name, version))
    end

    {
      "_id" => package_name,
      "name" => package_name,
      "dist-tags" => tags,
      "versions" => version_docs,
      "time" => times_for(package_name, versions),
      "description" => latest_info["description"],
      "keywords" => latest_info["keywords"] || [],
      "license" => latest_info["license"],
      "author" => latest_info["author"],
      "maintainers" => latest_info["maintainers"] || [],
      "repository" => latest_info["repository"],
      "bugs" => latest_info["bugs"],
      "homepage" => latest_info["homepage"],
      "readme" => readme_for(package_name, tags["latest"]) || ""
    }.compact
  end

  # Hashes are computed from the file, never taken from the publisher.
  def dist_for(package_name, version)
    path = package_file_path(package_name, version)
    return {} unless path && File.exist?(path)

    cached(path, :dist) do
      Paquette::Tarball.integrity(path).transform_keys(&:to_s).merge(
        "tarball" => Paquette::NpmServer::NpmRepository.tarball_path(package_name, version)
      )
    end
  end

  # A republished version must never silently carry different bytes.
  def add_package(binary_data, dist_tags: {})
    raise InvalidPackage, "Empty package payload" if binary_data.nil? || binary_data.empty?

    Measurometer.add_distribution_value("paquette.npm_repository.add_package_bytes", binary_data.bytesize)

    tmp = Tempfile.new(["paquette_publish", ".tgz"])
    begin
      tmp.binmode
      Measurometer.instrument("paquette.npm_repository.write_upload") { tmp.write(binary_data) }
      tmp.close

      info = begin
        Paquette::Tarball.package_json(tmp.path)
      rescue Paquette::Tarball::MalformedTarball => e
        raise InvalidPackage, "Could not read package: #{e.message}"
      end
      raise InvalidPackage, "Package contains no package.json" if info.nil?

      name = info["name"].to_s
      version = info["version"].to_s
      raise InvalidPackage, "package.json has no name" if name.empty?
      raise InvalidPackage, "package.json has no version" if version.empty?
      raise InvalidPackage, "Invalid package name: #{name}" unless Paquette::NpmServer::NpmRepository.valid_package_name?(name)

      raise PackageYanked, "#{name}@#{version} was unpublished and cannot be republished" if tomb_exists?(name, version)
      raise PackageAlreadyExists, "#{name}@#{version} already exists" if package_exists?(name, version)

      destination = package_file_path(name, version)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.mv(tmp.path, destination)
      FileUtils.chmod(0o644, destination)

      # Storing npm's always-sent "latest" would pin it to the first publish.
      published_tags = dist_tags.select { |tag, tagged| tagged == version && tag.to_s != "latest" }
      write_dist_tags(name, read_dist_tags(name).merge(published_tags))

      info
    ensure
      tmp.close unless tmp.closed?
      File.unlink(tmp.path) if File.exist?(tmp.path)
    end
  end

  # The tomb stops the version being republished with different contents.
  def yank_package(package_name, version)
    path = package_file_path(package_name, version)
    raise PackageNotFound, "#{package_name}@#{version} not found" unless path && File.exist?(path)

    Measurometer.instrument("paquette.npm_repository.yank_package") do
      FileUtils.mv(path, tomb_file_path(package_name, version))
      drop_dist_tags_for(package_name, version)
    end
    nil
  end

  # "latest" follows the newest release on disk; pointing it elsewhere is refused.
  def write_dist_tag(package_name, tag, version)
    raise InvalidPackage, "latest always follows the newest published version" if tag.to_s == "latest"
    raise PackageNotFound, "#{package_name}@#{version} not found" unless package_exists?(package_name, version)

    write_dist_tags(package_name, read_dist_tags(package_name).merge(tag.to_s => version))
    dist_tags(package_name)
  end

  def tomb_file_path(package_name, version)
    path = package_file_path(package_name, version)
    path && path + ".tomb"
  end

  def tomb_exists?(package_name, version)
    path = tomb_file_path(package_name, version)
    !!path && File.exist?(path)
  end

  private

  # nil for a non-name, so "../../etc" resolves to no package, not a path.
  def package_dir(package_name)
    return nil unless Paquette::NpmServer::NpmRepository.valid_package_name?(package_name)

    File.join(@packages_dir, *package_name.split("/"))
  end

  def each_child_dir(dir)
    Dir.children(dir).sort.each do |basename|
      path = File.join(dir, basename)
      yield path, basename if File.directory?(path)
    end
  rescue Errno::ENOENT
    nil
  end

  # mtimes, unlike Time.now, keep the document stable between requests.
  def times_for(package_name, versions)
    times = {}
    mtimes = versions.filter_map do |version|
      path = package_file_path(package_name, version)
      next unless path && File.exist?(path)

      mtime = File.mtime(path).utc
      times[version] = mtime.iso8601
      mtime
    end

    unless mtimes.empty?
      times["created"] = mtimes.min.iso8601
      times["modified"] = mtimes.max.iso8601
    end
    times
  end

  def readme_for(package_name, version)
    path = package_file_path(package_name, version)
    return nil unless path && File.exist?(path)

    cached(path, :readme) do
      entry = Paquette::Tarball.each_entry(path).find do |candidate|
        candidate.name.count("/") == 1 &&
          File.basename(candidate.name).match?(/\AREADME(\.md|\.markdown|\.txt)?\z/i)
      end
      entry && Paquette::Tarball.as_text(entry.content)
    end
  end

  def dist_tags_path(package_name)
    dir = package_dir(package_name)
    dir && File.join(dir, DIST_TAGS_FILE)
  end

  def read_dist_tags(package_name)
    path = dist_tags_path(package_name)
    return {} unless path && File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def write_dist_tags(package_name, tags)
    path = dist_tags_path(package_name)
    return unless path

    if tags.empty?
      File.unlink(path) if File.exist?(path)
    else
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(tags))
    end
  end

  def drop_dist_tags_for(package_name, version)
    tags = read_dist_tags(package_name).reject { |_tag, tagged| tagged == version }
    write_dist_tags(package_name, tags)
  end

  # Keyed on mtime + size so a replaced tarball is not served stale.
  def cached(path, aspect = :info)
    stat = File.stat(path)
    key = [path, aspect, stat.mtime.to_f, stat.size]
    @cache ||= {}
    if @cache.key?(key)
      Measurometer.increment_counter("paquette.npm_repository.cache_hit.#{aspect}")
      return @cache[key]
    end
    Measurometer.increment_counter("paquette.npm_repository.cache_miss.#{aspect}")

    # Bounded, or a long-lived server would hold every package.json ever read.
    @cache.shift if @cache.size >= 1024
    @cache[key] = yield
  end
end
