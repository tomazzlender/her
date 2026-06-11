# frozen_string_literal: true

require_relative "test_helper"
require "her/cli"
require "tmpdir"
require "open3"

# A named module so `her source` can const_get it.
module CliFixtureUI
  extend Her::Component
  component :chip do
    attr :text, :string, required: true
    template "<span>{@text}</span>"
  end
end

class CliTest < Minitest::Test
  def run_cli(*argv)
    status = nil
    out, err = capture_io { status = Her::CLI.run(argv) }
    [status, out, err]
  end

  def test_version
    status, out, = run_cli("version")
    assert_equal 0, status
    assert_equal "#{Her::VERSION}\n", out
  end

  def test_usage_on_unknown_command
    status, _, err = run_cli("wat")
    assert_equal 2, status
    assert_match(/Usage: her/, err)
  end

  def test_fmt_rewrites_files_and_reports
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.her")
      File.write(path, "<div>\n<p>x</p>\n</div>\n")
      status, out, = run_cli("fmt", path)
      assert_equal 0, status
      assert_match(/reformatted #{Regexp.escape(path)}/, out)
      assert_equal "<div>\n  <p>x</p>\n</div>\n", File.read(path)

      status, out, = run_cli("fmt", path) # second run: nothing to do
      assert_equal 0, status
      assert_empty out
    end
  end

  def test_fmt_check_mode_exits_one_without_writing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.her")
      File.write(path, "<div>\n<p>x</p>\n</div>\n")
      status, out, = run_cli("fmt", "--check", path)
      assert_equal 1, status
      assert_match(/would reformat/, out)
      assert_equal "<div>\n<p>x</p>\n</div>\n", File.read(path)
    end
  end

  def test_fmt_expands_directories
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "a.her"), "<div>\n<p>x</p>\n</div>\n")
      File.write(File.join(dir, "b.html.her"), "<i>ok</i>\n")
      status, out, = run_cli("fmt", dir)
      assert_equal 0, status
      assert_match(/a\.her/, out)
    end
  end

  def test_fmt_reports_parse_errors_with_exit_two
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.her")
      File.write(path, "<div>\n")
      status, _, err = run_cli("fmt", path)
      assert_equal 2, status
      assert_match(/unclosed tag/, err)
    end
  end

  # `her check` verifies every component module in the process, so it must
  # run as the subprocess it really is (in-process it would sweep up other
  # tests' deliberately broken fixture modules).
  def run_exe(*argv)
    exe = File.expand_path("../exe/her", __dir__)
    lib = File.expand_path("../lib", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, exe, *argv)
    [status.exitstatus, out, err]
  end

  def test_check_runs_verify
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "app.rb"), <<~RUBY)
        require "her"
        module CliCheckApp
          extend Her::Component
          component :good do
            template "<p>fine</p>"
          end
        end
      RUBY
      status, out, = run_exe("check", "-r", File.join(dir, "app.rb"))
      assert_equal 0, status
      assert_match(/ok: \d+ component/, out)
    end
  end

  def test_check_fails_on_verify_errors
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "bad_app.rb"), <<~RUBY)
        require "her"
        module CliCheckBadApp
          extend Her::Component
          component :caller do
            template "<.does_not_exist/>"
          end
        end
      RUBY
      status, _, err = run_exe("check", "-r", File.join(dir, "bad_app.rb"))
      assert_equal 1, status
      assert_match(/does_not_exist/, err)
    end
  end

  def test_source_prints_generated_code
    status, out, = run_cli("source", "CliFixtureUI.chip")
    assert_equal 0, status
    assert_match(/def self\.chip\(assigns = \{\}/, out)
  end

  def test_source_unknown_component
    status, _, err = run_cli("source", "CliFixtureUI.nope")
    assert_equal 1, status
    assert_match(/no component/, err)
  end
end
