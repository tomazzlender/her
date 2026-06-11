# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The example app's HER layer must keep working: boot file loads, every
# call site verifies, pages render. (The Sinatra layer itself needs the
# nested bundle and is exercised by running the app, not by this suite.)
class SinatraAppTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  APP = File.join(ROOT, "examples", "sinatra_app")

  def self.boot!
    @booted ||= begin
      require File.join(APP, "config", "boot")
      true
    end
  end

  def setup
    self.class.boot!
  end

  def test_components_verify
    assert Her.verify!(UI)
  end

  def test_projects_page_renders_a_full_document
    html = UI.projects_page(projects: [
      { id: 1, name: "HER & co", stars: 42, archived: false },
      { id: 2, name: "Dusty",    stars: 1,  archived: true }
    ]).to_s
    assert html.start_with?("<!DOCTYPE html>")
    assert_includes html, "HER &amp; co"                       # escaping
    assert_includes html, %(<span class="badge badge-active" data-stars="42">42 ★</span>)
    assert_includes html, %(<span class="badge badge-archived">archived</span>)
    assert_includes html, %(aria-current="page")               # smart attr
    assert_includes html, "Home / Projects"                    # slot override
    assert_includes html, "Served by the HER example app"      # slot fallback
    assert_includes html, "</html>"
  end

  def test_empty_state
    assert_includes UI.projects_page(projects: []).to_s, "No projects yet."
  end

  def test_contracts_are_live
    assert_raises(Her::MissingAttr) { UI.projects_page({}) }
    assert_raises(Her::InvalidAttr) { UI.badge(label: "x", kind: "sparkly") }
  end

  def test_sinatra_layer_is_at_least_valid_ruby
    %w[app.rb config.ru].each do |file|
      _, err, status = Open3.capture3(RbConfig.ruby, "-c", File.join(APP, file))
      assert status.success?, "#{file}: #{err}"
    end
  end

  def test_templates_load_under_a_non_utf8_locale
    # Locale-independence regression: template files are read as UTF-8 even
    # when the process locale is C/US-ASCII (common in containers) — the ★
    # in badge.html.her used to crash the frontmatter scanner.
    script = 'require_relative "examples/sinatra_app/config/boot"; ' \
             'print UI.badge(label: "ok").to_s.bytesize'
    out, err, status = Open3.capture3(
      { "LANG" => "C", "LC_ALL" => "C" },
      RbConfig.ruby, "-E", "US-ASCII", "-I", File.join(ROOT, "lib"), "-e", script,
      chdir: ROOT
    )
    assert status.success?, err
    assert_operator out.to_i, :>, 0
  end
end
