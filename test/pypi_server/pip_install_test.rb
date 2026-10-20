require_relative "../test_helper"
require "socket"
require "puma"
require "puma/server"
require "rotp"

# Real pip and real twine against a real Rack server: a completing install
# proves the index correct, not merely self-consistent.
class PipInstallTest < Minitest::Test
  include PythonTooling

  # Records every path asked for, so a test can tell what pip actually used
  class PathRecorder
    attr_reader :paths

    def initialize(app)
      @app = app
      @paths = Queue.new
    end

    def call(env)
      @paths << env["PATH_INFO"]
      @app.call(env)
    end

    def seen
      [].tap { |all| all << @paths.pop until @paths.empty? }
    end
  end

  def setup
    require_python_venv

    @packages_dir = Dir.mktmpdir("paquette_pip_packages")
    @target_dir = Dir.mktmpdir("paquette_pip_target")
    @home_dir = Dir.mktmpdir("paquette_pip_home")
    @work_dir = Dir.mktmpdir("paquette_pip_work")
    @repository = Paquette::PypiServer::DirectoryPypiRepository.new(@packages_dir)
  end

  def teardown
    stop_server
    [@packages_dir, @target_dir, @home_dir, @work_dir].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  def test_pip_installs_a_wheel
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    serve(Writable.pypi_server(@repository))

    assert pip_install("widgets==1.0.0"), "pip install failed:\n#{@output}"
    assert_equal "1.0.0", python_eval("import widgets; print(widgets.VERSION)")
  end

  # pip reads the JSON page, then the PEP 658 metadata, and only then the wheel
  def test_pip_uses_the_json_api_and_the_metadata_file
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    recorder = PathRecorder.new(Writable.pypi_server(@repository))
    serve(recorder)

    assert pip_install("widgets"), "pip install failed:\n#{@output}"
    seen = recorder.seen
    assert_includes seen, "/simple/widgets/"
    assert_includes seen, "/files/widgets/widgets-1.0.0-py3-none-any.whl.metadata"
    assert_includes seen, "/files/widgets/widgets-1.0.0-py3-none-any.whl"
  end

  def test_pip_finds_a_project_by_any_spelling_of_its_name
    write_wheel(@packages_dir, name: "acme-widgets", version: "1.0.0")
    serve(Writable.pypi_server(@repository))

    assert pip_install("Acme_Widgets"), "pip install failed:\n#{@output}"
    assert_equal "1.0.0", python_eval("import acme_widgets; print(acme_widgets.VERSION)")
  end

  def test_pip_builds_and_installs_an_sdist
    write_sdist(@packages_dir, name: "widgets", version: "1.0.0")
    serve(Writable.pypi_server(@repository))

    assert pip_install("widgets==1.0.0"), "pip install failed:\n#{@output}"
    assert_equal "1.0.0", python_eval("import widgets; print(widgets.VERSION)")
  end

  def test_pip_resolves_a_dependency_between_two_served_projects
    write_wheel(@packages_dir, name: "leaf", version: "1.2.0")
    metadata = core_metadata_text("trunk", "1.0.0").sub("\n\n", "\nRequires-Dist: leaf>=1.0\n\n")
    write_wheel(@packages_dir, name: "trunk", version: "1.0.0", metadata: metadata)
    serve(Writable.pypi_server(@repository))

    assert pip_install("trunk"), "pip install failed:\n#{@output}"
    assert_equal "1.2.0", python_eval("import leaf; print(leaf.VERSION)")
  end

  def test_pip_passes_over_a_yanked_file_unless_it_is_pinned
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    write_wheel(@packages_dir, name: "widgets", version: "2.0.0")
    @repository.yank_file("widgets", "widgets-2.0.0-py3-none-any.whl", reason: "broken")
    serve(Writable.pypi_server(@repository))

    assert pip_install("widgets"), "pip install failed:\n#{@output}"
    assert_equal "1.0.0", python_eval("import widgets; print(widgets.VERSION)")

    FileUtils.rm_rf(Dir.glob(File.join(@target_dir, "*")))
    assert pip_install("widgets==2.0.0"), "pip install failed:\n#{@output}"
    assert_equal "2.0.0", python_eval("import widgets; print(widgets.VERSION)")
  end

  def test_pip_passes_over_a_file_for_another_python
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    write_wheel(@packages_dir, name: "widgets", version: "2.0.0", requires_python: ">=4")
    serve(Writable.pypi_server(@repository))

    assert pip_install("widgets"), "pip install failed:\n#{@output}"
    assert_equal "1.0.0", python_eval("import widgets; print(widgets.VERSION)")
  end

  # pip checks the sha256 the page gave it, so this only passes if the page
  # describes the repacked file and not the one on disk
  def test_pip_installs_a_personalized_wheel
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "    # paquette_license_info\nVERSION = '1.0.0'\n"})
    personalized = Paquette::PypiServer::Personalizer.new(@repository,
      license_key: "LIC-ABC-123",
      magic_comment_replacements: {"# paquette_license_info" => "licensed to Acme Inc (LIC-ABC-123)"},
      files: {"widgets/LICENSE.txt" => "Licensed to Acme Inc."},
      cache_dir: File.join(@work_dir, "cache"))
    serve(Writable.pypi_server(personalized))

    assert pip_install("--require-hashes", "widgets==1.0.0 --hash=sha256:#{personalized.file_info("widgets", "widgets-1.0.0-py3-none-any.whl").sha256}"),
      "pip install failed:\n#{@output}"
    assert_includes File.read(File.join(@target_dir, "widgets", "__init__.py")), "    # licensed to Acme Inc (LIC-ABC-123)"
    assert_equal "Licensed to Acme Inc.", File.read(File.join(@target_dir, "widgets", "LICENSE.txt"))
    stamp = python_eval("import importlib.metadata as m, json; print(json.loads(m.distribution('widgets').read_text('paquette.json'))['license_key'])")
    assert_equal "LIC-ABC-123", stamp
  end

  def test_pip_installs_a_personalized_sdist
    write_sdist(@packages_dir, name: "widgets", version: "1.0.0",
      files: {"widgets/__init__.py" => "# paquette_license_info\nVERSION = '1.0.0'\n"})
    personalized = Paquette::PypiServer::Personalizer.new(@repository,
      license_key: "LIC-ABC-123",
      magic_comment_replacements: {"# paquette_license_info" => "licensed to LIC-ABC-123"},
      cache_dir: File.join(@work_dir, "cache"))
    serve(Writable.pypi_server(personalized))

    assert pip_install("widgets==1.0.0"), "pip install failed:\n#{@output}"
    assert_includes File.read(File.join(@target_dir, "widgets", "__init__.py")), "# licensed to LIC-ABC-123"
  end

  # The install has to fail, not merely the listing hide the project
  def test_pip_cannot_install_outside_the_entitlement
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    write_wheel(@packages_dir, name: "secret", version: "1.0.0")
    gated = Paquette::PypiServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "widgets" }
    serve(Writable.pypi_server(gated))

    assert pip_install("widgets"), "pip install failed:\n#{@output}"
    refute pip_install("secret"), "a gated project was installable:\n#{@output}"
  end

  def test_pip_needs_the_token_when_the_index_wants_one
    write_wheel(@packages_dir, name: "widgets", version: "1.0.0")
    serve(Paquette::PypiServer.new(@repository, authenticator: TestAuthenticator.new(readers: ["lic-token"])))

    refute pip_install("widgets"), "an anonymous install went through:\n#{@output}"
    refute pip_install("widgets", credentials: "__token__:wrong-token"), "a wrong token went through:\n#{@output}"
    assert pip_install("widgets", credentials: "__token__:lic-token"), "pip install failed:\n#{@output}"
    FileUtils.rm_rf(Dir.glob(File.join(@target_dir, "*")))
    assert pip_install("widgets", credentials: "lic-token"), "pip install with the token as the username failed:\n#{@output}"
  end

  # The round trip a publisher makes: build with `python -m build`, upload
  # with twine and the one-time password as the username, install with pip
  def test_twine_uploads_what_build_built_and_pip_installs_it
    secret = ROTP::Base32.random
    authenticator = TestAuthenticator.new(readers: ["lic-token"], writers: ["pub-token"], otp_secret: secret)
    serve(Paquette::PypiServer.new(@repository, authenticator: authenticator))
    dist = build_project("acme.widgets", "0.3.1")

    assert twine_upload(dist, username: ROTP::TOTP.new(secret).now, password: "pub-token"), "twine upload failed:\n#{@output}"
    assert_equal ["acme_widgets-0.3.1-py3-none-any.whl", "acme_widgets-0.3.1.tar.gz"],
      Dir.children(File.join(@packages_dir, "acme-widgets")).sort

    assert pip_install("acme.widgets==0.3.1", credentials: "__token__:lic-token"), "pip install failed:\n#{@output}"
    assert_equal "0.3.1", python_eval("import acme_widgets; print(acme_widgets.VERSION)")
  end

  def test_twine_without_a_one_time_password_is_refused
    authenticator = TestAuthenticator.new(writers: ["pub-token"], otp_secret: ROTP::Base32.random)
    serve(Paquette::PypiServer.new(@repository, authenticator: authenticator))
    dist = build_project("widgets", "1.0.0")

    refute twine_upload(dist, username: "__token__", password: "pub-token"), "an upload without a code went through:\n#{@output}"
    assert_includes @output, "one-time password"
    refute twine_upload(dist, username: "000000", password: "pub-token"), "an upload with a wrong code went through:\n#{@output}"
    assert_empty Dir.glob(File.join(@packages_dir, "**", "*.whl"))
  end

  # twine 7 refuses --skip-existing for anything but pypi.org, so the 409
  # is only seen as a failed upload
  def test_twine_cannot_upload_the_same_files_twice
    serve(Writable.pypi_server(@repository))
    dist = build_project("widgets", "1.0.0")

    assert twine_upload(dist, username: ANY_OTP, password: "any-token"), "twine upload failed:\n#{@output}"
    refute twine_upload(dist, username: ANY_OTP, password: "any-token"), "a second upload went through:\n#{@output}"
    assert_includes @output, "409"
  end

  private

  def serve(app)
    @port = find_free_port
    # A real Rack server: how the response reaches pip is part of the test
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
        return if Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/")).code.to_i < 500
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

  def index_url(credentials)
    "http://#{"#{credentials}@" if credentials}127.0.0.1:#{@port}/simple/"
  end

  # A requirement with a space in it is a requirement plus options, as in a
  # requirements file
  def pip_install(*requirements, credentials: nil)
    options, specs = requirements.partition { |requirement| requirement.start_with?("--") }
    if specs.any? { |spec| spec.include?(" ") }
      requirements_file = File.join(@work_dir, "requirements.txt")
      File.write(requirements_file, specs.join("\n") + "\n")
      specs = ["-r", requirements_file]
    end
    command = [venv_bin("python"), "-m", "pip", "install", "--target", @target_dir, "--index-url", index_url(credentials),
      "--no-build-isolation", "--retries", "0", "--timeout", "10", "--upgrade", *options, *specs]
    @output = IO.popen(python_env(@home_dir), command, err: [:child, :out], &:read)
    $?.success?
  end

  def python_eval(source)
    IO.popen(python_env(@home_dir).merge("PYTHONPATH" => @target_dir), [venv_bin("python"), "-c", source],
      err: [:child, :out], &:read).strip
  end

  # The project is written here and built by the real backend, so what
  # twine uploads is what a publisher's own machine would have produced
  def build_project(name, version)
    project_dir = File.join(@work_dir, "src-#{name}")
    module_name = name.gsub(/[-.]+/, "_").downcase
    FileUtils.mkdir_p(File.join(project_dir, module_name))
    File.write(File.join(project_dir, module_name, "__init__.py"), "VERSION = #{version.inspect}\n")
    File.write(File.join(project_dir, "pyproject.toml"), <<~TOML)
      [build-system]
      requires = ["setuptools"]
      build-backend = "setuptools.build_meta"

      [project]
      name = "#{name}"
      version = "#{version}"
      requires-python = ">=3.8"
    TOML

    out_dir = File.join(project_dir, "dist")
    output = IO.popen(python_env(@home_dir), [venv_bin("python"), "-m", "build", "--no-isolation", "--outdir", out_dir, project_dir],
      err: [:child, :out], &:read)
    assert $?.success?, "python -m build failed:\n#{output}"
    Dir.glob(File.join(out_dir, "*")).sort
  end

  def twine_upload(files, *options, username:, password:)
    command = [venv_bin("twine"), "upload", "--non-interactive", "--disable-progress-bar", "--verbose",
      "--repository-url", "http://127.0.0.1:#{@port}/legacy/", "-u", username, "-p", password, *options, *files]
    @output = IO.popen(python_env(@home_dir), command, err: [:child, :out], &:read)
    $?.success?
  end
end
