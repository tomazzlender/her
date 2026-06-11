# frozen_string_literal: true

require_relative "lib/her/version"

Gem::Specification.new do |spec|
  spec.name = "her"
  spec.version = Her::VERSION
  spec.authors = ["Tomaz Zlender"]
  spec.email = ["tomaz@84codes.com"]

  spec.summary = "HTML Embedded Ruby — HTML-aware templates compiled to function components"
  spec.description = <<~DESC
    HER is the Ruby sibling of Elixir's HEEx: templates are written as real
    HTML with embedded Ruby expressions and compiled once at load time into
    plain module functions. In-template component calls (<.button/>), slots
    (<:slot/>), smart attributes, declared attr contracts, and automatic
    HTML escaping that composes without double-escaping.
  DESC
  spec.homepage = "https://github.com/tomazzlender/her"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "editors/*", "LICENSE", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["her"]
  spec.require_paths = ["lib"]
end
