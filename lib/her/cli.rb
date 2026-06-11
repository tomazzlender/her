# frozen_string_literal: true

module Her
  # The `her` command-line tool. Returns exit codes rather than exiting, so
  # it is testable; the executable wraps it in Process.exit.
  module CLI
    USAGE = <<~TEXT
      Usage: her COMMAND [options]

      Commands:
        format [--check] FILE|DIR .. format .her templates in place
                                     (--check: report only, exit 1 on diffs)
        check -r FILE [-r FILE ...]  load the app and run Her.verify!
        lsp [-r FILE ...]            run the language server on stdio
        source -r FILE MOD.NAME      print the Ruby generated for a component
        version                      print the HER version
    TEXT

    module_function

    def run(argv)
      case argv.first
      when "format"  then format_files(argv.drop(1))
      when "check"   then check(argv.drop(1))
      when "lsp"     then lsp(argv.drop(1))
      when "source"  then source(argv.drop(1))
      when "version" then puts(Her::VERSION) || 0
      else
        warn USAGE
        argv.empty? || argv.first == "help" ? 0 : 2
      end
    end

    def format_files(args)
      check = args.delete("--check") ? true : false
      paths = args.flat_map do |arg|
        if File.directory?(arg)
          Dir.glob(File.join(arg, "**", "*.her")).sort
        else
          [arg]
        end
      end
      if paths.empty?
        warn "her format: no files given\n\n#{USAGE}"
        return 2
      end

      changed = []
      failed = false
      paths.each do |path|
        if Formatter.format_file(path, check: check)
          changed << path
          puts(check ? "would reformat #{path}" : "reformatted #{path}")
        end
      rescue ParseError => e
        warn "her format: #{e.message}"
        failed = true
      rescue Errno::ENOENT
        warn "her format: no such file: #{path}"
        failed = true
      end
      return 2 if failed
      check && changed.any? ? 1 : 0
    end

    def check(args)
      requires = extract_requires(args)
      if requires.empty?
        warn "her check: pass your app entry point with -r FILE\n\n#{USAGE}"
        return 2
      end
      load_requires(requires)
      Her.verify!
      modules = Her.component_modules.size
      components = Her.component_modules.sum { |m| m.__her_registry.size }
      puts "ok: #{components} component(s) across #{modules} module(s) verified"
      0
    rescue VerifyError => e
      warn e.message
      1
    end

    def lsp(args)
      requires = extract_requires(args)
      require_relative "lsp"
      LSP::Server.new(requires: requires).run
      0
    end

    def source(args)
      requires = extract_requires(args)
      target = args.first
      unless target&.include?(".")
        warn "her source: expected MOD.NAME (e.g. UI.button)\n\n#{USAGE}"
        return 2
      end
      load_requires(requires)
      mod_path, _, name = target.rpartition(".")
      mod = Object.const_get(mod_path)
      src = Her.generated_source(mod, name)
      if src
        puts src
        0
      else
        warn "her source: #{mod_path} has no component #{name.inspect}"
        1
      end
    end

    def extract_requires(args)
      requires = []
      while (i = args.index("-r") || args.index("--require"))
        args.delete_at(i)
        requires << args.delete_at(i)
      end
      requires.compact
    end

    def load_requires(requires)
      requires.each { |path| require File.expand_path(path) }
    end
  end
end
