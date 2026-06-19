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
    (response,) = request("textDocument/somethingNotReal")
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

  # -- inline templates in .rb files -----------------------------------------------

  # Writes a unique HER component module to dir and returns its path. The body
  # is indented to sit inside `module ... extend Her::Component`.
  def inline_module_file(dir, body)
    @inline_seq = (@inline_seq || 0) + 1
    name = "Inline#{Process.pid}_#{@inline_seq}"
    path = File.join(dir, "inline_#{@inline_seq}.rb")
    File.write(path, "module #{name}\n  extend Her::Component\n#{body}\nend\n")
    path
  end

  def test_inline_parse_error_maps_to_the_ruby_line
    Dir.mktmpdir do |dir|
      # No require: a live buffer with a broken inline template still diagnoses.
      buffer = <<~RUBY
        module Draft
          extend Her::Component
          component :oops do
            template <<~HER
              <div>
                <span>x</div>
              </div>
            HER
          end
        end
      RUBY
      uri = "file://#{File.join(dir, 'draft.rb')}"
      (note,) = open_doc(uri, buffer)
      diag = note.dig("params", "diagnostics").first
      assert diag, "expected a diagnostic for the broken inline template"
      assert_equal 1, diag["severity"]
      assert_match(/mismatched closing tag/, diag["message"])
      assert_equal 5, diag.dig("range", "start", "line") # 0-based: the </div> line
    end
  end

  def test_inline_single_line_template_error_gets_the_start_column_added
    Dir.mktmpdir do |dir|
      buffer = %(module Draft2\n  extend Her::Component\n  component :x do\n    template "<div></span>"\n  end\nend\n)
      uri = "file://#{File.join(dir, 'draft2.rb')}"
      (note,) = open_doc(uri, buffer)
      diag = note.dig("params", "diagnostics").first
      assert diag, "expected a diagnostic for the broken single-line inline template"
      assert_equal 3, diag.dig("range", "start", "line")
      # the column must be mapped past `    template "` to the real `</span>`
      assert_equal buffer.lines[3].index("</span>"), diag.dig("range", "start", "character")
    end
  end

  def test_repeated_diagnostics_do_not_leak_scratch_modules
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :caller do
            template "<.nowhere_to_be_seen/>"
          end
      BODY
      require path
      uri = "file://#{path}"
      buffer = File.read(path)
      baseline = Her.component_modules.size
      5.times { open_doc(uri, buffer) }
      assert_operator Her.component_modules.size, :<=, baseline,
                      "compiling unsaved buffers must not leak scratch modules"
      # the real module still resolves, so verify findings keep firing
      (note,) = open_doc(uri, buffer)
      messages = note.dig("params", "diagnostics").map { |d| d["message"] }
      assert(messages.any? { |m| m.include?("nowhere_to_be_seen") })
    end
  end

  def test_non_her_ruby_with_a_template_call_is_left_alone
    Dir.mktmpdir do |dir|
      buffer = %(def template(x) = x\ntemplate "<div></span>"\n) # unrelated DSL, no HER
      uri = "file://#{File.join(dir, 'other.rb')}"
      (note,) = open_doc(uri, buffer)
      assert_empty note.dig("params", "diagnostics")
    end
  end

  def test_inline_completion_hover_and_definition
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :badge do
            attr :text, :string, required: true
            template %(<span class="badge">{@text}</span>)
          end
          component :panel do
            attr :title, :string
            template <<~HER
              <section>
                <.badge text={@title}/>
              </section>
            HER
          end
      BODY
      require path
      uri = "file://#{path}"
      buffer = File.read(path)
      open_doc(uri, buffer)

      badge_line = buffer.lines.index { |l| l.include?("<.badge") }
      tag_col = buffer.lines[badge_line].index("<.")

      # completion right after "<." inside the heredoc region
      (completion,) = request("textDocument/completion",
                              "textDocument" => { "uri" => uri },
                              "position" => { "line" => badge_line, "character" => tag_col + 2 })
      assert_includes completion["result"].map { |i| i["label"] }, "badge"

      # hover on <.badge shows its contract
      (hover,) = request("textDocument/hover",
                         "textDocument" => { "uri" => uri },
                         "position" => { "line" => badge_line, "character" => tag_col + 2 })
      assert_match(/`text` :string, required/, hover.dig("result", "contents", "value"))

      # go-to-definition jumps back into the same Ruby file
      (definition,) = request("textDocument/definition",
                              "textDocument" => { "uri" => uri },
                              "position" => { "line" => badge_line, "character" => tag_col + 2 })
      assert_equal uri, definition.dig("result", "uri")
    end
  end

  def test_inline_features_are_inert_outside_template_regions
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :chip do
            attr :x, :string
            template "<span>{@x}</span>"
          end
      BODY
      require path
      uri = "file://#{path}"
      buffer = File.read(path)
      open_doc(uri, buffer)
      ruby_line = buffer.lines.index { |l| l.include?("extend Her::Component") }
      (completion,) = request("textDocument/completion",
                              "textDocument" => { "uri" => uri },
                              "position" => { "line" => ruby_line, "character" => 2 })
      assert_equal [], completion["result"]
    end
  end

  def test_inline_verify_finding_lands_on_the_call_line
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :caller do
            template "<.nowhere_to_be_seen/>"
          end
      BODY
      require path
      uri = "file://#{path}"
      buffer = File.read(path)
      (note,) = open_doc(uri, buffer)
      messages = note.dig("params", "diagnostics").map { |d| d["message"] }
      assert(messages.any? { |m| m.include?("nowhere_to_be_seen") },
             "expected the inline call to an unknown component to be flagged")
    end
  end

  # -- symbols / signature / formatting / references / rename / source -------------

  def test_document_symbol_lists_components_and_slots
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'layout.html.her')}"
      open_doc(uri, File.read(File.join(dir, "layout.html.her")))
      (resp,) = request("textDocument/documentSymbol", "textDocument" => { "uri" => uri })
      sym = resp["result"].find { |s| s["name"] == "layout" }
      assert sym, "layout component should be listed"
      assert_equal 12, sym["kind"]
      child_names = (sym["children"] || []).map { |c| c["name"] }
      assert_includes child_names, "side"
    end
  end

  def test_workspace_symbol_query_filters_by_name
    Dir.mktmpdir do |dir|
      project(dir)
      (resp,) = request("workspace/symbol", "query" => "butt")
      names = resp["result"].map { |s| s["name"] }
      assert_includes names, "button"
      refute_includes names, "layout"
    end
  end

  def test_signature_help_shows_the_contract
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      open_doc(uri, "<.chip ")
      (resp,) = request("textDocument/signatureHelp",
                        "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => 7 })
      label = resp.dig("result", "signatures", 0, "label")
      assert_match(/text:.*required/, label)
      params = resp.dig("result", "signatures", 0, "parameters").map { |p| p["label"] }
      assert(params.any? { |l| l.start_with?("text") })
    end
  end

  def test_formatting_is_offered_and_idempotent
    uri = "file:///tmp/fmt.her"
    open_doc(uri, "<div>\n<span>x</span>\n</div>\n")
    (resp,) = request("textDocument/formatting", "textDocument" => { "uri" => uri })
    refute_empty resp["result"]
    formatted = resp["result"].first["newText"]
    open_doc(uri, formatted)
    (resp2,) = request("textDocument/formatting", "textDocument" => { "uri" => uri })
    assert_equal [], resp2["result"], "an already-formatted document yields no edits"
  end

  def test_formatting_skips_unparseable_template
    uri = "file:///tmp/bad.her"
    open_doc(uri, "<div>\n") # unclosed
    (resp,) = request("textDocument/formatting", "textDocument" => { "uri" => uri })
    assert_nil resp["result"]
  end

  def test_references_and_highlight_find_component_usages
    Dir.mktmpdir do |dir|
      project(dir)
      page = File.join(dir, "page.html.her")
      uri = "file://#{page}"
      src = File.read(page) # "<.layout><p>x</p></.layout>\n"
      open_doc(uri, src)
      char = src.index("layout")

      (refs,) = request("textDocument/references",
                        "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => char })
      page_refs = refs["result"].select { |r| r["uri"] == uri }
      assert_equal 2, page_refs.size # the <.layout open and the </.layout> close
      page_refs.each do |ref|
        slice = src.lines[0][ref.dig("range", "start", "character")...ref.dig("range", "end", "character")]
        assert_equal "layout", slice
      end

      (hl,) = request("textDocument/documentHighlight",
                      "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => char })
      assert_equal 2, hl["result"].size
      assert(hl["result"].all? { |h| h["kind"] == 1 })
    end
  end

  def test_prepare_rename_returns_the_name_range
    Dir.mktmpdir do |dir|
      project(dir)
      uri = "file://#{File.join(dir, 'page.html.her')}"
      src = File.read(File.join(dir, "page.html.her"))
      open_doc(uri, src)
      (resp,) = request("textDocument/prepareRename",
                        "textDocument" => { "uri" => uri }, "position" => { "line" => 0, "character" => src.index("layout") })
      assert_equal "layout", resp.dig("result", "placeholder")
    end
  end

  def test_rename_file_backed_component_rewrites_usages_and_renames_the_file
    Dir.mktmpdir do |dir|
      project(dir)
      page = File.join(dir, "page.html.her")
      uri = "file://#{page}"
      src = File.read(page)
      open_doc(uri, src)
      (resp,) = request("textDocument/rename", "textDocument" => { "uri" => uri },
                                               "position" => { "line" => 0, "character" => src.index("layout") },
                                               "newName" => "shell")
      changes = resp.dig("result", "documentChanges")
      text_change = changes.find { |c| c.dig("textDocument", "uri") == uri }
      assert text_change
      assert_equal 2, text_change["edits"].size
      assert(text_change["edits"].all? { |e| e["newText"] == "shell" })
      file_rename = changes.find { |c| c["kind"] == "rename" }
      assert file_rename, "an embed/sibling component is named after its file, which must be renamed"
      assert_match(%r{/shell\.html\.her\z}, file_rename["newUri"])
    end
  end

  def test_rename_inline_component_rewrites_usage_and_declaration
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :badge do
            attr :text, :string, required: true
            template %(<span>{@text}</span>)
          end
          component :wrap do
            attr :title, :string
            template <<~HER
              <div><.badge text={@title}/></div>
            HER
          end
      BODY
      require path
      uri = "file://#{path}"
      buf = File.read(path)
      open_doc(uri, buf)
      badge_line = buf.lines.index { |l| l.include?("<.badge") }
      (resp,) = request("textDocument/rename", "textDocument" => { "uri" => uri },
                                               "position" => { "line" => badge_line, "character" => buf.lines[badge_line].index("badge") },
                                               "newName" => "chip")
      changes = resp.dig("result", "documentChanges")
      edit = changes.find { |c| c.dig("textDocument", "uri") == uri }
      assert edit
      assert(edit["edits"].all? { |e| e["newText"] == "chip" })
      assert_operator edit["edits"].size, :>=, 2 # the <.badge usage and the `component :badge` declaration
      assert_nil changes.find { |c| c["kind"] == "rename" }, "an inline component has no template file to rename"
    end
  end

  def test_execute_command_show_source_returns_generated_ruby
    Dir.mktmpdir do |dir|
      path = inline_module_file(dir, <<~'BODY')
          component :tag do
            attr :text, :string, required: true
            template %(<b>{@text}</b>)
          end
      BODY
      require path
      uri = "file://#{path}"
      open_doc(uri, File.read(path))
      (resp,) = request("workspace/executeCommand", "command" => "her.showSource", "arguments" => [uri])
      assert_kind_of String, resp["result"]
      assert_match(/<b>/, resp["result"])
    end
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
