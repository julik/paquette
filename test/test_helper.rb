require "minitest/autorun"
require "rack/test"
require "rack"
require "fileutils"
require "json"
require "stringio"
require "net/http"
require "tempfile"
require_relative "../lib/paquette"

FIXTURE_GEMS_DIR = File.expand_path("fixtures/gems", __dir__)
FIXTURE_NPM_DIR = File.expand_path("fixtures/npm", __dir__)
