require_relative "../test_helper"
require "puma"
require "puma/server"
require "time"
require "tmpdir"

# Drives rubygems' own gem_server_conformance suite against a live paquette.
#
# The suite ships as an RSpec CLI (the `gem_server_conformance` binary). It
# pushes, yanks and re-fetches gems over HTTP against whatever UPSTREAM points
# at, and asserts the exact compact-index and legacy-index bytes a conformant
# server has to return. So the test here is mostly a rig: boot a gem server on
# a port, hand the CLI the URL, and let it be the assertion.
#
# Two things it needs are not part of any gem server's public surface, and
# neither is allowed to leak into the shipped app:
#
#   - POST /set_time, which pins the server's clock so `created_at:` in
#     /versions is predictable;
#   - POST /rebuild_versions_list, which asks for a freshly compacted
#     versions list.
#
# Both are mounted *around* Paquette::GemServer by the rig below, the way
# rubygems' own reference harness wraps gemstash. The server under test is a
# bare DirectoryGemRepository with no wrappers — the configuration whose job
# is to be conformant. Anything in front of it (a read gate, a personalizer,
# the cooldown view) deliberately changes what a caller sees, and is not what
# this suite is about.
class GemServerConformanceTest < Minitest::Test
  # Only the suite's own `Authorization:` handshake needs this; paquette does
  # not authenticate, so any non-empty value will do.
  API_KEY = "paquette-conformance-key"

  # Pins Time.now for the process that serves requests. Prepended in the
  # forked child only — the parent runs minitest, and a test process whose
  # clock says 1990 is a test process that cannot time anything.
  module Clock
    class << self
      attr_accessor :now_override
    end

    def now
      Clock.now_override || super
    end
  end

  def test_paquette_is_a_conformant_gem_server
    require_tool("gem_server_conformance", conformance_available?, "PAQUETTE_REQUIRE_CONFORMANCE")

    Dir.mktmpdir("paquette_conformance") do |dir|
      port = boot_server(dir)
      begin
        output = run_conformance("http://127.0.0.1:#{port}")
        status = $?
        # Echoed whether it passed or failed: the suite's own summary is the
        # only readable account of what it found.
        puts output
        assert status.success?, "gem_server_conformance reported failures:\n\n#{output}"
      ensure
        shut_down_server
      end
    end
  end

  private

  def conformance_available?
    Gem::Specification.find_by_name("gem_server_conformance")
    true
  rescue Gem::MissingSpecError
    false
  end

  # The server runs in a forked child rather than in this process, for the
  # clock: /set_time has to move Time.now for everything that renders a
  # response, and doing that here would move it for minitest too. The child
  # writes the port it bound back over a pipe, so nothing has to guess at a
  # free port and race for it.
  def boot_server(gems_dir)
    reader, writer = IO.pipe

    @server_pid = fork do
      reader.close
      # Without this the child can get far enough into shutdown for
      # minitest's autorun hook to fire and report a second, empty suite.
      Signal.trap("TERM") { exit!(0) }
      Time.singleton_class.prepend(Clock)

      server = Puma::Server.new(conformance_app(gems_dir))
      bound = server.add_tcp_listener("127.0.0.1", 0).addr[1]
      writer.puts(bound)
      writer.close
      server.run
      sleep
    end

    writer.close
    port = Integer(reader.gets.to_s.strip)
    reader.close
    port
  end

  def shut_down_server
    return unless @server_pid

    Process.kill("TERM", @server_pid)
    Process.wait(@server_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # The app the child serves: the real gem server, with the suite's two
  # test-only endpoints mounted in front of it.
  def conformance_app(gems_dir)
    set_time = lambda do |env|
      Clock.now_override = Time.iso8601(env["rack.input"].read).utc
      [200, {"content-type" => "text/plain"}, ["OK"]]
    end

    # A no-op, and that is the finding rather than an omission. "Rebuild the
    # versions list" presumes a materialized, append-only /versions file that
    # gains a row per push and is periodically compacted back down to one row
    # per gem. Paquette has no such file: handle_compact_versions renders the
    # whole index out of the gems directory on every request, so what it
    # serves is already the compacted form and `created_at:` is already
    # stamped from the current clock. There is no state to drop and nothing to
    # regenerate, so the only honest implementation is to answer 200 and
    # change nothing.
    rebuild_versions_list = lambda do |_env|
      [200, {"content-type" => "text/plain"}, ["OK"]]
    end

    server = Paquette::GemServer.new(Paquette::GemServer::DirectoryGemRepository.new(gems_dir))

    Rack::Builder.new do
      map("/set_time") { run set_time }
      map("/rebuild_versions_list") { run rebuild_versions_list }
      run server
    end
  end

  def run_conformance(upstream)
    command = [
      "bundle", "exec", "gem_server_conformance",
      "--require", File.expand_path("rspec_exclusions.rb", __dir__),
      "--format", "progress"
    ]
    env = {"UPSTREAM" => upstream, "GEM_HOST_API_KEY" => API_KEY}

    IO.popen(env, command, err: [:child, :out], &:read)
  end
end
