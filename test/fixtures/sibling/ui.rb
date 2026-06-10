# frozen_string_literal: true

# Fixture exercising sibling-file template resolution: `component` with no
# inline template loads ./fancy_button.html.her relative to THIS file.
module SiblingUI
  extend Her::Component

  component :fancy_button do
    attr :label, required: true
  end
end
