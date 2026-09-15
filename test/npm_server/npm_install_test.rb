require_relative "../test_helper"
require "socket"
require "puma"
require "puma/server"

# A completing real-npm install proves the registry correct, not merely self-consistent.
class NpmInstallTest < Minitest::Test
  def setup
    require_tool "npm", !`which npm`.strip.empty?, "PAQUETTE_REQUIRE_NPM"

    @packages_dir = Dir.mktmpdir("paquette_npm_install_packages")
    @project_dir = Dir.mktmpdir("paquette_npm_install_project")
    @home_dir = Dir.mktmpdir("paquette_npm_install_home")
  end

  def teardown
    stop_server
    [@packages_dir, @project_dir, @home_dir].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  def test_npm_installs_a_package
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0")
    serve(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))

    assert npm_install("widget@1.0.0"), "npm install failed:\n#{@npm_output}"
    assert_path_exists File.join(@project_dir, "node_modules", "widget", "package.json")
  end

  def test_npm_installs_a_scoped_package
    write_npm_package(@packages_dir, name: "@acme/widgets", version: "2.0.0")
    serve(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))

    assert npm_install("@acme/widgets@2.0.0"), "npm install failed:\n#{@npm_output}"
    assert_path_exists File.join(@project_dir, "node_modules", "@acme", "widgets", "package.json")
  end

  def test_npm_resolves_a_dependency_between_two_served_packages
    write_npm_package(@packages_dir, name: "leaf", version: "1.2.0")
    write_npm_package(@packages_dir, name: "trunk", version: "1.0.0", dependencies: {"leaf" => "^1.0.0"})
    serve(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))

    assert npm_install("trunk"), "npm install failed:\n#{@npm_output}"
    assert_path_exists File.join(@project_dir, "node_modules", "leaf", "package.json")
  end

  def test_npm_installs_the_latest_stable_rather_than_a_prerelease
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0")
    write_npm_package(@packages_dir, name: "widget", version: "2.0.0-beta.1")
    serve(Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir))

    assert npm_install("widget"), "npm install failed:\n#{@npm_output}"
    installed = JSON.parse(File.read(File.join(@project_dir, "node_modules", "widget", "package.json")))
    assert_equal "1.0.0", installed["version"]
  end

  # Were the repack not reproducible, npm would refuse this install.
  def test_npm_installs_a_personalized_package
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0",
      files: {"index.js" => "// paquette_license_info\nmodule.exports = 1;\n"})

    repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    serve(Paquette::NpmServer::Personalizer.new(repository,
      license_key: "LIC-ABC-123",
      magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme Inc (LIC-ABC-123)"},
      files: {"LICENSE.txt" => "Licensed to Acme Inc."}))

    assert npm_install("widget@1.0.0"), "npm install failed:\n#{@npm_output}"

    installed_dir = File.join(@project_dir, "node_modules", "widget")
    assert_includes File.read(File.join(installed_dir, "index.js")), "LIC-ABC-123"
    assert_equal "Licensed to Acme Inc.", File.read(File.join(installed_dir, "LICENSE.txt"))
    assert_equal "LIC-ABC-123",
      JSON.parse(File.read(File.join(installed_dir, "package.json")))["paquette"]["licenseKey"]
  end

  # The install itself has to fail, not merely the listing hide the package.
  def test_npm_cannot_install_a_package_outside_the_entitlement
    write_npm_package(@packages_dir, name: "widget", version: "1.0.0")
    write_npm_package(@packages_dir, name: "secret", version: "1.0.0")

    repository = Paquette::NpmServer::DirectoryNpmRepository.new(@packages_dir)
    serve(Paquette::NpmServer::ReadGatedRepository.new(repository) { |name:, version: nil| name == "widget" })

    assert npm_install("widget@1.0.0"), "npm install failed:\n#{@npm_output}"
    refute npm_install("secret@1.0.0"), "a gated package was installable:\n#{@npm_output}"
  end

  private

  def serve(repository)
    app = Paquette::NpmServer.new(repository)
    @port = find_free_port

    # A real Rack server: how the response reaches npm is part of the test.
    @server = Puma::Server.new(app, nil, {log_writer: Puma::LogWriter.strings})
    @server.add_tcp_listener("127.0.0.1", @port)
    @server.run
    wait_for_server
  end

  def find_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def wait_for_server
    50.times do
      begin
        return if Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/-/ping")).code == "200"
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

  def npm_install(spec)
    command = [
      "npm", "install", spec,
      "--registry=http://127.0.0.1:#{@port}",
      "--no-audit", "--no-fund", "--no-package-lock",
      "--prefix", @project_dir,
      "--cache", File.join(@home_dir, "cache"),
      "--userconfig", File.join(@home_dir, "npmrc"),
      "--loglevel", "error",
      # npm retries a failed fetch for minutes, and two tests assert failure.
      "--fetch-retries", "0"
    ]

    @npm_output = IO.popen(
      {"HOME" => @home_dir, "npm_config_offline" => "false"},
      command, err: [:child, :out], &:read
    )
    $?.success?
  end
end
