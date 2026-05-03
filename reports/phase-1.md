# Phase 1 — minimal LSP server, swank-backed, nvim-driveable

## Pushback / gap-finding (before starting)

Three load-bearing things most likely to be wrong in Phase 1's framing:

1. **stdio LSP + swank both want `*standard-output*`.** swank prints
   warnings (`WARNING: Reference to unknown variable Y…` was noted in
   Phase 0) to `*error-output*`/`*standard-output*`, and ASDF loads
   spam stderr. If the stdio LSP entrypoint doesn't isolate the pair
   before starting, errant bytes corrupt the LSP frame stream and
   nvim disconnects. The fix is small (rebind `*standard-output*` and
   `*error-output*` to a log file before starting), but easy to
   forget. **Will do this in the entrypoint and document it.**
   *Verified during implementation:* this was real, AND there's a
   second instance — jsonrpc's mapper calls `dissect:present` on
   uncaught handler errors, which writes to `*standard-output*`.
   Wrapped every handler with `safe-handler` to never let an error
   reach the dispatcher. See "What surprised" #2.

2. **`jsonrpc` `params` arrive as a yason hash-table** (not a plist).
   Confirmed by reading `request-response.lisp`: `dispatch` invokes
   the handler with `(funcall handler (request-params request))`,
   where `params` came out of `jsonrpc/yason:parse`. So handler shape
   must `(gethash "uri" (gethash "textDocument" params))` — no plist
   destructuring. Easy once you know it; ugly to discover via failed
   test. Documented in handler module.
   *Verified.* Also verified that yason encodes results from handlers
   correctly when they're hash-tables of strings/numbers/lists; the
   one trap was JSON null — `'yason:null` doesn't encode as null,
   `:null` (the keyword) does. Defined `+json-null+` as `:null`.

3. **`positionEncoding` negotiation might not work the way the plan
   hopes.** LSP 3.17's `general.positionEncodings` requires the client
   to advertise it; modern nvim does (since 0.10) but the value is
   "utf-16" by default. The server can offer "utf-8" only if it
   appears in the client's list. Plan: implement both conversions,
   select UTF-8 when client offers it, fall back to UTF-16. **Verify
   in nvim headless test that both modes work.**
   *Verified.* nvim 0.x (current) advertises `["utf-8", "utf-16"]`
   when we set `capabilities.general.positionEncodings` in the
   `vim.lsp.start` call. The server picks utf-8. Negotiation logic
   tested with a unit test plus a wire test that explicitly offers
   only utf-16 and asserts utf-16 is chosen.

## Estimate (before)

| Field | Value |
|-------|-------|
| LoC | 700–1100 (plan says 500–800; bumping for jsonrpc API friction, position-encoding round-trip tests, and the integration-test client helper) |
| Files touched | ~15 |
| Subsystems | (a) jsonrpc transport + LSP framing wrapping (jsonrpc handles framing, we wire start/stop); (b) UTF-16/UTF-8/char position conversion; (c) in-memory document store keyed by URI with full-text didChange; (d) handler module — one defun per LSP method, each a thin swank passthrough; (e) stdio entrypoint that isolates stdio from swank chatter; (f) tests/client.lisp helper for socket-based wire tests; (g) nvim config snippet + headless verification script |
| Wall time | 4–6 hours |

## Actual (after)

| Field | Value |
|-------|-------|
| LoC | **1866 across 13 source files** + 35-line .asd. **~1.7–2.7× over estimate.** Within the same overrun shape as Phase 0 (2.1×). |
| Files touched | 13 source files: `swank-lsp.asd`, `lsp-src/{package,position,document,handlers,server}.lisp`, `lsp-tests/{package,suite,client,position-tests,document-tests,wire-tests}.lisp`, `bin/{swank-lsp-stdio.lisp,nvim-headless-verify.sh}`. Plus `qlfile`/`qlfile.lock` updates, `~/.config/nvim/lua/plugins/swank-lsp.lua`. |
| LoC by area | handlers 489 (the bulk); wire tests 238; position 198; document store 187; server lifecycle 172; tests/client 162; bin/stdio entry 121; position tests 101; bin/headless-verify (bash) 85; document tests 63; suite 24; package 23 |
| Subsystems | All seven from the plan, no surprises. |
| Wall time | ~5 hours, within estimate. |

The LoC overrun is mostly in **handlers.lisp (489 LoC)** — this includes
position helpers, the swank↔LSP shape conversions for completion
items, definition locations, hover content, signature labels, and
all the defensive error wrappings. The plan's "wrap as little as
possible" principle was followed; 489 LoC is what "as little as
possible" actually looks like once you account for null handling,
package-name extraction from the buffer, swank's quirky return
shapes, and the `with-swank-buffer-package` helper (see surprise #3).
**Test-side LoC (627 across 6 files) is half the total** — that's
appropriate for an integration boundary the plan explicitly called
out as the right place to test.

## What surprised

1. **`'yason:null` does not encode as JSON null.** Yason errors with
   "No policy for symbols as keys defined." `:null` (the keyword)
   does encode as null. Spent ~10 min debugging a "shutdown handler
   times out" before realizing the encoding error was crashing the
   processing thread silently. Fix: `(defparameter +json-null+ :null)`.

2. **jsonrpc/mapper writes uncaught handler errors to
   `*standard-output*`** via `dissect:present`. Over stdio this
   corrupts the LSP wire framing — nvim sees raw backtrace text
   prepended to the actual `Content-Length:` of the next response and
   complains "Content-Length not found in header." The fix is to
   wrap every handler in a `handler-case` that returns `+json-null+`
   on error, so no error reaches the framework's printer. Done via
   `safe-handler` in `server.lisp`. This is the kind of bug pure
   wire-level integration tests catch immediately and unit tests
   never would.

3. **swank entry points assume the swank emacs-rex caller has bound
   `swank::*buffer-package*`.** Calling
   `swank:find-definitions-for-emacs` from outside the emacs-rex
   protocol → `UNBOUND-VARIABLE`. swank's `eval-for-emacs` binds it
   from the buffer's package name. We need to do the same. Wrote
   `with-swank-buffer-package` macro in handlers.lisp; every swank
   call is wrapped. This is the *actual* "wrap as little as
   possible" — it's the minimum to make swank functions callable.

4. **jsonrpc TCP transport spawns per-connection threads inside the
   listener thread, with no cleanup hook.** When a test fixture's
   `with-test-server` destroyed the listener thread, the per-conn
   threads remained alive, each holding the previous `*server*`
   reference. Stuck on `usocket:wait-for-input` for 10s ticks. The
   second test's connection accepts fine, but state ambiguity makes
   the suite go silent. **Solution:** the test fixture starts ONE
   shared server and resets state between tests
   (`reset-document-store`, `reset-server-state`,
   `*server-position-encoding*`). The exit-handler test specifically
   tears down the shared server and re-creates it for downstream
   tests. Honest call: "we can't cleanly tear down jsonrpc TCP" is a
   library limitation, not something to work around with more
   plumbing.

5. **The line-starts cache slot collides with the position module's
   line-starts function.** Both wanted to be called
   `document-line-starts` — the struct slot accessor (`document-`
   conc-name) and the position module's standalone function. Renamed
   the function to `compute-line-starts`, kept the slot accessor.
   Trivial in retrospect; spotted only when ASDF's load order made
   the ambiguity visible.

6. **Phase 0's package surface (`swank-lsp/internal`) was not the
   right shape.** I started with a parallel `swank-lsp/internal`
   package re-exporting "internal" symbols for tests. But CL packages
   are about symbol identity — interning a symbol in
   `swank-lsp/internal` vs `swank-lsp` makes them different symbols,
   even if `:export` lists the same name. The function definitions
   live under `swank-lsp::name`. Dropped the wrapper package; tests
   use `swank-lsp::name` (double-colon = "I'm reaching past the
   public boundary"), which is a more honest signal. ~15 LoC
   reclaimed.

## Architectural simplifications

**Could a different framing make this drastically smaller?** Three
candidates considered:

1. **Drop the wire integration tests, do everything via direct
   handler calls.** The handler functions are pure — they take a
   params hash and return a result hash. Calling them in fiveam
   without a socket would be cheap. *Rejected* — the user explicitly
   asked for wire tests, and three real bugs (yason:null, dissect on
   stdout, *buffer-package* binding) would have been *invisible*
   without wire-level tests because they all live in the
   server-process layer.

2. **Skip the position-encoding negotiation, always use UTF-16 (the
   LSP default).** Would let me delete ~50 LoC of negotiation +
   utf-8 conversion. *Rejected* — Phase 2 will be calling into
   eclector for byte/char offsets, and bytes-vs-chars is the hard
   conversion. Owning the encoding layer here means Phase 2 doesn't
   re-derive it.

3. **Don't write a stdio entrypoint; tell users to TCP-only.**
   Would let me skip `bin/swank-lsp-stdio.lisp` and the
   stdout-corruption gymnastics. *Rejected* — nvim's lspconfig
   defaults to stdio, and "must run a side TCP server in your dev
   image" is a barrier the plan explicitly wanted to avoid. Stdio is
   what makes this drop-in for any LSP client.

The 1866 LoC ships the full feature surface the plan requires; I
don't see a different framing that'd cut it dramatically without
either dropping a real requirement or moving complexity into Phase 2.

## Open seams

**For Phase 2 (wiring in `cl-scope-resolver`):**

- **Definition handler currently walks `swank:find-definitions-for-emacs`
  → produces `Location[]` with file:// URIs.** Phase 2's resolver
  returns `:LOCAL` with character offsets in the *current* document.
  Branching shape: `(if (eq :local kind) (range-in-current-doc ...)
  (call-swank-definition ...))`. The current handler's
  `definition-entry->location-info` builds the LSP Range from a file
  path + 1-based offset; Phase 2 will need an analogous helper that
  builds a Range from `(uri, char-start, char-end)` directly.

- **Position conversion is centralized.** All handlers compute
  `(line-starts text)` once and pass it through to
  `lsp-position->char-offset`. Phase 2 should reuse the same idiom.

- **Document store API is stable.** Phase 2 just calls
  `(get-document uri)`, `(document-text doc)`. The internal struct
  has `line-starts` cached for re-use.

- **`current-package-for-document` is intentionally
  best-effort** — scans the first 4KB for `(in-package ...)`, returns
  "CL-USER" if not found. Phase 2 may want to fall back to walker
  context (the AST knows what package it's in). Keep the same name
  so callers don't have to choose.

- **Handler dispatch is *not* yet abstracted into a "framework."**
  This was deliberate (per the plan). When Phase 2 adds local
  resolution, it should *modify the existing definition handler*, not
  introduce a new layer. If a third or fourth handler has the same
  shape, *then* extract.

**For Phase 4 (anything else):**

- **`textDocument/references`** — Phase 0's resolver could return
  same-name uses by walking the AST again. Handler shape would
  mirror `definition-handler`.
- **Diagnostics** — would require a "compile" hook;
  `swank:compile-string-for-emacs` returns conditions in a structured
  shape. Can be added without touching transport.

## Test coverage

**117 checks across 3 suites, all green via `(asdf:test-system
:swank-lsp)`:**

- **POSITION-SUITE** (65 checks, 9 tests): unit tests for
  `lsp-position->char-offset` / `char-offset->lsp-position` /
  `negotiate-position-encoding`. Covers ASCII, multi-line LF, multi-line
  CRLF, CR-only line endings, em-dash UTF-8 (3-byte), em-dash UTF-16
  (1-unit BMP), supplementary-plane emoji UTF-16 (surrogate pair),
  supplementary-plane emoji UTF-8 (4-byte), supplementary-plane UTF-32
  (1 unit), full round-trip across all three encodings on a mixed
  string, and encoding negotiation under all reasonable client
  capability shapes.

- **DOCUMENT-SUITE** (18 checks, 8 tests): store-and-lookup,
  symbol-extraction at various cursor positions, package-qualified
  symbols, completion-prefix extraction, and `(in-package ...)` parsing
  in three syntactic forms (`:keyword`, `#:uninterned`, `"string"`).

- **WIRE-SUITE** (34 checks, 10 tests): every test opens a TCP socket,
  speaks framed JSON-RPC, asserts on the response shape:
  - `initialize` handshake (capabilities, server info, position encoding)
  - `initialize` falling back to UTF-16 when client only offers UTF-16
  - `didOpen` storing a document, `didClose` removing it
  - `didChange` (full sync) replacing text + version
  - `definition` returning a Location for a known global
  - `completion` returning a CompletionList including expected items
  - `hover` returning Hover.contents with non-empty value
  - `signatureHelp` returning a SignatureInformation
  - `shutdown` returning JSON null result
  - `exit` stopping the server, then restarting for downstream tests

The wire-test client helper (`lsp-tests/client.lisp`, ~150 LoC) does
the framing/JSON serialization. Other tests are 5-15 lines each.

## Nvim verification

**Config snippet added** at
`~/.config/nvim/lua/plugins/swank-lsp.lua` (gitignored from this
repo; lives in the user's nvim dotfiles). Pattern matches the existing
`alive-lsp.lua` plugin in the same directory:

- Spawns `qlot exec sbcl --script ~/projects/swank-lsp/bin/swank-lsp-stdio.lisp`
  on `FileType lisp` (falls back to plain `sbcl --script` if qlot is
  not on PATH).
- Advertises `general.positionEncodings = {"utf-8", "utf-16"}` so the
  server can negotiate utf-8.
- Uses `name = "swank-lsp"` so it coexists with alive-lsp (different
  client name), letting you compare or run both during development.

**Headless smoke test** (`bin/nvim-headless-verify.sh`):

- Opens a tiny .lisp file, positions the cursor on `list`, asks for
  hover. Asserts the response includes "Documentation".
- Same buffer, asks for definition. Asserts a `uri =` field appears
  in the response (i.e. at least one Location returned).
- Switches to a `(forma` buffer, asks for completion at end of
  `forma`. Asserts an `items =` field appears in the response.

**All three checks pass.** The script's output:

```
=== hover ===
OK: textDocument/hover ... value = "Documentation for the symbol LIST: ..."
=== definition ===
OK: textDocument/definition ... uri = "file:///usr/share/sbcl-source/src/code/list.lisp" ...
=== completion ===
OK: textDocument/completion ... items = { { detail = "-f-------", documentation = "COMMON-LISP:FORMAT", label = "format" }, ...
All checks passed.
```

Caveat: the user's nvim config emits some startup chatter
(`mason-lspconfig.nvim was renamed`, vlime auto-attach noise) that
adds noise to `nvim --headless` output. The verify script greps for
`OK:` / `FAIL:` markers to ignore it.

## Stdio vs TCP decisions

**TCP** is the test transport. `swank-lsp:start-server :transport
:tcp :port 0` picks a free port (returned via `server-port`); tests
open sockets and send framed messages. State is per-process; the
test fixture shares one server across the suite (see surprise #4)
and resets state between tests.

**Stdio** is the production transport. nvim's lspconfig spawns
`sbcl --script bin/swank-lsp-stdio.lisp` per `FileType lisp` attach.
The entrypoint:

1. Captures the real stdin/stdout *first*, before any `(load …)` call
   that could write to them.
2. Redirects `*standard-output*`, `*error-output*`, `*trace-output*`,
   `*debug-io*` to a log file (`/tmp/swank-lsp.log`) so qlot/ASDF/swank
   chatter during load doesn't corrupt the wire.
3. Loads quicklisp/qlot setup, pushes project root onto
   `*central-registry*`, loads `:swank-lsp`.
4. Optionally starts swank on `$SWANK_LSP_ATTACH_SWANK_PORT` (off by
   default) so nvlime/Vlime can attach to the same process.
5. Calls `swank-lsp:start-server :transport :stdio :input
   <real-stdin> :output <real-stdout>` and blocks.
6. Wraps the start in `handler-case` for `END-OF-FILE` so client
   disconnect exits cleanly via `(uiop:quit 0)`.

**Wrinkle**: `jsonrpc/transport/stdio` reads the `:input`/`:output`
initargs at `make-instance` time, so the redirection of
`*standard-output*` *must* happen before `start-server` is called AND
the entrypoint must pass explicit `:input :output` initargs pointing
at the *captured* original streams. My first attempt had the order
wrong — the transport got the redirected log stream as its output —
and silently sent nothing back to nvim. Fixed; documented in the
entrypoint script.
