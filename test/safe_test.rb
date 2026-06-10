# frozen_string_literal: true

require_relative "test_helper"

# Phase 0 (§5): the escaping core everything else depends on.
class SafeTest < Minitest::Test
  def test_escapes_html_metacharacters
    assert_equal "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;", Her.safe(%(<a href="x">&'</a>))
  end

  def test_escapes_non_strings_via_to_s
    assert_equal "42", Her.safe(42)
    assert_equal "", Her.safe(nil)
    assert_equal "1.5", Her.safe(1.5)
  end

  def test_safe_values_pass_through_untouched
    trusted = Her::Safe.new("<b>bold</b>")
    assert_equal "<b>bold</b>", Her.safe(trusted)
  end

  def test_safe_returns_plain_string
    assert_instance_of String, Her.safe(Her::Safe.new("<b>"))
    assert_instance_of String, Her.safe("<b>")
  end

  def test_raw_marks_trusted
    assert_equal "<i>x</i>", Her.safe(Her.raw("<i>x</i>"))
  end

  def test_raw_of_safe_is_identity
    trusted = Her::Safe.new("<b>")
    assert_same trusted, Her.raw(trusted)
  end

  def test_no_double_escaping_when_nesting
    inner = Her::Safe.new(Her.safe("<script>alert(1)</script>"))
    # Embedding the already-escaped inner fragment must not escape again.
    assert_equal "&lt;script&gt;alert(1)&lt;/script&gt;", Her.safe(inner)
  end

  def test_safe_to_str_allows_string_concat
    assert_equal "x<b>", +"x" << Her::Safe.new("<b>")
  end

  def test_safe_plus_escapes_untrusted_and_stays_safe
    sum = Her::Safe.new("<b>") + "<i>"
    assert_kind_of Her::Safe, sum
    assert_equal "<b>&lt;i&gt;", sum.to_s
  end

  def test_safe_equality
    assert_equal Her::Safe.new("a"), Her::Safe.new("a")
    refute_equal Her::Safe.new("a"), "a"
  end

  def test_attr_pair_smart_semantics
    assert_equal "", Her.attr_pair("disabled", nil)
    assert_equal "", Her.attr_pair("disabled", false)
    assert_equal " disabled", Her.attr_pair("disabled", true)
    assert_equal %( class="a &amp; b"), Her.attr_pair("class", "a & b")
  end

  def test_splat_attrs
    out = Her.splat_attrs({ id: "x", hidden: true, skipped: nil, "data-v": "1<2" })
    assert_equal %( id="x" hidden data-v="1&lt;2"), out
    assert_equal "", Her.splat_attrs(nil)
  end
end
