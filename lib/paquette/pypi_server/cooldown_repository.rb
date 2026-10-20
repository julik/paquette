require "delegate"
require "measurometer"

# Hides every file that arrived less than `interval` seconds ago - the PyPI
# twin of GemServer::CooldownRepository. Per file rather than per version: a
# wheel added to an old release later is exactly the kind of arrival a
# cooldown is for. An upload through it lands, and stays out of this view
# until it has cooled.
class Paquette::PypiServer::CooldownRepository < SimpleDelegator
  # - `repository`: the repository to wrap
  # - `interval`: the cooldown, in seconds
  # - `published_at`: called with `name:`, `version:` and `filename:`, returns
  #   a Time or nil for "I do not know". Defaults to the repository's own
  #   published_at - the file's mtime, for a directory.
  # - `published_at_validator`: only with `published_at:` - a string that
  #   changes whenever any answer `published_at:` would give does
  # - `clock`: returns the current Time
  #
  #: (Paquette::PypiServer::PypiRepository repository, interval: _ToI, ?published_at: Proc?, ?published_at_validator: Proc?, ?clock: Proc) -> void
  def initialize(repository, interval:, published_at: nil, published_at_validator: nil, clock: -> { Time.now })
    if published_at_validator && !published_at
      raise ArgumentError, "published_at_validator: describes a published_at: source, and none was given"
    end

    super(repository)
    @interval = interval.to_i
    @published_at_source = published_at
    @published_at_validator = published_at_validator
    @clock = clock
    @publish_times_lock = Mutex.new
    @publish_times = nil
  end

  # Named by how many known publish times have cooled - see the gem side,
  # whose reasoning this is.
  #
  #: () -> String?
  def cache_validator
    inner = Paquette::CacheValidation.validator_of(__getobj__)
    return nil if inner.nil?

    source_state = @published_at_source ? @published_at_validator&.call : "repository"
    return nil if source_state.nil?

    times = publish_times_for([inner, source_state])
    now = @clock.call
    cooled = times.bsearch_index { |published| !cooled?(published, now) } || times.length
    Paquette::CacheValidation.derive_validator(inner, "cooldown", [@interval, source_state, cooled].join("\0"))
  end

  #: () -> Array[String]
  def project_names
    super.select { |project| filenames_for_project(project).any? }
  end

  #: (String project) -> Array[String]
  def filenames_for_project(project)
    super.select { |filename| servable?(project, filename) }
  end

  #: (String project) -> Array[String]
  def versions_for_project(project)
    filenames_for_project(project).filter_map { |filename| Paquette::PypiServer::PypiRepository.version_from_filename(filename) }.uniq
  end

  #: (String project, String filename) -> String?
  def file_path(project, filename)
    super if servable?(project, filename)
  end

  #: (String project, String filename) -> bool
  def file_exists?(project, filename)
    servable?(project, filename) ? super : false
  end

  #: (String project, String filename) -> Paquette::PypiServer::PypiRepository::DistributionFile?
  def file_info(project, filename)
    super if servable?(project, filename)
  end

  #: (String project, String filename) -> String?
  def core_metadata(project, filename)
    super if servable?(project, filename)
  end

  # An unknown publication time fails open: this is a delay policy, and
  # authorization is ReadGatedRepository's job.
  #
  #: (String project, String filename) -> bool
  def servable?(project, filename)
    published = published_time(project, filename)
    return true if published.nil?

    cooled?(published, @clock.call)
  end

  private

  #: (Time published, Time now) -> bool
  def cooled?(published, now)
    (now - published) >= @interval
  end

  #: (Array[untyped] key) -> Array[Time]
  def publish_times_for(key)
    @publish_times_lock.synchronize do
      memo_key, times = @publish_times
      return times if memo_key == key

      inner = __getobj__
      times = inner.project_names.flat_map do |project|
        inner.filenames_for_project(project).filter_map { |filename| published_time(project, filename) }
      end.sort.freeze
      @publish_times = [key, times].freeze
      times
    end
  end

  #: (String project, String filename) -> Time?
  def published_time(project, filename)
    Measurometer.instrument("paquette.pypi_cooldown.published_at") do
      if @published_at_source
        version = Paquette::PypiServer::PypiRepository.version_from_filename(filename)
        @published_at_source.call(name: project, version: version, filename: filename)
      elsif __getobj__.respond_to?(:published_at)
        __getobj__.published_at(project, filename)
      end
    end
  end
end
