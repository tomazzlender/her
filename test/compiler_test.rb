# frozen_string_literal: true

require_relative "test_helper"

# Phase 1 + 5: the compiler on plain HTML, holes, and attribute flavors.
class CompilerTest < Minitest::Test
  def define(template_src, name: :demo)
    referenced = template_src.scan(/@([a-z_][a-zA-Z0-9_]*)/).flatten.uniq
    component_module do
      component name do
        referenced.each { |key| attr key.to_sym }
        template template_src
      end
    end
  end

  def test_static_html_passes_through_verbatim
    mod = define(%(<div class="a" id='b'>hello &amp; goodbye</div>))
    assert_equal %(<div class="a" id='b'>hello &amp; goodbye</div>), render(mod.demo)
  end

  def test_text_hole_is_escaped
    mod = define("<p>{@msg}</p>")
    assert_equal "<p>&lt;script&gt;</p>", render(mod.demo(msg: "<script>"))
  end

  def test_hole_with_expression
    mod = define("<p>{@a + @b * 2}</p>")
    assert_equal "<p>7</p>", render(mod.demo(a: 1, b: 3))
  end

  def test_hole_returning_safe_is_not_escaped
    mod = define("<p>{raw(@html)}</p>")
    assert_equal "<p><b>x</b></p>", render(mod.demo(html: "<b>x</b>"))
  end

  def test_assign_sigil_inside_string_interpolation
    mod = define(%q(<p>{"v-#{@x}!"}</p>))
    assert_equal "<p>v-9!</p>", render(mod.demo(x: 9))
  end

  def test_at_inside_string_literal_is_not_rewritten
    mod = define(%q(<p>{"mail: hi@example.com / mention: @here"}</p>))
    assert_equal "<p>mail: hi@example.com / mention: @here</p>", render(mod.demo)
  end

  def test_braces_inside_hole_strings_do_not_close_hole
    mod = define(%q(<p>{@items.join("}")}</p>))
    assert_equal "<p>a}b</p>", render(mod.demo(items: %w[a b]))
  end

  def test_nested_braces_in_hole
    mod = define("<p>{@h.merge({b: 2}).keys.join}</p>")
    assert_equal "<p>ab</p>", render(mod.demo(h: { a: 1 }))
  end

  # -- attributes ------------------------------------------------------------

  def test_whole_hole_attribute_smart_semantics
    mod = define("<p class={@c}>x</p>")
    assert_equal %(<p class="big">x</p>), render(mod.demo(c: "big"))
    assert_equal "<p>x</p>", render(mod.demo(c: nil))
    assert_equal "<p>x</p>", render(mod.demo(c: false))
    assert_equal "<p class>x</p>", render(mod.demo(c: true))
    assert_equal %(<p class="a&quot;b">x</p>), render(mod.demo(c: 'a"b'))
  end

  def test_partial_attribute_interpolation
    mod = define(%(<p class="btn btn-{@kind} x">y</p>))
    assert_equal %(<p class="btn btn-warn x">y</p>), render(mod.demo(kind: "warn"))
  end

  def test_partial_interpolation_in_single_quotes
    mod = define(%(<p class='a-{@k}'>y</p>))
    assert_equal %(<p class='a-1'>y</p>), render(mod.demo(k: 1))
  end

  def test_partial_interpolation_escapes_value
    mod = define(%(<p title="hi {@n}">y</p>))
    assert_equal %(<p title="hi &lt;u&gt;">y</p>), render(mod.demo(n: "<u>"))
  end

  def test_bare_boolean_attribute
    mod = define("<input disabled>")
    assert_equal "<input disabled>", render(mod.demo)
  end

  def test_unquoted_attribute_value
    mod = define("<p class=btn>x</p>")
    assert_equal "<p class=btn>x</p>", render(mod.demo)
  end

  def test_splat_attributes
    mod = define("<div {@rest}>x</div>")
    assert_equal %(<div id="a" hidden>x</div>), render(mod.demo(rest: { id: "a", hidden: true, gone: nil }))
    assert_equal "<div>x</div>", render(mod.demo(rest: nil))
  end

  def test_splat_combines_with_literal_attributes
    mod = define(%(<div class="c" {@rest}>x</div>))
    assert_equal %(<div class="c" data-x="1">x</div>), render(mod.demo(rest: { "data-x": 1 }))
  end

  # -- structure ----------------------------------------------------------------

  def test_void_elements_take_no_closing_tag
    mod = define(%(<br><hr/><img src="x.png"><input type="text">done))
    assert_equal %(<br><hr/><img src="x.png"><input type="text">done), render(mod.demo)
  end

  def test_self_closed_nonvoid_expands
    mod = define("<div/>")
    assert_equal "<div></div>", render(mod.demo)
  end

  def test_doctype_passes_through
    mod = define("<!DOCTYPE html><html><body>x</body></html>")
    assert_equal "<!DOCTYPE html><html><body>x</body></html>", render(mod.demo)
  end

  def test_html_comments_pass_through_with_braces_intact
    mod = define("<div><!-- not a {@hole} --></div>")
    assert_equal "<div><!-- not a {@hole} --></div>", render(mod.demo)
  end

  def test_template_comments_are_stripped
    mod = define("<%# internal note %><p>x</p>")
    assert_equal "<p>x</p>", render(mod.demo)
  end

  def test_literal_angle_bracket_in_text
    mod = define("<p>1 < 2 and 3 > 2</p>")
    assert_equal "<p>1 < 2 and 3 > 2</p>", render(mod.demo)
  end

  def test_multiline_text_preserved
    mod = define("<pre>a\n  b\nc</pre>")
    assert_equal "<pre>a\n  b\nc</pre>", render(mod.demo)
  end

  def test_utf8_text
    mod = define("<p>žąčí — {@x} ✓</p>")
    assert_equal "<p>žąčí — š ✓</p>", render(mod.demo(x: "š"))
  end

  def test_svg_camel_case_elements_and_attrs
    mod = define(%(<svg viewBox="0 0 1 1"><linearGradient id="g"/></svg>))
    assert_equal %(<svg viewBox="0 0 1 1"><linearGradient id="g"></linearGradient></svg>), render(mod.demo)
  end

  # -- script/style (§8.3) -------------------------------------------------------

  def test_script_disables_interpolation_by_default
    mod = define("<script>let o = { a: 1 };</script>")
    assert_equal "<script>let o = { a: 1 };</script>", render(mod.demo)
  end

  def test_style_disables_interpolation_by_default
    mod = define("<style>.x { color: red; }</style>")
    assert_equal "<style>.x { color: red; }</style>", render(mod.demo)
  end

  def test_script_her_interpolate_opts_in_and_strips_attribute
    mod = define(%(<script her-interpolate>let n = "{@n}";</script>))
    assert_equal %(<script>let n = "Ana &amp; co";</script>), render(mod.demo(n: "Ana & co"))
  end

  def test_script_attributes_still_dynamic
    mod = define("<script src={@src}></script>")
    assert_equal %(<script src="/app.js"></script>), render(mod.demo(src: "/app.js"))
  end

  def test_her_no_curly_subtree_keeps_braces_literal
    mod = define("<div her-no-curly><code>f = { x: 1 }</code><p>{not a hole}</p></div>")
    assert_equal "<div><code>f = { x: 1 }</code><p>{not a hole}</p></div>", render(mod.demo)
  end

  def test_her_no_curly_ends_with_element
    mod = define("<div her-no-curly>{literal}</div><p>{@x}</p>")
    assert_equal "<div>{literal}</div><p>9</p>", render(mod.demo(x: 9))
  end

  def test_her_no_curly_nested_same_element
    mod = define("<div her-no-curly><div>{a}</div>{b}</div>{@x}")
    assert_equal "<div><div>{a}</div>{b}</div>7", render(mod.demo(x: 7))
  end

  def test_curly_escape_via_entity
    mod = define("<p>&#123;not a hole&#125;</p>")
    assert_equal "<p>&#123;not a hole&#125;</p>", render(mod.demo)
  end

  def test_curly_escape_via_hole
    mod = define(%q(<p>{"{"}x{"}"}</p>))
    assert_equal "<p>{x}</p>", render(mod.demo)
  end

  # -- misc -----------------------------------------------------------------------

  def test_render_is_a_plain_method_returning_safe
    mod = define("<p>x</p>")
    assert_kind_of Her::Safe, mod.demo
    assert_kind_of Her::Safe, mod.demo({})
  end

  def test_assigns_hash_accepts_reserved_word_keys
    mod = define("<p>{assigns[:class]}-{assigns[:for]}-{assigns[:end]}</p>")
    assert_equal "<p>a-b-c</p>", render(mod.demo(class: "a", for: "b", end: "c"))
  end

  def test_generated_source_is_inspectable
    mod = define("<p>x</p>")
    src = Her.generated_source(mod, :demo)
    assert_includes src, "def self.demo(assigns = {}"
    assert_includes src, "::Her::Safe.new(__buf)"
  end
end
