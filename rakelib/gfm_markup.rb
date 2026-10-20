require "cgi"
require "commonmarker"
require "rdoc"

# GitHub Flavored Markdown for rdoc, through commonmarker. rdoc's own
# markdown parser is a near-miss: no inline HTML, no task lists, no alerts,
# no <details> around markdown. This takes over the "markdown" format, which
# covers the comments in lib/ and the .md pages alike.
#
# Fenced code goes back to rdoc as a Verbatim, so Ruby gets the same
# highlighting as the method sources. Everything else is commonmarker's HTML,
# carried in a Raw part and linked up the way rdoc links a comment: a
# backticked or bare name that rdoc documents becomes a link to it.
module PaquetteDocs
  # A part of a comment that is HTML already, as opposed to a Raw someone
  # else made.
  class GFMHTML < RDoc::Markup::Raw
  end

  module GFM
    OPTIONS = {
      parse: {smart: false},
      render: {unsafe: true, hardbreaks: false, github_pre_lang: true},
      extension: {
        table: true,
        strikethrough: true,
        tasklist: true,
        autolink: true,
        footnotes: true,
        alerts: true,
        header_ids: "",
        # tagfilter escapes <script>, <iframe> and the like. These docs are
        # written by us, and the filter would only get in the way.
        tagfilter: false
      }
    }.freeze

    # The RDoc::Text::MARKUP_FORMAT interface: text in, Document out.
    def self.parse(text)
      root = Commonmarker.parse(text, options: OPTIONS)
      parts = root.map do |node|
        if node.type == :code_block
          verbatim = RDoc::Markup::Verbatim.new(*node.string_content.lines)
          verbatim.format = code_format(node.fence_info)
          verbatim
        else
          GFMHTML.new(node.to_html(options: OPTIONS))
        end
      end
      RDoc::Markup::Document.new(*parts)
    end

    # The fence's language becomes the <pre>'s class: rdoc highlights :ruby
    # itself, and Aliki picks up c, bash, sh, shell and console in the
    # browser. No language at all leaves rdoc to guess, as it does for an
    # indented block.
    def self.code_format(info)
      lang = info.to_s.split.first
      lang&.downcase&.to_sym
    end
  end

  # The linking half, which needs the page being rendered and so lives on
  # the formatter rather than the parser.
  module CrossrefGFM
    def accept_raw(raw)
      return super unless raw.is_a?(GFMHTML)

      @res << link_names(raw.parts.join("\n"))
    end

    private

    def link_names(html)
      out = +""
      unlinkable = 0 # inside <pre> or <a>
      code = nil # the <code> span being collected

      html.split(/(<[^>]*>)/).each do |piece|
        if code
          if piece == "</code>"
            name = CGI.unescapeHTML(code)
            out << (tt_cross_reference(name) || "<code>#{code}</code>")
            code = nil
          else
            code << piece
          end
        elsif piece.start_with?("<")
          if unlinkable.zero? && piece == "<code>"
            code = +""
            next
          end
          unlinkable += 1 if piece.match?(/\A<(pre|a)[\s>]/i)
          unlinkable -= 1 if piece.match?(/\A<\/(pre|a)>/i)
          out << piece
        elsif unlinkable.zero?
          out << link_words(piece)
        else
          out << piece
        end
      end
      out << "<code>#{code}" if code
      out
    end

    # rdoc's own rule for prose: a name it can resolve, except an
    # all-lowercase word, which would make every "new" a link.
    def link_words(text)
      text.gsub(RDoc::CrossReference::CROSSREF_REGEXP) do
        match = Regexp.last_match
        name = match[1]
        lead = match[0][0, match.begin(1) - match.begin(0)]
        linked = name.match?(/\A[a-z]*\z/) ? nil : cross_reference(CGI.unescapeHTML(name))
        lead + (linked || name)
      end
    end
  end
end

RDoc::Text::MARKUP_FORMAT["markdown"] = PaquetteDocs::GFM
RDoc::Markup::ToHtmlCrossref.prepend(PaquetteDocs::CrossrefGFM)
