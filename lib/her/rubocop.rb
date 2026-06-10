# frozen_string_literal: true

require "rubocop"

module RuboCop
  module Cop
    module Her
      # Flags `template` arguments that Ruby interpolates at definition
      # time — before HER ever sees the template. `template <<~HER` with a
      # `#{...}` inside silently evaluates the interpolation when the Ruby
      # file loads (usually to nil/empty); the template must reach HER
      # verbatim.
      #
      #   # bad — #{@kind} evaluates at load time, not at render time
      #   template <<~HER
      #     <div class={"alert alert-#{@kind}"}>{@message}</div>
      #   HER
      #
      #   # good
      #   template <<~'HER'
      #     <div class={"alert alert-#{@kind}"}>{@message}</div>
      #   HER
      #
      # Opt in via .rubocop.yml:
      #
      #   require:
      #     - her/rubocop
      class TemplateInterpolation < Base
        MSG = "This template interpolates \#{...} when the Ruby file loads, before HER " \
              "compiles it — use a single-quoted heredoc (<<~'HER') or %q(...) so the " \
              "template reaches HER verbatim."

        RESTRICT_ON_SEND = %i[template].freeze

        def on_send(node)
          return unless node.receiver.nil? && node.arguments.one?

          argument = node.first_argument
          add_offense(argument) if argument.dstr_type?
        end
      end
    end
  end
end
