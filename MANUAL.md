# Paquette manual

Everything the [README](README.md) leaves out.

- [Concepts](#concepts)
- [Repository wrappers](#repository-wrappers)
  - [Entitlements](#entitlements)
  - [Package personalization](#package-personalization)
  - [Cooldown](#cooldown)
- [Wiring it all together](#wiring-it-all-together)
- [Authentication](#authentication)
- [Hostnames and mounting](#hostnames-and-mounting)
  - [Mounting under a path prefix (namespaces)](#mounting-under-a-path-prefix-namespaces)
- [After a publish](#after-a-publish)
- [Gems](#gems)
- [npm](#npm)
- [Python](#python)
- [HTTP caching](#http-caching)
- [The index page](#the-index-page)
- [Instrumentation](#instrumentation)
- [Running the tests](#running-the-tests)

## Concepts

Paquette is meant to be integrated into a larger Rails or Rack application, and otherwise bent to your will in various (slightly unhinged) ways. Just a few use cases it was designed for:

- Hosting your internal package registry (why get the jFrog and the kitchen sink?)
- Distributing your packages under specific authentication
- Distributing your packages with licensing

The key Paquette concepts are:

- The serving app object - this is what poses as a gem/npm/PyPI repo. It's a Rack app: `Paquette::GemServer`, `Paquette::NpmServer`, `Paquette::PypiServer`.
- The repository object - that's the frontend for your stored packages. The basic implementations just expose a directory: `DirectoryGemRepository`, `DirectoryNpmRepository`, `DirectoryPypiRepository`.
- The authenticator - one object per request, built from the token, that answers every question about the caller: may they read, may they publish, which packages they see, what gets written into their copies. See [Authentication](#authentication).
- The repository wrappers - that's how you can control fulfillment from Paquette.

A very basic example: in your Rails app, define a Paquette server with gems inside your app's `storage/`:

```ruby
# routes.rb

gem_dir = Rails.root.join("storage/gems")
gem_repo = Paquette::GemServer::DirectoryGemRepository.new(gem_dir)
gem_server = Paquette::GemServer.new(gem_repo)

# Every package server requires a separate hostname
constraints(->(req) { req.host.start_with?("gem.") }) do
  mount gem_server, at: "/"
end
```

Call your app with `gem.localhost:3000` (or whichever other port you use) and you should see the Paquette placeholder screen. You can then push gems into your Rails app using the `gem.localhost:3000` source URL. Setup for npm and PyPI is similar.

## Repository wrappers

You can make your package server do interesting things by wrapping your repository. Wrappers change what is read - who may write is the authenticator's business alone (see [Authentication](#authentication)), and a server without one already refuses every write.

Two of the wrappers decide by who is asking, and they ask the request's authenticator - `Paquette::Authenticator.current`, which the server sets while it serves a request. So a stack is built once and shared, and the authenticator is where the per-caller facts live.

Each of the three servers has its own `ReadGatedRepository` and `Personalizer`. The gem and PyPI servers also have a `CooldownRepository`.

### Entitlements

Which packages a caller sees is a question to their authenticator. Define `entitled?` on it and the server puts a `ReadGatedRepository` around its repository for that request:

```ruby
class AcmeAuthenticator < Paquette::Authenticator
  def license = @license ||= License.find_by(token: token)

  def read_permitted? = !license.nil?

  # Without a version: may this caller see the package at all? With one:
  # may they have that version? A lapsed license keeps its packages in the
  # index and loses the versions released after it lapsed.
  def entitled?(name:, version: nil)
    return false if license.nil?
    return license.package_names.include?(name) if version.nil?

    license.covers?(name, version)
  end
end
```

A package the authenticator says no to does not exist: not in the indexes, not as a download, not as a checksum. A listing asks once per package and once per version, so remember what the token resolved to on the instance - it lives for one request - rather than looking it up on every answer.

The gate's ETag is a digest of what the caller can see, within what the endpoint is about: one package for a compact-index `info/` file or a packument, everything for `versions`. It moves when and only when the visible set does, which is what makes [HTTP caching](#http-caching) safe behind it, and there is no key to keep honest. A caller who can see nothing gets no ETag.

### Package personalization

Paquette includes a _personalization_ wrapper which marks every package with the licensee's details. See it as a "soft-DRM" in the style of Pragmatic Programmers back in the day.

> [!IMPORTANT]
> Personalizing a package changes its checksum, and the checksum may become unique for every license. Often, this is exactly what you want. However, if you _change_ how you personalize a package for a specific user, their package manager may detect the changed checksum and assume the package has been tampered with. So - if you do personalize, either let your users know that package checksums will change when you alter the personalization flow, or never change how packages get personalized.
>
> Personalizing packages thus has security implications.

What is personal comes from the caller's authenticator, as a hash of single-line strings:

```ruby
class AcmeAuthenticator < Paquette::Authenticator
  # ...
  def personalization
    return if license.nil?

    {"licensee" => license.holder_name, "customer" => "Customer #{license.ref}"}
  end
end
```

How it is written into a package is the personalizer's business, and the same on all three registries:

```ruby
gem_repo = Paquette::GemServer::Personalizer.new(gem_repo,
  # Written into every personalized gem, markers filled in. Static: the
  # terms are the same for everyone, the licensee's name is not
  files: {"LICENSE.txt" => File.read("config/license_template.txt")},
  # Where the repacked packages are kept. Defaults to the system temp
  # directory, which an application with a cache directory should override
  cache_dir: Rails.root.join("tmp/cache/paquette").to_s)
gem_server = Paquette::GemServer.new(gem_repo, authenticator: AcmeAuthenticator)
```

Three things happen to a package that is personalized:

- **Marker lines are filled in.** A package author puts `paquette:licensee` on a line of its own, in their language's comment syntax - `# paquette:licensee` in Ruby or Python, `// paquette:licensee` in JavaScript - or bare in a text file such as a LICENSE. The line comes out with the value in place of the marker, indentation and comment leader kept: `# Acme BV`. One line in, one line out, so sourcemaps and traceback line numbers still point where they did. A marker that is not alone on its line - a minifier pulled it onto a code line - is refused rather than served with a hole in it. Any file in the package, not only source.
- **The values are stamped into the package's metadata**, machine-readably: `paquette.licensee` in the gemspec metadata, `"paquette": {"licensee": ...}` in package.json, `paquette.json` next to METADATA in a wheel.
- **`files:` are written in**, with their markers filled in the same way.

A package with no marker anywhere is served byte for byte, and that is remembered, so an open-source gem next to the licensed ones goes out untouched with no list to maintain. A caller whose authenticator gives no `personalization` - an anonymous reader, the publisher - gets vanilla bytes too.

All the packages passing through personalization are repackaged and cached under everything that went into them, so two callers never share a file and a renamed licensee gets a new one. The initial request for the package index may be slow if checksums and sizes have to be provided (that depends on the API endpoint and the registry used).

What each personalizer does differs a little by ecosystem - see [npm](#personalization-and-integrity-with-npm-packages) and [Python](#python).

### Cooldown

There is a _cooldown_ wrapper, which withholds versions that were published less than a given interval ago:

```ruby
cooldown_seconds = 7 * 24 * 60 * 60
gem_repo = Paquette::GemServer::CooldownRepository.new(gem_repo, interval: cooldown_seconds)
gem_server = Paquette::GemServer.new(gem_repo)
```

A version that is still cooling does not appear in `/names`, `/versions`, `/info/`, `/specs.4.8`, `/latest_specs.4.8` or `/prerelease_specs.4.8`, and it does not download - it 404s, as if the gem version were not present.

> [!IMPORTANT]
> By default the publication date is `spec.date`, the date recorded in the gemspec - which is **publisher-controlled and records the build time, not the moment the gem arrived on your server.** A gem built in March and pushed in June is already past a seven-day cooldown when it lands. `require_release_date: true` on the repository at least refuses the placeholder - see [After a publish](#after-a-publish).

The default is `spec.date` because it is a property of the immutable gem bytes. `published_at:` takes a block when you keep a better date.

The PyPI server has one too - see [Python](#python).

## Wiring it all together

The authenticator is the one thing you write. It is built once per request from the token, so whatever the token resolves to is looked up once and remembered on the instance for every question that follows:

```ruby
class AcmeAuthenticator < Paquette::Authenticator
  def license = @license ||= License.find_by(token: token)

  def read_permitted? = !license.nil?
  def write_permitted? = !!license&.publisher?
  def check_otp!(code) = Paquette::Totp.verify!(license.totp_secret, code)
  def entitled?(name:, version: nil) = license.publisher? || license.covers?(name, version)
  def identity = license.cache_key
  def personalization = {"licensee" => license.holder_name}
end

REPO = Paquette::GemServer::DirectoryGemRepository.new(Rails.root.join("packages", "gems").to_s)
GEM_SERVER = Paquette::GemServer.new(
  Paquette::GemServer::Personalizer.new(REPO, cache_dir: Rails.root.join("tmp/cache/paquette").to_s),
  authenticator: AcmeAuthenticator
)
```

The stack is built once. Per request, the server builds the authenticator, gates the repository on `entitled?`, and makes the authenticator current for the personalizer. `Paquette::AuthToken.from_env(env)` is how the server reads the token, in every dialect the clients speak, so you never do.

The npm and PyPI servers are assembled exactly the same way, out of the same kind of parts, and one authenticator class serves all three.

## Authentication

All three servers take an `authenticator:` - a subclass of `Paquette::Authenticator`, or anything that answers `call(token)` with an instance for one request. The server calls it once per request with the token the request carried, or `nil` when it carried none, and asks the instance:

```ruby
class AcmeAuthenticator < Paquette::Authenticator
  def license = @license ||= License.find_by(token: token)

  def read_permitted? = !license.nil? # a nil token resolves to no license, so anonymous callers are refused

  def write_permitted? = !!license&.publisher?

  def check_otp!(code) = Paquette::Totp.verify!(license.totp_secret, code)

  # Optional, for Paquette::ResponseCache - see Caching behind authentication
  def identity = license.cache_key
end

Paquette::GemServer.new(gem_repo, authenticator: AcmeAuthenticator)
Paquette::NpmServer.new(npm_repo, authenticator: AcmeAuthenticator)
Paquette::PypiServer.new(pypi_repo, authenticator: AcmeAuthenticator)
```

Three questions are always asked, and the base class answers them the way a server without an authenticator does: everyone reads, nobody writes, no code is good. Three more are asked only when the instance answers to them: `entitled?(name:, version: nil)` for [Entitlements](#entitlements), `personalization` for [Package personalization](#package-personalization), and `identity` for [Caching behind authentication](#caching-behind-authentication).

What each server does with it:

- **The token.** Clients do not send it the same way, and `Paquette::AuthToken.from_env(env)` reads all of them: `Authorization: Bearer TOKEN` from npm, the bare key `gem push` sends as the whole header, and Basic auth from Bundler - the token as the username with any password (`https://TOKEN:x-oauth-basic@gem.example.com`), or as the password behind an empty username or one of `x-oauth-basic`, `x-access-token`, `x-oauth-token`, `__token__` - the last being how pip and twine send one. The token is `nil` when the request sent no credentials, a blank `Authorization` header included. A header that carries no token at all - `Bearer` with nothing after it, a scheme Paquette does not speak - is a 401 without building an authenticator: a mangled header must not become an anonymous request.
- **Reads.** Every request asks `read_permitted?`, and a `false` is a 401. Return `true` for a `nil` token to let anonymous callers in. Which packages a caller sees is `entitled?`'s business, not this.
- **Writes.** Every write - `gem push`, `gem yank`, `npm publish`, `npm unpublish`, `npm dist-tag`, `twine upload` - also asks `write_permitted?`, which is a yes or no for the whole registry: a 403 for a token that may not, a 401 when there was no token. Then the write has to carry a one-time password. Without one the server asks for it in each client's own dialect, so `gem` and `npm` prompt the way they do against rubygems.org and npmjs.com, and `--otp` works on both. twine can send nothing but a username and a password, so on the PyPI server the code goes in the username: `twine upload -u 123456 -p TOKEN` - six to eight digits there, next to a password, is read as the code and the password as the token. With one, `check_otp!` gets it and raises `Paquette::OtpRejected` if it is no good. All of this happens before the handler runs, so a refused push is refused before its body is read.
- **One-time passwords.** `Paquette::Totp.verify!(secret, code, drift: 30, after: nil)` checks a code against a base32 TOTP secret, raises `Paquette::OtpRejected` for you, and returns the time step the code belongs to. Keep that and hand it back as `after:` next time, and a code that was already used is refused. Keeping it, and throttling wrong guesses, needs state Paquette has nowhere to put, so both stay with your `check_otp!`.
- **The outcome** lands in `env["paquette.authentication"]` for your own log line: `authorized`, `credentials_unreadable`, `read_refused`, `write_refused`, `otp_missing` or `otp_rejected`.
- **The instance** lands in `env["paquette.authenticator"]`, for an `on_publish:` hook that wants to know who published, or a log line that wants to say who was served. It is also `Paquette::Authenticator.current` while the server runs its handler, which is how the repository wrappers reach it, and `Paquette::Authenticator.with(authenticator) { ... }` makes one current anywhere else - a download link on a license page, say, that wants the same personalized file the registry serves.
- **`npm whoami`** answers `paquette` for any accepted token, and 401 without one.

Without an authenticator, a server lets everyone read and refuses every write. `Paquette::Authentication::Open` lets anyone read and write and takes any code as the one-time password - it is what the dev setup runs, and never what a server anyone else can reach should.

## Hostnames and mounting

The three registries live on separate hostnames. In Rails, give each server a constraint on the first label of the host and `mount` it at the root. A server is a Rack app, built once as in [Wiring it all together](#wiring-it-all-together):

```ruby
# config/routes.rb
Rails.application.routes.draw do
  constraints(->(req) { req.host.start_with?("gem.") }) do
    mount GEM_SERVER, at: "/"
  end

  constraints(->(req) { req.host.start_with?("npm.") }) do
    mount Paquette::NpmServer.new(npm_repo, authenticator: AcmeAuthenticator), at: "/"
  end

  constraints(->(req) { req.host.start_with?("pypi.") }) do
    mount Paquette::PypiServer.new(pypi_repo, authenticator: AcmeAuthenticator), at: "/"
  end

  # Your own routes go below. Rails matches top to bottom, so a `root` or a
  # catch-all declared above the mounts would answer `gem.example.com/` itself.
  root "pages#home"
end
```

Rails has a `subdomain:` constraint, but it is not the one to reach for here. It takes `config.action_dispatch.tld_length` labels (one by default) off the end of the host and calls the rest the subdomain, so `gem.example.com` has the subdomain `gem` while `gem.localhost` has none at all - `localhost` is the whole domain to Rails - and `gem.acme.co.uk` has `gem.acme`. The lambda looks at the first label and nothing else, so one routes file serves `gem.localhost:3000` in development and `gem.example.com` in production. A registry whose hostname does not start with the registry name gets a `host:` constraint instead:

```ruby
constraints host: "gems.acme.dev" do
  mount GEM_SERVER, at: "/"
end
```

In development Rails allows `.localhost`, `.test` and any IP address out of the box, so `gem.localhost:3000` answers straight away. If you set `config.hosts` in production, add each registry's hostname to it.

Mounting in `routes.rb` runs the server inside the Rails executor, so ActiveRecord connections and `Current` are managed the same as for a controller action. See [Hosting Paquette inside a Rails application](docs/hosting-paquette-inside-rails.md).

Outside Rails, in a bare `config.ru`, `Paquette::SubdomainRouter` does the same job by the first label of the host - this is what the dev server on `http://localhost:9292` runs:

```ruby
run Paquette::SubdomainRouter.new { |router|
  router.map "gem", to: Paquette::GemServer.new(gems_repo, authenticator: authenticator)
  router.map "npm", to: Paquette::NpmServer.new(npm_repo, authenticator: authenticator)
  router.map "pypi", to: Paquette::PypiServer.new(pypi_repo, authenticator: authenticator)
  router.fallback to: ->(*) { [404, {}, ["Need subdomain gem/npm/pypi"]] }
}
```

If your OS supports `.localhost` TLDs, `gem.whatever.localhost:9292` will respond.

### Mounting under a path prefix (namespaces)

All three servers can be mounted under a prefix, which is how [gem.coop spells a namespace](https://gem.coop/updates/6/). In Rails that is the `at:` of the mount:

```ruby
constraints(->(req) { req.host.start_with?("gem.") }) do
  mount Paquette::GemServer.new(acme_repo), at: "/@acme"
  mount Paquette::GemServer.new(beta_repo), at: "/@beta"
end
```

In Rack only a `map` and nothing else:

```ruby
Rack::Builder.new do
  map("/@acme") { run Paquette::GemServer.new(acme_repo) }
  map("/@beta") { run Paquette::GemServer.new(beta_repo) }
end
```

A namespace per repository is also a namespace per wrapper stack: each mount can have its own gating and personalization, since it is its own `GemServer` around its own repository.

## After a publish

All three servers take an `on_publish:` callable, called once a push, a publish or an upload has landed with a `Paquette::Published` (`name`, `version`, `released_at`) and the `Rack::Request` - to record the release, mail somebody, note the address it came from:

```ruby
Paquette::GemServer.new(repo, authenticator: authenticator, on_publish: ->(published, request) {
  Release.create!(name: published.name, version: published.version, released_at: published.released_at, from: request.ip)
})
```

`released_at` is the gemspec's date for a gem, and the moment of arrival for an npm package or a Python file - `npm pack` stamps every tarball entry with 1985-10-26, and a wheel carries no date of its own, so there is no better one. A Python project is named by its PEP 503 normalized name, as the gate sees it. An exception from the callable is a 500 for a package that is already stored, so rescue what is allowed to fail.

If anything downstream trusts a gem's date - a cooldown, a license window - make the date mean something: `DirectoryGemRepository.new(dir, require_release_date: true)` refuses a push dated with the RubyGems placeholder (1980-01-02, what a reproducible build stamps without `SOURCE_DATE_EPOCH`) or more than about three years from today, before anything is stored.

## Gems

### Publishing gems into Paquette

You can publish gems two ways.

1. Place `.gem` files in a per-gem directory under `gems/`, as `gems/gemname/gemname-version.gem`
2. Actually do a `gem push` - from your shell, do `gem push --host http://gem.localhost:9292 --otp 000000 pkg/your-gem-0.1.0.gem`

Note that the default dev setup runs `Paquette::Authentication::Open`, which takes any token and any one-time password - that is to say, _no_ auth. I told you it is slightly unhinged. See [Authentication](#authentication) for tokens and OTP.

### Consuming gems provided by a Paquette server

To install gems from Paquette, set it as source in your Gemfile - and provide auth for whichever auth mechanism you wrap it with:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.paquette.acme.com"
```

### Platform gems

A gem built for a platform is stored, downloaded and indexed under the filename RubyGems gives it - `nokogiri-1.16.0-java.gem` - so the same name and version can exist for `ruby`, `java` and `arm64-darwin` side by side, and each is downloaded and yanked on its own. `gem push` files each build under that same filename, so the three builds of one release are three artifacts rather than one pushed three times.

Where the platform ends up in a response depends on the format; Paquette follows RubyGems conventions.

### URL filtering in package metadata

Most of what the endpoints return comes straight out of the uploaded gemspec, so it is written by whoever pushed the gem. Two fields are filtered before they go out: `homepage`, and every `*_uri` key in `metadata`. Each is served only when it is an absolute `http`/`https` URL with a host, and replaced with `""` (or dropped, for a metadata key) when it is not — `gem build` only warns about a `javascript:` or `data:` homepage, so a crafted gem can carry one. The npm packument's top-level `homepage` is filtered the same way; its `repository` and `bugs` are not, because `git://` and `git+ssh://` are legitimate there, and neither are the per-version documents under `versions`, which pass `package.json` through whole.

Everything else — `authors`, `summary`, `description`, `info`, the non-URI keys of `metadata` — is passed through unchanged and is still uploader-controlled text. If you render any of it in a page of your own, escape it there.

### RubyGems API endpoints

- `GET /` - Repository info
- `GET /api/v1/dependencies` - Gem dependencies, as Marshal
- `GET /api/v1/dependencies.json` - the same thing as JSON
- `GET /api/v1/versions` - Available gem versions
- `GET /api/v1/names` - Available gem names
- `GET /api/v1/search.json` - Search gems
- `GET /specs.4.8`, `GET /specs.4.8.gz` - Legacy Marshal index of every released version
- `GET /latest_specs.4.8`, `GET /latest_specs.4.8.gz` - The newest release of each gem
- `GET /prerelease_specs.4.8`, `GET /prerelease_specs.4.8.gz` - Every prerelease version
- `GET /names`, `GET /versions`, `GET /info/{gemname}` - Compact index
- `GET /quick/Marshal.4.8/{gemname-version}.gemspec.rz` - Marshalled gemspec
- `GET /gems/{gemname-version.gem}` - Download gem file
- `POST /api/v1/gems` - Upload gem (basic implementation)

## npm

The npm server is built the same way as the gem server and out of the same kind of parts: one repository object, wrapped in as many layers as you want, handed to a Rack app, with the authenticator deciding who sees and gets what.

```ruby
repo = Paquette::NpmServer::DirectoryNpmRepository.new(Rails.root.join("packages", "npm").to_s)
repo = Paquette::NpmServer::Personalizer.new(repo,
  files: {"LICENSE.txt" => File.read("config/license_template.txt")},
  cache_dir: Rails.root.join("tmp/cache/paquette").to_s)

# AcmeAuthenticator as in Authentication: entitled? is asked with the scoped
# name whole - "@acme/widgets" - and personalization fills `// paquette:licensee`
Paquette::NpmServer.new(repo, authenticator: AcmeAuthenticator)
```

The layers mean the same things they do for gems, with a few quirks:

- A gated `latest` follows the newest version the caller is entitled to, not the newest version that exists. Otherwise `npm install pkg` would resolve to a version the very next request refuses to serve.
- `latest` never points at a prerelease while a stable release exists, which is what npm's own registry does.
- There is no `CooldownRepository` for npm.

### Where npm packages live on disk

One directory per package, with a scope as an ordinary directory above it:

```
packages/npm/lodash/lodash-4.17.21.tgz
packages/npm/@acme/widgets/widgets-1.0.0.tgz
```

The scope stays on the package name but is dropped from the filename, exactly as in the tarball URLs npm follows (`/@acme/widgets/-/widgets-1.0.0.tgz`).

### Personalization and integrity with npm packages

npm records a `dist.integrity` hash for every version and refuses to install a tarball whose bytes do not match. A registry that rebuilds a tarball to serve it therefore has to rebuild it to *the same bytes* it published a hash for. Thus the same restriction applies as for RubyGems packages.

A marker line is replaced by one line, so if your package contains sourcemaps the offsets of the sourcemap do not shift - and the sourcemap thus won't have to be rewritten. A marker a minifier has pulled onto the end of a code line is refused rather than left in.

The values land in `package.json` under `"paquette"`: `{"paquette": {"licensee": "Acme BV"}}`.

### Publishing npm packages into Paquette

1. Place `.tgz` files in the layout above. The filename should be `name-version.tgz`, scope excluded.
2. Actually do an `npm publish` - from your shell, do `npm publish --registry http://npm.localhost:9292 --otp 000000`.

`npm unpublish` works too. An unpublished version leaves a `.tgz.tomb` behind, which stops that exact version being republished with different contents later - the same trick the gem side uses for yanks.

### Consuming npm packages provided by a Paquette server

Point npm at it and provide auth for whichever mechanism you wrapped it with:

```
# .npmrc
@acme:registry=https://npm.paquette.acme.com
//npm.paquette.acme.com/:_authToken=tok_998218907784
```

### npm API endpoints

- `GET /` - Repository info
- `GET /-/ping` - Liveness
- `GET /-/whoami` - `paquette` for an accepted token, 401 without one
- `GET /{package}` - Package metadata document
- `GET /{package}/-/{name-version.tgz}` - Download tarball
- `GET /-/package/{package}/dist-tags` - Read dist-tags
- `PUT /-/package/{package}/dist-tags/{tag}` - Point a dist-tag at a version
- `PUT /{package}` - Publish
- `PUT /{package}/-rev/{rev}` - Document update (how `npm unpublish` removes versions)
- `DELETE /{package}/-rev/{rev}` - Unpublish a package
- `DELETE /{package}/-/{name-version.tgz}/-rev/{rev}` - Unpublish one version

## Python

The PyPI server is built like the other two: a repository, as many wrappers as you want, and a Rack app around them.

```ruby
repo = Paquette::PypiServer::DirectoryPypiRepository.new(Rails.root.join("packages", "pypi").to_s)
repo = Paquette::PypiServer::Personalizer.new(repo,
  files: {"acme_widgets/LICENSE.txt" => File.read("config/license_template.txt")}, # relative to site-packages
  cache_dir: Rails.root.join("tmp/cache/paquette").to_s)

# AcmeAuthenticator as in Authentication: entitled? is asked with the PEP 503
# normalized name - "acme-widgets" - and personalization fills `# paquette:licensee`
Paquette::PypiServer.new(repo, authenticator: AcmeAuthenticator)
```

`CooldownRepository` is there too, and means what it means for gems: an upload through it lands and stays out of view until it has cooled. As on the other two servers, the wrappers pass writes through - who may upload is the authenticator's to say. A few things are particular to Python:

- **Files, not versions.** A version is a set of files - a wheel per platform, an sdist - and the index lists files. The authenticator is still asked `entitled?` about `name:` and `version:`, the version read out of each filename, and a cooldown withholds each file on its own: a wheel added to an old release is held back like any new arrival. By default the cooldown reads the file's mtime, because a wheel carries no date of its own; `published_at:` takes a block called with `name:`, `version:` and `filename:` when you keep a better one.
- **Yanks.** `repo.yank_file(project, filename, reason: "")` is a PEP 592 yank: pip passes over the file unless a requirement pins that exact version, and the file stays downloadable for the lockfiles that already have it. There is no HTTP endpoint for it, since no client sends one.
- **Filenames are forever**, as on pypi.org. Uploading a filename that was ever uploaded before is a 409, yanked or not.
- **Personalization** fills marker lines - `# paquette:licensee` on a line of its own - indentation kept, one line in, one line out, so traceback line numbers match the source the publisher saw. The values land in `paquette.json`, which `importlib.metadata.distribution("acme-widgets").read_text("paquette.json")` reads from the installed package. `files:` paths are relative to the archive root - site-packages, for a wheel. A wheel gets its RECORD rewritten and loses any `RECORD.jws` signature. METADATA is never touched, so its PEP 658 hash stays the repository's. The same checksum warning as for gems applies: pip checks the sha256 the index published, and `--require-hashes` lockfiles will notice a change in how you personalize.

### Where Python packages live on disk

One directory per PEP 503 normalized project name, with the files under the names their build tools gave them:

```
packages/pypi/acme-widgets/acme_widgets-1.0.0-py3-none-any.whl
packages/pypi/acme-widgets/acme_widgets-1.0.0.tar.gz
packages/pypi/acme-widgets/acme_widgets-0.9.0.tar.gz.yanked   # the reason, possibly empty
```

### Publishing Python packages into Paquette

1. Place wheels and `.tar.gz` sdists in the layout above.
2. Upload with twine: `twine upload --repository-url http://pypi.localhost:9292/legacy/ -u 000000 -p TOKEN dist/*`. The username is the one-time password - see [Authentication](#authentication). `uv publish` and `poetry publish` speak the same protocol.

An upload is read before it is stored: the metadata inside has to name the project the filename does, and a `sha256_digest` twine sent has to match.

### Consuming Python packages provided by a Paquette server

```
pip install acme-widgets --index-url https://__token__:tok_998218907784@pypi.paquette.acme.com/simple/
```

or in `pip.conf`, `uv`'s `[[tool.uv.index]]` or Poetry's `[[tool.poetry.source]]` - all of them speak the same Simple API.

### PyPI API endpoints

- `GET /` - Repository info
- `GET /simple/` - Every project, as HTML or PEP 691 JSON by `Accept` (or `?format=`)
- `GET /simple/{project}/` - A project's files, with sha256, Requires-Python, yank status, size and upload time; any spelling of the name redirects to the normalized one
- `GET /files/{project}/{filename}` - Download a file
- `GET /files/{project}/{filename}.metadata` - A wheel's METADATA (PEP 658)
- `POST /legacy/` - Upload, as twine sends it

## HTTP caching

Paquette emits ETags for most endpoints, answers conditional requests, and supports partial responses - Bundler fetches the compact index incrementally with ranges.

Behind authentication, which is what Paquette is for, a shared cache such as `Rack::Cache` or a CDN stores nothing: every authorized response is `private`, as it has to be when it is gated and personalized for one licensee. Use `Paquette::ResponseCache` instead.

### Caching behind authentication

`Paquette::ResponseCache` stores whole 200s on disk, one entry per caller, and never answers on its own: every request still goes to the server, with `If-None-Match` set to the stored ETag. When the server answers that with a 304, the stored body goes out as the 200.

```ruby
use Paquette::ResponseCache, directory: "tmp/cache/gems"
run GEM_SERVER
```

Which entry is the caller's is the server's to say, after the fact. The cache leaves a lookup in the Rack env; once the request's authenticator has let the read in, the server asks that same instance for `identity` and hands the answer to the lookup, which gives back the ETag it holds for that identity. Return a license or user ID as a String or an Integer, not the token, and a rotated token finds the entries its predecessor left. Without an `identity` method, or with a `nil` or blank from it, nothing is cached. Anything else - a model object, say - raises `TypeError`, since it would stringify differently on every request and never hit.

So the identity always comes from the object that just authenticated the token, and never from the wire: an env key with a dot in it cannot be sent by a client, and no header names an identity in either direction. Anonymous and refused requests never get as far as being identified.

It pays off because the stack can name itself, so that Paquette answers the 304 _before_ rendering: the gate's validator is what the caller can see and the personalizer's is what gets written for them, both exact. The authenticator is still asked on every request, so a revoked token is refused with a body on disk for it, and a stack without a validator is simply never stored. The ETag, not the identity, is what keeps two callers apart: a stored body only goes out when the server says it is current for the caller asking, and it is filed under that ETag, so a concurrent request writing a new body for the same entry cannot swap it in. A refused request is never identified, so its entry stays on disk - harmless, since it is only ever replayed on a 304.

Entries are keyed by the URL - host and mount point included - the identity, and whether `Accept` asks for JSON (the PyPI index answers one URL in HTML or JSON). So one cache can sit in front of all three servers, whether they are told apart by hostname or by path prefix:

```ruby
use Paquette::ResponseCache, directory: "tmp/cache/paquette"
run Paquette::SubdomainRouter.new { |router|
  router.map "gem", to: GEM_SERVER
  router.map "npm", to: NPM_SERVER
  router.map "pypi", to: PYPI_SERVER
}
```

Two servers answering the same path with the same ETag still get an entry each. Ranges, `HEAD`, writes and file downloads go straight through, and so does any body over `max_body_bytes:` (8 MiB by default). So do anonymous requests and requests with a query string: an anonymous response is the same for everybody and a 304 away anyway, and a query string - like any raw header - is anybody's to vary, so storing either would let a stranger fill the disk. An identified caller can still spell one URL many ways - percent-escapes, `X-Forwarded-Host` - so each identity keeps at most `max_entries_per_identity:` entries (128 by default), the least recently written going first. The directory can be emptied at any time. Keep a compressor such as `Rack::Deflater` outside the cache, since the encoding is not in the key. `env["paquette.response_cache"]` says `hit`, `miss` or `bypass`, for your log line.

### Caching validators

Paquette allows the repo wrappers to alter the validator (the ETag). The validator itself is derived from the whole wrapper stack, not just from the corpus, and each wrapper contributes exactly what it changes: the gate the names and versions the caller can see within what the endpoint is about, the personalizer the values and files written for them, the cooldown how many versions have cooled.

A `nil` validator propagates outward, so a `Personalizer` wrapped around a repository that cannot name itself emits no `ETag` either, and neither does a gate in front of a caller who can see nothing.

## The index page

You can customize the user-visible index page of your package server by supplying a Rack app that will serve it, like so:

```ruby
# Serve our index page
Paquette::GemServer.new(repo, placeholder_app: Paquette::IndexPage.new("Gems for Stanquette staff. Ask Julik for a token."))

# ...or a redirect
Paquette::NpmServer.new(repo, placeholder_app: ->(_env) { [302, {"location" => "https://docs.example.com"}, []] })
Paquette::NpmServer.new(repo, placeholder_app: ->(_env) { [404, {}, []] })  # no root at all
```

## Instrumentation

Everything expensive in Paquette is wrapped in a [Measurometer](https://rubygems.org/gems/measurometer) block, so that you know how long things take. Measurometer does nothing until a driver is attached, so you may need to configure it:

```ruby
Measurometer.drivers << Appsignal
```

Metric paths that Paquette outputs are all prefixed with `paquette.` - the rest should be fairly self-explanatory.

For your own log line or monitoring transaction, each server says what a request turned out to be about in the env:

```ruby
env["paquette.served"] # => {route: "GET /gems/:gem_filename", package: "zip_kit", version: "6.2.1"}
```

The route is there whenever one matched, refused requests included, and makes a bounded action name. The package and version only when that package was actually served or written - a 2xx, or a 304 on a validator the client held - so a scanner probing made-up names cannot mint a tag value per probe. A push names the gem it wrote, which `gem push` sends only in the body, and an upload the Python project and version it wrote. `env["paquette.authentication"]`, `env["paquette.authenticator"]` - the caller's authenticator, with whatever the token resolved to still on it - and `env["paquette.response_cache"]` sit beside it.

## Running the tests

```bash
bundle exec rake test
```

Most of it is ordinary Ruby, but we also have a few end-to-end tests that require Docker, Node and Python 3. The Python ones build a venv with twine, build and setuptools in `tmp/test-python-venv` on first run, which needs the network once. You need none of these for using Paquette though.

RubyGems' own compact-index conformance suite runs separately, because it shells out to the `gem_server_conformance` RSpec binary:

```bash
bundle exec rake test:conformance
```

It boots a gem server over a bare `DirectoryGemRepository` and drives the suite against it over HTTP. `test/conformance/rspec_exclusions.rb` lists the examples Paquette knowingly does not pass and why — read it before concluding that a green run means full conformance. Without the `gem_server_conformance` gem installed the test skips; set `PAQUETTE_REQUIRE_CONFORMANCE=1` to turn that skip into a failure, which is what CI wants.
