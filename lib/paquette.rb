require 'rack'
require 'json'
require 'fileutils'
require_relative 'paquette/repository'
require_relative 'paquette/directory_repository'
require_relative 'paquette/app'
require_relative 'paquette/gem_server'
require_relative 'paquette/npm_server'

module Paquette
  VERSION = '0.1.0'
end
