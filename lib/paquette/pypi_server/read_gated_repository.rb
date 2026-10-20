require "delegate"
require "measurometer"

# Filters every read through an entitler block; non-entitled projects and
# versions do not exist. Writes pass through - see the gem-side twin.
class Paquette::PypiServer::ReadGatedRepository < SimpleDelegator
  # - `repository`: the repository to wrap
  # - `gate_key`: names this gate for HTTP caching - see the gem-side
  #   ReadGatedRepository for the contract. Without one the whole stack emits
  #   no ETag.
  # - the block: the entitler, called with the normalized project name and -
  #   for a file - the version out of its filename; returns truthy when the
  #   caller may see it
  #
  #: (Paquette::PypiServer::PypiRepository repository, ?gate_key: String?) { (name: String, ?version: String?) -> boolish } -> void
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  #: () -> String?
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "read-gate", @gate_key)
  end

  #: () -> bool
  def varies_by_caller?
    true
  end

  # A project with no entitled file is left out too - pip treats a listed
  # name as one it can install from.
  #
  #: () -> Array[String]
  def project_names
    super.select { |project| entitled?(name: project) && filenames_for_project(project).any? }
  end

  #: (String project) -> Array[String]
  def filenames_for_project(project)
    return [] unless entitled?(name: project)

    super.select { |filename| entitled_file?(project, filename) }
  end

  #: (String project) -> Array[String]
  def versions_for_project(project)
    filenames_for_project(project).filter_map { |filename| Paquette::PypiServer::PypiRepository.version_from_filename(filename) }.uniq
  end

  #: (String project, String filename) -> String?
  def file_path(project, filename)
    super if entitled_file?(project, filename)
  end

  #: (String project, String filename) -> bool
  def file_exists?(project, filename)
    entitled_file?(project, filename) ? !!super : false
  end

  #: (String project, String filename) -> Paquette::PypiServer::PypiRepository::DistributionFile?
  def file_info(project, filename)
    super if entitled_file?(project, filename)
  end

  #: (String project, String filename) -> String?
  def core_metadata(project, filename)
    super if entitled_file?(project, filename)
  end

  private

  #: (String project, String filename) -> bool
  def entitled_file?(project, filename)
    version = Paquette::PypiServer::PypiRepository.version_from_filename(filename)
    return false unless version

    !!(entitled?(name: project) && entitled?(name: project, version: version))
  end

  # The entitler is the caller's, and a project page calls it once per file.
  #
  # Returns truthy when entitled.
  #
  #: (**untyped criteria) -> untyped
  def entitled?(**criteria)
    Measurometer.instrument("paquette.pypi_read_gate.entitled") { @entitler.call(**criteria) }
  end
end
