# HER example app (Sinatra)

The smallest possible web host for HER — and the project to open when
testing editor integrations, because it has the *app shape* the tooling
conventions auto-detect: a `Gemfile`, a `config/boot.rb`, file-based
templates with frontmatter contracts, and cross-file component calls.

```sh
cd examples/sinatra_app
bundle install
bundle exec rackup        # → http://localhost:9292
```

HER itself stays framework-neutral — Sinatra appears only in this
directory's Gemfile, never in the gem.

## Layout

- `config/boot.rb` — loads the component modules and **nothing else** (no
  Sinatra). The same file serves the app, `her lsp -r config/boot.rb`,
  and `her check -r config/boot.rb`.
- `app/components.rb` + `app/components/*.html.her` — a layout with
  slots, typed attrs with `values:`, `:global` passthrough, control flow.
- `app.rb` — routes render components with `.to_s`; `Her.verify!(UI)`
  gates boot; a `before` filter calls `Her.reload_templates!(UI)` in
  development, so editing any `.html.her` (markup *or* its frontmatter
  contract) shows up on the next request with no restart.

## Testing editors against this app

**Open this directory as the project root** — editors resolve the
Gemfile, boot-file convention, and relative paths from the root they
open. Then follow [`../../editors/README.md`](../../editors/README.md)
for your editor; the boot file is found automatically (`config/boot.rb`).

Things to try in a `.her` file once the server is up:

- type `<.` → component completion with contract summaries
- inside `<.badge ` → attr completion (`kind` shows its allowed values)
- hover `<.project_card` → the contract as markdown
- go-to-definition on `<.layout` → jumps to `layout.html.her`
- change `<.badge label=...` to `<.badge labl=...` → verify diagnostic
- break a tag → parse error with the caret, as you type
- edit `badge.html.her`, save, reload the browser → new markup, no restart

The repo root also carries a `.her-lsp` file pointing here, so opening
the *whole* her repo in an editor that honors it (the IntelliJ plugin)
gets these components registered too.
