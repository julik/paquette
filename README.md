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
- An **authenticator** is who is asking, one object per request built from the token: may they read, may they publish, which packages they see, what gets written into their copies. You write one class - see [Authentication](MANUAL.md#authentication).
- **Wrappers** go around a repository and change what a caller gets: the server gates on the authenticator's `entitled?`, and a `Personalizer` repacks each package with the values the authenticator gives.
- A **server** is a Rack app around the wrapped repository, built once.

The examples below assume a `License` model, and this authenticator:

```ruby
class AcmeAuthenticator < Paquette::Authenticator
  def license = @license ||= License.find_by(token: token) # once per request, for every question below

  def read_permitted? = !license.nil?
  def write_permitted? = !!license&.publisher?
  def check_otp!(code) = Paquette::Totp.verify!(license.totp_secret, code)
  def entitled?(name:, version: nil) = license.publisher? || license.package_names.include?(name)
  def personalization = {"licensee" => license.holder_name}
end
```

A publisher sees the whole repository ungated; everyone else sees what their license covers.

## Gems

```ruby
gems = Paquette::GemServer::DirectoryGemRepository.new("packages/gems")
gems = Paquette::GemServer::Personalizer.new(gems, files: {"LICENSE.txt" => File.read("license_template.txt")})
gem_server = Paquette::GemServer.new(gems, authenticator: AcmeAuthenticator)
```

A line that is exactly `# paquette:licensee` in any file of the gem comes out as `# Acme Inc`, the licensee lands in the gemspec metadata as `paquette.licensee`, and a gem with no marker in it goes out untouched. Customers point Bundler at it:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gem.example.com"
```

## npm

```ruby
npm = Paquette::NpmServer::DirectoryNpmRepository.new("packages/npm")
npm = Paquette::NpmServer::Personalizer.new(npm, files: {"LICENSE.txt" => File.read("license_template.txt")})
npm_server = Paquette::NpmServer.new(npm, authenticator: AcmeAuthenticator)
```

The marker is `// paquette:licensee`, and the values land in package.json under `"paquette"`. Scoped names reach `entitled?` whole: `"@acme/widgets"`. A marker line is replaced by one line, so sourcemaps keep pointing at the right place. Customers point npm at it:

```
# .npmrc
@acme:registry=https://npm.example.com
//npm.example.com/:_authToken=tok_998218907784
```

## Python

```ruby
pypi = Paquette::PypiServer::DirectoryPypiRepository.new("packages/pypi")
pypi = Paquette::PypiServer::Personalizer.new(pypi, files: {"acme_widgets/LICENSE.txt" => File.read("license_template.txt")}) # relative to site-packages
pypi_server = Paquette::PypiServer.new(pypi, authenticator: AcmeAuthenticator)
```

The marker is `# paquette:licensee`, the values land in `paquette.json` in the `.dist-info`, and `entitled?` gets the PEP 503 normalized name: `"acme-widgets"`. Customers point pip (or uv, or Poetry) at it:

```
pip install acme-widgets --index-url https://__token__:tok_998218907784@pypi.example.com/simple/
```

## Serving all three

The registries need a hostname each. `SubdomainRouter` picks one by the first label of the host:

```ruby
run Paquette::SubdomainRouter.new { |router|
  router.map "gem", to: gem_server
  router.map "npm", to: npm_server
  router.map "pypi", to: pypi_server
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
