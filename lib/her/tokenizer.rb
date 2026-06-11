# frozen_string_literal: true

require "strscan"

module Her
  # Stage ① of the pipeline (§6): a hand-written scanner that turns .her
  # source into a flat token stream. Tracks line/column throughout so every
  # later error can point at the author's source.
  #
  # Lines in tokens are template-local (1-based); error messages add the
  # origin offset so inline heredoc templates report real .rb file lines.
  class Tokenizer
    TagToken  = Struct.new(:type, :kind, :name, :attrs, :self_closing, :void, :line, :col, :end_line, keyword_init: true)
    TextToken = Struct.new(:type, :value, :line, :col, keyword_init: true)
    HoleToken = Struct.new(:type, :code, :line, :col, keyword_init: true)
    # <%# ... %> template comments emit nothing but participate in
    # line-trimming, so comment-only lines vanish from output.
    CommentToken = Struct.new(:type, :line, :col, keyword_init: true)
    # value is nil (bare attribute) or one of:
    #   [:static, string, quote]   quote: '"', "'" or nil (unquoted)
    #   [:hole,   code]            whole-value hole  -> smart attribute
    #   [:mixed,  parts, quote]    parts: [:static, s] / [:hole, code] list
    #   [:splat,  code]            `{...}` in attribute-name position
    AttrToken = Struct.new(:name, :value, :line, :col, keyword_init: true)

    VOID_ELEMENTS = %w[
      area base br col embed hr img input link meta param source track wbr
    ].freeze

    RAW_TEXT_ELEMENTS = %w[script style].freeze

    HTML_NAME   = /[a-z][a-zA-Z0-9-]*/
    METHOD_NAME = /[a-z_][a-zA-Z0-9_]*/
    REMOTE_NAME = /[A-Z]\w*(?:::[A-Z]\w*)*\.[a-z_]\w*/
    ATTR_NAME   = /[^\s=\/>{}"'<]+/

    def initialize(source, file:, first_line: 1)
      @s = StringScanner.new(source)
      @file = file
      @first_line = first_line
      @line = 1
      @col = 1
      @tokens = []
      @no_curly = nil # {name:, depth:} while inside a her-no-curly subtree
    end

    def tokenize
      until @s.eos?
        if @s.match?(/</)
          scan_angle
        elsif !@no_curly && @s.match?(/\{/)
          scan_text_hole
        else
          scan_text_run
        end
      end
      @tokens
    end

    private

    # -- low-level cursor helpers -------------------------------------------

    def take(regexp)
      str = @s.scan(regexp)
      advance(str) if str
      str
    end

    def advance(str)
      newlines = str.count("\n")
      if newlines.zero?
        @col += str.length
      else
        @line += newlines
        @col = str.length - str.rindex("\n")
      end
    end

    def fail!(message, line: @line, col: @col)
      raise ParseError.new(message, file: @file, line: @first_line + line - 1, column: col,
                                    snippet: Her.source_snippet(@s.string, line, col, display_line: @first_line + line - 1))
    end

    def location_label(line, col)
      "#{@file}:#{@first_line + line - 1}:#{col}"
    end

    # Consume a `{...}` hole body; scanner must sit ON the `{`.
    def take_hole_body
      open_line = @line
      open_col = @col
      take(/\{/)
      rest = @s.rest
      code_length = RubyScanner.hole_code_length(rest)
      unless code_length
        fail!("unclosed interpolation `{`", line: open_line, col: open_col)
      end
      code = rest.byteslice(0, code_length)
      @s.pos += code_length + 1 # past the closing `}`
      advance(code)
      advance("}")
      code
    end

    # -- text ---------------------------------------------------------------

    def scan_text_run
      line = @line
      col = @col
      if (text = take(@no_curly ? /[^<]+/ : /[^<{]+/))
        push_text(text, line, col)
      end
    end

    def scan_text_hole
      line = @line
      col = @col
      code = take_hole_body
      if code.strip.empty?
        fail!("empty interpolation {} (write &#123; for a literal brace)", line: line, col: col)
      end
      @tokens << HoleToken.new(type: :hole, code: code, line: line, col: col)
    end

    def push_text(value, line, col)
      @tokens << TextToken.new(type: :text, value: value, line: line, col: col)
    end

    # -- everything starting with `<` ----------------------------------------

    def scan_angle
      line = @line
      col = @col
      if @s.match?(/<%#/)
        take(/<%#/)
        fail!("unclosed template comment <%# (expected %>)", line: line, col: col) unless take(/.*?%>/m)
        @tokens << CommentToken.new(type: :comment, line: line, col: col)
      elsif @s.match?(/<%/)
        fail!("ERB-style <% tags are not supported; use {...} holes " \
              "(or <%# ... %> for a comment, &lt;% for literal text)")
      elsif @s.match?(/<!--/)
        comment = take(/<!--.*?-->/m) or fail!("unclosed HTML comment <!-- (expected -->)", line: line, col: col)
        push_text(comment, line, col)
      elsif @s.match?(/<!/)
        decl = take(/<![^>]*>/m) or fail!("unclosed <! declaration (expected >)", line: line, col: col)
        push_text(decl, line, col)
      elsif @s.match?(%r{</})
        scan_close_tag
      elsif @s.match?(/<\./)
        take(/<\./)
        name = take(METHOD_NAME) or fail!("expected a component name after `<.`")
        scan_tag_innards(:local, name, line, col)
      elsif @s.match?(/<:/)
        take(/<:/)
        name = take(METHOD_NAME) or fail!("expected a slot name after `<:`")
        scan_tag_innards(:slot, name, line, col)
      elsif @s.match?(/<[A-Z]/)
        take(/</)
        name = take(REMOTE_NAME) or
          fail!("an uppercase tag must be a qualified component call like <Mod.func/> " \
                "(HTML tag names are lowercase)")
        scan_tag_innards(:remote, name, line, col)
      elsif @s.match?(/<[a-z]/)
        take(/</)
        name = take(HTML_NAME)
        scan_tag_innards(:html, name, line, col)
      else
        take(/</)
        push_text("<", line, col)
      end
    end

    def scan_close_tag
      line = @line
      col = @col
      take(%r{</})
      kind, name =
        if take(/\./) then [:local, take(METHOD_NAME)]
        elsif take(/:/) then [:slot, take(METHOD_NAME)]
        elsif @s.match?(/[A-Z]/) then [:remote, take(REMOTE_NAME)]
        else [:html, take(HTML_NAME)]
        end
      fail!("malformed closing tag", line: line, col: col) unless name
      take(/\s+/)
      take(/>/) or fail!("malformed closing tag </#{name} (expected >)", line: line, col: col)
      @tokens << TagToken.new(type: :tag_close, kind: kind, name: name, line: line, col: col)
      exit_no_curly_maybe(kind, name)
    end

    def exit_no_curly_maybe(kind, name)
      return unless @no_curly && kind == :html && name == @no_curly[:name]

      @no_curly[:depth] -= 1
      @no_curly = nil if @no_curly[:depth].zero?
    end

    # Scanner sits right after the tag name.
    def scan_tag_innards(kind, name, line, col)
      attrs = []
      seen = {}
      no_curly_flag = false
      interpolate_flag = false
      self_closing = nil

      loop do
        take(/\s+/)
        if take(%r{/>})
          self_closing = true
          break
        elsif take(/>/)
          self_closing = false
          break
        elsif @s.eos?
          fail!("unclosed tag <#{display_name(kind, name)} (expected > or />)", line: line, col: col)
        elsif @s.match?(/\{/)
          a_line = @line
          a_col = @col
          if @no_curly
            fail!("interpolation is disabled inside <#{@no_curly[:name]} her-no-curly>", line: a_line, col: a_col)
          end
          code = take_hole_body
          fail!("empty interpolation {}", line: a_line, col: a_col) if code.strip.empty?
          attrs << AttrToken.new(name: nil, value: [:splat, code], line: a_line, col: a_col)
        elsif @s.match?(%r{/})
          fail!("unexpected `/` inside tag <#{display_name(kind, name)} (did you mean `/>`?)")
        else
          a_line = @line
          a_col = @col
          attr_name = take(ATTR_NAME) or
            fail!("unexpected character #{@s.peek(1).inspect} inside tag <#{display_name(kind, name)}")
          value = @s.match?(/\s*=/) ? (take(/\s*=\s*/); scan_attr_value(a_line, a_col)) : nil

          case attr_name
          when "her-no-curly"    then no_curly_flag = true
          when "her-interpolate" then interpolate_flag = true
          else
            if seen[attr_name] && kind != :html
              fail!("duplicate attribute `#{attr_name}` on <#{display_name(kind, name)}", line: a_line, col: a_col)
            end
            seen[attr_name] = true
            attrs << AttrToken.new(name: attr_name, value: value, line: a_line, col: a_col)
          end
        end
      end

      void = kind == :html && VOID_ELEMENTS.include?(name)
      @tokens << TagToken.new(
        type: :tag_open, kind: kind, name: name, attrs: attrs,
        self_closing: self_closing, void: void, line: line, col: col, end_line: @line
      )

      return unless kind == :html

      if @no_curly
        @no_curly[:depth] += 1 if name == @no_curly[:name] && !self_closing && !void
      elsif no_curly_flag && !self_closing && !void
        @no_curly = { name: name, depth: 1 }
      end

      if RAW_TEXT_ELEMENTS.include?(name) && !self_closing
        scan_raw_text(name, interpolate_flag && !@no_curly)
      end
    end

    def display_name(kind, name)
      case kind
      when :local then ".#{name}"
      when :slot  then ":#{name}"
      else name
      end
    end

    def scan_attr_value(name_line, name_col)
      if (quote = take(/["']/))
        scan_quoted_value(quote, name_line, name_col)
      elsif @s.match?(/\{/)
        if @no_curly
          fail!("interpolation is disabled inside <#{@no_curly[:name]} her-no-curly>")
        end
        h_line = @line
        h_col = @col
        code = take_hole_body
        fail!("empty interpolation {}", line: h_line, col: h_col) if code.strip.empty?
        [:hole, code]
      else
        value = take(/[^\s>]+/) or fail!("expected an attribute value after `=`")
        [:static, value, nil]
      end
    end

    def scan_quoted_value(quote, name_line, name_col)
      parts = []
      text_re = if @no_curly
                  quote == '"' ? /[^"]+/ : /[^']+/
                else
                  quote == '"' ? /[^"{]+/ : /[^'{]+/
                end
      loop do
        if (chunk = take(text_re))
          parts << [:static, chunk]
        elsif take(Regexp.new(Regexp.escape(quote)))
          break
        elsif @s.match?(/\{/)
          h_line = @line
          h_col = @col
          code = take_hole_body
          fail!("empty interpolation {}", line: h_line, col: h_col) if code.strip.empty?
          parts << [:hole, code]
        else
          fail!("unclosed attribute value (#{quote} opened at #{location_label(name_line, name_col)})",
                line: name_line, col: name_col)
        end
      end

      if parts.none? { |kind, _| kind == :hole }
        [:static, parts.map { |_, s| s }.join, quote]
      else
        [:mixed, parts, quote]
      end
    end

    # <script>/<style> contents: no tags, and no holes unless her-interpolate
    # was given (§8.3). Consumes through the closing tag.
    def scan_raw_text(name, interpolate)
      close_re = %r{</#{name}\s*>}i
      chunk_re = if interpolate
                   /(?:(?!<\/#{name}\s*>)[^{])+/im
                 else
                   /(?:(?!<\/#{name}\s*>).)+/im
                 end
      loop do
        line = @line
        col = @col
        if (chunk = take(chunk_re))
          push_text(chunk, line, col)
        end
        if @s.match?(close_re)
          c_line = @line
          c_col = @col
          take(close_re)
          @tokens << TagToken.new(type: :tag_close, kind: :html, name: name, line: c_line, col: c_col)
          exit_no_curly_maybe(:html, name)
          return
        elsif interpolate && @s.match?(/\{/)
          scan_text_hole
        elsif @s.eos?
          fail!("unclosed <#{name}> — expected </#{name}>")
        end
      end
    end
  end
end
