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

`swank-lsp` is a Common Lisp library. Pull it into your project as a
dev dependency, call `(swank-lsp:start-and-publish …)` from a long-
running SBCL, and the nvim plugin discovers the listener via
`.swank-lsp-port`. *How* you keep that SBCL running is your choice —
a shell script, `docker compose`, a Makefile, your `~/.sbclrc`,
systemd. The library doesn't supervise itself.

### The library API

```lisp
(ql:quickload :swank-lsp)
(asdf:load-system :my-project)               ; load the project being edited
(swank-lsp:start-and-publish :port 0)        ; bind a free port; write port file
;; or :port 7777 to pin
```

`start-and-publish` writes `.swank-lsp-port` to
`*default-pathname-defaults*`, so set that to the project root before
calling. The default `:host` is `0.0.0.0` so the listener is reachable
from inside a docker container's published port; pass `:host
"127.0.0.1"` if you want loopback-only.

### Supervisor option A: a shell script (native)

`bin/swank-lsp-server.sh` in this repo is one example: `start`,
`stop`, `bounce`, `status`, with a PID file. Copy it into your project
and adapt the system name, or write your own — there's nothing magic
about it.

```sh
bin/swank-lsp-server.sh start    # writes .swank-lsp-port; image stays up
```

### Supervisor option B: docker compose

A reference `docker-compose.yml`:

```yaml
services:
  swank:
    image: clfoundation/sbcl:latest
    working_dir: /app
    volumes:
      - .:/app                            # so .swank-lsp-port lands on host
    ports:
      - "127.0.0.1:7777:7777"             # host loopback only
    command: >
      sbcl --non-interactive
        --eval "(ql:quickload :swank-lsp)"
        --eval "(asdf:load-system :my-project)"
        --eval "(swank-lsp:start-and-publish :port 7777 :host \"0.0.0.0\")"
        --eval "(loop (sleep 60))"
```

`docker compose up -d swank` brings it up; the container writes
`/app/.swank-lsp-port` which the host sees as `./.swank-lsp-port`;
nvim attaches via the published `127.0.0.1:7777`. The 0.0.0.0 bind
inside the container is required (loopback would be unreachable from
outside the container); the host-side `127.0.0.1:` prefix on `ports:`
keeps it private to your machine.

### Supervisor option C: your existing dev image

If you already start SBCL with swank for vlime, just add two forms:

```lisp
(ql:quickload :swank-lsp)
(swank:create-server :port 4005 :dont-close t)           ; vlime
(let ((*default-pathname-defaults* (truename ".")))
  (swank-lsp:start-and-publish :port 0))
```

One image, one cold load, vlime and the LSP both attached. When you
eval a `defmacro` in vlime, the LSP sees it on the next request.

### Booting the supervisor when nvim attaches

Configure `start_command` in `setup()` and the plugin runs it
automatically when no `.swank-lsp-port` is found in the project root,
then polls for the file and attaches:

```lua
require("swank-lsp").setup({
  start_command = { "docker", "compose", "up", "-d", "swank" },
  -- or { "make", "swank-up" }
  -- or { "bin/swank-lsp-server.sh", "start" }
})
```

The supervisor owns lifecycle (it doesn't die when nvim quits). If
`start_command` is unset or its port file doesn't appear in time, the
plugin falls back to a per-attach SBCL spawn (zero config, no
cross-file features).

### Discovery convention (for any tool, not just nvim)

Anything that wants to talk to a swank-lsp should:

1. Read `.swank-lsp-port` from the project root.
2. Connect to `127.0.0.1:<port>` and speak LSP over the socket.
3. Treat absence of the file as "no LSP up; either fall back or skip."

Same idea swank uses (`.swank-port`) and Vlime (`.vlime-port`): the
image publishes its discoverable listeners to the filesystem;
consumers never invent ports. `stop-server` deletes the file so a
stale `.swank-lsp-port` can never point at a dead listener.

### Cross-file `gr` needs your project loaded

`gr` (textDocument/references) returns two kinds of hits: local
references (in-buffer walk, no image state) and cross-file references
(swank's xref tables). swank's xref tables only contain entries for
code that has been **compiled into this image** — so cross-file `gr`
works for symbols your supervisor's image has loaded, and returns
nothing for symbols it hasn't. All three supervisor options above
load your project into the image, so cross-file `gr` works in each.
The per-attach spawn fallback does not.

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
| `start_command` | `nil` | argv table (or `function(root_dir) -> argv`) that brings the swank-lsp image up when no `.swank-lsp-port` exists. e.g. `{"docker","compose","up","-d","swank"}`, `{"make","swank-up"}`, `{"bin/swank-lsp-server.sh","start"}`. |
| `start_timeout_ms` | `30000` | How long to wait for `.swank-lsp-port` to appear after running `start_command` before falling back to per-attach spawn. |
| `swank_lsp_root` | auto-detected | Where bin/ scripts and the fallback `.swank-lsp-port` live. |
| `filetypes` | `{"lisp", "elp"}` | Drop `"elp"` if you don't have elp.nvim installed. |
| `root_markers` | `{".git", "qlfile", "qlfile.lock"}` | First match walking up determines the LSP's root and where project-local `.swank-lsp-port` is looked for. |
| `elp_gate` | `"auto"` | Gate position-bearing requests on `.elp` buffers to `<% %>` regions. Auto-enables when elp.nvim is loadable. |
| `install_keymaps` | `true` | Belt-and-suspenders `gd`/`gK`/`gr` mappings on LspAttach. Set false if your distro's LSP keymaps already cover them. |

Port-discovery priority (built into `setup`):

1. `$SWANK_LSP_PORT` (env override)
2. `<project-root>/.swank-lsp-port` — image started inside the project being edited
3. `<swank_lsp_root>/.swank-lsp-port` — swank-lsp's own dev image
4. `start_command` — run user-configured supervisor, poll for `.swank-lsp-port`
5. Auto-spawn a fresh SBCL per attach (`qlot exec sbcl` if available, else bare `sbcl`)

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
