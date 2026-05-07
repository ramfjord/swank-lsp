# Plan: useful return-type render for hover on globals

**Status:** filed-away. Not actively pursued. The headline lexical-type
plan (`plans/lexical-type-inference.md`) supersedes it as the K-feature
worth shipping first; this one is the smaller follow-up.

## Why this is filed, not active

The first attempt (saved on branch `experiment/sbcl-type-info-hover`)
plumbed `sb-introspect:function-type` straight into the markdown hover
under the arglist. Two problems showed up immediately on K:

1. **Args are duplicated.** The arglist already shows the parameter
   list — repeating it in `(FUNCTION (T T) ...)` adds nothing,
   especially since user code rarely declares argument types.
2. **SBCL-internal bound types are unreadable.** `(MOD 17592186044415)`,
   `(UNSIGNED-BYTE 44)`, `(SIMPLE-ARRAY CHARACTER (*))` are the
   compiler's truth but not what a human wants on K.

So the experiment is reverted on main. The registry mechanism
(`*type-info-providers*`, `register-type-info-provider`,
`type-info-string`) and the SBCL provider are saved on the branch and
can be revived.

## What this plan would ship if revived

A "return type only" line on hover, simplified for human reading.

- Drop the args side of the ftype entirely (already in the arglist).
- Strip the `(VALUES X &OPTIONAL)` envelope when there's a single
  primary return type: render as `→ X`. Keep `(values …)` form for
  multi-value returns.
- Translate SBCL-internal bounds via a small simplifier table:
  - `(MOD N)` with N at array-dimension-limit → `(integer 0 *)` or `array-index`
  - `(INTEGER lo hi)` with bounds at fixnum extremes → `integer`
  - `(SIMPLE-ARRAY CHARACTER (*))` → `simple-string`
  - `(UNSIGNED-BYTE 44|62|64)` → `unsigned-byte`
  - Pass through anything else.
- Same simplifier table is shared with the lexical-inference plan
  (which will land first).

## Related: K on a call-site argument

A separate idea that fits here: cursor on `xs` in `(some-fn xs)`.
Look up `some-fn`'s ftype, render the arg-position's type as
"expected: T" or "expected: list". Cheap once the simplifier exists.
Treat as an extension once (B) and (A)-proper are in.

## Estimate (if revived)

~80 LoC: ftype-parser + simplifier + handler integration + tests.
The registry plumbing (~50 LoC) already exists on the branch.

## Source

`git log experiment/sbcl-type-info-hover` for the original plumbing.
