require "rack/body_proxy"

# Ceiling on any single regexp match, held for the duration of a request —
# every path here meets a regexp with a client-chosen string on the other
# side. Prepended into every Rack app in this gem; an application wanting a
# different ceiling sets `Paquette.regexp_timeout` once, at boot.
module Paquette::RegexpTimeout
  # 3.2 gained Regexp.timeout and its error; on 3.1 this stands aside. The
  # placeholder keeps the rescue from naming a constant that may not exist.
  SUPPORTED = Regexp.respond_to?(:timeout=)
  TimedOut = SUPPORTED ? Regexp::TimeoutError : Class.new(StandardError)

  # Regexp.timeout is process-global, so requests are counted instead of
  # set-and-restored: otherwise one thread lowers the ceiling out from under
  # a match another thread is inside.
  @lock = Mutex.new
  @in_flight = 0
  @ambient = nil

  class << self
    # Arms the process-wide regexp ceiling for one request.
    #
    # @return [void]
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

    # Releases one request's hold; the last one out restores the ambient
    # timeout.
    #
    # @return [void]
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

    # A 400, not a 500: it ran out of time on bytes the client sent.
    #
    # @param error [Exception]
    # @return [Array] a Rack response triplet
    def timed_out(error)
      [400, {"Content-Type" => "text/plain"}, ["Request took too long to parse: #{error.class}"]]
    end
  end

  # @param env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(env)
    return super unless SUPPORTED

    Paquette::RegexpTimeout.acquire
    handed_off = false

    begin
      status, headers, body = super
      # The release hangs off the body's #close because a gem download
      # returns an open File and reads it after #call has returned.
      proxied = Rack::BodyProxy.new(body) { Paquette::RegexpTimeout.release }
      handed_off = true
      [status, headers, proxied]
    rescue TimedOut => e
      Paquette::RegexpTimeout.timed_out(e)
    ensure
      Paquette::RegexpTimeout.release unless handed_off
    end
  end
end
