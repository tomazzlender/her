# frozen_string_literal: true

require_relative "test_helper"

# `{= helper do |x|}...{end}` capture holes and the opt-in strict_html mode.
class CaptureStrictTest < Minitest::Test
  # -- capture ---------------------------------------------------------------

  def fieldset_module
    component_module do
      # A Rails-style capture helper: wraps its block's content.
      def self.fieldset(legend)
        Her.raw("<fieldset><legend>#{Her.safe(legend)}</legend>#{Her.safe(yield)}</fieldset>")
      end

      def self.maybe_wrap(wrap)
        inner = yield("inner-cls")
        wrap ? Her.raw("<div>#{Her.safe(inner)}</div>") : inner
      end
    end
  end

  def test_capture_appends_the_helpers_return_value
    mod = fieldset_module
    mod.component :form do
      template "{= fieldset(@title) do}<p>{@body}</p>{end}"
    end
    assert_equal "<fieldset><legend>T &amp; U</legend><p>b</p></fieldset>",
                 render(mod.form(title: "T & U", body: "b"))
  end

  def test_capture_block_arguments_bind
    mod = fieldset_module
    mod.component :wrapped do
      template "{= maybe_wrap(@wrap) do |cls|}<i class={cls}>x</i>{end}"
    end
    assert_equal %(<div><i class="inner-cls">x</i></div>), render(mod.wrapped(wrap: true))
    assert_equal %(<i class="inner-cls">x</i>), render(mod.wrapped(wrap: false))
  end

  def test_capture_contains_control_flow_and_nested_capture
    mod = fieldset_module
    mod.component :nested do
      template <<~'HER'
        {= fieldset("outer") do}
          {if @inner}
            {= fieldset("inner") do}<b>{@msg}</b>{end}
          {end}
        {end}
      HER
    end
    html = render(mod.nested(inner: true, msg: "hi"))
    assert_includes html, "<legend>outer</legend>"
    assert_includes html, "<fieldset><legend>inner</legend><b>hi</b></fieldset>"
    refute_includes render(mod.nested(inner: false, msg: "hi")), "inner"
  end

  def test_capture_inside_component_children
    mod = fieldset_module
    mod.component :card do
      template %(<div class="card">{render_slot(:inner)}</div>)
    end
    mod.component :page do
      template "<.card>{= fieldset(@t) do}body{end}</.card>"
    end
    assert_equal %(<div class="card"><fieldset><legend>L</legend>body</fieldset></div>),
                 render(mod.page(t: "L"))
  end

  def test_capture_escapes_untrusted_helper_results
    mod = component_module do
      def self.shady = yield.to_s + "<script>"
      component :demo do
        template "{= shady do}x{end}"
      end
    end
    assert_equal "x&lt;script&gt;", render(mod.demo)
  end

  def test_capture_without_block_opener_is_rejected
    error = assert_raises(Her::ParseError) do
      component_module do
        component :demo do
          template "{= @x + 1}"
        end
      end
    end
    assert_match(/capture hole `\{= \.\.\. \}` must end with a block opener/, error.message)
  end

  def test_captures_are_statement_transparent_but_strict_mode_rejects_crossing
    # Like all statement holes, captures are transparent to tag balancing in
    # the default mode (§8.1); strict_html catches the crossing.
    error = assert_raises(Her::CompileError) do
      component_module do
        def self.fieldset(_x) = Her.raw(yield.to_s)
        component :demo, strict_html: true do
          template "<div>{= fieldset(1) do}</div>{end}"
        end
      end
    end
    assert_match(/closes a statement opened outside/, error.message)
  end

  # -- strict_html -------------------------------------------------------------

  def test_strict_mode_accepts_nested_control_flow
    mod = component_module do
      component :ok, strict_html: true do
        template "<ul>{@items.each do |i|}<li>{if i > 1}<b>{i}</b>{else}{i}{end}</li>{end}</ul>"
      end
    end
    assert_equal "<ul><li>1</li><li><b>2</b></li></ul>", render(mod.ok(items: [1, 2]))
  end

  def test_strict_mode_rejects_conditional_wrappers
    error = assert_raises(Her::CompileError) do
      component_module do
        component :wrapper, strict_html: true do
          template %q({if @url}<a href={@url}>{end}{@text}{if @url}</a>{end})
        end
      end
    end
    assert_match(/strict_html/, error.message)
    assert_match(/\{end\} closes a statement opened outside <a>/, error.message)
    assert_match(/conditional-wrapper pattern is\s+disallowed/m, error.message)
  end

  def test_strict_mode_rejects_branches_crossing_an_element
    error = assert_raises(Her::CompileError) do
      component_module do
        component :crossed, strict_html: true do
          template "{if @a}<span>{else}</span>{end}"
        end
      end
    end
    assert_match(/\{else\} continues a statement opened outside <span>/, error.message)
  end

  def test_strict_mode_rejects_unclosed_statement_in_scope
    error = assert_raises(Her::CompileError) do
      component_module do
        component :open_ended, strict_html: true do
          template "<div>{if @a}</div>"
        end
      end
    end
    assert_match(/\{if @a\} is not closed within <div>/, error.message)
  end

  def test_strict_mode_reports_stray_end_at_template_level
    error = assert_raises(Her::CompileError) do
      component_module do
        component :stray, strict_html: true do
          template "<div>{if @a}</div>{end}"
        end
      end
    end
    assert_match(/\{end\} closes a statement opened outside the template body/, error.message)
  end

  def test_default_mode_still_allows_conditional_wrappers
    mod = component_module do
      component :wrapper do
        template %q({if @url}<a href={@url}>{end}{@text}{if @url}</a>{end})
      end
    end
    assert_equal %(<a href="/x">go</a>), render(mod.wrapper(url: "/x", text: "go"))
  end

  def test_global_strict_flag_applies_and_is_overridable
    Her.strict_html = true
    error = assert_raises(Her::CompileError) do
      component_module do
        component :bad do
          template "{if @a}<b>{end}</b>"
        end
      end
    end
    assert_match(/strict_html/, error.message)

    mod = component_module do
      component :opt_out, strict_html: false do
        template "{if @a}<b>{end}x{if @a}</b>{end}"
      end
    end
    assert_equal "<b>x</b>", render(mod.opt_out(a: true))
  ensure
    Her.strict_html = false
  end

  def test_strict_checks_slot_definition_bodies
    error = assert_raises(Her::CompileError) do
      component_module do
        component :layout, strict_html: true do
          template "<:side/>"
        end
        component :bad, strict_html: true do
          template "<.layout><:side>{end}</:side></.layout>"
        end
      end
    end
    assert_match(%r{closes a statement opened outside slot <:side>}, error.message)
  end
end
