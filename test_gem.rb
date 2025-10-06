#!/usr/bin/env ruby

# Simple script to create a test gem for testing the repository
require 'fileutils'

# Create a minimal gem structure
gem_name = 'test-gem'
version = '1.0.0'
gem_dir = "tmp_#{gem_name}-#{version}"
gemspec_content = <<~GEMSPEC
  Gem::Specification.new do |s|
    s.name = '#{gem_name}'
    s.version = '#{version}'
    s.summary = 'A test gem for Paquette'
    s.description = 'This is a test gem to verify the Paquette repository works'
    s.authors = ['Test Author']
    s.email = ['test@example.com']
    s.files = Dir.glob('lib/**/*')
    s.require_paths = ['lib']
  end
GEMSPEC

FileUtils.mkdir_p("#{gem_dir}/lib")
File.write("#{gem_dir}/lib/test_gem.rb", "module TestGem\n  VERSION = '#{version}'\nend\n")
File.write("#{gem_dir}/#{gem_name}.gemspec", gemspec_content)

puts "Created test gem structure in #{gem_dir}"
puts "To build the gem, run: gem build #{gem_dir}/#{gem_name}.gemspec"
puts "Then copy the .gem file to the gems/ directory"
