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

    # -- attr typing ---------------------------------------------------------

    # Does +value+ satisfy declared attr +type+? Shared by declaration-time
    # validation, the render-time guard, and Her.verify's literal checks.
    def type_ok?(value, type)
      case type
      when :any     then true
      when :string  then value.is_a?(String)
      when :symbol  then value.is_a?(Symbol)
      when :boolean then value.equal?(true) || value.equal?(false)
      when :integer then value.is_a?(Integer)
      when :float   then value.is_a?(Float)
      when :numeric then value.is_a?(Numeric)
      when :array   then value.is_a?(Array)
      when :hash    then value.is_a?(Hash)
      when :proc    then value.respond_to?(:call)
      when :global  then value.is_a?(Hash)
      when Module   then value.is_a?(type)
      else true
      end
    end

    def type_label(type)
      type.is_a?(Module) ? type.name || type.inspect : type.inspect
    end

    # -- runtime helpers used by generated code ----------------------------

    # @api private — render-time type/values guard for declared attrs.
    # +checks+ is the precomputed [[key, type, values], ...] list. nil is
    # "absent" and exempt; false likewise (the `attr={@x && "v"}` omit
    # idiom) except for :boolean attrs, where false is a first-class value.
    def check_attrs!(mod, name, assigns, checks)
      checks.each do |key, type, values|
        value = assigns[key]
        next if value.nil?
        next if value.equal?(false) && type != :boolean
        if type && !type_ok?(value, type)
          raise InvalidAttr.new(mod, name, key,
                                "expected #{type_label(type)}, got #{value.class}: #{truncate(value.inspect)}")
        end
        if values && !values.include?(value)
          raise InvalidAttr.new(mod, name, key,
                                "got #{truncate(value.inspect)} — allowed values: #{values.map(&:inspect).join(', ')}")
        end
      end
    end

    # @api private — `attr :rest, :global` support: returns assigns with
    # every key that is not in +declared+ collected into the +name+ hash.
    # Runs after the defaults merge, so a default (or an explicitly passed
    # hash) acts as the base and collected attrs override it.
    def collect_global(assigns, name, declared)
      rest = {}
      explicit = assigns[name]
      rest.update(explicit) if explicit.is_a?(Hash)
      kept = {}
      assigns.each do |key, value|
        if key == name
          next
        elsif declared.include?(key)
          kept[key] = value
        else
          rest[key] = value
        end
      end
      kept[name] = rest
      kept
    end

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

    def truncate(str, max = 80)
      str.length > max ? "#{str[0, max]}…" : str
    end

    def assert_slots!(slots, api)
      return if slots.is_a?(Hash)
      raise SlotError,
            "#{api} must be called bare inside a template hole — HER rewrites it there to " \
            "receive the component's slot context. Outside a template, pass a slots Hash " \
            "explicitly (got #{slots.inspect})."
    end
  end
end
