# Phase 2 — wire local jump-to-def

## Pushback / gap-finding (before starting)

Three load-bearing things most likely to be wrong about Phase 2's framing:

1. **Cursor-past-end-of-symbol mismatch.** The resolver
   (`cl-scope-resolver:resolve`) returns `:FOREIGN :NOT-LEAF` unless the
   passed offset lands strictly *inside* `[symbol-start, symbol-end)`.
   Phase 1's existing `extract-symbol-at` is more lenient — it walks back
   from `cursor==end-of-symbol` to identify the symbol. If the LSP
   handler hands the raw LSP-derived offset to the resolver and the
   client put the cursor right after the name, the resolver will fall
   through to swank even though the user clearly meant the local.
   **Resolution:** call `extract-symbol-at` first, pass *its* start
   offset to the resolver. This also means the resolver is asked the
   question "is this symbol local?" rather than "is this exact char a
   leaf?" — which matches the user's mental model.
   *Verified during implementation:* this was real and necessary. The
   `cursor-just-past-symbol-end-still-resolves-local` wire test passes
   only because of this conversion.

2. **Binder-name vs binding-form UX.** Plan asked me to flag this. The
   resolver returns the *binder name* range (the `x` in `(let ((x 1))
   …)`), not the binding form (`(x 1)` or the whole `let`). My read: the
   name is the right target. It's what M-. lands on in slime/sly for the
   binders walker can see, and it matches the user's expectation of "show
   me where this came from." Going with binder name; jumping to the
   `let` keyword would confuse "definition" with "containing form."
   No revision needed.

3. **`:walker-error` falling through to swank may produce misleading
   results.** If `cl-scope-resolver:resolve` errors out on a form
   containing a local `x`, falling through to swank's global lookup
   might return an unrelated global `x`. The supervisor flagged this as
   worth a debate. **Decision:** fall through, with the resolver call
   itself wrapped in `handler-case` so any *internal* exception in the
   resolver is treated identically to `:FOREIGN`. Forcing `+json-null+`
   on `:walker-error` would hide legitimate global resolutions in the
   (much more common) case where the walker bailed on a form whose
   cursor target *was* actually global. The honest framing is "the
   resolver is best-effort; falling through is the conservative shape."
   Documented in `try-local-resolution`'s docstring.

## Estimate (before)

| Field | Value |
|-------|-------|
| LoC   | **150–250 net delta** (plan said 100–200, calibrating up given Phase 0/1 ran 1.7–2.7×). Bulk = ~60-100 LoC of handler branch + ~80-120 LoC of new wire tests + ~20-30 LoC nvim-headless-verify additions. |
| Files touched | **~5**: `swank-lsp.asd` (add depends-on), `lsp-src/handlers.lisp` (add local branch), new `lsp-tests/local-definition-tests.lisp` + `lsp-tests/suite.lisp` (register suite), `bin/nvim-headless-verify.sh` (add local-def check), `reports/phase-2.md`. |
| Wall time | **2–3 hours**. Smallest phase by far; most machinery exists. |

## Actual (after)

| Field | Value |
|-------|-------|
| LoC | **+360 / -26 across 4 commits = net +334**. ~1.3–2.2× over the high end of the estimate. Smaller overrun than Phase 0 (2.1×) or Phase 1 (1.7-2.7×) — but still over. Breakdown: handlers.lisp net +66 (~40 LoC of actual new logic + reshape of surrounding handler / docstrings); `local-definition-tests.lisp` 230 LoC (estimated 80-120; ~2× because each test has fixture + 4-5 `is` assertions); `nvim-headless-verify.sh` 57 LoC added (estimated 20-30; ~2× because vim.lsp.buf_request_sync + URI extraction is verbose); asd + suite 8 LoC. |
| Files touched | **5** (matches estimate exactly): `swank-lsp.asd`, `lsp-src/handlers.lisp`, `lsp-tests/local-definition-tests.lisp` (new), `lsp-tests/suite.lisp`, `bin/nvim-headless-verify.sh`. |
| Wall time | **~1.5 hours.** Faster than estimate — the implementation itself was ~30 minutes, the rest was tests and the headless-verify script. |

**Overrun framing.** The handler logic landed close to estimate
(~40 LoC of substance). The test file is the overrun: 9 wire tests at
20-25 LoC each, where each test has its own `with-defn-fixture`,
positions math, range-end checks, and string-formatted error messages.
Could have been smaller with a `define-local-defn-test` macro
collapsing the position-from-text + assert-binder-range pattern, but
9 tests don't justify the abstraction (per `coding-lisp` skill's
"don't reach for code-as-data unless the problem demands it").

## What surprised

1. **The resolver's "cursor-must-be-on-leaf" semantics weren't obvious
   from the Phase 0 report.** Phase 0 documented `:NOT-LEAF` as a
   `:FOREIGN` reason but didn't emphasize how strict the offset check
   is. I caught it via probe (`(resolve "(let ((x 1)) x)" 14)` →
   `:NOT-LEAF` because offset 14 is `)`, not the `x`). The fix was
   small (use `extract-symbol-at`'s start offset) but easy to get wrong
   if you only read the report.

2. **`extract-symbol-at` returns multiple values; the existing handler
   was discarding `start`/`end`.** It was binding only `sym` because
   that's all the swank path needed. Adding the local branch means
   `start` becomes load-bearing. Tiny change but reads as "the existing
   handler was already collecting half the answer and throwing it
   away."

3. **The shadowing test's expected character was wrong by 1.** I
   miscounted and wrote `19` instead of `20` for the inner `x` binder.
   Caught immediately by the test failing — the resolver got the right
   answer, the test had bad arithmetic. No bug, but a reminder to count
   character positions with `(length (subseq …))` rather than by eye
   for tests.

4. **No new dependencies needed beyond the asd one-liner.** The
   `cl-scope-resolver` library's API surface (one function, four
   return values) composes cleanly with the existing handler. This is
   the architectural payoff of Phase 0 isolating the resolver behind a
   small public interface.

## Architectural simplifications

**Could a different framing make this drastically simpler?** Honest no.

The change is: one branch in one handler, gated by one resolver call.
There's no abstraction left to introduce that wouldn't be heavier
than the thing it replaces. Three candidates I considered:

1. **Inline the resolver call directly in `definition-handler` instead
   of factoring out `try-local-resolution`.** Would shave ~10 LoC, but
   the helper's docstring captures the "swallow resolver errors,
   conservative fall-through" policy in one place. Worth keeping
   separate.

2. **Skip `extract-symbol-at`, pass the raw LSP offset to the resolver,
   and check the resolver's reason code to retry.** Would couple the
   handler to the resolver's reason taxonomy. Current shape — use
   `extract-symbol-at` to identify the symbol, pass its start to the
   resolver — keeps the two layers' contracts orthogonal.

3. **Have the resolver return same-document Locations directly.**
   Would defeat Phase 0's design goal of zero LSP awareness in
   `cl-scope-resolver`. The current shape (resolver answers in
   character offsets, handler shapes to LSP) is correct.

The 360-line diff over 4 commits *is* the smallest correct shape I can
see. The 9 tests + nvim-verify check are not gold-plating — each
covers a distinct binder kind or fall-through path the supervisor
explicitly listed.

## Open seams

**For Phase 4 (anything else worth doing):**

- **`textDocument/references` for locals.** The resolver's
  `:LOCAL` answer gives `(start, end)` for the binder. To find every
  *use* of the same local, the resolver would need a second entry
  point — `find-references-to-binder source binder-start binder-end`
  — that walks the same scope and returns every leaf whose binder is
  EQ to the named binder. Phase 0 didn't expose that, but its
  internal `walker-side bridge` and `cst-only structural binder
  recognizer` already do most of the work. Likely 50-100 LoC in
  `cl-scope-resolver`, then 30-40 in a `references-handler` mirroring
  this phase's branch.

- **`:walker-error` handling.** Currently any walker error from the
  resolver is treated as `:FOREIGN` and falls through to swank, which
  may return a misleading global match for a form that *had* a local
  the walker couldn't see. A more conservative shape would suppress
  the swank fall-through when the resolver errored *and* the symbol
  is a candidate-name that exists in the lexical scope (peek at the
  containing forms for `let`/`flet`/etc binders before falling
  through). Worth doing if users report it as a real confusion;
  premature otherwise.

- **`:macro-introduced` is what Phase 3 is for.** Resolved as
  `:FOREIGN :macro-introduced` today, falls through to swank.
  Phase 3 will intercept this case and macroexpand-then-locate.

- **`:special` shadowing.** A `(declare (special x))` in the body of
  a `let` makes the local `x` dynamic; the resolver correctly
  identifies this as `:FOREIGN :special` and falls through to swank.
  Swank will jump to wherever `x` is `defvar`'d, which is the right
  answer. No action needed.

**For Phase 4 reuse:**

- **`try-local-resolution` is a public-ish helper.** It's currently
  defined alongside `definition-handler` and not exported from the
  package, but its shape is reusable for the future references-handler
  (different shaping of the resolver's `(start, end)` into LSP
  Locations vs LSP Locations[]).

**Behavior the supervisor or downstream phases should know:**

- The local branch returns a *single* Location (not a Location[]),
  because there's exactly one binder per local. The swank path
  returns either a Location, a Location[], or null. LSP clients
  must accept all three shapes (per spec). Verified in tests.

- The local branch's range is in terms of the *negotiated*
  position encoding (utf-8 / utf-16 / utf-32). `char-range->lsp-range`
  is the conversion point and uses the same `*server-position-encoding*`
  the existing handlers do. Multi-byte characters in source should
  Just Work (not exercised in the test corpus, but the conversion
  function is the same one Phase 1 unit-tested for utf-8 / utf-16).

## Test coverage

**Pre-existing baseline preserved:**
- `cl-scope-resolver`: 24/24 checks (corpus suite)
- `swank-lsp` Phase 1 suites: 117/117 checks (position 65, document 18, wire 34)

**New for Phase 2:**
- `local-definition-suite`: **9 wire-level tests, 36 checks**
  - LET-bound use → binder name in same doc
  - LAMBDA param use → param name in same doc
  - LABELS call → defn name in same doc
  - FLET call → defn name in same doc
  - LET multi-line → binder on prior line
  - Inner LET shadowing → inner binder, not outer
  - **Regression guard 1**: global function call (`list`) still falls through to swank, returns Location with sbcl-source URI (not current doc)
  - **Regression guard 2**: free variable (`y`) falls through; result is null *or* a non-current-doc Location
  - Cursor just past symbol end still resolves local

**Total green: 24 + 117 + 36 = 177 checks** via
`(asdf:test-system :cl-scope-resolver)` + `(asdf:test-system :swank-lsp)`.

**Nvim headless verification** (`bin/nvim-headless-verify.sh`):
- All 4 checks pass: hover (existing), definition (existing global),
  **local-definition (new)**, completion (existing).
- The new check writes a temp file containing `(let ((x 1)) (list x))`,
  positions cursor on the use-site `x`, asserts the response Location
  URI equals the temp file URI and the range is `((line 0 char 7),
  (line 0 char 8))` — the binder.

**Verified manually**: the local-resolution check correctly asserts on
the *result* URI (not the request's `params.textDocument.uri`, which
would always equal the buffer URI and produce a false positive). My
first version of the script had this bug — caught by inspecting the
output and noticing the result URI was sbcl-source's `list.lisp`
despite the check passing.

## Cross-phase retrospective

Now that all three phases are done, **is the architecture as simple as
it could be?** Mostly yes. Three observations after sitting with all
three phase reports:

### 1. The CST-only binder recognizer (Phase 0) is buying us a lot

Phase 0's report flagged that the CST-only structural binder
recognizer is ~300 LoC, vs ~250 LoC for the walker-side bridge —
they're roughly equal in size but very different in role. The CST
recognizer handles macroexpanded binders (DOLIST, MVB, DBIND, LOOP),
while the walker handles everything else. Phase 2's local resolution
works for **all** the binder forms in the Phase 0 corpus, including
the macro-expanded ones, *because* of that recognizer. Without it,
DOLIST / MVB / DBIND would all `:foreign :macro-introduced`-fall
through to swank, and the headline feature would be much weaker.

**Implication for follow-up:** the CST-only recognizer is the highest-
leverage subsystem in the project. If we ever ship `cl-scope-resolver`
as a standalone library, the recognizer is the part that should be
published with extension hooks (so users can register binder
patterns for their own macros — `iterate`, `with-slots`, etc.).
The walker bridge is more of a fallback than a primary engine.

### 2. The "wrap as little as possible" principle held — but in test code, not handler code

Phase 1's report framed the 489-LoC handlers.lisp as "what 'wrap as
little as possible' actually looks like once you account for swank's
quirky returns and `*buffer-package*` binding." Phase 2 added ~40 LoC
of *real new logic* for a feature this big — the feature surface
genuinely is small. But Phase 2's test file is 230 LoC for 9 tests.
**The handler-side discipline is working; the test-side discipline
isn't.**

This generalizes: every new handler will need tests that follow the
same shape (open doc, position cursor, send request, assert on
response shape and range). A small `define-wire-defn-test` macro
collapsing the boilerplate would cut test LoC by ~50% as more
features ship. Not worth doing in Phase 2 (9 tests don't justify it),
but **it'd be the highest-leverage simplification for Phase 4 and
beyond**.

### 3. The document store + position module + handlers.lisp split is
one layer too many for the current feature surface

Document store (187 LoC) is its own file because it owns
URI→document state, mutation, and lock. Position module (198 LoC) is
its own file because it owns LSP↔char conversion. Handlers (531 LoC
post-Phase-2) is its own file because it has the dispatched LSP
methods. Everything calls into one or both of the other two.

**Could this be one file?** Probably. The total is ~900 LoC across
three files with strong forward dependencies (handlers → document +
position; document → position). One `swank-lsp.lisp` file with three
`;;;; --- section ---` headers would be the same logical structure
without the file boundary. The file split is doing nothing
dispatch-wise (no separate ASDF compilation unit benefits, no test
isolation — all live in `:swank-lsp` package).

**My recommendation:** *leave them split.* The friction of
"navigating between files" is real but small; the *signal* that
"these are three logical concerns" is genuine. If a reader opens
`handlers.lisp` first and never has to read `document.lisp`, the file
split bought something. The cost is one extra `(:file …)` line per
module in the asd, which is nothing.

### THE one cross-phase simplification I'd most strongly recommend

**Extract a thin test macro** in `lsp-tests/`:

```lisp
(defmacro define-wire-test (name &key uri text method line character
                                      assert-result)
  ...)
```

This collapses the boilerplate every wire test currently repeats:
ensure server, open client socket, initialize+open document, build
position params, send request, bind result, run assertions. Phase 1
would shrink (10 wire tests), Phase 2 would shrink (9 wire tests),
and any future handler (references, codeAction, workspace/symbol)
would shrink in the same shape. Estimated win: ~40-50% LoC reduction
in `lsp-tests/wire-tests.lisp` and `lsp-tests/local-definition-tests.lisp`.

Why this and not anything else: it's the only simplification I can
see that **scales sub-linearly with new feature work** — every future
LSP method added to the server will pay this cost again under the
current test shape. Everything else I considered (file mergers,
helper consolidations, `cl-scope-resolver` interface tweaks) saves a
constant amount of LoC and doesn't compound.

A reasonable Phase 4 prelude is "extract the test macro, then add
references." Two commits, second one ships a feature, first one makes
the test layer smaller forever.
