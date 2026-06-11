# frozen_string_literal: true

# HER performance harness. Run with:
#
#   ruby benchmark/bench.rb               # Prism engine (Ruby 3.3+)
#   HER_NO_PRISM=1 ruby benchmark/bench.rb
#
# Times compilation, rendering at several scales, verification, formatting
# and reloading. An escaped stdlib-ERB equivalent is included for one case
# as a league check — HER's pitch is the authoring model, not speed.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "her"
require "erb"
require "tmpdir"

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def time_once(label)
  t0 = clock
  yield
  puts format("  %-44s %8.1f ms", label, (clock - t0) * 1000)
end

def bench(label, iterations: nil)
  # warmup + auto-scale iterations to ~0.4s
  yield
  unless iterations
    t0 = clock
    n = 0
    while clock - t0 < 0.05
      yield
      n += 1
    end
    iterations = [(n / 0.05 * 0.4).to_i, 10].max
  end
  t0 = clock
  iterations.times { yield }
  elapsed = clock - t0
  puts format("  %-44s %10.0f ops/s   (%6.1f µs/op)",
              label, iterations / elapsed, elapsed / iterations * 1_000_000)
end

puts "HER #{Her::VERSION} — engine: #{Her::RubyScanner.prism? ? "prism" : "heuristic"} — #{RUBY_DESCRIPTION}"

# -- fixtures --------------------------------------------------------------------

CARD_TEMPLATE = <<~'HER'
  <div class="card" id={@id} {@rest}>
    <h2>{@title}</h2>
    {if @subtitle}
      <h3>{@subtitle}</h3>
    {end}
    <ul>
      {@items.each do |item|}
        <li class="item item-{item.size}">{item}</li>
      {end}
    </ul>
    <.button label={@cta} class="primary"/>
    {render_slot(:inner)}
  </div>
HER

module Bench
  extend Her::Component
  component :button do
    attr :label, :string, required: true
    attr :class, :string, default: "btn"
    template %(<button class={@class}>{@label}</button>)
  end
  component :typed do
    attr :count, :integer, required: true
    attr :kind, :string, default: "a"
    template "<i>{@count}{@kind}</i>"
  end
  component :valued do
    attr :count, :integer, required: true
    attr :kind, :string, values: %w[a b c], default: "a"
    template "<i>{@count}{@kind}</i>"
  end
  component :untyped do
    attr :count, required: true
    attr :kind, default: "a"
    template "<i>{@count}{@kind}</i>"
  end
  component :globaled do
    attr :rest, :global
    template "<i {@rest}>x</i>"
  end
  component :nest do
    template "<b>{if @n > 0}<.nest n={@n - 1}/>{else}leaf{end}</b>"
  end
  component :card do
    template CARD_TEMPLATE
  end
end

# -- compile ---------------------------------------------------------------------

puts "\nCompile (template -> defined method):"
fresh = -> { Module.new { extend Her::Component } }

time_once("tiny (1 element, 2 holes)") do
  100.times { |i| fresh.().component(:"b#{i}") { template %(<button class={@class}>{@label}</button>) } }
  print "  [x100] "
end

time_once("realistic card (14 lines)") do
  100.times { |i| fresh.().component(:"c#{i}") { template CARD_TEMPLATE } }
  print "  [x100] "
end

big_static = ("<section><h1>Title</h1><p>Some body text here.</p></section>\n" * 2000)
time_once("large static (2000 sections, 6000 elements)") do
  fresh.().component(:big) { template big_static }
end

hole_heavy = 1000.times.map { |i| "<p>{@a#{i % 10}}</p>" }.join("\n")
time_once("hole-heavy (1000 holes)") do
  fresh.().component(:holes) { template hole_heavy }
end

stmt_heavy = 500.times.map { |i| "{if @x}<p>#{i}</p>{end}" }.join("\n")
time_once("statement-heavy (500 if/end pairs)") do
  fresh.().component(:stmts) { template stmt_heavy }
end

time_once("module with 200 components") do
  m = fresh.()
  200.times { |i| m.component(:"comp#{i}") { template %(<div class="x"><p>{@v}</p><.comp#{(i + 1) % 200} v={@v}/></div>) } }
  $verify_target = m
end

deep = 1500
time_once("deeply nested (1500 levels)") do
  fresh.().component(:deep) { template ("<div>" * deep) + "x" + ("</div>" * deep) }
end

# -- render ----------------------------------------------------------------------

puts "\nRender (compiled method calls):"
small = fresh.()
small.component(:s) { template %(<button class={@class}>{@label}</button>) }
bench("tiny: 1 smart attr + 1 hole") { small.s(label: "Save", class: "btn") }

card_args = { id: "c1", title: "Hello <World>", subtitle: nil, cta: "Go",
              items: %w[alpha beta gamma delta], rest: { "data-x": "1" } }
bench("realistic card (loop of 4, nested component)") { Bench.card(card_args) { "inner" } }

items100 = Array.new(100) { |i| "item #{i} & co" }
loop_mod = fresh.()
loop_mod.component(:l) { template "<ul>{@items.each do |i|}<li>{i}</li>{end}</ul>" }
bench("loop over 100 escaped items") { loop_mod.l(items: items100) }

items10k = Array.new(10_000) { |i| "item #{i} & co" }
bench("loop over 10_000 escaped items", iterations: 30) { loop_mod.l(items: items10k) }

bench("nested components, depth 50") { Bench.nest(n: 50) }

count = 0
bench("typed attrs (inlined type guards)") { Bench.typed(count: (count += 1), kind: "b") }
bench("typed attrs + values: (helper path)") { Bench.valued(count: (count += 1), kind: "b") }
bench("same shape, untyped (no guards)") { Bench.untyped(count: (count += 1), kind: "b") }
bench("global attr collection") { Bench.globaled("data-a": "1", "data-b": "2", id: "x") }

# ERB league check: same 100-item loop, escaped, precompiled
erb_src = "<ul><% items.each do |i| %><li><%= ERB::Util.html_escape(i) %></li><% end %></ul>"
erb_renderer = Class.new do
  erb = ERB.new(erb_src)
  erb.def_method(self, "render(items)")
end.new
bench("stdlib ERB, same 100-item escaped loop") { erb_renderer.render(items100) }

# -- verify / format / reload -------------------------------------------------------

puts "\nTooling:"
time_once("Her.verify on 200 components, 200 call sites") { Her.verify($verify_target) }

fmt_source = (["<div class=\"wrap\">"] +
              200.times.map { |i| "<section>\n<h2>{@t#{i % 7}}</h2>\n{if @on}\n<p>body #{i}</p>\n{end}\n</section>" } +
              ["</div>"]).join("\n") + "\n"
time_once("format a #{fmt_source.lines.size}-line template") { Her::Formatter.format(fmt_source) }

Dir.mktmpdir do |dir|
  100.times { |i| File.write(File.join(dir, "t#{i}.html.her"), "<p>{@x} in template #{i}</p>\n") }
  reload_mod = fresh.()
  reload_mod.embed_templates("*.html.her", dir: dir)
  time_once("reload_templates! over 100 file templates") { Her.reload_templates!(reload_mod) }
end

puts "\nOutput sizes: card=#{Bench.card(card_args) { "x" }.to_s.bytesize}B, " \
     "10k-loop=#{loop_mod.l(items: items10k).to_s.bytesize}B"
