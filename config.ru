require_relative "lib/paquette"

# Use GEMS_DIR environment variable if set, otherwise use default
gems_dir = ENV["GEMS_DIR"]
run Paquette::App.new(gems_dir)
