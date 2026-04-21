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
