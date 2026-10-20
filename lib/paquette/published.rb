# What a push or a publish wrote, handed to a server's `on_publish:` once the
# write has landed. `released_at` is the gemspec's date for a gem - see
# `require_release_date:` on DirectoryGemRepository for keeping it honest - and
# the moment of arrival for an npm package, whose tarball carries no date worth
# trusting: `npm pack` stamps every entry with 1985-10-26.
#
# @!attribute name
#   @return [String]
# @!attribute version
#   @return [String]
# @!attribute released_at
#   @return [Time]
Paquette::Published = Data.define(:name, :version, :released_at)
