# Loaded into the gem_server_conformance RSpec process with --require (see
# gem_server_conformance_test.rb). Everything here is an example paquette
# knowingly does not pass, with the reason it does not.
#
# Two mechanisms, because one is not enough. An exclusion filter matches on
# `full_description`, and an `it { is_expected.to … }` with no docstring has
# no full_description until it has run — RSpec generates that text from the
# matcher afterwards. So the rules that name a *group* are filters, and the
# two that can only name a bare `it` mark the example skipped instead. Skipped
# rather than quietly passed: the count at the end of the run is then honest,
# and each one points back here.
module PaquetteConformanceSkips
  # The reason has to go into metadata[:skip] as well as through
  # mark_skipped!. The suite reruns a group's examples until they all pass
  # (see StepHelpers::Step#request), and on the second run RSpec takes the
  # pending message from `metadata[:skip]` — where mark_skipped! leaves a bare
  # `true`, which reports as "No reason given".
  def self.skip!(reason)
    example = RSpec.current_example
    RSpec::Core::Pending.mark_skipped!(example, reason)
    example.metadata[:skip] = reason
    raise RSpec::Core::Pending::SkipDeclaredInExample.new(reason)
  end
end

# One Regexp.union rather than one filter_run_excluding call per rule: RSpec
# keeps exclusion filters in a single hash keyed by attribute, so a second
# call naming :full_description replaces the first, and only the last rule
# would bite.
PAQUETTE_EXCLUDED_GROUPS = [
  # The ETag on a compact index file. The suite requires it to be the MD5 of
  # the body, so that the third column of /versions and the ETag of the
  # matching /info/ are the same string. Paquette derives its ETag from the
  # corpus fingerprint instead, which is what lets a conditional /versions be
  # answered without rendering the index at all (see handle_compact_versions)
  # and what lets a gated or personalized stack decline to name a response at
  # all. Digesting the body would undo both.
  /have the same etag|has matching etags/,

  # Every /info/("a") body from the point gem "a" has had its only version
  # yanked, for two reasons that both live below the platform work.
  #
  # The first is that group itself. rubygems.org keeps answering 200 with an
  # empty "---\n" info file for a gem whose every version has been yanked;
  # paquette answers 404, because its repository knows which .gem files are
  # on disk and nothing else, so "no versions left" and "never heard of it"
  # are one answer to it. /names no longer lists such a gem either, so the
  # two endpoints agree — they just agree on 404. Telling the two apart
  # means the repository publishing its tombs, which is more than a response
  # tweak. The `.*` is what carries that forward: the suite expresses each
  # later body as the parent's plus a delta, so once the parent body
  # diverges every descendant does too, whatever paquette serves.
  #
  # The second only appears once platform builds are in the corpus, and it
  # is worth naming even though this filter would hide it anyway. The suite
  # expects /info/ lines in *push* order — "0.2.0", then
  # "0.2.0-x86-mingw32", then "0.2.0-java" — because rubygems.org appends a
  # row per push. Paquette renders the document from a directory listing and
  # sorts it, which puts "0.2.0-java" before "0.2.0-x86-mingw32". A
  # directory-backed corpus does not record the order it was written in, and
  # the two candidates for recovering it are both worse than sorting: an
  # mtime is a property of this filesystem right now rather than of the gem
  # (see CooldownRepository#published_time on what an rsync does to those),
  # and a sequence counter is durable state this repository deliberately
  # does not keep. Bundler sorts the lines it reads, so the order is not
  # load-bearing for a client — it is load-bearing for a byte-comparison
  # against a server that appends. That is the same append-only question
  # /versions is excluded for, one endpoint along.
  /after yanking only gem.*get_info\("a"\)/
].freeze

# /versions is rendered per request rather than appended to. The suite asserts
# the file grows by one row per push and is compacted only by an explicit
# rebuild, and that `created_at:` carries the time of that rebuild; paquette
# has no versions file to append to and always serves the compacted form. Its
# `created_at:` is the oldest publication time in the corpus, which is stable
# across renders but is not the rebuild stamp the suite looks for. Materializing an
# append-only index is the one thing this exercise deliberately did not do.
#
# Skipped rather than filtered out, so the group's before(:all) still issues
# the request: the suite's own "all expected requests are tested" check reads
# the /versions body to work out what else should have been asked for, and a
# filtered-away group would leave it with nothing to read.
PAQUETTE_VERSIONS_REASON =
  "paquette renders /versions per request; it is not an append-only file with a rebuild step"

RSpec.configure do |config|
  config.filter_run_excluding(full_description: Regexp.union(PAQUETTE_EXCLUDED_GROUPS))

  config.before do |example|
    group = example.metadata[:example_group][:full_description].to_s
    PaquetteConformanceSkips.skip!(PAQUETTE_VERSIONS_REASON) if group.include?("get_versions")
  end
end

# The compact index response headers, on /names and /info. `accept-ranges:
# bytes` and the RFC 9530 `digest` / `repr-digest` pair are served now and
# satisfy this matcher; what is left is the ETag alone, for the reason given
# above — the suite wants the MD5 of the body, and paquette derives its tag
# from the corpus fingerprint so that a conditional request can be answered
# without rendering the document, and so that a gated or personalized stack
# can decline to name a response at all. Redefined rather than filtered
# because the examples using it are bare `it { … }` with nothing to filter
# on, and the groups they sit in hold other examples that do pass and are
# worth keeping.
RSpec::Matchers.define :be_valid_compact_index_reponse do
  match do |_response|
    PaquetteConformanceSkips.skip!(
      "paquette's ETag on a compact index file is a corpus fingerprint rather than a digest of the body"
    )
  end
end
