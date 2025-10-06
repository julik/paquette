# Paquette

A minimal RubyGems repository server built with Rack.

## Setup

1. Install dependencies:
   ```bash
   bundle install
   ```

2. Start the server:
   ```bash
   bundle exec puma
   ```

The server will run on `http://localhost:9292` by default.

## Usage

### Adding Gems

Place `.gem` files in the `gems/` directory. The filename should follow the format: `gemname-version.gem`

### Using with Bundler

Add this to your Gemfile:
```ruby
source 'http://localhost:9292'
```

Or configure it as an additional source:
```ruby
source 'https://rubygems.org'
source 'http://localhost:9292'
```

## API Endpoints

- `GET /` - Repository info
- `GET /api/v1/dependencies` - Gem dependencies
- `GET /api/v1/versions` - Available gem versions
- `GET /api/v1/names` - Available gem names
- `GET /api/v1/search.json` - Search gems
- `GET /gems/{gemname-version.gem}` - Download gem file
- `POST /api/v1/gems` - Upload gem (basic implementation)
