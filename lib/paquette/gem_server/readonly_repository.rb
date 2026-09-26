require "delegate"
require "measurometer"

# Forbids package pushes
class Paquette::GemServer::ReadonlyRepository < SimpleDelegator
  # Raised by every write on a readonly repository.
  class WriteNotAllowed < StandardError; end

  # @raise [WriteNotAllowed] always
  def add_gem(*)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end

  # @raise [WriteNotAllowed] always
  def yank_gem(*)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end
end
