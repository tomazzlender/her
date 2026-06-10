# frozen_string_literal: true

module Her
  # A single finding from Her.verify. severity is :error or :warn.
  Issue = Struct.new(:severity, :type, :component, :file, :line, :message, keyword_init: true) do
    def error?
      severity == :error
    end

    def to_s
      "#{file}:#{line}: #{component}: #{message}"
    end
  end

  class << self
    # Cross-component call-site verification — the boot-time analogue of
    # Phoenix's compile-time component checks. Ruby has no after-compile
    # hook, so HER records every component call during template compilation
    # and verifies them all here, once the application has finished loading.
    #
    # Checks, with what is statically knowable:
    #   * the callee exists (with did-you-mean suggestions),
    #   * required attrs of contracted callees are provided
    #     (skipped when the call has a {...} splat — it could supply them),
    #   * no attrs are passed that a contracted callee does not declare,
    #   * no slots (or children) are passed that the callee never renders.
    #
    # Call it from the test suite — which makes it effectively compile-time,
    # since CI fails the build — or from an after-boot hook:
    #
    #   def test_components_verify = Her.verify!
    #   config.after_initialize { Her.verify! unless Rails.env.production? }
    #
    # With no arguments every module that extended Her::Component is
    # verified. Warnings are printed; errors raise Her::VerifyError listing
    # every failure at once.
    def verify!(*mods, **options)
      issues = verify(*mods, **options)
      issues.reject(&:error?).each { |issue| warn("Her: [#{issue.severity}] #{issue}") }
      errors = issues.select(&:error?)
      raise VerifyError.new(errors) if errors.any?
      true
    end

    # Like verify!, but returns the Issue list instead of printing/raising.
    # undeclared_attrs: and unknown_slots: accept :error, :warn or :ignore.
    def verify(*mods, undeclared_attrs: :warn, unknown_slots: :error)
      mods = component_modules if mods.empty?
      mods.each do |mod|
        unless mod.respond_to?(:__her_registry)
          raise ArgumentError, "#{mod.inspect} does not extend Her::Component"
        end
      end
      Verifier.new(mods, undeclared_attrs: undeclared_attrs, unknown_slots: unknown_slots).call
    end

    # Every module that extended Her::Component. Held weakly, so anonymous
    # modules can still be garbage collected.
    def component_modules
      component_module_map.keys
    end

    # @api private — called from Her::Component.extended
    def __register_component_module(mod)
      component_module_map[mod] = true
    end

    private

    def component_module_map
      @component_module_map ||= ObjectSpace::WeakMap.new
    end
  end

  # @api private — walks recorded call sites and produces Issues.
  class Verifier
    def initialize(mods, undeclared_attrs:, unknown_slots:)
      @mods = mods
      @severities = {
        undefined_component: :error,
        unresolvable_module: :error,
        undefined_remote_function: :error,
        missing_required_attr: :error,
        undeclared_attr: undeclared_attrs,
        unknown_slot: unknown_slots
      }
      @issues = []
    end

    def call
      @mods.each do |mod|
        mod.__her_registry.each do |caller_name, meta|
          (meta[:calls] || []).each do |call|
            verify_call(mod, caller_name, meta, call)
          end
        end
      end
      @issues
    end

    private

    def verify_call(mod, caller_name, meta, call)
      if call[:kind] == :local
        verify_local(mod, caller_name, meta, call)
      else
        verify_remote(mod, caller_name, meta, call)
      end
    end

    def verify_local(mod, caller_name, meta, call)
      callee_name = call[:name].to_sym
      if (callee_meta = mod.__her_registry[callee_name])
        check_contract(mod, caller_name, meta, call, callee_meta)
      elsif !mod.respond_to?(callee_name)
        add(:undefined_component, mod, caller_name, meta, call,
            "calls #{display(call)}, which is not defined" \
            "#{suggestion(callee_name, mod.__her_registry.keys) { |best| "<.#{best}/>" }}")
      end
      # responds but not HER-compiled: a hand-written module function —
      # existence is all that can be checked.
    end

    def verify_remote(mod, caller_name, meta, call)
      receiver_path, _, func = call[:name].rpartition(".")
      begin
        # Module#const_get falls back to top-level constants, mirroring how
        # the generated code resolves the receiver at render time.
        receiver = mod.const_get(receiver_path)
      rescue NameError
        add(:unresolvable_module, mod, caller_name, meta, call,
            "cannot resolve #{receiver_path} for #{display(call)} " \
            "(constant lookup from #{Her.module_label(mod)})")
        return
      end

      func_sym = func.to_sym
      callee_meta = receiver.respond_to?(:__her_registry) ? receiver.__her_registry[func_sym] : nil
      if callee_meta
        check_contract(mod, caller_name, meta, call, callee_meta)
      elsif !receiver.respond_to?(func_sym)
        candidates = receiver.respond_to?(:__her_registry) ? receiver.__her_registry.keys : []
        add(:undefined_remote_function, mod, caller_name, meta, call,
            "calls #{display(call)}, but #{Her.module_label(receiver)} does not define `#{func}`" \
            "#{suggestion(func_sym, candidates) { |best| "<#{receiver_path}.#{best}/>" }}")
      end
    end

    def check_contract(mod, caller_name, meta, call, callee_meta)
      callee = display(call)
      declared = callee_meta[:attrs]

      if declared
        unless call[:splat]
          declared.each do |attr_name, opts|
            next unless opts[:required]
            next if call[:attrs].include?(attr_name)
            add(:missing_required_attr, mod, caller_name, meta, call,
                "calls #{callee} without its required attr :#{attr_name}")
          end
        end
        call[:attrs].each do |attr_name|
          next if declared.key?(attr_name)
          add(:undeclared_attr, mod, caller_name, meta, call,
              "passes attr `#{attr_name}` to #{callee}, which does not declare it " \
              "(declared: #{declared.keys.map(&:inspect).join(', ')})")
        end
      end

      return if callee_meta[:dynamic_slot_render]

      known = callee_meta[:rendered_slots] || []
      call[:slots].each do |slot_name|
        next if known.include?(slot_name)
        message =
          if slot_name == :inner
            "passes children to #{callee}, which never renders its :inner slot — " \
            "the content would be dropped"
          else
            "passes slot <:#{slot_name}> to #{callee}, which never renders it"
          end
        add(:unknown_slot, mod, caller_name, meta, call, message)
      end
    end

    def add(type, mod, caller_name, meta, call, message)
      severity = @severities.fetch(type)
      return if severity == :ignore
      @issues << Issue.new(
        severity: severity,
        type: type,
        component: "#{Her.module_label(mod)}.#{caller_name}",
        file: meta[:file],
        line: meta[:first_line] + call[:line] - 1,
        message: message
      )
    end

    def display(call)
      call[:kind] == :local ? "<.#{call[:name]}/>" : "<#{call[:name]}/>"
    end

    def suggestion(name, candidates)
      return "" if candidates.empty? || !defined?(DidYouMean::SpellChecker)
      best = DidYouMean::SpellChecker.new(dictionary: candidates.map(&:to_s)).correct(name.to_s).first
      best ? " — did you mean #{yield(best)}?" : ""
    end
  end
end
