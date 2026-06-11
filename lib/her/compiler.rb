# frozen_string_literal: true

module Her
  # Orchestrates the pipeline (§6): tokenize → parse → codegen → module_eval,
  # and maps any SyntaxError in generated code back to the template.
  module Compiler
    module_function

    # Compile +source+ and define `mod.name(assigns)`.
    #
    # origin: { file:, first_line: } — where the template text really lives,
    #   so errors and backtraces point at the author's source.
    # attrs: declared attr metadata from a component block, or nil — the
    #   contract then comes from template frontmatter, or is empty
    #   (contracts are mandatory; an empty contract allows no @refs).
    def define(mod, name, source, origin:, attrs: nil, kind: :component, template_path: nil,
               strict_html: false)
      file = origin.fetch(:file)
      first_line = origin.fetch(:first_line, 1)
      label = Her.module_label(mod)

      # Template frontmatter (§12): leading <%# attr ... %> comments give
      # the template its own contract. One source of truth: declaring attrs
      # both in a component block and in frontmatter is an error.
      frontmatter = Frontmatter.extract(source, file: file, first_line: first_line,
                                                name: name, label: label)
      attrs_origin =
        if frontmatter
          if attrs
            raise CompileError,
                  "#{label}.#{name}: attrs are declared both in the component block and in " \
                  "the template frontmatter (#{file}) — declare them in one place"
          end
          attrs = frontmatter
          :frontmatter
        elsif attrs
          :block
        else
          # Contracts are mandatory: a template that declares nothing
          # compiles with an EMPTY contract, so every @x reference is a
          # precise load-time error. Static templates (and assigns[:key]
          # access) remain legal.
          attrs = {}
          :implicit
        end

      tokens = Tokenizer.new(source, file: file, first_line: first_line).tokenize
      tree = Parser.new(tokens, file: file, first_line: first_line, source: source).parse
      begin
        codegen = Codegen.new(
          tree,
          name: name,
          attrs: attrs,
          module_label: label,
          file: file,
          first_line: first_line,
          strict_html: strict_html
        )
        generated = codegen.generate
      rescue SystemStackError
        # The codegen walks recurse per nesting level; beyond ~2000 levels
        # the VM stack runs out. No sane template gets near that.
        raise CompileError,
              "#{label}.#{name}: template nests too deeply to compile (more than ~2000 " \
              "levels). If this is intentional, raise RUBY_THREAD_VM_STACK_SIZE."
      end

      # Redefinition of a HER-defined component (collision rule §3d, code
      # reload) is intentional; drop the old method to avoid the warning.
      if mod.__her_registry.key?(name) && mod.singleton_class.method_defined?(name)
        mod.singleton_class.send(:remove_method, name)
      end

      begin
        mod.module_eval(generated, file, first_line - 1)
      rescue ::SyntaxError => e
        raise CompileError,
              "invalid Ruby generated for #{label}.#{name}: #{e.message.lines.first(3).join.strip}\n" \
              "Hint: control-flow holes ({if}/{each do}/{end}) must balance within each " \
              "component or slot body. Inspect Her.generated_source(#{label}, #{name.inspect})."
      end

      mod.__her_registry[name] = {
        kind: kind,
        attrs: attrs,
        # set for file-based templates; Her.reload_templates! recompiles them
        template_path: template_path,
        strict_html: strict_html,
        # :block attrs are passed back in on reload; :frontmatter and
        # :required contracts are re-derived from the file and the policy
        attrs_origin: attrs_origin,
        defaults: attrs ? attrs.filter_map { |k, o| [k, o[:default]] if o.key?(:default) }.to_h.freeze : nil,
        # precomputed [[key, type, values], ...] for the non-inlinable
        # render-time checks (values: lists, Class/Module types)
        attr_checks: attrs&.filter_map { |k, o|
          [k, o[:type], o[:values]].freeze if o[:values] || o[:type].is_a?(Module)
        }&.freeze,
        file: file,
        first_line: first_line,
        generated_source: generated,
        # call-site metadata consumed by Her.verify
        calls: codegen.calls,
        rendered_slots: codegen.rendered_slots,
        dynamic_slot_render: codegen.dynamic_slot_render?
      }
      name
    end
  end
end
