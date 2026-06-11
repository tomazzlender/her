# frozen_string_literal: true

#   ruby -Ilib examples/06_file_templates/run.rb

require_relative "ui"

puts FileUI.user_card(name: "Ana", email: "ana@example.com")
puts FileUI.alert(message: "Saved!", kind: "info")

# File templates reload without re-evaluating any Ruby — the dev loop:
puts "(#{Her.reload_templates!(FileUI)} templates reloaded from disk)"

# And the whole module verifies at boot:
Her.verify!(FileUI)
puts "verify!: ok"
