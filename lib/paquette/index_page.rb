require "cgi"

# The Rack app a browser gets at the root of a registry — the default for
# the `placeholder_app:` keyword both servers take. Swap in any Rack app to
# get your own root. The blurb is HTML-escaped on the way in: a caller
# wanting markup is a caller wanting their own index app.
class Paquette::IndexPage
  TEMPLATE_PATH = File.join(__dir__, "index_page", "page.html")
  MASTHEAD_PATH = File.join(__dir__, "index_page", "masthead.svg")

  # An XML declaration is legal in a standalone .svg file and illegal
  # halfway down an HTML document, so it comes off when the art is inlined.
  XML_DECLARATION = /\A<\?xml[^>]{0,255}\?>\s*/

  # Read once per process rather than once per request: the root is what
  # every uptime check hits.
  #
  # @return [String]
  def self.template
    @template ||= File.read(TEMPLATE_PATH)
  end

  # @return [String] the masthead SVG, prepared for inlining into HTML
  def self.masthead
    @masthead ||= File.read(MASTHEAD_PATH)
      .sub(XML_DECLARATION, "")
      .sub("<svg ", %(<svg class="masthead" role="img" aria-label="Paquette" ))
  end

  # @return [String]
  attr_reader :blurb

  # @return [String]
  attr_reader :title

  # @param blurb [String] one sentence describing the registry
  # @param title [String]
  def initialize(blurb, title: "Paquette")
    @blurb = blurb.to_s
    @title = title.to_s
    @body = render
  end

  # @param _env [Hash] the Rack env
  # @return [Array] a Rack response triplet
  def call(_env)
    [200, {"Content-Type" => "text/html; charset=utf-8", "Content-Length" => @body.bytesize.to_s}, [@body]]
  end

  # The rendered page, built once at construction. Public because it is the
  # useful half for anyone wrapping this in their own Rack response.
  #
  # @return [String]
  def render
    # Block form throughout: a replacement string would have `\1` and `\\`
    # read out of it as backreferences, and path data is exactly the kind
    # of thing that carries a stray backslash.
    self.class.template
      .gsub("{{masthead}}") { self.class.masthead }
      .gsub("{{blurb}}") { CGI.escapeHTML(@blurb) }
      .gsub("{{title}}") { CGI.escapeHTML(@title) }
  end
end
