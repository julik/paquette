require_relative "lib/paquette"

# Use packages directory next to config.ru
packages_dir = File.expand_path("packages", __dir__)

npm_dir = File.join(packages_dir, "npm")
gems_dir = File.join(packages_dir, "gems")

gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

subdomain_apps = Paquette::SubdomainRouter.new do |router|
  router.map "gem", to: Paquette::GemServer.new(gems_repo)
  router.map "npm", to: Paquette::NpmServer.new(npm_dir)
  router.fallback to: ->(*) { [404, {}, ["Need subdomain gem/npm"]] }
end

run subdomain_apps
