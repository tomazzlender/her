# frozen_string_literal: true

# Control flow: statement holes are plain Ruby compiled into the method
# body — if/elsif/else, each, case/when, the conditional-wrapper pattern,
# and the capture form for block-wrapping helpers.
#
#   ruby -Ilib examples/05_control_flow.rb

require "her"

module UI
  extend Her::Component

  component :status do
    attr :score, :integer, required: true
    template <<~'HER'
      {if @score >= 90}
        <strong>Excellent</strong>
      {elsif @score >= 50}
        <em>Passable</em>
      {else}
        <span>Needs work</span>
      {end}
    HER
  end

  component :menu do
    attr :entries, :array, required: true
    template <<~'HER'
      <ul>
        {@entries.each_with_index do |entry, i|}
          <li data-pos={i}>{entry}</li>
        {end}
      </ul>
    HER
  end

  component :greeting do
    attr :lang, :string, default: "en"
    template <<~'HER'
      {case @lang}
      {when "sl"}<p>Živjo!</p>
      {when "de"}<p>Hallo!</p>
      {else}<p>Hello!</p>
      {end}
    HER
  end

  # The conditional wrapper HEEx rejects: a tag that opens in one branch
  # and closes in another. Tags balance lexically, so this compiles.
  component :maybe_link do
    attr :text, :string, required: true
    attr :href # nil renders plain text
    template <<~'HER'
      {if @href}<a href={@href}>{end}{@text}{if @href}</a>{end}
    HER
  end

  # Capture form: {= helper do}...{end} builds the children into a string
  # the block returns, and appends the HELPER'S return value — for
  # form-builder-style helpers that wrap their content.
  def self.fieldset(legend)
    Her.raw("<fieldset><legend>#{Her.safe(legend)}</legend>#{Her.safe(yield)}</fieldset>")
  end

  component :signup do
    template <<~'HER'
      {= fieldset("Sign #{@verb}") do}
        <input name="email" type="email">
      {end}
    HER
  end
end

puts UI.status(score: 97)
puts UI.status(score: 12)
puts UI.menu(entries: ["alpha", "beta & friends"])
puts UI.greeting(lang: "sl")
puts UI.maybe_link(text: "plain")
puts UI.maybe_link(text: "linked", href: "/go")
puts UI.signup(verb: "up")
