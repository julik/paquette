require_relative "lib/paquette"

# Packages dir defaults to the one next to config.ru. Tests set
# PAQUETTE_PACKAGES_DIR to point at test/fixtures so they don't depend
# on whatever a dev-time gem push might have left on disk.
packages_dir = ENV["PAQUETTE_PACKAGES_DIR"] || File.expand_path("packages", __dir__)

npm_dir = File.join(packages_dir, "npm")
gems_dir = File.join(packages_dir, "gems")

# Both servers take a repository, and the wrapper chain you build around it
# decides what a caller may see and whether they may publish. Bare repositories
# like these are wide open — which is the dev-time setup, and why the README
# calls this slightly unhinged.
gems_repo = Paquette::GemServer::DirectoryGemRepository.new(gems_dir)
npm_repo = Paquette::NpmServer::DirectoryNpmRepository.new(npm_dir)

# Swap the repositories below for authenticators to require a token, and a
# one-time password on every push. See the README's Authentication section.
# class Authenticator
#   def initialize(repo) = @repo = repo
#
#   def authenticate(token, _request)
#     owner = token && AccessToken.find_by(secret: token)&.owner
#     owner && Paquette::Access.new(repository: @repo, otp_secret: owner.totp_secret)
#   end
# end
#
# ...and then: Paquette::GemServer.new(authenticator: Authenticator.new(gems_repo))

subdomain_apps = Paquette::SubdomainRouter.new do |router|
  router.map "gem", to: Paquette::GemServer.new(gems_repo)
  router.map "npm", to: Paquette::NpmServer.new(npm_repo)
  router.fallback to: ->(*) { [404, {}, ["Need subdomain gem/npm"]] }
end

run subdomain_apps
