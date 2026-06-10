# HER — HTML Embedded Ruby

A view library for Ruby. Templates are written as **real HTML** with embedded Ruby
expressions, and each template is compiled **once at load time** into a plain module
function. Rendering is then just a fast method call that takes a hash of values and
returns an escaped HTML string.

HER is the Ruby sibling of Elixir's HEEx (`Phoenix.Component`): the same
"HTML-aware template compiled to a function-component" model, adapted to Ruby
idioms. The name follows the lineage — ERB (Embedded Ruby), HEEx (HTML +
Embedded Elixir), HER (HTML Embedded Ruby).

```ruby
module UI
  extend Her::Component

  component :button do
    attr :label, required: true
    attr :class, default: "btn"
    template %(<button class={@class}>{@label}</button>)
  end

  component :card do
    attr :title, required: true
    template <<~'HER'
      <div class="card">
        <h2>{@title}</h2>
        <.button label="Dismiss" class="btn ghost"/>
        {render_slot(:inner)}
      </div>
    HER
  end
end

UI.button(label: "Save", class: "btn primary")
# => <button class="btn primary">Save</button>

UI.card(title: "Welcome") { UI.button(label: "Get started") }
# => <div class="card"><h2>Welcome</h2>
#    <button class="btn ghost">Dismiss</button>
#    <button class="btn">Get started</button></div>

UI.button(class: "btn")
# => raises Her::MissingAttr: UI.button: missing required attribute :label
```

## Why

The Ruby view space forces a choice HER refuses. Phlex gives function-like
ergonomics but makes you abandon HTML for a Ruby DSL. ViewComponent keeps HTML
but binds it to a class instance, with no in-template component-call syntax and
no template-level contract. HER combines what no mainstream Ruby library does:

- **real HTML templates** — a designer who knows HTML can read and edit them
- **module-function components** — `UI.button(assigns)`, no classes, no lifecycle
- **`<.component/>` composition** — components call components inside templates
- **declared attr contracts** — required/default attrs, enforced with good errors
- **safe by default** — automatic escaping that composes without double-escaping

The pitch is the authoring model, not speed. (Compiled templates are plenty fast —
each render is one method call appending frozen string literals — but so are
Erubi and Phlex; template rendering is rarely your bottleneck.)

## Installation

```ruby
gem "her", github: "tomazzlender/her"
```

Requires Ruby >= 3.1. No hard runtime dependencies: on Ruby 3.3+ HER uses
the bundled Prism parser to analyze the Ruby inside `{...}` holes; on
3.1/3.2 add `gem "prism"` to get the same, or HER falls back to a small
built-in scanner (see Limitations).

## The two definition forms

Both compile to the same thing — a public module function taking one assigns
hash — and differ only in how the template is supplied. They mirror Phoenix's
`def ... ~H` and `embed_templates`.

### `component` — one-to-one

```ruby
module UI
  extend Her::Component

  # inline template
  component :alert do
    attr :message, required: true
    attr :kind, default: "info"
    template <<~'HER'
      <div class={"alert alert-#{@kind}"}>{@message}</div>
    HER
  end

  # sibling-file template: no inline `template` block means
  # ./button.html.her (next to this .rb file) is compiled into UI.button
  component :button do
    attr :label, required: true
    attr :class, default: "btn"
  end
end
```

> **Heredoc gotcha:** use a *single-quoted* heredoc (`<<~'HER'`) or `%q(...)`
> for inline templates that contain Ruby string interpolation. With a plain
> `<<~HER`, Ruby evaluates `#{@kind}` at definition time — before HER ever
> sees the template.

### `embed_templates` — directory glob

```ruby
module UI
  extend Her::Component
  embed_templates "components/*.html.her"   # relative to this file's directory
end
```

`components/button.html.her` → `UI.button`; `components/user_card.html.her` →
`UI.user_card`. Basename verbatim, `.html.her` suffix stripped. Pass `dir:` to
override the base directory.

### Contracts differ between the two — by design

- **`embed_templates` is contract-free**, exactly like Phoenix. The template's
  body is its contract: whatever `@foo` it references is what it needs.
  Referencing a missing assign **raises** `Her::MissingAssign` at render time
  (naming the component, the assign, and the keys you did pass) — it never
  silently renders `nil`.
- **`component` adds an optional declared-attr tier.** Declaring any `attr`
  opts in: required attrs are checked on entry (`Her::MissingAttr`), defaults
  are merged, and referencing an *undeclared* `@attr` fails **at load time**
  with a message telling you what to declare. A `component` block with no
  `attr` declarations stays contract-free.

### Collision rule

If a glob and an explicit `component` would define the same name, **explicit
wins** regardless of order — so you can override one globbed template with a
hand-contracted one. HER also refuses to overwrite methods it didn't define:
a stray `name.html.her` will not silently clobber `Module#name`; you get a
load-time error telling you to rename it.

## Calling convention (locked)

**Assigns is a single hash, not keyword arguments.** HTML attribute names
collide with Ruby reserved words — `class`, `for`, `end` are illegal as
keyword arguments, and `data-id` isn't an identifier at all. As hash keys
they're all fine. Trailing-hash sugar keeps call sites clean:

```ruby
UI.button(label: "Save", class: "btn primary", "data-id": "x")
```

**`@foo` is template syntax, not an instance variable.** The compiler rewrites
`@label` → `assigns[:label]` (or a strict fetch for contract-free templates)
when it generates the method body. There is no object, no `instance_variable_get`,
no binding magic. The rewrite understands string literals, so
`{"alert alert-#{@kind}"}` works while `{"contact: hi@example.com"}` is left alone.

Inside a hole you can also use `assigns` directly (`{assigns[:class]}`) — handy
for dynamic keys. Bare method calls in holes resolve against your module, so
`{format_date(@at)}` calls `UI.format_date`.

## Template syntax

### Interpolation: `{...}` holes

```her
<p>{@user_name}</p>
<p>{@price * 1.22}</p>
<p>{format_date(@at)}</p>
```

Hole results are HTML-escaped unless already trusted (see Escaping). The
contents are plain Ruby. With Prism available (Ruby 3.3+), hole code is
analyzed by the real Ruby parser: invalid expressions fail at load time with
the parser's own message pointing at the template line, assigns are enforced
read-only (`{@x = 1}` is a load error), and exotic literals (`%q[}]`,
regexps, heredocs) terminate holes correctly. A complete `if ... end`
expression in a hole renders its value; keyword *fragments* are control-flow
statements (below).

Two brace styles coexist by necessity: `{@x}` is a HER hole; `#{x}` is Ruby's
own interpolation *inside a Ruby string inside a hole*:

```her
<div class={"alert alert-#{@kind}"}>...</div>
```

Literal braces in text: use `&#123;` / `&#125;`, or `{"{"}`, or `her-no-curly`
(below). Inside `<script>`/`<style>` braces are already literal.

### Attributes

```her
<button class="btn">              literal — passed through verbatim
<button class={@class}>           smart: nil/false omit, true renders bare,
                                  anything else renders class="escaped value"
<button class="btn btn-{@kind}">  partial interpolation — mixed literal + holes
<button disabled>                 boolean attribute
<div {@rest}>                     splat: each key/value with smart semantics
```

Smart attributes make conditional attributes trivial: `aria-current={@active && "page"}`
renders nothing when inactive. The splat form merges in source order — later
attributes win — and ignores `nil` hashes.

### Components

```her
<.button label="Save"/>                    local: calls self.button(...)
<.button label={@text} class="x"/>         dynamic values are Ruby values
<UI::Icons.star name="x"/>                 qualified: calls UI::Icons.star(...)
<.card title="Hi">children...</.card>      children become the :inner slot
```

Attribute values on component calls are *values*, not HTML — escaping happens
exactly once, inside the called component. A bare attribute passes `true`.
Splats work here too: `<.button {@opts}/>`.

Qualified names resolve with standard Ruby constant lookup from the defining
module. Sibling modules nested in the same namespace need qualification from
the root (e.g. `<App::Icons.star/>`), because string-eval'd methods don't
inherit lexical nesting.

### Slots

```her
<%# inside a component's own template: render slots %>
<header><:title>Untitled</:title></header>     render :title, with fallback
<main>{render_slot(:inner)}</main>             function form, default slot
{if slot?(:footer)}<footer><:footer/></footer>{end}

<%# at a call site: direct slot children define slots %>
<.layout>
  <:title><b>My page</b></:title>
  everything else is the :inner slot
</.layout>
```

From Ruby, the block is the `:inner` slot: `UI.layout { "body" }`. A slot
defined multiple times renders concatenated, in order. `render_slot` returns
`nil` when the slot wasn't provided, so `{render_slot(:x) || "default"}` works.

Slot arguments flow through `render_slot(:item, value)` and bind via `let`:

```her
<%# list.html.her %>
<ul>{@items.each do |item|}<li>{render_slot(:item, item)}</li>{end}</ul>

<%# caller %>
<.list items={@users}>
  <:item let={user}><b>{user.name}</b></:item>
</.list>
```

`let={x}` on the component tag itself binds default-slot arguments. From Ruby,
block parameters do the same: `UI.list(items: xs) { |x| "row #{x}" }`.

Slot renders resolve *lexically*: a `<:icon/>` written in template A renders
A's `:icon` slot even when it appears inside children passed to another
component. The mechanism is plain data flow — each compiled component
receives a slots hash, `render_slot(...)` in a hole is rewritten at compile
time to pass it along, and content blocks close over the slots of the
template they appear in. No global or fiber-local state is involved, so
rendering works across threads, fibers, and lazily-evaluated blocks.
A consequence: `render_slot` is only meaningful inside template holes —
a module helper method has no ambient slot context to read (calling
`Her.render_slot` without a slots hash raises with guidance).

### Control flow

Holes that contain statements are emitted as statements. `{if}`, `{unless}`,
`{case}/{when}`, `{elsif}`, `{else}`, `{for}`, `{begin}/{rescue}`, `{end}`,
and anything ending in `do |...|`:

```her
<ul>
  {@items.each do |item|}
    <li>{item}</li>
  {end}
</ul>

{if @admin}
  <span class="badge">Admin</span>
{elsif @member}
  <span>Member</span>
{else}
  <span>Guest</span>
{end}

{case @lang}
{when "sl"}<p>Živjo</p>
{when "de"}<p>Hallo</p>
{else}<p>Hello</p>
{end}
```

This is plain Ruby compiled into the method body — no special block tags, no
`<% end %>`. It reads like the template, compiles like the language. (HEEx
cannot express multiline control flow in `{}` at all; this is where HER
deliberately beats its model.)

Rules worth knowing:

- A hole is a statement when it *starts with* a control-flow keyword or *ends
  with* `do |...|`. Everything else is an expression hole, including trailing
  conditionals like `{@name if @show}`.
- Control flow must balance within a component/slot body (children compile to
  a lambda; an `{if}` outside can't close inside). Unbalanced flow is caught
  at load time and reported per component.
- Use `each do ... end`, not `map { }` — a brace block is an expression hole
  and would append the receiver.

### HTML rules

- Text and literal attributes pass through **verbatim** — HER never re-encodes
  the HTML you wrote, and never reformats whitespace.
- Tags must balance lexically; mismatches are load-time errors with both
  locations. Statement holes are transparent to balancing, so the conditional
  wrapper HEEx rejects works in HER:

  ```her
  {if @url}<a href={@url}>{end}
    {@title}
  {if @url}</a>{end}
  ```

  For output that genuinely can't balance lexically, `{raw(...)}` is the
  escape hatch — raw markup bypasses tag validation entirely.
- `<div/>` on a non-void element expands to `<div></div>` (a browser would
  treat the slash as noise otherwise). Void elements (`<br>`, `<img>`, ...)
  take no closing tag, and `</br>` is an error.
- Uppercase tags must be qualified component calls; HTML tag names are
  lowercase (SVG's camelCase elements like `<linearGradient>` are fine).
- `<!-- comments -->` and `<!DOCTYPE>` pass through verbatim (holes inside
  comments are not evaluated). `<%# ... %>` comments are stripped from output.
  Other ERB `<%` tags are rejected with a hint.

### `<script>`, `<style>`, and opting in/out of `{}`

Inside `<script>` and `<style>`, `{` is literal — a JS object or CSS rule is
not an interpolation hole. Opt back in per element with `her-interpolate`;
opt *out* anywhere with `her-no-curly` (applies to the whole subtree). Both
attributes are stripped from output.

```her
<script>const conf = { a: 1 };</script>          braces literal
<script her-interpolate>const u = "{@name}";</script>
<p her-no-curly>CSS syntax: .x { color: red }</p>
```

## Escaping and composition

One mechanism carries the whole library:

- `Her::Safe` wraps already-rendered, trusted HTML.
- `Her.safe(value)` escapes anything that isn't `Safe` and passes `Safe`
  through untouched.
- Every component returns a `Safe`.

So components nest without double-escaping — an inner `<.button/>`'s markup
survives because the call returned `Safe`, while a user-supplied
`"<script>"` assign is neutralized at the hole that prints it. `Her.raw(str)`
(or bare `raw(str)` in a hole) marks trusted HTML explicitly; treat it like
the sharp knife it is.

`Safe#to_s` returns the HTML string. `Safe` also implements `to_str`, so it
embeds into string operations transparently.

## Errors

Where the polish went (§7 of the build spec):

| Failure | What you get |
|---|---|
| Typo'd component / missing required attr / unknown slot at a call site | boot-time error from `Her.verify!`, with did-you-mean (next section) |
| Missing required attr | `UI.button: missing required attribute :label` at render |
| Missing assign (contract-free) | `Pages.profile: missing assign :bio (assigns given: :name)` at render |
| Undeclared `@attr` in a contracted template | load-time error naming the attr, the fix, and the declared set |
| Malformed template | `components/button.html.her:14:3: mismatched closing tag </div> — expected </span> (opened at ...)` at load |
| Syntactically invalid Ruby in a hole | load-time error with the parser's message at the template line (Prism), e.g. `invalid Ruby in interpolation: expected an expression after the operator` |
| Bad Ruby in a hole at runtime (`{@bio.upcase}` on nil) | the normal Ruby error, with a backtrace pointing at **the template file and line** (`profile.html.her:3`) |
| Unbalanced control flow | load-time `CompileError` naming the component, with a hint |

Generated code is laid out so its line numbers coincide with template line
numbers — inline templates report positions inside your `.rb` file, sibling
and globbed templates report positions in the `.her` file. To see exactly what
the compiler produced:

```ruby
puts Her.generated_source(UI, :button)
```

## Boot-time call-site verification

HEEx verifies component call sites while your project compiles. Ruby has no
after-compile hook, so HER does the next best thing: every template records
its component calls at compile time, and `Her.verify!` checks them all once
the application has finished loading:

```ruby
# in the test suite — effectively compile-time, since CI fails the build:
def test_components_verify = Her.verify!

# or after boot in Rails:
config.after_initialize { Her.verify! unless Rails.env.production? }
```

With no arguments it verifies every module that extended `Her::Component`
(pass modules to narrow it). All failures are reported at once:

```
Her::VerifyError: 3 component verification failures
  [error] app/views/ui.rb:14: UI.card: calls <.buttom/>, which is not defined — did you mean <.button/>?
  [error] app/views/ui.rb:15: UI.card: calls <.button/> without its required attr :label
  [error] app/views/ui.rb:24: UI.page: passes slot <:side> to <.plain/>, which never renders it
```

What it checks, with what is statically knowable:

- **the callee exists** — typo'd `<.buttom/>` and unresolvable `<Mod.func/>`
  constants become boot errors with did-you-mean suggestions, instead of
  render-time `NoMethodError`s;
- **required attrs are provided** (contract-tier callees) — skipped when the
  call has a `{...}` splat, which could supply them at runtime;
- **no undeclared attrs are passed** (contract-tier callees) — a warning by
  default, since renders deliberately allow extra assigns through; raise or
  silence it with `undeclared_attrs: :error | :ignore`;
- **no unknown slots are passed** — a `<:side>` definition (or children, for
  the `:inner` slot) given to a component that never renders that slot would
  silently drop content, so it's an error; tune with `unknown_slots:`.

`Her.verify` (non-bang) returns the issue list instead of printing/raising,
for custom policies.

Soundness limits, stated plainly: attr names are always statically known in
HER, but a splat opens the attr set, and a `render_slot(expr)` with a dynamic
name opens the callee's slot set — both suppress the affected checks for that
call.
Contract-free callees get existence checks only — a template's `@x` references
can't soundly serve as an implicit contract because references inside `{if}`
branches are conditionally required. Verification is one more reason to
declare attrs.

Why not verify when each template compiles? Ordering: `<.button/>` may be
defined later in the same module, in a file required later, or be the
component itself (recursion) — all legitimate. Phoenix defers verification to
the end of module compilation for the same reason; HER defers to the explicit
call, which is the Ruby-idiomatic finalize step.

## Design decisions vs HEEx's known pain points

HER inherits HEEx's model, so it decided each of HEEx's documented criticisms
consciously:

| HEEx pain point | HER's answer |
|---|---|
| Strict HTML validation rejects conditional wrapper elements | Tags must balance lexically, but control-flow holes are transparent to balancing — conditional wrappers just work; `{raw(...)}` remains for true edge cases |
| No partial attribute interpolation (`class="x-{@y}"`) | Supported |
| `{` breaks JS/CSS in `<script>`/`<style>` | Interpolation off by default there; `her-interpolate` opts in, `her-no-curly` opts out anywhere |
| Two brace meanings (`{...}` vs `#{...}`) | Inherent to the sigil; documented above |
| `{}` can't hold multiline control flow | Statement holes: `{if}`/`{each do}`/`{end}` compile to plain Ruby |

## Limitations, by design or for now

- **No LiveView.** One-shot rendering only: a component renders to a string,
  the end. No change tracking, no diffing, no client runtime.
- Without Prism (Ruby 3.1/3.2 and no `prism` gem), hole analysis falls back
  to a scanner that understands `"…"`/`'…'` strings (including nested `#{}`)
  but not `%w[]`, regexps, or heredocs — on those rubies avoid unbalanced
  braces, quotes, or `@word` inside such literals within a hole. With Prism
  this limitation disappears.
- `__`-prefixed locals (`__buf`, `__slots`, `__inner`) are reserved in holes.
- Assign keys are symbols.
- Defaults are static values, frozen at declaration (no lazy/proc defaults).
- Buffer output already written before an expression raises stays written —
  `{begin}/{rescue}` has streaming semantics, like ERB.
- Framework-agnostic: no Rails integration yet (see Roadmap).

## How it works

```
.her source ──① tokenize──▶ tokens ──② parse──▶ tree ──③ codegen──▶ Ruby src ──④ module_eval──▶ def self.name(assigns)
```

A hand-written scanner (no Temple — its IR pipeline fits indentation
frontends, not component/slot semantics) tokenizes HTML, component/slot tags,
and holes; the Ruby inside holes is analyzed with Prism when available —
exact hole termination, AST-based `@assign` rewriting, load-time syntax
validation — with a small heuristic scanner as fallback. A stack parser
validates the tree; codegen emits a string-buffer method
(`__buf << "static".freeze`, `__buf << Her.safe(expr)`); one `module_eval`
per template defines the function. Compilation happens once at require time —
renders never re-parse and never `eval`.

For:

```her
<button class={@class}>{@label}</button>
```

with `attr :label, required: true` and `attr :class, default: "btn"`, the
generated method is essentially:

```ruby
def self.button(assigns = {}, __slots = nil, &__inner)
  assigns.key?(:label) or ::Her::MissingAttr.raise_for(self, :button, :label)
  assigns = __her_defaults(:button).merge(assigns)
  __buf = +''
  __buf << "<button".freeze
  __buf << ::Her.attr_pair("class", (assigns[:class]))
  __buf << ">".freeze
  __buf << ::Her.safe((assigns[:label]))
  __buf << "</button>".freeze
  ::Her::Safe.new(__buf)
end
```

## Roadmap / open questions

- Attr types and allowed-values validation (`attr :kind, values: %w[info warn]`).
- Frontmatter attr declarations in `.her` files — would give globbed templates
  a contract; deliberately deferred until missing-assign errors prove painful.
- Rails integration (renderable interface, helper access) — large, separate
  body of work; HER stays framework-agnostic until it's designed properly.
- A `her` CLI to pretty-print generated code and check templates.

## Development

```sh
bundle install
rake test
```

## License

MIT
