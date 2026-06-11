# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Template frontmatter (§12): <%# attr ... %> declarations give file-based
# (and inline) templates the same contract tier as component blocks.
class FrontmatterTest < Minitest::Test
  def embed(files)
    Dir.mktmpdir do |dir|
      files.each { |name, content| File.write(File.join(dir, name), content) }
      mod = component_module {}
      mod.embed_templates("*.html.her", dir: dir)
      yield mod, dir
    end
  end

  BADGE = <<~'HER'
    <%# A badge. Plain description comments are fine alongside attrs. %>
    <%# attr :label, :string, required: true %>
    <%#
      attr :kind, :string, values: %w[info warn], default: "info"
      attr :rest, :global
    %>
    <span class="badge-{@kind}" {@rest}>{@label}</span>
  HER

  def test_frontmatter_gives_embedded_templates_a_full_contract
    embed("badge.html.her" => BADGE) do |mod, _dir|
      assert_equal %(<span class="badge-info" data-id="9">Hi</span>\n),
                   render(mod.badge(label: "Hi", "data-id": "9"))

      error = assert_raises(Her::MissingAttr) { mod.badge({}) }
      assert_match(/missing required attribute :label/, error.message)

      error = assert_raises(Her::InvalidAttr) { mod.badge(label: "x", kind: "festive") }
      assert_match(/allowed values: "info", "warn"/, error.message)

      assert_raises(Her::InvalidAttr) { mod.badge(label: 42) }
    end
  end

  def test_frontmatter_output_has_no_leading_blank_lines
    embed("badge.html.her" => BADGE) do |mod, _dir|
      assert render(mod.badge(label: "x")).start_with?("<span")
    end
  end

  def test_undeclared_references_fail_at_load_with_frontmatter
    error = assert_raises(Her::CompileError) do
      embed("typo.html.her" => "<%# attr :label, required: true %>\n<b>{@labl}</b>\n") {}
    end
    assert_match(/references undeclared attr @labl/, error.message)
  end

  def test_verify_checks_call_sites_against_frontmatter_contracts
    embed("badge.html.her" => BADGE) do |mod, _dir|
      mod.component :caller do
        template %q(<.badge kind="nope"/>)
      end
      types = Her.verify(mod).map(&:type).sort
      assert_equal %i[attr_value missing_required_attr], types
    end
  end

  def test_reload_picks_up_edited_frontmatter
    embed("badge.html.her" => BADGE) do |mod, dir|
      File.write(File.join(dir, "badge.html.her"),
                 "<%# attr :label, :string, required: true %>\n" \
                 "<%# attr :tone, :string, required: true %>\n" \
                 "<span>{@label}/{@tone}</span>\n")
      Her.reload_templates!(mod)
      assert_equal "<span>a/b</span>\n", render(mod.badge(label: "a", tone: "b"))
      error = assert_raises(Her::MissingAttr) { mod.badge(label: "a") }
      assert_match(/:tone/, error.message)
    end
  end

  def test_sibling_file_component_takes_contract_from_frontmatter
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "chip.html.her"),
                 "<%# attr :text, :string, required: true %>\n<i>{@text}</i>\n")
      mod = component_module {}
      mod.component(:chip, dir: dir)
      assert_equal "<i>x</i>\n", render(mod.chip(text: "x"))
      assert_raises(Her::MissingAttr) { mod.chip }
    end
  end

  def test_block_attrs_and_frontmatter_conflict_is_an_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "chip.html.her"),
                 "<%# attr :text, required: true %>\n<i>{@text}</i>\n")
      error = assert_raises(Her::CompileError) do
        mod = component_module {}
        mod.component(:chip, dir: dir) do
          attr :text, required: true
        end
      end
      assert_match(/both in the component block and in the template frontmatter/, error.message)
    end
  end

  def test_inline_templates_accept_frontmatter_too
    mod = component_module do
      component :note do
        template <<~'HER'
          <%# attr :body, :string, required: true %>
          <p>{@body}</p>
        HER
      end
    end
    assert_equal "<p>n</p>\n", render(mod.note(body: "n"))
    assert_raises(Her::MissingAttr) { mod.note }
  end

  def test_misplaced_declarations_are_rejected_with_location
    error = assert_raises(Her::CompileError) do
      embed("late.html.her" => "<p>hi</p>\n<%# attr :x %>\n") {}
    end
    assert_match(/must appear at the top of the template/, error.message)
    assert_match(/late\.html\.her:2/, error.message)
  end

  def test_invalid_declaration_reports_file_and_line
    error = assert_raises(Her::CompileError) do
      embed("bad.html.her" => "<%# attr :x, :strnig %>\n<p>{@x}</p>\n") {}
    end
    assert_match(/unknown type :strnig/, error.message)
    assert_match(/bad\.html\.her:1/, error.message)
  end

  def test_broken_ruby_in_frontmatter_reports_file_and_line
    error = assert_raises(Her::CompileError) do
      embed("broken.html.her" => "<%# attr :x, %>\n<p>{@x}</p>\n") {}
    end
    assert_match(/invalid frontmatter at .*broken\.html\.her:1/, error.message)
  end

  def test_template_call_in_frontmatter_is_rejected
    error = assert_raises(Her::CompileError) do
      embed("sneaky.html.her" => "<%# attr :x; template \"<b>no</b>\" %>\n<p>{@x}</p>\n") {}
    end
    assert_match(/frontmatter can only declare attrs/, error.message)
  end

  def test_templates_without_frontmatter_may_not_reference_assigns
    error = assert_raises(Her::CompileError) do
      embed("plain.html.her" => "<p>{@x}</p>\n") {}
    end
    assert_match(/references undeclared attr @x/, error.message)
    assert_match(/declares no attrs/, error.message)
  end

  def test_comment_only_lines_are_trimmed_from_output
    mod = component_module do
      component :demo do
        template "<%# top note %>\n<p>x</p>\n<%# tail note %>\n"
      end
    end
    assert_equal "<p>x</p>\n", render(mod.demo)
  end

  def test_comments_sharing_a_line_with_content_keep_the_line
    mod = component_module do
      component :demo do
        template "<p><%# inline %>x</p>"
      end
    end
    assert_equal "<p>x</p>", render(mod.demo)
  end
end
