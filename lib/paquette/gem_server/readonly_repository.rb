require "delegate"
require "measurometer"

# Forbids package pushes
class Paquette::GemServer::ReadonlyRepository < SimpleDelegator
  class WriteNotAllowed < StandardError; end

  # `**` as well as `*`: add_gem takes a max_bytes: keyword, and a method
  # that only splats positionals raises ArgumentError on a keyword call
  # instead of the WriteNotAllowed the caller is rescuing.
  def add_gem(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end

  def yank_gem(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end
end
