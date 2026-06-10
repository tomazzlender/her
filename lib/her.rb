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
  SLOT_STACK_KEY = :__her_slot_stack__
  private_constant :SLOT_STACK_KEY

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

    # Render slot +name+ of the component currently being rendered, passing
    # +args+ to the slot's block. Returns a Safe string, or nil when the
    # slot was not provided — so `{render_slot(:x) || "fallback"}` works.
    # Multiple definitions of the same slot render concatenated, in order.
    def render_slot(name = :inner, *args)
      entries = current_slot_frame("render_slot")[name]
      return nil if entries.nil? || entries.empty?
      Safe.new(entries.map { |callable| safe(callable.call(*args)) }.join)
    end

    # True when the caller provided slot +name+.
    def slot?(name = :inner)
      entries = current_slot_frame("slot?")[name]
      !(entries.nil? || entries.empty?)
    end

    # @api private — used by generated code
    def push_slots(slots)
      slot_stack.push(slots)
    end

    # @api private — used by generated code
    def pop_slots
      slot_stack.pop
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

    def slot_stack
      Thread.current[SLOT_STACK_KEY] ||= []
    end

    def current_slot_frame(api)
      slot_stack.last or
        raise SlotError, "#{api} called outside of a component render"
    end
  end
end
