require_relative "../test_helper"

class NpmPersonalizerTest < Minitest::Test
  include Rack::Test::Methods

  LICENSED_SOURCE = <<~JS
    // paquette_license_info
    export function greet() {
      return "hello";
    }
  JS

  def setup
    @dir = Dir.mktmpdir("paquette_npm_personalizer_test")
    @repository = Paquette::NpmServer::DirectoryNpmRepository.new(@dir)

    write_npm_package(@dir, name: "widget", version: "1.0.0",
      files: {"index.js" => LICENSED_SOURCE}, dependencies: {"left-pad" => "^1.3.0"})
    write_npm_package(@dir, name: "@acme/gadget", version: "2.0.0",
      files: {"index.js" => LICENSED_SOURCE})
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def personalized(license_key: "LIC-123", **options)
    Paquette::NpmServer::Personalizer.new(
      @repository,
      license_key: license_key,
      magic_comment_replacements: {"// paquette_license_info" => "licensed to #{license_key}"},
      **options
    )
  end

  def test_the_license_key_lands_in_the_served_tarball
    path = personalized.package_file_path("widget", "1.0.0")

    assert_includes tarball_file(path, "package/index.js"), "licensed to LIC-123"
    refute_includes tarball_file(path, "package/index.js"), "paquette_license_info"
  end

  # Failing closed matters more here than anywhere: package.json still carries
  # the key, so a package served with the marker left in its code looks
  # personalized from the outside while the licensee's copy is untraceable.
  def test_a_package_whose_marker_could_not_be_applied_is_not_served
    write_npm_package(@dir, name: "minified", version: "1.0.0",
      files: {"index.js" => "function e(o,r){return o+r}// paquette_license_info\n"})

    assert_raises(Paquette::NpmRepacker::MarkerNotApplied) do
      personalized.package_file_path("minified", "1.0.0")
    end
  end

  # Refused where the stack is built, not on the first customer download.
  def test_a_multiline_replacement_is_refused_when_the_stack_is_built
    assert_raises(Paquette::NpmRepacker::MultilineReplacement) do
      Paquette::NpmServer::Personalizer.new(@repository,
        license_key: "LIC-123",
        magic_comment_replacements: {"// paquette_license_info" => "licensed to Acme\nand more"})
    end
  end

  # A package with no marker at all is ordinary, not a failure.
  def test_a_package_without_the_marker_is_served
    write_npm_package(@dir, name: "unmarked", version: "1.0.0",
      files: {"index.js" => "export const x = 1;\n"})

    path = personalized.package_file_path("unmarked", "1.0.0")
    assert_equal "export const x = 1;\n", tarball_file(path, "package/index.js")
  end

  def test_the_license_key_lands_in_package_json
    path = personalized.package_file_path("widget", "1.0.0")
    package_json = JSON.parse(tarball_file(path, "package/package.json"))

    assert_equal({"licenseKey" => "LIC-123"}, package_json["paquette"])
    assert_equal({"left-pad" => "^1.3.0"}, package_json["dependencies"])
    assert_equal "widget", package_json["name"]
  end

  def test_injected_files_are_carried_into_the_package
    repo = personalized(files: {"LICENSE.txt" => "Licensed to Acme Inc."})
    path = repo.package_file_path("widget", "1.0.0")

    assert_equal "Licensed to Acme Inc.", tarball_file(path, "package/LICENSE.txt")
  end

  def test_the_original_is_left_alone
    original = File.binread(@repository.package_file_path("widget", "1.0.0"))
    personalized.package_file_path("widget", "1.0.0")

    assert_equal original, File.binread(@repository.package_file_path("widget", "1.0.0"))
  end

  # The integrity npm is told to expect must describe the bytes it is handed.
  def test_published_integrity_describes_the_personalized_tarball
    repo = personalized
    metadata = repo.package_metadata("widget")
    dist = metadata["versions"]["1.0.0"]["dist"]

    served = repo.package_file_path("widget", "1.0.0")
    assert_equal Digest::SHA1.file(served).hexdigest, dist["shasum"]
    assert_equal "sha512-" + [Digest::SHA512.file(served).digest].pack("m0"), dist["integrity"]
  end

  def test_personalization_changes_the_hashes
    original_dist = @repository.dist_for("widget", "1.0.0")
    personalized_dist = personalized.dist_for("widget", "1.0.0")

    refute_equal original_dist["integrity"], personalized_dist["integrity"]
    assert_equal original_dist["tarball"], personalized_dist["tarball"]
  end

  def test_repacking_twice_produces_the_same_bytes
    first = personalized.package_file_path("widget", "1.0.0")
    digest = Digest::SHA256.file(first).hexdigest
    File.unlink(first)

    second = personalized.package_file_path("widget", "1.0.0")
    assert_equal digest, Digest::SHA256.file(second).hexdigest
  end

  # Two licensees must never share one personalized file.
  def test_two_licensees_get_different_files
    one = personalized(license_key: "LIC-111").package_file_path("widget", "1.0.0")
    two = personalized(license_key: "LIC-222").package_file_path("widget", "1.0.0")

    refute_equal one, two
    assert_includes tarball_file(one, "package/index.js"), "LIC-111"
    assert_includes tarball_file(two, "package/index.js"), "LIC-222"
  end

  def test_scoped_packages_are_personalized_too
    path = personalized.package_file_path("@acme/gadget", "2.0.0")

    assert_includes tarball_file(path, "package/index.js"), "licensed to LIC-123"
  end

  def test_metadata_still_describes_the_package_itself
    metadata = personalized.package_metadata("widget")

    assert_equal "widget", metadata["name"]
    assert_equal({"left-pad" => "^1.3.0"}, metadata["versions"]["1.0.0"]["dependencies"])
  end

  def test_stacked_on_a_gated_repository
    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository) { |name:, version: nil| name == "widget" }
    stack = Paquette::NpmServer::Personalizer.new(gated,
      license_key: "LIC-999",
      magic_comment_replacements: {"// paquette_license_info" => "licensed to LIC-999"})

    assert_nil stack.package_metadata("@acme/gadget")

    path = stack.package_file_path("widget", "1.0.0")
    assert_includes tarball_file(path, "package/index.js"), "LIC-999"
  end

  def test_served_bytes_match_published_integrity
    stack = personalized
    @app = Paquette::NpmServer.new(stack)

    get "/widget"
    dist = JSON.parse(last_response.body)["versions"]["1.0.0"]["dist"]

    get URI.parse(dist["tarball"]).path
    assert_equal 200, last_response.status
    assert_equal dist["shasum"], Digest::SHA1.hexdigest(last_response.body)
    assert_equal dist["integrity"], "sha512-" + [Digest::SHA512.digest(last_response.body)].pack("m0")
    assert_includes tarball_file_from_bytes(last_response.body, "package/index.js"), "LIC-123"
  end

  attr_reader :app

  private

  def tarball_file_from_bytes(bytes, name)
    Dir.mktmpdir("served") do |dir|
      path = File.join(dir, "served.tgz")
      File.binwrite(path, bytes)
      tarball_file(path, name)
    end
  end
end
