# frozen_string_literal: true

module Her
  # Stage ③ of the pipeline (§6): walk the tree and emit the body of a
  # `def self.name(assigns = {}, __slots = nil, &__inner)` method.
  #
  # Line mapping: the generated source is laid out so that code produced for
  # template line N sits on generated line N + 1 (line 1 is a single packed
  # header). Compiler evals it with `lineno = first_line - 1`, which makes
  # every Ruby backtrace and SyntaxError point at the author's template line.
  class Codegen
    def initialize(tree, name:, mode:, attrs: nil, module_label: nil, file: nil, first_line: 1)
      @tree = tree
      @name = name
      @mode = mode # :declared (component with attrs) or :free (§3c)
      @attrs = attrs || {}
      @module_label = module_label
      @file = file
      @first_line = first_line

      @out = +""
      @gen_line = 1        # template line the current output line corresponds to
      @line_has_code = false
      @static = +""
      @static_line = nil
      @static_buf = nil
      @var_serial = 0
      @swallow_blank_text = false
      trim_tree!(@tree)
      @uses_slots = tree_uses_slots?(@tree)
      @annotate = Her.debug_annotations

      # Call-site metadata for Her.verify, collected while walking (§ verify).
      @calls = []
      @rendered_slot_names = []
      @dynamic_slot_render = false
    end

    # Component calls this template makes, for boot-time verification.
    attr_reader :calls

    # Slot names this template renders (via <:name/> tags and literal
    # render_slot/slot? calls in holes).
    def rendered_slots
      @rendered_slot_names.uniq
    end

    # True when a render_slot/slot? call with a non-literal name was seen —
    # the rendered-slot set is then open and slot checks must be skipped.
    def dynamic_slot_render?
      @dynamic_slot_render
    end

    # Returns the full generated source. Line 1 is the header; the method
    # body starts on line 2 == template line 1.
    def generate
      @out << header << "\n"
      walk_children(@tree.children, "__buf")
      flush_static
      @out << "\n" unless @out.end_with?("\n")
      @out << "__buf << #{string_literal("<!-- </#{label}> -->")}.freeze\n" if @annotate
      @out << "::Her::Safe.new(__buf)\n"
      @out << "end\n"
      @out
    end

    private

    # -- header ---------------------------------------------------------------

    def header
      parts = ["def self.#{@name}(assigns = {}, __slots = nil, &__inner)"]
      if @mode == :declared
        @attrs.each do |key, opts|
          next unless opts[:required]
          parts << "assigns.key?(#{key.inspect}) or ::Her::MissingAttr.raise_for(self, #{@name.inspect}, #{key.inspect})"
        end
        if @attrs.any? { |_, opts| opts.key?(:default) }
          parts << "assigns = __her_defaults(#{@name.inspect}).merge(assigns)"
        end
        # After the defaults merge, so a default (or explicit hash) becomes
        # the base the collected attrs override.
        if (global = @attrs.find { |_, opts| opts[:type] == :global })
          declared_keys = (@attrs.keys - [global.first]).inspect
          parts << "assigns = ::Her.collect_global(assigns, #{global.first.inspect}, #{declared_keys})"
        end
        if @attrs.any? { |_, opts| (opts[:type] && ![:any, :global].include?(opts[:type])) || opts[:values] }
          parts << "::Her.check_attrs!(self, #{@name.inspect}, assigns, __her_attr_checks(#{@name.inspect}))"
        end
      end
      if @uses_slots
        parts << "__slots = __slots ? __slots.dup : {}"
        parts << "(__slots[:inner] ||= [__inner]) if __inner"
      end
      parts << "__buf = +''"
      if @annotate
        origin_label = [@file, @first_line].compact.join(":")
        parts << "__buf << #{string_literal("<!-- <#{label}> #{origin_label} -->")}.freeze"
      end
      parts.join("; ")
    end

    # -- statement-line trimming -------------------------------------------------
    # A template line that contains only control-flow holes leaves a blank
    # line in the output; trim its indentation and newline, Erubi-style.
    # Trimming only ever removes newlines, so the template-line sync simply
    # re-pads — backtrace mapping is preserved.

    def trim_tree!(node)
      case node
      when Parser::Root
        trim_statement_lines!(node.children, root: true)
        node.children.each { |child| trim_tree!(child) }
      when Parser::ElementNode, Parser::SlotDefNode, Parser::SlotRenderNode
        trim_statement_lines!(node.children, root: false)
        node.children.each { |child| trim_tree!(child) }
      when Parser::ComponentNode
        trim_statement_lines!(node.children, root: false)
        node.children.each { |child| trim_tree!(child) }
        node.slot_defs.each_value { |defs| defs.each { |slot_def| trim_tree!(slot_def) } }
      end
    end

    def trim_statement_lines!(children, root:)
      trimmed = []
      children.each_with_index do |child, index|
        next unless child.is_a?(Parser::HoleNode) && child.statement
        next unless line_start_before?(children, index, root, trimmed)
        next unless line_end_after?(children, index)
        trimmed << index
        prev_node = index.positive? ? children[index - 1] : nil
        next_node = children[index + 1]
        prev_node.value = prev_node.value.sub(/[ \t]+\z/, "") if prev_node.is_a?(Parser::TextNode)
        next_node.value = next_node.value.sub(/\A[ \t]*\r?\n/, "") if next_node.is_a?(Parser::TextNode)
      end
    end

    def line_start_before?(children, index, root, trimmed)
      prev_node = index.positive? ? children[index - 1] : nil
      case prev_node
      when nil
        root # element/component children begin mid-line, after their tag
      when Parser::TextNode
        value = prev_node.value
        value.match?(/\n[ \t]*\z/) || value.empty? ||
          (root && index == 1 && value.match?(/\A[ \t]*\z/))
      when Parser::HoleNode
        trimmed.include?(index - 1) # statements sharing an owned line
      else
        false
      end
    end

    def line_end_after?(children, index)
      next_node = children[index + 1]
      case next_node
      when nil
        true # the "line" ends with the template/scope
      when Parser::TextNode
        next_node.value.match?(/\A[ \t]*\r?\n/) ||
          (children[index + 2].nil? && next_node.value.match?(/\A[ \t]*\z/))
      when Parser::HoleNode
        !!next_node.statement
      else
        false
      end
    end

    # -- emission with template-line sync -------------------------------------

    # continue: true appends a fragment of the expression currently being
    # built (inside parens/brackets a `;` would be a syntax error); the
    # default starts a new statement.
    def emit(code, at_line, continue: false)
      if at_line > @gen_line
        @out << ("\n" * (at_line - @gen_line))
        @gen_line = at_line
        @line_has_code = false
      end
      @out << (continue ? " " : "; ") if @line_has_code
      @out << code
      @gen_line += code.count("\n")
      @line_has_code = !code.end_with?("\n")
    end

    # Consecutive static output merges into one append; switching to another
    # buffer (entering/leaving a lambda body) flushes first.
    def add_static(str, line, buf)
      return if str.empty?
      flush_static if @static_buf && @static_buf != buf
      if @static.empty?
        @static_line = line
        @static_buf = buf
      end
      @static << str
    end

    def flush_static
      return if @static.empty?
      emit("#{@static_buf} << #{string_literal(@static)}.freeze", @static_line)
      @static = +""
      @static_line = nil
      @static_buf = nil
    end

    def string_literal(str)
      %("#{escape_for_dquote(str)}")
    end

    def escape_for_dquote(str)
      str.gsub(/[\\"#]/) { |c| "\\#{c}" }
    end

    def fresh_var(prefix)
      @var_serial += 1
      "#{prefix}#{@var_serial}"
    end

    def origin(line)
      return "" unless @file
      " (#{@file}:#{@first_line + line - 1})"
    end

    def label
      [@module_label, @name].compact.join(".")
    end

    # -- assign rewriting (§4b) ------------------------------------------------

    def rewrite(code, line, kind: nil)
      scan_slot_calls(code)
      RubyScanner.rewrite_hole_code(code, kind: kind) do |key|
        if @mode == :declared
          unless @attrs.key?(key)
            declared = @attrs.keys.map(&:inspect).join(", ")
            declared = "none" if declared.empty?
            raise CompileError,
                  "#{label}: template references undeclared attr @#{key}#{origin(line)} — " \
                  "declare it with `attr #{key.inspect}` (declared: #{declared})"
          end
          "assigns[#{key.inspect}]"
        else
          "::Her.fetch!(assigns, #{key.inspect}, self, #{@name.inspect})"
        end
      end
    rescue RubyScanner::IvarWriteError => e
      raise CompileError, "#{label}: #{e.message}#{origin(line)}"
    end

    # A trailing Ruby comment in hole code would swallow the rest of the
    # generated line (including our closing parens); a newline ends it.
    def comment_safe(code)
      code.include?("#") ? "#{code}\n" : code
    end

    # -- tree walking ----------------------------------------------------------

    def walk_children(children, buf)
      children.each do |child|
        next if @swallow_blank_text && child.is_a?(Parser::TextNode) && child.value.strip.empty?
        @swallow_blank_text = false
        walk(child, buf)
      end
    end

    def walk(node, buf)
      case node
      when Parser::TextNode       then add_static(node.value, node.line, buf)
      when Parser::HoleNode       then walk_hole(node, buf)
      when Parser::ElementNode    then walk_element(node, buf)
      when Parser::ComponentNode  then walk_component(node, buf)
      when Parser::SlotRenderNode then walk_slot_render(node, buf)
      when Parser::SlotDefNode
        raise CompileError,
              "#{label}: slot <:#{node.name}> must be a direct child of a component call#{origin(node.line)}"
      end
    end

    def walk_hole(node, buf)
      flush_static
      code = rewrite(node.code, node.line, kind: node.statement)
      if node.statement
        emit(comment_safe(code), node.line)
        # `case` must be followed directly by `when`: swallow the
        # whitespace-only text between them (§8.5).
        @swallow_blank_text = true if node.code.strip.match?(/\Acase\b/)
      else
        emit("#{buf} << ::Her.safe((#{comment_safe(code)}))", node.line)
      end
    end

    # -- plain HTML elements ----------------------------------------------------

    def walk_element(node, buf)
      add_static("<#{node.name}", node.line, buf)
      emit_element_attrs(node, buf)
      if node.void
        add_static(node.self_closing ? "/>" : ">", node.line, buf)
      elsif node.self_closing
        add_static("></#{node.name}>", node.line, buf)
      else
        add_static(">", node.line, buf)
        walk_children(node.children, buf)
        add_static("</#{node.name}>", node.end_line, buf)
      end
    end

    def emit_element_attrs(node, buf)
      node.attrs.each do |attr|
        value = attr.value
        if value.nil?
          add_static(" #{attr.name}", attr.line, buf)
          next
        end
        case value[0]
        when :static
          _, text, quote = value
          if quote
            add_static(" #{attr.name}=#{quote}#{text}#{quote}", attr.line, buf)
          else
            add_static(" #{attr.name}=#{text}", attr.line, buf)
          end
        when :hole
          code = value[1]
          assert_expression!(code, attr.line, "attribute `#{attr.name}`")
          flush_static
          emit("#{buf} << ::Her.attr_pair(#{attr.name.inspect}, (#{comment_safe(rewrite(code, attr.line))}))", attr.line)
        when :mixed
          _, parts, quote = value
          add_static(" #{attr.name}=#{quote}", attr.line, buf)
          parts.each do |kind, part|
            if kind == :static
              add_static(part, attr.line, buf)
            else
              assert_expression!(part, attr.line, "attribute `#{attr.name}`")
              flush_static
              emit("#{buf} << ::Her.safe((#{comment_safe(rewrite(part, attr.line))}))", attr.line)
            end
          end
          add_static(quote, attr.line, buf)
        when :splat
          code = value[1]
          assert_expression!(code, attr.line, "attribute splat")
          flush_static
          emit("#{buf} << ::Her.splat_attrs((#{comment_safe(rewrite(code, attr.line))}))", attr.line)
        end
      end
    end

    def assert_expression!(code, line, where)
      classification = RubyScanner.classify(code)
      return if classification.kind.nil?
      if classification.kind == :invalid
        raise CompileError,
              "#{label}: invalid Ruby in #{where}#{origin(line)}: " \
              "#{classification.messages.join('; ')}"
      end
      raise CompileError,
            "#{label}: control-flow statements are not allowed in #{where}#{origin(line)} — " \
            "only expressions can appear there"
    end

    # Every hole's code passes through rewrite, so this sees all slot usage.
    # First arg shapes: `:sym` is a literal name; bare/empty-paren calls
    # render :inner; anything else makes the rendered-slot set dynamic.
    def scan_slot_calls(code)
      code.scan(/\b(?:render_slot|slot\?)\s*(?:\(\s*([^,)\s]+)?)?/) do |arg,|
        if arg.nil?
          @rendered_slot_names << :inner
        elsif arg.match?(/\A:[a-zA-Z_]\w*\z/)
          @rendered_slot_names << arg[1..].to_sym
        else
          @dynamic_slot_render = true
        end
      end
    end

    # -- component calls (§6) ----------------------------------------------------

    def walk_component(node, buf)
      record_call(node)
      flush_static
      receiver = node.kind == :local ? "self.#{node.name}" : node.name
      let_params, args = component_args(node)
      emit("#{buf} << ::Her.safe(#{receiver}(#{args}", node.line)

      emit_slot_defs(node) if node.slot_defs.any?

      if node.children.any?
        emit(") do#{let_params ? " |#{let_params}|" : ""}", node.line, continue: true)
        emit_lambda_body(node.children, node.line, node.end_line)
        emit("end)", node.end_line, continue: true)
      else
        emit("))", node.end_line, continue: true)
      end
    end

    # Record what is statically knowable about a component call: attr names
    # are always literal in HER, and so are some values — [:static, text]
    # and [:bare] (true) can be type/values-checked at verify time, [:mixed]
    # is a String of unknown content, [:dynamic] is opaque. A splat makes
    # the attr set open-ended; children count as passing the :inner slot.
    def record_call(node)
      attrs = {}
      splat = false
      node.attrs.each do |attr|
        value = attr.value
        if value.is_a?(Array) && value[0] == :splat
          splat = true
        elsif attr.name != "let"
          attrs[attr.name.to_sym] = attr_descriptor(value)
        end
      end
      slots = node.slot_defs.keys
      slots += [:inner] if node.children.any?
      @calls << { kind: node.kind, name: node.name, attrs: attrs, splat: splat,
                  slots: slots, line: node.line }
    end

    def attr_descriptor(value)
      return [:bare] if value.nil?
      case value[0]
      when :static then [:static, value[1]]
      when :mixed  then [:mixed]
      else [:dynamic]
      end
    end

    # Returns [let_params_or_nil, args_hash_source]. Splat attributes split
    # the literal hash into a left-to-right .merge chain so later attributes
    # still win.
    def component_args(node)
      let_params = nil
      segments = []
      pairs = []

      node.attrs.each do |attr|
        value = attr.value
        if value.is_a?(Array) && value[0] == :splat
          assert_expression!(value[1], attr.line, "attribute splat")
          segments << "{#{pairs.join(', ')}}" unless pairs.empty?
          pairs = []
          segments << "((#{comment_safe(rewrite(value[1], attr.line))}) || {})"
        elsif attr.name == "let"
          let_params = parse_let(attr)
        else
          pairs << "#{attr.name.to_sym.inspect} => #{attr_value_expr(attr)}"
        end
      end

      segments << "{#{pairs.join(', ')}}" unless pairs.empty?
      args = segments.empty? ? "{}" : segments.reduce { |acc, seg| "#{acc}.merge(#{seg})" }
      [let_params, args]
    end

    def attr_value_expr(attr)
      value = attr.value
      return "true" if value.nil?

      case value[0]
      when :static
        string_literal(value[1])
      when :hole
        assert_expression!(value[1], attr.line, "attribute `#{attr.name}`")
        "(#{comment_safe(rewrite(value[1], attr.line))})"
      when :mixed
        inner = value[1].map do |kind, part|
          if kind == :static
            escape_for_dquote(part)
          else
            assert_expression!(part, attr.line, "attribute `#{attr.name}`")
            "\#{#{rewrite(part, attr.line)}}"
          end
        end.join
        %("#{inner}")
      end
    end

    def parse_let(attr)
      value = attr.value
      code = value[1] if value.is_a?(Array) && value[0] == :hole
      unless code&.match?(/\A\s*[a-z_]\w*(\s*,\s*[a-z_]\w*)*\s*\z/)
        raise CompileError,
              "#{label}: `let` must be `let={name}` or `let={a, b}`#{origin(attr.line)}"
      end
      code.split(",").map(&:strip).map { |n| "#{n} = nil" }.join(", ") + ", *"
    end

    def emit_slot_defs(node)
      emit(", {", node.line, continue: true)
      node.slot_defs.each do |slot_name, defs|
        emit("#{slot_name.inspect} => [", defs.first.line, continue: true)
        defs.each do |slot_def|
          emit("lambda { |#{slot_let_params(slot_def)}|", slot_def.line, continue: true)
          emit_lambda_body(slot_def.children, slot_def.line, slot_def.end_line)
          emit("},", slot_def.end_line, continue: true)
        end
        emit("],", defs.last.end_line, continue: true)
      end
      emit("}", node.slot_defs.values.last.last.end_line, continue: true)
    end

    def slot_let_params(slot_def)
      let = nil
      slot_def.attrs.each do |attr|
        if attr.name == "let"
          let = parse_let(attr)
        else
          raise CompileError,
                "#{label}: slot <:#{slot_def.name}> only accepts a `let` attribute, " \
                "got `#{attr.name}`#{origin(attr.line)}"
        end
      end
      let || "*"
    end

    # Children of a component call / slot definition compile to a lambda
    # with its own buffer. Slot renders inside the lambda reference the
    # defining method's `__slots` local through the closure — which is
    # exactly what makes slot resolution lexical, with no runtime state.
    def emit_lambda_body(children, start_line, end_line)
      lambda_buf = fresh_var("__buf")
      emit("#{lambda_buf} = +''", start_line)
      walk_children(children, lambda_buf)
      flush_static
      emit("::Her::Safe.new(#{lambda_buf})", end_line)
    end

    # -- slot rendering -----------------------------------------------------------

    def walk_slot_render(node, buf)
      @rendered_slot_names << node.name.to_sym
      flush_static
      node.attrs.each do |attr|
        raise CompileError,
              "#{label}: slot render <:#{node.name}> takes no attributes#{origin(attr.line)} — " \
              "use {render_slot(#{node.name.to_sym.inspect}, args...)} to pass arguments"
      end
      if node.children.empty?
        emit("#{buf} << ::Her.render_slot(__slots, #{node.name.to_sym.inspect}).to_s", node.line)
      else
        slot_var = fresh_var("__slot")
        emit("if (#{slot_var} = ::Her.render_slot(__slots, #{node.name.to_sym.inspect}))", node.line)
        emit("#{buf} << #{slot_var}.to_s", node.line)
        emit("else", node.line)
        walk_children(node.children, buf)
        flush_static
        emit("end", node.end_line)
      end
    end

    # -- analysis -----------------------------------------------------------------

    SLOT_CALL = /\brender_slot\b|\bslot\?/

    def tree_uses_slots?(node)
      case node
      when Parser::Root
        node.children.any? { |c| tree_uses_slots?(c) }
      when Parser::SlotRenderNode
        true
      when Parser::HoleNode
        node.code.match?(SLOT_CALL)
      when Parser::ElementNode
        node.attrs.any? { |a| attr_uses_slots?(a) } || node.children.any? { |c| tree_uses_slots?(c) }
      when Parser::ComponentNode
        node.attrs.any? { |a| attr_uses_slots?(a) } ||
          node.children.any? { |c| tree_uses_slots?(c) } ||
          node.slot_defs.values.flatten.any? { |d| tree_uses_slots?(d) }
      when Parser::SlotDefNode
        node.children.any? { |c| tree_uses_slots?(c) }
      else
        false
      end
    end

    def attr_uses_slots?(attr)
      value = attr.value
      return false unless value.is_a?(Array)

      case value[0]
      when :hole, :splat
        value[1].match?(SLOT_CALL)
      when :mixed
        value[1].any? { |kind, part| kind == :hole && part.match?(SLOT_CALL) }
      else
        false
      end
    end
  end
end
