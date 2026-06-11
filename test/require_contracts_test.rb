# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Contracts are mandatory: every component declares its attrs (block or
# frontmatter); a template that declares nothing compiles with an EMPTY
# contract, so each @x reference is a precise load error.
class RequireContractsTest < Minitest::Test
  def test_contract_less_template_referencing_assigns_fails_at_load
    error = assert_raises(Her::CompileError) do
      component_module do
        component :naked do
          template "<p>{@x}</p>"
        end
      end
    end
    assert_match(/references undeclared attr @x/, error.message)
    assert_match(/declares no attrs/, error.message)
    assert_match(/component block or in template frontmatter/, error.message)
    assert_match(/assigns\[:x\]/, error.message) # the dynamic escape hatch is named
  end

  def test_static_templates_remain_legal
    mod = component_module do
      component :static do
        template "<hr>"
      end
    end
    assert_equal "<hr>", render(mod.static)
  end

  def test_block_attrs_satisfy_the_contract
    mod = component_module do
      component :ok do
        attr :x, :integer, required: true
        template "<p>{@x}</p>"
      end
    end
    assert_equal "<p>1</p>", render(mod.ok(x: 1))
  end

  def test_frontmatter_satisfies_the_contract
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "chip.html.her"),
                 "<%# attr :text, :string, required: true %>\n<i>{@text}</i>\n")
      File.write(File.join(dir, "bare.html.her"), "<p>{@x}</p>\n")
      mod = component_module {}
      error = assert_raises(Her::CompileError) { mod.embed_templates("*.html.her", dir: dir) }
      assert_match(/bare\.html\.her/, error.message)

      mod2 = component_module {}
      mod2.embed_templates("chip.html.her", dir: dir)
      assert_equal "<i>x</i>\n", render(mod2.chip(text: "x"))
    end
  end

  def test_assigns_bracket_access_remains_the_dynamic_escape_hatch
    mod = component_module do
      component :dynamic do
        template "<p>{assigns[:whatever]}</p>"
      end
    end
    assert_equal "<p>1</p>", render(mod.dynamic(whatever: 1))
  end

  def test_global_attr_is_the_passthrough_pattern
    mod = component_module do
      component :proxy do
        attr :rest, :global
        template "<div {@rest}>x</div>"
      end
    end
    assert_equal %(<div id="a" hidden>x</div>), render(mod.proxy(id: "a", hidden: true))
  end

  def test_reload_does_not_conflict_when_frontmatter_is_added_later
    Dir.mktmpdir do |dir|
      path = File.join(dir, "card.html.her")
      File.write(path, "<p>static</p>\n")
      mod = component_module {}
      mod.embed_templates("*.html.her", dir: dir)
      assert_equal "<p>static</p>\n", render(mod.card)

      # the file gains a contract; reload must re-derive, not conflict
      File.write(path, "<%# attr :title, :string, required: true %>\n<p>{@title}</p>\n")
      Her.reload_templates!(mod)
      assert_equal "<p>t</p>\n", render(mod.card(title: "t"))
      assert_raises(Her::MissingAttr) { mod.card }
    end
  end

  def test_empty_contract_components_get_verify_undeclared_warnings
    mod = component_module do
      component :static do
        template "<hr>"
      end
      component :caller do
        template %q(<.static stray="x"/>)
      end
    end
    issue = Her.verify(mod).first
    assert_equal :undeclared_attr, issue.type
    assert_match(/passes attr `stray`/, issue.message)
  end
end
