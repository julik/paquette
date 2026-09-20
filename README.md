# Paquette

Paquette is a (sligtly unhinged) Rack-based server for libraries. At the moment it serves gems and NPM packages. It is very basic and is made to serve packages gated by a licensing mechanism, which is supposed to be BYO.

Things are very in flux at the moment, but it may come in handy.

## Setup

1. Install dependencies:
   ```bash
   bundle install
   ```

2. Start the server:
   ```bash
   bundle exec puma
   ```

## Repository gating

Paquette is built on the premise that you can have a corpus of libraries you offer, and deduce - from the `Authorization` HTTP header or by other means - which packages a user may download. Only the packages they have access to get included in the API responses - version lists, checksum lists and so on.

`Paquette::GemServer` itself is dumb: it takes one repository object and routes every read, push, and yank through it. You build the stack per request by nesting plain constructors — no DSL, no callbacks registered on the server, just wrappers wrapping wrappers. For example, inside a Rack endpoint:

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

Each line adds one capability:

- `DirectoryGemRepository` reads `.gem` files from disk and accepts pushes and yanks.
- `ReadGatedRepository` wraps a repository and filters every name/version through the block — unauthorized gems simply stop existing as far as the server is concerned. It also refuses writes outright: if you gate reads, you are saying this caller is not the right party to mutate the corpus, so `add_gem`/`yank_gem` raise `WriteNotAllowed` (which the server turns into a 403).
- `Personalizer` wraps a repository and rewrites each served `.gem` on the fly to embed the user's license key.

The NPM server is assembled exactly the same way, out of the same kind of parts - see [Usage for NPM packages](#usage-for-npm-packages).

Because the wrappers are plain Ruby objects composed at the call site, per-user state (the `user` variable) is captured by ordinary closures. Drop a wrapper to disable that layer; add another by slotting in one more constructor. Whether the server will accept pushes and yanks is decided by what you build — wrap the base repo in `ReadGatedRepository` and writes are blocked; hand the server a bare `DirectoryGemRepository` (or your own wrapper that permits writes) and they go through.

The server will run on `http://localhost:9292` by default. Note that the NPM registry and the Rubygems registry have to live on separate domains - so they will respond on whichever domain is passed in that has `gem.` or `npm.` as first subdomain. If your OS supports `.localhost` TLDs, you can access `gem.whatever.localhost:9292` and it will respond.

## Usage for gems

Paquette contains a gem server. This is a separate Rack app which you can use without the NPM server, for example - inside of your Rails app. You can interact with it using `gem` commands, as if it were any other gem server, or by just placing stuff on the filesystem.

### Publishing gems into Paquette

You can publish gems two ways. 

1. Place `.gem` files in the `gems/` directory. The filename should follow the format: `gemname-version.gem`
2. Actually do a `gem push` - from your shell, do `gem push --host http://gem.localhost:9292 pkg/your-gem-0.1.0.gem` 

Note that Paquette will use whichever auth you wrap it with - that is to say, in the default dev setup - _none._ I told you it is slightly unhinged.

### Consuming gems provided by a Paquette server

To install gems from Paquette, set it as source in your Gemfile - and provide auth for whichever auth mechanism you wrap it with:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.paquette.acme.com"
```

### Gem API Endpoints

- `GET /` - Repository info
- `GET /api/v1/dependencies` - Gem dependencies
- `GET /api/v1/versions` - Available gem versions
- `GET /api/v1/names` - Available gem names
- `GET /api/v1/search.json` - Search gems
- `GET /gems/{gemname-version.gem}` - Download gem file
- `POST /api/v1/gems` - Upload gem (basic implementation)

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

The layers mean the same things they do for gems. `DirectoryNpmRepository` reads `.tgz` files from disk and accepts publishes and unpublishes; `ReadGatedRepository` filters every name/version through the block and refuses writes; `Personalizer` rewrites each served tarball on the fly.

Two npm-specific notes:

- A gated `latest` follows the newest version the caller is entitled to, not the newest version that exists. Otherwise `npm install pkg` would resolve to a version the very next request refuses to serve.
- `latest` never points at a prerelease while a stable release exists, which is what npm's own registry does.

### Where packages live on disk

One directory per package, with a scope as an ordinary directory above it:

```
packages/npm/lodash/lodash-4.17.21.tgz
packages/npm/@acme/widgets/widgets-1.0.0.tgz
```

The scope stays on the package name but is dropped from the filename, exactly as in the tarball URLs npm follows (`/@acme/widgets/-/widgets-1.0.0.tgz`).

### Personalization and integrity

npm records a `dist.integrity` hash for every version and refuses to install a tarball whose bytes do not match. A registry that rebuilds a tarball to serve it therefore has to rebuild it to *the same bytes* it published a hash for — so `Paquette::Tarball` writes archives that are byte-reproducible: entries sorted, mtimes carried over from the input, no build timestamp in the gzip header. `NpmRepacker` and `Personalizer` are built on that, and the published hashes are always taken from the personalized tarball rather than the original.

Magic comment replacements swap one whole comment line for another. A sourcemap restarts its column counter at every line, so rewriting a line cannot disturb the mappings on any other line — only on the line that changed, and keeping that line a comment means no mapped token was sitting on it. Changing the line *count*, or putting the license text on a line with real code, is what would misalign a customer's stack traces.

Because of that, the one-line rule is enforced rather than assumed. A replacement (or marker) containing a linebreak is refused when you build the stack — it used to have its newlines flattened to spaces, which published something other than what you wrote. And a marker the line match cannot reach is an error rather than a silent pass. `esbuild --minify` pulls a legal comment onto the end of a code line; the package would otherwise be served with no license key in it and nothing to say so — and `package.json` would still carry the key, so it would look personalized from the outside. A package with no marker at all is ordinary and repacks untouched.

### Publishing packages into Paquette

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

## Regexp timeouts

Every path this server answers goes through a regexp with a client-chosen string on the other side of it — the route patterns Mustermann compiles, then the ones the handlers use to take a gem name and version back out of the segment that matched. None of them backtrack in more than linear time, and `test/regexp_linearity_test.rb` fails the build if someone adds one that does. That is a property of the patterns rather than a guarantee about the runtime, so a middleware puts a ceiling under it:

```ruby
use Paquette::RegexpTimeout               # 0.25s, per match
use Paquette::RegexpTimeout, seconds: 0.05
```

A match that runs out of time becomes a `400`. Two things to know before tuning the number: `Regexp.timeout` is per match rather than per request, and it is process-global rather than per-thread — which is why the middleware counts requests rather than setting and restoring around each one. On Ruby 3.1, which has no `Regexp.timeout`, it stands aside.

Per match is not per request, and the route table holds a dozen or more of them, so `Routes#match` carries a budget of its own. Between candidates is the only point the router gets control back from the regexp engine, so that is where the clock is checked; running past it raises `Routes::MatchBudgetExceeded` and the server answers `400`. Total matching therefore costs the budget plus at most one timeout, and stays there as routes are added:

```ruby
Paquette::Routes.draw(match_budget: 0.1) { |r| ... }
```

The two are not redundant. The budget bounds route matching; the middleware's ceiling is what covers the patterns the handlers run afterwards on the segment that matched, and Rack's own parsing.

## Instrumentation

Everything expensive in Paquette is wrapped in a [Measurometer](https://github.com/julik/measurometer) block: the whole-corpus index renders, the tarball and gem reads under them, personalization repacks and their cache hits and misses, and the entitler a gated repository calls once per package.

Measurometer does nothing until a driver is attached, and adding one is the whole setup — it is API-compatible with Appsignal, so that is usually a single line in an initializer:

```ruby
Measurometer.drivers << Appsignal
```

The metric paths are namespaced by layer, so a slow request can be attributed without reading the code:

| Path | What it covers |
| --- | --- |
| `paquette.gem_server.*` / `paquette.npm_server.*` | Request dispatch and the work behind each endpoint |
| `paquette.route.GET /info/:gem_name` | One span per route, named by the pattern rather than the path |
| `paquette.gem_repository.*` / `paquette.npm_repository.*` | Directory listings, spec reads, publishes and yanks |
| `paquette.gem_personalizer.*` / `paquette.npm_personalizer.*` | Per-licensee repacks, plus `cache_hit` / `cache_miss` counters |
| `paquette.gem_repacker.*` / `paquette.npm_repacker.*` | The stages of a repack — unpack, rewrite, rebuild |
| `paquette.tarball.*` | Inflate, deflate, tar walk and the SHA1/SHA512 integrity pass |
| `paquette.gem_read_gate.entitled` / `paquette.npm_read_gate.entitled` | Your entitler block, which a listing calls once per package |
| `paquette.token_authorization.authenticate` | Your token lookup, which runs before anything else on every request |

Two numbers are worth a dashboard from the start. `paquette.gem_repository.sidecar_hit` against `sidecar_miss` says whether the compact index is being served from its cache or re-derived from the gems themselves, and the personalizer's `cache_hit` against `cache_miss` says the same for repacked tarballs — a miss rate that does not fall after warmup means something is invalidating the cache on every request.

## Running the tests

```bash
bundle exec rake test
```

Most of it is ordinary Ruby, but two parts drive real tooling, because a package registry that only ever answers its own test suite can be perfectly self-consistent and still serve something no client will accept:

- `test/npm_server/npm_install_test.rb` runs the **npm CLI** on this machine against a Paquette booted on a loopback port.
- `test/npm_server/docker_client_test.rb` runs npm **inside a container** (`test/docker/Dockerfile`) talking to a Paquette on the host through `host.docker.internal`. Nothing of Paquette's is in that container — it installs, verifies integrity, publishes and unpublishes the way a customer's machine would.

Both skip themselves when node or docker is missing. That is convenient locally and dangerous in CI, where a skip looks exactly like a pass, so the workflow sets `PAQUETTE_REQUIRE_NPM=1` and `PAQUETTE_REQUIRE_DOCKER=1` — with those set, missing tooling fails the run instead of quietly removing the coverage.

## License

Paquette is offered under the terms of the [O'Sassy license](https://osaasy.dev/) - basically, don't make it into your own product. Use it to sell your libraries. And godspeed!
