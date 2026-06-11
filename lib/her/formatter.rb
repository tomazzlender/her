# frozen_string_literal: true

module Her
  # A *safe* formatter for .her templates: it re-indents lines from the
  # parsed structure but never moves content between lines. Because HER
  # renders templates verbatim, re-indenting the source re-indents the
  # output's cosmetic whitespace — but it cannot change rendered *semantics*:
  # whitespace-significant regions are left untouched.
  #
  # Left verbatim:
  #   * everything inside <pre>, <textarea>, <script>, <style>
  #   * continuation lines of multi-line holes (Ruby code)
  #   * continuation lines of multi-line tags (attribute values may be
  #     multi-line strings)
  #
  # Indentation rules: children of elements/components/slots indent one
  # level; statement holes ({if}/{each do}/{= capture do}) indent what
  # follows; {end} closes a level; {else}/{elsif}/{when} outdent their own
  # line, Ruby-style. Trailing whitespace is stripped on formatted lines and
  # the file ends with exactly one newline. Raises ParseError (with the
  # caret snippet) on templates that do not parse.
  module Formatter
    VERBATIM_ELEMENTS = %w[pre textarea script style].freeze

    Line = Struct.new(:events, :verbatim, keyword_init: true)

    module_function

    # Format template +source+; returns the formatted string.
    def format(source, indent: "  ", file: "(her-fmt)")
      return source if source.strip.empty?

      tokens = Tokenizer.new(source, file: file).tokenize
      # Validation only: malformed templates must not be "formatted".
      Parser.new(tokens, file: file, source: source).parse
      lines = source.lines
      info = Array.new(lines.size + 2) { Line.new(events: [], verbatim: false) }
      collect_line_info(tokens, info)

      out = +""
      depth = 0
      lines.each_with_index do |raw, index|
        line = info[index + 1]
        content = raw.chomp
        if line.verbatim
          out << content
        elsif content.strip.empty?
          # keep blank lines blank
        else
          out << (indent * display_depth(depth, line, content)) << content.strip
        end
        out << "\n"
        depth = update_depth(depth, line)
      end
      out
    end

    # Format the file at +path+ in place. Returns true when the contents
    # changed. check: true leaves the file untouched and only reports.
    def format_file(path, indent: "  ", check: false)
      original = File.read(path)
      formatted = format(original, indent: indent, file: path)
      return false if formatted == original
      File.write(path, formatted) unless check
      true
    end

    # -- internals -------------------------------------------------------------

    def collect_line_info(tokens, info)
      verbatim_stack = []
      tokens.each do |token|
        case token.type
        when :tag_open
          unless token.self_closing || token.void
            info[token.line].events << [:open, token.col]
          end
          # multi-line tags: attribute lines stay verbatim
          mark_verbatim(info, token.line + 1, token.end_line)
          if VERBATIM_ELEMENTS.include?(token.name) && !token.self_closing && !token.void
            verbatim_stack << [token.name, token.end_line]
          end
        when :tag_close
          info[token.line].events << [:close, token.col]
          if (open = verbatim_stack.last) && open[0] == token.name
            verbatim_stack.pop
            # content lines, and the close line itself (its leading
            # whitespace belongs to the element's content)
            mark_verbatim(info, open[1] + 1, token.line)
          end
        when :hole
          kind = RubyScanner.classify(token.code).kind
          case kind
          when :open, :block, :capture then info[token.line].events << [:open, token.col]
          when :end                    then info[token.line].events << [:close, token.col]
          when :mid                    then info[token.line].events << [:mid, token.col]
          end
          mark_verbatim(info, token.line + 1, token.line + token.code.count("\n"))
        end
      end
    end

    def mark_verbatim(info, from, to)
      (from..to).each { |line| info[line].verbatim = true if info[line] }
    end

    # A line whose first content is a closer ({end}, </tag>) or a mid
    # keyword ({else}, {elsif}, {when}) sits one level out.
    def display_depth(depth, line, content)
      first_event = line.events.first
      if first_event && first_event[1] == content[/\A[ \t]*/].length + 1 &&
         %i[close mid].include?(first_event[0])
        [depth - 1, 0].max
      else
        depth
      end
    end

    def update_depth(depth, line)
      line.events.each do |kind, _col|
        case kind
        when :open  then depth += 1
        when :close then depth = [depth - 1, 0].max
        end
      end
      depth
    end
  end
end
