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
  # component tag, <: slots), hover, and go-to-definition.
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
        id = message["id"]
        params = message["params"] || {}

        case method
        when "initialize"        then [response(id, initialize_result)]
        when "initialized"       then load_error_messages
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
        when "textDocument/completion" then [response(id, completion(params))]
        when "textDocument/hover"      then [response(id, hover(params))]
        when "textDocument/definition" then [response(id, definition(params))]
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
            "definitionProvider" => true
          },
          "serverInfo" => { "name" => "her-lsp", "version" => Her::VERSION }
        }
      end

      def load_error_messages
        return [] unless @load_error
        [notification("window/showMessage", "type" => 1, "message" => @load_error)]
      end

      # -- diagnostics ----------------------------------------------------------

      def publish_diagnostics(uri, verify:)
        path = LSP.uri_to_path(uri)
        text = @documents[uri].to_s
        diagnostics = []
        entry = registry_entry_for(path)

        begin
          if entry
            mod_meta = entry[2]
            # Dry-run the real contract against a scratch module so unsaved
            # buffer text never clobbers the app's compiled method.
            scratch = Module.new { extend Her::Component }
            Compiler.define(scratch, entry[1], text,
                            origin: { file: path, first_line: 1 },
                            attrs: mod_meta[:attrs], kind: mod_meta[:kind],
                            strict_html: mod_meta[:strict_html])
          else
            tokens = Tokenizer.new(text, file: path).tokenize
            Parser.new(tokens, file: path, source: text).parse
          end
        rescue ParseError => e
          diagnostics << diagnostic(e.line, e.column, e.message, 1)
        rescue CompileError => e
          line = e.message[/\(#{Regexp.escape(path)}:(\d+)\)/, 1]&.to_i || 1
          diagnostics << diagnostic(line, 1, e.message, 1)
        end

        # Verify findings reflect the *registry* — the last-saved state —
        # while the parse/compile pass above tracks the live buffer. didSave
        # reloads the template first, so the two converge on every save.
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

      # -- completion -----------------------------------------------------------

      def completion(params)
        uri = params.dig("textDocument", "uri")
        text = @documents[uri] or return []
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
          detail = +""
          detail << "required " if spec[:required]
          detail << Her.type_label(spec[:type])
          detail << ", default: #{spec[:default].inspect}" if spec.key?(:default)
          detail << ", values: #{spec[:values].map(&:inspect).join('|')}" if spec[:values]
          {
            "label" => attr_name.to_s,
            "kind" => 10, # Property
            "detail" => detail,
            "insertText" => "#{attr_name}="
          }
        end
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
        if meta[:attrs]
          out << "\nAttrs:\n"
          meta[:attrs].each do |attr_name, spec|
            line = "- `#{attr_name}` #{Her.type_label(spec[:type])}"
            line << ", required" if spec[:required]
            line << ", default: `#{spec[:default].inspect}`" if spec.key?(:default)
            line << ", values: #{spec[:values].map(&:inspect).join(', ')}" if spec[:values]
            out << line << "\n"
          end
        else
          out << "\nContract-free (assigns inferred from the template body).\n"
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
            return [mod, name, meta] if meta[:template_path] == path
          end
        end
        nil
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
        return " (contract-free)" unless meta[:attrs]
        required = meta[:attrs].select { |_, spec| spec[:required] }.keys
        required.any? ? " (requires #{required.map { |r| ":#{r}" }.join(', ')})" : ""
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
