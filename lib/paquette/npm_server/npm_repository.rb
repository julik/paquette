require "json"
require "fileutils"

# Abstract base class for NPM package repositories; mirrors GemRepository.
class Paquette::NpmServer::NpmRepository
  def initialize
    raise NotImplementedError, "NpmRepository is an abstract class"
  end

  #: () -> Array[String]
  def package_names
    raise NotImplementedError, "Subclasses must implement package_names"
  end

  # Returns [name, version] pairs.
  #
  #: () -> Array[[String, String]]
  def package_versions
    raise NotImplementedError, "Subclasses must implement package_versions"
  end

  #: (String package_name) -> Array[String]
  def versions_for_package(package_name)
    raise NotImplementedError, "Subclasses must implement versions_for_package"
  end

  # Returns the path of the .tgz file.
  #
  #: (String package_name, String version) -> String?
  def package_file_path(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_file_path"
  end

  #: (String package_name, String version) -> bool
  def package_exists?(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_exists?"
  end

  # Returns the version's package.json document.
  #
  #: (String package_name, String version) -> Hash[String, untyped]?
  def package_info(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_info"
  end

  #: (String package_name, String version) -> Hash[String, String]
  def package_dependencies(package_name, version)
    raise NotImplementedError, "Subclasses must implement package_dependencies"
  end

  # Returns the packument.
  #
  #: (String package_name) -> Hash[String, untyped]?
  def package_metadata(package_name)
    raise NotImplementedError, "Subclasses must implement package_metadata"
  end

  # The packument's top-level fields that describe the package as one version
  # of it does - npm shows them on the package's page. A gate rebuilds them from
  # the newest version the caller may see, or a lapsed licensee reads the
  # README of a release they are not entitled to.
  SUMMARY_FIELDS = %w[description keywords license author maintainers repository bugs homepage readme].freeze #: Array[String]

  # Those fields, as `version` describes them.
  #
  #: (String package_name, String? version) -> Hash[String, untyped]
  def package_summary(package_name, version)
    info = (version && package_info(package_name, version)) || {}
    {
      "description" => info["description"],
      "keywords" => info["keywords"] || [],
      "license" => info["license"],
      "author" => info["author"],
      "maintainers" => info["maintainers"] || [],
      "repository" => info["repository"],
      "bugs" => info["bugs"],
      # Filtered, unlike its neighbours: this is the one field a reader
      # treats as "the link for this package". `repository` and `bugs` are
      # left alone on purpose — `git://` and `git+ssh://` are legitimate
      # there.
      "homepage" => Paquette::SafeUrl.http_url(info["homepage"])
    }.compact
  end

  #: (String package_name) -> Hash[String, String]
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
  # serve changes, or nil for "do not cache this". A packument replayed to
  # the wrong licensee carries integrity hashes that cannot match the
  # tarball they download — npm treats that as tampering.
  #
  #: () -> String?
  def cache_validator
    nil
  end

  # Whether two callers can get different answers out of this repository —
  # true is the safe default; see GemRepository#varies_by_caller?.
  #
  #: () -> bool
  def varies_by_caller?
    true
  end

  # - `binary_data`: the tarball bytes
  #
  # Returns the stored version's info.
  #
  #: (String binary_data, ?dist_tags: Hash[String, String]) -> Hash[String, untyped]
  def add_package(binary_data, dist_tags: {})
    raise NotImplementedError, "Subclasses must implement add_package"
  end

  #: (String package_name, String version) -> void
  def yank_package(package_name, version)
    raise NotImplementedError, "Subclasses must implement yank_package"
  end

  # The registry-convention shape; lockfiles record it verbatim.
  #
  #: (String package_name, String version) -> String
  def self.tarball_path(package_name, version)
    "/#{package_name}/-/#{File.basename(package_name)}-#{version}.tgz"
  end

  # Drops the scope: a scoped package lives in a directory named for it.
  #
  #: (String package_name, String version) -> String
  def self.tarball_filename(package_name, version)
    "#{File.basename(package_name)}-#{version}.tgz"
  end

  #: (String package_name) -> bool
  def self.scoped?(package_name)
    package_name.to_s.start_with?("@")
  end

  # Tighter than npm's rules: nothing that could escape the packages directory.
  SEGMENT = /\A[a-z0-9][a-z0-9._-]*\z/

  #: (String package_name) -> bool
  def self.valid_package_name?(package_name)
    name = package_name.to_s
    return false if name.empty? || name.length > 214

    if scoped?(name)
      unscoped = name[1..] #: String
      scope, _, rest = unscoped.partition("/")
      !rest.empty? && scope.match?(SEGMENT) && rest.match?(SEGMENT)
    else
      name.match?(SEGMENT)
    end
  end

  # The version is half of every tarball filename — a path component out
  # of a package.json the uploader wrote. Tighter than semver, which
  # decides what sorts before what, not what is safe in a path.
  VERSION = /\A[0-9][0-9A-Za-z.+-]{0,63}\z/

  #: (String version) -> bool
  def self.valid_version?(version)
    string = version.to_s
    # A percent-decoded path segment can be bytes that are not valid
    # UTF-8, and a regexp run over those raises rather than failing to
    # match.
    return false unless string.valid_encoding?

    VERSION.match?(string)
  end

  # Not Gem::Version: it mangles prereleases and rejects "+build" metadata.
  #
  #: (Array[String] versions) -> Array[String]
  def self.sort_versions(versions)
    versions.sort { |a, b| compare_versions(a, b) }
  end

  #: (Array[String] versions) -> String?
  def self.max_version(versions)
    sort_versions(versions).last
  end

  #: (String version) -> bool
  def self.prerelease?(version)
    !split_version(version)[1].empty?
  end

  # Newest stable release, or plain installs would get prereleases.
  #
  #: (Array[String] versions) -> String?
  def self.max_release_version(versions)
    stable = versions.reject { |version| prerelease?(version) }
    max_version(stable.empty? ? versions : stable)
  end

  # Semver: a prerelease sorts *below* the same version without one.
  #
  #: (String a, String b) -> Integer
  def self.compare_versions(a, b)
    release_a, pre_a = split_version(a)
    release_b, pre_b = split_version(b)

    by_release = release_a <=> release_b #: Integer
    return by_release unless by_release.zero?

    return 0 if pre_a.empty? && pre_b.empty?
    return 1 if pre_a.empty?
    return -1 if pre_b.empty?

    compare_prerelease(pre_a, pre_b)
  end

  # Returns release segments and
  # prerelease identifiers.
  #
  #: (String version) -> [Array[Integer], Array[String]]
  def self.split_version(version)
    core, _, prerelease = version.to_s.split("+").first.to_s.partition("-")
    release = core.split(".").map { |part| part.to_i }
    # Pad so "1.0" and "1.0.0" compare equal.
    release += [0] * [0, 3 - release.length].max
    [release, prerelease.empty? ? [] : prerelease.split(".")]
  end

  #: (Array[String] a, Array[String] b) -> Integer
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
  #
  #: (Hash[untyped, untyped] package_json, String package_name, String version, Hash[untyped, untyped] dist) -> Hash[untyped, untyped]
  def self.version_doc(package_json, package_name, version, dist)
    package_json.merge(
      "name" => package_name,
      "version" => version,
      "_id" => "#{package_name}@#{version}",
      "dist" => dist
    )
  end
end
