## Unreleased

- Serve conditional GETs on `/versions`, `/names` and `/info/`, with a 304 skipping the compact index render entirely
- Derive HTTP cache validators from the whole repository wrapper stack, and emit none at all when a layer cannot describe itself
- Mark gated and personalized responses `Cache-Control: private`, so a shared cache cannot replay one licensee's index to another
- Add `gate_key:` to both `ReadGatedRepository` classes, the caller-supplied name a gate needs before it may be cached
- Add `cache_validator`, `private_to_caller?` and `gem_checksum` to the repository protocols
- Serve `.gem` downloads and npm tarballs as immutable, with an `ETag`, `Last-Modified` and `Range` support on Rack's own file serving
- Answer conditional GETs on npm packuments and dist-tags, and never store `/-/whoami`
- Fold each `dist-tags.json` mtime into the npm fingerprint as whole nanoseconds rather than a float
- Document how to put rack-cache or Rails' Rack::Cache integration in front of a Paquette server
- Serve only absolute http(s) URLs for `homepage` and the `*_uri` gemspec metadata keys, and for the npm packument `homepage`
- Name each gem's `required_rubygems_version` in the compact index, and bump the sidecar cache format so warm caches re-derive it

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
