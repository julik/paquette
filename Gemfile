source "https://rubygems.org"

gemspec

gem "puma"

group :test do
  gem "minitest"
  # Minitest 6 extracted Mock and Object#stub into their own gem; 5.x still
  # bundles them. Depending on it explicitly works on both and keeps the
  # suite free to float forward.
  gem "minitest-mock"
  gem "minitest-parallel_fork", "~> 2.1"
  gem "rack-test"
  gem "rake"
  gem "standard"
end
