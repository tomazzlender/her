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

  def test_intellij_build_leaves_the_compatibility_range_open
    gradle = File.read(File.join(ROOT, "editors", "intellij", "her", "build.gradle.kts"))
    assert_includes gradle, "untilBuild = provider { null }",
                    "without an explicit null untilBuild, the Gradle plugin derives a " \
                    "ceiling from sinceBuild and newer IDEs refuse to install the plugin"
  end

  # The plugin ships the grammar itself (TextMate bundleProvider EP), so
  # installing it is enough for .her highlighting. Every piece of that wiring
  # is stringly-typed across four files — keep them agreeing.
  def test_intellij_plugin_ships_the_textmate_bundle
    dir = File.join(ROOT, "editors", "intellij", "her")
    resources = File.join(dir, "src", "main", "resources")

    plugin_xml = File.read(File.join(resources, "META-INF", "plugin.xml"), encoding: "UTF-8")
    assert_match(%r{<depends optional="true" config-file="her-textmate\.xml">org\.jetbrains\.plugins\.textmate</depends>},
                 plugin_xml, "highlighting must not be required for the LSP half to load")

    textmate_xml = File.read(File.join(resources, "META-INF", "her-textmate.xml"), encoding: "UTF-8")
    implementation = textmate_xml[/textmate\.bundleProvider\s+implementation="([^"]+)"/, 1]
    refute_nil implementation, "her-textmate.xml must register a textmate.bundleProvider"
    package, _, class_name = implementation.rpartition(".")
    provider_path = File.join(dir, "src", "main", "kotlin", *package.split("."), "#{class_name}.kt")
    assert File.file?(provider_path), "her-textmate.xml references #{implementation} but #{provider_path} is missing"

    provider = File.read(provider_path, encoding: "UTF-8")
    assert_includes provider, "package #{package}"
    assert_includes provider, "class #{class_name}"
    # Each resource the provider extracts must exist in the plugin resources.
    assert_includes provider, '"/textmate/her.tmbundle/$name"',
                    "the provider must read resources from /textmate/her.tmbundle/"
    files = provider[/FILES = listOf\(([^)]*)\)/m, 1]
    refute_nil files, "the provider must declare its bundle files in FILES"
    files.scan(/"([^"]+)"/).flatten.each do |rel|
      assert File.file?(File.join(resources, "textmate", "her.tmbundle", rel)),
             "#{class_name} extracts #{rel} but it is missing from resources/textmate/her.tmbundle/"
    end

    gradle = File.read(File.join(dir, "build.gradle.kts"))
    assert_includes gradle, %(bundledPlugin("org.jetbrains.plugins.textmate")),
                    "compiling against the bundleProvider EP needs the TextMate plugin dependency"
  end

  def test_intellij_bundled_grammar_stays_in_sync_with_canonical_json
    require_relative "../tools/grammar_build"
    expected = GrammarBuild.plist(File.read(File.join(ROOT, "editors", "her.tmLanguage.json")))
    bundled = File.join(ROOT, "editors", "intellij", "her", "src", "main", "resources",
                        "textmate", "her.tmbundle", "Syntaxes", "her.tmLanguage")
    assert_equal expected, File.read(bundled),
                 "the IntelliJ plugin's bundled grammar is generated — run `rake grammar`"
  end

  # A GUI-launched IDE's `bundle` and the terminal's `bundle` are routinely
  # different programs (login vs interactive shell PATH; macOS ships
  # /usr/bin/bundle). The descriptor must compensate with version-manager
  # shims and offer a full command override — and the README must say so.
  def test_intellij_lsp_descriptor_handles_gui_path_and_command_override
    dir = File.join(ROOT, "editors", "intellij", "her")
    source = File.read(File.join(dir, "src", "main", "kotlin", "dev", "her", "intellij",
                                 "HerLspServerSupportProvider.kt"), encoding: "UTF-8")
    %w[mise rbenv asdf].each do |manager|
      assert_includes source, manager, "the descriptor must prepend #{manager} shims"
    end
    assert_includes source, '"boot:"'
    assert_includes source, '"command:"'
    readme = File.read(File.join(dir, "README.md"), encoding: "UTF-8")
    assert_includes readme, "command:", "the README must document the .her-lsp command override"
    assert_includes readme, "boot:"
  end

  def test_intellij_bundle_info_plist_names_the_bundle
    info = File.read(File.join(ROOT, "editors", "intellij", "her", "src", "main", "resources",
                               "textmate", "her.tmbundle", "info.plist"))
    assert info.start_with?("<?xml"), "info.plist must be an XML plist"
    assert_match(%r{<key>name</key>\s*<string>HER</string>}, info)
    assert_match(%r{<key>uuid</key>\s*<string>[0-9A-F-]{36}</string>}, info)
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
