require "minitest/autorun"
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

module Minitest
  class Test
    include NpmTarballHelpers
    include ExternalTooling
  end
end
