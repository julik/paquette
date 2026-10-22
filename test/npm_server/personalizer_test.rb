require_relative "../test_helper"

class NpmPersonalizerTest < Minitest::Test
  include Rack::Test::Methods

  LICENSED_SOURCE = <<~JS
    // paquette:licensee
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

  def personalized(**options)
    Paquette::NpmServer::Personalizer.new(@repository, **options)
  end

  # The repository as one caller sees it: the personalizer is built once and
  # asks the current authenticator who that is.
  def as(licensee = "LIC-123", &block)
    Paquette::Authenticator.with(PersonalizingAuthenticator.new(nil, {"licensee" => "licensed to #{licensee}"}), &block)
  end

  def test_the_value_lands_in_the_served_tarball
    path = as { personalized.package_file_path("widget", "1.0.0") }

    assert_includes tarball_file(path, "package/index.js"), "// licensed to LIC-123"
    refute_includes tarball_file(path, "package/index.js"), "paquette:licensee"
  end

  # Failing closed matters more here than anywhere: package.json still carries
  # the stamp, so a package served with the marker left in its code looks
  # personalized from the outside while the licensee's copy is untraceable.
  def test_a_package_whose_marker_could_not_be_applied_is_not_served
    write_npm_package(@dir, name: "minified", version: "1.0.0",
      files: {"index.js" => "function e(o,r){return o+r}// paquette:licensee\n"})

    assert_raises(Paquette::Markers::NotApplied) do
      as { personalized.package_file_path("minified", "1.0.0") }
    end
  end

  # Refused before the tarball is opened: a value is one line or it is not a value.
  def test_a_multiline_value_is_refused
    authenticator = PersonalizingAuthenticator.new(nil, {"licensee" => "licensed to Acme\nand more"})

    assert_raises(Paquette::Markers::MultilineValue) do
      Paquette::Authenticator.with(authenticator) { personalized.package_file_path("widget", "1.0.0") }
    end
  end

  # A package with no marker at all is ordinary: it goes out as it sits on disk.
  def test_a_package_without_a_marker_is_served_byte_for_byte
    write_npm_package(@dir, name: "unmarked", version: "1.0.0",
      files: {"index.js" => "export const x = 1;\n"})

    path = as { personalized.package_file_path("unmarked", "1.0.0") }
    assert_equal @repository.package_file_path("unmarked", "1.0.0"), path
    assert_nil JSON.parse(tarball_file(path, "package/package.json"))["paquette"]
  end

  # Nobody to personalize for, nothing personalized - and no cache touched.
  def test_a_caller_without_personalization_gets_the_original
    cache_dir = Dir.mktmpdir("paquette_npm_personalizer_cache")
    repo = personalized(cache_dir: cache_dir)

    assert_equal @repository.package_file_path("widget", "1.0.0"), repo.package_file_path("widget", "1.0.0")
    Paquette::Authenticator.with(Paquette::Authenticator.new(nil)) do
      assert_equal @repository.package_file_path("widget", "1.0.0"), repo.package_file_path("widget", "1.0.0")
    end
    assert_equal @repository.dist_for("widget", "1.0.0"), repo.dist_for("widget", "1.0.0")
    assert_empty Dir.children(cache_dir)
  ensure
    FileUtils.rm_rf(cache_dir)
  end

  def test_the_values_land_in_package_json
    path = as { personalized.package_file_path("widget", "1.0.0") }
    package_json = JSON.parse(tarball_file(path, "package/package.json"))

    assert_equal({"licensee" => "licensed to LIC-123"}, package_json["paquette"])
    assert_equal({"left-pad" => "^1.3.0"}, package_json["dependencies"])
    assert_equal "widget", package_json["name"]
  end

  def test_injected_files_are_carried_into_the_package_with_their_markers_filled
    repo = personalized(files: {"LICENSE.txt" => "This copy is\n  paquette:licensee\n"})
    path = as { repo.package_file_path("widget", "1.0.0") }

    assert_equal "This copy is\n  licensed to LIC-123\n", tarball_file(path, "package/LICENSE.txt")
  end

  def test_the_original_is_left_alone
    original = File.binread(@repository.package_file_path("widget", "1.0.0"))
    as { personalized.package_file_path("widget", "1.0.0") }

    assert_equal original, File.binread(@repository.package_file_path("widget", "1.0.0"))
  end

  # The integrity npm is told to expect must describe the bytes it is handed.
  def test_published_integrity_describes_the_personalized_tarball
    repo = personalized
    as do
      metadata = repo.package_metadata("widget")
      dist = metadata["versions"]["1.0.0"]["dist"]

      served = repo.package_file_path("widget", "1.0.0")
      assert_equal Digest::SHA1.file(served).hexdigest, dist["shasum"]
      assert_equal "sha512-" + [Digest::SHA512.file(served).digest].pack("m0"), dist["integrity"]
    end
  end

  def test_personalization_changes_the_hashes
    original_dist = @repository.dist_for("widget", "1.0.0")
    personalized_dist = as { personalized.dist_for("widget", "1.0.0") }

    refute_equal original_dist["integrity"], personalized_dist["integrity"]
    assert_equal original_dist["tarball"], personalized_dist["tarball"]
  end

  def test_repacking_twice_produces_the_same_bytes
    first = as { personalized.package_file_path("widget", "1.0.0") }
    digest = Digest::SHA256.file(first).hexdigest
    File.unlink(first)

    second = as { personalized.package_file_path("widget", "1.0.0") }
    assert_equal digest, Digest::SHA256.file(second).hexdigest
  end

  # Two licensees must never share one personalized file.
  def test_two_licensees_get_different_files
    repo = personalized
    one = as("LIC-111") { repo.package_file_path("widget", "1.0.0") }
    two = as("LIC-222") { repo.package_file_path("widget", "1.0.0") }

    refute_equal one, two
    assert_includes tarball_file(one, "package/index.js"), "LIC-111"
    assert_includes tarball_file(two, "package/index.js"), "LIC-222"
  end

  def test_scoped_packages_are_personalized_too
    path = as { personalized.package_file_path("@acme/gadget", "2.0.0") }

    assert_includes tarball_file(path, "package/index.js"), "licensed to LIC-123"
  end

  def test_metadata_still_describes_the_package_itself
    metadata = as { personalized.package_metadata("widget") }

    assert_equal "widget", metadata["name"]
    assert_equal({"left-pad" => "^1.3.0"}, metadata["versions"]["1.0.0"]["dependencies"])
  end

  def test_stacked_on_a_gated_repository
    gated = Paquette::NpmServer::ReadGatedRepository.new(@repository, EntitlingAuthenticator.new { |name:, version: nil| name == "widget" })
    stack = Paquette::NpmServer::Personalizer.new(gated)

    as("LIC-999") do
      assert_nil stack.package_metadata("@acme/gadget")

      path = stack.package_file_path("widget", "1.0.0")
      assert_includes tarball_file(path, "package/index.js"), "LIC-999"
    end
  end

  # End to end: the server resolves the caller, the personalizer picks them up.
  def test_served_bytes_match_published_integrity
    @app = Paquette::NpmServer.new(personalized,
      authenticator: PersonalizingAuthenticator.with({"licensee" => "licensed to LIC-123"}))

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
