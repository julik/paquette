require "rubygems"

# Lets a repack tell RubyGems what timestamp to stamp into the archive without
# going through ENV.
#
# The timestamp matters because a repack has to be reproducible: Personalizer
# publishes the SHA256 of a personalized gem in the compact index and then
# serves the gem, and if the two builds disagree by a second `bundle install`
# reports the gem a customer paid for as tampered. RubyGems takes the mtime of
# every tar entry, and the mtime in every gzip header, from
# `Gem.source_date_epoch` — so pinning that to the source gem's own date is
# what makes two machines, and two requests, agree.
#
# The only lever RubyGems offers for it is ENV["SOURCE_DATE_EPOCH"], read fresh
# on each call, inline, in four places inside Gem::Package::TarWriter that take
# no argument and are handed no writer state. That is fine for `gem build`,
# which is a process per build. It is not fine here: ENV is process-wide, so two
# threads repacking two gems at once are two builds sharing one variable, and
# what comes out is one of them stamped with the other's date — bytes that
# depend on what was being built next to them. Serializing repacks around the
# variable would fix it by making a server build one gem at a time, which is a
# strange price to pay for a timestamp.
#
# So the reader is overridden instead of the variable being written. Every path
# that wants the epoch — the four TarWriter call sites, and Gem::Package's own
# @build_time — goes through Gem.source_date_epoch_string, which makes it the
# one place to intervene. `with` holds the value in fiber-local storage, so
# concurrent repacks cannot see each other's and no lock is needed; with nothing
# set, this is RubyGems' own behavior, ENV included, unchanged.
module Paquette::GemServer::GemRepacker::BuildTime
  KEY = :paquette_gem_repacker_source_date_epoch

  # Fiber-local rather than thread-local, and deliberately: a build runs to
  # completion inside the fiber that started it, so under a thread pool this is
  # per-request and under a fiber scheduler it stays per-request.
  def self.with(time)
    previous = Thread.current[KEY]
    Thread.current[KEY] = time.to_i.to_s
    yield
  ensure
    Thread.current[KEY] = previous
  end

  def source_date_epoch_string
    Thread.current[KEY] || super
  end

  # Prepending onto another library's module is worth being loud about when it
  # stops working. A RubyGems that no longer routes the epoch through this
  # method would not fail here — it would quietly go back to reading ENV, and
  # the first sign of it would be a customer's checksum mismatch. Better to
  # refuse to load.
  unless Gem.respond_to?(:source_date_epoch_string)
    raise "RubyGems #{Gem::VERSION} has no Gem.source_date_epoch_string; " \
          "Paquette cannot pin a repack's timestamp without it"
  end

  Gem.singleton_class.prepend(self)
end
