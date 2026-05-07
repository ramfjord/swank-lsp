# Plan: type inference on hover for lexical bindings

K on a lexical binding (let / let* / mvb name; defun or lambda
parameter) shows the SBCL-derived type of the binding, simplified to
human-readable form. The headline payoff is the user's `hi` example:

```lisp
(let ((lo 0)
      (hi (1- (length line-starts))))
  …)
```

K on `hi` should say something like `→ integer`, not "undefined."

## How

The mechanism is verified: compile a throwaway lambda whose body is the
init-form, then read SBCL's derived type back via
`sb-introspect:function-type`. Internally we call this the "compile-derive"
trick; the entry point is `compile-derived-type-of`.

```lisp
(sb-introspect:function-type
 (compile nil '(lambda (line-starts)
                (1- (length line-starts)))))
;; => (FUNCTION (T) (VALUES (INTEGER -1 17592186044414) &OPTIONAL))
```

- Free vars of the init-form become T-typed parameters of a synthetic
  lambda.
- SBCL compiles it and gives us the derived return type.
- A simplifier maps SBCL-internal bound forms (`(integer -1 N)`,
  `(simple-array character (*))`, …) to readable specs (`integer`,
  `simple-string`, …).
- `(values X &optional)` envelope is stripped to just `X` for the
  common single-value case.
- Render `→ TYPE` as one extra markdown line in the hover.

## What ships

`src/derived-type.lisp` — pure-functional core:

- `extract-init-form (analysis source binder-start)` — given a binder
  position from cl-scope-resolver and the source string, return the
  init form (sexp) and the binder kind (`:let`, `:let*`, `:mvb`,
  `:lambda-param`, `:other`). Reads the surrounding top-level form
  via Eclector with source positions, walks to the binder, plucks the
  init expression off the canonical shape of its parent.
- `free-vars-of (sexp)` — symbols at variable position in SEXP that
  aren't bound by SEXP itself. Walker recognises `let`/`let*`/`lambda`
  and the special-form list; treats everything else as a function
  call. Tolerates quote / function / backquote.
- `derive-type (init-form free-vars)` — wrap in
  `(lambda (free-vars…) (declare (ignorable …)) init-form)`,
  `(compile nil …)`, read return type via
  `sb-introspect:function-type`, return the simplified spec.
- `simplify-type (spec)` — small lookup-table simplifier:
  - `(mod n)` with n ≥ array-dimension-limit → `(integer 0 *)`
  - `(integer lo hi)` with bounds at fixnum extremes → `integer`
  - `(simple-array character (*))` → `simple-string`
  - `(unsigned-byte n)` for 44/62/64 → `unsigned-byte`
  - `(or X X)` collapses to `X`
  - Pass-through otherwise.

`src/handlers.lisp` — hover-handler integration:

- After computing the existing arglist + docstring path, ask the
  document analysis: is the cursor on a `local` provenance with a
  binder we can handle?
- If yes, derive the type and append a `→ TYPE` line to the hover
  markdown. Cache on `(document-version, binder-start)`.

The `*type-info-providers*` registry from the saved experiment is
**not** revived for this work. The lexical path is direct: it needs
position + analysis, not just a symbol. The registry made sense for
implementation-keyed function-type lookups; the lexical case is a
different shape and gets its own narrow API. (`global-hover-return-type.md`
keeps the registry on hold.)

## Binder kinds in v1

| Form | Init source | Status |
|---|---|---|
| `let` | the `INIT` in `(NAME INIT)` | yes |
| `let*` | same, with earlier `let*` bindings in scope as free vars | yes |
| `multiple-value-bind` | nth value of the values-form (pluck the nth `(values …)` element) | yes |
| `defun` / `lambda` parameter | declared type from the body's `(declare (type X PARAM))` if any, else `T` | yes (declared-type only) |
| `destructuring-bind`, `dolist`, `loop for`, etc. | complicated; would need per-form shape rules | no — return nil, hover unchanged |
| `via-macros` provenance | no syntactic init-form available | no — return nil |

The "no" cases degrade gracefully: hover stays as it is today (arglist
+ docstring or nothing). The user's `hi` example is `let`, the most
common case, and lands in v1.

## Tests

Unit tests in a new `tests/derived-type-tests.lisp` (added to suite):

- `extract-init-form` on synthetic source strings: let / let* / mvb
  binders, returns correct sexp + kind.
- `free-vars-of` on representative forms: respects quote, recognises
  let/lambda binders as shadowing.
- `compile-derived-type-of` end-to-end on the user's exact example,
  `(concatenate 'string …)`, declared-fixnum arithmetic.
- `simplify-type` table: each rewrite rule has one positive case and
  one pass-through case.

Wire test in `tests/wire-tests.lisp`:

- Open a buffer with the user's `let`+`hi` shape, K on `hi`, assert
  the hover value contains the simplified type.
- K on a defun parameter with a `(declare (fixnum …))` shows `fixnum`.
- K on a binder we don't handle (e.g. `dolist`) returns the existing
  hover shape unchanged (regression guard).

## Commits

Mechanism-first ordering — ship raw types, see what's actually noisy
in real use, then add a simplifier whose rules are observed rather
than speculative. Mirrors the "raw, I'll filter" preference and the
`feedback_special_case_smell` discipline: don't preemptively branch
on N noisy forms when we haven't seen which ones bite.

1. **`compile-derived-type-of` + unit tests** on direct sexp inputs.
   No source-walking yet. Verifies the compile-derive trick on
   representative forms (`(1- (length xs))`, declared-fixnum
   arithmetic, `(concatenate 'string …)`, undefined-fn graceful
   degradation).
2. **Source-walking pieces** (`binder-at-cursor`, `extract-init-form`,
   `enclosing-lexicals`, `local-declares-for`) + unit tests.
3. **Hover integration + cache + wire tests.** Feature ships here,
   raw output, no simplifier yet.
4. **Simplifier**, only after we've used (3) and named the rules that
   matter. Pure data transform; can land any time after (3).

## Estimate

~250–300 LoC total, four files touched:

- `src/derived-type.lisp` — new, ~120 LoC
- `src/handlers.lisp` — ~30 LoC change in `hover-handler` + hookup
- `tests/derived-type-tests.lisp` — new, ~80 LoC
- `tests/wire-tests.lisp` — ~30 LoC of new wire tests
- `swank-lsp.asd` — register the new file (and SBCL-gate it via
  `:if-feature :sbcl`, since `sb-introspect` is the engine; on other
  impls the file isn't loaded and hover gains no `→ TYPE` line)

Subsystems: scope-resolver consumption (extending what we already do
for `gd`), source-walking via Eclector, synth-lambda compile, hover
handler.

## What this ISN'T

- **Not interprocedural inference.** We don't propagate types from
  call sites into parameters of called functions. K on a defun's
  parameter shows declared type or T, full stop.
- **Not a static analyzer.** SBCL's compiler does the analysis; we're
  just arranging the inputs and reading the output.
- **Not portable to non-SBCL.** Other impls have similar machinery
  (CCL has `ccl::function-type`, etc.) and could be added behind the
  same `derive-type` interface, but v1 is SBCL-only and the file is
  `:if-feature :sbcl`-gated.

## Risks worth surfacing

1. **Compile cost.** A `compile` per hover would be wasteful; cache
   keyed by `(document-version, binder-start)` makes the hot path
   a hash lookup. Compile itself is sub-millisecond for these sizes;
   the cache is for amortising across re-hovers of the same binder.
2. **Free-var walker correctness.** A walker that misses a binding
   form will list a bound name as free, the synth-lambda will shadow
   the outer binding, and the derived type will be `T` instead of
   useful. Mitigated by leaning on the same canonical-binder list
   `cl-scope-resolver` already uses; lifted into our code if the
   library doesn't expose it cleanly.
3. **Init-form references undefined functions.** `function-type` of
   the synth-lambda becomes `T` because SBCL has no signature for the
   call. Result: no useful type, simplifier returns the symbol "T".
   We elide the `→ TYPE` line in that case rather than show `→ T`.
4. **Side-effecting init-forms** (`(let ((x (launch-rocket))) …)`).
   We `compile` the synth-lambda but never call it, so no side
   effects. Verified.
5. **`let*` ordering.** The walker has to thread earlier-binding names
   into scope for later inits. Easy in principle, easy to get wrong
   in code. Tests cover the case explicitly.
6. **`multiple-value-bind`.** Plucking the nth `(values …)` element
   means parsing the values-form's function-type rather than just the
   primary type. Worth one test.

## Demonstrable outcome

Before: K on `hi` says "hi is undefined".
After: K on `hi` shows the arglist (none, it's a binder), and
`→ integer`. K on `s` in `(let ((s (concatenate 'string a b))))`
shows `→ simple-string`. K on a defun parameter declared
`(fixnum n)` shows `→ fixnum`.
