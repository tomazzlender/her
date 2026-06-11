# frozen_string_literal: true

# The app's components. Templates live in app/components/*.html.her and
# carry their contracts in frontmatter; this file only declares the module
# and a couple of inline components.
module UI
  extend Her::Component

  embed_templates "components/*.html.her"

  component :nav_link do
    attr :href,    :string, required: true
    attr :label,   :string, required: true
    attr :current, :boolean, default: false
    template <<~'HER'
      <a href={@href} aria-current={@current && "page"}>{@label}</a>
    HER
  end
end
