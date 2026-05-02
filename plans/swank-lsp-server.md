# Swank-backed LSP server for Common Lisp

**Status:** living document. The phase shapes are committed; the
contents-per-commit are not. Each phase teaches us what the later ones
should actually look like, and *this file is updated as that
happens* — what's written here reflects current intent, not the
original outline. Per-phase agent reports live under `reports/`.

This is the project's own repository. MIT-licensed, to match swank.

## Purpose (load-bearing)

Two sentences, kept here so every phase decision can be checked
against them:

1. **Make it easy to add LSP features to Lisp.** The internal seams
   should make "add a new request handler" a small, local change.
2. **Make it easy to use Lisp in any editor.** The LSP wire shape
   is what the world speaks; conform to it, don't extend it.

Corollary: components don't know about each other unless they have
to. The scope resolver doesn't know about LSP. The LSP layer doesn't
know about swank's wire format. The editor doesn't know about
swank at all.

## Testing principle

**Test at the LSP wire protocol boundary, not at internal function
boundaries.** The integration boundary is the thing other tools
exercise; bugs at that seam are the ones that bite users.

Concrete shape: a test opens a TCP socket to the running server (or
spawns a stdio child), sends framed JSON-RPC requests, asserts on
the responses. Same shape an editor would use. Editor-agnostic by
construction.

Unit tests are appropriate where the unit is genuinely
self-contained and has its own complexity (the Phase 0 scope
resolver — pure function, no IO, complex enough to deserve focused
tests). For everything LSP-shaped, default to wire-level
integration tests.

## Goal

A Common Lisp LSP server that uses **swank as its engine** and speaks
**vanilla LSP** to any client (nvim first, but not nvim-specific). The
headline differentiator vs. existing options:

- **vlime / nvlime** — swank-backed but locked to vim/nvim and to
  swank's own wire protocol.
- **alive-lsp** — speaks LSP but reimplements swank's surface in
  parallel (own parser, direct `sb-introspect`); functionally
  VS-Code-only because that's the only client extension shipped.
- **This** — swank-backed *and* LSP-fronted. Inherit every swank
  contrib for free; portable across LSP clients; nvlime/Vlime can
  attach to the same image in parallel.

Headline new feature, not present in any of the above:
**jump-to-definition that resolves local lexical bindings**, including
a v2 with macroexpansion-aware navigation that lets you jump *into*
an expansion when the binder only exists post-expansion.

## Why

Lisp's tooling story outside Emacs is "build your own editor" or
"second-class everywhere else." That gatekeeps the language behind
editor choice. LSP is the lingua franca every other modern language
ecosystem speaks. Filling this gap is one of the cheapest things that
could get more people writing Lisp — the engine (swank) already
exists and is excellent; it just doesn't speak the standard wire
format. Bridge that, and any editor with an LSP client gets a
swank-grade Lisp experience.

The local-resolution + macroexpand-pane work is the bonus payload:
something *no* existing CL editor integration does, and which falls
out almost for free once we have eclector + walker wired up.

## Context

Pieces verified to exist and compose, in a warm session against the
current swank image:

- `jsonrpc` (Quicklisp) — JSON-RPC 2.0 + LSP `Content-Length` framing
  + stdio/tcp/ws transports. Handles the wire layer.
- `eclector` + `eclector-concrete-syntax-tree` — position-tracking
  reader. Returns `(start . end)` byte offsets per node.
- `hu.dwim.walker` — scope analysis. Resolves lexical references to
  their binders by walking the parent chain. Already an `elp` dep.
- `swank` — 185 external symbols covering definitions, xref,
  completion, arglist, docs, macroexpansion, compile, debugger.

Recommended architecture: **in-process with swank.** The LSP server
runs inside the same SBCL image that's running swank. Every handler
is a direct function call into swank internals; no IPC; reloads
visible immediately; nvlime/Vlime can attach to the swank socket on
the side. One process to crash; for an interactive dev tool that's
fine.

`alive-lsp` is reference material, not a dependency. Two files worth
reading carefully before reimplementing the equivalents:
`src/position.lisp` + `src/range.lisp` (LSP UTF-16 position encoding,
easy to get wrong) and `src/session/state.lisp` +
`src/session/handler/document.lisp` (didOpen/didChange/didClose
buffer divergence handling).

## Non-goals (for v0–v2)

- Code formatting. Defer; alive-lsp's `format.lisp` is 600 lines and
  it's a self-contained problem.
- Semantic-tokens highlighting. nvim has tree-sitter; cost/benefit
  for v0 is wrong.
- Multi-implementation support. SBCL only until something else
  asks. Swank is portable across CLs but our `sb-introspect`-shaped
  edges aren't.
- Out-of-process mode. Possible later but the in-process design
  carries weight.
- Project-wide indexing. Resolution is on-demand per request.

## Phases

Each phase ends in something demonstrably useful. Within a phase, the
shape of individual commits is deliberately under-specified — we'll
discover commit boundaries while doing the work. Each phase header
names an outcome, not a checklist.

### Phase 0 — eclector ↔ walker bridge, as a standalone library

The interesting research piece, isolated from anything LSP. Build a
small CL library (call it `cl-scope-resolver` or similar) that:

- Reads source text with eclector-cst, retaining per-node ranges.
- Walks the resulting form with hu.dwim.walker.
- Maps walker AST nodes back to their CST source ranges.
- Given `(source-string, byte-offset)`, returns either:
  - the range of the **binder** for the local at that offset, or
  - a sentinel meaning "this is a free / global / special / macro-
    introduced reference; ask swank instead."

This is a pure function with no IO and no LSP awareness. Scratch-file
iteration is the right workflow: build a corpus of small forms with
marked offsets and expected resolutions, eval against a warm image.

**Key open questions to resolve here, not before:**

- How does the CST↔walker map actually behave under macroexpansion?
  The walker macroexpands as it walks; the CST is pre-expansion.
  What's the cleanest rule for "this AST node has no source position
  because it doesn't exist in the source"? The walker's
  `result-of-macroexpansion?` slot is the hook, but the policy isn't
  obvious yet.
- Are there walker forms (symbol-macrolets, compiler-let, special
  declarations) where the parent-chain binder-search needs special
  handling?
- Performance: walking a whole defun on every cursor move is fine,
  but what about a 500-line top-level form? Probably also fine but
  worth measuring.

Outcome: a library that, given a source string and a position,
correctly answers "where is this local bound" for the 95% case, and
honestly says "I don't know, ask swank" for the rest.

### Phase 1 — minimal LSP server, swank-backed, nvim-driveable

Wrap `jsonrpc` + swank in just enough scaffolding to answer real
requests from nvim's `lspconfig`. Methods covered, all by direct
swank passthrough:

- `initialize` / `initialized` / `shutdown` / `exit`
- `textDocument/didOpen` / `didChange` / `didClose` — in-memory
  document store, kept in sync with the editor's view
- `textDocument/definition` — global jump-to-def via
  `swank:find-definitions-for-emacs`
- `textDocument/completion` — `swank:simple-completions`
- `textDocument/hover` — `swank:documentation-symbol`
- `textDocument/signatureHelp` — `swank:operator-arglist`

Everything still resolves through swank; Phase 0's resolver is not
yet wired in. The point of this phase is to get the *transport,
document tracking, and LSP-shape-conversion* layer correct on its
own, with a feature surface that's already useful (parity with the
boring 80% of any LSP).

**Key open questions:**

- Position encoding: LSP wants UTF-16 code-unit offsets, swank
  speaks bytes/chars, nvim's defaults vary. Get the conversion
  right once, centrally.
- didChange merging: full-text vs. incremental sync. Pick one for
  v0; LSP supports both.
- Where the server actually launches from: a script that loads
  swank, loads the LSP package, and starts both? Some part of this
  needs to be `bin/`-shaped before nvim can drive it.
- Does nvim's lspconfig need anything weird (a config snippet) or
  is the standard "cmd = sbcl ..." pattern enough? Test against a
  real nvim early.

Outcome: a working LSP server that nvim can launch via `lspconfig`,
with completion / hover / signatureHelp / global jump-to-def all
working. At this point it's already useful — vlime-parity with no
nvim-specific code.

### Phase 2 — local jump-to-def

Wire Phase 0's resolver into the `definition` handler. On a
`textDocument/definition` request:

1. Phase 0 resolver runs first.
2. If it returns a binder range, return that as a `Location` in the
   same document.
3. If it returns "not local," fall through to Phase 1's swank path.

This is where the project starts being something other tools don't
have. Cursor on a `let`-bound `x` jumps to its `let`. Cursor on a
`labels`-defined helper jumps to its binding. Cursor on a lambda
parameter jumps to the lambda head.

**Key open questions:**

- What does "definition" mean for a `(setf x ...)` site vs. its
  binding? LSP can return multiple locations.
- Should we also implement `textDocument/references` for locals
  (find every other use of the same `let`-bound variable)? Likely
  yes, same machinery.

Outcome: the headline new feature works. v2 ships here if we want
to stop.

### Phase 3 — macroexpansion-aware navigation

The "frigging amazing" version. When the resolved binder is
`result-of-macroexpansion?`:

1. Macroexpand the relevant form (probably `macroexpand-all`).
2. Pretty-print the expansion to a string.
3. Re-read that string with eclector-cst to get positions.
4. Locate the binder within the expansion.
5. Return a `Location` whose URI is a virtual document scheme
   (e.g. `lisp-macroexpand://...`) carrying the expansion ID.
6. Server keeps a small cache: virtual URI → expansion text +
   binder range.
7. Client (nvim, via a small Lua handler) intercepts the URI scheme
   and opens the cached text in a scratch buffer, jumps to the
   range.

This is the only phase with editor-side glue. The Lua handler is
~30 lines but it's the one nvim-specific piece — VS Code, Helix,
etc. would each need their own.

**Key open questions:**

- Single-step vs. fully-expanded: which to show first? Probably
  fully-expanded, but offer "step" as a separate command.
- How readable is the pretty-printed expansion of, say, `iterate`
  or a `with-slots`? May need its own formatting pass.
- Does the cache need invalidation? Probably yes, on any
  `textDocument/didChange` for files involved in the expansion.
- LSP doesn't have a standard for virtual documents — VS Code
  invented `TextDocumentContentProvider`, every other client
  reinvents. Document the protocol shape clearly so other clients
  can implement.

Outcome: a feature SLIME doesn't have. Lisp's macro-heavy code
stops being opaque to "where did this come from."

### Phase 4 — anything else worth doing

Open-ended. Candidates, in rough order of value:

- `textDocument/references` (globally; locals come for free with
  Phase 2)
- `textDocument/codeAction` for "expand macro at point" (no virtual
  doc needed — replace the form in-place as an edit)
- `workspace/symbol` for project-wide symbol search
- Diagnostics: surface SBCL compiler warnings/errors as LSP
  diagnostics on save or on `compile-string-for-emacs`
- Inlay hints for arglists (parameter names next to call-site
  arguments)
- Multi-implementation: CCL, ECL. Mostly a matter of
  `sb-introspect` → portable equivalents.

Each is a discrete project. None are committed to in this plan.

## Sequencing notes

- Phase 0 can ship as its own published library regardless of
  whether the LSP work continues. Generally useful.
- Phases 1 and 2 are the minimum viable product. Phase 3 is the
  feature that makes the project notable.
- Phase 1 has the most LoC; Phase 0 has the most research risk;
  Phase 3 has the most UX risk.

## Open architectural questions still on the table

- **Project layout.** One `defsystem` with everything? Multiple
  systems (`scope-resolver`, `swank-lsp`)? Probably the latter so
  Phase 0 stands alone, but defer.
- **How the server starts.** `sbcl --load start.lisp` from nvim's
  lspconfig is the obvious answer; `bin/swank-lsp` script as
  syntactic sugar; eventually a Roswell / qlot / Docker story for
  install. None of this needs to be solved in Phase 0–1; ship as a
  loadable system first.
- **Naming.** `cl-lsp` is taken (a different abandoned project).
  `swank-lsp`, `swank-bridge`, `lisp-lsp` all candidates. Bikeshed
  later.
- **License.** MIT to match swank. Decide before first push.

## Estimates (very rough — recalibrate per phase)

| Phase | LoC range | Research risk | UX risk |
|---|---|---|---|
| 0 | 200–400 | medium | none |
| 1 | 500–800 | low | low |
| 2 | 100–200 (delta over 1) | low | low |
| 3 | 200–400 + ~30 Lua | medium | high |
| 4 | open | varies | varies |

If totals run dramatically over, that's evidence we missed
something — pause and revisit, don't power through.
