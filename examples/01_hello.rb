# frozen_string_literal: true

# The smallest possible HER program: one module, one component.
#
#   ruby -Ilib examples/01_hello.rb

require "her"

module UI
  extend Her::Component

  # `component` compiles the template ONCE, right here at load time, into a
  # plain module function `UI.greeting(assigns)`. Rendering is just calling
  # that method.
  component :greeting do
    template <<~'HER'
      <h1>Hello, {@name}!</h1>
    HER
  end
end

# Assigns are one hash; `{@name}` in the template reads assigns[:name].
puts UI.greeting(name: "world")
# => <h1>Hello, world!</h1>

# Escaping is automatic — user input cannot inject markup:
puts UI.greeting(name: "<script>alert(1)</script>")
# => <h1>Hello, &lt;script&gt;alert(1)&lt;/script&gt;!</h1>

# ...unless you explicitly mark something as trusted:
puts UI.greeting(name: Her.raw("<em>world</em>"))
# => <h1>Hello, <em>world</em>!</h1>

# Referencing an assign you did not pass is an error, never a silent blank:
begin
  UI.greeting({})
rescue Her::MissingAssign => e
  puts "!! #{e.message}"
  # => UI.greeting: missing assign :name (assigns given: none)
end
