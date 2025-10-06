require_relative "test_helper"

class DependencyExtractionTest < RackIntegrationTest
  def test_dependencies_endpoint_returns_correct_format
    # Test that the dependencies endpoint returns the correct format
    get "/api/v1/dependencies?gems=test-gem"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type

    dependencies = JSON.parse(last_response.body)
    assert_equal 1, dependencies.length

    test_gem = dependencies.first
    assert_equal "test-gem", test_gem["name"]
    assert_equal "1.0.0", test_gem["number"]
    assert_equal "ruby", test_gem["platform"]
    assert_equal [], test_gem["dependencies"] # test-gem has no dependencies
  end

  def test_dependencies_endpoint_with_multiple_gems
    # Test dependencies endpoint with multiple gems
    get "/api/v1/dependencies?gems=test-gem,zip_kit"
    assert_equal 200, last_response.status

    dependencies = JSON.parse(last_response.body)
    assert_equal 4, dependencies.length # test-gem (1) + zip_kit (3 versions)

    # Check that all gems are present
    gem_names = dependencies.map { |d| d["name"] }.uniq
    assert_includes gem_names, "test-gem"
    assert_includes gem_names, "zip_kit"

    # Check that all have correct structure
    dependencies.each do |dep|
      assert_includes dep.keys, "name"
      assert_includes dep.keys, "number"
      assert_includes dep.keys, "platform"
      assert_includes dep.keys, "dependencies"
      assert_equal "ruby", dep["platform"]
      assert dep["dependencies"].is_a?(Array)
    end
  end

  def test_dependencies_endpoint_with_nonexistent_gem
    # Test dependencies endpoint with nonexistent gem
    get "/api/v1/dependencies?gems=nonexistent-gem"
    assert_equal 200, last_response.status

    dependencies = JSON.parse(last_response.body)
    assert_equal [], dependencies
  end

  def test_dependencies_endpoint_without_gems_parameter
    # Test dependencies endpoint without gems parameter
    get "/api/v1/dependencies"
    assert_equal 200, last_response.status

    dependencies = JSON.parse(last_response.body)
    assert_equal 4, dependencies.length # All gems in the repository
  end
end
