# frozen_string_literal: true

require "cgi/escape"

require_relative "her/version"
require_relative "her/errors"
require_relative "her/safe"
require_relative "her/ruby_scanner"
require_relative "her/tokenizer"
require_relative "her/parser"
require_relative "her/codegen"
require_relative "her/compiler"
require_relative "her/component"
require_relative "her/verify"

# HER — HTML Embedded Ruby.
#
# Templates are real HTML with embedded Ruby expressions; each template is
# compiled once at load time into a plain module function. Rendering is a
# fast method call taking a hash of values and returning escaped HTML.
#
#   module UI
#     extend Her::Component
#
#     component :button do
#       attr :label, required: true
#       attr :class, default: "btn"
#       template %(<button class={@class}>{@label}</button>)
#     end
#   end
#
#   UI.button(label: "Save").to_s # => "<button class=\"btn\">Save</button>"
module Her
  class << self
    # Escape +value+ for HTML unless it is already trusted (§5). Safe values
    # pass through untouched — this is what lets components nest without
    # double-escaping. Always returns a plain String.
    def safe(value)
      value.is_a?(Safe) ? value.to_s : CGI.escapeHTML(value.to_s)
    end

    # Mark +value+ as trusted HTML; it will not be escaped. This is also the
    # §8.1 escape hatch: markup emitted through `{raw(...)}` bypasses the
    # parser's tag balancing entirely.
    def raw(value)
      value.is_a?(Safe) ? value : Safe.new(value)
    end

    # -- slots ------------------------------------------------------------
    # Slot context is plain data: every compiled component receives a slots
    # hash, and `render_slot(...)` written in a template hole is rewritten
    # at compile time to pass it along. Content blocks close over the slots
    # of the template they appear in — which is what makes slot resolution
    # lexical. There is no global or fiber-local state, so rendering works
    # across threads, fibers and lazily-evaluated blocks.

    # Render slot +name+ from +slots+, passing +args+ to the slot's block.
    # Returns a Safe string, or nil when the slot was not provided — so
    # `{render_slot(:x) || "fallback"}` works. Multiple definitions of the
    # same slot render concatenated, in order.
    #
    # In templates, call it bare: `{render_slot(:x)}` — the compiler
    # supplies the slots argument.
    def render_slot(slots, name = :inner, *args)
      assert_slots!(slots, "render_slot")
      entries = slots[name]
      return nil if entries.nil? || entries.empty?
      Safe.new(entries.map { |callable| safe(callable.call(*args)) }.join)
    end

    # True when +slots+ contains slot +name+. In templates: `{slot?(:x)}`.
    def slot?(slots, name = :inner)
      assert_slots!(slots, "slot?")
      entries = slots[name]
      !(entries.nil? || entries.empty?)
    end

    # -- runtime helpers used by generated code ----------------------------

    # @api private — strict assign access for contract-free templates (§3c):
    # a missing assign raises instead of silently rendering nil.
    def fetch!(assigns, key, mod, name)
      assigns.fetch(key) { raise MissingAssign.new(mod, name, key, assigns) }
    end

    # @api private — smart attribute emission for `name={value}` (§1.4):
    # nil/false omit the attribute, true renders it bare, anything else
    # renders name="escaped value".
    def attr_pair(name, value)
      case value
      when nil, false then ""
      when true then " #{name}"
      else %( #{name}="#{safe(value)}")
      end
    end

    # @api private — `<div {@rest}>`: splat a hash into attributes, each
    # with attr_pair semantics.
    def splat_attrs(hash)
      return "" if hash.nil?
      hash.map { |key, value| attr_pair(key, value) }.join
    end

    # The Ruby source HER generated for a compiled component — useful for
    # debugging and for understanding what the compiler does.
    def generated_source(mod, name)
      mod.__her_registry.dig(name.to_sym, :generated_source)
    end

    private

    def assert_slots!(slots, api)
      return if slots.is_a?(Hash)
      raise SlotError,
            "#{api} must be called bare inside a template hole — HER rewrites it there to " \
            "receive the component's slot context. Outside a template, pass a slots Hash " \
            "explicitly (got #{slots.inspect})."
    end
  end
end
