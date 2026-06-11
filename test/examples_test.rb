# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The examples/ directory is living documentation: every script must run
# clean, so the docs cannot rot.
class ExamplesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SCRIPTS = (Dir[File.join(ROOT, "examples", "*.rb")] +
             Dir[File.join(ROOT, "examples", "*", "run.rb")]).sort

  def run_example(script)
    Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), script)
  end

  def test_examples_exist
    assert_operator SCRIPTS.size, :>=, 7
  end

  SCRIPTS.each do |script|
    name = script.delete_prefix("#{ROOT}/examples/").gsub(/\W+/, "_")
    define_method("test_example_#{name}") do
      out, err, status = run_example(script)
      assert status.success?, "#{script} failed:\n#{err}"
      assert_empty err, "#{script} wrote to stderr:\n#{err}"
      refute_empty out, "#{script} produced no output"
    end
  end

  def test_full_page_renders_a_complete_document
    out, = run_example(File.join(ROOT, "examples", "07_full_page.rb"))
    assert out.start_with?("<!DOCTYPE html>")
    assert_includes out, "Example &amp; Co"          # escaping
    assert_includes out, 'aria-current="page"'       # smart attribute
    assert_includes out, '<article class="card" data-id="1">' # splat
    assert_includes out, "<em>archived</em>"         # branch
    assert_includes out, "Made with HER"             # slot override
    assert_includes out, "</html>"
  end
end
