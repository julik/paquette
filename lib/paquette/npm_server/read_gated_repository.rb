require "delegate"
require "measurometer"

# Filters every read through an entitler block; non-entitled packages do
# not exist. Writes always raise: a gated caller may not mutate the corpus.
class Paquette::NpmServer::ReadGatedRepository < SimpleDelegator
  class WriteNotAllowed < StandardError; end

  def initialize(repository, &entitler)
    super(repository)
    @entitler = entitler
  end

  def package_names
    super.select { |name| entitled?(name: name) }
  end

  def package_versions
    super.select do |package_name, version|
      entitled?(name: package_name, version: version)
    end
  end

  def versions_for_package(package_name)
    return [] unless entitled?(name: package_name)

    super.select do |version|
      entitled?(name: package_name, version: version)
    end
  end

  def package_file_path(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  # false rather than nil: callers treat this as a boolean.
  def package_exists?(package_name, version)
    if entitled?(name: package_name, version: version)
      !!super
    else
      false
    end
  end

  def package_info(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    end
  end

  def package_dependencies(package_name, version)
    if entitled?(name: package_name, version: version)
      super
    else
      {}
    end
  end

  def dist_tags(package_name)
    return {} unless entitled?(name: package_name)

    entitled = versions_for_package(package_name)
    tags = super.select { |_tag, version| entitled.include?(version) }
    # "latest" must point at a version this caller may actually download.
    tags = tags.merge("latest" => Paquette::NpmServer::NpmRepository.max_release_version(entitled)) if entitled.any?
    tags
  end

  def package_metadata(package_name)
    return nil unless entitled?(name: package_name)

    metadata = super
    return metadata unless metadata

    entitled = versions_for_package(package_name)
    # A fully gated package does not exist for this caller.
    return nil if entitled.empty?

    # A leaner custom repository is filtered, not crashed on.
    versions = metadata["versions"].is_a?(Hash) ? metadata["versions"].slice(*entitled) : {}

    metadata.merge(
      "versions" => versions,
      "time" => entitled_times(metadata["time"], entitled),
      "dist-tags" => dist_tags(package_name)
    )
  end

  # Recomputed so created/modified do not leak withheld publication dates.
  def entitled_times(times, entitled)
    return {} unless times.is_a?(Hash)

    entitled_times = times.slice(*entitled)
    return entitled_times if entitled_times.empty?

    stamps = entitled_times.values.sort
    entitled_times.merge("created" => stamps.first, "modified" => stamps.last)
  end

  # The entitler is the caller's, and a listing calls it once per package in
  # the corpus — an entitler that reaches for a database on every call is
  # the usual reason a gated index is slower than an ungated one, and this
  # is where that shows up.
  def entitled?(**criteria)
    Measurometer.instrument("paquette.npm_read_gate.entitled") { @entitler.call(**criteria) }
  end

  def add_package(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  def yank_package(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  def write_dist_tag(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end
end

# Former name, kept so existing stacks keep building.
Paquette::NpmServer::GatedNpmRepository = Paquette::NpmServer::ReadGatedRepository
