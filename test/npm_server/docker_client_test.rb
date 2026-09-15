require_relative "../test_helper"
require "socket"
require "puma"
require "puma/server"

# The npm client, in a container, talking to a Paquette on the host.
#
# The rest of the suite constructs requests in Ruby and checks Paquette's own
# answers, which cannot catch a registry that is merely self-consistent. Here a
# real npm does the resolving, the downloading, the integrity check and the
# unpacking, over a real socket, on a machine that has none of Paquette's code
# on it. If npm is happy, a customer will be.
#
# The container reaches the host through host.docker.internal, which Docker
# Desktop provides and which --add-host wires up on plain Linux dockers.
class DockerNpmClientTest < Minitest::Test
  IMAGE = "paquette-npm-test".freeze
  TOKEN = "pqt_test_token".freeze

  @image_built = false

  class << self
    attr_accessor :image_built
  end

  def setup
    require_tool "Docker", docker_available?, "PAQUETTE_REQUIRE_DOCKER"

    @packages_dir = Dir.mktmpdir("paquette_docker_packages")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    build_image
  end

  def teardown
    stop_server
    FileUtils.rm_rf(@packages_dir) if @packages_dir
  end

  def test_npm_installs_a_package
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0", dependencies: {"leaf" => "^1.0.0"})
    write_npm_package(@packages_dir, name: "leaf", version: "1.4.0")
    serve(@repository)

    output = run_npm(<<~SH)
      npm install widget --loglevel error
      cat node_modules/widget/package.json
      test -f node_modules/leaf/package.json && echo DEPENDENCY-INSTALLED
    SH

    assert_npm_ok output
    assert_includes output, "DEPENDENCY-INSTALLED"
    assert_includes output, '"version": "1.0.0"'
  end

  def test_npm_installs_a_scoped_package
    write_npm_package(@packages_dir, name: "@acme/widgets", version: "2.1.0")
    serve(@repository)

    output = run_npm(<<~SH)
      npm install @acme/widgets --loglevel error
      cat node_modules/@acme/widgets/package.json
    SH

    assert_npm_ok output
    assert_includes output, '"name": "@acme/widgets"'
    assert_includes output, '"version": "2.1.0"'
  end

  # npm refuses a tarball whose bytes do not match the integrity it was given,
  # so an install that completes here proves the personalized tarball Paquette
  # built on the fly is the one it published a hash for.
  def test_npm_installs_a_personalized_package
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0",
      files: {"index.js" => "// paquette_license_info\nmodule.exports = 1;\n"})

    serve(Paquette::NpmServer::Personalizer.new(@repository,
      license_key: "LIC-DOCKER-1",
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme Inc (LIC-DOCKER-1)"},
      files: {"LICENSE.txt" => "Licensed to Acme Inc."}))

    output = run_npm(<<~SH)
      npm install widget --loglevel error
      head -1 node_modules/widget/index.js
      cat node_modules/widget/LICENSE.txt
    SH

    assert_npm_ok output
    assert_includes output, "LIC-DOCKER-1"
    assert_includes output, "Licensed to Acme Inc."
  end

  def test_npm_cannot_install_a_package_outside_the_entitlement
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0")
    write_npm_package(@packages_dir, name: "secret", version: "1.0.0")

    serve(Paquette::NpmServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "widget" })

    output = run_npm("npm install secret --loglevel error --fetch-retries 0", expect_failure: true)
    assert_match(/404|E404|not found/i, output)

    assert_npm_ok run_npm("npm install widget --loglevel error")
  end

  # `npm publish` PUTs the metadata document with the tarball inlined, which is
  # a shape no test of ours would think to build by hand.
  def test_npm_publishes_a_package
    serve(@repository)

    output = run_npm(<<~SH)
      #{write_package_json("pushed-by-npm", "1.2.3")}
      echo "module.exports = 'hello';" > index.js
      npm publish --loglevel error
    SH

    assert_npm_ok output
    assert_equal ["1.2.3"], @repository.versions_for_package("pushed-by-npm")

    info = @repository.package_info("pushed-by-npm", "1.2.3")
    assert_equal "pushed-by-npm", info["name"]
    assert_equal "1.2.3", info["version"]
  end

  def test_npm_publishes_a_scoped_package
    serve(@repository)

    output = run_npm(<<~SH)
      #{write_package_json("@acme/pushed", "0.1.0")}
      echo "module.exports = 1;" > index.js
      npm publish --access public --loglevel error
    SH

    assert_npm_ok output
    assert_equal ["0.1.0"], @repository.versions_for_package("@acme/pushed")
    assert_path_exists File.join(@packages_dir, "@acme", "pushed", "pushed-0.1.0.tgz")
  end

  # The round trip: what npm pushed is what npm can pull back, integrity and
  # all. Paquette derives the hashes itself rather than trusting the ones the
  # publisher sent, so this is not circular.
  def test_a_published_package_can_be_installed_again
    serve(@repository)

    assert_npm_ok run_npm(<<~SH)
      #{write_package_json("round-trip", "2.0.0")}
      echo "module.exports = 'round trip';" > index.js
      npm publish --loglevel error
    SH

    output = run_npm(<<~SH)
      mkdir -p /home/node/consumer && cd /home/node/consumer
      #{npmrc}
      npm install round-trip --loglevel error
      cat node_modules/round-trip/index.js
    SH

    assert_npm_ok output
    assert_includes output, "round trip"
  end

  def test_republishing_a_version_is_refused
    serve(@repository)

    script = <<~SH
      #{write_package_json("twice", "1.0.0")}
      echo "module.exports = 1;" > index.js
      npm publish --loglevel error
    SH

    assert_npm_ok run_npm(script)
    output = run_npm(script, expect_failure: true)

    assert_match(/409|conflict|already exists/i, output)
  end

  def test_writes_are_refused_through_a_read_gated_registry
    serve(Paquette::NpmServer::ReadGatedRepository.new(@repository) { |name:, version: nil| true })

    output = run_npm(<<~SH, expect_failure: true)
      #{write_package_json("nope", "1.0.0")}
      echo "module.exports = 1;" > index.js
      npm publish --loglevel error --fetch-retries 0
    SH

    assert_match(/403|forbidden|not allowed/i, output)
    assert_empty @repository.package_names
  end

  # The licensing story end to end: npm sends the token it was configured with,
  # the middleware turns it into an identity, and the entitlement built from
  # that identity decides what npm is allowed to see.
  def test_a_token_gated_registry
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0")
    repository = @repository

    authorized = Rack::Builder.new do
      use Paquette::TokenAuthorization, "Paquette" do |token|
        (token == TOKEN) ? Struct.new(:username).new("acme") : nil
      end
      run Paquette::NpmServer.new(repository)
    end

    serve_app(authorized.to_app)

    assert_npm_ok run_npm("npm install widget --loglevel error")

    without_token = run_npm("npm install widget --loglevel error --fetch-retries 0",
      npmrc: npmrc(token: nil), expect_failure: true)
    assert_match(/401|unauthorized|E401|ENEEDAUTH/i, without_token)
  end

  private

  def docker_available?
    @docker_available ||= system("docker info", out: File::NULL, err: File::NULL)
  end

  def build_image
    return if self.class.image_built

    dockerfile_dir = File.expand_path("../docker", __dir__)
    ok = system("docker", "build", "-q", "-t", IMAGE, dockerfile_dir, out: File::NULL, err: File::NULL)
    flunk "Could not build the #{IMAGE} image" unless ok

    self.class.image_built = true
  end

  def serve(repository)
    serve_app(Paquette::NpmServer.new(repository))
  end

  def serve_app(app)
    @port = find_free_port

    # 0.0.0.0 rather than 127.0.0.1: the client is in a container, so the
    # loopback the other tests bind to is not an address it can reach.
    @server = Puma::Server.new(app, nil, {log_writer: Puma::LogWriter.strings})
    @server.add_tcp_listener("0.0.0.0", @port)
    @server.run
    wait_for_server
  end

  def registry
    "http://host.docker.internal:#{@port}"
  end

  # An .npmrc naming this registry, and a token for it unless the caller wants
  # to be anonymous. npm declines to publish to a registry it has no credentials
  # for even when the registry does not ask for any, so the token is normally
  # configured and only sometimes checked.
  #
  # The registry line is never optional. Without it npm falls back to
  # registry.npmjs.org and installs whatever real package shares the name — a
  # green test that never touched Paquette at all.
  def npmrc(token: TOKEN)
    lines = [%(registry=#{registry})]
    lines << %(//host.docker.internal:#{@port}/:_authToken=#{token}) if token

    %(printf '%s\\n' #{lines.map { |line| %("#{line}") }.join(" ")} > .npmrc)
  end

  def write_package_json(name, version)
    <<~SH.strip
      cat > package.json <<'JSON'
      {"name": "#{name}", "version": "#{version}", "main": "index.js", "license": "MIT"}
      JSON
    SH
  end

  def run_npm(script, expect_failure: false, npmrc: nil)
    preamble = npmrc.nil? ? self.npmrc : npmrc
    # The probe asks only whether something answered. A token-gated registry
    # replies 401 to an unauthenticated ping and is perfectly reachable; only a
    # curl that got no HTTP response at all (code 000) means the container
    # cannot see the host, which is the case worth telling apart from a bug.
    full_script = <<~SH
      set -e
      status=$(curl -sS -o /dev/null -w '%{http_code}' #{registry}/-/ping || echo 000)
      if [ "$status" = "000" ]; then
        echo "REGISTRY-UNREACHABLE"
        exit 90
      fi
      #{preamble}
      #{script}
    SH

    command = [
      "docker", "run", "--rm",
      "--add-host=host.docker.internal:host-gateway",
      # Belt and braces over the .npmrc: if a test ever manages not to configure
      # the registry, npm quietly resolves against registry.npmjs.org and
      # installs whatever real package shares the name, which passes without
      # having tested Paquette at all. This has already happened once.
      "-e", "npm_config_registry=#{registry}",
      IMAGE, "sh", "-c", full_script
    ]

    output = IO.popen(command, err: [:child, :out], &:read)
    status = $?

    refute_includes output.to_s, "REGISTRY-UNREACHABLE",
      "the container could not reach Paquette on the host, so nothing below was tested"

    if expect_failure
      refute status.success?, "expected npm to fail, but it succeeded:\n#{output}"
    end

    @last_status = status
    output.to_s
  end

  def assert_npm_ok(output)
    assert @last_status.success?, "npm failed:\n#{output}"
    output
  end

  def find_free_port
    server = TCPServer.new("0.0.0.0", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Any answer means the socket is listening, which is all this is waiting for.
  # A token-gated registry answers 401 here and is no less started for it.
  def wait_for_server
    50.times do
      begin
        Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/-/ping"))
        return
      rescue
        # not up yet
      end
      sleep 0.1
    end
    flunk "Paquette did not start within 5 seconds"
  end

  def stop_server
    @server&.stop(true)
    @server = nil
  end
end
