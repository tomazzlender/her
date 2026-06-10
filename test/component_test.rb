# frozen_string_literal: true

require_relative "test_helper"

# Phase 2 (§6): in-template component calls and slots.
class ComponentTest < Minitest::Test
  # A namespaced component used by <Remote.icon/> tests. Note %q: an
  # interpolating literal would evaluate #{@name} at definition time.
  module Remote
    extend Her::Component
    component :icon do
      attr :name, required: true
      template %q(<svg class={"icon-#{@name}"}></svg>)
    end
  end

  def ui
    @ui ||= component_module do
      component :button do
        attr :label, required: true
        attr :class, default: "btn"
        template %(<button class={@class}>{@label}</button>)
      end
    end
  end

  def test_local_component_call_with_static_attrs
    ui.component :bar do
      template %(<div><.button label="Save"/></div>)
    end
    assert_equal %(<div><button class="btn">Save</button></div>), render(ui.bar)
  end

  def test_local_component_call_with_dynamic_attrs
    ui.component :bar do
      template %(<.button label={@text} class={@cls}/>)
    end
    assert_equal %(<button class="big">Go</button>), render(ui.bar(text: "Go", cls: "big"))
  end

  def test_component_attr_values_are_values_not_html
    ui.component :bar do
      template %(<.button label={@text}/>)
    end
    # Escaping happens exactly once, inside button's own template.
    assert_equal %(<button class="btn">a &lt;b&gt; c</button>), render(ui.bar(text: "a <b> c"))
  end

  def test_component_mixed_attr_builds_string_value
    ui.component :bar do
      template %(<.button label="Hi {@name}!"/>)
    end
    assert_equal %(<button class="btn">Hi Ana!</button>), render(ui.bar(name: "Ana"))
  end

  def test_nested_components_do_not_double_escape
    ui.component :level1 do
      template %(<.button label="A & B"/>)
    end
    ui.component :level2 do
      template %(<section><.level1/></section>)
    end
    assert_equal %(<section><button class="btn">A &amp; B</button></section>), render(ui.level2)
  end

  def test_remote_component_call
    mod = component_module do
      component :toolbar do
        template %(<div><ComponentTest::Remote.icon name="x"/></div>)
      end
    end
    assert_equal %(<div><svg class="icon-x"></svg></div>), render(mod.toolbar)
  end

  def test_component_splat_attrs
    ui.component :bar do
      template %(<.button {@opts}/>)
    end
    assert_equal %(<button class="btn">S</button>), render(ui.bar(opts: { label: "S" }))
  end

  def test_splat_merge_order_later_wins
    ui.component :bar do
      template %(<.button label="first" {@opts}/>)
    end
    assert_equal %(<button class="btn">second</button>), render(ui.bar(opts: { label: "second" }))
  end

  def test_bare_attr_on_component_is_true
    mod = component_module do
      component :flag do
        template "<p>{assigns[:on].inspect}</p>"
      end
      component :caller do
        template "<.flag on/>"
      end
    end
    assert_equal "<p>true</p>", render(mod.caller)
  end

  # -- slots -------------------------------------------------------------------

  def slotted
    @slotted ||= component_module do
      component :card do
        attr :title, required: true
        template %(<div class="card"><h2>{@title}</h2>{render_slot(:inner)}</div>)
      end
    end
  end

  def test_default_slot_from_ruby_block
    out = slotted.card(title: "T") { "plain & <text>" }
    assert_equal %(<div class="card"><h2>T</h2>plain &amp; &lt;text&gt;</div>), render(out)
  end

  def test_default_slot_block_returning_safe_is_trusted
    inner = slotted
    out = inner.card(title: "T") { inner.card(title: "N") }
    assert_equal %(<div class="card"><h2>T</h2><div class="card"><h2>N</h2></div></div>), render(out)
  end

  def test_default_slot_absent_renders_empty
    assert_equal %(<div class="card"><h2>T</h2></div>), render(slotted.card(title: "T"))
  end

  def test_default_slot_from_template_children
    slotted.component :page do
      template %(<.card title="T"><em>inner {@x}</em></.card>)
    end
    assert_equal %(<div class="card"><h2>T</h2><em>inner 5</em></div>), render(slotted.page(x: 5))
  end

  def test_inner_slot_tag_render_form
    mod = component_module do
      component :box do
        template "<div><:inner/></div>"
      end
    end
    assert_equal "<div>hi</div>", render(mod.box { "hi" })
  end

  def test_named_slot_definition_and_render
    mod = component_module do
      component :layout do
        template %(<header><:top/></header><main>{render_slot(:inner)}</main>)
      end
      component :page do
        template %(<.layout><:top><b>Title</b></:top>body</.layout>)
      end
    end
    assert_equal "<header><b>Title</b></header><main>body</main>", render(mod.page)
  end

  def test_named_slot_fallback_content
    mod = component_module do
      component :layout do
        template "<h1><:title>Untitled</:title></h1>"
      end
      component :with_title do
        template "<.layout><:title>Real</:title></.layout>"
      end
    end
    assert_equal "<h1>Untitled</h1>", render(mod.layout)
    assert_equal "<h1>Real</h1>", render(mod.with_title)
  end

  def test_multiple_same_name_slots_concatenate
    mod = component_module do
      component :list do
        template "<ul><:item/></ul>"
      end
      component :menu do
        template "<.list><:item><li>a</li></:item><:item><li>b</li></:item></.list>"
      end
    end
    assert_equal "<ul><li>a</li><li>b</li></ul>", render(mod.menu)
  end

  def test_slot_with_let_binding
    mod = component_module do
      component :table do
        template "<table>{@rows.each do |r|}<tr>{render_slot(:col, r)}</tr>{end}</table>"
      end
      component :grid do
        template "<.table rows={@rows}><:col let={r}><td>{r * 2}</td></:col></.table>"
      end
    end
    assert_equal "<table><tr><td>2</td></tr><tr><td>4</td></tr></table>", render(mod.grid(rows: [1, 2]))
  end

  def test_component_level_let_binds_inner_block_args
    mod = component_module do
      component :list do
        template "<ul>{@items.each do |i|}<li>{render_slot(:inner, i)}</li>{end}</ul>"
      end
      component :doubles do
        template "<.list items={@items} let={n}>n={n}</.list>"
      end
    end
    assert_equal "<ul><li>n=1</li><li>n=2</li></ul>", render(mod.doubles(items: [1, 2]))
  end

  def test_render_slot_args_reach_ruby_block
    mod = component_module do
      component :each_item do
        template "{@items.each do |i|}[{render_slot(:inner, i)}]{end}"
      end
    end
    assert_equal "[I1][I2]", render(mod.each_item(items: [1, 2]) { |i| "I#{i}" })
  end

  def test_slot_predicate
    mod = component_module do
      component :box do
        template "{if slot?(:badge)}<span><:badge/></span>{end}<p>{render_slot(:inner)}</p>"
      end
      component :with_badge do
        template "<.box><:badge>9</:badge>text</.box>"
      end
      component :without_badge do
        template "<.box>text</.box>"
      end
    end
    assert_equal "<span>9</span><p>text</p>", render(mod.with_badge)
    assert_equal "<p>text</p>", render(mod.without_badge)
  end

  def test_slot_renders_resolve_lexically_not_dynamically
    # A slot render nested inside another component's children must see the
    # slots of the component whose template it appears in.
    mod = component_module do
      component :wrap do
        template %(<div class="w">{render_slot(:inner)}</div>)
      end
      component :outer do
        template "<.wrap><span><:icon>none</:icon></span></.wrap>"
      end
      component :gives_icon do
        template "<.outer><:icon>ICON</:icon></.outer>"
      end
    end
    assert_equal %(<div class="w"><span>none</span></div>), render(mod.outer)
    assert_equal %(<div class="w"><span>ICON</span></div>), render(mod.gives_icon)
  end

  def test_whitespace_between_slot_defs_is_not_inner_content
    mod = component_module do
      component :box do
        template "{if slot?(:inner)}HAS-INNER{else}EMPTY{end}<:top/>"
      end
      component :caller do
        template <<~'HER'
          <.box>
            <:top>t</:top>
          </.box>
        HER
      end
    end
    assert_equal "EMPTYt", render(mod.caller).strip
  end

  def test_render_slot_without_slot_context_raises_with_guidance
    error = assert_raises(Her::SlotError) { Her.render_slot(:inner) }
    assert_match(/must be called bare inside a template hole/, error.message)
    assert_raises(Her::SlotError) { Her.slot?(:inner) }
  end

  def test_render_slot_takes_an_explicit_slots_hash_outside_templates
    out = Her.render_slot({ inner: [-> { "<b>x</b>" }] }, :inner)
    assert_equal "&lt;b&gt;x&lt;/b&gt;", out.to_s
    assert Her.slot?({ inner: [-> { "" }] })
    refute Her.slot?({}, :inner)
  end

  def test_render_slot_works_across_fiber_boundaries
    # The block given to Enumerator#next runs in a separate fiber; slot
    # context travels through the closure, not fiber-local state.
    mod = component_module do
      component :lazy do
        template "<p>{Enumerator.new { |y| y << render_slot(:inner) }.next}</p>"
      end
    end
    assert_equal "<p>hi</p>", render(mod.lazy { "hi" })
    refute_includes Her.generated_source(mod, :lazy), "push_slots"
  end

  def test_slot_call_inside_string_interpolation
    mod = component_module do
      component :wrapped do
        template %q(<p>{"[#{render_slot(:inner)}]"}</p>)
      end
    end
    assert_equal "<p>[x]</p>", render(mod.wrapped { "x" })
  end

  def test_bare_render_slot_with_fallback_expression
    mod = component_module do
      component :box do
        template %q(<p>{render_slot || raw("none")}</p>)
      end
    end
    assert_equal "<p>none</p>", render(mod.box)
    assert_equal "<p>given</p>", render(mod.box { "given" })
  end

  def test_render_slot_command_form
    skip "needs prism" unless Her::RubyScanner.prism?
    mod = component_module do
      component :box do
        template "<p>{render_slot :inner}</p>"
      end
    end
    assert_equal "<p>x</p>", render(mod.box { "x" })
  end

  def test_methods_named_like_render_slot_are_untouched
    mod = component_module do
      def self.my_render_slot(value) = "M#{value}"
      component :demo do
        template "<p>{my_render_slot(@x)}</p>"
      end
    end
    assert_equal "<p>M1</p>", render(mod.demo(x: 1))
  end

  def test_render_slot_on_a_receiver_is_not_rewritten
    obj = Class.new { def render_slot = "object-method" }.new
    mod = component_module do
      component :demo do
        template "<p>{@obj.render_slot}</p>"
      end
    end
    assert_equal "<p>object-method</p>", render(mod.demo(obj: obj))
  end

  def test_helpers_cannot_render_slots_implicitly
    # Slot context is data, not ambient state: a module helper has no slot
    # frame to read. The error says what to do instead.
    mod = component_module do
      def self.sneaky = Her.render_slot(:inner)
      component :demo do
        template "<p>{sneaky}</p>"
      end
    end
    error = assert_raises(Her::SlotError) { mod.demo { "x" } }
    assert_match(/must be called bare/, error.message)
  end

  def test_user_helpers_callable_from_holes
    mod = component_module do
      def self.shout(s) = s.upcase
      component :loud do
        template "<p>{shout(@msg)}</p>"
      end
    end
    assert_equal "<p>HI</p>", render(mod.loud(msg: "hi"))
  end

  def test_components_defined_later_resolve_at_render_time
    mod = component_module do
      component :a do
        template "<.b/>"
      end
      component :b do
        template "<i>b</i>"
      end
    end
    assert_equal "<i>b</i>", render(mod.a)
  end

  def test_recursive_component
    mod = component_module do
      component :tree do
        template "<li>{@node[:name]}{if @node[:kids].any?}<ul>{@node[:kids].each do |k|}<.tree node={k}/>{end}</ul>{end}</li>"
      end
    end
    out = render(mod.tree(node: { name: "a", kids: [{ name: "b", kids: [] }] }))
    assert_equal "<li>a<ul><li>b</li></ul></li>", out
  end

  def test_slot_frames_are_isolated_across_threads
    mod = component_module do
      component :box do
        template "<i>{render_slot(:inner)}</i>"
      end
    end
    outputs = Array.new(4) do |i|
      Thread.new { Array.new(25) { mod.box { "t#{i}" }.to_s }.uniq }
    end.flat_map(&:value)
    assert_equal %w[<i>t0</i> <i>t1</i> <i>t2</i> <i>t3</i>], outputs.uniq.sort
  end
end
