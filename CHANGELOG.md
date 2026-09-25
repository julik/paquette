## Unreleased

- Report a platform gem's real platform, with a bare version beside it, in `/specs.4.8`, `/latest_specs.4.8`, the dependency API, `/api/v1/versions` and search — all five used to advertise `nokogiri-1.16.0-java` as version `"1.16.0-java"` on platform `"ruby"`, which is a version no client can resolve on a platform that is not the gem's
- Carry a `Gem::Version` rather than a String in the legacy Marshal indexes, as rubygems.org does — `Gem::SpecFetcher` sorts what it unmarshals, and Strings sort `1.10.0` below `1.9.0`
- Name the latest version of each gem per *platform* in `/latest_specs.4.8`, so a java or arm64-darwin build is not hidden behind the plain-ruby one
- Serve `/api/v1/dependencies` and `/api/v1/dependencies.json`, which were documented and implemented but had no route; the unsuffixed one answers Marshal, the way Bundler's legacy fallback reads it
- Report the gem's own authors, summary and platform from `/api/v1/search.json` instead of the placeholders it used to send for every gem
- Serve `/prerelease_specs.4.8` and `/prerelease_specs.4.8.gz`, which `gem install --pre` and mirroring tools fetch and which used to 404
- Keep prereleases out of `/specs.4.8` and `/latest_specs.4.8`, which used to list them alongside releases, so a gem with only prereleases no longer has a "latest" release
- Serve conditional GETs on `/versions`, `/names` and `/info/`, with a 304 skipping the compact index render entirely
- Derive HTTP cache validators from the whole repository wrapper stack, and emit none at all when a layer cannot describe itself
- Never answer a request carrying `Authorization` or a `Cookie`, or one served through a gate or a personalizer, with `Cache-Control: public`, so a shared cache in front cannot replay an authorized download or index to a caller the embedder's gate would have refused; everything else caller-specific is `private` with `Vary: Authorization, Cookie, Accept-Encoding` (security)
- Answer anonymous requests over an ungated, unpersonalized repository `public`, so a CDN can cache an open registry, and add `shared_caching: false` to both servers for embedders who authorize by IP, mTLS or a header Paquette cannot see
- Add `gate_key:` to both `ReadGatedRepository` classes, the caller-supplied name a gate needs before it may be cached
- Add `cache_validator`, `varies_by_caller?` and `gem_checksum` to the repository protocols
- Serve `.gem` downloads and npm tarballs as immutable, with an `ETag`, `Last-Modified` and `Range` support on Rack's own file serving
- Answer conditional GETs on npm packuments and dist-tags, and never store `/-/whoami`
- Fold each `dist-tags.json` mtime into the npm fingerprint as whole nanoseconds rather than a float
- Document what rack-cache or Rails' Rack::Cache in front of a Paquette server does and does not store
- Serve only absolute http(s) URLs for `homepage` and the `*_uri` gemspec metadata keys, and for the npm packument `homepage`
- Name each gem's `required_rubygems_version` in the compact index, and bump the sidecar cache format so warm caches re-derive it
- Accept every version RubyGems publishes, not just three-segment ones — a gem pushed at `0.2` or `0.17` used to be written to disk and then served to nobody
- Add `CooldownRepository`, a wrapper serving only versions published longer than a configured interval ago
- Give `CooldownRepository` a cache validator that moves only when a version cools, a push or yank lands, or the interval changes, so its index documents can answer 304; a custom `published_at:` gets one only with `published_at_validator:`
- Validate a pushed gemspec before acting on it, closing an arbitrary file write through `spec.name` (security)
- Refuse newlines and NUL bytes in every spec field the compact index interpolates, so a push cannot forge an index row
- Refuse any pushed gemspec field longer than 2KB
- Validate the npm package version, which reached the filesystem as a path component the same way
- Parse an uploaded gemspec with YAML alias expansion disabled
- Stream a gem push to disk instead of buffering it in memory, and cap it with `max_push_bytes:`

## 0.2.0

- Repack gems in-process instead of shelling out to the `gem` binary
- Serve correctly when Paquette is mounted under a path prefix
- Autoload the library and namespace it with flat identifiers
- Arm the regexp backtracking ceiling from inside the apps instead of a middleware
- Extract `ReadonlyRepository` out of `ReadGatedRepository`
- Add `bin/dev`, a read-write gem-only server backed by `tmp/gems`
- Add an HTML placeholder page for repository roots
- Verify publishing OTPs, with each server owning its own dialect
- Add repository fingerprints, route recognition, and selective personalization
- Add per-request timing instrumentation, and return 400 for bodies that could not be parsed
- Add a full NPM registry: metadata, tarball serving, publishing, read gating, and licensee personalization
- Verify npm parity against a real npm client installing from and publishing to Paquette
- Make repacked gems and written tarballs byte-reproducible
- Have the compact index name each gem's dependencies, and make `/versions` checksum what `/info/` returns
- Build gem info lines from sidecar metadata instead of re-parsing each gem
- Stop the personalizer from deleting directories it did not create
- Add the `TokenAuthorization` Rack middleware
- Add a guide for hosting Paquette inside a Rails app
- Add a GitHub Actions CI workflow

## 0.1.0

- First packaged release: gem repository serving the compact index, `/info/`, `/versions`, and gem downloads
- Add the RubyGems push and yank endpoints
- Add read gating so a licensee is only ever handed their own packages
- Add the gem repacker and personalizer, injecting licensee metadata into the gemspec
- Route with Mustermann on top of the minuscule app framework
- Ship the gemspec for gem distribution
