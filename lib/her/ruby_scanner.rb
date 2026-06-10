# frozen_string_literal: true

require "strscan"

module Her
  # The Ruby-understanding component of the compiler. Three jobs:
  #
  #   * find the `}` that closes a `{...}` hole,
  #   * classify hole code as expression vs control-flow statement (§8.5),
  #   * rewrite the `@name` assign sigil (§4b).
  #
  # Two engines back these. When Prism is available (bundled with Ruby 3.3+,
  # or `gem "prism"` on older rubies) hole code is analyzed with the real
  # Ruby parser: exotic literals (%q[], %w[], regexps, heredocs) terminate
  # holes correctly, `@name` is rewritten by AST offsets (never inside
  # string contents, comments or symbols), assigns are enforced read-only,
  # and invalid Ruby fails at load time with the parser's own message.
  #
  # Without Prism a small hand-written scanner takes over: it understands
  # `"…"`/`'…'` strings (including nested `#{}`) but not exotic literals —
  # braces, quotes or `@` inside those may confuse it. Set HER_NO_PRISM=1
  # to force the fallback engine (used in CI to test it).
  module RubyScanner
    PRISM_AVAILABLE =
      if ENV["HER_NO_PRISM"]
        false
      else
        begin
          require "prism"
          defined?(Prism.parse) ? true : false
        rescue LoadError
          false
        end
      end

    # Raised (and re-raised with template context by codegen) when a
    # template tries to assign to an @assign. Prism engine only.
    class IvarWriteError < StandardError
      def initialize(name)
        super("cannot assign to #{name} — assigns are read-only in templates")
      end
    end

    # kind: nil (expression), :open/:mid/:end/:block (statement), or
    # :invalid (Prism engine only) with the parser's messages.
    Classification = Struct.new(:kind, :messages)

    IVAR = /@[a-zA-Z_][a-zA-Z0-9_]*/

    STMT_OPEN  = /\A(?:if|unless|case|while|until|for|begin)\b/
    STMT_MID   = /\A(?:elsif|else|when|in|rescue|ensure)\b/
    STMT_END   = /\Aend\b/
    BLOCK_TAIL = /\bdo(?:\s*\|[^|]*\|)?\s*\z/

    # Parse-error messages that mean "a string-like literal never closed" —
    # the signature of the heuristic scanner having mistaken a `}` inside an
    # exotic literal for the hole's close. Must NOT match fragment errors
    # like "expected an `end` to close the `if` statement".
    UNTERMINATED_MESSAGE = /closing delimiter|could not find a terminator|unterminated/i

    module_function

    def prism?
      PRISM_AVAILABLE
    end

    # -- hole termination -------------------------------------------------------

    # +rest+ is the source immediately after a hole's `{`. Returns the byte
    # index of the closing `}` (== byte length of the code), or nil when the
    # hole never closes.
    def hole_code_length(rest)
      # Phase 1: string-aware depth scan — cheap, correct for ~all templates.
      scanner = StringScanner.new(rest)
      status = catch(:her_hole_unclosed) do
        scan_hole_body(scanner, on_eof: -> { throw :her_hole_unclosed, :eof })
        :ok
      end
      heuristic_end = status == :ok ? scanner.pos - 1 : nil
      return heuristic_end unless prism?

      # Phase 2 (Prism): if the candidate ends mid-literal, the `}` we found
      # was inside an exotic literal — extend through successive raw `}`
      # positions until the code parses as complete Ruby.
      if heuristic_end
        result = Prism.parse(rest.byteslice(0, heuristic_end))
        return heuristic_end if result.success? || !unterminated_literal?(result)
      end
      bytes = rest.b
      from = heuristic_end ? heuristic_end + 1 : 0
      while (idx = bytes.index("}", from))
        return idx if Prism.parse(rest.byteslice(0, idx)).success?
        from = idx + 1
      end
      heuristic_end # may be nil (unclosed) or garbage code — later stages report it
    end

    def unterminated_literal?(parse_result)
      parse_result.errors.any? do |error|
        error.message.match?(UNTERMINATED_MESSAGE) ||
          (error.respond_to?(:type) && error.type.to_s.match?(/unterminated/))
      end
    end

    # -- classification (§8.5) ----------------------------------------------------

    # Classify hole code for control flow. `end` and mid-keywords (elsif/
    # else/when/in/rescue/ensure) are decided by keyword — they can never
    # start an expression. With Prism, everything else is decided by the
    # parser: a complete expression is an expression hole (so `{if x then a
    # else b end}` renders its value); a fragment starting with an opener
    # keyword or ending in `do |...|` is a statement; anything else is
    # invalid and reported with the parser's message.
    def classify(code)
      stripped = code.strip
      return Classification.new(:end, nil) if stripped.match?(STMT_END)
      return Classification.new(:mid, nil) if stripped.match?(STMT_MID)

      unless prism?
        return Classification.new(:open, nil) if stripped.match?(STMT_OPEN)
        return Classification.new(:block, nil) if stripped.match?(BLOCK_TAIL)
        return Classification.new(nil, nil)
      end

      result = Prism.parse(code)
      if result.success?
        if result.value.statements.body.empty?
          Classification.new(:invalid, ["contains no expression (only comments or whitespace)"])
        else
          Classification.new(nil, nil)
        end
      else
        return Classification.new(:open, nil) if stripped.match?(STMT_OPEN)
        return Classification.new(:block, nil) if stripped.match?(BLOCK_TAIL)
        Classification.new(:invalid, result.errors.map(&:message).uniq)
      end
    end

    # Back-compat shim.
    def statement_kind(code)
      classify(code).kind
    end

    # -- assign rewriting (§4b) -----------------------------------------------------

    # Rewrite hole code for emission into the generated method:
    #
    #   * every `@name` read in code position becomes the block's return
    #     value (§4b),
    #   * bare `render_slot(...)`/`slot?(...)` calls become
    #     `::Her.render_slot(__slots, ...)` — slot context is passed as
    #     plain data, no global state.
    #
    # +kind+ is the hole's statement classification — fragments are wrapped
    # into parseable Ruby for the Prism engine. Raises IvarWriteError on
    # assignment to an @assign (Prism engine).
    def rewrite_hole_code(code, kind: nil, &replacement)
      return code if kind == :end
      return rewrite_hole_code_heuristic(code, &replacement) unless prism?

      wrapped, shift = wrap_fragment(code, kind)
      result = Prism.parse(wrapped)
      # Shouldn't happen — classification accepted this code — but degrade
      # gracefully rather than fail.
      return rewrite_hole_code_heuristic(code, &replacement) unless result.success?

      collector = RewriteCollector.new
      result.value.accept(collector)
      if (write = collector.writes.first)
        raise IvarWriteError.new(write.name)
      end

      in_range = ->(offset) { offset >= shift && offset < shift + code.bytesize }
      edits = []
      collector.reads.each do |node|
        next unless in_range.call(node.location.start_offset)
        edits << [node.location.start_offset - shift, node.location.length,
                  replacement.call(node.name[1..].to_sym)]
      end
      collector.slot_calls.each do |node|
        next unless in_range.call(node.message_loc.start_offset)
        edits << slot_call_edit(node, shift)
      end
      return code if edits.empty?

      out = +""
      cursor = 0
      edits.sort_by!(&:first)
      edits.each do |start, length, text|
        out << code.byteslice(cursor, start - cursor)
        out << text
        cursor = start + length
      end
      out << code.byteslice(cursor, code.bytesize - cursor)
      out.force_encoding(code.encoding)
    end

    # Splice for one bare render_slot/slot? call: replace the message (and
    # opening paren, when present) so __slots becomes the first argument.
    def slot_call_edit(node, shift)
      start = node.message_loc.start_offset - shift
      if node.opening_loc # render_slot(:x) / render_slot()
        length = node.opening_loc.end_offset - node.message_loc.start_offset
        [start, length, "::Her.#{node.name}(__slots#{node.arguments ? ', ' : ''}"]
      elsif node.arguments # command form: render_slot :x
        [start, node.message_loc.length, "::Her.#{node.name} __slots,"]
      else # bare: render_slot || fallback
        [start, node.message_loc.length, "::Her.#{node.name}(__slots)"]
      end
    end

    # Statement fragments are not complete Ruby; wrap them into the smallest
    # construct that parses, and remember the prefix size so node offsets
    # can be mapped back onto the original code.
    def wrap_fragment(code, kind)
      stripped = code.strip
      case kind
      when :open
        if stripped.match?(/\Acase\b/)
          ["#{code}\nwhen nil\nend", 0]
        else
          ["#{code}\nend", 0]
        end
      when :block
        ["#{code}\nend", 0]
      when :mid
        prefix =
          case stripped[/\A[a-z]+/]
          when "elsif", "else"    then "if nil\n"
          when "when", "in"       then "case nil\n"
          when "rescue", "ensure" then "begin\n"
          end
        prefix ? ["#{prefix}#{code}\nend", prefix.bytesize] : [code, 0]
      else
        [code, 0]
      end
    end

    if PRISM_AVAILABLE
      # Collects @ivar reads (to rewrite), ivar writes (to reject), and bare
      # render_slot/slot? calls (to thread the slot context through). The
      # default visitor traverses children when we call super, so nodes
      # inside `#{...}` interpolation are found while string text is not.
      class RewriteCollector < Prism::Visitor
        attr_reader :reads, :writes, :slot_calls

        def initialize
          @reads = []
          @writes = []
          @slot_calls = []
          super()
        end

        def visit_call_node(node)
          if node.receiver.nil? && (node.name == :render_slot || node.name == :slot?)
            @slot_calls << node
          end
          super
        end

        def visit_instance_variable_read_node(node)
          @reads << node
          super
        end

        def visit_instance_variable_write_node(node)
          @writes << node
          super
        end

        def visit_instance_variable_operator_write_node(node)
          @writes << node
          super
        end

        def visit_instance_variable_or_write_node(node)
          @writes << node
          super
        end

        def visit_instance_variable_and_write_node(node)
          @writes << node
          super
        end

        def visit_instance_variable_target_node(node)
          @writes << node
          super
        end
      end
    end

    # == The heuristic engine =====================================================
    # Used when Prism is unavailable, and internally for phase-1 hole
    # termination and `#{}` recursion. Understands "…"/'…' strings (with
    # nested interpolation) but not exotic literals.

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

    # Heuristic hole rewrite: `@name` reads and bare render_slot/slot? calls,
    # skipping string contents (but descending into `#{...}`), comments,
    # `@@class_vars`, and tokens preceded by a word character or receiver.
    def rewrite_hole_code_heuristic(code, &replacement)
      out = +""
      catch(:her_scan_eof) do
        eof = -> { throw :her_scan_eof }
        scanner = StringScanner.new(code)
        until scanner.eos?
          if (chunk = scanner.scan(/[^"'@#a-z]+/))
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
          elsif (call = scanner.scan(/(?:render_slot|slot\?)(?![\w?])/))
            if out.match?(/[\w.:@$]\z/) # receiver call, symbol, etc — not ours
              out << call
            else
              out << heuristic_slot_call(call, scanner)
            end
          elsif (word = scanner.scan(/[a-z][a-zA-Z0-9_]*[!?]?/))
            out << word
          else
            out << scanner.getch
          end
        end
      end
      out
    end

    # Heuristic counterpart of slot_call_edit: paren and bare forms only
    # (the command form `render_slot :x` needs the Prism engine).
    def heuristic_slot_call(name, scanner)
      if scanner.scan(/\s*\(/)
        "::Her.#{name}(__slots#{scanner.match?(/\s*\)/) ? '' : ', '}"
      else
        "::Her.#{name}(__slots)"
      end
    end

    # -- internals ----------------------------------------------------------------

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
          out << "\#{" << rewrite_hole_code_heuristic(body, &replacement) << "}"
        elsif scanner.scan(/#/)
          out << "#"
        elsif scanner.scan(/"/)
          return out
        end
      end
    end
  end
end
