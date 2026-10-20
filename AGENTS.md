# Working on paquette

## Tests

Run `bundle exec rake` (Steep, then the tests) and `bundle exec standardrb` before you call a change done.

### Regexes get a pathological test, not just a happy-path one

Every request here meets a regexp with a client-chosen string on the other side: the route patterns Mustermann compiles, and the ones the handlers use to pull a name, version or tarball back out of the segment that matched. A feature that adds or edits one is not finished until it also has tests that try to break it.

Four things to cover:

- **Linearity.** Assert `Regexp.linear_time?` on the pattern. A `false` means a client picks the running time. `test/regexp_linearity_test.rb` already walks the live route table and the handler patterns — add yours there rather than starting a new file.
- **Pathological input.** Feed it the strings built to make it backtrack: long runs of the delimiter it splits on, long near-misses that match everything but the last character, nested repetition of whatever the pattern repeats. Assert it still returns promptly, and that it rejects rather than half-matches.
- **Anchors.** Use `\A` and `\z`, never `^` and `$` — those are line anchors, and Mustermann unescapes `%0A` into a real newline, so `^..$` will happily match the first line of a path segment and let the rest ride along. Test the `%0A` case end to end.
- **Encoding.** A percent-decoded segment can be invalid UTF-8, which makes a match raise `ArgumentError` rather than return `nil`. `Routes::Route#params` refuses those at the door, but anything matching against bytes that did not come through a route — a tar entry name out of an uploaded tarball, say — has to survive them on its own. Feed it `%E2` and a lone `\xFF`.

Do not build a regexp by interpolating a name into one, even through `Regexp.escape`: it compiles a pattern per call, and a name with invalid UTF-8 raises out of the compile itself. Use `start_with?`, `delete_prefix` and `String#[]`.

Prefer bounded quantifiers (`{1,255}`) over `+` wherever the thing being matched has a real-world maximum. Ruby 3.2 memoizes most backtracking away, but the gemspec still allows 3.1, which does not.

`Paquette::RegexpTimeout` — prepended into every Rack app here, so it is armed on any request that reaches one — is the backstop, not the fix. Keep the patterns linear anyway.

## Types and docs

The signatures live in the code, as rbs-inline annotations, and the comments above them are rdoc in markdown. There are no YARD tags.

- A method gets a `#:` line directly above its `def`, with parameter names: `#: (String name, ?weak: bool) -> String?`. Overloads are one `#:` line each. rdoc reads this line and prints it on the method's page, so keep it on one line however long it gets.
- An attribute, a constant or a Struct/Data member gets a trailing `#: Type`. A constant whose value is a plain literal needs none. rbs-inline does not see `Foo::Bar = Data.define(...)`, so assign one inside the module.
- What a parameter is for goes in the prose, as a markdown list (`` - `name`: what it is ``), followed by "Returns ..." and "Raises ..." sentences. Do not restate what the signature already says.
- `@rbs` annotations that rdoc should not print (`generic`, `skip`) go after a `#--` line, which ends the documentation part of the comment.
- A Rack response is `Paquette::rack_response`, an env `Paquette::rack_env`, anything callable as a Rack app `Paquette::_RackApp`.
- Prefer a narrowing local (`upload_path = tmp.path #: String`) over `# steep:ignore`; the ignore is for stdlib signatures that are wrong, such as `Zlib::GzipWriter.wrap` refusing a StringIO.

`rake steep` regenerates `sig/generated` and type-checks `lib/`. It is part of the default `rake` and of CI. `sig/` is not committed: `rake build` generates it before packaging, so the gem ships it. Signatures for dependencies that ship none live in `sig-stubs/`, which is not packaged.

`rake docs` builds the HTML docs into `doc/`. Comments and the .md pages are GitHub Flavored Markdown, rendered by commonmarker (`rakelib/gfm_markup.rb`): tables, task lists, alerts, footnotes and raw HTML all work. A backticked or bare name that rdoc documents still becomes a link to it.

## Style

* Use autoloading where possible
* Use flat Ruby module identifiers: `class Foo::Bar::Baz` instead of creating deeply-indented code blocks
* A flat identifier narrows the lexical scope to that one constant, so a superclass or a sibling in the same namespace has to be written out in full — `Paquette::GemServer::GemRepository`, not `GemRepository`.

## Tests

`rake test` runs the suite one forked process per test class (minitest-parallel_fork), because it binds ports, shells out to Bundler and npm, and leans on process-global state like `Regexp.timeout`. `NCPU` sets the number of forks; `NCPU=1` runs it serially, which is what to reach for when a failure looks like it depends on what else was running.
