# frozen_string_literal: true

require_relative "test_helper"

begin
  require "her/rubocop"
  HER_RUBOCOP_AVAILABLE = true
rescue LoadError
  HER_RUBOCOP_AVAILABLE = false
end

# The opt-in RuboCop cop catching the heredoc-interpolation trap.
class RubocopCopTest < Minitest::Test
  def offenses_for(source)
    skip "rubocop not installed" unless HER_RUBOCOP_AVAILABLE
    config = RuboCop::Config.new
    cop = RuboCop::Cop::Her::TemplateInterpolation.new(config)
    team = RuboCop::Cop::Team.new([cop], config, raise_error: true)
    processed = RuboCop::ProcessedSource.new(source, RUBY_VERSION.to_f.round(1))
    team.investigate(processed).offenses
  end

  def test_flags_interpolating_heredoc
    offenses = offenses_for(<<~'RUBY')
      component :alert do
        template <<~HER
          <div class={"alert-#{@kind}"}>x</div>
        HER
      end
    RUBY
    assert_equal 1, offenses.size
    assert_match(/interpolates .* when the Ruby file loads/, offenses.first.message)
  end

  def test_flags_interpolating_inline_string
    offenses = offenses_for('template "<p>#{@x}</p>"')
    assert_equal 1, offenses.size
  end

  def test_allows_single_quoted_heredoc
    offenses = offenses_for(<<~'RUBY')
      template <<~'HER'
        <div class={"alert-#{@kind}"}>x</div>
      HER
    RUBY
    assert_empty offenses
  end

  def test_allows_plain_strings_and_percent_q
    assert_empty offenses_for('template %q(<p>{@x}</p>)')
    assert_empty offenses_for('template "<p>{@x}</p>"')
  end

  def test_ignores_template_calls_on_receivers
    assert_empty offenses_for('mailer.template "a#{b}"')
  end
end
