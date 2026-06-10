# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "her"
require "minitest/autorun"

module HerTestHelpers
  # A fresh anonymous module extended with the component DSL. Templates are
  # declared inline from the test file, so caller-relative lookups resolve
  # against test/.
  def component_module(&block)
    mod = Module.new
    mod.extend(Her::Component)
    mod.module_eval(&block) if block
    mod
  end

  def fixtures_path(*parts)
    File.join(__dir__, "fixtures", *parts)
  end

  def render(safe)
    assert_kind_of Her::Safe, safe
    safe.to_s
  end
end

Minitest::Test.include(HerTestHelpers)
