require "etc"
require "minitest/autorun"

# Minitest::Mock and Object#stub both live here, and minitest 6 moved the file
# out into the minitest-mock gem. On 5.x autorun pulled it in for free, so the
# suite used both without ever requiring it — latent until the lockfile stopped
# pinning 5.25. See the Gemfile for why the dependency is spelled out.
require "minitest/mock"

# One forked process per test class, rather than minitest's threads: the suite
# binds ports, shells out, sets ENV and leans on process-global state like
# Regexp.timeout, none of which survives sharing a process. NCPU is the gem's
# own knob — it defaults to 4, which is usually fewer than this machine has.
ENV["NCPU"] ||= Etc.nprocessors.to_s
require "minitest/parallel_fork"

# Minitest.autorun turns deprecation warnings back on, and on 3.4 that means
# every chilled-string warning out of rack and rubygems lands between the
# dots. Ours would be worth reading; theirs are not ours to fix. `rake test`
# already drops -w, so this is the other half of the same switch.
Warning[:deprecated] = false
require "rack/test"
require "rack"
require "fileutils"
require "json"
require "stringio"
require "net/http"
require "tempfile"
require "tmpdir"
require "rubygems/package"
require_relative "../lib/paquette"

FIXTURE_GEMS_DIR = File.expand_path("fixtures/gems", __dir__)
FIXTURE_NPM_DIR = File.expand_path("fixtures/npm", __dir__)

# In CI a skip looks like a pass; the env var turns a missing tool into a failure.
module ExternalTooling
  def require_tool(name, available, env_var)
    return if available

    if ENV[env_var].to_s.empty?
      skip "#{name} is not available"
    else
      flunk "#{name} is not available, and #{env_var} says this run must have it"
    end
  end
end

# Builds .gem files whose specs say things `gem build` would never let
# them say. A gemspec is YAML the uploader wrote, so every one of these is
# a payload a real client can produce — RubyGems' own validation runs on
# the *pushing* side, which is exactly why a server cannot rely on it.
#
# Two escapes are needed. Gem::Package.build takes a skip_validation flag,
# which gets a nonsense name or licence past the builder; and fields that
# RubyGems parses into an object on assignment (versions, requirements)
# are built well-formed and then have their backing string replaced, which
# is what the YAML actually carries and what the server reads back.
module HostileGemHelpers
  # A Gem::Version whose string is whatever you want, including one that
  # Gem::Version.new would have refused outright.
  def forged_version(string)
    version = Gem::Version.new("1.0.0")
    version.instance_variable_set(:@version, string)
    version
  end

  # Likewise for a requirement: Gem::Requirement#to_s renders "#{op}
  # #{version}", so a forged version inside one is how a newline reaches
  # the "ruby:" field of a compact index line.
  def forged_requirement(operator, version_string)
    requirement = Gem::Requirement.new(">= 0")
    requirement.instance_variable_set(:@requirements, [[operator, forged_version(version_string)]])
    requirement
  end

  # The bytes of a .gem carrying `spec`. The filename is passed explicitly
  # rather than left to default to spec.file_name, because a spec named
  # "../../pwned" has a file_name that escapes the build directory — the
  # test would land the payload outside tmp before the code under test
  # ever saw it.
  def gem_bytes_for(spec)
    Dir.mktmpdir("paquette_hostile_gem") do |dir|
      built = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
        Dir.chdir(dir) do
          Gem::Package.build(spec, true, false, "hostile.gem")
          File.join(dir, "hostile.gem")
        end
      end
      File.binread(built)
    end
  end

  # A gemspec YAML document that uses an alias. Harmless in itself — the
  # point is that it round-trips at all, because the shape that is not
  # harmless (`&a [*b, *b, *b, …]`, repeated) is the same feature.
  ALIASED_GEMSPEC_YAML = <<~YAML
    --- !ruby/object:Gem::Specification
    name: &shared aliased
    version: !ruby/object:Gem::Version
      version: 1.0.0
    summary: *shared
    authors:
      - a
    require_paths:
      - lib
    rubygems_version: 3.0.0
    specification_version: 4
  YAML

  # The same .gem with its metadata.gz replaced. A .gem is an uncompressed
  # tar of metadata.gz, data.tar.gz and checksums.yaml.gz, so this goes
  # through RubyGems' own tar reader and writer rather than through
  # Paquette::Tarball, which is for the gzipped tarballs npm ships.
  # checksums.yaml.gz is rebuilt rather than dropped, so the only thing
  # wrong with the result is the thing under test — a gem that merely
  # fails its own checksum would be refused for a reason that proves
  # nothing about the YAML parse.
  def gem_bytes_with_metadata(original_bytes, metadata_yaml)
    parts = {}
    Gem::Package::TarReader.new(StringIO.new(original_bytes)) do |tar|
      tar.each { |entry| parts[entry.full_name] = entry.read }
    end
    parts["metadata.gz"] = Zlib.gzip(metadata_yaml)

    if parts.key?("checksums.yaml.gz")
      digested = parts.except("checksums.yaml.gz")
      checksums = {
        "SHA1" => digested.transform_values { |c| Digest::SHA1.hexdigest(c) },
        "SHA512" => digested.transform_values { |c| Digest::SHA512.hexdigest(c) }
      }
      parts["checksums.yaml.gz"] = Zlib.gzip(Psych.dump(checksums))
    end

    io = StringIO.new(+"".b)
    Gem::Package::TarWriter.new(io) do |tar|
      parts.each do |name, content|
        tar.add_file_simple(name, 0o444, content.bytesize) { |f| f.write(content) }
      end
    end
    io.string
  end

  # Gem::Package#verify announces a failed verification with Kernel#warn,
  # which no Gem::SilentUI can intercept. A test that deliberately feeds
  # it an unreadable gem would otherwise print that line between the dots.
  def without_rubygems_chatter
    original = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = original
  end

  # A minimal but otherwise plausible spec, ready to be sabotaged by the
  # block before it is packed.
  def hostile_gem_bytes(name: "hostile", version: "1.0.0")
    spec = Gem::Specification.new
    spec.name = name
    spec.version = version.is_a?(Gem::Version) ? version : forged_version(version.to_s)
    spec.summary = "A gem built to say things it should not"
    spec.authors = ["Test"]
    spec.files = []
    yield spec if block_given?
    gem_bytes_for(spec)
  end
end

module NpmTarballHelpers
  # The mtime npm itself stamps on every file it packs (1985-10-26).
  NPM_EPOCH = 499162500

  # The server reads package.json out of the tarball, so arbitrary bytes
  # named .tgz cannot stand in for a package.
  def npm_tarball_bytes(name:, version:, files: {}, **package_json)
    contents = {
      "package.json" => JSON.pretty_generate({
        "name" => name,
        "version" => version,
        "description" => "The #{name} package",
        "main" => "index.js",
        "license" => "MIT"
      }.merge(package_json.transform_keys(&:to_s))),
      "index.js" => "module.exports = #{version.inspect};\n",
      "README.md" => "# #{name}\n"
    }.merge(files)

    entries = contents.map do |path, content|
      Paquette::Tarball::Entry.new(
        name: "package/#{path}",
        mode: 0o644,
        mtime: NPM_EPOCH,
        content: content
      )
    end

    Dir.mktmpdir("npm_fixture") do |dir|
      path = Paquette::Tarball.write(File.join(dir, "fixture.tgz"), entries)
      File.binread(path)
    end
  end

  def write_npm_package(packages_dir, name:, version:, files: {}, **package_json)
    package_dir = File.join(packages_dir, *name.split("/"))
    FileUtils.mkdir_p(package_dir)

    path = File.join(package_dir, "#{File.basename(name)}-#{version}.tgz")
    File.binwrite(path, npm_tarball_bytes(name: name, version: version, files: files, **package_json))
    path
  end

  def npm_publish_body(name:, version:, dist_tags: {"latest" => nil}, **package_json)
    tarball = npm_tarball_bytes(name: name, version: version, **package_json)
    tags = dist_tags.transform_values { |tagged| tagged || version }

    JSON.generate({
      "_id" => name,
      "name" => name,
      "dist-tags" => tags,
      "versions" => {version => {"name" => name, "version" => version}},
      "_attachments" => {
        "#{File.basename(name)}-#{version}.tgz" => {
          "content_type" => "application/octet-stream",
          "data" => [tarball].pack("m0"),
          "length" => tarball.bytesize
        }
      }
    })
  end

  def tarball_entry_names(path)
    Paquette::Tarball.entries(path).map(&:name).sort
  end

  def tarball_file(path, name)
    Paquette::Tarball.entries(path).find { |entry| entry.name == name }&.content
  end
end

# Rack::Test cannot build a body that disagrees with its own Content-Length,
# which is exactly the shape of request these tests are about.
module MalformedRequestHelpers
  def malformed_multipart_env(path, body: nil, content_length: nil)
    env = Rack::MockRequest.env_for(path, "CONTENT_TYPE" => "multipart/form-data; boundary=AaB03x")
    env["rack.input"] = StringIO.new(body.to_s)
    if content_length
      env["CONTENT_LENGTH"] = content_length
    else
      env.delete("CONTENT_LENGTH")
    end
    env
  end
end

module TimingHelpers
  # Minitest::Test already has #time, hence the name.
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end

module Minitest
  class Test
    include NpmTarballHelpers
    include HostileGemHelpers
    include ExternalTooling
    include MalformedRequestHelpers
    include TimingHelpers
  end
end
