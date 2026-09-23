require "delegate"
require "measurometer"

# Forbids package pushes
class Paquette::GemServer::ReadonlyRepository < SimpleDelegator
  class WriteNotAllowed < StandardError; end

  def add_gem(*)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end

  def yank_gem(*)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end
end
