require_relative "lib/paquette/version"

Gem::Specification.new do |spec|
  spec.name = "paquette"
  spec.version = Paquette::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.summary = "Rack-based server for gated gem and NPM package repositories"
  spec.homepage = "https://github.com/julik/paquette"
  spec.license = "Osassy"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage
  }

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir.glob("lib/**/*.rb") + Dir.glob("test/**/*") + ["LICENSE.md", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rack", "~> 3.0"
  spec.add_dependency "mustermann", "~> 3.0"
  spec.add_dependency "sourcemap", "~> 0.1"
end
