require "delegate"
require "measurometer"

# Wraps a gem repository and hides every version that was published less
# than `interval` seconds ago, giving a publisher a window to yank a
# compromised or broken release before anybody can pick it up. Read-only:
# a push into a delayed view would land and then immediately vanish from
# the view that accepted it.
class Paquette::GemServer::CooldownRepository < Paquette::GemServer::ReadonlyRepository
  # @param repository [Paquette::GemServer::GemRepository] the repository
  #   to wrap
  # @param interval [Integer, #to_i] the cooldown, in seconds
  # @param published_at [Proc, nil] called with `name:` and `version:`,
  #   returns a Time — or nil for "I do not know". Defaults to the
  #   repository's own published_at (the gemspec date).
  # @param published_at_validator [Proc, nil] only with `published_at:`: a
  #   zero-argument callable returning a string that changes whenever any
  #   answer `published_at:` would give changes, or nil for "I cannot say".
  #   Without one, a view over a custom source emits no validator.
  # @param clock [Proc] returns the current Time; here so tests do not
  #   have to sleep
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

  # The inner validator alone would 304 a client out of exactly the
  # release the channel exists to deliver — but the servable set only
  # moves when a version crosses the boundary, and versions cross in
  # publication order, so the set is named by how many known publish times
  # are at least `interval` old. That count is digested with the inner
  # validator and the interval; the sorted publish times are memoized
  # under the inner validator, fail-closed as everywhere else.
  #
  # @return [String, nil]
  def cache_validator
    inner = Paquette::GemServer::GemRepository.cache_validator_of(__getobj__)
    return nil if inner.nil?

    source_state = if @published_at_source
      @published_at_validator&.call
    else
      "gemspec-date"
    end
    return nil if source_state.nil?

    times = publish_times_for([inner, source_state])
    now = @clock.call
    cooled = times.bsearch_index { |published| !cooled?(published, now) } || times.length
    Paquette::GemServer::GemRepository.derive_validator(inner, "cooldown", [@interval, source_state, cooled].join("\0"))
  end

  # A gem with no servable version disappears from /names altogether —
  # Bundler treats a listed name as resolvable.
  #
  # @return [Array<String>]
  def gem_names
    super.select { |gem_name| versions_for_gem(gem_name).any? }
  end

  # @return [Array<Array(String, String)>]
  def gem_versions
    super.select { |gem_name, version| servable?(gem_name, version) }
  end

  # @param gem_name [String]
  # @return [Array<String>]
  def versions_for_gem(gem_name)
    super.select { |version| servable?(gem_name, version) }
  end

  # /specs.4.8 and /latest_specs.4.8 are built out of gem_versions, so they
  # follow from the filter above without this class touching them.

  # @param gem_name [String]
  # @return [Array<String>, Object]
  def compact_info(gem_name)
    all_info = super
    return all_info unless all_info.is_a?(Array)

    all_info.select do |line|
      # The version column, platform suffix and all.
      version = line.split(" ", 2).first
      servable?(gem_name, version)
    end
  end

  # The download path has to agree with the index: a cooling version 404s.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [String, nil]
  def gem_file_path(gem_name, version)
    super if servable?(gem_name, version)
  end

  # @param gem_name [String]
  # @param version [String]
  # @return [Boolean]
  def gem_exists?(gem_name, version)
    if servable?(gem_name, version)
      super
    else
      false
    end
  end

  # gem_spec is deliberately *not* filtered: /quick/Marshal.4.8 asks
  # gem_exists? first, and the default published_at source reads spec.date —
  # a wrapper that hid the spec of a cooling gem could not tell it is
  # cooling.

  # True when the version has been published for at least `interval`
  # seconds. An unknown publication time fails **open**: a cooldown is a
  # delay policy, not an authorization boundary — that is
  # ReadGatedRepository's job — and failing closed would break `bundle
  # install` over a missing timestamp.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [Boolean]
  def servable?(gem_name, version)
    published = published_time(gem_name, version)
    return true if published.nil?

    cooled?(published, @clock.call)
  end

  private

  # The one comparison both servable? and cache_validator make, so the two
  # cannot disagree about which side of the boundary a version is on.
  #
  # @param published [Time]
  # @param now [Time]
  # @return [Boolean]
  def cooled?(published, now)
    (now - published) >= @interval
  end

  # The known publish times of every version the inner repository lists,
  # sorted; rebuilt only when `key` changes, under the lock.
  #
  # @param key [Array]
  # @return [Array<Time>]
  def publish_times_for(key)
    @publish_times_lock.synchronize do
      memo_key, times = @publish_times
      return times if memo_key == key

      times = __getobj__.gem_versions.filter_map { |gem_name, version| published_time(gem_name, version) }.sort.freeze
      @publish_times = [key, times].freeze
      times
    end
  end

  # The default source is `spec.date`: intrinsic to the immutable gem
  # bytes, where an mtime or a cache-minted "first seen" would put the
  # whole corpus into cooldown on any rsync or restore. Its weakness — it
  # records the publisher's build time — is what `published_at:` is for.
  #
  # @param gem_name [String]
  # @param version [String]
  # @return [Time, nil]
  def published_time(gem_name, version)
    Measurometer.instrument("paquette.gem_cooldown.published_at") do
      if @published_at_source
        @published_at_source.call(name: gem_name, version: version)
      elsif __getobj__.respond_to?(:published_at)
        __getobj__.published_at(gem_name, version)
      else
        # A repository from outside this gem need not implement published_at.
        __getobj__.gem_spec(gem_name, version)&.date
      end
    end
  end
end
