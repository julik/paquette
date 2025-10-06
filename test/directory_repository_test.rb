require "minitest/autorun"
require_relative "../lib/paquette"

class DirectoryRepositoryTest < Minitest::Test
  def setup
    @gems_dir = File.expand_path("./gems", Dir.pwd)
    @repository = Paquette::DirectoryRepository.new(@gems_dir)
  end

  def test_gem_names
    names = @repository.gem_names
    assert_includes names, "scatter_gather"
    assert_includes names, "test-gem"
    assert_includes names, "zip_kit"
    assert_equal 3, names.length
  end

  def test_gem_versions
    versions = @repository.gem_versions
    assert versions.length >= 6 # Total number of gem files

    # Check for scatter_gather versions
    scatter_versions = versions.slice("scatter_gather")
    assert_equal 2, scatter_versions.length
    assert_includes scatter_versions.map { |_, v| v }, "0.1.0"
    assert_includes scatter_versions.map { |_, v| v }, "0.1.1"

    # Check for zip_kit versions
    zip_kit_versions = versions.slice("zip_kit")
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.0"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.2.1"
    assert_includes zip_kit_versions.map { |_, v| v }, "6.3.2"
  end

  def test_versions_for_gem
    scatter_versions = @repository.versions_for_gem("scatter_gather")
    assert_equal 2, scatter_versions.length
    assert_includes scatter_versions, "0.1.0"
    assert_includes scatter_versions, "0.1.1"

    zip_kit_versions = @repository.versions_for_gem("zip_kit")
    assert_equal 3, zip_kit_versions.length
    assert_includes zip_kit_versions, "6.2.0"
    assert_includes zip_kit_versions, "6.2.1"
    assert_includes zip_kit_versions, "6.3.2"

    test_gem_versions = @repository.versions_for_gem("test-gem")
    assert_equal 1, test_gem_versions.length
    assert_includes test_gem_versions, "1.0.0"
  end

  def test_gem_exists
    assert @repository.gem_exists?("scatter_gather", "0.1.0")
    assert @repository.gem_exists?("scatter_gather", "0.1.1")
    assert @repository.gem_exists?("zip_kit", "6.2.0")
    assert @repository.gem_exists?("test-gem", "1.0.0")

    refute @repository.gem_exists?("scatter_gather", "0.2.0")
    refute @repository.gem_exists?("nonexistent", "1.0.0")
  end

  def test_gem_file_path
    expected_path = File.join(@gems_dir, "scatter_gather-0.1.0.gem")
    assert_equal expected_path, @repository.gem_file_path("scatter_gather", "0.1.0")

    expected_path = File.join(@gems_dir, "zip_kit-6.3.2.gem")
    assert_equal expected_path, @repository.gem_file_path("zip_kit", "6.3.2")
  end

  def test_gem_spec
    spec = @repository.gem_spec("test-gem", "1.0.0")
    refute_nil spec
    assert_equal "test-gem", spec.name
    assert_equal "1.0.0", spec.version.to_s

    spec = @repository.gem_spec("scatter_gather", "0.1.1")
    refute_nil spec
    assert_equal "scatter_gather", spec.name
    assert_equal "0.1.1", spec.version.to_s

    # Test non-existent gem
    spec = @repository.gem_spec("nonexistent", "1.0.0")
    assert_nil spec
  end

  def test_gem_dependencies
    deps = @repository.gem_dependencies("test-gem", "1.0.0")
    assert deps.is_a?(Array)
    # The actual dependencies depend on what's in the test-gem.gem file

    deps = @repository.gem_dependencies("scatter_gather", "0.1.1")
    assert deps.is_a?(Array)
    # The actual dependencies depend on what's in the scatter_gather-0.1.1.gem file

    # Test non-existent gem
    deps = @repository.gem_dependencies("nonexistent", "1.0.0")
    assert_equal [], deps
  end

  def test_compact_info
    info = @repository.compact_info("scatter_gather")
    assert info.is_a?(Array)
    assert_equal 2, info.length
    assert_includes info, "scatter_gather,0.1.0,ruby,"
    assert_includes info, "scatter_gather,0.1.1,ruby,"

    info = @repository.compact_info("test-gem")
    assert info.is_a?(Array)
    assert_equal 1, info.length
    assert_includes info, "test-gem,1.0.0,ruby,"

    # Test non-existent gem
    info = @repository.compact_info("nonexistent")
    assert_equal [], info
  end
end
