# frozen_string_literal: true

# Composition: components calling components inside templates — locally with
# <.name/>, across modules with <Module.name/> — plus smart attributes.
#
#   ruby -Ilib examples/03_composition.rb

require "her"

module Icons
  extend Her::Component
  component :icon do
    attr :name, :string, required: true
    template %q(<svg class={"icon icon-#{@name}"} aria-hidden="true"></svg>)
  end
end

module UI
  extend Her::Component

  component :button do
    attr :label,    :string, required: true
    attr :kind,     :string, values: %w[primary ghost], default: "primary"
    attr :disabled, :boolean, default: false
    attr :icon # nil means "no icon"
    template <<~'HER'
      <button class="btn btn-{@kind}" disabled={@disabled}>
        {if @icon}<Icons.icon name={@icon}/>{end}
        {@label}
      </button>
    HER
  end

  component :toolbar do
    attr :items, :array, required: true
    template <<~'HER'
      <nav class="toolbar">
        {@items.each do |item|}
          <.button label={item[:label]} icon={item[:icon]} disabled={item[:disabled]}/>
        {end}
      </nav>
    HER
  end
end

# Component attrs are VALUES, not strings: arrays, hashes, booleans pass
# through as themselves and each component escapes its own output once.
puts UI.toolbar(items: [
  { label: "Save",    icon: "disk" },
  { label: "Delete",  icon: "trash", disabled: true },
  { label: "A & B" } # escaping happens exactly once, inside button
])

# Smart attributes: nil/false omit the attribute, true renders it bare —
# note `disabled` above appears only on the Delete button.

# Splats forward attribute sets wholesale:
module UI
  component :linkish do
    attr :rest, :global
    template "<a {@rest}>link</a>"
  end
  component :wrapper do
    template %q(<.linkish href="/x" target="_blank" data-turbo="false"/>)
  end
end
puts UI.wrapper
# => <a href="/x" target="_blank" data-turbo="false">link</a>

# Boot-time verification checks every call site you wrote in templates:
# typo'd components, missing required attrs, wrong-typed literals.
Her.verify!
puts "verify!: all call sites check out"
