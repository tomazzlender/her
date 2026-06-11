# frozen_string_literal: true

require_relative "test_helper"
require "json"

# The editor assets must stay loadable and internally consistent.
class EditorsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_grammar_is_valid_json_with_expected_scope
    grammar = JSON.parse(File.read(File.join(ROOT, "editors", "her.tmLanguage.json")))
    assert_equal "text.html.her", grammar["scopeName"]
    assert_includes grammar["fileTypes"], "her"
  end

  def test_vscode_extension_grammar_copy_stays_in_sync
    canonical = File.read(File.join(ROOT, "editors", "her.tmLanguage.json"))
    bundled = File.read(File.join(ROOT, "editors", "vscode", "her", "syntaxes", "her.tmLanguage.json"))
    assert_equal canonical, bundled,
                 "editors/vscode/her/syntaxes/her.tmLanguage.json must be a copy of editors/her.tmLanguage.json"
  end

  def test_vscode_extension_manifest_references_existing_files
    dir = File.join(ROOT, "editors", "vscode", "her")
    manifest = JSON.parse(File.read(File.join(dir, "package.json")))
    grammar = manifest.dig("contributes", "grammars", 0)
    assert_equal "text.html.her", grammar["scopeName"]
    assert File.file?(File.join(dir, grammar["path"])), "grammar path must exist"
    language = manifest.dig("contributes", "languages", 0)
    assert_includes language["extensions"], ".her"
    assert File.file?(File.join(dir, language["configuration"]))
    assert File.file?(File.join(dir, manifest["main"]))
    JSON.parse(File.read(File.join(dir, "language-configuration.json")))
  end
end
