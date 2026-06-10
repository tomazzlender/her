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
    # attrs: declared attr metadata ({name => {required:, default:}}) for the
    #   contract tier, or nil for contract-free templates (§3c).
    def define(mod, name, source, origin:, attrs: nil, kind: :component)
      file = origin.fetch(:file)
      first_line = origin.fetch(:first_line, 1)
      label = Her.module_label(mod)

      tokens = Tokenizer.new(source, file: file, first_line: first_line).tokenize
      tree = Parser.new(tokens, file: file, first_line: first_line).parse
      generated = Codegen.new(
        tree,
        name: name,
        mode: attrs ? :declared : :free,
        attrs: attrs,
        module_label: label,
        file: file,
        first_line: first_line
      ).generate

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
        defaults: attrs ? attrs.filter_map { |k, o| [k, o[:default]] if o.key?(:default) }.to_h.freeze : nil,
        file: file,
        first_line: first_line,
        generated_source: generated
      }
      name
    end
  end
end
