require "bundler/gem_tasks"
require "rake/testtask"

# Default task runs tests
task default: :test

# Test task configuration
Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end

# Standard tasks
require "standard/rake"

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
  puts "  rake standard    - Check code style with Standard"
  puts "  rake standard:fix - Auto-fix code style issues"
  puts "  rake clean       - Clean up temporary files"
  puts "  rake help        - Show this help"
end
