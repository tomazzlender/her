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
    assert_match(/\.button: missing required attribute :label\z/, error.message)
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

  def test_component_without_attrs_is_contract_free
    mod = component_module do
      component :free do
        template "<p>{@anything}</p>"
      end
    end
    assert_equal "<p>1</p>", render(mod.free(anything: 1))
    assert_raises(Her::MissingAssign) { mod.free }
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
end
