# Nested rather than `Paquette::Published = ...`: rbs-inline only types the
# members of a Data.define assigned to a bare constant.

module Paquette
  # What a push or a publish wrote, handed to a server's `on_publish:` once the
  # write has landed. `released_at` is the gemspec's date for a gem - see
  # `require_release_date:` on DirectoryGemRepository for keeping it honest - and
  # the moment of arrival for an npm package, whose tarball carries no date worth
  # trusting: `npm pack` stamps every entry with 1985-10-26.
  Published = Data.define(
    :name, #: String
    :version, #: String
    :released_at #: Time
  )
end
