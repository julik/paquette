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

A version that is still cooling does not appear in `/names`, `/versions`, `/info/`, `/specs.4.8`, `/latest_specs.4.8` or `/prerelease_specs.4.8`, and it does not download - it 404s, same as a gem that is not there. A gem whose every version is still cooling disappears from the index entirely rather than showing up with an empty version list. The interval is in seconds (Paquette has no ActiveSupport, so there is no `7.days` to write), and a version whose age is exactly the interval is served.

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

A custom source may read state that changes while the corpus does not, so Paquette cannot tell when to re-read it, and a cooldown over one emits no `ETag` - every index request is served in full. To get one back, also pass `published_at_validator:`, a callable returning a string that changes whenever any answer your source gives would (or `nil` for "cannot say"):

```ruby
published_at_validator: -> { GemPush.maximum(:updated_at)&.iso8601(6) }
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

Where the platform ends up in a response depends on the format, and both of these are what rubygems.org does:

- The compact index (`/info/{gemname}` and the version lists in `/versions`) keeps the platform glued onto the version column, as `1.16.0-java`. That *is* the wire format there; Bundler splits it apart itself.
- Everywhere else - `/specs.4.8` and `/latest_specs.4.8`, `/api/v1/dependencies`, `/api/v1/versions`, `/api/v1/search.json` - the version is bare and the platform is its own field. The legacy Marshal indexes carry `[name, Gem::Version, platform]` triples, and `/latest_specs.4.8` names the latest version of each gem *per platform*, so a java build never hides behind a newer plain-ruby one.

`gem push` still files a gem under its bare version, so pushing a platform build of a name and version that already exists is refused as a duplicate. Put platform builds in the gems directory as files for now.

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

`GET /gems/:gem_filename` carries an `ETag`, a `Last-Modified`, `Accept-Ranges: bytes` and `Cache-Control: max-age=31536000, immutable` (`public` or `private` - see below), and honours `If-None-Match`, `If-Modified-Since`, and `Range` (including multiple ranges, `416` for an unsatisfiable one, and `If-Range`). The `immutable` is honest: a `.gem` file at a given path never changes, because a yank renames it away and a name+version can never be pushed twice.

The npm server does the same on its own surfaces. `GET /:package` (the packument) and `GET /-/package/:package/dist-tags` carry an `ETag` and answer `If-None-Match` with a 304 - the npm client honours ETag on packuments, so this is the equivalent of `/versions`. `GET /:package/-/:tarball` is served exactly like a gem download, and its `ETag` is the very `dist.integrity` value the packument published, because npm refuses to install a tarball that disagrees with the document that pointed at it. `GET /-/whoami` is `Cache-Control: private, no-store` and carries no validator at all: it is the caller's identity, and there is no key under which storing it would be safe.

Range serving is Rack's own `Rack::Files#serving`, so this adds no dependency.

### Public or private, per request

Paquette does not require authentication, so an open registry is a real configuration, and it gets headers a CDN can use. Whether a response is `public` is decided per request. It is `public` only when all three hold:

1. **The request carries no credential** - no `Authorization` header and no `Cookie` header.
2. **Nothing in the repository stack varies by caller** - no `ReadGatedRepository` and no `Personalizer` anywhere in it. A gate may decide by something Paquette never sees (an IP, a header), so even two anonymous callers can get different answers from it. A repository class that does not answer `#varies_by_caller?` is assumed to vary.
3. **The server was not built with `shared_caching: false`** - see below.

Otherwise it is `private`. Every labelled response carries `Vary: Authorization, Cookie, Accept-Encoding`, and every response at all carries at least `Vary: Authorization`.

| Response | Anonymous, open stack | Credential, gated or personalized stack, or `shared_caching: false` |
| --- | --- | --- |
| `.gem` download, npm tarball (and their 304s) | `public, max-age=31536000, immutable` | `private, max-age=31536000, immutable` |
| `/versions`, `/names`, `/info/:gem_name`, packument, dist-tags (and their 304s) | `public, no-cache` | `private, no-cache` |
| `/-/whoami` | `private, no-store` | `private, no-store` |
| Everything else - errors and 404s, the legacy Marshal indexes, `/quick/*`, `/api/v1/*`, the index page | `private, no-store` | `private, no-store` |

The index endpoints get `no-cache` rather than `no-store`, so a cache - Bundler's on-disk compact index, npm's metadata cache, or a CDN on an open registry - can keep a copy and send `If-None-Match`, and every use is revalidated. It is `no-cache` rather than a short `max-age` because a push or a yank then shows up on the very next request rather than a `max-age` later, and the revalidation is answered with a 304 off the corpus fingerprint without rendering anything.

### Why a credentialed response is never `public`

It is normal to serve the *same URL* ungated to one caller (the owner's publishing token reading the unwrapped repository) and gated to the next. A shared cache keys on the URL and cannot tell those two apart. RFC 9111 says a shared cache must not store the response to a request that carried `Authorization` - unless the response says `public`, which is exactly what that directive overrides. Rack::Cache implements that rule to the letter, so a `public` download handed to the publisher would be stored, and the next anonymous request for the URL would be answered out of the cache without your gate ever running. Paquette therefore never answers a request that carries a credential with `public`.

**`Cache-Control: private` is the load-bearing control.** `Vary` is defence in depth: a Vary-honouring cache such as Rack::Cache will not hand the anonymous copy it stored to a request carrying `Authorization` or `Cookie`. It is not sufficient on its own - Paquette does not resolve identity, your application does, and many caches ignore `Vary` (see the CDN section below).

### `shared_caching: false`

```ruby
Paquette::GemServer.new(gem_repo, shared_caching: false)
Paquette::NpmServer.new(npm_repo, shared_caching: false)
```

This makes every response `private`, as if every request carried a credential. Set it when you authorize by something Paquette cannot see, in front of an ungated repository: an IP allowlist, mutual TLS, a custom header checked in your own middleware, a VPN, a signed URL. Without it, an anonymous request that your middleware let through would be answered `public`, and a shared cache in front of that middleware would replay it to callers the middleware would have refused. You do not need it when every request carries `Authorization` or a `Cookie`, or when the repository is wrapped in a `ReadGatedRepository` or a `Personalizer`.

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

On an open registry, anonymous downloads are then served out of the cache and index documents are revalidated against Paquette with a cheap 304. Authorized, gated and personalized responses are never stored; each of those requests reaches your gate and Paquette every time, and the client's own cache still revalidates cheaply. If the server-side cost of those is what you are after, cache inside your application - the personalizer already keeps repacked artifacts on disk.

### CDNs

A CDN (Cloudflare, Fastly, CloudFront) is a shared cache like any other, with one important difference: **most do not honour `Vary: Authorization`.** Cloudflare, for one, [does not consider `Vary` values in caching decisions by default](https://developers.cloudflare.com/cache/concepts/cache-control/), apart from `Accept-Encoding` and, with Vary for Images, image formats; [other `Vary` values are respected only if you configure the Cache Rules Vary setting](https://developers.cloudflare.com/cache/concepts/vary/). Cloudflare also [stores a response to a request carrying `Authorization` when the response says `public`, `must-revalidate` or `s-maxage`](https://developers.cloudflare.com/cache/concepts/cache-control/). At the edge, then, `public` on an authorized response would be exactly the leak described above, and it is why Paquette never sends it - nor `must-revalidate` or `s-maxage`, on anything.

What that means in practice:

- **Anonymous requests to an open registry can be cached at the edge.** Note that Cloudflare [caches by file extension only and does not cache HTML or JSON by default](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/) - and `.gem` and `.tgz` are not on its default list, nor are extensionless paths like `/versions`; you need a Cache Rule making these paths eligible for cache, with origin `Cache-Control` respected. With Origin Cache Control enabled, Cloudflare stores `no-cache` responses and revalidates them on every use; without it, it does not cache them at all.
- **Authorized responses are not cached at the edge.** They are `private`, and every one reaches your origin. The client still revalidates cheaply with `ETag` and a 304.
- **A stored anonymous copy may be handed to an authorized caller** by a CDN that ignores `Vary`. That exposes nothing - the copy was public - but if your application gives credentialed callers a *different* view of the same URL (say, the owner's token reads an unwrapped repository while anonymous callers get a smaller open one), configure the CDN to bypass its cache for requests that carry `Authorization` or a `Cookie`.
- **Caching per credential at the edge** would need a cache key that includes the credential. That is CDN-specific, it is your decision and not Paquette's, and Paquette will still mark those responses `private` - the CDN has to be told to override that.
- If your origin authorizes by IP, mTLS or a header your CDN adds, set `shared_caching: false`.

### How the validator is derived

The validator itself is derived from the whole wrapper stack, not just from the corpus:

- The directory repository contributes its `fingerprint` - a digest of what is on disk, which moves on every push and yank. On the npm side it also folds in each `dist-tags.json` mtime, because a dist-tag write rewrites that file in place and moves no path at all.
- `Personalizer` mixes in its personalization key, so one licensee's index can never validate another's.
- `ReadGatedRepository` mixes in the `gate_key:` you supplied, **and emits no validator at all if you did not supply one.** That is deliberate. An entitlement gate is an arbitrary block; guessing that two of them are the same gate is how one customer ends up with another customer's index. No `ETag` means every request is served in full, which is slow and recoverable.
- `CooldownRepository` mixes in its interval and how many of the known publish times have cooled. What it serves changes with the clock while the corpus stands still, so the inner validator alone would answer 304 to a client holding the index from before a version cooled. But versions cool in the order they were published, so that count moves exactly when the servable set does. The publish times are read once per inner validator and binary-searched per request, which means the wrapper should be built once rather than per request. With a custom `published_at:` it emits no validator unless you also pass `published_at_validator:` (see above).

On the npm side the packument validator also folds in the base URL the request was made against, since the document embeds absolute tarball URLs built from it. Host is part of any cache key already, but scheme is not.

Personalization is worse on the npm side than on the gem side, and worth understanding before you cache anything. A gem `Personalizer` changes the bytes of a `.gem` and the checksum the index publishes for it. An npm `Personalizer` changes the *packument itself*, because `dist.integrity` is recomputed per licensee and the document carries one per version. Hand a second licensee a packument cached for the first and npm receives integrity hashes that cannot match the tarball it downloads next - which it treats as tampering and refuses to install.

A `nil` validator propagates outward, so a `Personalizer` wrapped around a keyless gate emits no `ETag` either.

### For your own repository classes

If you have written a repository of your own, these optional methods hook into this (defined on `Paquette::GemServer::GemRepository` and `Paquette::NpmServer::NpmRepository` with safe defaults, so an existing class keeps working untouched):

- `#cache_validator` - a short string that changes whenever anything you would serve changes, or `nil` for "do not cache this". Defaults to `nil`.
- `#varies_by_caller?` - whether two callers can get different answers out of you. Defaults to `true`, which keeps every response `private`; `DirectoryGemRepository` and `DirectoryNpmRepository` say `false`, and `ReadGatedRepository` and `Personalizer` say `true`. A wrapper that does not change what a caller sees can simply delegate it.
- `#gem_checksum(name, version)` - the SHA256 of the `.gem` bytes you would actually serve, used for the download `ETag`. Defaults to `nil`, which falls back to size and mtime.

The npm repository protocol has `#cache_validator` and `#varies_by_caller?` with the same meaning; instead of `#gem_checksum` it reads the tarball's integrity off `#dist_for`.

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

RubyGems' own compact-index conformance suite runs separately, because it shells out to the `gem_server_conformance` RSpec binary:

```bash
bundle exec rake test:conformance
```

It boots a gem server over a bare `DirectoryGemRepository` and drives the suite against it over HTTP. `test/conformance/rspec_exclusions.rb` lists the examples Paquette knowingly does not pass and why — read it before concluding that a green run means full conformance. Without the `gem_server_conformance` gem installed the test skips; set `PAQUETTE_REQUIRE_CONFORMANCE=1` to turn that skip into a failure, which is what CI wants.

## License

Paquette is offered under the terms of the [O'Sassy license](https://osaasy.dev/) - basically, **don't make it into your own product or a service.** Use it to sell your libraries. And godspeed!
