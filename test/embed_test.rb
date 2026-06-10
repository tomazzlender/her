# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Phase 4 (§3b–§3d): embed_templates, sibling files, and the collision rule.
class EmbedTest < Minitest::Test
  def test_embed_templates_defines_one_function_per_file
    mod = component_module do
      embed_templates "fixtures/components/*.html.her"
    end
    assert_respond_to mod, :button
    assert_respond_to mod, :user_card
    assert_equal %(<button class="x">Hi</button>\n), render(mod.button(class: "x", label: "Hi"))
    assert_equal %(<div class="user-card"><h3>Ana</h3><p>a@b.c</p></div>\n),
                 render(mod.user_card(name: "Ana", email: "a@b.c"))
  end

  def test_glob_resolves_relative_to_caller_dir
    # component_module evals the block from this file, so the glob above is
    # already exercising caller-relative resolution; double-check dir: too.
    mod = component_module {}
    mod.embed_templates "*.html.her", dir: fixtures_path("components")
    assert_respond_to mod, :button
  end

  def test_embedded_templates_are_contract_free
    mod = component_module do
      embed_templates "fixtures/components/*.html.her"
    end
    error = assert_raises(Her::MissingAssign) { mod.button(class: "x") }
    assert_match(/missing assign :label/, error.message)
    assert_match(/assigns given: :class/, error.message)
  end

  def test_missing_assign_never_renders_nil
    mod = component_module do
      embed_templates "fixtures/components/*.html.her"
    end
    assert_raises(Her::MissingAssign) { mod.user_card(name: "Ana") }
  end

  def test_sibling_file_resolution
    require fixtures_path("sibling", "ui")
    assert_equal %(<button class="fancy">Go</button>\n), render(SiblingUI.fancy_button(label: "Go"))
    assert_raises(Her::MissingAttr) { SiblingUI.fancy_button }
  end

  def test_explicit_component_wins_when_defined_first
    mod = component_module do
      component :greeting do
        template "<p>from component</p>"
      end
      embed_templates "fixtures/override/*.html.her"
    end
    assert_equal "<p>from component</p>", render(mod.greeting)
  end

  def test_explicit_component_wins_when_defined_second
    mod = component_module do
      embed_templates "fixtures/override/*.html.her"
      component :greeting do
        template "<p>from component</p>"
      end
    end
    assert_equal "<p>from component</p>", render(mod.greeting)
  end

  def test_collision_with_existing_method_is_refused
    error = assert_raises(Her::CompileError) do
      component_module do
        embed_templates "fixtures/collide/*.html.her" # name.html.her vs Module#name
      end
    end
    assert_match(/already responds to `name`/, error.message)
    assert_match(/rename/, error.message)
  end

  def test_empty_glob_warns
    _, err = capture_io do
      component_module do
        embed_templates "fixtures/no_such_dir/*.html.her"
      end
    end
    assert_match(/matched no files/, err)
  end

  def test_keyword_filename_is_refused
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "end.html.her"), "<p>x</p>")
      error = assert_raises(Her::CompileError) do
        mod = component_module {}
        mod.embed_templates("*.html.her", dir: dir)
      end
      assert_match(/not a valid component name/, error.message)
    end
  end

  def test_embedded_components_compose
    mod = component_module do
      embed_templates "fixtures/components/*.html.her"
      component :toolbar do
        template %(<nav><.button class="t" label={@label}/></nav>)
      end
    end
    assert_equal %(<nav><button class="t">Press</button>\n</nav>), render(mod.toolbar(label: "Press"))
  end
end
