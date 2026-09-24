require "json"
require "fileutils"

# Abstract base class for NPM package repositories; mirrors GemRepository.
class Paquette::NpmServer::NpmRepository
  def initialize
    raise NotImplementedError, "NpmRepository is an abstract class"
  end

  def package_names
    raise NotImplementedError, "Subclasses must implement package_names"
  end

  def package_versions
    raise NotImplementedError, "Subclasses must implement package_versions"
  end

  def versions_for_package(package_name)
    raise NotImplementedError, "Subclasses must implement versions_for_package"
  end

  def package_file_path(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_file_path"
  end

  def package_exists?(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_exists?"
  end

  def package_info(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_info"
  end

  def package_dependencies(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_dependencies"
  end

  def package_metadata(package_name)
    raise NotImplementedError, "Subclasses must implement package_metadata"
  end

  def dist_tags(package_name)
    raise NotImplementedError, "Subclasses must implement dist_tags"
  end

  # ---------------------------------------------------------------------
  # The HTTP caching protocol, mirroring the gem side. Defaults instead of
  # raises, because a repository written before any of this existed has to
  # degrade to "no caching" rather than raise out of the middle of a
  # request. The rules live in Paquette::CacheValidation.
  # ---------------------------------------------------------------------

  # A short string that changes whenever anything this repository would
  # serve changes, including anything a wrapper would change about it, or
  # nil for "do not cache this".
  #
  # The npm side needs this more badly than the gem side does. A gem
  # Personalizer changes the bytes of a .gem and the checksum an index
  # publishes for it; an npm Personalizer changes the *packument itself*,
  # because dist.integrity is computed per licensee and the document
  # carries one per version. A packument cached under a
  # licensee-independent key and replayed to a second licensee hands them
  # integrity hashes that cannot match the tarball they then download, and
  # npm treats that as tampering and hard-fails the install.
  def cache_validator
    nil
  end

  # Whether two callers can get different answers out of this repository,
  # deciding whether an anonymous response may be `public`. True is the
  # safe default; see GemRepository#varies_by_caller?.
  def varies_by_caller?
    true
  end

  def add_package(binary_data, dist_tags: {})
    raise NotImplementedError, "Subclasses must implement add_package"
  end

  def yank_package(package_name, version)
    raise NotImplementedError, "Subclasses must implement yank_package"
  end

  # The registry-convention shape; lockfiles record it verbatim.
  def self.tarball_path(package_name, version)
    "/#{package_name}/-/#{File.basename(package_name)}-#{version}.tgz"
  end

  # Drops the scope: a scoped package lives in a directory named for it.
  def self.tarball_filename(package_name, version)
    "#{File.basename(package_name)}-#{version}.tgz"
  end

  def self.scoped?(package_name)
    package_name.to_s.start_with?("@")
  end

  # Tighter than npm's rules: nothing that could escape the packages directory.
  SEGMENT = /\A[a-z0-9][a-z0-9._-]*\z/
  def self.valid_package_name?(package_name)
    name = package_name.to_s
    return false if name.empty? || name.length > 214

    if scoped?(name)
      scope, _, rest = name[1..].partition("/")
      !rest.empty? && scope.match?(SEGMENT) && rest.match?(SEGMENT)
    else
      name.match?(SEGMENT)
    end
  end

  # The version is half of every tarball filename, so it is a path
  # component just as much as the name is — and it comes from the same
  # place, a package.json the uploader wrote. Without this, a version of
  # "0.0.0/../../../../etc/thing" writes the upload wherever it points.
  #
  # Tighter than semver, and deliberately so: semver's grammar exists to
  # decide what sorts before what, not to decide what is safe to put in a
  # path. Everything a real version needs is here — digits, dots, a "-"
  # prerelease tail, "+build" metadata — and "/", "\", "%", NUL and a
  # leading dot are not. \A..\z rather than ^..$ so a trailing newline
  # cannot ride along, and bounded because no version is 64 characters.
  VERSION = /\A[0-9][0-9A-Za-z.+-]{0,63}\z/
  def self.valid_version?(version)
    string = version.to_s
    # A percent-decoded path segment can be bytes that are not valid
    # UTF-8, and a regexp run over those raises ArgumentError rather than
    # failing to match. Refusing them here is what keeps a caller from
    # having to rescue around a predicate.
    return false unless string.valid_encoding?

    VERSION.match?(string)
  end

  # Not Gem::Version: it mangles prereleases and rejects "+build" metadata.
  def self.sort_versions(versions)
    versions.sort { |a, b| compare_versions(a, b) }
  end

  def self.max_version(versions)
    sort_versions(versions).last
  end

  def self.prerelease?(version)
    !split_version(version)[1].empty?
  end

  # Newest stable release, or plain installs would get prereleases.
  def self.max_release_version(versions)
    stable = versions.reject { |version| prerelease?(version) }
    max_version(stable.empty? ? versions : stable)
  end

  # Semver: a prerelease sorts *below* the same version without one.
  def self.compare_versions(a, b)
    release_a, pre_a = split_version(a)
    release_b, pre_b = split_version(b)

    by_release = release_a <=> release_b
    return by_release unless by_release.zero?

    return 0 if pre_a.empty? && pre_b.empty?
    return 1 if pre_a.empty?
    return -1 if pre_b.empty?

    compare_prerelease(pre_a, pre_b)
  end

  def self.split_version(version)
    core, _, prerelease = version.to_s.split("+").first.to_s.partition("-")
    release = core.split(".").map { |part| part.to_i }
    # Pad so "1.0" and "1.0.0" compare equal.
    release += [0] * [0, 3 - release.length].max
    [release, prerelease.empty? ? [] : prerelease.split(".")]
  end

  def self.compare_prerelease(a, b)
    a.zip(b).each do |left, right|
      # A longer chain wins on an equal prefix: 1.0.0-alpha < 1.0.0-alpha.1
      return 1 if right.nil?

      numeric_left = left.match?(/\A\d+\z/)
      numeric_right = right.match?(/\A\d+\z/)

      result = if numeric_left && numeric_right
        left.to_i <=> right.to_i
      elsif numeric_left
        -1 # numeric identifiers have lower precedence
      elsif numeric_right
        1
      else
        left <=> right
      end
      return result unless result.zero?
    end
    a.length <=> b.length
  end

  # Passed through whole: a curated subset breaks whichever field it forgot.
  def self.version_doc(package_json, package_name, version, dist)
    package_json.merge(
      "name" => package_name,
      "version" => version,
      "_id" => "#{package_name}@#{version}",
      "dist" => dist
    )
  end
end
