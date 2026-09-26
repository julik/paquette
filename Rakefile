require "bundler/gem_tasks"
require "rake/testtask"

# The default task is defined next to the YARD tasks below: it rebuilds
# the signature files before running tests when the :docs group is
# installed, and degrades to bare tests when it is not.

# Test task configuration. test/conformance is deliberately not in here: it
# shells out to the external gem_server_conformance RSpec CLI, which is a
# different kind of slow and a different kind of dependency from the rest.
# `rake test:conformance` runs it on its own.
Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/conformance/**/*_test.rb")
  t.verbose = true
  # No -w: the warnings that show up are rack's and rubygems', not ours, and
  # they bury the dots.
  t.warning = false
end

# Runs the RubyGems compact-index conformance suite against a live paquette.
# Kept out of the default :test run because it shells out; skips cleanly when
# the gem_server_conformance gem is not installed, unless
# PAQUETTE_REQUIRE_CONFORMANCE says the run must have it.
Rake::TestTask.new("test:conformance") do |t|
  t.libs << "test"
  t.test_files = FileList["test/conformance/**/*_test.rb"]
  t.verbose = true
  t.warning = false
end

# Standard tasks
require "standard/rake"

# YARD and sord are in the :docs Gemfile group; the doc tasks only exist
# when that group is installed.
begin
  require "yard"

  YARD::Rake::YardocTask.new(:yard) do |t|
    t.files = ["lib/**/*.rb"]
  end

  desc "Generate RBI signatures from YARD tags into rbi/paquette.rbi"
  task :rbi do
    mkdir_p "rbi"
    sh "bundle exec sord --no-sord-comments rbi/paquette.rbi"
  end

  desc "Generate RBS signatures from YARD tags into sig/paquette.rbs"
  task :rbs do
    mkdir_p "sig"
    sh "bundle exec sord --no-sord-comments sig/paquette.rbs"
  end

  desc "Generate docs and type signatures"
  task docs: [:yard, :rbi, :rbs]

  task default: [:rbi, :rbs, :test]
rescue LoadError
  task default: :test
end

# Clean task
task :clean do
  # Remove any temporary files if needed
  puts "Cleaning up..."
end

# Help task
desc "Show available tasks"
task :help do
  puts "Available tasks:"
  puts "  rake test        - Run all tests (default)"
  puts "  rake test:conformance - Run the RubyGems conformance suite against a live server"
  puts "  rake standard    - Check code style with Standard"
  puts "  rake standard:fix - Auto-fix code style issues"
  puts "  rake clean       - Clean up temporary files"
  puts "  rake help        - Show this help"
end
