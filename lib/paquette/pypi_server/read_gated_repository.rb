require "delegate"
require "digest"
require "measurometer"

# Filters every read through the caller's authenticator; non-entitled projects
# and versions do not exist. Writes pass through - see the gem-side twin, which
# the server applies the same way: for every request whose authenticator
# answers `entitled?`.
class Paquette::PypiServer::ReadGatedRepository < SimpleDelegator
  # @param repository [Paquette::PypiServer::PypiRepository] the repository
  #   to wrap
  # @param authenticator [Paquette::Authenticator] the caller's, answering
  #   `entitled?(name:, version: nil)` - asked with the normalized project
  #   name and, for a file, the version out of its filename
  def initialize(repository, authenticator)
    super(repository)
    @authenticator = authenticator
  end

  # What this caller can see within the scope, digested into the wrapped
  # validator - see the gem-side twin for why, and for why a caller who sees
  # nothing gets none.
  #
  # @param scope [String, nil] one normalized project name, or nil for the
  #   whole index
  # @return [String, nil]
  def cache_validator(scope = nil)
    inner = Paquette::CacheValidation.validator_of(__getobj__, scope)
    return nil if inner.nil?

    visible = if scope
      filenames_for_project(scope).map { |filename| [scope, filename] }
    else
      project_names.flat_map { |project| [[project]] + filenames_for_project(project).map { |filename| [project, filename] } }
    end
    return nil if visible.empty?

    Paquette::CacheValidation.derive_validator(inner, "read-gate", Digest::SHA256.hexdigest(visible.sort.join("\0")))
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

  private

  # @param project [String]
  # @param filename [String]
  # @return [Boolean]
  def entitled_file?(project, filename)
    version = Paquette::PypiServer::PypiRepository.version_from_filename(filename)
    return false unless version

    !!(entitled?(name: project) && entitled?(name: project, version: version))
  end

  # The authenticator is the caller's, and a project page asks it once per file.
  #
  # @param criteria [Hash]
  # @return [Object] truthy when entitled
  def entitled?(**criteria)
    Measurometer.instrument("paquette.pypi_read_gate.entitled") { @authenticator.entitled?(**criteria) }
  end
end
