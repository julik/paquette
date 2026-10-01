# Hosting Paquette inside a Rails application

Paquette is a plain Rack application, which makes it straightforward to embed inside a Rails app. This is a natural fit when the Rails app already manages users, subscriptions, or entitlements that should control access to packages.

## Mounting in routes.rb

The simplest approach is to mount Paquette as a Rack app in your Rails routes:

```ruby
# config/routes.rb

gems_dir = Rails.root.join("packages/gems")
gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

class GemAuthenticator
  def initialize(repo)
    @repo = repo
  end

  def authenticate(token, request)
    Current.user = token && User.find_by(api_key: token)
    return nil unless Current.user

    gated = Paquette::GemServer::ReadGatedRepository.new(@repo, gate_key: Current.user.cache_key_with_version) do |name:, version: nil|
      Current.user.entitlements.exists?(gem_name: name)
    end
    Paquette::Access.new(repository: gated, otp_secret: Current.user.totp_secret)
  end
end

gem_app = Paquette::GemServer.new(authenticator: GemAuthenticator.new(gems_repo))

Rails.application.routes.draw do
  mount gem_app, at: "/gems"
end
```

The server reads the token however the client sent it - Bundler puts it in Basic auth, `gem push` sends it bare - and asks `authenticate` once per request. The access it returns names the repository stack that user is served from, and with an `otp_secret`, every push and yank has to carry a one-time password. See [Authentication](../README.md#authentication).

Everything here is built once and shared across requests: the `DirectoryGemRepository` just does file I/O, and the server keeps per-request state on a copy of itself. What is per-user - the `ReadGatedRepository` and the closure it holds - is built inside `authenticate`.

## Rails execution context

When you use `mount` in `routes.rb`, your Rack app runs inside the full Rails middleware stack. The Rails router sits at the bottom of that stack, so by the time your app receives `call`, the `ActionDispatch::Executor` has already wrapped the request. This gives you:

- **ActiveRecord connection management** — connections are checked out and returned to the pool correctly, and the query cache is active.
- **Code reloading** — the reloader is engaged in development, so changes to your app code are picked up without restarting the server.
- **`CurrentAttributes` reset** — `ActiveSupport::CurrentAttributes` instances are cleared at the start of each request, just as they would be for a normal controller action.

In short, mounting via `routes.rb` gives you the same execution context as any Rails controller action, minus the `ActionController` layer itself. You are free to use ActiveRecord, `Current`, and any other framework facility that depends on the executor.

## Setting up Current

Because the request does not pass through a Rails controller, `CurrentAttributes` will be reset but not populated — controllers typically set `Current` in a `before_action`. You need to set the attributes yourself - `authenticate` is a good place, as shown in the example above.

## Mounting outside of Rails routes

If for some reason you mount Paquette in `config.ru` before the Rails application, the request will not pass through the Rails middleware stack. In that case ActiveRecord connections will leak and `CurrentAttributes` will not be managed. You would need to wrap the call yourself:

```ruby
gem_app = ->(env) {
  Rails.application.executor.wrap do
    # safe to use ActiveRecord and Current here
  end
}
```

Prefer mounting in `routes.rb` to avoid this entirely.
