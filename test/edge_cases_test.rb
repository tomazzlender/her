# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Adversarial edges across the whole pipeline: encodings, line endings,
# pathological nesting, statement-hole corner cases, capture semantics,
# and inputs at the boundaries of the grammar.
class EdgeCasesTest < Minitest::Test
  def define(template_src)
    referenced = template_src.scan(/@([a-z_][a-zA-Z0-9_]*)/).flatten.uniq
    component_module do
      component :demo do
        referenced.each { |key| attr key.to_sym }
        template template_src
      end
    end
  end

  # -- encodings & line endings -------------------------------------------------

  def test_crlf_templates_render_crlf_verbatim
    mod = define("<div>\r\n  <p>{@x}</p>\r\n</div>\r\n")
    assert_equal "<div>\r\n  <p>1</p>\r\n</div>\r\n", render(mod.demo(x: 1))
  end

  def test_crlf_parse_errors_count_lines_correctly
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "win.html.her"), "<div>\r\n<span>\r\n")
      error = assert_raises(Her::ParseError) do
        component_module {}.embed_templates("*.html.her", dir: dir)
      end
      assert_equal 2, error.line # the <span> sits on line 2 despite CRLF endings
      assert_match(/unclosed tag <span>/, error.message)
    end
  end

  def test_carriage_return_in_attribute_value
    mod = define("<p title=\"a\r\nb\">x</p>")
    assert_equal "<p title=\"a\r\nb\">x</p>", render(mod.demo)
  end

  def test_emoji_in_text_attrs_and_assigns
    mod = define(%q(<p title="🎉 {@x}">🚀</p>))
    assert_equal %(<p title="🎉 ✨">🚀</p>), render(mod.demo(x: "✨"))
  end

  def test_bom_passes_through
    mod = define("﻿<p>x</p>")
    assert_equal "﻿<p>x</p>", render(mod.demo)
  end

  # -- grammar boundaries ----------------------------------------------------------

  def test_template_of_a_single_hole
    assert_equal "7", render(define("{@x}").demo(x: 7))
  end

  def test_consecutive_holes
    assert_equal "123", render(define("{@a}{@b}{@c}").demo(a: 1, b: 2, c: 3))
  end

  def test_custom_elements_with_dashes
    mod = define(%q(<my-widget data-x="1">a</my-widget>))
    assert_equal %(<my-widget data-x="1">a</my-widget>), render(mod.demo)
  end

  def test_empty_quoted_attribute_value
    assert_equal %(<p class="">x</p>), render(define(%q(<p class="">x</p>)).demo)
  end

  def test_greater_than_in_text_and_attr
    assert_equal %(<p data-x="a>b">1 > 0</p>), render(define(%q(<p data-x="a>b">1 > 0</p>)).demo)
  end

  def test_cdata_like_declaration_passes_through
    assert_equal "<![CDATA[plain]]>", render(define("<![CDATA[plain]]>").demo)
  end

  def test_statement_keywords_with_inner_spaces
    assert_equal "Y", render(define("{ if @x }Y{ end }").demo(x: true))
  end

  def test_script_with_statement_holes_under_her_interpolate
    mod = define(%q(<script her-interpolate>{if @x}let a;{end}</script>))
    assert_equal "<script>let a;</script>", render(mod.demo(x: true))
    assert_equal "<script></script>", render(mod.demo(x: false))
  end

  def test_script_attribute_value_containing_gt
    mod = define(%q(<script data-x="a>b">let y;</script>))
    assert_equal %(<script data-x="a>b">let y;</script>), render(mod.demo)
  end

  def test_nested_no_curly_with_different_tag_names
    mod = define("<div her-no-curly><section her-no-curly>{a}</section>{b}</div>{@x}")
    assert_equal "<div><section>{a}</section>{b}</div>9", render(mod.demo(x: 9))
  end

  # -- statement-hole failure modes --------------------------------------------------

  def test_orphan_end_is_a_mapped_compile_error
    error = assert_raises(Her::CompileError) { define("<p>x</p>{end}") }
    assert_match(/invalid Ruby generated/, error.message)
    assert_match(/control-flow holes/, error.message)
  end

  def test_orphan_else_is_a_mapped_compile_error
    assert_raises(Her::CompileError) { define("{else}") }
  end

  def test_surplus_end_is_a_mapped_compile_error
    assert_raises(Her::CompileError) { define("{if @x}a{end}{end}") }
  end

  # -- scale: nesting, recursion, attribute counts ------------------------------------

  def test_deeply_nested_template
    depth = 500
    mod = define(("<div>" * depth) + "x" + ("</div>" * depth))
    out = render(mod.demo)
    assert_equal depth, out.scan("<div>").size
    assert out.include?("x")
  end

  def test_pathological_nesting_fails_with_a_clear_error
    # Codegen recursion has a stack limit (~2000 levels on the main thread,
    # far beyond real HTML); past it the failure must be a CompileError,
    # not a raw SystemStackError. Threads have small stacks, so this is
    # deterministic regardless of how much main-thread stack remains.
    error = nil
    Thread.new do
      component_module do
        component :abyss do
          template ("<div>" * 50_000) + "x" + ("</div>" * 50_000)
        end
      end
    rescue Her::CompileError => e
      error = e
    end.join
    assert_kind_of Her::CompileError, error
    assert_match(/nests too deeply/, error.message)
    assert_match(/RUBY_THREAD_VM_STACK_SIZE/, error.message)
  end

  def test_recursive_render_depth
    mod = component_module do
      component :tree do
        attr :n
        template "<i>{if @n > 0}<.tree n={@n - 1}/>{end}</i>"
      end
    end
    out = render(mod.tree(n: 500))
    assert_equal 501, out.scan("<i>").size
  end

  def test_many_attributes
    attrs = 60.times.map { |i| %(a#{i}="v#{i}") }.join(" ")
    out = render(define("<p #{attrs}>x</p>").demo)
    assert_includes out, 'a59="v59"'
  end

  def test_many_component_attrs
    mod = component_module do
      component :sink do
        template "<p>{assigns.size}</p>"
      end
      component :caller do
        template "<.sink #{40.times.map { |i| %(k#{i}="#{i}") }.join(' ')}/>"
      end
    end
    assert_equal "<p>40</p>", render(mod.caller)
  end

  # -- capture semantics ----------------------------------------------------------------

  def test_capture_block_called_twice_rebuilds_buffer
    mod = component_module do
      def self.twice = Her.raw("#{yield}#{yield}")
      component :demo do
        template "{= twice do}a{end}"
      end
    end
    assert_equal "aa", render(mod.demo)
  end

  def test_capture_block_never_called
    mod = component_module do
      def self.silent = Her.raw("<hr>")
      component :demo do
        template "{= silent do}dropped{end}"
      end
    end
    assert_equal "<hr>", render(mod.demo)
  end

  # -- naming & contracts -----------------------------------------------------------------

  def test_component_can_shadow_kernel_private_method_names
    mod = component_module do
      component :p do
        template "<b>I am p</b>"
      end
      component :demo do
        template "<.p/>"
      end
    end
    assert_equal "<b>I am p</b>", render(mod.demo)
  end

  def test_frozen_defaults_cannot_be_mutated_by_renders
    mod = component_module do
      component :demo do
        attr :items, default: []
        template "{@items << 1}"
      end
    end
    assert_raises(FrozenError) { mod.demo }
  end

  def test_string_keyed_assigns_fail_with_a_telling_message
    mod = component_module do
      component :demo do
        attr :x, required: true
        template "<p>{@x}</p>"
      end
    end
    error = assert_raises(Her::MissingAttr) { mod.demo("x" => 1) }
    assert_match(/missing required attribute :x \(assigns given: "x"\)/, error.message)
  end

  def test_verify_catches_recursive_call_missing_own_required_attr
    mod = component_module do
      component :tree do
        attr :node, required: true
        template "<li>{@node}{if false}<.tree/>{end}</li>"
      end
    end
    issue = Her.verify(mod).first
    assert_equal :missing_required_attr, issue.type
    assert_match(/calls <\.tree\/> without its required attr :node/, issue.message)
  end

  # -- formatter line endings ----------------------------------------------------------------

  def test_formatter_preserves_cr_inside_pre
    src = "<pre>\r\n  a\r\n</pre>\n"
    out = Her::Formatter.format(src)
    assert_includes out, "  a\r\n"
  end

  def test_formatter_normalizes_indent_lines_to_lf
    out = Her::Formatter.format("<div>\r\n<p>a</p>\r\n</div>\r\n")
    assert_equal "<div>\n  <p>a</p>\n</div>\n", out
  end
end
