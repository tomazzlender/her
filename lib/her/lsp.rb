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
