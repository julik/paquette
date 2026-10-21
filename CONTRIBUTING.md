# Contributing to Paquette

Contributions are welcome! Please take a moment to review this document so that
contributing stays easy and effective for everyone involved.

I'd especially love to get:

* Package manager clients (or versions of them) that Paquette doesn't serve correctly
* Security findings — the whole point of Paquette is gating access, so leaks matter most
* Documentation fixes

## What do I need to know to help?

If you would like to learn more about the technologies Paquette builds on, check out the (non-exhaustive) list below. You can also get in touch with me via an issue or email.

 - [ruby](https://ruby-doc.org)
 - [Rack 3](https://github.com/rack/rack/blob/main/SPEC.rdoc) and [Mustermann](https://github.com/sinatra/mustermann), which compiles the route patterns
 - The [RubyGems compact index](https://guides.rubygems.org/rubygems-org-compact-index-api/) and the [gem_server_conformance](https://github.com/rubygems/gem_server_conformance) suite
 - The [npm registry API](https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md)
 - The PyPI [simple repository API](https://packaging.python.org/en/latest/specifications/simple-repository-api/) and the [upload API](https://docs.pypi.org/api/upload/)
 - [minitest](https://github.com/minitest/minitest) for testing

## Issues and pull requests

* Opening an issue first is often the fastest way to get something in. I can shape it into something that fits the library.
* The most useful bug report names the client and its version (`bundler`, `gem`, `npm`, `pnpm`, `yarn`, `pip`, `uv`, `twine`…), the command you ran, and the request and response it choked on — with tokens and credentials removed.
* Report a way around authentication, entitlements or limits by email rather than in a public issue, so it can be fixed before it is known.
* I may close a PR and implement the idea differently. That's not a rejection of the idea, and you'll be credited (`Co-authored-by`).
* Feel free to propose opinionated changes, but be prepared that your opinion won't be shared. It is a give-and-take.

## Code changes

Please adhere to the coding conventions used throughout the project (indentation,
accurate and terse comments, flat module identifiers, autoloading etc.) and any other
requirements (such as test coverage). [AGENTS.md](AGENTS.md) has the details — read it
before you add or change a regexp, because every one of them gets matched against strings
a client picked, and it has to come with tests that try to break it.

Run `bundle exec rake` and `bundle exec standardrb` before you submit. The default task
runs the tests and regenerates the type signatures in `rbi/` and `sig/`; commit those.
See [Running the tests](README.md#running-the-tests) for the parts that need Docker, Node
or Python.

## Basic expectations

This project is something created with love, and I - as an author - expect you, as a contributor, to return the favor. The ground rules:

* Do your best to be kind.
* Be polite and direct. No abrasiveness, no passive-aggression.
* [Low-context](https://www.ebsco.com/research-starters/communication-and-mass-media/high-context-and-low-context-cultures) communication is preferred and permitted
* No ad-hominems, also in code comments
* No sexualized or aggressive language

As a maintainer, I reserve the right to deny any contribution, discussion post, comment or pull request I find inappropriate.

Similarly, I reserve the right to not accept any contribution that doesn't fit the goals or spirit of the project (or my own), without explaining why it has been refused.

## Decisions are final

You're welcome to make your case once, clearly. After that, please don't reopen closed issues, start meta-threads about the decision, or argue about the wording of this document. This is a list of expectations, not a contract to be lawyered. If something isn't covered, the maintainer's judgment applies.

## What happens elsewhere stays elsewhere

Contributions are judged on what they are, not on who sent them. What anyone says or does outside this project (on social media, at their job, in other repos, in politics) is not a topic here and will not be considered, either for or against them. Please don't bring it in: no call-outs, no "are you aware this person…" threads, no requests to ban someone over things that didn't happen here.

## AI-generated issues and code

This project uses LLMs to produce code and artifacts, and it's fine if you do the same when contributing. LLM use in this project is settled: threads about whether it should be used (utility, harm, societal implications etc.) will be closed.

Please disclose LLM use in every issue and PR: say which model or tool you used and what for (e.g. "Claude wrote the fix, I wrote the test"). This is for transparency, not for judgment. Disclosed LLM use is treated the same as no LLM use.

However, the following is on you:

* Make your LLM output _terse._ Nobody likes reading slop, even my agents. Make it get to the point.
* Make sure what you submit actually ran. Don't file issues about behavior or APIs your LLM imagined.
* Do not add external dependencies (or have your LLM do it) unless absolutely necessary
* If you file a PR, make at least one pass with "Make this at least 50% less code"
* Code generated by your LLM will be considered as written by you, with the same requirements

## License

By submitting a patch, you agree to allow the project owner to license your work under the same license as that used by the project, which you can see [here](LICENSE.md).
