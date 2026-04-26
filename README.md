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

Because the wrappers are plain Ruby objects composed at the call site, per-user state (the `user` variable) is captured by ordinary closures. Drop a wrapper to disable that layer; add another by slotting in one more constructor. Whether the server will accept pushes and yanks is decided by what you build — wrap the base repo in `ReadGatedRepository` and writes are blocked; hand the server a bare `DirectoryGemRepository` (or your own wrapper that permits writes) and they go through.

The server will run on `http://localhost:9292` by default. Note that the NPM registry and the Rubygems registry have to live on separate domains - so they will respond on whichever domain is passed in that has `gems.` or `npm.` as first subdomain. If your OS supports `.localhost` TLDs, you can access `gems.whatever.localhost:9292` and it will respond.

## Usage for gems

Paquette contains a gem server. This is a separate Rack app which you can use without the NPM server, for example - inside of your Rails app. You can interact with it using `gem` commands, as if it were any other gem server, or by just placing stuff on the filesystem.

### Publishing gems into Paquette

You can publish gems two ways. 

1. Place `.gem` files in the `gems/` directory. The filename should follow the format: `gemname-version.gem`
2. Actually do a `gem push` - from your shell, do `gem push --host http://gems.localhost:9292 pkg/your-gem-0.1.0.gem` 

Note that Paquette will use whichever auth you wrap it with - that is to say, in the default dev setup - _none._ I told you it is slightly unhinged.

### Consuming gems provided by a Paquette server

To install gems from Paquette, set it as source in your Gemfile - and provide auth for whichever auth mechanism you wrap it with:

```ruby
gem "private_algos", source: "https://tok_998218907784:x-oauth-basic@gems.paquette.acme.com"
```

### API Endpoints

- `GET /` - Repository info
- `GET /api/v1/dependencies` - Gem dependencies
- `GET /api/v1/versions` - Available gem versions
- `GET /api/v1/names` - Available gem names
- `GET /api/v1/search.json` - Search gems
- `GET /gems/{gemname-version.gem}` - Download gem file
- `POST /api/v1/gems` - Upload gem (basic implementation)

## License

Paquette is offered under the terms of the [O'Sassy license](https://osaasy.dev/) - basically, don't make it into your own product. Use it to sell your libraries. And godspeed!
