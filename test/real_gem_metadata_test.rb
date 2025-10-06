require "minitest/autorun"
require "rack/test"
require_relative "../lib/paquette"

class RealGemMetadataTest < Minitest::Test
  include Rack::Test::Methods

  def setup
    # Use the real gems directory for this test
    @app = Paquette::GemServer.new(File.expand_path("../gems", __dir__))
  end

  attr_reader :app

  def test_zip_kit_metadata
    get "/api/v1/versions"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    data = JSON.parse(last_response.body)
    zip_kit_versions = data.select { |v| v["name"] == "zip_kit" }

    assert_equal 3, zip_kit_versions.length, "Should have 3 zip_kit versions"

    # Check that we have the expected versions
    version_numbers = zip_kit_versions.map { |v| v["number"] }
    assert_includes version_numbers, "6.2.0"
    assert_includes version_numbers, "6.2.1"
    assert_includes version_numbers, "6.3.2"

    # Check metadata for the first version
    first_version = zip_kit_versions.first
    assert_equal "zip_kit", first_version["name"]
    assert_equal "ruby", first_version["platform"]

    # Check authors
    expected_authors = [
      "Julik Tarkhanov",
      "Noah Berman",
      "Dmitry Tymchuk",
      "David Bosveld",
      "Felix Bünemann"
    ]
    assert_equal expected_authors, first_version["authors"]

    # Check description and summary
    assert_equal "Stream out ZIP files from Ruby. Successor to zip_tricks.", first_version["description"]
    assert_equal "Stream out ZIP files from Ruby. Successor to zip_tricks.", first_version["summary"]
    assert_equal "Stream out ZIP files from Ruby. Successor to zip_tricks.", first_version["info"]

    # Check homepage
    assert_equal "https://github.com/julik/zip_kit", first_version["homepage"]

    # Check metadata
    assert first_version["metadata"].is_a?(Hash)
    assert first_version["metadata"]["allowed_push_host"] == "https://rubygems.org"
  end

  def test_scatter_gather_metadata
    get "/api/v1/versions"
    assert_equal 200, last_response.status

    data = JSON.parse(last_response.body)
    scatter_gather_versions = data.select { |v| v["name"] == "scatter_gather" }

    assert_equal 2, scatter_gather_versions.length, "Should have 2 scatter_gather versions"

    # Check that we have the expected versions
    version_numbers = scatter_gather_versions.map { |v| v["number"] }
    assert_includes version_numbers, "0.1.0"
    assert_includes version_numbers, "0.1.1"

    # Check metadata for version 0.1.0
    version_010 = scatter_gather_versions.find { |v| v["number"] == "0.1.0" }
    assert_equal "scatter_gather", version_010["name"]
    assert_equal "ruby", version_010["platform"]

    # Check authors
    assert_equal ["Julik Tarkhanov"], version_010["authors"]

    # Check description and summary
    assert_equal "Step workflows for Rails/ActiveRecord", version_010["description"]
    assert_equal "Effortless step workflows that embed nicely inside Rails", version_010["summary"]
    assert_equal "Step workflows for Rails/ActiveRecord", version_010["info"]

    # Check homepage
    assert_equal "https://scattergather.dev", version_010["homepage"]

    # Check metadata
    assert version_010["metadata"].is_a?(Hash)
    assert version_010["metadata"]["homepage_uri"] == "https://scattergather.dev"
    assert version_010["metadata"]["source_code_uri"] == "https://github.com/julik/scatter_gather"

    # Check metadata for version 0.1.1
    version_011 = scatter_gather_versions.find { |v| v["number"] == "0.1.1" }
    assert_equal "Scatter-gather for ActiveJob allowing batching", version_011["description"]
    assert_equal "Scatter-gather for ActiveJob", version_011["summary"]
    assert_equal "https://github.com/julik/scatter_gather", version_011["homepage"]
  end

  def test_metadata_consistency
    get "/api/v1/versions"
    assert_equal 200, last_response.status

    data = JSON.parse(last_response.body)

    # All entries should have required fields
    data.each do |version|
      assert version["name"].is_a?(String), "Name should be a string"
      assert version["number"].is_a?(String), "Number should be a string"
      assert version["platform"].is_a?(String), "Platform should be a string"
      assert version["authors"].is_a?(Array), "Authors should be an array"
      assert version["description"].is_a?(String), "Description should be a string"
      assert version["summary"].is_a?(String), "Summary should be a string"
      assert version["homepage"].is_a?(String), "Homepage should be a string"
      assert version["metadata"].is_a?(Hash), "Metadata should be a hash"

      # Authors should not be empty for real gems
      unless version["name"] == "test-gem"
        assert version["authors"].any?, "Authors should not be empty for real gems"
      end
    end
  end
end
