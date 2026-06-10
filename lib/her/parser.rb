# frozen_string_literal: true

module Her
  # Stage ② of the pipeline (§6): fold the flat token stream into a tree,
  # matching open/close tags with a stack.
  #
  # Strictness (§8.1): tags must balance lexically within their scope, but
  # control-flow statement holes are *transparent* — they are linear
  # statements, not tree scopes — so the conditional-wrapper pattern
  # (`{if @x}<a href=...>{end} ... {if @x}</a>{end}`) parses and compiles.
  # Component and slot bodies ARE hard scopes: their children become a
  # lambda, so a tag opened inside must close inside.
  class Parser
    TextNode = Struct.new(:value, :line, keyword_init: true)
    # statement: nil for expression holes, else :open/:mid/:end/:block (§8.5)
    HoleNode = Struct.new(:code, :line, :statement, keyword_init: true)
    ElementNode = Struct.new(:name, :attrs, :children, :self_closing, :void, :line, :end_line, keyword_init: true)
    # kind: :local ("button") or :remote ("Mod.func"); slot_defs: {name => [SlotDefNode]}
    ComponentNode = Struct.new(:kind, :name, :attrs, :children, :slot_defs, :line, :end_line, keyword_init: true)
    SlotDefNode = Struct.new(:name, :attrs, :children, :line, :end_line, keyword_init: true)
    # children = fallback content, rendered when the slot was not provided
    SlotRenderNode = Struct.new(:name, :attrs, :children, :line, :end_line, keyword_init: true)
    Root = Struct.new(:children)

    def initialize(tokens, file:, first_line: 1, source: nil)
      @tokens = tokens
      @file = file
      @first_line = first_line
      @source = source
    end

    def parse
      root = Root.new([])
      stack = [[root, nil]] # [node, open_token]

      @tokens.each do |token|
        parent = stack.last[0]
        case token.type
        when :text
          parent.children << TextNode.new(value: token.value, line: token.line)
        when :hole
          classification = RubyScanner.classify(token.code)
          if classification.kind == :invalid
            fail!("invalid Ruby in interpolation: #{classification.messages.join('; ')}",
                  token.line, token.col)
          end
          parent.children << HoleNode.new(
            code: token.code, line: token.line,
            statement: classification.kind
          )
        when :tag_open
          node = build_node(token, parent)
          parent.children << node
          stack.push([node, token]) unless token.self_closing || token.void
        when :tag_close
          close_tag(stack, token)
        end
      end

      if stack.size > 1
        _node, open_token = stack.last
        fail!("unclosed tag <#{tag_label(open_token)}> (opened at #{location(open_token.line, open_token.col)})",
              open_token.line, open_token.col)
      end

      root
    end

    private

    def build_node(token, parent)
      case token.kind
      when :html
        ElementNode.new(
          name: token.name, attrs: token.attrs, children: [],
          self_closing: token.self_closing, void: token.void,
          line: token.line, end_line: token.line
        )
      when :local, :remote
        ComponentNode.new(
          kind: token.kind, name: token.name, attrs: token.attrs,
          children: [], slot_defs: {}, line: token.line, end_line: token.line
        )
      when :slot
        # A slot tag that is a DIRECT child of a component call defines a
        # slot; anywhere else it renders one (children = fallback content).
        if parent.is_a?(ComponentNode)
          SlotDefNode.new(name: token.name, attrs: token.attrs, children: [],
                          line: token.line, end_line: token.line)
        else
          SlotRenderNode.new(name: token.name, attrs: token.attrs, children: [],
                             line: token.line, end_line: token.line)
        end
      end
    end

    def close_tag(stack, token)
      if token.kind == :html && Tokenizer::VOID_ELEMENTS.include?(token.name)
        fail!("void element <#{token.name}> cannot have a closing tag", token.line, token.col)
      end

      node, open_token = stack.last
      if node.is_a?(Root)
        fail!("closing tag </#{tag_label(token)}> without a matching open tag", token.line, token.col)
      end

      unless open_token.kind == token.kind && open_token.name == token.name
        fail!("mismatched closing tag </#{tag_label(token)}> — expected </#{tag_label(open_token)}> " \
              "(opened at #{location(open_token.line, open_token.col)})", token.line, token.col)
      end

      set_end_line(node, token.line)
      stack.pop

      finalize_component(node) if node.is_a?(ComponentNode)
    end

    def set_end_line(node, line)
      node.end_line = line if node.respond_to?(:end_line=)
    end

    # Partition a component's direct children into named slot definitions
    # and the inner (default) slot content.
    def finalize_component(node)
      inner = []
      node.children.each do |child|
        if child.is_a?(SlotDefNode)
          (node.slot_defs[child.name.to_sym] ||= []) << child
        else
          inner << child
        end
      end
      # Whitespace that only separates slot definitions is not inner content.
      if node.slot_defs.any? && inner.all? { |c| c.is_a?(TextNode) && c.value.strip.empty? }
        inner = []
      end
      node.children = inner
    end

    def tag_label(token)
      case token.kind
      when :local then ".#{token.name}"
      when :slot  then ":#{token.name}"
      else token.name
      end
    end

    def location(line, col)
      "#{@file}:#{@first_line + line - 1}:#{col}"
    end

    def fail!(message, line, col)
      snippet = @source && Her.source_snippet(@source, line, col, display_line: @first_line + line - 1)
      raise ParseError.new(message, file: @file, line: @first_line + line - 1, column: col,
                                    snippet: snippet)
    end
  end
end
