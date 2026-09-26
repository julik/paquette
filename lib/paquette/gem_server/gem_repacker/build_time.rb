require "rubygems"

# Pins the timestamp RubyGems stamps into a repacked gem, so that repeated
# repacks of the same gem are byte-identical. RubyGems only offers
# ENV["SOURCE_DATE_EPOCH"] for this, which is process-wide and thus unsafe
# with concurrent repacks; this overrides the reader instead.
module Paquette::GemServer::GemRepacker::BuildTime
  KEY = :paquette_gem_repacker_source_date_epoch

  # Runs the block with the given build timestamp pinned. Fiber-local rather
  # than thread-local, deliberately: a build runs to completion inside the
  # fiber that started it, so this stays per-request under both a thread pool
  # and a fiber scheduler.
  #
  # @param time [Time, Integer] the timestamp to stamp into archive entries
  # @return [Object] the return value of the block
  def self.with(time)
    previous = Thread.current[KEY]
    Thread.current[KEY] = time.to_i.to_s
    yield
  ensure
    Thread.current[KEY] = previous
  end

  # @return [String] the pinned epoch, or whatever RubyGems would have used
  def source_date_epoch_string
    Thread.current[KEY] || super
  end

  # A RubyGems that no longer routes the epoch through this method would not
  # fail here — it would quietly go back to reading ENV, and the first sign
  # would be a customer's checksum mismatch. Better to refuse to load.
  unless Gem.respond_to?(:source_date_epoch_string)
    raise "RubyGems #{Gem::VERSION} has no Gem.source_date_epoch_string; " \
          "Paquette cannot pin a repack's timestamp without it"
  end
end

Gem.singleton_class.prepend(Paquette::GemServer::GemRepacker::BuildTime)
