require "rack/body_proxy"

module Paquette
  # Ceiling on any single regexp match, held for the duration of a request.
  # Every path here meets a regexp with a client-chosen string on the other
  # side, and those patterns are linear only until someone adds one that is not.
  #
  # Regexp.timeout is per match, not per request, and dispatch runs a dozen or
  # so — a bad request costs the timeout times the matches it survives, hence
  # the low default.
  #
  # It is also process-global rather than per-thread, so requests are counted
  # instead of set-and-restored: otherwise one thread lowers the ceiling out
  # from under a match another thread is inside. The release hangs off the
  # body's #close because a gem download returns an open File and reads it
  # after #call has returned.
  #
  #   use Paquette::RegexpTimeout, seconds: 0.05
  #
  class RegexpTimeout
    DEFAULT_TIMEOUT = 0.05

    # 3.2 gained Regexp.timeout and its error; on 3.1 this stands aside. The
    # placeholder keeps the rescue from naming a constant that may not exist.
    SUPPORTED = Regexp.respond_to?(:timeout=)
    TimedOut = SUPPORTED ? Regexp::TimeoutError : Class.new(StandardError)

    def initialize(app, seconds: DEFAULT_TIMEOUT)
      @app = app
      @seconds = seconds
      @lock = Mutex.new
      @in_flight = 0
      @ambient = nil
    end

    def call(env)
      return @app.call(env) unless SUPPORTED

      acquire
      handed_off = false

      begin
        status, headers, body = @app.call(env)
        proxied = Rack::BodyProxy.new(body) { release }
        handed_off = true
        [status, headers, proxied]
      rescue TimedOut => e
        timed_out(e)
      ensure
        release unless handed_off
      end
    end

    private

    def acquire
      @lock.synchronize do
        if @in_flight.zero?
          @ambient = Regexp.timeout
          Regexp.timeout = @seconds
        end
        @in_flight += 1
      end
    end

    def release
      @lock.synchronize do
        @in_flight -= 1
        if @in_flight.zero?
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
end
