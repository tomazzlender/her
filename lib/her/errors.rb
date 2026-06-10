# frozen_string_literal: true

module Her
  # Base class for all HER errors.
  class Error < StandardError; end

  # Raised at load time when a template cannot be tokenized or parsed.
  # The message always carries file:line:column pointing at the author's
  # template source (for inline templates, at the Ruby file that declared
  # the heredoc).
  class ParseError < Error
    attr_reader :file, :line, :column

    def initialize(message, file: nil, line: nil, column: nil)
      @file = file
      @line = line
      @column = column
      location = [file, line, column].compact.join(":")
      super(location.empty? ? message : "#{location}: #{message}")
    end
  end

  # Raised at load time for problems outside the template text itself:
  # bad component names, missing template files, invalid attr declarations,
  # or generated Ruby that fails to compile.
  class CompileError < Error; end

  # Raised at render time when a declared, required attr is missing (§7.1).
  class MissingAttr < Error
    attr_reader :component, :attr

    # Used by generated code; keeps the generated line short.
    def self.raise_for(mod, name, attr)
      raise new(mod, name, attr)
    end

    def initialize(mod, name, attr)
      @component = "#{Her.module_label(mod)}.#{name}"
      @attr = attr
      super("#{@component}: missing required attribute #{attr.inspect}")
    end
  end

  # Raised at render time when a contract-free template references an
  # assign that was not passed (§3c). Never silently renders nil.
  class MissingAssign < Error
    attr_reader :component, :assign

    def initialize(mod, name, key, assigns)
      @component = "#{Her.module_label(mod)}.#{name}"
      @assign = key
      given = assigns.keys.map(&:inspect).join(", ")
      given = "none" if given.empty?
      super("#{@component}: missing assign #{key.inspect} (assigns given: #{given})")
    end
  end

  # Raised when render_slot/slot? is called outside of a component render.
  class SlotError < Error; end

  # @api private
  def self.module_label(mod)
    mod.name || mod.inspect
  end
end
