require_relative "lib/paquette"

# Packages dir defaults to the one next to config.ru. Tests set
# PAQUETTE_PACKAGES_DIR to point at test/fixtures so they don't depend
# on whatever a dev-time gem push might have left on disk.
packages_dir = ENV["PAQUETTE_PACKAGES_DIR"] || File.expand_path("packages", __dir__)

npm_dir = File.join(packages_dir, "npm")
gems_dir = File.join(packages_dir, "gems")

gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)

subdomain_apps = Paquette::SubdomainRouter.new do |router|
  router.map "gem", to: Paquette::GemServer.new(gems_repo)
  router.map "npm", to: Paquette::NpmServer.new(npm_dir)
  router.fallback to: ->(*) { [404, {}, ["Need subdomain gem/npm"]] }
end

run subdomain_apps
