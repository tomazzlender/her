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

  def test_plist_grammar_stays_in_sync_with_canonical_json
    require_relative "../tools/grammar_build"
    expected = GrammarBuild.plist(File.read(File.join(ROOT, "editors", "her.tmLanguage.json")))
    actual = File.read(File.join(ROOT, "editors", "her.tmLanguage"))
    assert_equal expected, actual,
                 "editors/her.tmLanguage is generated — run `rake grammar` after editing the JSON grammar"
  end

  def test_plist_grammar_shape
    plist = File.read(File.join(ROOT, "editors", "her.tmLanguage"))
    assert plist.start_with?("<?xml")
    assert_includes plist, "<key>scopeName</key>"
    assert_includes plist, "<string>text.html.her</string>"
    assert_includes plist, "<key>fileTypes</key>"
    refute_includes plist, "$schema"
  end

  def test_vscode_extension_grammar_copy_stays_in_sync
    canonical = File.read(File.join(ROOT, "editors", "her.tmLanguage.json"))
    bundled = File.read(File.join(ROOT, "editors", "vscode", "her", "syntaxes", "her.tmLanguage.json"))
    assert_equal canonical, bundled,
                 "editors/vscode/her/syntaxes/her.tmLanguage.json must be a copy of editors/her.tmLanguage.json"
  end

  def test_intellij_plugin_xml_matches_the_kotlin_sources
    dir = File.join(ROOT, "editors", "intellij", "her")
    plugin_xml = File.read(File.join(dir, "src", "main", "resources", "META-INF", "plugin.xml"))
    implementation = plugin_xml[/implementation="([^"]+)"/, 1]
    refute_nil implementation, "plugin.xml must register an LSP server support provider"
    package, _, class_name = implementation.rpartition(".")
    source_path = File.join(dir, "src", "main", "kotlin", *package.split("."), "#{class_name}.kt")
    assert File.file?(source_path), "plugin.xml references #{implementation} but #{source_path} is missing"
    source = File.read(source_path)
    assert_includes source, "package #{package}"
    assert_includes source, "class #{class_name}"
    assert_includes source, %(file.extension == "her")
    assert_includes plugin_xml, "com.intellij.modules.ultimate" # LSP API is commercial-only
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
