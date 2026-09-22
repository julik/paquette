require "cgi"

module Paquette
  # The page a browser gets when it hits the root of a registry. There is one
  # of it, shared by both servers, and the only thing that differs between
  # them is the sentence in the middle — "This server provides RubyGems
  # packages." against the npm one. Everything else, the wordmark included,
  # is the same page.
  #
  # It is a Rack app, which is the whole of the plug: a server takes whatever
  # was handed to it as `placeholder_app:` and calls it — the name says what
  # it has to be. Swap in your own and you get
  # your own root — a redirect to a docs site, a status page, a bare 404:
  #
  #   Paquette::GemServer.new(repo, placeholder_app: IndexPage.new("Gems for staff only."))
  #   Paquette::NpmServer.new(repo, placeholder_app: ->(_env) { [302, {"location" => "/docs"}, []] })
  #
  # The blurb is HTML-escaped on the way in, so it is a sentence rather than
  # a template — a caller wanting markup is a caller wanting their own index
  # app, which is a page they own end to end rather than a hole in this one.
  class IndexPage
    TEMPLATE_PATH = File.join(__dir__, "index_page", "page.html")
    MASTHEAD_PATH = File.join(__dir__, "index_page", "masthead.svg")

    # An XML declaration is legal in a standalone .svg file and illegal
    # halfway down an HTML document, so it comes off when the art is inlined.
    XML_DECLARATION = /\A<\?xml[^>]{0,255}\?>\s*/

    # Read once per process rather than once per request: the page is static
    # apart from the blurb, and the root is what every uptime check hits.
    def self.template
      @template ||= File.read(TEMPLATE_PATH)
    end

    def self.masthead
      @masthead ||= File.read(MASTHEAD_PATH)
        .sub(XML_DECLARATION, "")
        .sub("<svg ", %(<svg class="masthead" role="img" aria-label="Paquette" ))
    end

    attr_reader :blurb, :title

    def initialize(blurb, title: "Paquette")
      @blurb = blurb.to_s
      @title = title.to_s
      @body = render
    end

    def call(_env)
      [200, {"Content-Type" => "text/html; charset=utf-8", "Content-Length" => @body.bytesize.to_s}, [@body]]
    end

    # The rendered page, built once at construction. Public because it is the
    # useful half for anyone wrapping this in their own Rack response.
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
end
