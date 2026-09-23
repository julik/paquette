require "rack/body_proxy"

module Paquette
  class << self
    # The ceiling every Rack app in this gem installs for the duration of a
    # request, in seconds — see RegexpTimeout for what it is for. Set it at
    # boot; a change under live requests takes effect on the next one. `nil`
    # is "no ceiling", which is Ruby's own default and a decision to make
    # knowingly.
    attr_accessor :regexp_timeout
  end

  # Ceiling on any single regexp match, held for the duration of a request.
  # Every path here meets a regexp with a client-chosen string on the other
  # side, and those patterns are linear only until someone adds one that is not.
  #
  # Prepended into every Rack app in this gem rather than offered as a
  # middleware: the ceiling is a property of these apps, not a decision an
  # application embedding them should have to remember to make. Nesting is
  # free — a request through SubdomainRouter into GemServer arms it twice and
  # the count, not the innermost exit, is what releases it.
  #
  # Regexp.timeout is per match, not per request, and dispatch runs a dozen or
  # so — a bad request costs the timeout times the matches it survives, hence
  # the low default.
  #
  # It is also process-global rather than per-thread, so requests are counted
  # instead of set-and-restored: otherwise one thread lowers the ceiling out
  # from under a match another thread is inside. That count lives on the module
  # rather than in each including class, for the same reason — one process, one
  # ceiling. The release hangs off the body's #close because a gem download
  # returns an open File and reads it after #call has returned.
  #
  # An application wanting a different ceiling sets it once, at boot:
  #
  #   Paquette.regexp_timeout = 0.1
  #
  module RegexpTimeout
    DEFAULT_TIMEOUT = 0.05

    # 3.2 gained Regexp.timeout and its error; on 3.1 this stands aside. The
    # placeholder keeps the rescue from naming a constant that may not exist.
    SUPPORTED = Regexp.respond_to?(:timeout=)
    TimedOut = SUPPORTED ? Regexp::TimeoutError : Class.new(StandardError)

    @lock = Mutex.new
    @in_flight = 0
    @ambient = nil

    class << self
      def acquire
        @lock.synchronize do
          seconds = Paquette.regexp_timeout
          @ambient = Regexp.timeout if @in_flight.zero?
          # Armed against what is there now rather than against the count: a
          # body that is never closed leaks a request, and anything else in
          # the process may set Regexp.timeout meanwhile. Leaving the ceiling
          # off because the count says it should already be on is the one
          # failure mode with teeth — a request matching unbounded.
          Regexp.timeout = seconds unless Regexp.timeout == seconds
          @in_flight += 1
        end
      end

      def release
        @lock.synchronize do
          @in_flight -= 1
          if @in_flight <= 0
            @in_flight = 0
            Regexp.timeout = @ambient
            @ambient = nil
          end
        end
      end

      # Same reasoning as Routes::MalformedRequest: it ran out of time on bytes
      # the client sent.
      def timed_out(error)
        [400, {"Content-Type" => "text/plain"}, ["Request took too long to parse: #{error.class}"]]
      end
    end

    def call(env)
      return super unless SUPPORTED

      RegexpTimeout.acquire
      handed_off = false

      begin
        status, headers, body = super
        proxied = Rack::BodyProxy.new(body) { RegexpTimeout.release }
        handed_off = true
        [status, headers, proxied]
      rescue TimedOut => e
        RegexpTimeout.timed_out(e)
      ensure
        RegexpTimeout.release unless handed_off
      end
    end
  end

  self.regexp_timeout = RegexpTimeout::DEFAULT_TIMEOUT
end
