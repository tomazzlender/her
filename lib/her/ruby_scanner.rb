# frozen_string_literal: true

require "strscan"

module Her
  # A deliberately small scanner for the Ruby code inside `{...}` holes.
  #
  # It does NOT parse Ruby (§6). It knows just enough to:
  #
  #   * find the `}` that closes a hole, counting brace depth while skipping
  #     braces that occur inside string literals (including nested `#{...}`
  #     interpolation), and
  #   * rewrite the `@name` assign sigil (§4b) everywhere except inside
  #     string contents, comments, class variables, and email-looking text.
  #
  # Exotic literals (%w[], regexps, heredocs) are not understood; braces,
  # quotes or `@` inside those may confuse it. Hole code should stay small —
  # anything bigger belongs in a helper method on the component module.
  module RubyScanner
    IVAR = /@[a-zA-Z_][a-zA-Z0-9_]*/

    STMT_OPEN  = /\A(?:if|unless|case|while|until|for|begin)\b/
    STMT_MID   = /\A(?:elsif|else|when|in|rescue|ensure)\b/
    STMT_END   = /\Aend\b/
    BLOCK_TAIL = /\bdo(?:\s*\|[^|]*\|)?\s*\z/

    module_function

    # Classify hole code for control flow (§8.5). Returns nil for a plain
    # expression hole, otherwise :open, :mid, :end or :block.
    def statement_kind(code)
      stripped = code.strip
      return :open  if stripped.match?(STMT_OPEN)
      return :mid   if stripped.match?(STMT_MID)
      return :end   if stripped.match?(STMT_END)
      return :block if stripped.match?(BLOCK_TAIL)
      nil
    end

    # +scanner+ must be positioned just after an opening `{`. Consumes up to
    # and including the matching `}` and returns the code between them.
    # +on_eof+ is called (and must raise/throw) if the hole never closes.
    def scan_hole_body(scanner, on_eof:)
      out = +""
      depth = 1
      until scanner.eos?
        if (chunk = scanner.scan(/[^{}"']+/))
          out << chunk
        elsif scanner.scan(/\{/)
          depth += 1
          out << "{"
        elsif scanner.scan(/\}/)
          depth -= 1
          return out if depth.zero?
          out << "}"
        elsif scanner.scan(/"/)
          out << '"' << consume_double_quoted(scanner, on_eof: on_eof) << '"'
        elsif scanner.scan(/'/)
          out << "'" << consume_single_quoted(scanner, on_eof: on_eof) << "'"
        end
      end
      on_eof.call
    end

    # Rewrite every `@name` that occurs in code position using the block's
    # return value. Skips string contents (but descends into `#{...}`),
    # comments, `@@class_vars`, and `@` preceded by a word character.
    def rewrite_assigns(code, &replacement)
      out = +""
      catch(:her_scan_eof) do
        eof = -> { throw :her_scan_eof }
        scanner = StringScanner.new(code)
        until scanner.eos?
          if (chunk = scanner.scan(/[^"'@#]+/))
            out << chunk
          elsif scanner.scan(/"/)
            out << '"' << rewrite_double_quoted(scanner, eof, &replacement) << '"'
          elsif scanner.scan(/'/)
            out << "'" << consume_single_quoted(scanner, on_eof: eof) << "'"
          elsif (comment = scanner.scan(/#[^\n]*/))
            out << comment
          elsif (ivar = scanner.scan(IVAR))
            if out.match?(/[\w@]\z/)
              out << ivar
            else
              out << replacement.call(ivar[1..].to_sym)
            end
          else
            out << scanner.getch
          end
        end
      end
      out
    end

    # -- internals ----------------------------------------------------------

    def consume_double_quoted(scanner, on_eof:)
      out = +""
      loop do
        on_eof.call if scanner.eos?
        if (chunk = scanner.scan(/[^"\\#]+/))
          out << chunk
        elsif scanner.scan(/\\/)
          out << "\\" << (scanner.getch || on_eof.call)
        elsif scanner.scan(/\#\{/)
          out << "\#{" << scan_hole_body(scanner, on_eof: on_eof) << "}"
        elsif scanner.scan(/#/)
          out << "#"
        elsif scanner.scan(/"/)
          return out
        end
      end
    end

    def consume_single_quoted(scanner, on_eof:)
      out = +""
      loop do
        on_eof.call if scanner.eos?
        if (chunk = scanner.scan(/[^'\\]+/))
          out << chunk
        elsif scanner.scan(/\\/)
          out << "\\" << (scanner.getch || on_eof.call)
        elsif scanner.scan(/'/)
          return out
        end
      end
    end

    # Like consume_double_quoted, but `#{...}` bodies are themselves
    # assign-rewritten — `{"alert alert-#{@kind}"}` must see @kind.
    def rewrite_double_quoted(scanner, eof, &replacement)
      out = +""
      loop do
        eof.call if scanner.eos?
        if (chunk = scanner.scan(/[^"\\#]+/))
          out << chunk
        elsif scanner.scan(/\\/)
          out << "\\" << (scanner.getch || eof.call)
        elsif scanner.scan(/\#\{/)
          body = scan_hole_body(scanner, on_eof: eof)
          out << "\#{" << rewrite_assigns(body, &replacement) << "}"
        elsif scanner.scan(/#/)
          out << "#"
        elsif scanner.scan(/"/)
          return out
        end
      end
    end
  end
end
