<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/paquette-wordmark-logo-on-dark.png">
  <img src="img/paquette-wordmark-logo.png" alt="Paquette" width="420">
</picture>

Paquette is a (slightly unhinged) Rack-based server for libraries. At the moment it serves gems and NPM packages. It is designed to be small and embeddable in other Ruby web applications. You allocate a directory with packages and expose it through Paquette, all the while bringing your own authentication, limits, filtering and entitlements.

In essence, it is a gem/NPM server for distributing commercial packages. I use
it for https://shop.stanquette.nl and it is pretty neat!

Things are somewhat in flux but Paquette is usable alright.

## Basic setup

This is a Ruby library so you will need Ruby installed. To try a minimal setup, do a `bundle install` and start `bin/dev`. Try pushing a gem into Paquette and then adding the local server to your `Gemfile` - and then do a `bundle install` in your application for that custom gem.

However, that is not how Paquette is primarily meant to be used. It is meant to be integrated into a larger Rails or Rack application. The key Paquette concepts are:

- The serving app object - this is what poses as a gem/NPM repo. It's a Rack app.
- The repository object - that's the frontend for your stored packages.
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

You can make your package server do interesting things by wrapping your `repo`. For example, to disallow gem pushes:

```ruby
# ...the rest as above
gem_repo = Paquette::GemServer::ReadonlyRepository.new(gem_repo) # forbids yank and push
gem_server = Paquette::GemServer.new(gem_repo)
```

You can also create your own entitlement checks. This allows you to customize which gems get offered to a specific user:

```ruby
# ...the rest as above
gem_repo = Paquette::GemServer::ReadGatedRepository.new(gem_repo, gate_key: Current.license.cache_key) do |name:, version: nil|
  lic = Current.license
  lic.package_names.include?(name)
end
gem_server = Paquette::GemServer.new(gem_repo)
```

Now the holder of the `license` stored in your `ActiveSupport::Current` for the request will only receive the gems included in their license's `package_names` list. And you can limit version access as well. This affects serving the actual packages, serving the indexes and anything else.

The `gate_key:` (the npm `ReadGatedRepository` takes one too) is optional and is only used for HTTP caching. Your gate is a block, and nothing inside Paquette can work out which subset of the corpus it selects - so if you want Paquette to emit `ETag`s on the index endpoints, you have to say who this gate is for. Pass something that identifies the licensee *and* changes whenever their entitlements change (a Rails `cache_key` does both). Leave it out and Paquette emits no `ETag` at all rather than a possibly-wrong one - see [HTTP caching](#http-caching).

Paquette also includes a _personalization_ wrapper.

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

There is also a _cooldown_ wrapper, which withholds versions that were published less than a given interval ago:

```ruby
# ...the rest as above
gem_repo = Paquette::GemServer::CooldownRepository.new(gem_repo, interval: 7 * 24 * 60 * 60)
gem_server = Paquette::GemServer.new(gem_repo)
```

A version that is still cooling does not appear in `/names`, `/versions`, `/info/`, `/specs.4.8` or `/latest_specs.4.8`, and it does not download - it 404s, same as a gem that is not there. A gem whose every version is still cooling disappears from the index entirely rather than showing up with an empty version list. The interval is in seconds (Paquette has no ActiveSupport, so there is no `7.days` to write), and a version whose age is exactly the interval is served.

The point is that a bad release should not be resolvable into a customer's lockfile the instant it is pushed: the cooldown is the window in which you can still yank it before anyone has picked it up. It also makes a serviceable release channel - point your conservative customers at a server wrapped in this and they get every release a week late, out of the same corpus, without a second copy of anything. Like the other wrappers it is read-only; wrap the bare repository for the endpoint that accepts pushes.

> [!IMPORTANT]
> By default the publication date is `spec.date`, the date recorded in the gemspec - which is **publisher-controlled and records the build time, not the moment the gem arrived on your server.** A gem built in March and pushed in June is already past a seven-day cooldown when it lands.

The default is `spec.date` because it is a property of the immutable gem bytes. It is not the file mtime, because an mtime is a property of your filesystem right now: an rsync, a container rebuild or a restore from backup resets every one of them, which would make the whole corpus look freshly published and put every gem into cooldown at once - a self-inflicted outage for every customer on the cooldown channel. And it is not a timestamp minted into the sidecar cache, because that cache is an optimization that may be deleted and regenerated at any time, which would have the same effect. `spec.date` survives all of that, and is cached in the sidecar precisely because it can always be re-derived.

If you need the stronger property - when the artifact actually appeared here - pass your own source. Anyone embedding Paquette in a Rails app has a table for this:

```ruby
gem_repo = Paquette::GemServer::CooldownRepository.new(
  gem_repo,
  interval: 7 * 24 * 60 * 60,
  published_at: ->(name:, version:) { GemPush.where(name: name, version: version).pick(:created_at) },

  # Injectable so tests do not have to sleep
  clock: -> { Time.now }
)
```

Returning `nil` from `published_at:` means "I do not know when this was published", and an unknown date **fails open** - the version is served. That is deliberate: a cooldown is a delay policy, not an authorization boundary, and failing closed would turn one missing timestamp into a broken `bundle install`. If a version must not be served at all, gate it with `ReadGatedRepository`, which is the wrapper whose job that is.

You may want to construct your own Rack application when wiring all that up though:

```ruby
def call(env)
  username = env["REMOTE_USER"]
  user = User.where(login: username).first!
  packages_dir = Rails.root.join("packages", "gems").to_s

  repo = Paquette::GemServer::DirectoryGemRepository.new(packages_dir)

  repo_with_gating = Paquette::GemServer::ReadGatedRepository.new(repo) do |name:, version: nil|
    user.license.gem_names.include?(name)
  end

  repo_with_gating_and_personalization = Paquette::GemServer::Personalizer.new(
    repo_with_gating,
    license_key: user.license_key,
    magic_comment_replacements: {"# paquette_license_info" => user.license_key}
  )

  Paquette::GemServer.new(repo_with_gating_and_personalization).call(env)
end
```

The NPM server is assembled exactly the same way, out of the same kind of parts - see [Usage for NPM packages](#usage-for-npm-packages).

Because the wrappers are plain Ruby objects composed at the call site, per-user state (the `user` variable) is captured by ordinary closures. Drop a wrapper to disable that layer; add another by slotting in one more constructor. Whether the server will accept pushes and yanks is decided by what you build — wrap the base repo in `ReadonlyRepository` and writes are blocked; hand the server a bare `DirectoryGemRepository` (or your own wrapper that permits writes) and they go through.

The server will run on `http://localhost:9292` by default. Note that the NPM registry and the RubyGems registry have to live on separate domains - so they will respond on whichever domain is passed in that has `gem.` or `npm.` as first subdomain. If your OS supports `.localhost` TLDs, you can access `gem.whatever.localhost:9292` and it will respond.

You can publish gems two ways.

1. Place `.gem` files in a per-gem directory under `gems/`, as `gems/gemname/gemname-version.gem`
2. Actually do a `gem push` - from your shell, do `gem push --host http://gem.localhost:9292 pkg/your-gem-0.1.0.gem`

Note that Paquette will use whichever auth you wrap it with - that is to say, in the default dev setup - _none._ I told you it is slightly unhinged.

### Consuming gems provided by a Paquette server

To install gems from Paquette, set it as source in your Gemfile - and provide auth for whichever auth mechanism you wrap it with:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.paquette.acme.com"
```

The RubyGems API in Paquette supports the following endpoints:

- `GET /` - Repository info
- `GET /api/v1/dependencies` - Gem dependencies
- `GET /api/v1/versions` - Available gem versions
- `GET /api/v1/names` - Available gem names
- `GET /api/v1/search.json` - Search gems
- `GET /gems/{gemname-version.gem}` - Download gem file
- `POST /api/v1/gems` - Upload gem (basic implementation)

### What `/api/v1/versions` does and does not sanitise

Most of what that endpoint returns comes straight out of the uploaded gemspec, so it is written by whoever pushed the gem. Two fields are filtered before they go out: `homepage`, and every `*_uri` key in `metadata`. Each is served only when it is an absolute `http`/`https` URL with a host, and replaced with `""` (or dropped, for a metadata key) when it is not — `gem build` only warns about a `javascript:` or `data:` homepage, so a crafted gem can carry one. The npm packument's top-level `homepage` is filtered the same way; its `repository` and `bugs` are not, because `git://` and `git+ssh://` are legitimate there, and neither are the per-version documents under `versions`, which pass `package.json` through whole.

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
2. Actually do an `npm publish` - from your shell, do `npm publish --registry http://npm.localhost:9292`.

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
- `GET /-/whoami` - The identity your auth wrapper resolved
- `GET /{package}` - Package metadata document
- `GET /{package}/-/{name-version.tgz}` - Download tarball
- `GET /-/package/{package}/dist-tags` - Read dist-tags
- `PUT /-/package/{package}/dist-tags/{tag}` - Point a dist-tag at a version
- `PUT /{package}` - Publish
- `PUT /{package}/-rev/{rev}` - Document update (how `npm unpublish` removes versions)
- `DELETE /{package}/-rev/{rev}` - Unpublish a package
- `DELETE /{package}/-/{name-version.tgz}/-rev/{rev}` - Unpublish one version

## HTTP caching

Paquette does not cache anything itself. It emits correct HTTP cache headers and answers conditional requests, and leaves the actual caching to a cache you put in front of it.

### What the server emits

`GET /versions`, `GET /names` and `GET /info/:gem_name` carry an `ETag` and honour `If-None-Match` with a `304 Not Modified`. This is worth having on `/versions` in particular: rendering it means rendering and MD5-ing every gem's `/info/` body for the whole corpus, so a 304 turns the most expensive request this server serves into a digest of the corpus fingerprint.

`GET /gems/:gem_filename` carries an `ETag`, a `Last-Modified`, `Accept-Ranges: bytes` and `Cache-Control: private, max-age=31536000, immutable`, and honours `If-None-Match`, `If-Modified-Since`, and `Range` (including multiple ranges, `416` for an unsatisfiable one, and `If-Range`). The `immutable` is honest: a `.gem` file at a given path never changes, because a yank renames it away and a name+version can never be pushed twice.

The npm server does the same on its own surfaces. `GET /:package` (the packument) and `GET /-/package/:package/dist-tags` carry an `ETag` and answer `If-None-Match` with a 304 - the npm client honours ETag on packuments, so this is the equivalent of `/versions`. `GET /:package/-/:tarball` is served exactly like a gem download, and its `ETag` is the very `dist.integrity` value the packument published, because npm refuses to install a tarball that disagrees with the document that pointed at it. `GET /-/whoami` is `Cache-Control: private, no-store` and carries no validator at all: it is the caller's identity, and there is no key under which storing it would be safe.

Range serving is Rack's own `Rack::Files#serving`, so this adds no dependency.

Nothing either server sends is ever `public`, and every response carries `Vary: Authorization`:

| Response | `Cache-Control` | `Vary` |
| --- | --- | --- |
| `.gem` download, npm tarball (and their 304s) | `private, max-age=31536000, immutable` | `Authorization, Accept-Encoding` |
| `/versions`, `/names`, `/info/:gem_name`, packument, dist-tags (and their 304s) | `private, no-cache` | `Authorization, Accept-Encoding` |
| `/-/whoami` | `private, no-store` | `Authorization, Accept-Encoding` |
| Everything else - errors, the legacy Marshal indexes, `/api/v1/*`, the index page | `private, no-store` | `Authorization` |

### Why everything is `private`

Paquette is a private registry. Every request you route to it has been let through by something - a bearer token, a publishing token, `Paquette::TokenAuthorization` - and it is normal to serve the *same URL* ungated to one caller (the owner's publishing token reading the unwrapped repository) and gated to the next. A shared cache in front keys on the URL and cannot tell those two apart.

RFC 9111 already says a shared cache must not store the response to a request that carried `Authorization` - unless the response says `public`, which is exactly what that directive is for. Rack::Cache implements that rule to the letter. So a `public` download handed to the publisher would be stored, and the next anonymous request for the URL would be answered out of the cache without your gate ever running. That is why Paquette never sends `public`, whatever repository it is serving, and why a bare `DirectoryGemRepository` is treated no differently from a gated one.

**`Cache-Control: private` is the load-bearing control.** It keeps every shared cache out.

**`Vary: Authorization` is defence in depth, and it is not sufficient on its own.** It is correct for the flow this gem documents - `Paquette::TokenAuthorization` reads the token out of `Authorization`, in both its Bearer and its Basic spelling - but Paquette does not resolve identity, your application does. The example further up this README resolves the user from `env["REMOTE_USER"]`; yours may use a cookie, a client certificate or a subdomain. A shared cache keyed only on `Authorization` would then serve one licensee's index to another quite happily. If you override these headers, do not read "we set `Vary`" as meaning you are covered - `private` is what covers you, and if you relax it you are on your own.

The index endpoints get `no-cache` rather than `no-store`, so the *client* (Bundler's own on-disk compact index, npm's metadata cache) can still keep a copy and send `If-None-Match`. Without that there would be nothing to revalidate and no 304.

### Putting a cache in front

With every response `private`, a shared cache in front of Paquette - rack-cache, Rails' Rack::Cache integration, a CDN - stores nothing Paquette serves. Each request reaches your gate and then Paquette, every time. That is deliberate, and it is what stops one caller's download from being replayed to another. What you still get:

- The client's own cache revalidates cheaply. A repeat `bundle install` or `npm install` sends `If-None-Match`, and a 304 on `/versions` or a packument skips the render entirely.
- Downloads are `immutable` for a year in the client's cache, and `Range`/`If-Range` let an interrupted one resume.

If you already run rack-cache in front for other routes, it is safe to leave it there:

```ruby
# config.ru
require "rack/cache"

use Rack::Cache,
  metastore: "file:tmp/cache/rack/meta",
  entitystore: "file:tmp/cache/rack/body",
  verbose: false

run Paquette::GemServer.new(gem_repo)
```

Put your authorization *below* the cache, next to Paquette, and it runs on every request. If the server-side cost of rendering is what you are after, cache inside your application - the personalizer already keeps repacked artifacts on disk - rather than asking a shared HTTP cache to hold responses that were served to one authorized caller.

### How the validator is derived

The validator itself is derived from the whole wrapper stack, not just from the corpus:

- The directory repository contributes its `fingerprint` - a digest of what is on disk, which moves on every push and yank. On the npm side it also folds in each `dist-tags.json` mtime, because a dist-tag write rewrites that file in place and moves no path at all.
- `Personalizer` mixes in its personalization key, so one licensee's index can never validate another's.
- `ReadGatedRepository` mixes in the `gate_key:` you supplied, **and emits no validator at all if you did not supply one.** That is deliberate. An entitlement gate is an arbitrary block; guessing that two of them are the same gate is how one customer ends up with another customer's index. No `ETag` means every request is served in full, which is slow and recoverable.
- `CooldownRepository` emits no validator at all. What it serves changes with the clock while the corpus stands still, so a corpus-derived `ETag` would answer 304 to a client holding the index from before a version cooled - and the release the channel exists to deliver would reach nobody.

On the npm side the packument validator also folds in the base URL the request was made against, since the document embeds absolute tarball URLs built from it. Host is part of any cache key already, but scheme is not.

Personalization is worse on the npm side than on the gem side, and worth understanding before you cache anything. A gem `Personalizer` changes the bytes of a `.gem` and the checksum the index publishes for it. An npm `Personalizer` changes the *packument itself*, because `dist.integrity` is recomputed per licensee and the document carries one per version. Hand a second licensee a packument cached for the first and npm receives integrity hashes that cannot match the tarball it downloads next - which it treats as tampering and refuses to install.

A `nil` validator propagates outward, so a `Personalizer` wrapped around a keyless gate emits no `ETag` either.

### For your own repository classes

If you have written a repository of your own, these optional methods hook into this (defined on `Paquette::GemServer::GemRepository` and `Paquette::NpmServer::NpmRepository` with safe defaults, so an existing class keeps working untouched):

- `#cache_validator` - a short string that changes whenever anything you would serve changes, or `nil` for "do not cache this". Defaults to `nil`.
- `#gem_checksum(name, version)` - the SHA256 of the `.gem` bytes you would actually serve, used for the download `ETag`. Defaults to `nil`, which falls back to size and mtime.

The npm repository protocol has `#cache_validator` with the same meaning; instead of `#gem_checksum` it reads the tarball's integrity off `#dist_for`.

If you are writing a wrapper, mix yourself into the layer below with `Paquette::CacheValidation.derive_validator(inner_validator, "your-layer", your_key)`, which returns `nil` if either argument is `nil`.

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

Both servers can be mounted under a prefix, which is how [gem.coop spells a namespace](https://gem.coop/updates/6/). In Rack only a `map` and nothing else:

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

## Running the tests

```bash
bundle exec rake test
```

Most of it is ordinary Ruby, but we also have a few end-to-end tests, that require Docker and Node. You don't need either for using Paquette though.

## License

Paquette is offered under the terms of the [O'Sassy license](https://osaasy.dev/) - basically, **don't make it into your own product or a service.** Use it to sell your libraries. And godspeed!
