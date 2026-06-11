# frozen_string_literal: true

# Slots: passing markup INTO components — the default :inner slot, named
# slots with fallbacks, and `let` bindings for data-driven slots.
#
#   ruby -Ilib examples/04_slots.rb

require "her"

module UI
  extend Her::Component

  # `{render_slot(:inner)}` (or `<:inner/>`) renders whatever the caller
  # passed as children. `<:title>` here RENDERS a named slot, with fallback
  # content used when the caller did not provide it.
  component :panel do
    template <<~'HER'
      <section class="panel">
        <header><:title>Untitled panel</:title></header>
        <div class="body">{render_slot(:inner)}</div>
        {if slot?(:footer)}<footer><:footer/></footer>{end}
      </section>
    HER
  end

  # At a CALL site, direct <:name> children DEFINE slots; everything else
  # becomes :inner.
  component :page do
    attr :at, :string, required: true
    template <<~'HER'
      <.panel>
        <:title>Quarterly <em>report</em></:title>
        <p>All numbers are up and to the right.</p>
        <:footer>Generated {@at}</:footer>
      </.panel>
      <.panel>
        <p>This one uses the fallback title and has no footer.</p>
      </.panel>
    HER
  end

  # `let` binds slot arguments: the component passes data to the slot with
  # render_slot(:row, value) and the caller receives it as a local.
  component :table do
    attr :rows, :array, required: true
    template <<~'HER'
      <table>
        {@rows.each do |row|}
          <tr>{render_slot(:row, row)}</tr>
        {end}
      </table>
    HER
  end

  component :user_table do
    attr :users, :array, required: true
    template <<~'HER'
      <.table rows={@users}>
        <:row let={user}>
          <td>{user[:name]}</td><td>{user[:email]}</td>
        </:row>
      </.table>
    HER
  end
end

puts UI.page(at: "2026-06-11")
puts

puts UI.user_table(users: [
  { name: "Ana",  email: "ana@example.com" },
  { name: "Bo & Co", email: "bo@example.com" }
])
puts

# From Ruby, the block is the :inner slot — and block arguments work too:
puts UI.panel { "Plain string content, escaped: <b>" }
