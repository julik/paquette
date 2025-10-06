require_relative "test_helper"

class CompactIndexTest < RackIntegrationTest
  def test_compact_names_endpoint
    get "/names"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    names = last_response.body.split("\n")
    assert_includes names, "test-gem"
    assert_includes names, "another-gem"
  end

  def test_compact_versions_endpoint
    get "/versions"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    versions = last_response.body.split("\n")
    assert_includes versions, "test-gem 1.0.0"
    assert_includes versions, "another-gem 2.1.0"
  end

  def test_compact_info_endpoint
    get "/info/test-gem"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    info = last_response.body.split("\n")
    assert_equal 1, info.length
    assert_equal "test-gem,1.0.0,ruby,", info[0]
  end

  def test_compact_info_nonexistent_gem
    get "/info/nonexistent-gem"
    assert_equal 404, last_response.status
    assert_equal "Not Found", last_response.body
  end

  def test_compact_info_scoped_gem
    get "/info/another-gem"
    assert_equal 200, last_response.status
    assert_equal "text/plain", last_response.content_type

    info = last_response.body.split("\n")
    assert_equal 1, info.length
    assert_equal "another-gem,2.1.0,ruby,", info[0]
  end
end
