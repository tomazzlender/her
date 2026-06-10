# frozen_string_literal: true

require_relative "test_helper"

# The build spec's Appendix A, end to end: embed_templates + an explicit
# contracted component + in-template calls + block slot.
class AppendixTest < Minitest::Test
  module UI
    extend Her::Component
    embed_templates "fixtures/components/*.html.her"

    component :card do
      attr :title, required: true
      template <<~HER
        <div class="card">
          <h2>{@title}</h2>
          <.button label="Dismiss" class="btn ghost"/>
          {render_slot(:inner)}
        </div>
      HER
    end
  end

  def test_button_direct_call
    out = UI.button(label: "Save", class: "btn primary")
    assert_kind_of Her::Safe, out
    assert_equal %(<button class="btn primary">Save</button>\n), out.to_s
  end

  def test_card_with_block
    html = UI.card(title: "Welcome") do
      UI.button(label: "Get started", class: "btn primary")
    end.to_s

    assert_includes html, %(<div class="card">)
    assert_includes html, "<h2>Welcome</h2>"
    assert_includes html, %(<button class="btn ghost">Dismiss</button>)
    assert_includes html, %(<button class="btn primary">Get started</button>)
    assert_operator html.index("Dismiss"), :<, html.index("Get started")
    assert html.end_with?("</div>\n")
  end

  def test_card_escapes_untrusted_title
    assert_includes UI.card(title: "<xss>") { "" }.to_s, "<h2>&lt;xss&gt;</h2>"
  end

  def test_missing_attr
    error = assert_raises(Her::MissingAttr) { UI.card }
    assert_equal "AppendixTest::UI.card: missing required attribute :title", error.message
  end
end
