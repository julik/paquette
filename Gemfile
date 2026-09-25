source "https://rubygems.org"

gemspec

gem "puma"

group :test do
  # The RubyGems compact-index conformance suite, an external RSpec CLI that
  # drives a live server over HTTP. Only `rake test:conformance` shells out to
  # it, and that test skips cleanly when the gem is absent.
  gem "gem_server_conformance"
  gem "minitest"
  # Minitest 6 extracted Mock and Object#stub into their own gem; 5.x still
  # bundles them. Depending on it explicitly works on both and keeps the
  # suite free to float forward.
  gem "minitest-mock"
  gem "minitest-parallel_fork", "~> 2.1"
  # The shared cache the README tells embedders to put in front, so the
  # suite can show it never replays one caller's response to another.
  gem "rack-cache"
  gem "rack-test"
  gem "rake"
  # Pinned, unlike everything else here. Floating the dependencies is how a
  # library finds out early that a release broke it — but a linter floating
  # forward does not report a break, it reports a new opinion, and it does so
  # on whatever branch happens to bundle next. standard pins rubocop to
  # ~> 1.88.0 in turn, so this pins the whole cop set.
  gem "standard", "~> 1.56.0"
end
