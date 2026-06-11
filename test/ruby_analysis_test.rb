# frozen_string_literal: true

require_relative "test_helper"

# Hole analysis: the Prism engine (real Ruby parser — exotic literals,
# AST-exact rewriting, load-time validation) and behaviors shared with the
# heuristic fallback. Prism-gated tests skip under HER_NO_PRISM / old rubies.
class RubyAnalysisTest < Minitest::Test
  def define(template_src)
    referenced = template_src.scan(/@([a-z_][a-zA-Z0-9_]*)/).flatten.uniq
    component_module do
      component :demo do
        referenced.each { |key| attr key.to_sym }
        template template_src
      end
    end
  end

  def prism?
    Her::RubyScanner.prism?
  end

  # -- both engines -------------------------------------------------------------

  def test_engine_selection_is_reported
    assert_includes [true, false], prism?
  end

  def test_comment_in_expression_hole_does_not_eat_generated_code
    mod = define("<p>{@x # a note}</p><i>after</i>")
    assert_equal "<p>5</p><i>after</i>", render(mod.demo(x: 5))
  end

  def test_comment_in_statement_hole
    mod = define("{if @on # toggle}Y{end}<i>after</i>")
    assert_equal "Y<i>after</i>", render(mod.demo(on: true))
  end

  def test_comment_in_attribute_hole
    mod = define("<p class={@c # note}>x</p>")
    assert_equal %(<p class="big">x</p>), render(mod.demo(c: "big"))
  end

  # -- exotic literals terminate holes correctly (Prism) ---------------------------

  def test_percent_q_with_closing_brace
    skip "needs prism" unless prism?
    mod = define("<p>{'a' + %q[}] + 'b'}</p>")
    assert_equal "<p>a}b</p>", render(mod.demo)
  end

  def test_regexp_with_closing_brace
    skip "needs prism" unless prism?
    mod = define(%q(<p>{@s.sub(/\}/, "X")}</p>))
    assert_equal "<p>aXb</p>", render(mod.demo(s: "a}b"))
  end

  def test_heredoc_with_closing_brace_in_body
    skip "needs prism" unless prism?
    mod = define("<p>{<<~T.strip\n  a}b\nT\n}</p>")
    assert_equal "<p>a}b</p>", render(mod.demo)
  end

  def test_percent_w_contents_are_not_assign_rewritten
    skip "needs prism" unless prism?
    mod = define("<p>{%w[@a @b].join}</p>")
    assert_equal "<p>@a@b</p>", render(mod.demo)
  end

  def test_at_in_regexp_is_not_rewritten
    skip "needs prism" unless prism?
    mod = define(%q(<p>{@s.match?(/@here/) ? "y" : "n"}</p>))
    assert_equal "<p>y</p>", render(mod.demo(s: "cc @here"))
  end

  # -- load-time validation of hole Ruby (Prism) ------------------------------------

  def test_invalid_expression_fails_at_load_with_parser_message
    skip "needs prism" unless prism?
    decl_line = nil
    error = assert_raises(Her::ParseError) do
      component_module do
        component :demo do
          decl_line = __LINE__ + 1
          template "<p>{@price *}</p>"
        end
      end
    end
    assert_match(/invalid Ruby in interpolation/, error.message)
    assert_match(/expected an expression/, error.message)
    assert_equal decl_line, error.line
  end

  def test_comment_only_hole_is_rejected
    skip "needs prism" unless prism?
    error = assert_raises(Her::ParseError) { define("<p>{# just a note}</p>") }
    assert_match(/contains no expression/, error.message)
  end

  def test_invalid_ruby_in_attribute_hole
    skip "needs prism" unless prism?
    error = assert_raises(Her::CompileError) { define("<p class={@a +}>x</p>") }
    assert_match(/invalid Ruby in attribute `class`/, error.message)
  end

  # -- assigns are read-only (Prism) ---------------------------------------------------

  def test_assigning_to_an_assign_is_rejected
    skip "needs prism" unless prism?
    error = assert_raises(Her::CompileError) { define("<p>{@x = 1}</p>") }
    assert_match(/cannot assign to @x/, error.message)
    assert_match(/read-only/, error.message)
  end

  def test_operator_assignment_is_rejected
    skip "needs prism" unless prism?
    assert_raises(Her::CompileError) { define("<p>{@x ||= 1}</p>") }
  end

  def test_mutating_an_assigned_object_is_still_allowed
    mod = define("<p>{@list.push(2).join}</p>")
    assert_equal "<p>12</p>", render(mod.demo(list: [1]))
  end

  # -- parse-based classification (Prism) -----------------------------------------------

  def test_complete_if_expression_renders_its_value
    skip "needs prism" unless prism?
    mod = define(%q(<p>{if @on then "Y" else "N" end}</p>))
    assert_equal "<p>Y</p>", render(mod.demo(on: true))
    assert_equal "<p>N</p>", render(mod.demo(on: false))
  end

  def test_fragments_still_classify_as_statements
    mod = define("{if @on}<b>y</b>{else}<i>n</i>{end}")
    assert_equal "<b>y</b>", render(mod.demo(on: true))
    assert_equal "<i>n</i>", render(mod.demo(on: false))
  end

  def test_assigns_rewritten_inside_mid_fragments
    mod = define(%q({if false}a{elsif @alt}<b>{@alt}</b>{end}))
    assert_equal "<b>x</b>", render(mod.demo(alt: "x"))
  end
end
