require_relative "../test_helper"
require "rubygems/package"

# `/api/v1/versions` serves fields straight out of an uploaded gemspec, and
# `gem build` does not check the scheme of a homepage — it only warns. The
# endpoint is public and the README's whole premise is that some other
# application renders what it returns, so the filtering happens here rather
# than being left to every reader.
class HostileGemspecUrlsTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("paquette_hostile")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_hostile_homepage_schemes_are_dropped_from_versions
    [
      "javascript:alert(document.domain)",
      "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
      "//evil.test/takeover",
      "docs/index.html",
      "http:///no-host",
      ""
    ].each do |homepage|
      version = version_doc_for(homepage: homepage)
      assert_equal "", version["homepage"], "expected #{homepage.inspect} to be filtered out"
    end
  end

  # Packed as binary because that is the only way a gemspec can carry these
  # bytes: Psych refuses to dump a UTF-8 string that is not valid UTF-8, and
  # writes a binary one as base64, which reads back as ASCII-8BIT.
  def test_homepage_that_is_not_valid_utf8_is_dropped_rather_than_raising
    version = version_doc_for(homepage: "http://evil\xFF.test".b)
    assert_equal "", version["homepage"]
  end

  def test_ordinary_homepages_are_served_unchanged
    ["http://example.test/gem", "https://example.test/gem?ref=1#top"].each do |homepage|
      assert_equal homepage, version_doc_for(homepage: homepage)["homepage"]
    end
  end

  # Only the `*_uri` keys are filtered. Everything else in the hash passes
  # through, because an application can put whatever it likes in there
  # through GemRepacker's gemspec_extras.
  def test_uri_metadata_keys_are_filtered_and_the_rest_of_the_hash_is_kept
    metadata = {
      "homepage_uri" => "javascript:alert(1)",
      "source_code_uri" => "https://example.test/src",
      "bug_tracker_uri" => "//evil.test/issues",
      "changelog_uri" => "http://evil\xFF.test".b,
      "paquette_license_key" => "abc-123",
      "rubygems_mfa_required" => "true"
    }

    served = version_doc_for(homepage: "https://example.test", metadata: metadata)["metadata"]

    refute served.key?("homepage_uri")
    refute served.key?("bug_tracker_uri")
    refute served.key?("changelog_uri")
    assert_equal "https://example.test/src", served["source_code_uri"]
    assert_equal "abc-123", served["paquette_license_key"]
    assert_equal "true", served["rubygems_mfa_required"]
  end

  private

  # The one version document `/api/v1/versions` returns for a corpus holding
  # a single gem built with these fields.
  def version_doc_for(homepage:, metadata: {})
    gems_dir = File.join(@tmpdir, "gems-#{rand(0xffffffff).to_s(16)}")
    build_hostile_gem(gems_dir, homepage: homepage, metadata: metadata)

    repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)
    session = Rack::Test::Session.new(Rack::MockSession.new(Paquette::GemServer.new(repo)))
    session.get "/api/v1/versions"
    assert_equal 200, session.last_response.status

    versions = JSON.parse(session.last_response.body)
    assert_equal 1, versions.length
    versions.first
  end

  # Built with validation off: RubyGems refuses a metadata link with a
  # hostile scheme, and warns about a homepage with one. A gem does not have
  # to come out of `gem build` at all, so neither is a guarantee the server
  # can lean on.
  def build_hostile_gem(gems_dir, homepage:, metadata:)
    name = "hostile_fixture"
    source_dir = File.join(@tmpdir, "src-#{rand(0xffffffff).to_s(16)}")
    FileUtils.mkdir_p(File.join(source_dir, "lib"))
    File.write(File.join(source_dir, "lib", "#{name}.rb"), "module HostileFixture; end\n")

    spec = Gem::Specification.new do |s|
      s.name = name
      s.version = "1.0.0"
      s.summary = "Paquette test fixture"
      s.authors = ["Paquette"]
      s.files = ["lib/#{name}.rb"]
      s.license = "MIT"
    end
    # Assigned after the block so the writers cannot normalize what the block
    # form would run through validation later.
    spec.homepage = homepage
    spec.metadata = metadata

    built = nil
    capture_io { built = Dir.chdir(source_dir) { Gem::Package.build(spec, true) } }

    FileUtils.mkdir_p(File.join(gems_dir, name))
    FileUtils.mv(File.join(source_dir, built), File.join(gems_dir, name, built))
  end
end
