# Working on paquette

## Tests

Run `bundle exec rake test` and `bundle exec standardrb` before you call a change done.

### Regexes get a pathological test, not just a happy-path one

Every request here meets a regexp with a client-chosen string on the other side: the route patterns Mustermann compiles, and the ones the handlers use to pull a name, version or tarball back out of the segment that matched. A feature that adds or edits one is not finished until it also has tests that try to break it.

Four things to cover:

- **Linearity.** Assert `Regexp.linear_time?` on the pattern. A `false` means a client picks the running time. `test/regexp_linearity_test.rb` already walks the live route table and the handler patterns — add yours there rather than starting a new file.
- **Pathological input.** Feed it the strings built to make it backtrack: long runs of the delimiter it splits on, long near-misses that match everything but the last character, nested repetition of whatever the pattern repeats. Assert it still returns promptly, and that it rejects rather than half-matches.
- **Anchors.** Use `\A` and `\z`, never `^` and `$` — those are line anchors, and Mustermann unescapes `%0A` into a real newline, so `^..$` will happily match the first line of a path segment and let the rest ride along. Test the `%0A` case end to end.
- **Encoding.** A percent-decoded segment can be invalid UTF-8, which makes a match raise `ArgumentError` rather than return `nil`. `Routes::Route#params` refuses those at the door, but anything matching against bytes that did not come through a route — a tar entry name out of an uploaded tarball, say — has to survive them on its own. Feed it `%E2` and a lone `\xFF`.

Do not build a regexp by interpolating a name into one, even through `Regexp.escape`: it compiles a pattern per call, and a name with invalid UTF-8 raises out of the compile itself. Use `start_with?`, `delete_prefix` and `String#[]`.

Prefer bounded quantifiers (`{1,255}`) over `+` wherever the thing being matched has a real-world maximum. Ruby 3.2 memoizes most backtracking away, but the gemspec still allows 3.1, which does not.

`Paquette::RegexpTimeout` is the backstop, not the fix. Keep the patterns linear anyway.
