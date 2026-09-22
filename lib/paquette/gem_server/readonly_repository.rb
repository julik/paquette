require "delegate"
require "measurometer"

module Paquette
  class GemServer
    # Forbids package pushes
    class ReadonlyRepository < SimpleDelegator
      class WriteNotAllowed < StandardError; end

      def add_gem(*)
        raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
      end

      def yank_gem(*)
        raise WriteNotAllowed, "Writes are not allowed through a readonly repository"
      end
    end
  end
end
