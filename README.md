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

## A tour, small to large

Runnable versions of everything below live in [`examples/`](examples) —
`ruby -Ilib examples/01_hello.rb` and up.

**1. One component.** A template compiles at load time into a plain module
function; rendering is calling it. Escaping is automatic:

```ruby
module UI
  extend Her::Component

  component :greeting do
    attr :name, required: true
    template <<~'HER'
      <h1>Hello, {@name}!</h1>
    HER
  end
end

UI.greeting(name: "world")          # => <h1>Hello, world!</h1>
UI.greeting(name: "<script>")       # => <h1>Hello, &lt;script&gt;!</h1>
UI.greeting({})                     # raises Her::MissingAttr — never silent nil
```

(That `attr :name` line is not optional — contracts are mandatory. A
template that references `@x` without declaring it fails at load time
with the exact declaration to add.)

**2. A contract.** Declare attrs and the function enforces them — required
at entry, types and values checked, typos in the template caught at load:

```ruby
component :badge do
  attr :label, :string, required: true
  attr :count, :integer, default: 0
  attr :kind,  :string, values: %w[info warn danger], default: "info"
  attr :rest,  :global   # collects data-*/aria-*/anything undeclared
  template <<~'HER'
    <span class="badge badge-{@kind}" {@rest}>{@label}{if @count > 0} ({@count}){end}</span>
  HER
end

UI.badge(label: "Inbox", count: 3, "data-id": "b1")
# => <span class="badge badge-info" data-id="b1">Inbox (3)</span>
UI.badge(count: 1)              # Her::MissingAttr:  UI.badge: missing required attribute :label
UI.badge(label: "x", count: "3") # Her::InvalidAttr: attribute :count expected :integer, got String: "3"
```

Contracts are not optional decoration: they are the calling convention.
Static templates need no declarations, and `assigns[:key]` is the explicit
escape hatch for deliberately dynamic access.

**3. One function, two call sites.** Every component is a plain module
function — so the *same* `badge`, with the *same* contract, is callable
from Ruby and from any template:

```ruby
# From Ruby — controllers, jobs, mailers, tests:
UI.badge(label: "Inbox", count: unread_count)

# From a template — same method, same enforcement:
component :inbox_header do
  attr :unread, :integer, required: true
  template <<~'HER'
    <header>
      <h1>Mail</h1>
      <.badge label="Inbox" count={@unread} kind="warn" data-tracking="hdr"/>
    </header>
  HER
end
```

In template calls, attribute values are real Ruby values: `label="Inbox"`
passes a String, `count={@unread}` passes whatever the expression yields,
a bare attribute passes `true`. `UI.badge(...)` and `<.badge .../>` hit
the identical compiled method — there is no separate "partial" or "tag"
layer to learn, and `Her.verify!` checks the template call sites at boot.

**4. Composition.** Components call components inside templates; attr
values are real Ruby objects, and each component escapes its own output
exactly once:

```ruby
component :toolbar do
  attr :items, :array, required: true
  template <<~'HER'
    <nav class="toolbar">
      {@items.each do |item|}
        <.button label={item[:label]} disabled={item[:disabled]}/>
      {end}
    </nav>
  HER
end

UI.toolbar(items: [{ label: "Save" }, { label: "Delete", disabled: true }])
```

`disabled={...}` is a smart attribute: nil/false omit it, true renders it
bare. Cross-module calls are `<Icons.star name="x"/>`.

**5. Slots.** Markup flows *into* components — a default `:inner` slot,
named slots with fallbacks, and `let` bindings for data-driven rows:

```ruby
component :panel do
  template <<~'HER'
    <section class="panel">
      <header><:title>Untitled</:title></header>
      <div class="body">{render_slot(:inner)}</div>
    </section>
  HER
end

component :page do
  template <<~'HER'
    <.panel>
      <:title>Quarterly <em>report</em></:title>
      <p>Everything is fine.</p>
    </.panel>
  HER
end
```

**6. A full page.** [`examples/07_full_page.rb`](examples/07_full_page.rb)
puts it all together — an HTML layout with nav/footer slots, a card grid
driven by an array of hashes with conditional branches and splats, a form
built with a capture helper — and ends with `Her.verify!`, which checks
every component call written in those templates at boot. That escalation
path (template → contract → composition → slots → verified page) is the
library.

**7. A running app.** [`examples/sinatra_app/`](examples/sinatra_app)
serves it over HTTP with the smallest possible host: `config/boot.rb`
loads the components (the same file feeds `her lsp` and `her check`),
routes render with `.to_s`, `Her.verify!` gates boot, and a before-filter
calls `Her.reload_templates!` in development — edit a template, refresh
the browser. It is also the project to open when testing editor
integrations.

## Installation

```ruby
gem "her", github: "tomazzlender/her"
```

Requires Ruby >= 3.1. The only dependency is Prism, Ruby's own parser
(bundled with Ruby 3.3+; installed as a gem automatically on 3.1/3.2),
which HER uses to analyze the Ruby inside `{...}` holes.

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

- **`embed_templates` files declare their contract in frontmatter** — the
  same `attr` DSL inside leading `<%# %>` comments (a deliberate departure
  from Phoenix, whose embedded templates are contract-free):

  ```her
  <%# attr :label, :string, required: true %>
  <%# attr :kind, :string, values: %w[info warn], default: "info" %>
  <span class="badge-{@kind}">{@label}</span>
  ```

  Frontmatter templates get everything the contract tier has: required and
  type/values enforcement, load-time errors for undeclared `@attr`
  references, `Her.verify!` call-site checks, and LSP completion — and
  `Her.reload_templates!` re-reads the declarations, so editing the contract
  never requires touching Ruby. Declarations must sit at the top of the file
  (before any content); plain description comments can sit alongside them.
  Declaring attrs both in a `component` block and in its template's
  frontmatter is a load-time error — one source of truth.

- **Contracts are mandatory everywhere.** A template that declares nothing
  compiles with an *empty* contract: legal for purely static markup, and a
  load-time error (naming the exact attr to declare) the moment it
  references `@x`. There is no opt-out — the escape hatches are explicit:
  `assigns[:key]` for deliberately dynamic access, and `attr :rest,
  :global` for passthrough components. Missing *required* attrs raise
  `Her::MissingAttr` at render, listing the keys that were passed (the
  fast way to spot string-vs-symbol mistakes); declared-optional attrs
  read as nil — silence is something you declared, never an accident.

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
`@label` → `assigns[:label]`
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
contents are plain Ruby, analyzed by Prism — the real Ruby parser: invalid
expressions fail at load time with the parser's own message pointing at the
template line, assigns are enforced read-only (`{@x = 1}` is a load error),
and exotic literals (`%q[}]`, regexps, heredocs) terminate holes correctly.
A complete `if ... end` expression in a hole renders its value; keyword
*fragments* are control-flow statements (below).

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

Lines that contain only statement holes are trimmed from the output —
the `{each do}` / `{end}` lines above leave no blank lines behind. A
statement sharing its line with content leaves the line untouched.

For *capture-style* helpers — ones that wrap their block's content and
return the combined markup, like form builders — plain statements would
discard the helper's return value. The capture form `{= ... do}` appends it:

```her
{= form_for(@user) do |f|}
  <label>{f.label :name}</label>
{end}
```

The children build the string the block returns; the helper's result is
escaped-or-trusted like any hole. Blocks bind arguments (`do |f|`) as usual.

Rules worth knowing:

- A hole is a statement when it *starts with* a control-flow keyword or *ends
  with* `do |...|`; a hole starting with `=` and ending with a block opener
  is a capture. Everything else is an expression hole, including trailing
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

  The flip side of that flexibility: lexical balance can't prove the
  *output* balances (`{if @a}<div>{end}` paired with `{if @b}</div>{end}`
  compiles, and misrenders when `a != b`). If you want HEEx's guarantee,
  opt into strict mode — `component :x, strict_html: true do ... end`,
  `embed_templates "...", strict_html: true`, or globally
  `Her.strict_html = true` — which requires control flow to nest fully
  within each element and rejects conditional wrappers at load time.
- `<div/>` on a non-void element expands to `<div></div>` (a browser would
  treat the slash as noise otherwise). Void elements (`<br>`, `<img>`, ...)
  take no closing tag, and `</br>` is an error.
- Uppercase tags must be qualified component calls; HTML tag names are
  lowercase (SVG's camelCase elements like `<linearGradient>` are fine).
- `<!-- comments -->` and `<!DOCTYPE>` pass through verbatim (holes inside
  comments are not evaluated). `<%# ... %>` comments are stripped from
  output — a comment alone on its line takes the whole line with it.
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
| Typo'd component / missing required attr / wrong-typed literal / unknown slot at a call site | boot-time error from `Her.verify!`, with did-you-mean (next section) |
| Missing required attr | `UI.button: missing required attribute :label (assigns given: :class)` at render |
| Wrong type / disallowed value for a declared attr | `UI.badge: attribute :count expected :integer, got String: "3"` at render |
| Undeclared `@attr` in a contracted template | load-time error naming the attr, the fix, and the declared set |
| Malformed template | `components/button.html.her:14:3: mismatched closing tag </div> — expected </span> (opened at ...)` at load, with the source line and a caret under the column |
| Syntactically invalid Ruby in a hole | load-time error with the parser's message at the template line, e.g. `invalid Ruby in interpolation: expected an expression after the operator` |
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
# (or call it from any after-boot hook in development)
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
- **literal values satisfy the attr's type and `values:`** — `count="5"`
  passed to an `:integer` attr, a bare (boolean) attr passed to a `:string`
  one, an interpolated `"n-{@x}"` (always a String) passed to a non-string
  attr, or a literal outside the allowed values — all errors, since they
  would raise `Her::InvalidAttr` at render;
- **no undeclared attrs are passed** (contract-tier callees) — a warning by
  default, since renders deliberately allow extra assigns through; raise or
  silence it with `undeclared_attrs: :error | :ignore`. Skipped entirely
  when the callee declares a `:global` attr — passthrough is then expected;
- **no unknown slots are passed** — a `<:side>` definition (or children, for
  the `:inner` slot) given to a component that never renders that slot would
  silently drop content, so it's an error; tune with `unknown_slots:`.

`Her.verify` (non-bang) returns the issue list instead of printing/raising,
for custom policies.

Soundness limits, stated plainly: attr names are always statically known in
HER, but a splat opens the attr set, and a `render_slot(expr)` with a dynamic
name opens the callee's slot set — both suppress the affected checks for that
call.
Hand-written module functions used as callees get existence checks only —
HER has no contract metadata for them.

Why not verify when each template compiles? Ordering: `<.button/>` may be
defined later in the same module, in a file required later, or be the
component itself (recursion) — all legitimate. Phoenix defers verification to
the end of module compilation for the same reason; HER defers to the explicit
call, which is the Ruby-idiomatic finalize step.

## Development conveniences

```ruby
Her.reload_templates!            # re-read and recompile all file-based
Her.reload_templates!(UI)        # templates (sibling files + globs);
                                 # wire it to your file watcher
Her.debug_annotations = true     # set BEFORE loading components: rendered
                                 # output gets <!-- <UI.card> ui.rb:12 -->
                                 # comments around each component
puts Her.generated_source(UI, :button)  # what the compiler produced
```

`reload_templates!` reuses the attr declarations from the original
definition — editing a `.her` file never needs the Ruby file re-evaluated.
A template that no longer compiles raises (with the caret snippet) and
leaves the previous compilation in place. Inline templates live in Ruby
files and are your code reloader's business.

## Design decisions vs HEEx's known pain points

HER inherits HEEx's model, so it decided each of HEEx's documented criticisms
consciously:

| HEEx pain point | HER's answer |
|---|---|
| Strict HTML validation rejects conditional wrapper elements | Tags must balance lexically, but control-flow holes are transparent to balancing — conditional wrappers just work; `{raw(...)}` remains for true edge cases, and `strict_html:` opts back into the HEEx guarantee |
| No partial attribute interpolation (`class="x-{@y}"`) | Supported |
| `{` breaks JS/CSS in `<script>`/`<style>` | Interpolation off by default there; `her-interpolate` opts in, `her-no-curly` opts out anywhere |
| Two brace meanings (`{...}` vs `#{...}`) | Inherent to the sigil; documented above |
| `{}` can't hold multiline control flow | Statement holes: `{if}`/`{each do}`/`{end}` compile to plain Ruby |

## Limitations, by design or for now

- **One-shot rendering only.** A component renders to a string, the end.
  No change tracking, no diffing, no client runtime.
- `__`-prefixed locals (`__buf`, `__slots`, `__inner`) are reserved in holes.
- Assign keys are symbols.
- Defaults are static values, frozen at declaration (no lazy/proc defaults).
- Buffer output already written before an expression raises stays written —
  `{begin}/{rescue}` has streaming semantics, like ERB.
- Framework-agnostic by design: bring your own request layer.

## How it works

```
.her source ──① tokenize──▶ tokens ──② parse──▶ tree ──③ codegen──▶ Ruby src ──④ module_eval──▶ def self.name(assigns)
```

A hand-written scanner (no Temple — its IR pipeline fits indentation
frontends, not component/slot semantics) tokenizes HTML, component/slot tags,
and holes; the Ruby inside holes is analyzed with Prism — exact hole
termination, AST-based `@assign` rewriting, load-time syntax validation.
A stack parser validates the tree; codegen emits a string-buffer method
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

## Editor support & tooling

### The `her` CLI

```sh
her format app/components          # format .her templates in place
her format --check app/components   # CI mode: exit 1 if anything would change
her check -r ./config/boot.rb     # load the app, run Her.verify!
her lsp -r ./config/boot.rb       # language server on stdio
her source -r ./boot.rb UI.button # print the generated Ruby
```

### Formatter

`her format` (or `Her::Formatter.format`) is a *safe* formatter: it re-indents
lines from the parsed structure but never moves content between lines, so it
cannot change rendered semantics. Children indent two spaces; `{if}`/`{each
do}` indent what follows; `{else}`/`{elsif}`/`{when}` outdent Ruby-style.
Left verbatim: everything inside `<pre>`/`<textarea>`/`<script>`/`<style>`,
continuation lines of multi-line holes (Ruby code), and multi-line tags.
Idempotent; malformed templates fail with the usual caret error instead of
being "formatted".

### Language server

`her lsp` speaks LSP over stdio with no dependencies. Everything it knows
comes from the same registry that powers `Her.verify` — pass your app's
entry point with `-r` and you get:

- **diagnostics** as you type (parse/compile errors with positions) plus
  `Her.verify` findings on open/save — typo'd components, missing required
  attrs, wrong-typed literals, unknown slots, in-editor;
- **completion**: components after `<.`, their attrs (with type, required,
  default, values) inside the tag, slot names after `<:`;
- **hover**: the component's contract; **go-to-definition**: jumps to the
  `.her` file or the declaring Ruby line.

All four work the same whether the template lives in a standalone `.her`
file or **inline** in a Ruby component (`template <<~HER … HER`, `%(…)`, or
a quoted string) — the server locates each inline template with Prism and
maps diagnostics back to the right line and column in the `.rb` file.
Completion, hover and definition stay inert in the surrounding Ruby code.

Without `-r` it still provides syntax diagnostics. Saving a registered
`.her` file hot-reloads it via `Her.reload_templates!`; inline templates
reload with your code reloader (they live in Ruby). Wire it up as a generic
stdio language server in your editor — attach it to both the `her` filetype
and Ruby files to get inline-template support.

### Editor wiring

[`editors/README.md`](editors/README.md) has copy-paste setup for VS Code
(a ready-made extension under `editors/vscode/her`), Neovim, Vim, Sublime
Text, JetBrains IDEs (a thin LSP plugin under `editors/intellij/her`),
and Zed — both the language server and highlighting.
`editors/her.tmLanguage.json` is a TextMate grammar for `.her` files
(with a plist build, `editors/her.tmLanguage`, for Sublime Text/TextMate) —
holes highlight as embedded Ruby, component (`<.button>`), slot
(`<:title>`) and qualified (`<Icons.star>`) tags get their own scopes, and
attribute holes work inside quoted values. Editors without TextMate
support get a good approximation by treating `.her` as HTML.

### RuboCop cop

`Her/TemplateInterpolation` flags `template` arguments that interpolate
`#{...}` at definition time (the one mistake everyone makes once). Opt in:

```yaml
# .rubocop.yml
require:
  - her/rubocop
```

## Performance

The pitch is the authoring model, not speed — but the league check holds:
on the same 100-item escaped loop, HER renders within ~15% of *precompiled
stdlib ERB* (both ~25–40µs/render; `ruby benchmark/bench.rb` to reproduce).
Representative numbers on Ruby 3.3 (one core):

- tiny component (smart attr + hole): ~1.7µs/render
- realistic card (loop, nested component, slot, splat): ~12µs/render
- 10,000-item loop: ~4.3ms, scaling linearly
- compile: ~1ms per realistic component at boot; 1000-hole templates ~80ms
- `Her.verify` on 200 components: under 1ms; formatter: ~30ms per 1200 lines

Declared attr types compile to inline predicates in the method header —
about **0.1µs per typed attr** per render — so the contract belongs on
every component, hot paths included. (`values:` lists and Class/Module
types go through a helper, ~0.5µs.) Templates nesting beyond ~2000 levels
fail compilation with a clear error — real documents nest ~50.

## Development

```sh
bundle install
rake test
ruby benchmark/bench.rb
```

## License

MIT
