require "etc"
require "minitest/autorun"

# Explicit because minitest 6 stopped pulling it in behind autorun. The suite
# has always used Minitest::Mock; on 5.x it happened to be there already, so
# the missing require sat latent until the lockfile stopped pinning 5.25.
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
    include ExternalTooling
    include MalformedRequestHelpers
    include TimingHelpers
  end
end
