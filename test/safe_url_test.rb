require_relative "test_helper"

class SafeUrlTest < Minitest::Test
  def test_keeps_ordinary_http_and_https_urls_byte_for_byte
    [
      "http://example.test",
      "https://example.test",
      "https://example.test/path/to/thing?query=1&other=2#fragment",
      "https://user:pass@example.test:8443/x",
      "HTTP://Example.test/"
    ].each do |url|
      assert_equal url, Paquette::SafeUrl.http_url(url), "expected #{url.inspect} to survive"
    end
  end

  # The whole point of the filter: `gem build` only warns about these, and
  # `npm publish` does not look at all.
  def test_refuses_script_bearing_schemes
    assert_nil Paquette::SafeUrl.http_url("javascript:alert(document.domain)")
    assert_nil Paquette::SafeUrl.http_url("JavaScript:alert(1)")
    assert_nil Paquette::SafeUrl.http_url("data:text/html;base64,PHNjcmlwdD4=")
    assert_nil Paquette::SafeUrl.http_url("vbscript:msgbox(1)")
  end

  def test_refuses_other_schemes
    assert_nil Paquette::SafeUrl.http_url("ftp://example.test/x")
    assert_nil Paquette::SafeUrl.http_url("mailto:someone@example.test")
    assert_nil Paquette::SafeUrl.http_url("git+ssh://git@example.test/x.git")
  end

  # Scheme-relative and relative values resolve against whatever page renders
  # them, so where they point cannot be read off the value itself.
  def test_refuses_relative_and_scheme_relative_urls
    assert_nil Paquette::SafeUrl.http_url("//evil.test/x")
    assert_nil Paquette::SafeUrl.http_url("/docs/index.html")
    assert_nil Paquette::SafeUrl.http_url("docs/index.html")
  end

  def test_refuses_http_urls_without_a_host
    assert_nil Paquette::SafeUrl.http_url("http:///x")
    assert_nil Paquette::SafeUrl.http_url("http://")
  end

  def test_refuses_empty_and_nil
    assert_nil Paquette::SafeUrl.http_url("")
    assert_nil Paquette::SafeUrl.http_url(nil)
  end

  # A gemspec field carries whatever bytes were published in it; URI's parser
  # raises on those rather than declining to match.
  def test_refuses_bytes_that_are_not_valid_utf8_without_raising
    assert_nil Paquette::SafeUrl.http_url("http://evil\xFF.test")
    assert_nil Paquette::SafeUrl.http_url("http://evil\xFF.test".b)
    assert_nil Paquette::SafeUrl.http_url((+"\xE2").force_encoding("UTF-8"))
    assert_nil Paquette::SafeUrl.http_url("\xFF\xFE".b)
  end

  def test_refuses_values_uri_cannot_parse_at_all_without_raising
    assert_nil Paquette::SafeUrl.http_url(" http://example.test")
    assert_nil Paquette::SafeUrl.http_url("http://exa mple.test")
    assert_nil Paquette::SafeUrl.http_url("http://example.test/\n<script>")
    assert_nil Paquette::SafeUrl.http_url("http://[")
  end

  # Not a security property, just the honest shape of the rule: the URL has to
  # be one URI can parse, and an unescaped non-ASCII path is not.
  def test_refuses_urls_that_are_not_percent_escaped
    assert_nil Paquette::SafeUrl.http_url("http://example.test/café")
    assert_equal "http://example.test/caf%C3%A9", Paquette::SafeUrl.http_url("http://example.test/caf%C3%A9")
  end

  def test_accepts_anything_that_responds_to_to_s
    assert_nil Paquette::SafeUrl.http_url(:"javascript:alert(1)")
    assert_nil Paquette::SafeUrl.http_url(42)
    assert_nil Paquette::SafeUrl.http_url(["https://example.test"])
  end
end
