# frozen_string_literal: true

require_relative "test_helper"

# Boot-time cross-component verification: the deferred analogue of HEEx's
# compile-time call-site checks.
class VerifyTest < Minitest::Test
  # Plain (non-HER) module for remote-call checks.
  module Helpers
    def self.existing(assigns = {})
      Her.raw("<i>#{assigns[:x]}</i>")
    end
  end

  # HER module with a contract, for remote contract checks.
  module RemoteUI
    extend Her::Component
    component :chip do
      attr :text, required: true
      template "<span>{@text}</span>"
    end
  end

  def buttoned(&extra)
    component_module do
      component :button do
        attr :label, required: true
        attr :class, default: "btn"
        template "<button class={@class}>{@label}</button>"
      end
      module_eval(&extra) if extra
    end
  end

  # -- clean cases that justify the deferred design ---------------------------

  def test_clean_module_passes
    mod = buttoned do
      component :bar do
        template %(<.button label="x" class="big"/>)
      end
    end
    assert_empty Her.verify(mod)
    assert Her.verify!(mod)
  end

  def test_callee_defined_later_in_module_is_fine
    mod = component_module do
      component :bar do
        template %(<.button label="x"/>)
      end
      component :button do
        attr :label, required: true
        template "<b>{@label}</b>"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_recursive_component_is_fine
    mod = component_module do
      component :tree do
        attr :kids
        template "{if @kids.any?}<.tree kids={[]}/>{end}"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_hand_written_module_function_callee_passes_existence_only
    mod = component_module do
      def self.legacy(assigns = {})
        Her.raw("<i>#{assigns[:x]}</i>")
      end
      component :bar do
        attr :y
        attr :z
        template "<.legacy x={@y} anything_goes={@z}/>"
      end
    end
    assert_empty Her.verify(mod)
  end

  # -- undefined callees -------------------------------------------------------

  def test_undefined_local_component_with_did_you_mean
    mod = buttoned do
      component :bar do
        template %(<.buttom label="x"/>)
      end
    end
    issues = Her.verify(mod)
    assert_equal 1, issues.size
    issue = issues.first
    assert_equal :undefined_component, issue.type
    assert issue.error?
    assert_match(/calls <\.buttom\/>, which is not defined/, issue.message)
    assert_match(%r{did you mean <\.button/>\?}, issue.message)
  end

  def test_verify_bang_raises_aggregated_error
    mod = buttoned do
      component :bar do
        template "<.missing_a/><.missing_b/>"
      end
    end
    error = assert_raises(Her::VerifyError) { Her.verify!(mod) }
    assert_match(/2 component verification failures/, error.message)
    assert_match(/missing_a/, error.message)
    assert_match(/missing_b/, error.message)
    assert_equal 2, error.issues.size
  end

  def test_issue_points_at_template_file_and_line
    decl_line = nil
    mod = component_module do
      component :bar do
        decl_line = __LINE__ + 1
        template "<.missing/>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal __FILE__, issue.file
    assert_equal decl_line, issue.line
    assert_match(/\.bar\z/, issue.component)
  end

  # -- remote callees ------------------------------------------------------------

  def test_unresolvable_remote_module
    mod = component_module do
      component :bar do
        template "<Definitely::Not::Here.thing/>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :unresolvable_module, issue.type
    assert_match(/cannot resolve Definitely::Not::Here/, issue.message)
  end

  def test_remote_plain_module_function_resolves
    mod = component_module do
      component :bar do
        attr :y
        template "<VerifyTest::Helpers.existing x={@y}/>"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_remote_undefined_function_with_suggestion
    mod = component_module do
      component :bar do
        template %(<VerifyTest::RemoteUI.chap text="x"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :undefined_remote_function, issue.type
    assert_match(/does not define `chap`/, issue.message)
    assert_match(%r{did you mean <VerifyTest::RemoteUI\.chip/>\?}, issue.message)
  end

  def test_remote_contract_is_checked
    mod = component_module do
      component :bar do
        template "<VerifyTest::RemoteUI.chip/>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :missing_required_attr, issue.type
    assert_match(/without its required attr :text/, issue.message)
  end

  # -- attr contract checks --------------------------------------------------------

  def test_missing_required_attr_is_an_error
    mod = buttoned do
      component :bar do
        template %(<.button class="x"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :missing_required_attr, issue.type
    assert issue.error?
    assert_match(/calls <\.button\/> without its required attr :label/, issue.message)
  end

  def test_splat_suppresses_required_attr_check
    mod = buttoned do
      component :bar do
        attr :opts
        template "<.button {@opts}/>"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_undeclared_attr_warns_by_default
    mod = buttoned do
      component :bar do
        template %(<.button label="x" clas="y"/>)
      end
    end
    issues = Her.verify(mod)
    assert_equal 1, issues.size
    issue = issues.first
    assert_equal :undeclared_attr, issue.type
    assert_equal :warn, issue.severity
    refute issue.error?
    assert_match(/passes attr `clas`/, issue.message)
    assert_match(/declared: :label, :class/, issue.message)

    out, err = capture_io { assert Her.verify!(mod) } # warns, does not raise
    assert_empty out
    assert_match(/\[warn\].*passes attr `clas`/, err)
  end

  def test_undeclared_attr_severity_is_configurable
    mod = buttoned do
      component :bar do
        template %(<.button label="x" clas="y"/>)
      end
    end
    assert Her.verify(mod, undeclared_attrs: :error).first.error?
    assert_empty Her.verify(mod, undeclared_attrs: :ignore)
    assert_raises(Her::VerifyError) { Her.verify!(mod, undeclared_attrs: :error) }
  end

  def test_global_attr_callee_accepts_arbitrary_attrs_cleanly
    mod = component_module do
      component :freeform do
        attr :rest, :global
        template "<p>{@rest.inspect}</p>"
      end
      component :bar do
        template %(<.freeform whatever="x"/>)
      end
    end
    assert_empty Her.verify(mod)
  end

  # -- literal type/values checks ------------------------------------------------

  def typed_mod(&caller_block)
    component_module do
      component :badge do
        attr :count, :integer, required: true
        attr :kind, :string, values: %w[low high]
        attr :on, :boolean, default: false
        template "<b>{@count}{@kind}{@on}</b>"
      end
      module_eval(&caller_block)
    end
  end

  def test_literal_string_to_integer_attr_is_an_error
    mod = typed_mod do
      component :bar do
        template %(<.badge count="5"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :attr_type, issue.type
    assert issue.error?
    assert_match(/passes "5" to attr :count of <\.badge\/>, declared :integer/, issue.message)
  end

  def test_bare_attr_to_non_boolean_is_an_error
    mod = typed_mod do
      component :bar do
        attr :n
        template "<.badge count={@n} kind/>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :attr_type, issue.type
    assert_match(/passes true to attr :kind/, issue.message)
  end

  def test_interpolated_attr_is_type_checked_as_string
    mod = typed_mod do
      component :bar do
        attr :n
        template %(<.badge count="n-{@n}"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :attr_type, issue.type
    assert_match(/passes an interpolated String to attr :count/, issue.message)
  end

  def test_interpolated_attr_satisfies_string_type
    mod = typed_mod do
      component :bar do
        attr :n
        attr :x
        template %(<.badge count={@n} kind="k-{@x}"/>)
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_literal_outside_values_is_an_error
    mod = typed_mod do
      component :bar do
        attr :n
        template %(<.badge count={@n} kind="High"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :attr_value, issue.type
    assert_match(/passes "High" to attr :kind .* allowed values: "low", "high"/, issue.message)
  end

  def test_literal_within_values_and_dynamic_holes_are_clean
    mod = typed_mod do
      component :bar do
        attr :n
        attr :k
        template %(<.badge count={@n} kind="low"/><.badge count={@n} kind={@k}/>)
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_bare_attr_to_boolean_is_clean
    mod = typed_mod do
      component :bar do
        attr :n
        template "<.badge count={@n} on/>"
      end
    end
    assert_empty Her.verify(mod)
  end

  # -- :global interplay ------------------------------------------------------------

  def test_global_attr_silences_undeclared_warnings
    mod = component_module do
      component :button do
        attr :label, :string, required: true
        attr :rest, :global
        template "<button {@rest}>{@label}</button>"
      end
      component :bar do
        template %(<.button label="x" data-id="1" hidden/>)
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_literal_to_global_attr_is_a_type_error
    mod = component_module do
      component :button do
        attr :rest, :global
        template "<button {@rest}></button>"
      end
      component :bar do
        template %(<.button rest="oops"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :attr_type, issue.type
    assert_match(/declared :global/, issue.message)
  end

  # -- slot checks --------------------------------------------------------------------

  def test_unknown_named_slot_is_an_error
    mod = component_module do
      component :plain do
        template "<p>no slots here</p>"
      end
      component :bar do
        template "<.plain><:side>s</:side></.plain>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :unknown_slot, issue.type
    assert_match(/passes slot <:side>/, issue.message)
    assert_match(/never renders it/, issue.message)
  end

  def test_children_to_slotless_callee_is_flagged
    mod = component_module do
      component :plain do
        template "<p>no slots here</p>"
      end
      component :bar do
        template "<.plain>dropped content</.plain>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :unknown_slot, issue.type
    assert_match(/passes children/, issue.message)
    assert_match(/content would be dropped/, issue.message)
  end

  def test_slots_known_via_tag_render_function_form_and_predicate
    mod = component_module do
      component :layout do
        template "<aside><:side/></aside>{render_slot(:footer)}{if slot?(:hint)}?{end}{render_slot(:inner)}"
      end
      component :bar do
        template "<.layout><:side>s</:side><:footer>f</:footer><:hint>h</:hint>inner</.layout>"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_dynamic_render_slot_suppresses_slot_checks
    mod = component_module do
      component :dyn do
        template "{render_slot(assigns[:which])}"
      end
      component :bar do
        template "<.dyn><:anything>x</:anything></.dyn>"
      end
    end
    assert_empty Her.verify(mod)
  end

  def test_bare_render_slot_means_inner
    mod = component_module do
      component :box do
        template "{render_slot || raw(\"none\")}"
      end
      component :bar do
        template "<.box>content</.box>"
      end
    end
    assert_empty Her.verify(mod)
  end

  # -- module tracking -------------------------------------------------------------------

  def test_default_verification_covers_all_tracked_modules
    broken = component_module do
      component :bar do
        template "<.definitely_not_defined_anywhere/>"
      end
    end
    label = Her.module_label(broken)
    issues = Her.verify # no args: every module that extended Her::Component
    assert(issues.any? { |i| i.component == "#{label}.bar" && i.type == :undefined_component })
    assert_includes Her.component_modules, broken
  end

  def test_verifying_a_non_component_module_is_an_argument_error
    error = assert_raises(ArgumentError) { Her.verify(String) }
    assert_match(/does not extend Her::Component/, error.message)
  end
end
