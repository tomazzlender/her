# frozen_string_literal: true

require "json"
require_relative "../her" unless defined?(Her::Compiler)

module Her
  # A small language server for .her templates, speaking LSP over stdio
  # with no dependencies beyond stdlib JSON. Start it with
  #
  #   her lsp -r ./path/to/app_boot.rb
  #
  # The --require is what loads your component modules; everything the
  # server knows — components, attrs, types, required, slots, definition
  # sites — comes from the same registry that powers Her.verify. Without a
  # require it still provides syntax diagnostics.
  #
  # Features: diagnostics (parse/compile errors on every change; Her.verify
  # findings on open/save), completion (<. components, attrs inside a
  # component tag, <: slots), hover, and go-to-definition. These work both in
  # standalone .her files and in inline templates (`template <<~HER ... HER`,
  # `%(...)`, or quoted strings) embedded in .rb component files.
  module LSP
    module_function

    # -- JSON-RPC framing -------------------------------------------------------

    def read_message(io)
      length = nil
      while (line = io.gets("\r\n"))
        line = line.chomp("\r\n")
        break if line.empty?
        length = Regexp.last_match(1).to_i if line =~ /\AContent-Length:\s*(\d+)/i
      end
      return nil unless length
      body = io.read(length)
      return nil unless body && body.bytesize == length
      JSON.parse(body)
    end

    def write_message(io, payload)
      body = JSON.generate(payload)
      io.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      io.flush if io.respond_to?(:flush)
    end

    def uri_to_path(uri)
      uri.sub(%r{\Afile://}, "").gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).to_i(16).chr }
    end

    def path_to_uri(path)
      "file://#{path}"
    end

    # Locates inline `template <literal>` bodies inside a Ruby source file so
    # the server can offer for .rb files the same template features it offers
    # for standalone .her files. Parses with Prism (already HER's Ruby parser
    # via RubyScanner), so heredoc (`<<~HER`), percent (`%(...)`) and quoted
    # inline templates are all found precisely, with the body's true line and
    # column in the file.
    module RubyTemplates
      module_function

      # One inline template body and where it sits in the Ruby file.
      #   body       — the raw source between the literal's delimiters
      #   start_line — 1-based file line of the body's first line
      #   start_col  — 0-based column of the body's first character; applies to
      #                the first body line only (later lines align with the file)
      #   end_line   — 1-based file line of the body's last character
      Region = Struct.new(:body, :start_line, :start_col, :end_line, keyword_init: true) do
        # Is the given 0-based LSP line within this region?
        def cover?(line0)
          line1 = line0 + 1
          line1 >= start_line && line1 <= end_line
        end
      end

      # Every inline template region in +source+, in source order. Returns []
      # when the buffer is not valid Ruby (mid-edit) so a transient parse
      # error never takes the server's features down.
      def regions(source)
        result = Prism.parse(source)
        return [] unless result.success?
        finder = Finder.new
        result.value.accept(finder)
        finder.regions
      rescue StandardError
        []
      end

      # Collects the body location of every bare `template "<...>"` call
      # (`receiver.nil?`, so `foo.template` is ignored).
      class Finder < Prism::Visitor
        attr_reader :regions

        def initialize
          @regions = []
          super()
        end

        def visit_call_node(node)
          record(node) if node.receiver.nil? && node.name == :template
          super
        end

        private

        def record(node)
          arg = node.arguments&.arguments&.first
          loc =
            case arg
            when Prism::StringNode
              arg.content_loc
            when Prism::InterpolatedStringNode # squiggly heredocs and #{} strings
              parts = arg.parts
              parts.first.location.join(parts.last.location) unless parts.empty?
            end
          return unless loc

          body = loc.slice
          newlines = body.count("\n")
          last = body.end_with?("\n") ? newlines - 1 : newlines
          @regions << Region.new(body: body, start_line: loc.start_line,
                                 start_col: loc.start_column,
                                 end_line: loc.start_line + [last, 0].max)
        end
      end

      # A `component :name` declaration symbol and where its name sits (the
      # colon excluded, so a rename keeps it). Used for go-to/rename of the
      # declaration itself.
      Declaration = Struct.new(:name, :line, :start_col, :end_col, keyword_init: true)

      # Every `component :name`/`component(:name)` declaration in +source+.
      # Prism-based, so `component :x` inside a string or comment is ignored.
      def declarations(source)
        result = Prism.parse(source)
        return [] unless result.success?
        finder = DeclFinder.new
        result.value.accept(finder)
        finder.declarations
      rescue StandardError
        []
      end

      class DeclFinder < Prism::Visitor
        attr_reader :declarations

        def initialize
          @declarations = []
          super()
        end

        def visit_call_node(node)
          if node.receiver.nil? && node.name == :component
            arg = node.arguments&.arguments&.first
            if arg.is_a?(Prism::SymbolNode) && arg.value
              loc = arg.value_loc
              @declarations << Declaration.new(name: arg.value.to_sym, line: loc.start_line,
                                               start_col: loc.start_column, end_col: loc.end_column)
            end
          end
          super
        end
      end
    end

    class Server
      def initialize(requires: [], input: $stdin, output: $stdout)
        @input = input
        @output = output
        @documents = {}
        @exit = false
        @load_error = nil
        requires.each do |path|
          require File.expand_path(path)
        rescue Exception => e # rubocop:disable Lint/RescueException -- boot errors must not kill the server
          @load_error = "her-lsp: failed to load #{path}: #{e.class}: #{e.message}"
        end
      end

      def run
        @input.binmode if @input.respond_to?(:binmode)
        until @exit
          message = LSP.read_message(@input) or break
          handle(message).each { |out| LSP.write_message(@output, out) }
        end
        0
      end

      # Handles one incoming message; returns the messages to send back.
      # Public so the server can be driven directly in tests.
      def handle(message)
        method = message["method"]
        return [] if method.nil? # a response to a server-initiated request (registerCapability)
        id = message["id"]
        params = message["params"] || {}

        case method
        when "initialize"        then [response(id, initialize_result)]
        when "initialized"       then register_file_watcher + load_error_messages
        when "shutdown"          then [response(id, nil)]
        when "exit"              then @exit = true; []
        when "textDocument/didOpen"
          uri = params.dig("textDocument", "uri")
          @documents[uri] = params.dig("textDocument", "text")
          [publish_diagnostics(uri, verify: true)]
        when "textDocument/didChange"
          uri = params.dig("textDocument", "uri")
          change = (params["contentChanges"] || []).last
          @documents[uri] = change["text"] if change
          [publish_diagnostics(uri, verify: false)]
        when "textDocument/didSave"
          uri = params.dig("textDocument", "uri")
          reload_owner(uri)
          [publish_diagnostics(uri, verify: true)]
        when "textDocument/didClose"
          uri = params.dig("textDocument", "uri")
          @documents.delete(uri)
          [notification("textDocument/publishDiagnostics", "uri" => uri, "diagnostics" => [])]
        when "workspace/didChangeWatchedFiles" then refresh_watched_files
        when "textDocument/completion"        then [response(id, completion(params))]
        when "textDocument/hover"             then [response(id, hover(params))]
        when "textDocument/definition"        then [response(id, definition(params))]
        when "textDocument/references"        then [response(id, references(params))]
        when "textDocument/documentHighlight" then [response(id, document_highlights(params))]
        when "textDocument/documentSymbol"    then [response(id, document_symbols(params))]
        when "workspace/symbol"               then [response(id, workspace_symbols(params))]
        when "textDocument/signatureHelp"     then [response(id, signature_help(params))]
        when "textDocument/formatting"        then [response(id, formatting(params))]
        when "textDocument/onTypeFormatting"  then [response(id, on_type_formatting(params))]
        when "textDocument/foldingRange"      then [response(id, folding_ranges(params))]
        when "textDocument/selectionRange"    then [response(id, selection_ranges(params))]
        when "textDocument/linkedEditingRange" then [response(id, linked_editing_ranges(params))]
        when "textDocument/codeAction"        then [response(id, code_actions(params))]
        when "textDocument/prepareCallHierarchy" then [response(id, prepare_call_hierarchy(params))]
        when "callHierarchy/incomingCalls"    then [response(id, incoming_calls(params))]
        when "callHierarchy/outgoingCalls"    then [response(id, outgoing_calls(params))]
        when "textDocument/prepareRename"     then [response(id, prepare_rename(params))]
        when "textDocument/rename"            then [response(id, rename(params))]
        when "workspace/willRenameFiles"      then [response(id, will_rename_files(params))]
        when "workspace/executeCommand"       then [response(id, execute_command(params))]
        else
          id ? [error_response(id, -32_601, "method not supported: #{method}")] : []
        end
      end

      private

      def initialize_result
        {
          "capabilities" => {
            "textDocumentSync" => 1, # full content sync
            "completionProvider" => { "triggerCharacters" => ["<", ".", ":", " "] },
            "hoverProvider" => true,
            "definitionProvider" => true,
            "referencesProvider" => true,
            "documentHighlightProvider" => true,
            "documentSymbolProvider" => true,
            "workspaceSymbolProvider" => true,
            "signatureHelpProvider" => { "triggerCharacters" => [" "] },
            "documentFormattingProvider" => true,
            "foldingRangeProvider" => true,
            "selectionRangeProvider" => true,
            "linkedEditingRangeProvider" => true,
            "callHierarchyProvider" => true,
            "codeActionProvider" => true,
            "documentOnTypeFormattingProvider" => { "firstTriggerCharacter" => ">" },
            "renameProvider" => { "prepareProvider" => true },
            "executeCommandProvider" => { "commands" => ["her.showSource"] },
            "workspace" => {
              "fileOperations" => {
                "willRename" => { "filters" => [{ "pattern" => { "glob" => "**/*.her" } }] }
              }
            }
          },
          "serverInfo" => { "name" => "her-lsp", "version" => Her::VERSION }
        }
      end

      def load_error_messages
        return [] unless @load_error
        [notification("window/showMessage", "type" => 1, "message" => @load_error)]
      end

      # Ask the editor to watch .her files so edits made outside the editor
      # (git pull, a generator, another tool) refresh the server's view —
      # the registry is otherwise only as fresh as the -r boot plus in-editor
      # saves. A server-initiated request; the client's response carries no
      # method and is ignored by handle.
      def register_file_watcher
        [{
          "jsonrpc" => "2.0", "id" => "her-watched-files", "method" => "client/registerCapability",
          "params" => {
            "registrations" => [{
              "id" => "her-watched-files", "method" => "workspace/didChangeWatchedFiles",
              "registerOptions" => { "watchers" => [{ "globPattern" => "**/*.her" }] }
            }]
          }
        }]
      end

      # -- diagnostics ----------------------------------------------------------

      def publish_diagnostics(uri, verify:)
        path = LSP.uri_to_path(uri)
        text = @documents[uri].to_s
        entry = registry_entry_for(path)

        diagnostics =
          if path.end_with?(".rb")
            her_ruby_file?(path, text) ? inline_diagnostics(path, text) : []
          else
            template_diagnostics(path, text, entry)
          end

        # Verify findings reflect the *registry* — the last-saved state —
        # while the parse/compile pass above tracks the live buffer. didSave
        # reloads file templates first, so the two converge on every save.
        # Inline templates carry meta[:file], so an entry resolves for .rb
        # files too and their call-site findings are file-absolute already.
        if verify && entry && diagnostics.empty?
          begin
            Her.verify(entry[0]).each do |issue|
              next unless issue.file == path
              diagnostics << diagnostic(issue.line, 1, issue.message, issue.error? ? 1 : 2)
            end
          rescue StandardError
            nil # verification must never take diagnostics down with it
          end
        end

        notification("textDocument/publishDiagnostics",
                     "uri" => uri, "diagnostics" => diagnostics)
      end

      # Diagnostics for a standalone .her document: the whole file is one
      # template, checked against its registered contract when there is one.
      def template_diagnostics(path, text, entry)
        diagnostics = []
        begin
          check_template(text, path, first_line: 1, name: entry&.at(1), meta: entry&.at(2))
        rescue ParseError => e
          diagnostics << diagnostic(e.line, e.column, e.message, 1)
        rescue CompileError => e
          line = e.message[/\(#{Regexp.escape(path)}:(\d+)\)/, 1]&.to_i || 1
          diagnostics << diagnostic(line, 1, e.message, 1)
        end
        diagnostics
      end

      # Diagnostics for every inline `template <...>` body in a Ruby file.
      # Each region is checked on its own and positions are mapped back to the
      # Ruby file: parse/compile error lines are already file-absolute (the
      # tokenizer/parser are told the body's first_line) and a first-line
      # column gets the body's start column added. A region matched to a
      # registered component is checked against its real contract; an
      # unmatched one (new/unsaved) falls back to a syntax-only check,
      # mirroring how a .her file degrades without a registry entry.
      def inline_diagnostics(path, text)
        entries = inline_entries_for(path)
        diagnostics = []
        RubyTemplates.regions(text).each_with_index do |region, i|
          name, meta = entries[i]
          begin
            check_template(region.body, path, first_line: region.start_line, name: name, meta: meta)
          rescue ParseError => e
            column = e.column.to_i
            column += region.start_col if e.line == region.start_line
            diagnostics << diagnostic(e.line, column, e.message, 1)
          rescue CompileError => e
            line = e.message[/\(#{Regexp.escape(path)}:(\d+)\)/, 1]&.to_i || region.start_line
            diagnostics << diagnostic(line, 1, e.message, 1)
          end
        end
        diagnostics
      end

      # Parse a template body, and — when its contract is known — compile it
      # too, so undeclared-attr and other contract errors surface live. The
      # compile runs against a throwaway module that is deregistered right
      # after, so it never shadows the real component in file-keyed lookups
      # (and editing never leaks modules). Raises ParseError/CompileError.
      def check_template(source, path, first_line:, name:, meta:)
        unless meta
          tokens = Tokenizer.new(source, file: path, first_line: first_line).tokenize
          return Parser.new(tokens, file: path, first_line: first_line, source: source).parse
        end

        scratch = Module.new { extend Her::Component }
        begin
          attrs = meta[:attrs_origin] == :block ? meta[:attrs] : nil
          Compiler.define(scratch, name || :__lsp_check__, source,
                          origin: { file: path, first_line: first_line },
                          attrs: attrs, kind: meta[:kind], strict_html: meta[:strict_html])
        ensure
          Her.__deregister_component_module(scratch)
        end
      end

      # Registered inline components declared in this Ruby file, as
      # [name, meta] pairs in source order — zipped positionally with the
      # regions found in the buffer so a region can be checked against its
      # real contract. Only the contract (line-independent) is taken from
      # here, so line shifts from unsaved edits don't matter and a mismatch
      # simply degrades to a syntax check.
      def inline_entries_for(path)
        Her.component_modules.flat_map do |mod|
          mod.__her_registry.filter_map do |name, meta|
            [name, meta] if meta[:file] == path && meta[:template_path].nil?
          end
        end.sort_by { |(_name, meta)| meta[:first_line].to_i }
      end

      # Does this Ruby file define HER components? A cheap gate so the server
      # never reads inline templates out of unrelated Ruby (a stray
      # `template "..."` in some other DSL): true when the file is already a
      # registered component file or names the definition mixin.
      def her_ruby_file?(path, text)
        !registry_entry_for(path).nil? || text.include?("Her::Component")
      end

      def diagnostic(line, column, message, severity)
        l = [line.to_i - 1, 0].max
        c = [column.to_i - 1, 0].max
        {
          "range" => { "start" => { "line" => l, "character" => c },
                       "end" => { "line" => l, "character" => c + 1 } },
          "severity" => severity,
          "source" => "her",
          "message" => message
        }
      end

      def reload_owner(uri)
        entry = registry_entry_for(LSP.uri_to_path(uri))
        Her.reload_templates!(entry[0]) if entry
      rescue StandardError
        nil # compile problems show up as diagnostics instead
      end

      # A watched .her file changed on disk: recompile file-backed templates so
      # their contracts/calls are current, then re-diagnose open documents so
      # cross-file findings (a callee whose required attrs changed, say) update
      # without a restart. Each module reloads independently so one broken or
      # deleted template can't block the rest. Scope: edits to *existing*
      # file-backed templates — brand-new or removed components, and inline .rb
      # templates, still need the app's code reloader (or a restart), since the
      # registry is built by the -r require.
      def refresh_watched_files
        Her.component_modules.each do |mod|
          Her.reload_templates!(mod)
        rescue StandardError
          nil # a deleted/now-broken template surfaces as a diagnostic, not a crash
        end
        @documents.keys.map { |uri| publish_diagnostics(uri, verify: true) }
      end

      # -- completion -----------------------------------------------------------

      def completion(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return []
        return [] unless region_at(uri, params["position"])
        prefix = text_before(text, params["position"])
        line_prefix = prefix[/[^\n]*\z/]

        if (match = line_prefix.match(/<\.([a-z_][a-zA-Z0-9_]*)?\z/))
          component_items(uri, match[1].to_s)
        elsif (match = line_prefix.match(/<:([a-z_][a-zA-Z0-9_]*)?\z/))
          slot_items(uri, prefix, match[1].to_s)
        elsif (tag = unterminated_component_tag(prefix))
          attr_items(uri, tag)
        else
          []
        end
      end

      def component_items(uri, typed)
        candidate_registries(uri).flat_map do |mod, registry|
          registry.filter_map do |name, meta|
            next unless name.to_s.start_with?(typed)
            {
              "label" => name.to_s,
              "kind" => 3, # Function
              "detail" => "#{Her.module_label(mod)}.#{name}#{contract_summary(meta)}",
              "insertText" => name.to_s
            }
          end
        end
      end

      def attr_items(uri, component_name)
        _mod, _name, meta = find_component(uri, component_name)
        return [] unless meta && meta[:attrs]
        meta[:attrs].map do |attr_name, spec|
          {
            "label" => attr_name.to_s,
            "kind" => 10, # Property
            "detail" => attr_detail(spec),
            "insertText" => "#{attr_name}="
          }
        end
      end

      # The human-readable contract for one attr, e.g. "required :string" or
      # ":symbol, default: :a, values: :a|:b". Shared by completion, hover and
      # signature help so they always read the same.
      def attr_detail(spec)
        detail = +""
        detail << "required " if spec[:required]
        detail << Her.type_label(spec[:type])
        detail << ", default: #{spec[:default].inspect}" if spec.key?(:default)
        detail << ", values: #{spec[:values].map(&:inspect).join('|')}" if spec[:values]
        detail
      end

      def slot_items(uri, prefix, typed)
        component_name = enclosing_component(prefix) or return []
        _mod, _name, meta = find_component(uri, component_name)
        return [] unless meta
        meta[:rendered_slots].to_a.filter_map do |slot|
          next if slot == :inner # inner is the implicit children slot
          next unless slot.to_s.start_with?(typed)
          { "label" => slot.to_s, "kind" => 8, "detail" => "slot of <.#{component_name}>" }
        end
      end

      # Cursor inside `<.button ...` with no closing `>` yet.
      def unterminated_component_tag(prefix)
        prefix[/<\.([a-z_][a-zA-Z0-9_]*)[^>]*\z/m, 1]
      end

      # Innermost still-open component call before the cursor.
      def enclosing_component(prefix)
        stack = []
        prefix.scan(%r{<(/?)\.([a-z_]\w*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(/?)>}m) do |closing, name, _attrs, self_closing|
          if closing == "/"
            stack.pop if stack.last == name
          elsif self_closing != "/"
            stack << name
          end
        end
        stack.last
      end

      # -- hover / definition -----------------------------------------------------

      def hover(params)
        resolved = resolve_at(params)
        return nil unless resolved
        mod, name, meta = resolved
        { "contents" => { "kind" => "markdown", "value" => hover_markdown(mod, name, meta) } }
      end

      def definition(params)
        resolved = resolve_at(params)
        return nil unless resolved
        meta = resolved[2]
        line = meta[:first_line].to_i - 1
        {
          "uri" => LSP.path_to_uri(meta[:file]),
          "range" => { "start" => { "line" => line, "character" => 0 },
                       "end" => { "line" => line, "character" => 0 } }
        }
      end

      def hover_markdown(mod, name, meta)
        out = +"**#{Her.module_label(mod)}.#{name}** — `#{meta[:file]}:#{meta[:first_line]}`\n"
        if meta[:attrs]&.any?
          out << "\nAttrs:\n"
          meta[:attrs].each do |attr_name, spec|
            line = "- `#{attr_name}` #{Her.type_label(spec[:type])}"
            line << ", required" if spec[:required]
            line << ", default: `#{spec[:default].inspect}`" if spec.key?(:default)
            line << ", values: #{spec[:values].map(&:inspect).join(', ')}" if spec[:values]
            out << line << "\n"
          end
        else
          out << "\nDeclares no attrs (static template).\n"
        end
        slots = meta[:rendered_slots].to_a
        out << "\nSlots: #{slots.map { |s| "`#{s}`" }.join(', ')}\n" if slots.any?
        out
      end

      # Resolve the component reference under the cursor, if any.
      def resolve_at(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        position = params["position"]
        return nil unless region_at(uri, position)
        line = text.lines[position["line"]] or return nil
        character = position["character"]

        line.to_enum(:scan, %r{</?(?:\.([a-z_]\w*)|([A-Z][\w:]*)\.([a-z_]\w*))}).each do
          match = Regexp.last_match
          next unless match.begin(0) <= character && character <= match.end(0)
          return match[1] ? find_component(uri, match[1]) : find_remote(match[2], match[3])
        end
        nil
      end

      # -- registry access ----------------------------------------------------------

      def registry_entry_for(path)
        Her.component_modules.each do |mod|
          mod.__her_registry.each do |name, meta|
            # template_path matches file-backed (.her) templates; file matches
            # those plus inline templates, whose origin file is the .rb source.
            return [mod, name, meta] if meta[:template_path] == path || meta[:file] == path
          end
        end
        nil
      end

      # The template region a position is inside, or nil. A .her document is a
      # single implicit region (the whole file), so its features are never
      # gated; a .rb document exposes one region per inline template, and a
      # position outside them all (plain Ruby) resolves to nil — that's what
      # keeps completion/hover/definition inert in the surrounding code.
      def region_at(uri, position)
        path = LSP.uri_to_path(uri)
        return :whole unless path.end_with?(".rb")
        text = @documents[uri] or return nil
        return nil unless her_ruby_file?(path, text)
        RubyTemplates.regions(text).find { |r| r.cover?(position["line"]) }
      end

      # Registries to search: the module owning this file first, then all.
      def candidate_registries(uri)
        owner = registry_entry_for(LSP.uri_to_path(uri))&.first
        mods = owner ? [owner] : Her.component_modules
        mods.map { |mod| [mod, mod.__her_registry] }
      end

      def find_component(uri, name)
        name = name.to_sym
        candidate_registries(uri).each do |mod, registry|
          return [mod, name, registry[name]] if registry.key?(name)
        end
        Her.component_modules.each do |mod|
          return [mod, name, mod.__her_registry[name]] if mod.__her_registry.key?(name)
        end
        nil
      end

      def find_remote(receiver, func)
        func = func.to_sym
        Her.component_modules.each do |mod|
          label = Her.module_label(mod)
          next unless label == receiver || label.end_with?("::#{receiver}")
          return [mod, func, mod.__her_registry[func]] if mod.__her_registry.key?(func)
        end
        nil
      end

      def contract_summary(meta)
        attrs = meta[:attrs] || {}
        required = attrs.select { |_, spec| spec[:required] }.keys
        required.any? ? " (requires #{required.map { |r| ":#{r}" }.join(', ')})" : ""
      end

      # -- symbols --------------------------------------------------------------------

      # The components a document defines, as DocumentSymbols (with their
      # rendered slots as children). Sourced from the registry, so it works
      # for .her files and inline .rb components alike.
      def document_symbols(params)
        path = LSP.uri_to_path(params.dig("textDocument", "uri"))
        components_in_file(path).map do |name, meta|
          point = symbol_point(meta)
          symbol = { "name" => name.to_s, "detail" => contract_summary(meta).strip,
                     "kind" => 12, "range" => point, "selectionRange" => point } # 12 = Function
          children = (meta[:rendered_slots] || []).to_a.filter_map do |slot|
            { "name" => slot.to_s, "kind" => 8, "range" => point, "selectionRange" => point } unless slot == :inner
          end
          symbol["children"] = children if children.any?
          symbol
        end
      end

      # Workspace-wide component search (Cmd-T), filtered by a substring query.
      def workspace_symbols(params)
        query = params["query"].to_s.downcase
        symbols = []
        each_registered_component do |mod, name, meta|
          next unless query.empty? || name.to_s.downcase.include?(query)
          symbols << { "name" => name.to_s, "kind" => 12, "containerName" => Her.module_label(mod),
                       "location" => { "uri" => LSP.path_to_uri(meta[:file]), "range" => symbol_point(meta) } }
        end
        symbols
      end

      def symbol_point(meta)
        line = [meta[:first_line].to_i - 1, 0].max
        { "start" => { "line" => line, "character" => 0 }, "end" => { "line" => line, "character" => 0 } }
      end

      # -- signature help -------------------------------------------------------------

      # While the cursor sits inside an open `<.name ...` tag, show the callee's
      # contract — each attr with its type/required/default/values.
      def signature_help(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        return nil unless region_at(uri, params["position"])
        name = unterminated_component_tag(text_before(text, params["position"])) or return nil
        _mod, cname, meta = find_component(uri, name)
        return nil unless meta

        attrs = meta[:attrs] || {}
        parameters = attrs.map { |attr_name, spec| { "label" => "#{attr_name}: #{attr_detail(spec)}" } }
        label =
          if attrs.empty?
            "<.#{cname}> — no attrs"
          else
            "<.#{cname} #{attrs.map { |n, spec| "#{n}: #{attr_detail(spec)}" }.join(', ')}>"
          end
        {
          "signatures" => [{ "label" => label,
                             "documentation" => "#{meta[:file]}:#{meta[:first_line]}",
                             "parameters" => parameters }],
          "activeSignature" => 0,
          "activeParameter" => 0
        }
      end

      # -- formatting -----------------------------------------------------------------

      # Format .her documents with Her::Formatter (the engine behind
      # `her format`). Inline templates in .rb files are left untouched — their
      # indentation belongs to the surrounding Ruby heredoc.
      def formatting(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        return nil unless LSP.uri_to_path(uri).end_with?(".her")
        formatted =
          begin
            Formatter.format(text)
          rescue ParseError
            return nil # never reformat a template that doesn't parse
          end
        return [] if formatted == text
        [{ "range" => { "start" => { "line" => 0, "character" => 0 },
                        "end" => { "line" => text.count("\n") + 1, "character" => 0 } },
           "newText" => formatted }]
      end

      # -- references / highlight / rename --------------------------------------------

      # The reference grammar (same as resolve_at): `<.name>` / `</.name>` and
      # qualified `<Mod.name>` / `</Mod.name>`.
      USAGE_PATTERN = %r{</?(?:\.([a-z_]\w*)|([A-Z][\w:]*)\.([a-z_]\w*))}

      def references(params)
        mod, name = resolve_at(params)&.first(2)
        return nil unless mod
        component_usages(mod, name).map do |(path, line0, from, to)|
          { "uri" => LSP.path_to_uri(path), "range" => point_range(line0, from, to) }
        end
      end

      def document_highlights(params)
        mod, name = resolve_at(params)&.first(2)
        return nil unless mod
        path = LSP.uri_to_path(params.dig("textDocument", "uri"))
        component_usages(mod, name).filter_map do |(upath, line0, from, to)|
          { "range" => point_range(line0, from, to), "kind" => 1 } if upath == path # 1 = Text
        end
      end

      def prepare_rename(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        line0 = params.dig("position", "line")
        character = params.dig("position", "character")
        line = text.lines[line0] or return nil

        if region_at(uri, params["position"]) && (hit = usage_at(line, character))
          name, from, to = hit
          return { "range" => point_range(line0, from, to), "placeholder" => name }
        end
        if her_ruby_file?(LSP.uri_to_path(uri), text) && (decl = declaration_under(text, line0, character))
          return { "range" => point_range(line0, decl.start_col, decl.end_col), "placeholder" => decl.name.to_s }
        end
        nil
      end

      # Rename a component everywhere: every `<.name>`/`<Mod.name>` usage, the
      # `component :name` declaration symbol in Ruby, and — for a file-backed
      # component named after its file — a workspace rename of that file.
      def rename(params)
        new_name = params["newName"].to_s
        return nil unless new_name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)
        mod, name, meta = resolve_at(params) || component_declaration_at(params)
        return nil unless mod

        edits = Hash.new { |hash, key| hash[key] = [] }
        component_usages(mod, name).each do |(path, line0, from, to)|
          edits[LSP.path_to_uri(path)] << { "range" => point_range(line0, from, to), "newText" => new_name }
        end
        declaration_edits(name.to_s, new_name).each { |uri, list| edits[uri].concat(list) }

        changes = edits.map do |uri, list|
          { "textDocument" => { "uri" => uri, "version" => nil }, "edits" => list.uniq }
        end
        if (file_change = template_file_rename(meta, name.to_s, new_name))
          changes << file_change
        end
        { "documentChanges" => changes }
      end

      # Every workspace reference to a component, as [path, line0, from, to].
      # A local `<.name>` matches in files that resolve `name` to this module;
      # a remote `<Mod.name>` matches when Mod resolves to it.
      def component_usages(target_mod, target_name)
        target = target_name.to_s
        opened = open_texts
        results = []
        candidate_files.each do |path|
          text = opened[path] || read_template_file(path)
          next unless text
          owner = registry_entry_for(path)&.first
          template_sources(path, text).each do |(body, base_line, base_col)|
            body.each_line.with_index do |line, index|
              line.to_enum(:scan, USAGE_PATTERN).each do
                match = Regexp.last_match
                matches =
                  if match[1] then match[1] == target && local_resolves_to?(owner, match[1], target_mod)
                  else match[3] == target && (remote = find_remote(match[2], match[3])) && remote[0].equal?(target_mod)
                  end
                next unless matches
                referenced = match[1] || match[3]
                from = (match.end(0) - referenced.length) + (index.zero? ? base_col : 0)
                results << [path, (base_line - 1) + index, from, from + referenced.length]
              end
            end
          end
        end
        results
      end

      # Edits renaming the `component :name` declaration symbol wherever it
      # appears in Ruby (covers inline and explicit components).
      def declaration_edits(name, new_name)
        edits = Hash.new { |hash, key| hash[key] = [] }
        opened = open_texts
        candidate_files.each do |path|
          next unless path.end_with?(".rb")
          text = opened[path] || read_template_file(path)
          next unless text
          RubyTemplates.declarations(text).each do |decl|
            next unless decl.name.to_s == name
            edits[LSP.path_to_uri(path)] << { "range" => point_range(decl.line - 1, decl.start_col, decl.end_col), "newText" => new_name }
          end
        end
        edits
      end

      # A workspace file rename for a component whose name is its basename
      # (`name.html.her`/`name.her`), so embed/sibling naming stays correct.
      def template_file_rename(meta, name, new_name)
        path = meta && meta[:template_path]
        return nil unless path
        base = File.basename(path)
        return nil unless base == "#{name}.html.her" || base == "#{name}.her"
        new_base = "#{new_name}#{base[name.length..]}"
        { "kind" => "rename", "oldUri" => LSP.path_to_uri(path),
          "newUri" => LSP.path_to_uri(File.join(File.dirname(path), new_base)) }
      end

      def component_declaration_at(params)
        uri = params.dig("textDocument", "uri")
        path = LSP.uri_to_path(uri)
        text = @documents[uri] or return nil
        return nil unless her_ruby_file?(path, text)
        decl = declaration_under(text, params.dig("position", "line"), params.dig("position", "character"))
        decl ? find_component(uri, decl.name) : nil
      end

      # The component reference under the cursor on a line, as [name, from, to].
      def usage_at(line, character)
        line.to_enum(:scan, USAGE_PATTERN).each do
          match = Regexp.last_match
          name = match[1] || match[3]
          return [name, match.end(0) - name.length, match.end(0)] if character >= match.begin(0) && character <= match.end(0)
        end
        nil
      end

      # The RubyTemplates::Declaration whose name the 0-based position lands on.
      def declaration_under(text, line0, character)
        RubyTemplates.declarations(text).find do |decl|
          decl.line - 1 == line0 && character >= decl.start_col && character <= decl.end_col
        end
      end

      # -- execute command ------------------------------------------------------------

      # her.showSource — the Ruby HER generated for the component at a position
      # (or the document's first component). The same output as `her source`.
      def execute_command(params)
        return nil unless params["command"] == "her.showSource"
        uri, position = params["arguments"] || []
        return nil unless uri
        resolved = (resolve_at("textDocument" => { "uri" => uri }, "position" => position) if position)
        resolved ||= document_component(uri)
        return nil unless resolved
        mod, name, _meta = resolved
        Her.generated_source(mod, name)
      end

      # -- willRenameFiles ------------------------------------------------------------

      # Renaming `card.html.her` → `panel.html.her` in the explorer renames
      # the component: rewrite every usage and the `component :card`
      # declaration so the basename rule still holds. (The editor performs the
      # file move itself; we only return the in-file edits.)
      def will_rename_files(params)
        changes = []
        (params["files"] || []).each do |file|
          old_path = LSP.uri_to_path(file["oldUri"])
          new_path = LSP.uri_to_path(file["newUri"])
          next unless old_path.end_with?(".her") && new_path.end_with?(".her")
          old_name = component_basename(old_path)
          new_name = component_basename(new_path)
          next if old_name == new_name || !new_name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

          target = nil
          each_registered_component do |mod, name, meta|
            target ||= [mod, name] if name.to_s == old_name && meta[:template_path] == old_path
          end
          next unless target

          edits = Hash.new { |hash, key| hash[key] = [] }
          component_usages(target[0], target[1]).each do |(path, line0, from, to)|
            edits[LSP.path_to_uri(path)] << { "range" => point_range(line0, from, to), "newText" => new_name }
          end
          declaration_edits(old_name, new_name).each { |uri, list| edits[uri].concat(list) }
          edits.each { |uri, list| changes << { "textDocument" => { "uri" => uri, "version" => nil }, "edits" => list.uniq } }
        end
        changes.empty? ? nil : { "documentChanges" => changes }
      end

      def component_basename(path)
        File.basename(path).sub(/\.html\.her\z/, "").sub(/\.her\z/, "")
      end

      # -- folding / selection / linked editing ---------------------------------------

      # All matched tag pairs in a document, with file-absolute positions for
      # the open/close names and the whole-element span. Built from the
      # tokenizer (so holes, strings and attributes are handled), then offset
      # back onto the file (inline .rb regions included).
      TagPair = Struct.new(:open_line, :open_name_from, :open_name_to, :open_tag_col,
                           :close_line, :close_name_from, :close_name_to, :close_tag_end,
                           keyword_init: true)

      def document_tag_pairs(uri, text)
        path = LSP.uri_to_path(uri)
        pairs = []
        template_sources(path, text).each do |(body, base_line, base_col)|
          body_lines = body.lines
          region_tag_pairs(body, path).each do |(open, close)|
            pairs << build_tag_pair(open, close, body_lines, base_line, base_col)
          end
        end
        pairs
      end

      def region_tag_pairs(body, path)
        tokens = Tokenizer.new(body, file: path).tokenize
        stack = []
        pairs = []
        tokens.each do |token|
          next unless token.type == :tag_open || token.type == :tag_close
          if token.type == :tag_open
            stack.push(token) unless token.self_closing || token.void
          else
            open = stack.pop
            pairs << [open, token] if open && open.kind == token.kind && open.name == token.name
          end
        end
        pairs
      rescue ParseError, CompileError
        [] # a half-typed template just yields no structure for now
      end

      def build_tag_pair(open, close, body_lines, base_line, base_col)
        line_offset = base_line - 1
        open_off = open.line == 1 ? base_col : 0
        close_off = close.line == 1 ? base_col : 0
        open_name = tag_name_col(open, closing: false)
        close_name = tag_name_col(close, closing: true)
        close_text = body_lines[close.line - 1] || ""
        gt = close_text.index(">", close_name + close.name.length) || (close.col - 1)
        TagPair.new(
          open_line: line_offset + (open.line - 1),
          open_name_from: open_name + open_off, open_name_to: open_name + open.name.length + open_off,
          open_tag_col: (open.col - 1) + open_off,
          close_line: line_offset + (close.line - 1),
          close_name_from: close_name + close_off, close_name_to: close_name + close.name.length + close_off,
          close_tag_end: gt + 1 + close_off
        )
      end

      # 0-based column of a tag's name within its line: `<`/`</` for HTML and
      # remote, `<.`/`</.` for components, `<:`/`</:` for slots.
      def tag_name_col(token, closing:)
        prefix = case token.kind
                 when :local, :slot then closing ? 3 : 2
                 else closing ? 2 : 1
                 end
        (token.col - 1) + prefix
      end

      def folding_ranges(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        document_tag_pairs(uri, text).filter_map do |pair|
          next if pair.close_line - 1 <= pair.open_line
          { "startLine" => pair.open_line, "endLine" => pair.close_line - 1 }
        end
      end

      def linked_editing_ranges(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        line0 = params.dig("position", "line")
        character = params.dig("position", "character")
        document_tag_pairs(uri, text).each do |pair|
          on_open = pair.open_line == line0 && character >= pair.open_name_from && character <= pair.open_name_to
          on_close = pair.close_line == line0 && character >= pair.close_name_from && character <= pair.close_name_to
          next unless on_open || on_close
          return { "ranges" => [point_range(pair.open_line, pair.open_name_from, pair.open_name_to),
                                point_range(pair.close_line, pair.close_name_from, pair.close_name_to)] }
        end
        nil
      end

      def selection_ranges(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        pairs = document_tag_pairs(uri, text)
        (params["positions"] || []).map do |position|
          enclosing = pairs.select { |pair| pair_encloses?(pair, position["line"], position["character"]) }
          enclosing.sort_by! { |pair| [pair.close_line - pair.open_line, pair.close_tag_end - pair.open_tag_col] }
          selection_chain(enclosing, position)
        end
      end

      def pair_encloses?(pair, line, character)
        after_open = line > pair.open_line || (line == pair.open_line && character >= pair.open_tag_col)
        before_close = line < pair.close_line || (line == pair.close_line && character <= pair.close_tag_end)
        after_open && before_close
      end

      # Nest enclosing spans (innermost first) into a SelectionRange chain whose
      # `parent` links point outward; returns the innermost node.
      def selection_chain(inner_first, position)
        node = nil
        inner_first.reverse_each do |pair|
          range = { "start" => { "line" => pair.open_line, "character" => pair.open_tag_col },
                    "end" => { "line" => pair.close_line, "character" => pair.close_tag_end } }
          node = node ? { "range" => range, "parent" => node } : { "range" => range }
        end
        node || { "range" => point_range(position["line"], position["character"], position["character"]) }
      end

      # -- call hierarchy -------------------------------------------------------------

      def prepare_call_hierarchy(params)
        resolved = resolve_at(params) || component_declaration_at(params)
        return nil unless resolved
        [call_hierarchy_item(*resolved)]
      end

      def outgoing_calls(params)
        item = params["item"] or return nil
        resolved = component_from_item(item) or return nil
        mod, _name, meta = resolved
        (meta[:calls] || []).group_by { |call| call[:name] }.filter_map do |_callee, calls|
          target = resolve_call(mod, calls.first) or next
          { "to" => call_hierarchy_item(*target), "fromRanges" => calls.map { |call| call_from_range(meta, call) } }
        end
      end

      def incoming_calls(params)
        item = params["item"] or return nil
        resolved = component_from_item(item) or return nil
        target_mod, target_name, = resolved
        callers = []
        each_registered_component do |mod, name, meta|
          hits = (meta[:calls] || []).select do |call|
            resolved = resolve_call(mod, call)
            resolved && resolved[0].equal?(target_mod) && resolved[1] == target_name
          end
          callers << { "from" => call_hierarchy_item(mod, name, meta), "fromRanges" => hits.map { |call| call_from_range(meta, call) } } unless hits.empty?
        end
        callers
      end

      def call_hierarchy_item(mod, name, meta)
        { "name" => name.to_s, "kind" => 12, "detail" => Her.module_label(mod),
          "uri" => LSP.path_to_uri(meta[:file]), "range" => symbol_point(meta), "selectionRange" => symbol_point(meta) }
      end

      def component_from_item(item)
        path = LSP.uri_to_path(item["uri"])
        name = item["name"].to_sym
        each_registered_component do |mod, cname, meta|
          return [mod, cname, meta] if cname == name && (meta[:file] == path || meta[:template_path] == path)
        end
        nil
      end

      def resolve_call(caller_mod, call)
        if call[:kind] == :remote
          receiver, _, func = call[:name].rpartition(".")
          find_remote(receiver, func)
        else
          name = call[:name].to_sym
          caller_mod.__her_registry.key?(name) ? [caller_mod, name, caller_mod.__her_registry[name]] : nil
        end
      end

      def call_from_range(meta, call)
        line0 = [meta[:first_line].to_i - 1 + (call[:line].to_i - 1), 0].max
        point_range(line0, 0, 0)
      end

      # -- code actions ---------------------------------------------------------------

      # Quick fixes built from diagnostics in range. Today: an unknown-component
      # finding whose message already suggests a name ("did you mean <.x/>?")
      # becomes a one-click rename of the misspelled call.
      def code_actions(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return []
        (params.dig("context", "diagnostics") || []).filter_map { |diag| unknown_component_fix(uri, text, diag) }
      end

      def unknown_component_fix(uri, text, diag)
        message = diag["message"].to_s
        suggested = message[%r{did you mean <\.([a-z_]\w*)/?>}, 1] or return nil
        bad = message[%r{calls <\.([a-z_]\w*)/?>}, 1] or return nil
        line0 = diag.dig("range", "start", "line")
        line = text.lines[line0] or return nil
        dot = line.index(".#{bad}") or return nil
        name_col = dot + 1
        {
          "title" => "Change <.#{bad}/> to <.#{suggested}/>",
          "kind" => "quickfix",
          "diagnostics" => [diag],
          "edit" => { "changes" => { uri => [{ "range" => point_range(line0, name_col, name_col + bad.length),
                                               "newText" => suggested }] } }
        }
      end

      # -- on-type formatting ---------------------------------------------------------

      # Typing `>` to finish an opening tag inserts its matching close tag.
      def on_type_formatting(params)
        return nil unless params["ch"] == ">"
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return nil
        return nil unless region_at(uri, params["position"])
        line0 = params.dig("position", "line")
        character = params.dig("position", "character")
        lines = text.lines
        before = lines[0...line0].join + (lines[line0] || "")[0, character].to_s
        insert = auto_close_for(before) or return nil
        position = { "line" => line0, "character" => character }
        [{ "range" => { "start" => position, "end" => position }, "newText" => insert }]
      end

      # The close tag for the open tag that `before` (text up to the cursor)
      # just completed, or nil. Conservative: only fires for a clean
      # `<tag …>` with no nested `<`/`>` (so holes/quoted `>` never misfire),
      # and never for void, self-closing, or closing tags.
      def auto_close_for(before)
        match = before.match(%r{<(\.|:)?([a-zA-Z][\w.-]*)[^<>]*>\z}) or return nil
        prefix = match[1]
        name = match[2]
        return nil if match[0].end_with?("/>")
        return nil if prefix.nil? && Tokenizer::VOID_ELEMENTS.include?(name)
        "</#{prefix}#{name}>"
      end

      # -- registry scan helpers ------------------------------------------------------

      def each_registered_component
        Her.component_modules.each do |mod|
          mod.__her_registry.each { |name, meta| yield mod, name, meta }
        end
      end

      def components_in_file(path)
        components = []
        each_registered_component do |_mod, name, meta|
          components << [name, meta] if meta[:file] == path || meta[:template_path] == path
        end
        components.sort_by { |(_name, meta)| meta[:first_line].to_i }
      end

      def document_component(uri)
        path = LSP.uri_to_path(uri)
        name, meta = components_in_file(path).first
        return nil unless meta
        mod = Her.component_modules.find { |m| m.__her_registry[name].equal?(meta) }
        mod ? [mod, name, meta] : nil
      end

      # Files that might hold templates: every registered component's source
      # (file-backed .her and inline .rb origins) plus the open buffers.
      def candidate_files
        paths = []
        each_registered_component do |_mod, _name, meta|
          paths << meta[:template_path] if meta[:template_path]
          paths << meta[:file] if meta[:file]
        end
        open_texts.each_key { |path| paths << path }
        paths.uniq
      end

      # A file's template region(s) as [body, base_line, base_col]: a whole
      # .her file is one region; a .rb file yields one per inline template.
      def template_sources(path, text)
        if path.end_with?(".rb")
          return [] unless her_ruby_file?(path, text)
          RubyTemplates.regions(text).map { |region| [region.body, region.start_line, region.start_col] }
        elsif path.end_with?(".her")
          [[text, 1, 0]]
        else
          []
        end
      end

      def open_texts
        @documents.each_with_object({}) { |(uri, text), map| map[LSP.uri_to_path(uri)] = text }
      end

      def read_template_file(path)
        File.read(path, encoding: "UTF-8") if path && File.file?(path)
      rescue SystemCallError
        nil
      end

      # Does a local `<.name>` in a file owned by +owner+ resolve to
      # +target_mod+? Mirrors find_component's order: the owner first, then the
      # first module that defines the name.
      def local_resolves_to?(owner, name, target_mod)
        name = name.to_sym
        if owner && owner.__her_registry.key?(name)
          owner.equal?(target_mod)
        else
          Her.component_modules.find { |mod| mod.__her_registry.key?(name) }.equal?(target_mod)
        end
      end

      def point_range(line0, from, to)
        { "start" => { "line" => line0, "character" => from },
          "end" => { "line" => line0, "character" => to } }
      end

      # -- plumbing -------------------------------------------------------------------

      def text_before(text, position)
        lines = text.lines
        line_index = position["line"]
        before = lines[0...line_index].join
        current = lines[line_index] || ""
        before + current[0, position["character"]].to_s
      end

      def response(id, result)
        { "jsonrpc" => "2.0", "id" => id, "result" => result }
      end

      def error_response(id, code, message)
        { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => message } }
      end

      def notification(method, params)
        { "jsonrpc" => "2.0", "method" => method, "params" => params }
      end
    end
  end
end
