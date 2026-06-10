# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Phase 5 (§7): error quality. Every failure mode names the component and
# points at the author's source.
class ErrorsTest < Minitest::Test
  def parse_error(template_src)
    assert_raises(Her::ParseError) do
      component_module do
        component :demo do
          template template_src
        end
      end
    end
  end

  def compile_error(template_src)
    assert_raises(Her::CompileError) do
      component_module do
        component :demo do
          template template_src
        end
      end
    end
  end

  # -- malformed templates (§7.2) ---------------------------------------------

  def test_unclosed_tag_reports_name_and_location
    error = parse_error("<div>\n  <button>oops\n")
    assert_match(/unclosed tag <button>/, error.message)
    assert_match(/#{Regexp.escape(__FILE__)}:\d+/, error.message)
  end

  def test_mismatched_close_names_both_tags_and_open_location
    error = parse_error("<div><span>x</div></span>")
    assert_match(/mismatched closing tag <\/div> — expected <\/span>/, error.message)
    assert_match(/opened at/, error.message)
  end

  def test_stray_close_tag
    error = parse_error("hello</p>")
    assert_match(%r{closing tag </p> without a matching open tag}, error.message)
  end

  def test_void_element_close_is_an_error
    error = parse_error("<br></br>")
    assert_match(/void element <br> cannot have a closing tag/, error.message)
  end

  def test_unclosed_hole
    error = parse_error("<p>{@x")
    assert_match(/unclosed interpolation `\{`/, error.message)
  end

  def test_empty_hole
    error = parse_error("<p>{}</p>")
    assert_match(/empty interpolation/, error.message)
    assert_match(/&#123;/, error.message)
  end

  def test_unclosed_attribute_value
    error = parse_error(%(<p class="btn>x</p>))
    assert_match(/unclosed attribute value/, error.message)
  end

  def test_unclosed_script
    error = parse_error("<script>let a = 1;")
    assert_match(%r{unclosed <script> — expected </script>}, error.message)
  end

  def test_unclosed_comment
    error = parse_error("<!-- never ends")
    assert_match(/unclosed HTML comment/, error.message)
  end

  def test_erb_tags_are_rejected_with_guidance
    error = parse_error("<p><% puts 1 %></p>")
    assert_match(/ERB-style <% tags are not supported/, error.message)
  end

  def test_uppercase_tag_without_function_part
    error = parse_error("<Button>x</Button>")
    assert_match(/must be a qualified component call/, error.message)
  end

  def test_parse_error_line_numbers_offset_into_inline_heredocs
    declaration_line = nil
    error = assert_raises(Her::ParseError) do
      component_module do
        declaration_line = __LINE__ + 1
        component :demo do
          template <<~HER
            <p>fine</p>
            <div>
          HER
        end
      end
    end
    # The heredoc body starts two lines below `component :demo do`;
    # the unclosed <div> sits on its second line.
    assert_equal declaration_line + 3, error.line
    assert_equal __FILE__, error.file
  end

  def test_parse_error_line_numbers_in_template_files
    error = assert_raises(Her::ParseError) do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "broken.html.her"), "<p>ok</p>\n<div>\n")
        mod = component_module {}
        mod.embed_templates("*.html.her", dir: dir)
      end
    end
    assert_equal 2, error.line
    assert_match(/broken\.html\.her/, error.file)
  end

  # -- bad Ruby in holes (§7.3) --------------------------------------------------

  def test_name_error_backtrace_points_at_template_file_and_line
    error = assert_raises(NameError) do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "typo.html.her"), "<p>fine</p>\n<p>{no_such_helper}</p>\n")
        mod = component_module {}
        mod.embed_templates("*.html.her", dir: dir)
        mod.typo
      end
    end
    assert_match(/typo\.html\.her:2/, error.backtrace.first)
  end

  def test_unbalanced_control_flow_is_a_mapped_compile_error
    error = compile_error("{if @x}<p>tags balance, flow does not</p>")
    assert_match(/invalid Ruby generated for/, error.message)
    assert_match(/control-flow holes/, error.message)
  end

  def test_statement_hole_in_attribute_is_rejected
    error = compile_error("<p class={if @x}>x</p>")
    assert_match(/control-flow statements are not allowed in attribute/, error.message)
  end

  def test_bad_let_is_rejected
    error = assert_raises(Her::CompileError) do
      component_module do
        component :inner do
          template "<p><:col/></p>"
        end
        component :demo do
          template %(<.inner><:col let="nope">x</:col></.inner>)
        end
      end
    end
    assert_match(/`let` must be/, error.message)
  end

  def test_slot_def_with_unknown_attr_is_rejected
    error = assert_raises(Her::CompileError) do
      component_module do
        component :inner do
          template "<p><:col/></p>"
        end
        component :demo do
          template "<.inner><:col if={@x}>x</:col></.inner>"
        end
      end
    end
    assert_match(/only accepts a `let` attribute/, error.message)
  end

  def test_slot_render_with_attrs_is_rejected
    error = compile_error("<p><:icon size={@s}/></p>")
    assert_match(/takes no attributes/, error.message)
    assert_match(/render_slot\(:icon, args\.\.\.\)/, error.message)
  end

  def test_duplicate_component_attr_is_rejected
    error = parse_error("<.x label=\"a\" label=\"b\"/>")
    assert_match(/duplicate attribute `label`/, error.message)
  end

  # -- missing attr / assign messages (§7.1) ---------------------------------------

  def test_missing_attr_message_shape
    mod = component_module do
      component :button do
        attr :label, required: true
        template "<b>{@label}</b>"
      end
    end
    error = assert_raises(Her::MissingAttr) { mod.button }
    assert_match(/\A#{Regexp.escape(Her.module_label(mod))}\.button: missing required attribute :label\z/,
                 error.message)
  end

  def test_missing_assign_lists_given_keys
    mod = component_module do
      component :free do
        template "<p>{@a}{@b}</p>"
      end
    end
    error = assert_raises(Her::MissingAssign) { mod.free(a: 1, c: 3) }
    assert_match(/missing assign :b \(assigns given: :a, :c\)/, error.message)
  end

  def test_missing_assign_with_no_assigns
    mod = component_module do
      component :free do
        template "<p>{@a}</p>"
      end
    end
    error = assert_raises(Her::MissingAssign) { mod.free }
    assert_match(/assigns given: none/, error.message)
  end
end
