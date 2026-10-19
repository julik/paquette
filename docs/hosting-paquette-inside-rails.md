# Hosting Paquette inside a Rails application

Paquette is a plain Rack application, which makes it straightforward to embed inside a Rails app. This is a natural fit when the Rails app already manages users, subscriptions, or entitlements that should control access to packages.

## Mounting in routes.rb

The simplest approach is to mount Paquette as a Rack app in your Rails routes:

```ruby
# config/routes.rb

gems_dir = Rails.root.join("packages/gems")
gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir.to_s)

class GemAuthenticator
  def read_permitted?(auth_token:)
    !user_for(auth_token).nil?
  end

  def write_permitted?(auth_token:)
    !!user_for(auth_token)&.publisher?
  end

  def check_otp!(auth_token:, otp_code:)
    Paquette::Totp.verify!(user_for(auth_token).totp_secret, otp_code)
  end

  private

  # Asked up to three times per push - remember the answer for the request
  def user_for(token)
    return nil unless token
    return Current.user if Current.user&.api_key == token

    Current.user = User.find_by(api_key: token)
  end
end

authenticator = GemAuthenticator.new

gem_app = ->(env) {
  token = Paquette::AuthToken.from_env(env)
  user = token && User.find_by(api_key: token)
  repo = if user&.publisher?
    gems_repo
  else
    Paquette::GemServer::ReadGatedRepository.new(gems_repo, gate_key: user&.cache_key_with_version) do |name:, version: nil|
      user&.entitlements&.exists?(gem_name: name)
    end
  end
  Paquette::GemServer.new(repo, authenticator: authenticator).call(env)
}

Rails.application.routes.draw do
  mount gem_app, at: "/gems"
end
```

The server reads the token however the client sent it - Bundler puts it in Basic auth, `gem push` sends it bare - and `Paquette::AuthToken.from_env` reads it the same way, so the stack built here and the answers `GemAuthenticator` gives are about the same caller. Every push and yank has to carry a one-time password. See [Authentication](../README.md#authentication).

The `DirectoryGemRepository` and the authenticator are built once and shared across requests: the repository just does file I/O, and the authenticator keeps what it learns about a caller in `Current`. What is per-user - the `ReadGatedRepository` and the closure it holds - is built per request, and so is the server around it, which is cheap.

## Rails execution context

When you use `mount` in `routes.rb`, your Rack app runs inside the full Rails middleware stack. The Rails router sits at the bottom of that stack, so by the time your app receives `call`, the `ActionDispatch::Executor` has already wrapped the request. This gives you:

- **ActiveRecord connection management** — connections are checked out and returned to the pool correctly, and the query cache is active.
- **Code reloading** — the reloader is engaged in development, so changes to your app code are picked up without restarting the server.
- **`CurrentAttributes` reset** — `ActiveSupport::CurrentAttributes` instances are cleared at the start of each request, just as they would be for a normal controller action.

In short, mounting via `routes.rb` gives you the same execution context as any Rails controller action, minus the `ActionController` layer itself. You are free to use ActiveRecord, `Current`, and any other framework facility that depends on the executor.

## Setting up Current

Because the request does not pass through a Rails controller, `CurrentAttributes` will be reset but not populated — controllers typically set `Current` in a `before_action`. You need to set the attributes yourself - the authenticator is a good place, as shown in the example above.

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
