# frozen_string_literal: true

# Templates as real .html.her FILES — a designer can edit these without
# touching Ruby.
require "her"

module FileUI
  extend Her::Component

  # One function per file: components/button.html.her -> FileUI.button,
  # components/user_card.html.her -> FileUI.user_card. Contract-free:
  # whatever @assigns the template references is what it needs.
  embed_templates "components/*.html.her"

  # One-to-one with a contract: no inline `template` means the sibling file
  # ./alert.html.her (next to THIS .rb file) is compiled into FileUI.alert.
  component :alert do
    attr :message, :string, required: true
    attr :kind, :string, values: %w[info error], default: "info"
  end
end
