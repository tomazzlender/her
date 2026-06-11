# frozen_string_literal: true

require "strscan"

module Her
  # Template frontmatter: attr declarations inside leading <%# ... %>
  # comments, giving file-based templates the same contract tier as
  # `component` blocks — a deliberate departure from Phoenix (§12):
  #
  #   <%# attr :label, :string, required: true %>
  #   <%# attr :kind, :string, values: %w[info warn], default: "info" %>
  #   <button class="btn-{@kind}">{@label}</button>
  #
  # The declarations are the SAME `attr` DSL as component blocks — same
  # types, values:, :global, defaults, and the same validation — evaluated
  # against a ComponentBuilder at load time. Templates are code; the
  # frontmatter runs with exactly the trust holes already have.
  #
  # Declarations must appear before any template content (other comments
  # and whitespace are fine); an attr comment after content has begun is a
  # load error, never a silent miss.
  module Frontmatter
    ATTR_COMMENT = /\Aattr\b/

    module_function

    # Returns the declared attrs hash, or nil when the template has no
    # frontmatter. +name+/+label+ feed error messages.
    def extract(source, file:, first_line: 1, name:, label:)
      scanner = StringScanner.new(source)
      scanner.skip(/﻿/) # tolerate a BOM before the frontmatter
      builder = Component::ComponentBuilder.new(name)
      found = false

      loop do
        scanner.skip(/\s+/)
        break unless scanner.skip(/<%#/)
        body_start = scanner.pos
        body = scanner.scan_until(/%>/)
        break unless body # unclosed: let the tokenizer produce its error

        body = body.delete_suffix("%>")
        next unless body.strip.match?(ATTR_COMMENT)

        found = true
        line = first_line + source[0, body_start].count("\n")
        evaluate(builder, body, file, line, label, name)
      end

      check_misplaced!(scanner, source, file, first_line, label, name)
      return nil unless found

      if builder.__template
        raise CompileError,
              "#{label}.#{name}: template frontmatter can only declare attrs (#{file})"
      end
      builder.__attrs
    end

    def evaluate(builder, code, file, line, label, name)
      builder.instance_eval(code, file, line)
    rescue CompileError => e
      raise CompileError, "#{e.message} (#{file}:#{line})"
    rescue ::SyntaxError, ::StandardError => e
      raise CompileError,
            "#{label}.#{name}: invalid frontmatter at #{file}:#{line}: " \
            "#{e.message.lines.first.strip}"
    end

    def check_misplaced!(scanner, source, file, first_line, label, name)
      rest = scanner.rest
      offset = rest.index(/<%#\s*attr\b/)
      return unless offset

      line = first_line + source[0, scanner.pos + offset].count("\n")
      raise CompileError,
            "#{label}.#{name}: attr declarations must appear at the top of the template, " \
            "before any content (#{file}:#{line})"
    end
  end
end
