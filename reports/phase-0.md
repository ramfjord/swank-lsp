# Phase 0 — `cl-scope-resolver`

## Pushback / gap-finding (before starting)

Three claims about the framing in the plan, written down before I committed to an approach:

1. **API shape — `(values :local s e) / (values :foreign nil nil)` collapses two
   cases the next phase will want to distinguish.** "I confidently determined
   this is global / special / quoted" and "I bailed on the form" both want to
   fall through to swank, but the *reason* matters for diagnostics. Resolution:
   add a fourth value `REASON` (a keyword), keep `KIND` binary so Phase 2's
   branching stays trivial.
2. **"byte-offset" vs character-index is load-bearing and unspecified.**
   Eclector counts `read-char` calls, so its source positions are character
   offsets (0-based, end-exclusive), not bytes. UTF-8 disagrees with characters
   as soon as a multi-byte character appears. Resolution: define the API in
   **character offsets**, matching eclector. Phase 1 already has to do
   UTF-16↔char for LSP; let it own the byte/char conversion too. Documented
   in `RESOLVE`'s docstring and `cst-from-string`'s docstring.
3. **`hu.dwim.walker`'s surface needs verification, not assumption.** The plan
   names `result-of-macroexpansion?` as the macroexpansion-seam hook. The
   walker version Quicklisp ships may or may not match. Resolution: empirical
   first — `describe` the walker's exports before designing around any
   specific slot.

**Verified after starting:** all three concerns landed correctly.
`result-of-macroexpansion?` exists and is set on macro-introduced bindings.
`map-ast` and `collect-variable-references` are exported (the plan doesn't
mention them but they're load-bearing for the bridge).

## Estimate (before)

| Field        | Value |
|--------------|---|
| LoC          | 250–400 |
| Files touched | ~7: `cl-scope-resolver.asd`, `src/{package,cst,walk,resolver}.lisp`, `tests/{package,corpus,suite}.lisp`, `qlfile`, `qlfile.lock` |
| Subsystems   | (a) eclector-cst wrapper → CST nodes with positions; (b) walker wrapper → AST with binder info; (c) bridge: walker AST node ↔ CST source range, by name + lexical scope; (d) test corpus + runner |
| Wall time    | 3–5 hours |

## Actual (after)

| Field        | Value |
|--------------|---|
| LoC (resolver alone) | 1037 (842 non-comment) — **2.1× over estimate** |
| LoC (whole library)  | ~1450 across 9 files |
| Files touched        | 9 (matches estimate) |
| Subsystems   | (a) eclector-cst wrapper (~70 LoC, as estimated); (b) walker wrapper (~25 LoC, smaller than estimated — the walker exposes enough that no real wrapper layer is needed); (c) **bridge — both halves**: walker-side bridge (~250 LoC) AND a CST-only structural binder recognizer (~300 LoC) for forms the walker macroexpands; (d) sentinels for special / symbol-macrolet / quoted / declarations (~100 LoC); (e) corpus + suite (~265 LoC) |
| Wall time    | ~4 hours (within estimate) |

## What surprised

**Three significant surprises drove most of the overrun:**

1. **The walker stores raw cons cells in its AST `source` slot — but for
   *atom* references, the source is just the symbol object, which is `EQ`
   across every occurrence of the same name in a form.** This means
   `(eq walker-source cst-raw)` works to disambiguate cons positions but
   *cannot* disambiguate two uses of the same symbol. Worked around by
   keying on the parent cons + child index instead of the atom itself.
   This is the architectural cost of the walker not knowing about
   positions; not solvable without rewriting the walker's traversal.

2. **The walker macroexpands aggressively.** `(dolist (i …) …)`,
   `(multiple-value-bind (a b) …)`, `(destructuring-bind (a b) …)`,
   `(let* ((x 1) (y x)) …)`, `(loop for i …)` — all of these have AST
   nodes whose `source` slot points at the *whole macro form*, not the
   binder name. The walker correctly identifies that `i` is bound, and
   correctly resolves uses of `i` to the binding form, but the binding
   form's source position is "the entire dolist form." Useless for jump-to-def.
   Resolution: a parallel CST-only structural binder recognizer that runs
   *first* for known binder forms (LET/LET*/LAMBDA/DEFUN/FLET/LABELS/
   DOLIST/DOTIMES/MVB/DBIND/LOOP), maintaining a lexical environment as
   it walks the CST. The walker handles the rest.

   This duplication is the bulk of the 2× LoC overrun. It's not gold-plating
   — the walker's macroexpansion is genuinely lossy and there's no way
   around it short of pre-expansion (Phase 3 territory).

3. **`WALKED-LEXICAL-APPLICATION-FORM` doesn't have a child node for its
   function name.** For `(helper 5)` where `helper` is FLET-bound, the
   walker emits a single application form whose `definition-of` is the
   FLET binding — there's no separate `walked-lexical-function-reference`
   node for the cursor to land on. Had to special-case "cursor on operator
   of a lexical-application-form" in the bridge.

**Smaller surprises:**

- `loop`'s `for` (and `as`/`with`/`into`) is genuinely simple in the CST
  if you can find adjacent `for VAR` / `with VAR` / `into VAR` patterns
  — a 15-LoC recognizer covers the basic case. Full LOOP grammar isn't
  needed for the binder question.
- LOOP's `WARNING: Reference to unknown variable Y in Y.` from the walker
  on the `free-variable` corpus case is harmless noise; the walker prints
  to stderr but resolution still works.

## Architectural simplifications

**Could a different framing make this drastically smaller?** I considered
two alternatives during exploration:

1. **CST-only resolver, no walker at all.** Would handle ~80% of the corpus
   with the structural binder recognizer alone. Punts on
   special-declared shadowing (correctly identified as `:foreign :special`
   today via walker), `result-of-macroexpansion?` introspection (would
   need to be detected by name only), and any binder forms not in the
   recognizer's hardcoded list. *Not strictly smaller* — the recognizer
   still needs the same ~300 LoC for the macroexpanded forms; we'd lose
   the ~250 LoC bridge but gain similar-sized additions for the
   sentinel paths the walker handles today. **Wash.**

2. **Walker-only, with eclector for positions only.** Doesn't work — see
   surprise #2. The walker loses positions for any macroexpanded form.
   This is the "obvious" approach the plan suggests, and it bottoms out
   at ~50% corpus coverage (LET/LAMBDA/FLET/LABELS/DEFUN only).

**The hybrid (what I shipped) is the smallest correct shape I can see**
given the available tooling. The 2× overrun is real and is the price of
honest macroexpansion handling.

A genuinely smaller approach would require either (a) a position-preserving
walker (none exists), or (b) accepting "ask swank" for everything but the
simplest forms (which defeats the headline feature). Neither is a Phase 0
move.

## Open seams

**Things that fall into `:foreign` and Phase 2 will route to swank:**

- `:special` — declared SPECIAL is dynamic; the binder is the same name
  but the lookup goes through the symbol's value cell, not lexical scope.
  Swank knows where the `defvar` lives.
- `:symbol-macro` — `SYMBOL-MACROLET` rewrites the name at expansion time;
  the "binder" is structurally a name but semantically a macro. Phase 3
  (macroexpansion-aware nav) is the right home for this.
- `:quoted` — cursor on a quoted symbol; not a reference.
- `:not-a-reference` — cursor on a name in `(declare …)` (TYPE / IGNORE /
  DYNAMIC-EXTENT) or operator of a free function call — the LSP layer
  may want to use swank's `find-definitions-for-emacs` to jump to a
  global definition.
- `:macro-introduced` — walker's `result-of-macroexpansion?` is true for
  the binding. Phase 3 territory.
- `:walker-error` — walker refused the form. Falls through to swank.
- `:no-form` / `:not-leaf` / `:not-a-symbol` — cursor not on a symbol.
- `:unresolved` — fall-through; bridge couldn't determine.

**Behavioral nuances Phase 2 should know:**

- LOOP's binder recognizer is the **basic case only** (`for`/`as`/`with`/
  `into VAR`). LOOP destructuring (`for (a . b)`), step-arithmetic
  variables introduced by `for X = Y then Z`, and named accumulator
  bindings work because `cst-find-binder-in-tree` walks atoms recursively.
  But the recognizer doesn't *parse* LOOP; surprising LOOP shapes will
  fall through to walker (which often fails on LOOP, → `:walker-error`
  or `:foreign`).
- The CST-only fast path runs for the listed binder forms; anything
  outside that list (e.g. `BLOCK` references, `TAGBODY` tags, `RETURN-FROM`)
  will fall through to walker. Walker handles BLOCK/TAGBODY tags but
  again: macroexpansion drops their positions. Not in the corpus today.
- `compiler-let` (deprecated, not in corpus) will currently behave as
  a function call (atoms inside fall through to walker) — likely
  `:walker-error`.

**API stability for Phase 2:**

- `(resolve source-string offset)` returns 4 values:
  `(KIND START END REASON)`. `KIND` is `:LOCAL` or `:FOREIGN`. When
  `:LOCAL`, START/END are inclusive/exclusive 0-based **character**
  offsets pointing at the binder *name* (not the binding form). When
  `:FOREIGN`, START/END are NIL, REASON is one of the keywords above.
- The package also exports `cst-from-string`, `cst-source-range`, and
  `cst-at-offset` for diagnostics in Phase 2 — callers can inspect what
  CST node a given offset lands on.

## Test coverage

**Corpus: 24 cases, all green via `(asdf:test-system :cl-scope-resolver)`.**

Covered categories:
- LET / LET* / LET-shadowing
- LAMBDA params / DEFUN params
- FLET (function call site) / LABELS (recursive call site)
- DESTRUCTURING-BIND (flat + nested)
- DOLIST / DOTIMES (LET+BLOCK expansion)
- MULTIPLE-VALUE-BIND
- &OPTIONAL / &KEY params
- LOOP `for-as` (basic)
- Cursor on the binder itself
- WHEN-body (macroexpansion seam, simple case)
- Free variable, global function, declared SPECIAL — all `:foreign`
- SYMBOL-MACROLET — `:foreign :symbol-macro` (policy: punt to swank)
- Quoted symbol at cursor — `:foreign :quoted`
- Use of a symbol that also appears quoted nearby

**NOT covered (and how the resolver behaves):**

- `BLOCK` / `RETURN-FROM` — block names; walker handles, positions
  would be lost on macro expansion of `LOOP`/`DO`. Likely `:foreign`.
- `TAGBODY` / `GO` — tag names. Same story.
- Deeply nested LOOP with destructuring or `=`/`then` step variables.
- `compiler-let` (deprecated).
- `MACROLET` body resolution (binders are recognized, but the
  expansions are post-walker — currently `:macro-introduced`).
- Multi-byte / Unicode identifiers (the resolver works on character
  offsets and would handle them; not exercised).
- Forms with reader macros producing non-standard CSTs (e.g.,
  `#+sbcl` conditionals, custom `#!` reader macros).
- Real-world complex `defmethod` with method qualifiers and specializers.
- Files with multiple top-level forms where the cursor is on a later
  form (works in principle; not tested).
