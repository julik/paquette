require_relative "lib/paquette"

use Paquette::RegexpTimeout

repo = Paquette::GemServer::DirectoryGemRepository.new(File.expand_path("packages/gems", __dir__))
run Paquette::GemServer.new(repo)
