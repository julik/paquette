#!/usr/bin/env ruby

# This script demonstrates how to use Paquette as a RubyGems repository
# Run this after starting the Paquette server

require 'net/http'
require 'json'
require 'uri'

def test_repository(base_url = 'http://localhost:9292')
  puts "Testing Paquette repository at #{base_url}"
  puts "=" * 50
  
  # Test 1: Check if repository is accessible
  begin
    response = Net::HTTP.get_response(URI("#{base_url}/"))
    if response.code == '200'
      puts "✓ Repository is accessible: #{response.body}"
    else
      puts "✗ Repository not accessible: #{response.code}"
      return false
    end
  rescue => e
    puts "✗ Cannot connect to repository: #{e.message}"
    return false
  end
  
  # Test 2: Check available gems
  begin
    response = Net::HTTP.get_response(URI("#{base_url}/api/v1/names"))
    if response.code == '200'
      gems = JSON.parse(response.body)
      puts "✓ Available gems: #{gems.join(', ')}"
    else
      puts "✗ Cannot fetch gem names: #{response.code}"
    end
  rescue => e
    puts "✗ Error fetching gem names: #{e.message}"
  end
  
  # Test 3: Check gem versions
  begin
    response = Net::HTTP.get_response(URI("#{base_url}/api/v1/versions"))
    if response.code == '200'
      versions = JSON.parse(response.body)
      puts "✓ Available versions:"
      versions.each do |gem|
        puts "  - #{gem['name']} #{gem['number']} (#{gem['platform']})"
      end
    else
      puts "✗ Cannot fetch gem versions: #{response.code}"
    end
  rescue => e
    puts "✗ Error fetching gem versions: #{e.message}"
  end
  
  # Test 4: Check dependencies endpoint (what Bundler uses)
  begin
    uri = URI("#{base_url}/api/v1/dependencies")
    uri.query = URI.encode_www_form(gems: ['test-gem'])
    response = Net::HTTP.get_response(uri)
    if response.code == '200'
      dependencies = JSON.parse(response.body)
      puts "✓ Dependencies endpoint works:"
      dependencies.each do |dep|
        puts "  - #{dep['name']} #{dep['number']} (#{dep['platform']})"
      end
    else
      puts "✗ Cannot fetch dependencies: #{response.code}"
    end
  rescue => e
    puts "✗ Error fetching dependencies: #{e.message}"
  end
  
  # Test 5: Check specs endpoint (what Bundler uses)
  begin
    response = Net::HTTP.get_response(URI("#{base_url}/specs.4.8"))
    if response.code == '200'
      specs = response.body.split("\n")
      puts "✓ Specs endpoint works:"
      specs.each do |spec|
        puts "  - #{spec}"
      end
    else
      puts "✗ Cannot fetch specs: #{response.code}"
    end
  rescue => e
    puts "✗ Error fetching specs: #{e.message}"
  end
  
  puts "\n" + "=" * 50
  puts "To use this repository with Bundler, add this to your Gemfile:"
  puts "source '#{base_url}'"
  puts "\nOr as an additional source:"
  puts "source 'https://rubygems.org'"
  puts "source '#{base_url}'"
  puts "\nThen run: bundle install"
  
  true
end

if __FILE__ == $0
  test_repository
end
