# frozen_string_literal: true

#   ruby -Ilib examples/06_file_templates/run.rb

require_relative "ui"

puts FileUI.user_card(name: "Ana", email: "ana@example.com")
puts FileUI.alert(message: "Saved!", kind: "info")

# user_card.html.her declares its own attrs in frontmatter, so even though
# it came in through the contract-free embed_templates glob, the contract
# is enforced:
begin
  FileUI.user_card(name: "Ana")
rescue Her::MissingAttr => e
  puts "!! #{e.message}"
end

# File templates reload without re-evaluating any Ruby — the dev loop:
puts "(#{Her.reload_templates!(FileUI)} templates reloaded from disk)"

# And the whole module verifies at boot:
Her.verify!(FileUI)
puts "verify!: ok"
