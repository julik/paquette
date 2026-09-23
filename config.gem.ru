require_relative "lib/paquette"

repo = Paquette::GemServer::DirectoryGemRepository.new(File.expand_path("packages/gems", __dir__))
run Paquette::GemServer.new(repo)
