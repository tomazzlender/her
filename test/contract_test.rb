# frozen_string_literal: true

require_relative "test_helper"

# Phase 3 (§3c, §7.1): the declared-attr contract tier.
class ContractTest < Minitest::Test
  def test_missing_required_attr_raises_with_component_and_attr_name
    mod = component_module do
      component :button do
        attr :label, required: true
        template "<button>{@label}</button>"
      end
    end
    error = assert_raises(Her::MissingAttr) { mod.button }
    assert_match(/\.button: missing required attribute :label \(assigns given: none\)\z/, error.message)
    assert_equal :label, error.attr
  end

  def test_default_applied_and_overridable
    mod = component_module do
      component :button do
        attr :class, default: "btn"
        template "<button class={@class}></button>"
      end
    end
    assert_equal %(<button class="btn"></button>), render(mod.button)
    assert_equal %(<button class="big"></button>), render(mod.button(class: "big"))
  end

  def test_declared_optional_attr_without_default_is_nil
    mod = component_module do
      component :button do
        attr :label, required: true
        attr :title
        template "<button title={@title}>{@label}</button>"
      end
    end
    assert_equal "<button>x</button>", render(mod.button(label: "x"))
  end

  def test_nil_default_can_be_branched_on
    mod = component_module do
      component :badge do
        attr :level, default: nil
        template "{if @level}<b>{@level}</b>{else}<i>none</i>{end}"
      end
    end
    assert_equal "<i>none</i>", render(mod.badge)
    assert_equal "<b>vip</b>", render(mod.badge(level: "vip"))
  end

  def test_undeclared_attr_reference_fails_at_definition_time
    error = assert_raises(Her::CompileError) do
      component_module do
        component :button do
          attr :label, required: true
          template "<button>{@labl}</button>"
        end
      end
    end
    assert_match(/references undeclared attr @labl/, error.message)
    assert_match(/attr :labl/, error.message)
    assert_match(/declared: :label/, error.message)
  end

  def test_extra_assigns_are_allowed_through
    mod = component_module do
      component :button do
        attr :label, required: true
        template "<button>{@label}</button>"
      end
    end
    assert_equal "<button>x</button>", render(mod.button(label: "x", analytics_id: "ignored"))
  end

  def test_required_with_default_is_rejected
    error = assert_raises(Her::CompileError) do
      component_module do
        component :button do
          attr :label, required: true, default: "x"
          template "<button>{@label}</button>"
        end
      end
    end
    assert_match(/cannot be both required and have a default/, error.message)
  end

  def test_duplicate_attr_declaration_rejected
    error = assert_raises(Her::CompileError) do
      component_module do
        component :button do
          attr :label
          attr :label
          template "<button>{@label}</button>"
        end
      end
    end
    assert_match(/declared twice/, error.message)
  end

  def test_component_without_attrs_may_not_reference_assigns
    error = assert_raises(Her::CompileError) do
      component_module do
        component :free do
          template "<p>{@anything}</p>"
        end
      end
    end
    assert_match(/declares no attrs/, error.message)
    assert_match(/assigns\[:anything\]/, error.message)
  end

  def test_default_values_are_frozen
    mod = component_module do
      component :tag do
        attr :items, default: []
        template "<p>{@items.size}</p>"
      end
    end
    assert_equal "<p>0</p>", render(mod.tag)
    assert mod.__her_registry[:tag][:defaults][:items].frozen?
  end

  def test_invalid_component_names_rejected
    assert_raises(Her::CompileError) { component_module { component :"bad-name" } }
    assert_raises(Her::CompileError) { component_module { component :end } }
    assert_raises(Her::CompileError) { component_module { component :Upper } }
  end

  def test_missing_template_and_sibling_file_explains_path
    error = assert_raises(Her::CompileError) do
      component_module { component :nowhere_to_be_found }
    end
    assert_match(/no inline template and no sibling/, error.message)
    assert_match(/nowhere_to_be_found\.html\.her/, error.message)
  end

  # -- attr types ---------------------------------------------------------------

  def typed
    @typed ||= component_module do
      component :badge do
        attr :count, :integer, required: true
        attr :label, :string, default: "items"
        attr :level, :string, values: %w[low high]
        attr :active, :boolean, default: false
        attr :at, Time
        template "<b>{@count} {@label} {@level} {@active} {@at.class}</b>"
      end
    end
  end

  def test_valid_typed_render
    out = render(typed.badge(count: 3, level: "low", at: Time.at(0)))
    assert_equal "<b>3 items low false Time</b>", out
  end

  def test_wrong_type_raises_invalid_attr
    error = assert_raises(Her::InvalidAttr) { typed.badge(count: "3") }
    assert_match(/\.badge: attribute :count expected :integer, got String: "3"/, error.message)
    assert_equal :count, error.attr
  end

  def test_module_type
    assert_raises(Her::InvalidAttr) { typed.badge(count: 1, at: "now") }
  end

  def test_boolean_type
    assert_raises(Her::InvalidAttr) { typed.badge(count: 1, active: 1) }
    assert_equal "<b>1 items  true NilClass</b>", render(typed.badge(count: 1, active: true))
  end

  def test_values_enforced_at_render
    error = assert_raises(Her::InvalidAttr) { typed.badge(count: 1, level: "High") }
    assert_match(/attribute :level got "High" — allowed values: "low", "high"/, error.message)
  end

  def test_nil_is_exempt_from_type_and_values_checks
    assert_equal "<b>1 items  false NilClass</b>", render(typed.badge(count: 1, level: nil, at: nil))
  end

  def test_false_is_exempt_except_for_boolean
    # the `attr={@x && "v"}` omit idiom: false means "absent"
    assert_equal "<b>1 items false false NilClass</b>", render(typed.badge(count: 1, level: false))
  end

  def test_untyped_attrs_accept_anything
    mod = component_module do
      component :loose do
        attr :thing
        template "<p>{@thing.inspect}</p>"
      end
    end
    assert_equal "<p>[1, 2]</p>", render(mod.loose(thing: [1, 2]))
  end

  # -- declaration-time validation -------------------------------------------------

  def test_unknown_type_rejected
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, :strnig } }
    end
    assert_match(/unknown type :strnig/, error.message)
  end

  def test_default_must_satisfy_type
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, :integer, default: "1" } }
    end
    assert_match(/default "1" is not :integer/, error.message)
  end

  def test_default_must_be_among_values
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, :string, values: %w[a b], default: "c" } }
    end
    assert_match(/default "c" is not among values/, error.message)
  end

  def test_values_must_satisfy_type
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, :integer, values: [1, "2"] } }
    end
    assert_match(/values: contains "2", which is not :integer/, error.message)
  end

  def test_empty_values_rejected
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, values: [] } }
    end
    assert_match(/non-empty Enumerable/, error.message)
  end

  # -- :global ------------------------------------------------------------------------

  def globalized
    @globalized ||= component_module do
      component :button do
        attr :label, :string, required: true
        attr :rest, :global, default: { class: "btn" }
        template "<button {@rest}>{@label}</button>"
      end
    end
  end

  def test_global_collects_undeclared_assigns
    out = render(globalized.button(label: "Go", "data-id": "7", hidden: true))
    assert_equal %(<button class="btn" data-id="7" hidden>Go</button>), out
  end

  def test_global_default_is_overridable_base
    assert_equal %(<button class="btn">Go</button>), render(globalized.button(label: "Go"))
    assert_equal %(<button class="big">Go</button>), render(globalized.button(label: "Go", class: "big"))
  end

  def test_global_chains_through_splats
    globalized.component :toolbar do
      template %(<.button label="Save" aria-label="save"/>)
    end
    assert_equal %(<button class="btn" aria-label="save">Save</button>), render(globalized.toolbar)
  end

  def test_global_cannot_be_required_or_have_values_or_repeat
    assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :rest, :global, required: true } }
    end
    assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :rest, :global, values: [1] } }
    end
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :a, :global; attr :b, :global } }
    end
    assert_match(/only one :global attr/, error.message)
  end

  def test_global_default_must_be_a_hash
    error = assert_raises(Her::CompileError) do
      component_module { component(:x) { attr :rest, :global, default: "x" } }
    end
    assert_match(/default "x" is not :global/, error.message)
  end
end
