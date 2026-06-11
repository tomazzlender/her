# frozen_string_literal: true

# The contract tier: declared attrs with required, defaults, types, allowed
# values, and a :global collector. Declaring any attr opts the component in.
#
#   ruby -Ilib examples/02_contracts.rb

require "her"

module UI
  extend Her::Component

  component :badge do
    attr :label, :string, required: true
    attr :count, :integer, default: 0
    attr :kind,  :string, values: %w[info warn danger], default: "info"
    attr :rest,  :global # collects every undeclared assign for passthrough
    template <<~'HER'
      <span class="badge badge-{@kind}" {@rest}>{@label}{if @count > 0} ({@count}){end}</span>
    HER
  end
end

puts UI.badge(label: "Inbox", count: 3)
# => <span class="badge badge-info">Inbox (3)</span>

# Undeclared assigns flow into the :global attr — handy for data-*/aria-*:
puts UI.badge(label: "Done", kind: "warn", "data-id": "b1", hidden: true)
# => <span class="badge badge-warn" data-id="b1" hidden>Done</span>

# The contract is enforced, with errors naming component and attribute:
def show(label)
  yield
rescue Her::Error => e
  puts "#{label}: #{e.message}"
end

show("missing required") { UI.badge(count: 1) }
# => UI.badge: missing required attribute :label

show("wrong type") { UI.badge(label: "x", count: "3") }
# => UI.badge: attribute :count expected :integer, got String: "3"

show("outside values") { UI.badge(label: "x", kind: "festive") }
# => UI.badge: attribute :kind got "festive" — allowed values: "info", "warn", "danger"

# Typos in the template itself fail at LOAD time, not in production:
show("undeclared @attr in template") do
  Module.new do
    extend Her::Component
    component :broken do
      attr :label, :string, required: true
      template "<b>{@labl}</b>"
    end
  end
end
# => ...template references undeclared attr @labl — declare it with `attr :labl` (declared: :label)
