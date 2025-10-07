require_relative "lib/paquette"

# Use GEMS_DIR environment variable if set, otherwise use default
gems_dir = ENV["GEMS_DIR"]
app = Paquette::App.new(gems_dir)

run app
