# frozen_string_literal: true

require_relative "test_helper"
require "her/lsp"
require "tmpdir"
require "stringio"

class LspTest < Minitest::Test
  def server
    @server ||= Her::LSP::Server.new(input: StringIO.new, output: StringIO.new)
  end

  def request(method, id: 1, **params)
    server.handle({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
  end

  def notify(method, **params)
    server.handle({ "jsonrpc" => "2.0", "method" => method, "params" => params })
  end

  def open_doc(uri, text)
    notify("textDocument/didOpen", "textDocument" => { "uri" => uri, "text" => text })
  end

  # A module with file-backed templates, so the LSP can resolve ownership.
  def project(dir)
    File.write(File.join(dir, "button.html.her"),
                 "<%# attr :label, :string, required: true %>\n" \
                 "<%# attr :class, :string %>\n" \
                 "<button class={@class}>{@label}</button>\n")
    File.write(File.join(dir, "layout.html.her"), %(<main>{render_slot(:inner)}<:side/></main>\n))
    File.write(File.join(dir, "page.html.her"), %(<.layout><p>x</p></.layout>\n))
    mod = Module.new { extend Her::Component }
    mod.embed_templates("*.html.her", dir: dir)
    mod.component :chip do
      attr :text, :string, required: true
      attr :kind, :string, values: %w[a b], default: "a"
      template "<span>{@text}</span>"
    end
    mod
  end

  # -- framing -------------------------------------------------------------------

  def test_message_framing_roundtrip
    io = StringIO.new
    Her::LSP.write_message(io, { "id" => 1, "result" => "žš" })
    io.rewind
    assert_equal({ "id" => 1, "result" => "žš" }, Her::LSP.read_message(io))
    assert_nil Her::LSP.read_message(io)
  end

  # -- lifecycle ------------------------------------------------------------------

  def test_initialize_capabilities
    (response,) = request("initialize")
    caps = response.dig("result", "capabilities")
    assert_equal 1, caps["textDocumentSync"]
    assert caps["hoverProvider"]
    assert caps["definitionProvider"]
    assert_includes caps.dig("completionProvider", "triggerCharacters"), "<"
    assert_equal "her-lsp", response.dig("result", "serverInfo", "name")
  end

  def test_unknown_request_errors_and_unknown_notification_is_ignored
    (response,) = request("workspace/symbol")
    assert_equal(-32_601, response.dig("error", "code"))
    assert_empty notify("workspace/didChangeNothing")
  end

  # -- diagnostics -----------------------------------------------------------------

  def test_did_open_publishes_parse_diagnostics
    (note,) = open_doc("file:///tmp/x.her", "<div>\n  <span>oops</div>\n</div>\n")
    assert_equal "textDocument/publishDiagnostics", note["method"]
    diag = note.dig("params", "diagnostics").first
    assert_equal 1, diag["severity"]
    assert_match(/mismatched closing tag/, diag["message"])
    assert_equal 1, diag.dig("range", "start", "line") # 0-based line 2
    assert_equal "her", diag["source"]
  end

  def test_clean_document_publishes_empty_diagnostics
    (note,) = open_doc("file:///tmp/ok.her", "<p>{@x}</p>\n")
    assert_empty note.dig("params", "diagnostics")
  end

  def test_registered_file_gets_verify_diagnostics
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "caller.html.her"), "<.nowhere_to_be_seen/>\n")
      mod = Module.new { extend Her::Component }
      mod.embed_templates("*.html.her", dir: dir)
      path = File.join(dir, "caller.html.her")
      (note,) = open_doc("file://#{path}", File.read(path))
      messages = note.dig("params", "diagnostics").map { |d| d["message"] }
      assert(messages.any? { |m| m.include?("nowhere_to_be_seen") })
    end
  end

  def test_did_change_updates_diagnostics
    uri = "file:///tmp/y.her"
    open_doc(uri, "<p>x</p>\n")
    (note,) = notify("textDocument/didChange",
                     "textDocument" => { "uri" => uri },
                     "contentChanges" => [{ "text" => "<p>\n" }])
    assert_match(/unclosed tag/, note.dig("params", "diagnostics").first["message"])
  end

  # -- completion -------------------------------------------------------------------

  def test_component_completion_after_angle_dot
    Dir.mktmpdir do |dir|
      project(dir)
      path = File.join(dir, "page.html.her")
      uri = "file://#{path}"
      open_doc(uri, "<.la")
      (response,) = request("textDocument/completion",
                            "textDocument" => { "uri" => uri },
                            "position" => { "line" => 0, "character" => 4 })
      labels = response["result"].map { |i| i["label"] }
      assert_includes labels, "layout"
      refute_includes labels, "button" # prefix-filtered
    end
  end

  def test_attr_completion_inside_component_tag
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      open_doc(uri, "<.chip ")
      (response,) = request("textDocument/completion",
                            "textDocument" => { "uri" => uri },
                            "position" => { "line" => 0, "character" => 7 })
      items = response["result"]
      text_item = items.find { |i| i["label"] == "text" }
      assert text_item, "expected attr completion for `text`"
      assert_match(/required :string/, text_item["detail"])
      kind_item = items.find { |i| i["label"] == "kind" }
      assert_match(/values: "a"\|"b"/, kind_item["detail"])
      assert_equal "text=", text_item["insertText"]
    end
  end

  def test_slot_completion_inside_component_children
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      open_doc(uri, "<.layout><:")
      (response,) = request("textDocument/completion",
                            "textDocument" => { "uri" => uri },
                            "position" => { "line" => 0, "character" => 11 })
      labels = response["result"].map { |i| i["label"] }
      assert_includes labels, "side"
      refute_includes labels, "inner"
    end
  end

  # -- hover / definition ----------------------------------------------------------

  def test_hover_shows_contract
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      open_doc(uri, "<.chip text=\"hi\"/>\n")
      (response,) = request("textDocument/hover",
                            "textDocument" => { "uri" => uri },
                            "position" => { "line" => 0, "character" => 3 })
      markdown = response.dig("result", "contents", "value")
      assert_match(/\.chip\*\*/, markdown)
      assert_match(/`text` :string, required/, markdown)
      assert_match(/`kind` :string.*default: `"a"`/, markdown)
    end
  end

  def test_definition_points_at_template_file
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      open_doc(uri, "<.button label=\"x\"/>\n")
      (response,) = request("textDocument/definition",
                            "textDocument" => { "uri" => uri },
                            "position" => { "line" => 0, "character" => 4 })
      location = response["result"]
      assert_equal "file://#{File.join(dir, 'button.html.her')}", location["uri"]
      assert_equal 0, location.dig("range", "start", "line")
    end
  end

  def test_hover_on_plain_text_is_nil
    uri = "file:///tmp/plain.her"
    open_doc(uri, "<p>hello</p>\n")
    (response,) = request("textDocument/hover",
                          "textDocument" => { "uri" => uri },
                          "position" => { "line" => 0, "character" => 5 })
    assert_nil response["result"]
  end

  # -- edge cases -------------------------------------------------------------------

  def test_did_change_before_did_open_is_safe
    (note,) = notify("textDocument/didChange",
                     "textDocument" => { "uri" => "file:///tmp/never_opened.her" },
                     "contentChanges" => [{ "text" => "<p>x</p>" }])
    assert_empty note.dig("params", "diagnostics")
  end

  def test_completion_at_origin_of_empty_document
    uri = "file:///tmp/empty.her"
    open_doc(uri, "")
    (response,) = request("textDocument/completion",
                          "textDocument" => { "uri" => uri },
                          "position" => { "line" => 0, "character" => 0 })
    assert_equal [], response["result"]
  end

  def test_position_beyond_end_of_document
    uri = "file:///tmp/short.her"
    open_doc(uri, "<p>x</p>\n")
    (response,) = request("textDocument/hover",
                          "textDocument" => { "uri" => uri },
                          "position" => { "line" => 99, "character" => 42 })
    assert_nil response["result"]
  end

  def test_percent_encoded_uris_resolve_registered_files
    Dir.mktmpdir("her sp ace") do |dir|
      path = File.join(dir, "thing.html.her")
      File.write(path, "<.nope_not_here/>\n")
      mod = Module.new { extend Her::Component }
      mod.embed_templates("*.html.her", dir: dir)
      uri = "file://#{path.gsub(' ', '%20')}"
      (note,) = open_doc(uri, File.read(path))
      messages = note.dig("params", "diagnostics").map { |d| d["message"] }
      assert(messages.any? { |m| m.include?("nope_not_here") },
             "expected the %20 uri to resolve to the registered template")
    end
  end

  def test_did_close_clears_diagnostics
    uri = "file:///tmp/closing.her"
    open_doc(uri, "<div>\n")
    (note,) = notify("textDocument/didClose", "textDocument" => { "uri" => uri })
    assert_equal "textDocument/publishDiagnostics", note["method"]
    assert_empty note.dig("params", "diagnostics")
  end

  def test_exit_stops_the_loop
    input = StringIO.new
    Her::LSP.write_message(input, { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} })
    Her::LSP.write_message(input, { "jsonrpc" => "2.0", "method" => "exit" })
    input.rewind
    output = StringIO.new
    assert_equal 0, Her::LSP::Server.new(input: input, output: output).run
    output.rewind
    first = Her::LSP.read_message(output)
    assert_equal "her-lsp", first.dig("result", "serverInfo", "name")
  end
end
