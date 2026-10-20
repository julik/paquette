<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/paquette-wordmark-logo-on-dark.png">
  <img src="img/paquette-wordmark-logo.png" alt="Paquette" width="420">
</picture>

Paquette is a (slightly unhinged) Rack-based server for libraries. At the moment it serves gems, NPM packages and Python packages. It is designed to be small and embeddable in other Ruby web applications. You allocate a directory with packages and expose it through Paquette, all the while bringing your own authentication, limits, filtering and entitlements.

In essence, it is a gem/NPM/PyPI server for distributing commercial packages. I use
it for https://shop.stanquette.nl and it is pretty neat!

Things are somewhat in flux but Paquette is usable alright.

## Basic setup

This is a Ruby library so you will need Ruby installed. To try a minimal setup, do a `bundle install` and start `bin/dev`. Try pushing a gem into Paquette and then adding the local server to your `Gemfile` - and then do a `bundle install` in your application for that custom gem.

However, that is not how Paquette is primarily meant to be used. It is meant to be integrated into a larger Rails or Rack application, and otherwise bent to your will in various (slightly unhinged) ways. Just a few use cases Paquette was designed for:

- Hosting your internal package registry (why get the jFrog and the kitchen sink?)
- Distributing your packages under specific authentication
- Distributing your packages with licensing

The key Paquette concepts are:

- The serving app object - this is what poses as a gem/NPM repo. It's a Rack app.
- The repository object - that's the frontend for your stored packages. The basic implementation just exposes a dir.
- The repository wrappers - that's how you can control fulfillment from Paquette.

A very basic example: in your Rails app, define a Paquette server with gems inside your app's `storage/`:

```ruby
# routes.rb

gem_dir = Rails.root.join("storage/gems")
gem_repo = Paquette::GemServer::DirectoryGemRepository.new(gem_dir)
gem_server = Paquette::GemServer.new(gem_repo)

# Both package servers require a separate hostname
constraints(->(req) { req.host.start_with?("gem.") }) do
  mount gem_server, at: "/"
end
```

Call your app with `gem.localhost:3000` (or whichever other port you use) and you should see the Paquette placeholder screen. You can then push gems into your Rails app using the `gem.localhost:3000` source URL. Setup for NPM is similar.

The `Paquette::GemServer::DirectoryGemRepository` is a repository. The `Paquette::GemServer` is the Rack app that serves a repository.

## Repository wrappers

You can make your package server do interesting things by wrapping your `repo`. Wrappers change what is read - who may write is the authenticator's business alone (see [Authentication](#authentication)), and a server without one already refuses every write.

For example, you can create your own entitlement checks. This allows you to customize which gems get offered to a specific user:

```ruby
# ...the rest as above
gem_repo = Paquette::GemServer::ReadGatedRepository.new(gem_repo, gate_key: Current.license.cache_key) do |name:, version: nil|
  lic = Current.license
  lic.package_names.include?(name)
end
gem_server = Paquette::GemServer.new(gem_repo)
```

Now the holder of the `license` stored in your `ActiveSupport::Current` for the request will only receive the gems included in their license's `package_names` list. And you can limit version access as well. This affects serving the actual packages, serving the indexes and anything else.

The `gate_key:` (the npm `ReadGatedRepository` takes one too) is optional and is only used for HTTP caching. Broadly speaking, it is the user or license ID which alters the ETag of the response. If you pass none the response won't be cacheable - see [HTTP caching](#http-caching).

### Package personalization

Paquette includes a _personalization_ wrapper which allows every package to be marked with license details of the downlaoder. See it as a "soft-DRM" in the style of Pragmatic Programmers back in the day.

> [!IMPORTANT]
> Personalizing a package changes its checksum, and the checksum may become unique for every license. Often, this is exactly what you want. However, if you _change_ how you personalize a package for a specific user, their package manager may detect the changed checksum and assume the package has been tampered with. So - if you do personalize, either let your users know that package checksums will change when you alter the personalization flow, or never change how packages get personalized.
>
> Personalizing packages thus has security implications.

```ruby
# ...the rest as above
gem_repo = Paquette::GemServer::Personalizer.new(
    gem_repo,

    # Gets injected into the gemspec metadata as "paquette.license_key"
    license_key: Current.license.serial,

    # The cache's name for "who this gem is baked for" - anything the
    # personalized contents depend on has to be part of it, or a cached
    # artifact will be reused after the personalization has changed
    personalization_key: Current.license.holder_name,

    # Apply blanket edits to a specific magic comment in all Ruby files
    magic_comment_replacements: {"# license: " => Current.license.serial},

    # Inject files when repackaging the gem, hash of paths to contents
    files: {"THANK-YOU.txt" => "Thank you for using this library!"}
)
gem_server = Paquette::GemServer.new(gem_repo)
```

All the packages passing through personalization will be repackaged for this specific `personalization_key` and cached. The initial request for the package index may be slow if checksums and sizes have to be provided (that depends on the API endpoint and the registry used).

### Cooldown

There is a _cooldown_ wrapper, which withholds versions that were published less than a given interval ago:

```ruby
# ...the rest as above
cooldown_seconds = 7 * 24 * 60 * 60
gem_repo = Paquette::GemServer::CooldownRepository.new(gem_repo, interval: cooldown_seconds)
gem_server = Paquette::GemServer.new(gem_repo)
```

A version that is still cooling does not appear in `/names`, `/versions`, `/info/`, `/specs.4.8`, `/latest_specs.4.8` or `/prerelease_specs.4.8`, and it does not download - it 404s, as if the gem version were not present.

> [!IMPORTANT]
> By default the publication date is `spec.date`, the date recorded in the gemspec - which is **publisher-controlled and records the build time, not the moment the gem arrived on your server.** A gem built in March and pushed in June is already past a seven-day cooldown when it lands. `require_release_date: true` on the repository at least refuses the placeholder - see [After a push](#after-a-push).

The default is `spec.date` because it is a property of the immutable gem bytes.

## Wiring it all together

Since Paquette is very modular and is supposed to be assembled per use case, you will likely want to build the repository stack per caller - gated and personalized for the licensee the token belongs to:

```ruby
REPO = Paquette::GemServer::DirectoryGemRepository.new(Rails.root.join("packages", "gems").to_s)
AUTHENTICATOR = AcmeAuthenticator.new # see Authentication below

gem_app = ->(env) {
  token = Paquette::AuthToken.from_env(env)
  # A ReadGatedRepository refuses every write, so a publisher gets the bare one
  if AUTHENTICATOR.write_permitted?(auth_token: token)
    next Paquette::GemServer.new(REPO, authenticator: AUTHENTICATOR).call(env)
  end

  license = token && License.find_by(token: token)

  repo = Paquette::GemServer::ReadGatedRepository.new(REPO, gate_key: license&.cache_key_with_version) do |name:, version: nil|
    license&.gem_names&.include?(name)
  end
  if license
    repo = Paquette::GemServer::Personalizer.new(repo,
      license_key: license.key,
      magic_comment_replacements: {"# paquette_license_info" => license.key})
  end

  Paquette::GemServer.new(repo, authenticator: AUTHENTICATOR).call(env)
}
```

Building a server is cheap, and a stack built per request is the norm. `Paquette::AuthToken.from_env(env)` reads the token the same way the server does, so the stack you pick and the answers your authenticator gives are about the same caller.

The NPM server is assembled exactly the same way, out of the same kind of parts - see [Usage for NPM packages](#usage-for-npm-packages).

## Authentication

All three servers take an `authenticator:` - any object answering three questions about a token:

```ruby
class AcmeAuthenticator
  def read_permitted?(auth_token:)
    auth_token.nil? || AccessToken.exists?(secret: auth_token) # nil lets anonymous callers read
  end

  def write_permitted?(auth_token:)
    Publisher.exists?(token: auth_token)
  end

  def check_otp!(auth_token:, otp_code:)
    Paquette::Totp.verify!(Publisher.find_by!(token: auth_token).totp_secret, otp_code)
  end
end

Paquette::GemServer.new(gem_repo, authenticator: AcmeAuthenticator.new)
Paquette::NpmServer.new(npm_repo, authenticator: AcmeAuthenticator.new)
```

What each server does with it:

- **The token.** Clients do not send it the same way, and `Paquette::AuthToken.from_env(env)` reads all of them: `Authorization: Bearer TOKEN` from npm, the bare key `gem push` sends as the whole header, and Basic auth from Bundler - the token as the username with any password (`https://TOKEN:x-oauth-basic@gem.example.com`), or as the password behind an empty username or one of `x-oauth-basic`, `x-access-token`, `x-oauth-token`, `__token__` - the last being how pip and twine send one. The token is `nil` when the request sent no credentials, a blank `Authorization` header included. A header that carries no token at all - `Bearer` with nothing after it, a scheme Paquette does not speak - is a 401 without asking the authenticator: a mangled header must not become an anonymous request.
- **Reads.** Every request asks `read_permitted?`, and a `false` is a 401. Return `true` for a `nil` token to let anonymous callers in. Which packages a caller sees is the repository stack's business - a `ReadGatedRepository` - not the authenticator's.
- **Writes.** Every write - `gem push`, `gem yank`, `npm publish`, `npm unpublish`, `npm dist-tag`, `twine upload` - also asks `write_permitted?`, which is a yes or no for the whole registry: a 403 for a token that may not, a 401 when there was no token. Then the write has to carry a one-time password. Without one the server asks for it in each client's own dialect, so `gem` and `npm` prompt the way they do against rubygems.org and npmjs.com, and `--otp` works on both. twine can send nothing but a username and a password, so on the PyPI server the code goes in the username: `twine upload -u 123456 -p TOKEN` - six to eight digits there, next to a password, is read as the code and the password as the token. With one, `check_otp!` gets it and raises `Paquette::OtpRejected` if it is no good. All of this happens before the handler runs, so a refused push is refused before its body is read.
- **One-time passwords.** `Paquette::Totp.verify!(secret, code, drift: 30)` checks a code against a base32 TOTP secret and raises `Paquette::OtpRejected` for you. Refusing a code that was already used once, or locking someone out after a few wrong guesses, needs state Paquette has nowhere to keep, so that stays with your `check_otp!`.
- **The outcome** lands in `env["paquette.authentication"]` for your own log line: `authorized`, `credentials_unreadable`, `read_refused`, `write_refused`, `otp_missing` or `otp_rejected`.
- **`npm whoami`** answers `paquette` for any accepted token, and 401 without one.

Without an authenticator, a server lets everyone read and refuses every write. `Paquette::Authentication::Open` lets anyone read and write and takes any code as the one-time password - it is what the dev setup runs, and never what a server anyone else can reach should.

## Hostname limitations

The server will run on `http://localhost:9292` by default. Note that the three registries have to live on separate domains - so they will respond on whichever domain is passed in that has `gem.`, `npm.` or `pypi.` as first subdomain. If your OS supports `.localhost` TLDs, you can access `gem.whatever.localhost:9292` and it will respond.

## Publishing gems into Paquette

You can publish gems two ways.

1. Place `.gem` files in a per-gem directory under `gems/`, as `gems/gemname/gemname-version.gem`
2. Actually do a `gem push` - from your shell, do `gem push --host http://gem.localhost:9292 --otp 000000 pkg/your-gem-0.1.0.gem`

Note that the default dev setup runs `Paquette::Authentication::Open`, which takes any token and any one-time password - that is to say, _no_ auth. I told you it is slightly unhinged. See [Authentication](#authentication) for tokens and OTP.

### After a push

All three servers take an `on_publish:` callable, called once a push, a publish or an upload has landed with a `Paquette::Published` (`name`, `version`, `released_at`) and the `Rack::Request` - to record the release, mail somebody, note the address it came from:

```ruby
Paquette::GemServer.new(repo, authenticator: authenticator, on_publish: ->(published, request) {
  Release.create!(name: published.name, version: published.version, released_at: published.released_at, from: request.ip)
})
```

`released_at` is the gemspec's date for a gem, and the moment of arrival for an npm package or a Python file - `npm pack` stamps every tarball entry with 1985-10-26, and a wheel carries no date of its own, so there is no better one. A Python project is named by its PEP 503 normalized name, as the gate sees it. An exception from the callable is a 500 for a package that is already stored, so rescue what is allowed to fail.

If anything downstream trusts a gem's date - a cooldown, a license window - make the date mean something: `DirectoryGemRepository.new(dir, require_release_date: true)` refuses a push dated with the RubyGems placeholder (1980-01-02, what a reproducible build stamps without `SOURCE_DATE_EPOCH`) or more than about three years from today, before anything is stored.

### Consuming gems provided by a Paquette server

To install gems from Paquette, set it as source in your Gemfile - and provide auth for whichever auth mechanism you wrap it with:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.paquette.acme.com"
```

The RubyGems API in Paquette supports the following endpoints:

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
- `GET /specs.4.8`, `GET /latest_specs.4.8` (and their `.gz` variants) - the legacy Marshal indexes
- `GET /names`, `GET /versions`, `GET /info/{gemname}` - the compact index

### Platform gems

A gem built for a platform is stored, downloaded and indexed under the filename RubyGems gives it - `nokogiri-1.16.0-java.gem` - so the same name and version can exist for `ruby`, `java` and `arm64-darwin` side by side, and each is downloaded and yanked on its own.

Where the platform ends up in a response depends on the format, Paquette follows Rubygems conventions.

`gem push` files each build under that same RubyGems filename, so the three builds of one release are three artifacts rather than one pushed three times. What follows from that:

### URL filtering in package metadata

Most of what that endpoints return comes straight out of the uploaded gemspec, so it is written by whoever pushed the gem. Two fields are filtered before they go out: `homepage`, and every `*_uri` key in `metadata`. Each is served only when it is an absolute `http`/`https` URL with a host, and replaced with `""` (or dropped, for a metadata key) when it is not — `gem build` only warns about a `javascript:` or `data:` homepage, so a crafted gem can carry one. The npm packument's top-level `homepage` is filtered the same way; its `repository` and `bugs` are not, because `git://` and `git+ssh://` are legitimate there, and neither are the per-version documents under `versions`, which pass `package.json` through whole.

Everything else — `authors`, `summary`, `description`, `info`, the non-URI keys of `metadata` — is passed through unchanged and is still uploader-controlled text. If you render any of it in a page of your own, escape it there.

## Usage for NPM packages

The NPM server is built the same way as the gem server and out of the same kind of parts: one repository object, wrapped in as many layers as you want, handed to a Rack app.

```ruby
def call(env)
  username = env["REMOTE_USER"]
  user = User.where(login: username).first!
  packages_dir = Rails.root.join("packages", "npm").to_s

  repo = Paquette::NpmServer::DirectoryNpmRepository.new(packages_dir)

  repo_with_gating = Paquette::NpmServer::ReadGatedRepository.new(repo) do |name:, version: nil|
    user.license.package_names.include?(name)
  end

  repo_with_gating_and_personalization = Paquette::NpmServer::Personalizer.new(
    repo_with_gating,
    license_key: user.license_key,
    magic_comment_replacements: {"// paquette_license_info" => user.license_key},
    files: {"LICENSE.txt" => user.rendered_license}
  )

  Paquette::NpmServer.new(repo_with_gating_and_personalization).call(env)
end
```

The layers mean the same things they do for gems, with a few quirks:

- A gated `latest` follows the newest version the caller is entitled to, not the newest version that exists. Otherwise `npm install pkg` would resolve to a version the very next request refuses to serve.
- `latest` never points at a prerelease while a stable release exists, which is what npm's own registry does.

### Where packages live on disk

One directory per package, with a scope as an ordinary directory above it:

```
packages/npm/lodash/lodash-4.17.21.tgz
packages/npm/@acme/widgets/widgets-1.0.0.tgz
```

The scope stays on the package name but is dropped from the filename, exactly as in the tarball URLs npm follows (`/@acme/widgets/-/widgets-1.0.0.tgz`).

### Personalization and integrity with NPM packages

npm records a `dist.integrity` hash for every version and refuses to install a tarball whose bytes do not match. A registry that rebuilds a tarball to serve it therefore has to rebuild it to *the same bytes* it published a hash for. Thus the same restriction applies as for Rubygems packages.

Magic comment replacements forces replacements to be on one line. This is done so that if your package contains sourcemaps the offsets of the sourcemap do not shift - and the sourcemap thus won't have to be rewritten.

### Publishing NPM packages into Paquette

1. Place `.tgz` files in the layout above. The filename should be `name-version.tgz`, scope excluded.
2. Actually do an `npm publish` - from your shell, do `npm publish --registry http://npm.localhost:9292 --otp 000000`.

`npm unpublish` works too. An unpublished version leaves a `.tgz.tomb` behind, which stops that exact version being republished with different contents later - the same trick the gem side uses for yanks.

### Consuming packages provided by a Paquette server

Point npm at it and provide auth for whichever mechanism you wrapped it with:

```
# .npmrc
@acme:registry=https://npm.paquette.acme.com
//npm.paquette.acme.com/:_authToken=tok_998218907784
```

### NPM API Endpoints

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

## Usage for Python packages

The PyPI server is built like the other two: a repository, as many wrappers as you want, and a Rack app around them.

```ruby
repo = Paquette::PypiServer::DirectoryPypiRepository.new(Rails.root.join("packages", "pypi").to_s)

repo = Paquette::PypiServer::ReadGatedRepository.new(repo, gate_key: license.cache_key) do |name:, version: nil|
  license.package_names.include?(name) # name is PEP 503 normalized: "acme-widgets"
end

repo = Paquette::PypiServer::Personalizer.new(repo,
  license_key: license.key,
  magic_comment_replacements: {"# paquette_license_info" => "licensed to #{license.holder}"},
  files: {"acme_widgets/LICENSE.txt" => license.rendered_text})

Paquette::PypiServer.new(repo, authenticator: AUTHENTICATOR)
```

`CooldownRepository` is there too, and means what it means for gems: an upload through it lands and stays out of view until it has cooled. As on the other two servers, the wrappers pass writes through - who may upload is the authenticator's to say. A few things are particular to Python:

- **Files, not versions.** A version is a set of files - a wheel per platform, an sdist - and the index lists files. The gate's entitler is still asked about `name:` and `version:`, the version read out of each filename, and a cooldown withholds each file on its own: a wheel added to an old release is held back like any new arrival. By default the cooldown reads the file's mtime, because a wheel carries no date of its own; `published_at:` takes a block called with `name:`, `version:` and `filename:` when you keep a better one.
- **Yanks.** `repo.yank_file(project, filename, reason: "")` is a PEP 592 yank: pip passes over the file unless a requirement pins that exact version, and the file stays downloadable for the lockfiles that already have it. There is no HTTP endpoint for it, since no client sends one.
- **Filenames are forever**, as on pypi.org. Uploading a filename that was ever uploaded before is a 409, yanked or not.
- **Personalization** rewrites the comment lines that consist of a marker, indentation kept, in `.py` and `.pyi` files - one line in, one line out, so traceback line numbers match the source the publisher saw. The license key lands in `paquette.json`, which `importlib.metadata.distribution("acme-widgets").read_text("paquette.json")` reads from the installed package. A wheel gets its RECORD rewritten and loses any `RECORD.jws` signature. METADATA is never touched, so its PEP 658 hash stays the repository's. The same checksum warning as for gems applies: pip checks the sha256 the index published, and `--require-hashes` lockfiles will notice a change in how you personalize.

### Where packages live on disk

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

### Consuming packages provided by a Paquette server

```
pip install acme-widgets --index-url https://__token__:tok_998218907784@pypi.paquette.acme.com/simple/
```

or in `pip.conf`, `uv`'s `[[tool.uv.index]]` or Poetry's `[[tool.poetry.source]]` - all of them speak the same Simple API.

### PyPI API Endpoints

- `GET /` - Repository info
- `GET /simple/` - Every project, as HTML or PEP 691 JSON by `Accept` (or `?format=`)
- `GET /simple/{project}/` - A project's files, with sha256, Requires-Python, yank status, size and upload time; any spelling of the name redirects to the normalized one
- `GET /files/{project}/{filename}` - Download a file
- `GET /files/{project}/{filename}.metadata` - A wheel's METADATA (PEP 658)
- `POST /legacy/` - Upload, as twine sends it

## HTTP caching

Paquette emits correct HTTP cache headers and answers conditional requests. For anonymous traffic, a shared cache in front of it does the rest - I usually use `Rack::Cache`, which is fairly reliable, and a CDN works if you know that it handles the `Vary: Authorization` bits correctly. Behind authentication, use `Paquette::ResponseCache` (see below).

Paquette will try to emit sensible ETags for most endpoints, and there is support for partial responses.

### Putting a cache in front

Under plain Rack, with [rack-cache](https://github.com/rtomayko/rack-cache):

```ruby
# config.ru
require "rack/cache"

use Rack::Cache,
  metastore: "file:tmp/cache/rack/meta",
  entitystore: "file:tmp/cache/rack/body",
  verbose: false

run Paquette::GemServer.new(gem_repo)
```

Under Rails, `config.action_dispatch.rack_cache = true` does the same. Put your authorization *below* the cache, next to Paquette, so it runs on every request the cache does not answer.

On an open registry, anonymous downloads are then served out of the cache and index documents are revalidated against Paquette with a cheap 304. Authorized, gated and personalized responses are never stored there: they are `private`, which a shared cache refuses to keep.

### Caching behind authentication

`Paquette::ResponseCache` keeps those. It stores whole 200s on disk, one entry per credential - keyed by the URL, `Authorization`, `Accept` (the PyPI index answers one URL in HTML or JSON) and `Accept-Encoding` - and never answers on its own: every request still goes to the server, with `If-None-Match` set to the stored ETag. When the server answers that with a 304, the stored body goes out as the 200.

```ruby
use Paquette::ResponseCache, directory: "tmp/cache/gems"
run Paquette::GemServer.new(gated_repo, authenticator: authenticator)
```

That only pays off when the stack can name itself, so that Paquette answers the 304 _before_ rendering: give the `ReadGatedRepository` a `gate_key:`. The authenticator and the gate's cache key are still consulted on every request, so a revoked token is refused with a body on disk for it, and a stack without a validator is simply never stored. Ranges, `HEAD`, writes and file downloads go straight through, and so does any body over `max_body_bytes:` (8 MiB by default). Nothing is evicted - the directory holds credentials times index URLs, and can be emptied at any time. `env["paquette.response_cache"]` says `hit`, `miss` or `bypass`, for your log line.

### Caching validators

Paquette allows the repo wrappers to alter the validator (the ETag). The validator itself is derived from the whole wrapper stack, not just from the corpus, wrappers are written to contribute to the ETag in a meaningful way.

A `nil` validator propagates outward, so a `Personalizer` wrapped around a keyless gate emits no `ETag` either.

## The index page

You can customize the user-visible index page of your package server by supplying a Rack app that will serve it, like so:

```ruby
# Serve our index page
Paquette::GemServer.new(repo, placeholder_app: Paquette::IndexPage.new("Gems for Stanquette staff. Ask Julik for a token."))

# ...or a redirect
Paquette::NpmServer.new(repo, placeholder_app: ->(_env) { [302, {"location" => "https://docs.example.com"}, []] })
Paquette::NpmServer.new(repo, placeholder_app: ->(_env) { [404, {}, []] })  # no root at all
```

## Mounting under a path prefix (namespaces)

All three servers can be mounted under a prefix, which is how [gem.coop spells a namespace](https://gem.coop/updates/6/). In Rack only a `map` and nothing else:

```ruby
Rack::Builder.new do
  map("/@acme") { run Paquette::GemServer.new(acme_repo) }
  map("/@beta") { run Paquette::GemServer.new(beta_repo) }
end
```

A namespace per repository is also a namespace per wrapper stack: each mount can have its own gating and personalization, since it is its own `GemServer` around its own repository.

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

The route is there whenever one matched, refused requests included, and makes a bounded action name. The package and version only when that package was actually served or written - a 2xx, or a 304 on a validator the client held - so a scanner probing made-up names cannot mint a tag value per probe. A push names the gem it wrote, which `gem push` sends only in the body, and an upload the Python project and version it wrote. `env["paquette.authentication"]` and `env["paquette.response_cache"]` sit beside it.

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

## License

Paquette is offered under the terms of the [O'Sassy license](https://osaasy.dev/) - basically, **don't make it into your own product or a service.** Use it to sell your libraries. And godspeed!
