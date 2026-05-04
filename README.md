# swank-lsp

A Common Lisp LSP server that uses **swank as its engine** and speaks
**vanilla LSP** to any editor.

Goal: a swank-grade Lisp development experience in any editor with an
LSP client — not just Emacs (SLIME), nvim (vlime/nvlime), or VS Code
(alive). Inherits every swank contrib for free; vlime/nvlime can
attach to the same image in parallel.

Headline feature: jump-to-definition that resolves **local lexical
bindings**, including binders introduced by macros — a feature SLIME's
`slime-mdot-fu` doesn't reach (it's editor-coupled paren-walking, not
semantic). Built on
[`cl-scope-resolver`](https://github.com/ramfjord/cl-scope-resolver)
for the analysis half.

**Status:** working for `gd` (local + global + via-macros),
`K` (hover), `gK` (signatureHelp), and completion in nvim. References
(`gr`), diagnostics, code actions are not implemented yet.

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
| `K` | `textDocument/hover` | swank's `documentation-symbol`. Works on globals and on symbols whose `defun`/`defmacro` is in your image. |
| `gK` / `<C-k>` | `textDocument/signatureHelp` | swank's `operator-arglist`. |
| (auto, as you type) | `textDocument/completion` | swank's `simple-completions`. Trigger chars: `: * + - /`. |

Not implemented: `gr` (references), diagnostics, code actions,
formatting, semantic tokens. Each is a small, focused addition.

## Installation

```sh
git clone https://github.com/<your-org>/swank-lsp.git ~/projects/swank-lsp
cd ~/projects/swank-lsp
~/.roswell/bin/qlot install     # pulls jsonrpc, swank, cl-scope-resolver, ...
```

Then either symlink the asd into Quicklisp's `local-projects/`, or
use the `(ql:quickload :swank-lsp)` workflow above.

For the nvim plugin, copy `nvim-plugin/swank-lsp.lua` (TODO: not yet
extracted into this repo — see the example in `~/.config/nvim/lua/plugins/`)
into your LazyVim plugin directory. It registers swank-lsp via
`nvim-lspconfig`'s custom-server API so LazyVim's default LSP keymaps
(`gd`, `K`, `gK`, etc.) wire up automatically.

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
