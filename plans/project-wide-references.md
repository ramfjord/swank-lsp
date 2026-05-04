# Plan: project-wide static analysis for references

Add a third information source for `textDocument/references`:
purely-static analysis of the user's project source files. Composes
with swank's image-based xref; doesn't replace it.

## Why

Swank's xref index sees post-macroexpansion call sites the compiler
recorded. That's powerful but has gaps:

- Functions defined inside macro expansions sometimes don't get
  tracked.
- Code loaded but not compiled may be missing.
- `(eval ...)`-introduced code escapes static recording.
- Auto-spawn LSP mode has nothing of the user's project loaded, so
  swank's index is effectively empty for user code.

A pure-source project scan complements this:

- Sees every literal call site in source, regardless of compilation
  state.
- Works in auto-spawn mode (no image loaded).
- Catches callers in code that has not yet been loaded into the
  image.
- Sees calls in commented-out / dead code (some users want this,
  others don't; configurable later).

The two are complementary, not competing. Real `gr` accuracy = the
union of both, deduplicated.

## Where it lives

In `cl-scope-resolver`, not `swank-lsp`. New API:

```lisp
(cl-scope-resolver:find-references-in-project
  source-strings    ; list of (file-path . source-string)
  cursor-source     ; the buffer the cursor is in (in source-strings)
  cursor-offset)
```

Returns a list of `(file-path source-start source-end)`. Pure
function: no IO, no image queries. swank-lsp builds the
`source-strings` list (from ASDF + the document store) and passes it
in.

This keeps the layering clean per the user's preference: scope work
in the scope library, orchestration in the LSP layer. No image
hooks, no opt-in callbacks -- the API is what it is.

## How swank-lsp uses it

`references-handler` orchestration grows a third call:

```lisp
(or (and ctx (local-references ctx))
    (and ctx (project-references ctx))   ; new
    (and ctx (swank-references ctx))
    +json-null+)
```

Or, with merging (probably better):

```lisp
(merge-locations
  (local-references ctx)
  (project-references ctx)
  (swank-references ctx))
```

`merge-locations` deduplicates by URI + range. Local refs always
included; project + swank merged for cross-file coverage.

## Building the source list

`swank-lsp` enumerates files in two ways:

1. Open documents from the document store (the user's edits, freshest
   source).
2. Files belonging to the project's ASDF system (anything not open in
   a buffer reads from disk).

For libraries: skipped by default. The "find references to my-foo"
case rarely needs to scan library code (libraries don't call user
code). Could add an `:include-libraries` opt-in later if users want
references inside library macros that touch their symbols.

## Caching / performance

For small projects (~20-200 files): no cache needed. Cold scan is
sub-second. Re-parse on every request is fine.

For larger projects: build a per-project parse cache keyed by
file-mtime. Invalidate per-file on `didChange` / `didSave`.
clojure-lsp's pattern via clj-kondo is the reference.

Don't build the cache until profiling shows the cold scan hurts.

## Library-macro nuance (the user's question)

Pure-source scan can't see callers that only exist post-macroexpansion
of a library macro. Example:

```lisp
;; in some library:
(defmacro defservice (name &body body)
  `(defun ,name () ,@body))

;; in user code:
(defservice my-foo (do-stuff))
;; user-code source has zero textual references to defun;
;; image has a defun named MY-FOO that "calls do-stuff"
```

For cases like this:
- Project-scan misses the call `do-stuff` from `my-foo` (no source
  text says it).
- Swank xref CATCHES it (compiler saw the post-expansion `(defun
  my-foo () (do-stuff))`).

Hence the union: project-scan + swank xref together cover both
"source-only" and "image-only" call sites.

If we ever want to catch the converse case ("library macro that
expands to a binding the user references"), we'd need to expand
library macros in the static analyzer. That requires having library
source loaded. Possible but expensive; punt until needed.

## Tests

- Cross-file: defun in `a.lisp`, callers in `b.lisp` and `c.lisp`.
  `gr` from any of the three returns all 3 sites.
- Doc-store wins over disk: edit `b.lisp` in nvim to add a new
  caller, don't save. `gr` should see the new caller (from doc
  store), not the on-disk version.
- Library exclusion: a defun in user code referenced by a library
  function -- project-scan returns only user-code refs. Swank xref
  may return the library ref (if it's in the image). Document the
  difference.

## Estimate

- `cl-scope-resolver:find-references-in-project`: ~120 LoC in the
  resolver + ~80 LoC of tests. One PR there.
- `swank-lsp` integration: ~60 LoC. Build source-list, merge results,
  one commit here after the resolver PR lands.

## When to build this

After the simpler swank-xref `gr` lands and gets used. If the gaps
people hit are mostly "missed callers in unloaded code" or
"auto-spawn mode is useless for `gr`", project-scan is the answer.
If the gaps are mostly "macro-introduced callers not tracked in
xref," that's a different problem (and project-scan doesn't help
either).

Wait for actual usage to tell us which gaps matter most.
