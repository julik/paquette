require "delegate"
require "measurometer"

# Filters every read through an entitler block; non-entitled projects and
# versions do not exist. Writes always raise: a gated caller may not mutate
# the corpus.
class Paquette::PypiServer::ReadGatedRepository < SimpleDelegator
  # Raised by every write on a gated repository.
  class WriteNotAllowed < StandardError; end

  # @param repository [Paquette::PypiServer::PypiRepository] the repository
  #   to wrap
  # @param gate_key [String, nil] names this gate for HTTP caching - see the
  #   gem-side ReadGatedRepository for the contract. Without one the whole
  #   stack emits no ETag.
  # @yield [name:, version:] the entitler, called with the normalized project
  #   name and - for a file - the version out of its filename; returns truthy
  #   when the caller may see it
  def initialize(repository, gate_key: nil, &entitler)
    super(repository)
    @entitler = entitler
    @gate_key = gate_key
  end

  # @return [String, nil]
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    Paquette::CacheValidation.derive_validator(inner, "read-gate", @gate_key)
  end

  # @return [Boolean]
  def varies_by_caller?
    true
  end

  # A project with no entitled file is left out too - pip treats a listed
  # name as one it can install from.
  #
  # @return [Array<String>]
  def project_names
    super.select { |project| entitled?(name: project) && filenames_for_project(project).any? }
  end

  # @param project [String]
  # @return [Array<String>]
  def filenames_for_project(project)
    return [] unless entitled?(name: project)

    super.select { |filename| entitled_file?(project, filename) }
  end

  # @param project [String]
  # @return [Array<String>]
  def versions_for_project(project)
    filenames_for_project(project).filter_map { |filename| Paquette::PypiServer::PypiRepository.version_from_filename(filename) }.uniq
  end

  # @param project [String]
  # @param filename [String]
  # @return [String, nil]
  def file_path(project, filename)
    super if entitled_file?(project, filename)
  end

  # @param project [String]
  # @param filename [String]
  # @return [Boolean]
  def file_exists?(project, filename)
    entitled_file?(project, filename) ? !!super : false
  end

  # @param project [String]
  # @param filename [String]
  # @return [Paquette::PypiServer::PypiRepository::DistributionFile, nil]
  def file_info(project, filename)
    super if entitled_file?(project, filename)
  end

  # @param project [String]
  # @param filename [String]
  # @return [String, nil]
  def core_metadata(project, filename)
    super if entitled_file?(project, filename)
  end

  # @raise [WriteNotAllowed] always
  # @return [void]
  def add_file(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  # @raise [WriteNotAllowed] always
  # @return [void]
  def yank_file(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a read-gated repository"
  end

  private

  # @param project [String]
  # @param filename [String]
  # @return [Boolean]
  def entitled_file?(project, filename)
    version = Paquette::PypiServer::PypiRepository.version_from_filename(filename)
    return false unless version

    !!(entitled?(name: project) && entitled?(name: project, version: version))
  end

  # The entitler is the caller's, and a project page calls it once per file.
  #
  # @param criteria [Hash]
  # @return [Object] truthy when entitled
  def entitled?(**criteria)
    Measurometer.instrument("paquette.pypi_read_gate.entitled") { @entitler.call(**criteria) }
  end
end
