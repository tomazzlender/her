# frozen_string_literal: true

require "json"

# Builds the derived grammar artifacts from the canonical TextMate grammar,
# editors/her.tmLanguage.json:
#
#   * editors/her.tmLanguage — the same grammar as an old-style Apple plist,
#     which is what Sublime Text and TextMate load directly
#   * editors/vscode/her/syntaxes/her.tmLanguage.json — the copy bundled in
#     the VS Code extension
#
# Run `rake grammar` after editing the canonical file; the editors test
# fails when the artifacts drift.
module GrammarBuild
  module_function

  def run(root)
    canonical = File.join(root, "editors", "her.tmLanguage.json")
    json = File.read(canonical)
    File.write(File.join(root, "editors", "her.tmLanguage"), plist(json))
    File.write(File.join(root, "editors", "vscode", "her", "syntaxes", "her.tmLanguage.json"), json)
  end

  # TextMate grammars only contain strings, arrays and dicts, so a minimal
  # plist emitter covers them completely.
  def plist(json)
    grammar = JSON.parse(json)
    grammar.delete("$schema") # JSON-editor affordance, noise in a plist
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      #{node(grammar, 0)}
      </plist>
    XML
  end

  def node(value, depth)
    pad = "  " * depth
    case value
    when Hash
      return "#{pad}<dict/>" if value.empty?
      inner = value.map { |key, val| "#{pad}  <key>#{escape(key)}</key>\n#{node(val, depth + 1)}" }
      "#{pad}<dict>\n#{inner.join("\n")}\n#{pad}</dict>"
    when Array
      return "#{pad}<array/>" if value.empty?
      "#{pad}<array>\n#{value.map { |val| node(val, depth + 1) }.join("\n")}\n#{pad}</array>"
    when String
      "#{pad}<string>#{escape(value)}</string>"
    else
      raise ArgumentError, "unsupported plist value: #{value.class}"
    end
  end

  def escape(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
