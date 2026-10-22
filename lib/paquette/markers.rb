# The one mechanism the personalizers write with. A package author puts a
# marker on a line of its own, in whatever their language calls a comment:
#
#   # paquette:licensee
#   // paquette:licensee
#   -- paquette:licensee
#
# or bare, in a text file that has no comments. The personalizer replaces the
# body of that line with the value the caller's authenticator gave for the
# key, keeping the indentation, the comment leader and the line ending, so the
# line count never changes and a sourcemap or a traceback still points where
# it did. A key is lowercase letters, digits and underscores. A line that is
# not exactly a marker is never touched.
#
# No regexps. Every line here came out of an uploaded package.
module Paquette::Markers
  # @return [String]
  PREFIX = "paquette:"

  # What may stand in front of a marker on its line.
  #
  # @return [Array<String>]
  LEADERS = ["#", "//", "--", ";", "%", "*"].freeze

  # @return [Integer]
  MAX_KEY_LENGTH = 64

  # Raised when a marker for a key the caller supplied is still in the text
  # after the pass: it was not alone on its line - `esbuild --minify` pulls
  # a legal comment onto the end of a code line - and the package would go
  # out with no stamp in it and nothing to say so.
  class NotApplied < StandardError; end

  # Raised for a value that would change the line count.
  class MultilineValue < StandardError; end

  module_function

  # Every value is a single line of text, or the whole scheme breaks.
  #
  # @param values [Hash{String => String}]
  # @return [void]
  # @raise [MultilineValue, ArgumentError]
  def check_values!(values)
    raise ArgumentError, "personalization must be a Hash of String => String, got #{values.class}" unless values.is_a?(Hash)

    values.each do |key, value|
      raise ArgumentError, "personalization key #{key.inspect} is not a valid marker key" unless valid_key?(key.to_s)
      raise ArgumentError, "personalization value for #{key.inspect} is not a String" unless value.is_a?(String)
      if value.include?("\n") || value.include?("\r")
        raise MultilineValue, "personalization value for #{key.inspect} spans several lines; a value replaces one line"
      end
    end
    nil
  end

  # @param key [String]
  # @return [Boolean]
  def valid_key?(key)
    !key.empty? && key.length <= MAX_KEY_LENGTH && key.count("^a-z0-9_").zero?
  end

  # The key when `line` is nothing but a marker, nil otherwise.
  #
  # @param line [String] one line, with or without its ending
  # @return [String, nil]
  def key_of(line)
    stripped = line.strip
    at = stripped.index(PREFIX)
    return nil unless at

    key = stripped[(at + PREFIX.length)..]
    return nil unless valid_key?(key)

    leader = stripped[0, at].rstrip
    return nil unless leader.empty? || LEADERS.include?(leader)

    key
  end

  # Whether `text` is something this module can read at all: UTF-8 with no
  # NUL in it. Anything else is a binary and is left alone.
  #
  # @param text [String]
  # @return [Boolean]
  def text?(text)
    utf8 = text.dup.force_encoding(Encoding::UTF_8)
    utf8.valid_encoding? && !utf8.include?("\0")
  end

  # The key named anywhere on `line`, alone on it or not - what the package
  # asks for, as opposed to what {key_of} will fill. nil when nothing on the
  # line looks like a marker.
  #
  # @param line [String]
  # @return [String, nil]
  def mentioned_key_of(line)
    at = line.index(PREFIX)
    return nil unless at

    rest = line[(at + PREFIX.length)..]
    # A key is at most MAX_KEY_LENGTH long, so this looks at one more
    # character than that and no further, whatever the line's length
    stop = 0
    stop += 1 while stop <= MAX_KEY_LENGTH && stop < rest.length && rest[stop].count("a-z0-9_") == 1
    key = rest[0, stop]
    valid_key?(key) ? key : nil
  end

  # The keys of every marker in `text`, in order of appearance - mentioned
  # anywhere on a line, not only alone on one. Detection is loose where
  # filling is strict, so that a marker a minifier has pulled onto a code
  # line still counts as the package asking to be personalized, and is then
  # refused by {substitute} rather than served untouched.
  #
  # @param text [String]
  # @return [Array<String>]
  def keys_in(text)
    return [] unless text?(text)

    text.dup.force_encoding(Encoding::UTF_8).each_line.filter_map { |line| mentioned_key_of(line) }.uniq
  end

  # `text` with every marker line whose key is in `values` replaced. A marker
  # for a key not in `values` stays as it is - it is a comment. Returns the
  # input itself, not a copy, when there was nothing to do.
  #
  # @param text [String]
  # @param values [Hash{String => String}]
  # @param described_as [String] what to call the text in an error
  # @return [String] in the encoding `text` came in
  # @raise [NotApplied]
  def substitute(text, values, described_as: "text")
    return text if values.empty? || !text?(text)

    utf8 = text.dup.force_encoding(Encoding::UTF_8)
    changed = false
    replaced = utf8.each_line.map do |line|
      key = key_of(line)
      next line unless key && values.key?(key)

      changed = true
      stripped = line.strip
      indent = line[0, line.length - line.lstrip.length]
      leader = stripped[0, stripped.index(PREFIX)].rstrip
      ending = line[line.rstrip.length..]
      "#{indent}#{leader}#{" " unless leader.empty?}#{values[key]}#{ending}"
    end.join

    values.each_key do |key|
      next unless replaced.include?(PREFIX + key)

      raise NotApplied,
        "#{described_as} still contains #{(PREFIX + key).inspect} after personalization: it is not alone on its " \
        "line (minified?), so the package would have gone out without it"
    end

    changed ? replaced.force_encoding(text.encoding) : text
  end
end
