# Editor setup for HER

Two things to wire per editor:

1. **Syntax highlighting** — `editors/her.tmLanguage.json` is a TextMate
   grammar (scope `text.html.her`) for editors that speak TextMate
   grammars. Editors that don't (Zed, Vim) get a good approximation by
   treating `.her` as HTML, since HER templates *are* HTML plus holes.
2. **The language server** — any LSP client can run it; it speaks plain
   stdio JSON-RPC:

   ```sh
   her lsp -r ./config/boot.rb
   ```

   The `-r` file is whatever requires your component modules (the same
   file you'd pass to `her check`). Inside a bundled project, invoke it
   as `bundle exec her lsp ...` so the right gem versions load. Without
   `-r` you still get syntax diagnostics; with it you get the full
   registry-backed features: diagnostics (parse/compile errors as you
   type, `Her.verify` findings on open/save), completion (components,
   attrs with types, slots), hover, and go-to-definition. Saving a
   registered `.her` file hot-reloads it.

The server reads from the workspace root, so relative `-r` paths and
relative template paths resolve per-project.

## VS Code

A ready-to-copy extension lives in [`vscode/her/`](vscode/her):

```sh
cp -r editors/vscode/her ~/.vscode/extensions/her-language
# highlighting now works after a reload; for the language server:
cd ~/.vscode/extensions/her-language && npm install
```

Then set two settings (per workspace is most useful):

```jsonc
// .vscode/settings.json
{
  "her.bootFile": "config/boot.rb",
  "her.command": ["bundle", "exec", "her"] // or ["her"] for a global install
}
```

The grammar bundled in the extension is a copy of
`editors/her.tmLanguage.json` (kept in sync by a test).

## Neovim (0.10+)

No plugins needed — built-in LSP client plus the tree-sitter HTML grammar
for highlighting:

```lua
vim.filetype.add({ extension = { her = "her" } })

-- approximate highlighting: parse HER as HTML
vim.treesitter.language.register("html", "her")

vim.api.nvim_create_autocmd("FileType", {
  pattern = "her",
  callback = function(args)
    vim.lsp.start({
      name = "her",
      cmd = { "bundle", "exec", "her", "lsp", "-r", "config/boot.rb" },
      root_dir = vim.fs.root(args.buf, { "Gemfile", ".git" }),
    })
  end,
})
```

(On Neovim 0.8/0.9, replace `vim.fs.root(...)` with
`vim.fs.dirname(vim.fs.find({ "Gemfile", ".git" }, { upward = true })[1])`.)

## Vim 8/9

Classic Vim has no built-in LSP client; with
[vim-lsp](https://github.com/prabirshrestha/vim-lsp):

```vim
autocmd BufRead,BufNewFile *.her set filetype=html

if executable('her')
  au User lsp_setup call lsp#register_server({
        \ 'name': 'her',
        \ 'cmd': {server_info->['bundle', 'exec', 'her', 'lsp', '-r', 'config/boot.rb']},
        \ 'allowlist': ['html'],
        \ })
endif
```

Caveat: with `filetype=html` the server attaches to all HTML buffers, not
just `.her` — harmless (it only diagnoses what it's sent) but noisy if you
edit a lot of plain HTML. Defining a dedicated `her` filetype that sources
the HTML syntax avoids that:

```vim
autocmd BufRead,BufNewFile *.her set filetype=her
autocmd FileType her runtime! syntax/html.vim
" then use 'allowlist': ['her'] above
```

## Sublime Text

LSP via the [LSP package](https://packagecontrol.io/packages/LSP)
(`Preferences → Package Settings → LSP → Settings`):

```jsonc
{
  "clients": {
    "her": {
      "enabled": true,
      "command": ["bundle", "exec", "her", "lsp", "-r", "config/boot.rb"],
      "selector": "text.html.her"
    }
  }
}
```

Highlighting: Sublime loads TextMate grammars in the *plist* format
(`.tmLanguage`), not the JSON flavor this repo ships. Either convert
`editors/her.tmLanguage.json` (the PackageDev package converts JSON →
plist) and drop it in your `Packages/User`, or take the zero-effort route:
open a `.her` file and `View → Syntax → Open all with current extension
as… → HTML`, then change the LSP selector above to `"text.html"` (with
the same attaches-to-all-HTML caveat as Vim).

## Zed

Zed uses tree-sitter, not TextMate grammars, and language servers attach
through extensions — so full support needs a Zed extension (not written
yet; contributions welcome). The zero-effort approximation is good,
though — `.her` is HTML plus holes:

```jsonc
// settings.json
{ "file_types": { "HTML": ["her"] } }
```
