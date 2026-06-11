# frozen_string_literal: true

# Loads the component modules and nothing else — deliberately free of any
# web-server dependency, so the same file serves three masters:
#
#   * the app:            require_relative "config/boot" from app.rb
#   * the language server: her lsp -r config/boot.rb
#   * CI / the console:    her check -r config/boot.rb
require "her"
require_relative "../app/components"
