# Hosting Paquette inside a Rails application

Paquette is a plain Rack application, which makes it straightforward to embed inside a Rails app. This is a natural fit when the Rails app already manages users, subscriptions, or entitlements that should control access to packages.

## Mounting in routes.rb

The simplest approach is to mount Paquette as a Rack app in your Rails routes:

```ruby
# config/routes.rb

# One instance per request, built by the server from the token. Everything
# the token resolves to is looked up once and remembered on it.
class GemAuthenticator < Paquette::Authenticator
  def user = @user ||= token && User.find_by(api_key: token)

  def read_permitted? = !user.nil?

  def write_permitted? = !!user&.publisher?

  def check_otp!(code) = Paquette::Totp.verify!(user.totp_secret, code)

  # Which gems this caller sees. A publisher sees everything
  def entitled?(name:, version: nil) = user.publisher? || user.entitlements.exists?(gem_name: name)

  # For Paquette::ResponseCache, if one sits in front
  def identity = user.cache_key
end

gems_repo = Paquette::GemServer::DirectoryGemRepository.new(Rails.root.join("packages/gems").to_s)
gem_server = Paquette::GemServer.new(gems_repo, authenticator: GemAuthenticator)

Rails.application.routes.draw do
  constraints(->(req) { req.host.start_with?("gem.") }) do
    mount gem_server, at: "/"
  end
end
```

The server reads the token however the client sent it - Bundler puts it in Basic auth, `gem push` sends it bare - and hands it to `GemAuthenticator.new`. Every push and yank has to carry a one-time password. See [Authentication](../MANUAL.md#authentication).

The repository and the server are built once and shared across requests. What is per-caller - the authenticator, and the gate the server puts around the repository when the authenticator answers `entitled?` - is built per request, which is cheap.

## Rails execution context

When you use `mount` in `routes.rb`, your Rack app runs inside the full Rails middleware stack. The Rails router sits at the bottom of that stack, so by the time your app receives `call`, the `ActionDispatch::Executor` has already wrapped the request. This gives you:

- **ActiveRecord connection management** — connections are checked out and returned to the pool correctly, and the query cache is active.
- **Code reloading** — the reloader is engaged in development, so changes to your app code are picked up without restarting the server.
- **`CurrentAttributes` reset** — `ActiveSupport::CurrentAttributes` instances are cleared at the start of each request, just as they would be for a normal controller action.

In short, mounting via `routes.rb` gives you the same execution context as any Rails controller action, minus the `ActionController` layer itself. You are free to use ActiveRecord and any other framework facility that depends on the executor from inside your authenticator.

## Who the caller was, after the request

The authenticator the server built is left in `env["paquette.authenticator"]`, so an `on_publish:` hook, which gets the `Rack::Request`, can read `request.env["paquette.authenticator"].user` to record who published - and a log line can say who was served.

## Mounting outside of Rails routes

If for some reason you mount Paquette in `config.ru` before the Rails application, the request will not pass through the Rails middleware stack. In that case ActiveRecord connections will leak. You would need to wrap the call yourself:

```ruby
gem_app = ->(env) {
  Rails.application.executor.wrap { gem_server.call(env) }
}
```

Prefer mounting in `routes.rb` to avoid this entirely.
