# Plan: `textDocument/references` for globals via swank xref

Cursor on a defun name returns every caller swank's xref index knows
about, as LSP Locations. Cursor on a local binding still uses the
local-references path. Pure addition to `swank-lsp`; no
`cl-scope-resolver` changes.

## What ships

A new `swank-references` strategy in `src/handlers.lisp`. Returns a
list of LSP Locations or NIL.

```lisp
(defun swank-references (ctx)
  ;; intern symbol in buffer's package via with-swank-buffer-package
  ;; call swank/backend:list-callers SYMBOL -> ((label . source-loc) ...)
  ;; convert each source-location via definition-entry->location-info
  ;; filter out :NOT-FOUND / non-file results
  )
```

`references-handler` becomes simple sequential orchestration:

```lisp
(or (and ctx (local-references ctx))
    (and ctx (swank-references ctx))
    +json-null+)
```

Two strategies, but they're not a "framework" -- just two named
operations on different data sources, tried in order.

## Tests

Three wire tests in `tests/local-definition-tests.lisp`:

- `gr` on a defun loaded in the image returns >=1 caller. Use a
  symbol the LSP image always has (`swank-lsp::compute-line-starts`
  or similar).
- `gr` on a symbol with no callers returns null.
- `gr` on a local binding still works (regression guard for the new
  orchestration order).

## Estimate

~40 LoC of source in handlers.lisp, ~50 LoC of tests. One commit.

## What this ISN'T

- **Not a refactor of `local-references` into cl-scope-resolver.**
  That's the right structural move (scope work belongs in the scope
  library) but it's a follow-up commit, not entangled with the
  feature.
- **Not project-wide static analysis.** That's a separate plan
  (`plans/project-wide-references.md`).
- **Not a fallback for things swank's xref doesn't track.** If swank
  doesn't have the caller, we return null. Documented limitation.

## Risks worth surfacing in the commit

- Swank xref misses macro-introduced calls -- functions defined
  inside an expansion sometimes aren't tracked. README's "what works
  today" section will note this.
- `list-callers` returns nothing for non-function symbols (variables,
  classes). Handler returns null for those, which is correct LSP
  behavior.
- Attach mode required for any meaningful result. In auto-spawn the
  image has only `:swank-lsp` and its deps loaded; nothing in the
  user's project. Will note in README.

## After this lands

Open question to revisit: is the local + swank pairing accurate
enough? If users report missed callers, the next move is the
project-wide-references plan -- pure-source scan as a third
information source, complementing swank xref rather than replacing
it.
