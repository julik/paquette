# Hosting Paquette inside a Rails application

Paquette is a plain Rack application, which makes it straightforward to embed inside a Rails app. This is a natural fit when the Rails app already manages users, subscriptions, or entitlements that should control access to packages.

## Mounting in routes.rb

The simplest approach is to mount Paquette as a Rack app in your Rails routes:

```ruby
# config/routes.rb

gems_dir = Rails.root.join("packages/gems")
gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

gem_app = ->(env) {
  request = Rack::Request.new(env)
  Current.user = User.find_by(api_key: request.get_header("HTTP_AUTHORIZATION"))

  repo = if Current.user
    Paquette::GemServer::ReadGatedRepository.new(gems_repo) do |name:, version: nil|
      Current.user.entitlements.exists?(gem_name: name)
    end
  else
    Paquette::GemServer::ReadGatedRepository.new(gems_repo) { |**| false }
  end

  Paquette::GemServer.new(repo).call(env)
}

Rails.application.routes.draw do
  mount gem_app, at: "/gems"
end
```

Note that the `DirectoryGemRepository` is created once and shared across requests — it just does file I/O and is safe to reuse. The `ReadGatedRepository` wrapper and `GemServer` are built per-request so that user-specific state is captured in plain closures.

## Rails execution context

When you use `mount` in `routes.rb`, your Rack app runs inside the full Rails middleware stack. The Rails router sits at the bottom of that stack, so by the time your app receives `call`, the `ActionDispatch::Executor` has already wrapped the request. This gives you:

- **ActiveRecord connection management** — connections are checked out and returned to the pool correctly, and the query cache is active.
- **Code reloading** — the reloader is engaged in development, so changes to your app code are picked up without restarting the server.
- **`CurrentAttributes` reset** — `ActiveSupport::CurrentAttributes` instances are cleared at the start of each request, just as they would be for a normal controller action.

In short, mounting via `routes.rb` gives you the same execution context as any Rails controller action, minus the `ActionController` layer itself. You are free to use ActiveRecord, `Current`, and any other framework facility that depends on the executor.

## Setting up Current

Because the request does not pass through a Rails controller, `CurrentAttributes` will be reset but not populated — controllers typically set `Current` in a `before_action`. You need to set the attributes yourself before building the repository stack, as shown in the example above.

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
