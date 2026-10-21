<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/paquette-wordmark-logo-on-dark.png">
  <img src="img/paquette-wordmark-logo.png" alt="Paquette" width="420">
</picture>

Paquette is a (slightly unhinged) Rack-based server for libraries. At the moment it serves gems, NPM packages and Python packages. It is designed to be small and embeddable in other Ruby web applications. You allocate a directory with packages and expose it through Paquette, all the while bringing your own authentication, limits, filtering and entitlements.

In essence, it is a gem/NPM/PyPI server for distributing commercial packages. I use
it for https://shop.stanquette.nl and it is pretty neat!

Things are somewhat in flux but Paquette is usable alright.

This README shows the common case: each server gated to what a license covers, with every package personalized for its licensee. The [MANUAL](MANUAL.md) has everything else.

## Installation

```ruby
gem "paquette"
```

To kick the tyres, `bundle install` and start `bin/dev`. It serves `packages/` wide open on `gem.localhost:9292`, `npm.localhost:9292` and `pypi.localhost:9292`.

## How it fits together

- A **repository** is your packages - the basic one is a directory.
- **Wrappers** go around a repository and change what a caller gets: `ReadGatedRepository` decides which packages and versions they may see, `Personalizer` repacks each package for them.
- A **server** is a Rack app around the wrapped repository, plus an **authenticator** that says who may read and who may publish - see [Authentication](MANUAL.md#authentication).

Building a server is cheap, so you build the stack per request, for the license the token belongs to. A publisher gets the bare repository, since a gate would hide from them whatever no license covers. The examples below assume a `License` model and an `AUTHENTICATOR`.

## Gems

```ruby
GEMS = Paquette::GemServer::DirectoryGemRepository.new("packages/gems")

gem_app = ->(env) {
  token = Paquette::AuthToken.from_env(env)
  next Paquette::GemServer.new(GEMS, authenticator: AUTHENTICATOR).call(env) if AUTHENTICATOR.write_permitted?(auth_token: token)

  license = token && License.find_by(token: token)
  repo = Paquette::GemServer::ReadGatedRepository.new(GEMS, gate_key: license&.cache_key) do |name:, version: nil|
    license&.package_names&.include?(name)
  end
  if license
    repo = Paquette::GemServer::Personalizer.new(repo,
      license_key: license.key, # lands in the gemspec metadata as "paquette.license_key"
      magic_comment_replacements: {"# paquette_license_info" => "Licensed to #{license.holder_name}"},
      files: {"LICENSE.txt" => license.rendered_text})
  end
  Paquette::GemServer.new(repo, authenticator: AUTHENTICATOR).call(env)
}
```

A line that is exactly `# paquette_license_info` in any `.rb` file comes out as `# Licensed to Acme Inc`. Customers point Bundler at it:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.example.com"
```

## npm

```ruby
NPM = Paquette::NpmServer::DirectoryNpmRepository.new("packages/npm")

npm_app = ->(env) {
  token = Paquette::AuthToken.from_env(env)
  next Paquette::NpmServer.new(NPM, authenticator: AUTHENTICATOR).call(env) if AUTHENTICATOR.write_permitted?(auth_token: token)

  license = token && License.find_by(token: token)
  repo = Paquette::NpmServer::ReadGatedRepository.new(NPM, gate_key: license&.cache_key) do |name:, version: nil|
    license&.package_names&.include?(name) # scoped names arrive whole: "@acme/widgets"
  end
  if license
    repo = Paquette::NpmServer::Personalizer.new(repo,
      license_key: license.key, # lands in package.json as "paquette": {"licenseKey": ...}
      magic_comment_replacements: {"// paquette_license_info" => "Licensed to #{license.holder_name}"},
      files: {"LICENSE.txt" => license.rendered_text})
  end
  Paquette::NpmServer.new(repo, authenticator: AUTHENTICATOR).call(env)
}
```

A replacement has to stay on one line, so sourcemaps keep pointing at the right place. Customers point npm at it:

```
# .npmrc
@acme:registry=https://npm.example.com
//npm.example.com/:_authToken=tok_998218907784
```

## Python

```ruby
PYPI = Paquette::PypiServer::DirectoryPypiRepository.new("packages/pypi")

pypi_app = ->(env) {
  token = Paquette::AuthToken.from_env(env)
  next Paquette::PypiServer.new(PYPI, authenticator: AUTHENTICATOR).call(env) if AUTHENTICATOR.write_permitted?(auth_token: token)

  license = token && License.find_by(token: token)
  repo = Paquette::PypiServer::ReadGatedRepository.new(PYPI, gate_key: license&.cache_key) do |name:, version: nil|
    license&.package_names&.include?(name) # PEP 503 normalized: "acme-widgets"
  end
  if license
    repo = Paquette::PypiServer::Personalizer.new(repo,
      license_key: license.key, # lands in paquette.json in the .dist-info
      magic_comment_replacements: {"# paquette_license_info" => "Licensed to #{license.holder_name}"},
      files: {"acme_widgets/LICENSE.txt" => license.rendered_text}) # relative to site-packages
  end
  Paquette::PypiServer.new(repo, authenticator: AUTHENTICATOR).call(env)
}
```

Customers point pip (or uv, or Poetry) at it:

```
pip install acme-widgets --index-url https://__token__:tok_998218907784@pypi.example.com/simple/
```

## Serving all three

The registries need a hostname each. `SubdomainRouter` picks one by the first label of the host:

```ruby
run Paquette::SubdomainRouter.new { |router|
  router.map "gem", to: gem_app
  router.map "npm", to: npm_app
  router.map "pypi", to: pypi_app
}
```

In Rails, mount each under a host constraint instead - see [Hostnames and mounting](MANUAL.md#hostnames-and-mounting).

> [!IMPORTANT]
> Personalizing a package changes its checksum, and lockfiles remember checksums. If you change _how_ you personalize - another comment, another file - every licensee's package manager sees a package that changed under the same version. Pick a personalization and keep it, or tell your customers before you change it. See [Package personalization](MANUAL.md#package-personalization).

## Publishing

Drop files into the repository directory, or publish with the usual tools. The authenticator asks for a one-time password on every write:

```
gem push --host https://gem.example.com --otp 123456 pkg/private_algos-1.0.0.gem
npm publish --registry https://npm.example.com --otp 123456
twine upload --repository-url https://pypi.example.com/legacy/ -u 123456 -p TOKEN dist/*
```

twine has no OTP option, so the code goes in the username.

## Where to next

The [MANUAL](MANUAL.md) covers [authentication](MANUAL.md#authentication) and one-time passwords, the [cooldown](MANUAL.md#cooldown) wrapper, what each server stores on disk and which endpoints it answers, [running code after a publish](MANUAL.md#after-a-publish), [HTTP caching](MANUAL.md#http-caching) behind authentication, the [index page](MANUAL.md#the-index-page), [path-prefix namespaces](MANUAL.md#mounting-under-a-path-prefix-namespaces), [instrumentation](MANUAL.md#instrumentation) and [running the tests](MANUAL.md#running-the-tests).

## License

Paquette is offered under the terms of the [O'Saasy license](https://osaasy.dev/) - basically, **don't make it into your own product or a service.** Use it to sell your libraries. And godspeed!
