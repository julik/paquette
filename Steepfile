D = Steep::Diagnostic

target :lib do
  # sig/generated is what `rake rbs` writes out of the inline annotations in
  # lib/; sig-stubs covers the dependencies that ship no signatures.
  signature "sig", "sig-stubs"
  check "lib"

  # The rest of the stdlib in use (delegate, fileutils, stringio, tempfile,
  # tmpdir, uri, cgi) comes in through rbs_collection.lock.yaml.
  library "date", "digest", "erb", "json", "securerandom", "time", "zlib"

  configure_code_diagnostics(D::Ruby.default) do |hash|
    # An accumulator built up in a loop (`acc = {}`, `each_with_object({})`)
    # is left untyped rather than asserted at every site: the assertion
    # cannot sit on an argument, and the loop body is what fills it anyway.
    hash[D::Ruby::UnannotatedEmptyCollection] = :hint
  end
end
