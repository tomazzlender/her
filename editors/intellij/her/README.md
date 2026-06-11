# HER plugin for IntelliJ-platform IDEs (thin / LSP)

A minimal plugin that starts `her lsp` for any project with open `.her`
files and lets the IDE render what the server knows: diagnostics as you
type plus `Her.verify` findings, completion (components, attrs with
types, slots), hover, and go-to-definition.

**Requires a commercial JetBrains IDE** (IntelliJ IDEA Ultimate,
RubyMine, ...) 2024.2 or newer — the IntelliJ Platform LSP API does not
exist in Community Edition. On Community, use the
[LSP4IJ](https://plugins.jetbrains.com/plugin/23257-lsp4ij) plugin
instead and define a server with the same command (see
[`../../README.md`](../../README.md)).

## Build & install

Needs JDK 21 and Gradle 8.10+ (this skeleton is not built by the repo's
Ruby CI):

```sh
cd editors/intellij/her
gradle buildPlugin
# -> build/distributions/her-intellij-0.1.0.zip
```

Then `Settings → Plugins → ⚙ → Install Plugin from Disk…` and pick the
zip. `gradle runIde` launches a sandboxed IDE for trying it out.

## How the server is started

One process per project, in the project root:

- `bundle exec her lsp ...` when a `Gemfile` exists at the root,
  plain `her lsp ...` otherwise;
- the boot file (`-r`, which loads your component modules) comes from a
  `.her-lsp` file at the project root — its first non-comment line is
  the path — or defaults to `config/boot.rb` when that file exists.
  Without one you still get syntax diagnostics.

```sh
echo "app/boot.rb" > .her-lsp   # check it in; the whole team shares it
```

## Syntax highlighting

This plugin only wires the language server. For colors, import the
TextMate grammar once: `Settings → Editor → TextMate Bundles → +` and
select the repo's `editors/vscode/her` directory (JetBrains IDEs accept
VS Code extension folders as bundles). Holes highlight as Ruby only if a
Ruby TextMate bundle is also installed; the HTML/component/slot
structure highlights regardless.

## Limits of "thin"

The plugin contains no language model — everything flows through LSP, so
IDE-native features that need a PSI tree (rename refactoring across
templates, structure view, cross-language find-usages) are out of scope
by design.
