require_relative 'test_helper'

class RepositoryTest < RackIntegrationTest
  def setup
    super
    @repository = Paquette::DirectoryRepository.new(@test_gems_dir)
  end
  
  def test_gem_names
    names = @repository.gem_names
    assert_includes names, 'test-gem'
    assert_includes names, 'another-gem'
    assert_equal 2, names.length
  end
  
  def test_gem_versions
    versions = @repository.gem_versions
    assert_includes versions, ['test-gem', '1.0.0']
    assert_includes versions, ['another-gem', '2.1.0']
    assert_equal 2, versions.length
  end
  
  def test_versions_for_gem
    versions = @repository.versions_for_gem('test-gem')
    assert_equal ['1.0.0'], versions
    
    versions = @repository.versions_for_gem('another-gem')
    assert_equal ['2.1.0'], versions
    
    versions = @repository.versions_for_gem('nonexistent')
    assert_equal [], versions
  end
  
  def test_gem_file_path
    path = @repository.gem_file_path('test-gem', '1.0.0')
    expected = File.join(@test_gems_dir, 'test-gem-1.0.0.gem')
    assert_equal expected, path
  end
  
  def test_gem_exists
    assert @repository.gem_exists?('test-gem', '1.0.0')
    assert @repository.gem_exists?('another-gem', '2.1.0')
    refute @repository.gem_exists?('test-gem', '2.0.0')
    refute @repository.gem_exists?('nonexistent', '1.0.0')
  end
  
  def test_gem_spec
    spec = @repository.gem_spec('test-gem', '1.0.0')
    assert_nil spec # Our test gems don't have proper specs
    
    spec = @repository.gem_spec('nonexistent', '1.0.0')
    assert_nil spec
  end
  
  def test_gem_dependencies
    deps = @repository.gem_dependencies('test-gem', '1.0.0')
    assert_equal [], deps # Our test gems have no dependencies
    
    deps = @repository.gem_dependencies('nonexistent', '1.0.0')
    assert_equal [], deps
  end
  
  def test_compact_info
    info = @repository.compact_info('test-gem')
    assert_equal ['test-gem,1.0.0,ruby,'], info
    
    info = @repository.compact_info('another-gem')
    assert_equal ['another-gem,2.1.0,ruby,'], info
    
    info = @repository.compact_info('nonexistent')
    assert_equal [], info
  end
end
