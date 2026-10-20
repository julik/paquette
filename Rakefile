require "bundler/gem_tasks"
require "rake/testtask"

# The default task is defined next to the type tasks below: it regenerates
# the signatures and runs Steep before the tests when the :types group is
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

# The types are written inline in lib/, as rbs-inline `#:` comments. `rake rbs`
# turns them into sig/generated, which is not committed: it ships with the gem
# (build generates it first), is what Steep checks lib/ against, and is where
# rdoc finds the types of attributes.
begin
  require "rbs/inline"

  desc "Generate sig/generated from the inline RBS annotations in lib/"
  task :rbs do
    rm_rf "sig/generated"
    sh "bundle exec rbs-inline --opt-out --output=sig/generated lib"
  end

  # Signatures for the dependencies, from gem_rbs_collection; fetched once.
  file ".gem_rbs_collection" do
    sh "bundle exec rbs collection install"
  end

  desc "Type-check lib/ with Steep"
  task steep: [:rbs, ".gem_rbs_collection"] do
    sh "bundle exec steep check"
  end

  task default: [:steep, :test]
  Rake::Task["build"].enhance([:rbs])
rescue LoadError
  task default: :test
end

# rdoc 8.1 renders the `#:` signatures under each method, and the sig/
# types under each attribute, so the docs are built from fresh signatures.
# An older rdoc - the default gem, when the :docs group is not installed -
# would build them without the types, so it gets no task at all.
begin
  require "rdoc/task"
  raise LoadError, "rdoc #{RDoc::VERSION} does not render RBS" if Gem::Version.new(RDoc::VERSION) < Gem::Version.new("8.1")
  require_relative "rakelib/gfm_markup"

  RDoc::Task.new(:rdoc) do |rd|
    rd.rdoc_dir = "doc"
    rd.title = "Paquette"
    rd.main = "README.md"
    # "markdown" is GitHub Flavored Markdown here: see rakelib/gfm_markup.rb.
    rd.markup = "markdown"
    rd.generator = "aliki"
    rd.options << "--template-stylesheets=rakelib/gfm.css"
    rd.rdoc_files.include("README.md", "CHANGELOG.md", "LICENSE.md", "docs/**/*.md", "lib/**/*.rb")
  end

  desc "Build the HTML docs into doc/, and open them when run from a terminal"
  task docs: [*(:rbs if Rake::Task.task_defined?(:rbs)), :rdoc] do
    index = File.expand_path("doc/index.html")
    puts "Docs are in #{index}"
    next unless $stdout.tty?

    opener = RUBY_PLATFORM.include?("darwin") ? "open" : "xdg-open"
    system(opener, index)
  end
rescue LoadError
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
  puts "  rake test        - Run all tests (default, after steep when available)"
  puts "  rake test:conformance - Run the RubyGems conformance suite against a live server"
  puts "  rake rbs         - Generate sig/generated from the inline signatures"
  puts "  rake steep       - Type-check lib/ with Steep"
  puts "  rake docs        - Build the HTML docs into doc/ and open them"
  puts "  rake standard    - Check code style with Standard"
  puts "  rake standard:fix - Auto-fix code style issues"
  puts "  rake clean       - Clean up temporary files"
  puts "  rake help        - Show this help"
end
