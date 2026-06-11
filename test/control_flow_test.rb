# frozen_string_literal: true

require_relative "test_helper"

# Phase 6 (§8.5): control flow as statement holes — plain Ruby, no block tags.
class ControlFlowTest < Minitest::Test
  def define(template_src)
    referenced = template_src.scan(/@([a-z_][a-zA-Z0-9_]*)/).flatten.uniq
    component_module do
      component :demo do
        referenced.each { |key| attr key.to_sym }
        template template_src
      end
    end
  end

  def squish(safe)
    render(safe).gsub(/\s+/, " ").strip
  end

  def test_if_else_end
    mod = define("{if @on}<b>yes</b>{else}<i>no</i>{end}")
    assert_equal "<b>yes</b>", render(mod.demo(on: true))
    assert_equal "<i>no</i>", render(mod.demo(on: false))
  end

  def test_elsif_chain
    mod = define("{if @n > 10}big{elsif @n > 5}mid{else}small{end}")
    assert_equal "big", render(mod.demo(n: 11))
    assert_equal "mid", render(mod.demo(n: 7))
    assert_equal "small", render(mod.demo(n: 1))
  end

  def test_unless
    mod = define("{unless @hide}<p>shown</p>{end}")
    assert_equal "<p>shown</p>", render(mod.demo(hide: false))
    assert_equal "", render(mod.demo(hide: true))
  end

  def test_each_do_loop
    mod = define("<ul>{@items.each do |item|}<li>{item}</li>{end}</ul>")
    assert_equal "<ul><li>a</li><li>&lt;b&gt;</li></ul>", render(mod.demo(items: ["a", "<b>"]))
  end

  def test_each_with_index
    mod = define("{@items.each_with_index do |item, i|}<p>{i}:{item}</p>{end}")
    assert_equal "<p>0:a</p><p>1:b</p>", render(mod.demo(items: %w[a b]))
  end

  def test_for_in_loop
    mod = define("{for n in @nums}[{n}]{end}")
    assert_equal "[1][2][3]", render(mod.demo(nums: [1, 2, 3]))
  end

  def test_case_when_with_blank_swallowing
    mod = define(<<~HER)
      {case @lang}
      {when "sl"}
        <p>Živjo</p>
      {when "de"}
        <p>Hallo</p>
      {else}
        <p>Hello</p>
      {end}
    HER
    assert_equal "<p>Živjo</p>", squish(mod.demo(lang: "sl"))
    assert_equal "<p>Hallo</p>", squish(mod.demo(lang: "de"))
    assert_equal "<p>Hello</p>", squish(mod.demo(lang: "en"))
  end

  def test_conditional_wrapper_element
    # The §8.1 pain point HEEx rejects: a tag opened in one branch and
    # closed in another. Tags balance lexically, so this compiles.
    mod = define(%q({if @url}<a href={@url}>{end}{@text}{if @url}</a>{end}))
    assert_equal "plain", render(mod.demo(url: nil, text: "plain"))
    assert_equal %(<a href="/go">link</a>), render(mod.demo(url: "/go", text: "link"))
  end

  def test_nested_loops_and_conditionals
    mod = define(<<~HER)
      {@rows.each do |row|}{if row.any?}<tr>{row.each do |cell|}<td>{cell}</td>{end}</tr>{end}{end}
    HER
    assert_equal "<tr><td>1</td><td>2</td></tr><tr><td>3</td></tr>",
                 squish(mod.demo(rows: [[1, 2], [], [3]]))
  end

  def test_trailing_if_is_an_expression_hole
    mod = define("<p>{@name if @show}</p>")
    assert_equal "<p>Ana</p>", render(mod.demo(name: "Ana", show: true))
    assert_equal "<p></p>", render(mod.demo(name: "Ana", show: false))
  end

  def test_block_locals_are_not_assign_rewritten
    mod = define("{@pairs.each do |k, v|}<p>{k}={v}</p>{end}")
    assert_equal "<p>a=1</p>", render(mod.demo(pairs: { "a" => 1 }))
  end

  def test_begin_rescue_end
    # Note: output already written before an expression raises stays in the
    # buffer (streaming semantics, same as ERB) — so the rescue branch here
    # carries the whole <p> element.
    mod = define("{begin}{Integer(@raw)}{rescue ArgumentError}<p>bad</p>{end}")
    assert_equal "42", render(mod.demo(raw: "42"))
    assert_equal "<p>bad</p>", render(mod.demo(raw: "nope"))
  end

  def test_words_starting_with_keywords_are_expressions
    mod = define("<p>{@iffy}{@ending}{@case_count}</p>")
    assert_equal "<p>abc</p>", render(mod.demo(iffy: "a", ending: "b", case_count: "c"))
  end
end
