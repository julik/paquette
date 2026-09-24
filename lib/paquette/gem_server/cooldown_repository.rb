require "delegate"
require "measurometer"

# Wraps a gem repository and hides every version that was published less
# than `interval` seconds ago.
#
# The point is that a compromised — or merely broken — release should not
# be resolvable into a customer's lockfile the instant it is pushed. A
# cooldown view serves only versions that have been published for longer
# than the configured interval, which gives the publisher a window to yank
# before anybody can pick the release up. It doubles as a release channel:
# point the conservative customers at a server wrapped in this and they
# get every release a week late, from the same corpus, with no second copy
# of anything.
#
#   Paquette::GemServer::CooldownRepository.new(repo, interval: 7 * 24 * 60 * 60)
#
# The interval is in seconds. Paquette has no ActiveSupport, so there is
# no `7.days` to write here — anything answering to `to_i` will do.
#
# Read-only, for the same reason ReadGatedRepository is: you do not push
# through a delayed view of the corpus. A push into a cooldown view would
# land in the underlying repository and then immediately vanish from the
# view that accepted it, which is a confusing way to say "wrong wrapper".
# Wrap the bare repository for the push endpoint and this one for the
# cooling channel.
class Paquette::GemServer::CooldownRepository < Paquette::GemServer::ReadonlyRepository
  # `published_at:`, when given, is called with `name:` and `version:` and
  # returns a Time — or nil for "I do not know". See #published_time for
  # what the default source is and why, and #servable? for what nil does.
  #
  # `published_at_validator:` goes with it, and only with it: a callable
  # taking no arguments that returns a string which changes whenever any
  # answer `published_at:` would give changes — or nil for "I cannot say".
  # Without one, a view over a custom source emits no validator. See
  # #cache_validator for why.
  #
  # `clock:` is here so tests do not have to sleep; it returns the current
  # Time and nothing calls it more than it has to.
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

  # What this view serves moves with the clock while the corpus underneath
  # sits still, so the inner validator passed through would answer 304 to a
  # client holding the index from before a version cooled - hiding exactly
  # the release the channel exists to deliver. But the clock only matters
  # at the moments a version crosses the boundary, and versions cross it in
  # the order they were published. Over a fixed corpus, then, the servable
  # set is named exactly by how many of the known publish times are at
  # least `interval` old: the count moves when, and only when, a version
  # cools. (That count is the latest cooled publish time in another form -
  # the same thing over a fixed sorted list, without a timestamp's
  # precision to worry about.) A version with no known publish time is
  # always served and never moves the set, so it is left out altogether.
  #
  # So the validator is a digest of the inner validator, the interval and
  # that count. Counting is a binary search over the publish times sorted
  # once, which is the walk a 304 is there to skip - done once per corpus
  # rather than once per request. The sorted list is memoized under the
  # inner validator, which is the stack's promise that nothing it serves
  # has changed, and the default publish time is read out of the gem
  # itself, so it cannot have changed either. One entry: a new inner
  # validator replaces the old list. The memo lives on this instance, so
  # build the wrapper once and not per request.
  #
  # A custom `published_at:` is a different animal. It may read a table
  # whose rows change while the corpus does not, and nothing here can see
  # that happen, so it only gets a validator when its owner can name its
  # state with `published_at_validator:`. That is folded into both the
  # memo key and the digest; nil from it, or no validator at all, gives no
  # ETag - the same fail-closed rule as everywhere else, where the price of
  # not knowing is serving in full. Rebuilding the memo per request
  # instead would have been correct for exactly as long as the table did
  # not change between two requests, which is no guarantee at all.
  #
  # The clock is read once here and again for every servable? during a
  # render, so a version cooling between the two is in the body but not
  # the validator. That errs the safe way: the client's next ETag cannot
  # match, and it gets a 200 it did not strictly need.
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

  # A gem with no servable version disappears from /names and /versions
  # altogether rather than showing up with an empty version list. Bundler
  # treats a listed name as resolvable and goes looking for its /info/
  # file; an empty one makes it report a gem it cannot find a version of,
  # which is a worse error message than the gem simply not being there.
  #
  # This costs a directory listing per gem in the corpus — the same walk
  # gem_versions does. ReadGatedRepository's gem_names is a filter over
  # names alone and is cheaper; there is no equivalent shortcut here,
  # because whether a name survives is a fact about its versions.
  def gem_names
    super.select { |gem_name| versions_for_gem(gem_name).any? }
  end

  def gem_versions
    super.select { |gem_name, version| servable?(gem_name, version) }
  end

  def versions_for_gem(gem_name)
    super.select { |version| servable?(gem_name, version) }
  end

  # /specs.4.8 and /latest_specs.4.8 are built out of gem_versions, so
  # they follow from the filter above without this class touching them —
  # and "latest" in the latest_specs sense becomes the latest *servable*
  # version, which is exactly the point of the channel.

  def compact_info(gem_name)
    all_info = super
    return all_info unless all_info.is_a?(Array)

    all_info.select do |line|
      # The version column, platform suffix and all — the same
      # first-column read ReadGatedRepository filters these lines by.
      version = line.split(" ", 2).first
      servable?(gem_name, version)
    end
  end

  # The download path has to agree with the index, or Bundler resolves
  # against a version it is then handed a 404 for and reports a failure
  # nobody can act on. A cooling version 404s.
  #
  # A download's ETag is the checksum of its bytes and never asks
  # cache_validator, and a cooldown cannot change the bytes at a path -
  # only whether the path is served at all, which gem_exists? has settled
  # before the server computes an ETag. So downloads need nothing from
  # the reasoning above #cache_validator.
  def gem_file_path(gem_name, version)
    super if servable?(gem_name, version)
  end

  def gem_exists?(gem_name, version)
    if servable?(gem_name, version)
      super
    else
      false
    end
  end

  # gem_spec is deliberately *not* filtered, exactly as in
  # ReadGatedRepository: /quick/Marshal.4.8 asks gem_exists? before it
  # asks for a spec, so the gate above already covers that endpoint. And
  # the default published_at source reads spec.date — a wrapper that hid
  # the spec of a cooling gem would be unable to tell that it is cooling.

  # True when the version has been published for at least `interval`
  # seconds. The comparison is `>=`, so a version whose age is exactly the
  # interval is served: the cooldown is the time you must wait, not a time
  # you must exceed.
  #
  # An unknown publication time fails **open** — the version is served.
  # This is a deliberate choice and worth saying loudly: failing closed
  # would mean that anything this wrapper cannot date becomes permanently
  # invisible, and "permanently invisible" is a broken `bundle install`
  # for every customer on this channel, caused by a missing timestamp
  # rather than by anything wrong with the gem. A cooldown is a delay
  # policy, not an authorization boundary; if a version must not be
  # served, gate it with ReadGatedRepository, which is the wrapper whose
  # job that is.
  def servable?(gem_name, version)
    published = published_time(gem_name, version)
    return true if published.nil?

    cooled?(published, @clock.call)
  end

  private

  # The one comparison both servable? and cache_validator make, so the two
  # cannot disagree about which side of the boundary a version is on.
  def cooled?(published, now)
    (now - published) >= @interval
  end

  # The known publish times of every version the inner repository lists,
  # sorted, out of the same published_time servable? reads. Rebuilt only
  # when `key` changes. Built under the lock, so a burst of requests after
  # a push walks the corpus once rather than once each.
  def publish_times_for(key)
    @publish_times_lock.synchronize do
      memo_key, times = @publish_times
      return times if memo_key == key

      times = __getobj__.gem_versions.filter_map { |gem_name, version| published_time(gem_name, version) }.sort.freeze
      @publish_times = [key, times].freeze
      times
    end
  end

  # Where a publication timestamp comes from.
  #
  # The default is `spec.date`, the date recorded in the gemspec, and the
  # reasoning is mostly about what the alternatives do when the server is
  # moved:
  #
  # *Not the file mtime.* An mtime is not a property of the gem, it is a
  # property of this filesystem right now. An rsync, a container rebuild
  # or a restore from backup resets every one of them — and with mtime as
  # the source, that makes the entire corpus look freshly published and
  # puts every gem into cooldown at once. That is a self-inflicted
  # outage: `bundle install` starts failing for every customer on the
  # cooldown channel, at the exact moment somebody was already busy
  # moving the server.
  #
  # *Not a timestamp minted into the sidecar cache.* The sidecar is
  # documented as an optimization and never a requirement: it may be
  # deleted at any time and regenerated from the gem. Cooldown state is
  # semantic, not disposable, so nothing durable can live there — a
  # "first seen at" written on first read would be re-minted as "now" by
  # a `rm -rf` of the cache directories, with the same whole-corpus
  # cooldown as above.
  #
  # `spec.date` is intrinsic to the immutable gem bytes, so it survives
  # all of that, and it is free to cache in the sidecar *precisely
  # because* it can always be re-derived from the gem.
  #
  # Its weakness is that it is publisher-controlled and records the build
  # time, not the moment the artifact appeared on this server: a gem built
  # in March and pushed in June is already past a seven-day cooldown when
  # it arrives. For a private registry whose publishers you employ, that
  # is acceptable. Anyone who needs the stronger property passes
  # `published_at:` and answers from a table of their own:
  #
  #   CooldownRepository.new(repo, interval: ..., published_at: ->(name:, version:) {
  #     GemPush.where(name: name, version: version).pick(:created_at)
  #   })
  def published_time(gem_name, version)
    Measurometer.instrument("paquette.gem_cooldown.published_at") do
      if @published_at_source
        @published_at_source.call(name: gem_name, version: version)
      elsif __getobj__.respond_to?(:published_at)
        __getobj__.published_at(gem_name, version)
      else
        # A repository from outside this gem need not implement
        # published_at. Reading the spec is what the base implementation
        # does anyway, only without the sidecar cache in front of it.
        __getobj__.gem_spec(gem_name, version)&.date
      end
    end
  end
end
