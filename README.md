# swank-lsp

A Common Lisp language server aiming to be the best one there is.
Uses **swank as its engine** and speaks **vanilla LSP** to any editor.

Goal: the best language server for Common Lisp, period — in any
editor with an LSP client, not just Emacs (SLIME), nvim
(vlime/nvlime), or VS Code (alive). Swank is the engine because
it's the right engine: a live image, every contrib for free,
parallel attach from vlime/nvlime to the same image. The bar isn't
parity with SLIME; it's exceeding what any current Lisp environment
delivers, and doing it portably.

Headline feature: jump-to-definition that resolves **local lexical
bindings**, including binders introduced by macros — a feature SLIME's
`slime-mdot-fu` doesn't reach (it's editor-coupled paren-walking, not
semantic). Built on
[`cl-scope-resolver`](https://github.com/ramfjord/cl-scope-resolver)
for the analysis half.

**Status:** working for `gd` (local + global + via-macros),
`K` (hover), `gK` (signatureHelp), and completion in nvim. References
(`gr`), diagnostics, code actions are not implemented yet.

## Direction

The North Star is making Lisp's meta-level *visible* in the editor.
When a binding comes from a chain of macro expansions, the editor
should walk you through it: "this variable is bound by macro A, which
expanded to macro B, which expanded to a `let` here." A side pane
shows each expansion step with the relevant slice highlighted; you
can stop at any layer.

The chain isn't a static list of snapshots — it animates. Each macro
visibly expands in place, so you watch the chain unfold rather than
read a final result. The bet: if macros are obvious enough to follow,
people stop complaining about them. That's the goal — make macros
easy enough to read that they stop being a tax on collaboration.

The data already exists — `cl-scope-resolver` materializes the
via-macros chain when it resolves a binding (`expand-prov`,
`produced-by`, `expansion-list`). What's missing is the transport
and the editor surface. Vanilla LSP has no primitive for "show me
the macro expansion," so this feature will live as a custom request
with editor-specific UI built on top. Vanilla LSP keeps the basics
portable; the expansion-explorer is where we deliberately leave
the standard to deliver something no current Lisp environment
offers, in any editor.

This is a North Star, not a near-term plan. Captured here because
it shapes upstream choices: provenance in `cl-scope-resolver` is
user-facing data, not just an internal invariant; and the LSP layer
will eventually grow a small custom-request surface that earns its
keep by surfacing the meta-level.

## Running it

Two modes; pick the one that matches your workflow.

### Mode 1: attach to your existing dev image (recommended)

You already start an SBCL with swank for vlime. Tell it to also start
swank-lsp on a TCP port, and have nvim connect to that port. One
process, no double cold-load, your defmacros are immediately visible
to the LSP because they live in the same image.

In your `~/.sbclrc` (or a one-shot startup file):

```lisp
(ql:quickload :swank-lsp)
(swank:create-server :port 4005 :dont-close t)         ; vlime port
;; start-and-publish writes .swank-lsp-port to the project root so the
;; editor (and any other consumer) can discover the port without an
;; env var. Mirrors how swank's bootstrap publishes .swank-port and
;; vlime's .vlime-port.
(let ((*default-pathname-defaults*
        (truename "~/projects/swank-lsp/")))
  (swank-lsp:start-and-publish :port 7777))            ; or :port 0
```

The nvim plugin discovers the port in this order:

1. `$SWANK_LSP_PORT` env var (override; useful for quick testing)
2. `~/projects/swank-lsp/.swank-lsp-port` (the convention)
3. fallback to auto-spawn (Mode 2 below)

If discovery succeeds, the plugin runs `bin/swank-lsp-attach.sh`
(a `socat` shim) to bridge nvim's stdio LSP to the image's TCP
listener. Multiple nvim windows can attach to the same image.

`stop-server` deletes `.swank-lsp-port` so a stale file can never
point at a dead listener.

When you eval a `defmacro` in vlime, the LSP sees it on the next
request — `gd` on a macro-introduced binding (`via-macros` path) just
works.

#### Cross-file `gr` needs your project loaded

`gr` (textDocument/references) returns two kinds of hits:

- **Local references** — read out of an in-memory walk of the buffer's
  text. No image state involved; works on unsaved edits.
- **Cross-file references** — pulled from swank's xref tables
  (`who-calls`, `who-references`, `who-macroexpands`).

swank's xref tables only contain entries for code that has been
**compiled into this image**. So cross-file `gr` works for symbols
your dev image has loaded, and returns nothing for symbols it hasn't.
Save-on-edit will keep things current after the first load (didSave
calls `swank:load-file`), but you need an initial load.

Recommended setups, easiest first:

1. **Edit the project that's already loaded in your dev image.** If
   you start swank-lsp inside the SBCL you also use for vlime/REPL
   work — and that image has `(ql:quickload :my-project)` or
   `(asdf:load-system :my-project)` in it — `gr` on globals just works.
2. **Use a startup snippet that loads your project explicitly.** See
   `bin/swank-lsp-with-project.lisp.example` for a template; copy it,
   adapt the system name, and either eval it or pass it via
   `sbcl --load`.
3. **Auto-spawn (Mode 2) won't give you cross-file `gr`** — the
   spawned image only knows what's in the open buffer.

### Discovery convention (for any tool, not just nvim)

Anything that wants to talk to a swank-lsp running in someone's
image should:

1. Read `.swank-lsp-port` from the project root.
2. Connect to `127.0.0.1:<port>` and speak LSP over the socket.
3. Treat absence of the file as "no LSP up; either fall back or skip."

Same idea swank uses (`.swank-port`) and Vlime (`.vlime-port`): the
image publishes its discoverable listeners to the filesystem;
consumers never invent ports. If you (or another agent) want to
modify the image's behavior, do it through the filesystem — edit a
file, reload via `(asdf:load-system :swank-lsp :force '(:swank-lsp))`
or `(claude-tools:reload-form ...)` — not by rewriting symbols
through eval. Keeps the image and the on-disk truth in sync.

### Mode 2: auto-spawn (zero-config, slower)

If `SWANK_LSP_PORT` is unset, the plugin spawns a fresh SBCL per
nvim attach via `bin/swank-lsp-stdio.lisp`. ~3-second cold load every
time you open a `.lisp` file. The spawned image only sees the buffer
text (not your loaded project), so global lookups and `via-macros`
won't find symbols from your code unless you also wire didSave-loading
(not implemented yet).

Works out of the box; useful for trying things or for one-off edits.

## What works in nvim today

| Key (LazyVim default) | LSP method | Notes |
|---|---|---|
| `gd` | `textDocument/definition` | local binders (let/lambda/dolist/loop/flet/labels/MVB/destructuring-bind/let*); macro-introduced bindings (jumps to the innermost user macro's defmacro); globals (falls through to swank). |
| `gr` | `textDocument/references` | local binders (in-buffer walk); cross-file refs to globals via swank's xref tables. Cross-file requires the project to be loaded into the image — see "Cross-file `gr` needs your project loaded" above. |
| `K` | `textDocument/hover` | swank's `documentation-symbol`. Works on globals and on symbols whose `defun`/`defmacro` is in your image. |
| `gK` / `<C-k>` | `textDocument/signatureHelp` | swank's `operator-arglist`. |
| (auto, as you type) | `textDocument/completion` | swank's `simple-completions`. Trigger chars: `: * + - /`. |

Not implemented: diagnostics, code actions, formatting, semantic
tokens. Each is a small, focused addition.

## Installation

```sh
git clone https://github.com/<your-org>/swank-lsp.git ~/projects/swank-lsp
cd ~/projects/swank-lsp
~/.roswell/bin/qlot install     # pulls jsonrpc, swank, cl-scope-resolver, ...
```

Then either symlink the asd into Quicklisp's `local-projects/`, or
use the `(ql:quickload :swank-lsp)` workflow above.

### nvim plugin

The plugin is part of this repo at `lua/swank-lsp/`. With lazy.nvim:

```lua
{
  "<your-org>/swank-lsp",
  dependencies = { "neovim/nvim-lspconfig" },
  config = function() require("swank-lsp").setup({}) end,
},
```

Or, while developing locally:

```lua
{
  dir = "~/projects/swank-lsp",
  name = "swank-lsp.nvim",
  dependencies = { "neovim/nvim-lspconfig" },
  config = function() require("swank-lsp").setup({}) end,
},
```

`setup({})` uses sensible defaults — see `lua/swank-lsp/init.lua` for
the option table. Notable knobs:

| Option | Default | Purpose |
|---|---|---|
| `swank_lsp_root` | auto-detected | Where bin/ scripts and the fallback `.swank-lsp-port` live. |
| `filetypes` | `{"lisp", "elp"}` | Drop `"elp"` if you don't have elp.nvim installed. |
| `root_markers` | `{".git", "qlfile", "qlfile.lock"}` | First match walking up determines the LSP's root and where project-local `.swank-lsp-port` is looked for. |
| `elp_gate` | `"auto"` | Gate position-bearing requests on `.elp` buffers to `<% %>` regions. Auto-enables when elp.nvim is loadable. |
| `install_keymaps` | `true` | Belt-and-suspenders `gd`/`gK`/`gr` mappings on LspAttach. Set false if your distro's LSP keymaps already cover them. |

Port-discovery priority (built into `setup`):

1. `$SWANK_LSP_PORT` (env override)
2. `<project-root>/.swank-lsp-port` — image started inside the project being edited
3. `<swank_lsp_root>/.swank-lsp-port` — swank-lsp's own dev image
4. Auto-spawn a fresh SBCL per attach (`qlot exec sbcl` if available, else bare `sbcl`)

The first three modes attach to a running image, so your evaled
`(defmacro …)` and `(defun …)` are visible immediately. Auto-spawn
only sees the buffer text.

## Project requirements

Project-wide features (cross-file references, eventual rename, the
SQLite xref index — see `plans/project-wide-references.md`) require
the project to be a **git working tree**. The indexer enumerates
source files via `git ls-files`, which gets `.gitignore` correctness
and vendored-deps exclusion for free. Non-git directories are not
supported for these features (single-buffer `gd`/`gr`/hover work
fine without git).

## Repo layout

- `src/` — the LSP server (handlers, document store, position
  conversion, jsonrpc transport hook-in).
- `src/jsonrpc-byte-fix.lisp` — local monkey-patch on
  `jsonrpc/request-response::read-message` for byte-counted
  Content-Length. Will go away once the upstream fix lands; see
  `tmp/jsonrpc/` for the WIP PR.
- `tests/` — wire-level integration tests + position/document units.
  158 checks; runs via `qlot exec sbcl --eval '(asdf:test-system :swank-lsp)'`.
- `bin/swank-lsp-stdio.lisp` — entrypoint for auto-spawn mode.
- `bin/swank-lsp-attach.sh` — stdio↔TCP shim for attach mode.
- `bin/nvim-headless-verify.sh` — end-to-end smoke test.
- `plans/`, `reports/` — design history, phase reports.
- `tmp/jsonrpc/` — local clone of jsonrpc with the in-progress
  upstream patch (and `tmp/jsonrpc-pr-description.md` for the PR).

## License

MIT. See `LICENSE`.
