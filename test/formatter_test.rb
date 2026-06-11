# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class FormatterTest < Minitest::Test
  def fmt(src)
    Her::Formatter.format(src)
  end

  def test_reindents_nested_elements_and_statements
    messy = <<~'HER'
      <div class="card">
      <h2>{@title}</h2>
          {if @on}
      <ul>
      {@items.each do |i|}
      <li>{i}</li>
      {end}
      </ul>
            {else}
      <p>off</p>
      {end}
      </div>
    HER
    assert_equal <<~'HER', fmt(messy)
      <div class="card">
        <h2>{@title}</h2>
        {if @on}
          <ul>
            {@items.each do |i|}
              <li>{i}</li>
            {end}
          </ul>
        {else}
          <p>off</p>
        {end}
      </div>
    HER
  end

  def test_components_and_slots_indent
    messy = "<.card title=\"x\">\n<:top>\n<b>t</b>\n</:top>\nbody\n</.card>\n"
    assert_equal "<.card title=\"x\">\n  <:top>\n    <b>t</b>\n  </:top>\n  body\n</.card>\n", fmt(messy)
  end

  def test_pre_and_script_content_left_verbatim
    src = "<div>\n<pre>\n   spaced   out\n  end</pre>\n<script>\nlet x = { a: 1 };\n</script>\n</div>\n"
    out = fmt(src)
    assert_includes out, "\n   spaced   out\n  end</pre>"
    assert_includes out, "\nlet x = { a: 1 };\n</script>"
    assert out.start_with?("<div>\n  <pre>\n")
  end

  def test_multiline_hole_continuations_left_verbatim
    src = "<p>{[\n  @a,\n].size}</p>\n"
    assert_equal src, fmt(src)
  end

  def test_multiline_tag_attribute_lines_left_verbatim
    src = "<div\n  class=\"a\"\n  id={@x}\n>\n<p>x</p>\n</div>\n"
    out = fmt(src)
    assert_includes out, "<div\n  class=\"a\"\n  id={@x}\n"
    assert_includes out, "  <p>x</p>\n</div>"
  end

  def test_idempotent
    messy = "<div>\n<span>{if @x}a{end}</span>\n{case @l}\n{when 1}\n<i>one</i>\n{end}\n</div>\n"
    once = fmt(messy)
    assert_equal once, fmt(once)
  end

  def test_does_not_change_semantics
    messy = "<article>\n<pre>  keep</pre>\n{if @on}\n<b>x</b>\n{end}\n</article>\n"
    formatted = fmt(messy)
    m1 = component_module { component(:t) { attr :on; template messy } }
    m2 = component_module { component(:t) { attr :on; template formatted } }
    [{ on: true }, { on: false }].each do |assigns|
      a = m1.t(assigns).to_s
      b = m2.t(assigns).to_s
      assert_includes b, "<pre>  keep</pre>"
      assert_equal a.gsub(/\s+/, " "), b.gsub(/\s+/, " ")
    end
  end

  def test_conditional_wrapper_templates_format
    src = "{if @url}\n<a href={@url}>\n{end}\n{@text}\n{if @url}\n</a>\n{end}\n"
    out = fmt(src)
    assert_equal out, fmt(out) # transparent statements keep it parseable + idempotent
  end

  def test_blank_lines_kept_blank
    assert_equal "<p>a</p>\n\n<p>b</p>\n", fmt("<p>a</p>\n   \n<p>b</p>\n")
  end

  def test_raises_with_caret_on_invalid_templates
    error = assert_raises(Her::ParseError) { fmt("<div>\n  <span>\n</div>\n") }
    assert_match(/mismatched closing tag/, error.message)
    assert_includes error.message, "^"
  end

  def test_format_file_and_check_mode
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.her")
      File.write(path, "<div>\n<p>a</p>\n</div>\n")
      assert Her::Formatter.format_file(path, check: true)
      assert_equal "<div>\n<p>a</p>\n</div>\n", File.read(path) # check leaves it alone
      assert Her::Formatter.format_file(path)
      assert_equal "<div>\n  <p>a</p>\n</div>\n", File.read(path)
      refute Her::Formatter.format_file(path) # already formatted
    end
  end
end
