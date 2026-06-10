# frozen_string_literal: true

module Her
  # The definition DSL (§3). `extend Her::Component` in a module to get
  # `component` and `embed_templates`; both compile templates into public
  # module functions taking a single assigns hash (§4a).
  module Component
    # Track extending modules so Her.verify! with no arguments can check
    # every component module in the application.
    def self.extended(mod)
      Her.__register_component_module(mod)
    end

    NAME_FORMAT = /\A[a-z_][a-zA-Z0-9_]*\z/
    RUBY_KEYWORDS = %w[
      alias and begin break case class def defined? do else elsif end ensure
      false for if in module next nil not or redo rescue retry return self
      super then true undef unless until when while yield
    ].freeze

    # Declares one component (§3a). The template is either given inline with
    # `template` inside the block, or auto-loaded from the sibling file
    # `<name>.html.her` next to the calling Ruby file.
    #
    #   component :alert do
    #     attr :message, required: true
    #     attr :kind, default: "info"
    #     template %(<div class={"alert alert-\#{@kind}"}>{@message}</div>)
    #   end
    #
    # Declaring any `attr` opts the component into the contract tier:
    # required attrs are enforced at render time and referencing an
    # undeclared @attr is a load-time error. With no attrs declared the
    # component is contract-free, exactly like embed_templates (§3c).
    def component(name, dir: nil, &block)
      name = validate_component_name!(name)
      caller_loc = caller_locations(1, 1).first

      builder = ComponentBuilder.new(name)
      builder.instance_eval(&block) if block

      template_path = nil
      if (source = builder.__template)
        origin = { file: caller_loc.path, first_line: builder.__template_line }
      else
        base = dir || File.dirname(caller_loc.absolute_path || caller_loc.path)
        path = File.join(base, "#{name}.html.her")
        unless File.file?(path)
          raise CompileError,
                "#{Her.module_label(self)}.#{name}: no inline template and no sibling " \
                "template file at #{path}"
        end
        source = File.read(path)
        origin = { file: path, first_line: 1 }
        template_path = path
      end

      __her_guard_collision!(name, "component #{name.inspect}")
      Compiler.define(self, name, source, origin: origin, attrs: builder.__attrs,
                                          kind: :component, template_path: template_path)
    end

    # Defines one contract-free function per file matching +glob+ (§3b),
    # named after the file's basename (`button.html.her` → `.button`).
    # The glob is relative to the calling file's directory unless `dir:`
    # is given. Files whose name was already taken by an explicit
    # `component` are skipped — explicit wins (§3d).
    def embed_templates(glob, dir: nil)
      caller_loc = caller_locations(1, 1).first
      base = dir || File.dirname(caller_loc.absolute_path || caller_loc.path)
      paths = Dir.glob(File.expand_path(glob, base)).sort

      if paths.empty?
        warn "Her: embed_templates(#{glob.inspect}) matched no files in #{base}"
        return []
      end

      paths.filter_map do |path|
        name = File.basename(path).sub(/\.html\.her\z/, "").sub(/\.her\z/, "")
        unless NAME_FORMAT.match?(name) && !RUBY_KEYWORDS.include?(name)
          raise CompileError,
                "embed_templates: #{path} would define `#{name}`, which is not a valid " \
                "component name — rename the file"
        end
        name = name.to_sym
        next if __her_registry.dig(name, :kind) == :component # explicit wins (§3d)

        __her_guard_collision!(name, "template file #{path}")
        Compiler.define(self, name, File.read(path), origin: { file: path, first_line: 1 },
                                                     attrs: nil, kind: :embed, template_path: path)
      end
    end

    # @api private — per-module component metadata (defaults, sources, kinds).
    def __her_registry
      @__her_registry ||= {}
    end

    # @api private — called by generated code to apply declared defaults.
    def __her_defaults(name)
      @__her_registry[name][:defaults]
    end

    # @api private — called by generated code: precomputed type/values
    # checks for the render-time guard.
    def __her_attr_checks(name)
      @__her_registry[name][:attr_checks]
    end

    private

    # Refuse to silently overwrite methods HER did not define — e.g. a
    # `name.html.her` template would clobber Module#name (§3d).
    def __her_guard_collision!(name, what)
      return if __her_registry.key?(name) # redefinition of a HER component is fine
      return unless respond_to?(name)

      raise CompileError,
            "#{Her.module_label(self)} already responds to `#{name}` " \
            "(from #{method(name).owner}); refusing to overwrite it with #{what} — rename it"
    end

    def validate_component_name!(name)
      str = name.to_s
      unless NAME_FORMAT.match?(str) && !RUBY_KEYWORDS.include?(str)
        raise CompileError, "invalid component name #{name.inspect} " \
                            "(must match #{NAME_FORMAT.inspect} and not be a Ruby keyword)"
      end
      str.to_sym
    end

    # -- helpers available bare inside template holes --------------------------
    # Becomes a (private) singleton method of the extending module, so hole
    # code like `{raw(@html)}` resolves. (`render_slot`/`slot?` need no
    # helper: the compiler rewrites them to ::Her calls carrying the slot
    # context.)

    def raw(value)
      Her.raw(value)
    end

    # Collects `attr` and `template` declarations inside a component block.
    class ComponentBuilder
      # Declared-attr types. :global collects every undeclared assign into
      # one hash (for `<div {@rest}>` passthrough); any Class/Module also
      # works as a type (`attr :at, Time`).
      ATTR_TYPES = %i[any string symbol boolean integer float numeric array hash proc global].freeze

      def initialize(component_name)
        @component_name = component_name
        @attrs = nil
        @template = nil
        @template_line = nil
      end

      def attr(name, type = :any, required: false, default: (no_default = true; nil), values: nil)
        name = name.to_sym
        @attrs ||= {}
        raise CompileError, "attr #{name.inspect} declared twice on :#{@component_name}" if @attrs.key?(name)
        unless ATTR_TYPES.include?(type) || type.is_a?(Module)
          raise CompileError,
                "attr #{name.inspect} on :#{@component_name}: unknown type #{type.inspect} " \
                "(valid: #{ATTR_TYPES.map(&:inspect).join(', ')}, or a Class/Module)"
        end
        if required && !no_default
          raise CompileError,
                "attr #{name.inspect} on :#{@component_name} cannot be both required and have a default"
        end
        validate_global!(name, required, values) if type == :global
        values = validate_values!(name, type, values) if values
        unless no_default || default.nil?
          unless Her.type_ok?(default, type)
            raise CompileError,
                  "attr #{name.inspect} on :#{@component_name}: default #{default.inspect} " \
                  "is not #{Her.type_label(type)}"
          end
          if values && !values.include?(default)
            raise CompileError,
                  "attr #{name.inspect} on :#{@component_name}: default #{default.inspect} " \
                  "is not among values: #{values.map(&:inspect).join(', ')}"
          end
        end

        spec = { type: type, required: !!required }
        spec[:values] = values if values
        spec[:default] = default.frozen? ? default : default.dup.freeze unless no_default
        @attrs[name] = spec
      end

      def template(source)
        raise CompileError, "template declared twice on :#{@component_name}" if @template
        @template = source
        # A heredoc body starts on the line after the `template <<~HER` call;
        # heredocs always end with a newline, inline strings usually don't.
        line = caller_locations(1, 1).first.lineno
        @template_line = source.end_with?("\n") ? line + 1 : line
      end

      def __attrs = @attrs
      def __template = @template
      def __template_line = @template_line

      private

      def validate_global!(name, required, values)
        if required
          raise CompileError, "attr #{name.inspect} on :#{@component_name}: a :global attr cannot be required"
        end
        if values
          raise CompileError, "attr #{name.inspect} on :#{@component_name}: a :global attr cannot have values:"
        end
        if (other = @attrs.find { |_, spec| spec[:type] == :global })
          raise CompileError,
                "attr #{name.inspect} on :#{@component_name}: only one :global attr is allowed " \
                "(already declared on #{other.first.inspect})"
        end
      end

      def validate_values!(name, type, values)
        unless values.is_a?(Enumerable) && values.to_a.any?
          raise CompileError,
                "attr #{name.inspect} on :#{@component_name}: values: must be a non-empty Enumerable"
        end
        values = values.to_a.freeze
        if (bad = values.find { |v| !Her.type_ok?(v, type) })
          raise CompileError,
                "attr #{name.inspect} on :#{@component_name}: values: contains #{bad.inspect}, " \
                "which is not #{Her.type_label(type)}"
        end
        values
      end
    end
  end
end
