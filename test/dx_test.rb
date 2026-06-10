# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Developer-experience features: statement-line trimming, template
# reloading, and debug annotations.
class DxTest < Minitest::Test
  # -- statement-line whitespace trimming ---------------------------------------

  def test_loop_lines_leave_no_blank_output
    mod = component_module do
      component :list do
        template <<~'HER'
          <ul>
            {@items.each do |item|}
              <li>{item}</li>
            {end}
          </ul>
        HER
      end
    end
    assert_equal "<ul>\n    <li>a</li>\n    <li>b</li>\n</ul>\n", render(mod.list(items: %w[a b]))
  end

  def test_conditional_lines_trimmed_including_template_start
    mod = component_module do
      component :badge do
        template <<~'HER'
          {if @on}
            <b>on</b>
          {else}
            <i>off</i>
          {end}
        HER
      end
    end
    assert_equal "  <b>on</b>\n", render(mod.badge(on: true))
    assert_equal "  <i>off</i>\n", render(mod.badge(on: false))
  end

  def test_statement_sharing_a_line_with_content_is_left_alone
    mod = component_module do
      component :inline do
        template "<p>{if @on}YES{end}</p>\n"
      end
    end
    assert_equal "<p>YES</p>\n", render(mod.inline(on: true))
  end

  def test_expression_holes_are_never_trimmed
    mod = component_module do
      component :keeps do
        template "<pre>\n  {@x}\n</pre>"
      end
    end
    assert_equal "<pre>\n  1\n</pre>", render(mod.keeps(x: 1))
  end

  def test_line_mapping_survives_trimming
    decl_line = nil
    mod = component_module do
      component :mapped do
        decl_line = __LINE__ + 1
        template "{if @x}\n{end}\n<p>{no_such_helper_here}</p>"
      end
    end
    error = assert_raises(NameError) { mod.mapped(x: 1) }
    # template line 3 == decl_line + 2
    assert_match(/#{Regexp.escape(__FILE__)}:#{decl_line + 2}/, error.backtrace.first)
  end

  # -- Her.reload_templates! ------------------------------------------------------

  def test_reload_recompiles_file_templates
    Dir.mktmpdir do |dir|
      path = File.join(dir, "greet.html.her")
      File.write(path, "<p>v1 {@name}</p>")
      mod = component_module {}
      mod.embed_templates("*.html.her", dir: dir)
      assert_equal "<p>v1 Ana</p>", render(mod.greet(name: "Ana"))

      File.write(path, "<h1>v2 {@name}!</h1>")
      assert_equal 1, Her.reload_templates!(mod)
      assert_equal "<h1>v2 Ana!</h1>", render(mod.greet(name: "Ana"))
    end
  end

  def test_reload_keeps_attr_declarations_for_sibling_components
    Dir.mktmpdir do |dir|
      path = File.join(dir, "tag.html.her")
      File.write(path, "<i>{@label}</i>")
      mod = component_module {}
      mod.component :tag, dir: dir do
        attr :label, :string, required: true
      end
      assert_equal "<i>x</i>", render(mod.tag(label: "x"))

      File.write(path, "<b>{@label}</b>")
      Her.reload_templates!(mod)
      assert_equal "<b>x</b>", render(mod.tag(label: "x"))
      assert_raises(Her::MissingAttr) { mod.tag } # contract survived the reload
    end
  end

  def test_reload_skips_inline_templates
    mod = component_module do
      component :inline do
        template "<p>inline</p>"
      end
    end
    assert_equal 0, Her.reload_templates!(mod)
    assert_equal "<p>inline</p>", render(mod.inline)
  end

  def test_failed_reload_keeps_the_old_method
    Dir.mktmpdir do |dir|
      path = File.join(dir, "frag.html.her")
      File.write(path, "<p>ok</p>")
      mod = component_module {}
      mod.embed_templates("*.html.her", dir: dir)

      File.write(path, "<p>broken")
      assert_raises(Her::ParseError) { Her.reload_templates!(mod) }
      assert_equal "<p>ok</p>", render(mod.frag) # old compilation still in place
    end
  end

  # -- debug annotations ------------------------------------------------------------

  def test_debug_annotations_wrap_output_with_origin
    Her.debug_annotations = true
    mod = component_module do
      component :tagged do
        template "<p>x</p>"
      end
    end
    html = render(mod.tagged)
    assert_match(%r{\A<!-- <#{Regexp.escape(Her.module_label(mod))}\.tagged> .+:\d+ -->}, html)
    assert html.end_with?("<!-- </#{Her.module_label(mod)}.tagged> -->")
    assert_includes html, "<p>x</p>"
  ensure
    Her.debug_annotations = false
  end

  def test_annotations_off_by_default
    mod = component_module do
      component :plain do
        template "<p>x</p>"
      end
    end
    assert_equal "<p>x</p>", render(mod.plain)
  end
end
