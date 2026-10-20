require "delegate"

# Forbids uploads and yanks
class Paquette::PypiServer::ReadonlyRepository < SimpleDelegator
  # Raised by every write on a readonly repository.
  class WriteNotAllowed < StandardError; end

  # @raise [WriteNotAllowed] always
  # @return [void]
  def add_file(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end

  # @raise [WriteNotAllowed] always
  # @return [void]
  def yank_file(*, **)
    raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
  end
end
