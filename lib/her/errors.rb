# frozen_string_literal: true

module Her
  # Base class for all HER errors.
  class Error < StandardError; end

  # Raised at load time when a template cannot be tokenized or parsed.
  # The message always carries file:line:column pointing at the author's
  # template source (for inline templates, at the Ruby file that declared
  # the heredoc), plus the offending source line with a caret.
  class ParseError < Error
    attr_reader :file, :line, :column

    def initialize(message, file: nil, line: nil, column: nil, snippet: nil)
      @file = file
      @line = line
      @column = column
      location = [file, line, column].compact.join(":")
      full = location.empty? ? message : "#{location}: #{message}"
      full = "#{full}\n#{snippet}" if snippet
      super(full)
    end
  end

  # Renders one source line with a caret under the column, for ParseError
  # messages. +line+ is local to +source+ (1-based).
  #
  #     3 |   <span>oops</div>
  #       |              ^
  def self.source_snippet(source, line, column, display_line: line)
    text = source.lines[line - 1] or return nil
    text = text.chomp.gsub("\t", " ")
    gutter = display_line.to_s
    caret_pad = " " * [[column - 1, 0].max, text.length].min
    "  #{gutter} | #{text}\n  #{' ' * gutter.length} | #{caret_pad}^"
  end

  # Raised at load time for problems outside the template text itself:
  # bad component names, missing template files, invalid attr declarations,
  # or generated Ruby that fails to compile.
  class CompileError < Error; end

  # Raised at render time when a declared, required attr is missing (§7.1).
  # Lists the keys that WERE passed — the fast way to spot string-vs-symbol
  # key mistakes.
  class MissingAttr < Error
    attr_reader :component, :attr

    # Used by generated code; keeps the generated line short.
    def self.raise_for(mod, name, attr, assigns = nil)
      raise new(mod, name, attr, assigns)
    end

    def initialize(mod, name, attr, assigns = nil)
      @component = "#{Her.module_label(mod)}.#{name}"
      @attr = attr
      given = assigns ? assigns.keys.map(&:inspect).join(", ") : nil
      given = "none" if given && given.empty?
      suffix = given ? " (assigns given: #{given})" : ""
      super("#{@component}: missing required attribute #{attr.inspect}#{suffix}")
    end
  end

  # Raised at render time when a declared attr receives a value of the
  # wrong type or outside its allowed values.
  class InvalidAttr < Error
    attr_reader :component, :attr

    def initialize(mod, name, attr, detail)
      @component = "#{Her.module_label(mod)}.#{name}"
      @attr = attr
      super("#{@component}: attribute #{attr.inspect} #{detail}")
    end
  end

  # Raised when render_slot/slot? is called outside of a component render.
  class SlotError < Error; end

  # Raised by Her.verify! when cross-component call-site verification finds
  # errors. Carries every failure so a sweep is one fix cycle.
  class VerifyError < Error
    attr_reader :issues

    def initialize(issues)
      @issues = issues
      noun = issues.size == 1 ? "failure" : "failures"
      super("#{issues.size} component verification #{noun}\n" +
            issues.map { |issue| "  [#{issue.severity}] #{issue}" }.join("\n"))
    end
  end

  # @api private
  def self.module_label(mod)
    mod.name || mod.inspect
  end
end
