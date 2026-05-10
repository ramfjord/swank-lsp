# Plan: vendor-rename — drop-in CL package isolation for shippable libraries

**Status:** drafted, not started. Shipping order: this tool first, then use it
to make swank-lsp installable in arbitrary projects without dep conflicts.

## Why this exists

CL has no per-project module isolation (Bundler / Cargo / npm-style). Two
projects sharing one image both `:depends-on ("hu.dwim.walker")` will collide
when their qlot envs cache the same source at different paths and ASDF tries
to compile both copies. We hit this trying to load swank-lsp into
home-media-server's dev image — see the long debug session that ended in a
load-order workaround in `script/dev-image.lisp`. The workaround is fragile
and project-specific.

The general fix the ecosystem doesn't have: **vendor a library's transitive
deps with renamed packages, so the library is drop-in importable into any
host project without conflict possibility.** Like Java's JAR shading, like
some Python apps' vendored renames. This plan ships that as a tool
(`vendor-rename`) and uses it on swank-lsp as the first consumer.

The motivating non-swank-lsp case: any CL library author who wants their
project to be installable alongside arbitrary other libraries gains a path
to publish without paranoid-minimal-deps as the only safe strategy. The
ecosystem norm of "single-file libraries to avoid conflicts" is a coping
mechanism for the missing tooling, not a virtue. This tool is a contribution
toward unblocking that.

## What this is not

- Not a constraint-solving package manager. CL libraries don't have version
  constraints in their .asd files; there's nothing to solve over. Building
  a real solver requires ecosystem-wide adoption of versioned constraints,
  which is years of coordination work. Out of scope.
- Not a replacement for qlot. Sits alongside qlot. qlot installs upstream
  source; vendor-rename produces renamed copies of selected systems for a
  consumer.
- Not aiming for 100% correctness on dynamic package access. Reflection
  patterns (`(find-package (concatenate ...))`) can't be statically rewritten
  without a Lisp evaluator. Documented as a known hole, surfaced via
  diagnostics, addressable case-by-case via manual config.

## How it works (the high-level shape)

Given a config that names systems to vendor and a prefix:

```lisp
(:prefix "swank-lsp"
 :systems ("hu.dwim.walker" "cl-scope-resolver" "jsonrpc")
 :include-deps t
 :exclude-systems ("alexandria" "uiop"))
```

The tool reads the consumer's qlot tree to find materialized source for the
named systems, walks their `.asd` `:depends-on` to determine the full set to
rename, and rewrites every `defpackage` / `in-package` / qualified-symbol
reference / asd `defsystem` name to use the prefix. Result: every renamed
system has a globally distinct name (`SWANK-LSP/HU.DWIM.WALKER` etc.) and
the consumer's `.asd` depends on the prefixed names.

### Two output modes from one engine

1. **Live mode** (the production default): renamed source is written into a
   build-time cache directory (`~/.cache/vendor-rename/<config-hash>/...`),
   ASDF's source-registry points at it, FASL caching works normally. The
   consumer's repo never has a checked-in `vendor/`. Cache is hashed on
   (config + upstream source mtimes); rebuild on change. Cheap to clean
   (`rm -rf` the cache).

2. **Dump mode** (for inspection / golden testing): same engine writes to a
   user-chosen `--output ./vendor/` for diff review, IDE jump-to, debugging.

The cache-dir-as-real-files approach is preferred over pure stream-rewrite
because:
- ASDF's FASL cache is keyed on source pathname; real files preserve it.
- Errors anchor to real source positions for the user.
- `M-.` jump-to-definition lands on the renamed source (slightly weird at
  first, coherent in practice).

### CLI

```
vendor-rename install [--config ./vendor-rename.lisp]   # populate cache, register with ASDF
vendor-rename dump --output ./vendor/                   # write to disk
vendor-rename test --fixtures tests/fixtures/           # golden + behavioral
```

Flags:
- `--prefix <str>`: rename prefix (e.g., "swank-lsp").
- `--systems <comma-list>`: explicit roots.
- `--include-deps`: walk transitive `:depends-on`. Default on.
- `--exclude-systems <comma-list>`: don't vendor these (alexandria, uiop, etc.).
- `--qlot-root <path>`: where to find materialized source. Default: search up.
- `--strict-strings`: fail on suspicious dynamic-pkg-name strings (warn by default).
- `--dry-run`: print intended writes, do nothing.

Or pass a config file (`--config ./vendor-rename.lisp`) for repeatable runs.

## Internal algorithm

**Phase 1 — gather**: read consumer's qlot to find materialized systems;
walk `:depends-on` from each `--system` (excluding `--exclude-systems`);
build the OLD→NEW rename map for both ASDF system names and CL package names
(1:1 in practice).

**Phase 2 — rewrite**: for every `.lisp` and `.asd` in each system:

1. Parse top-level forms via eclector (CL's reader library, exposes form
   positions). For each form:
   - `(defpackage :foo ...)`: rewrite name + `:use` items + `:nicknames`.
   - `(in-package :foo)`: rewrite designator.
   - `(asdf:defsystem "foo" ...)`: rewrite name + `:depends-on` items.
2. Token-level pass over the rest of the file (skipping string literals
   and comments): rewrite qualified symbol references (`OLD:sym`,
   `OLD::sym`, `#:OLD`, `:OLD`).
3. String-literal scan: any string that exactly matches a package name
   in the rename map gets rewritten (`(find-package "FOO")` works).
   Strings that *look like* package designators but aren't exact matches
   are warned (might be dynamic concat); user can mark them in
   `:extra-rename-strings`.
4. Output rewritten text to the corresponding path under the cache dir
   (or `--output`).

**Phase 3 — verify**: try to load each renamed system. Surface load
errors with file/line. The verify pass is what catches "rewrote A but
missed reference B" — purely textual checks would let those through.

**Phase 4 — manifest**: write `vendor-rename.manifest` capturing the
rename map, source git revisions, timestamp. Used to detect drift on
re-runs (warn when upstream has changed since last vendor).

### Why eclector + ppcre, not pure regex

Top-level form structure (defpackage, in-package, defsystem) needs to be
recognized as forms — not as text patterns — because their argument
shapes vary and naive regex misclassifies. Eclector parses CL with form
positions, lets us identify each form's start/end and key sub-positions
(the package name in defpackage, the system name in defsystem). Inside
forms, simpler regex on tokens (with string-literal awareness) handles
the qualified-symbol pass.

## Test approach: tiny fixtures with golden output

Each fixture is a minimal CL package focused on one rewrite case.

```
tests/fixtures/
├── 01-defpackage-rename/
│   ├── README.md             ; one-line description for failure messages
│   ├── config.lisp           ; (:prefix "pfx" :systems ("foo") :smoke-test 'foo:hello)
│   ├── input/
│   │   ├── foo.asd
│   │   └── foo/package.lisp
│   └── golden/
│       ├── pfx-foo.asd
│       └── pfx-foo/package.lisp
├── 02-in-package-and-qualified-syms/
├── 03-defpackage-use-clause/
├── 04-defpackage-nicknames/
├── 05-find-package-string-literal/
├── 06-asd-depends-on-rewrite/
├── 07-cross-file-symbol-references/
├── 08-reader-conditional-sbcl/
├── 09-package-with-shadow-clause/
├── 10-nested-string-literals/
└── 99-real-mini-walker/         ; multi-file, mimics walker shape
```

**Two assertions per fixture**:

1. **Textual**: rewriter on `input/` must produce byte-identical `golden/`.
   Catches accidental output drift; reviewable as a diff in PRs.
2. **Behavioral**: load the `golden/` tree as a fresh ASDF system; call
   the `:smoke-test` function specified in the fixture's config; expect
   it to return T or signal on failure. Catches "I rewrote A but forgot
   to update reference B" — the gold-output diff matched but the
   renamed system doesn't actually load/work.

Adding a case: drop a directory, write input + intended golden + smoke
test, commit. CI-friendly. Run all fixtures: should be sub-second.

## What it can't catch (documented holes)

1. **Dynamically constructed package designators**:
   `(find-package (concatenate 'string "HU.DWIM." "WALKER"))`. Detect
   `find-package` / `intern` calls with non-literal args inside renamed
   systems and emit a warning at scan time.
2. **Macro-built package designators at expansion time**, when the macro
   uses host package names dynamically. These usually break loudly at
   compile time of the renamed copy — surface clearly so user can
   address case-by-case.
3. **Reader macros that build package names at read time** (rare in
   libraries; common in DSLs). Same diagnostic-not-fix posture.

In all cases: report via the manifest's "potential issues" section,
keep building, document as known limitations. The point is to catch
the 95% mechanically; 5% are still better than 0%.

## Project layout (lives inside swank-lsp repo for now)

```
swank-lsp/
├── tools/
│   └── vendor-rename/
│       ├── vendor-rename.asd
│       ├── README.md
│       ├── src/
│       │   ├── package.lisp
│       │   ├── config.lisp        ; parse --config and CLI
│       │   ├── deps.lisp          ; walk asd :depends-on graphs
│       │   ├── rename-map.lisp    ; OLD → PFX/OLD construction
│       │   ├── rewriter.lisp      ; eclector + ppcre pass
│       │   ├── cache.lisp         ; ~/.cache/vendor-rename/ layout
│       │   ├── verify.lisp        ; load-test the output
│       │   └── main.lisp          ; CLI entry point
│       ├── tests/
│       │   ├── package.lisp
│       │   ├── suite.lisp
│       │   ├── runner.lisp        ; fixture-driver
│       │   └── fixtures/
│       │       └── ...
│       └── bin/
│           └── vendor-rename      ; thin qlot-exec shell wrapper
```

Inside the swank-lsp repo because:
- swank-lsp is the first user; co-development convenience matters.
- Cross-PR changes (rewriter handles a new edge case → swank-lsp picks
  it up) live in one repo, atomic commits.
- Eventual extraction to its own repo via `git filter-repo` is cheap
  if the tool matures.

The inner `.asd` declares its own deps (uiop, eclector, cl-ppcre,
alexandria) and doesn't depend on swank-lsp. Conversely, swank-lsp
won't depend on vendor-rename at runtime — it invokes it as a
build step that produces the renamed cache, then loads the
prefixed systems normally.

Tool's deps stay small so the tool itself doesn't have the same
vendoring problem at install time. uiop ships with ASDF; eclector
and cl-ppcre are stable, low-conflict-risk libraries.

## Build sequencing for swank-lsp itself, after the tool exists

1. Add `tools/vendor-rename/` (the tool, with passing fixtures).
2. Author `vendor-rename.lisp` config at swank-lsp's root listing the
   transitive deps to rename (walker, scope-resolver, jsonrpc, plus
   their hu.dwim.* dependencies).
3. Modify swank-lsp's build/load steps to invoke `vendor-rename install`
   before `(asdf:load-system :swank-lsp)`, so the renamed systems are
   on the source-registry by the time swank-lsp itself loads.
4. Update swank-lsp.asd's `:depends-on` from upstream names to
   prefixed names: `"swank-lsp/hu.dwim.walker"`, etc.
5. Verify swank-lsp loads cleanly into a host project's dev image
   alongside whatever the host project already has — the case that
   originally drove this whole thing.
6. Document the install flow in swank-lsp's README.

## Commits (rough sequence)

Each line is a candidate commit; not gospel, expect iteration.

1. `vendor-rename: scaffold (asd, package, README, runner skeleton)`
2. `vendor-rename: fixture 01 — defpackage-rename, end-to-end`
3. `vendor-rename: in-package + qualified-symbol pass (fixture 02)`
4. `vendor-rename: defpackage :use clause (fixture 03)`
5. `vendor-rename: defpackage :nicknames preserves consumer access (fixture 04)`
6. `vendor-rename: find-package string-literal rewrite (fixture 05)`
7. `vendor-rename: asdf defsystem rename + :depends-on rewrite (fixture 06)`
8. `vendor-rename: cross-file symbol references (fixture 07)`
9. `vendor-rename: reader-conditional bodies untouched (fixture 08)`
10. `vendor-rename: shadow clauses (fixture 09)`
11. `vendor-rename: dump mode (--output)`
12. `vendor-rename: cache-dir layout + content-hash invalidation`
13. `vendor-rename: verify pass (load each renamed system as smoke test)`
14. `vendor-rename: manifest output + drift detection on re-run`
15. `vendor-rename: 99-real-mini-walker fixture (multi-file)`
16. `vendor-rename: dynamic-string-literal diagnostic (warn, not fail)`
17. `vendor-rename: bin/vendor-rename shell wrapper`
18. `swank-lsp: vendor-rename.lisp config + asd switched to prefixed deps`
19. `swank-lsp: install instructions in README using vendor-rename`

The ones marked 18-19 are the "swank-lsp benefits from the tool" milestone.
Everything before is the tool itself, fixture-driven.

## Open questions to resolve when starting

1. **First fixture to write**: 01-defpackage-rename, the simplest case. Use
   it to wire up the test harness before tackling harder cases.
2. **Eclector usage shape**: read each top-level form, get its position,
   walk substructure to find sub-positions to rewrite. Open: do we hold
   form objects in memory and emit text from them, or do we use eclector
   purely for positions and emit text via direct string manipulation?
   Leaning toward the latter — direct string manipulation preserves
   formatting/whitespace exactly, which keeps golden diffs readable.
3. **Whether the consumer's .asd is auto-patched**: no, in 0.1. Manual
   edit, documented. Auto-patching is a footgun (can overwrite other
   edits). Could add later behind an explicit flag.
4. **Config file format**: S-expressions match the rest of the
   ecosystem. Alternative would be YAML for tooling-friendliness;
   sticking with sexp for 0.1.
5. **Error-on-warnings during the verify pass**: the tool's verify
   compiles the renamed code. ASDF's `*compile-file-warnings-behaviour*`
   could be tightened to catch problems early, OR loosened so the
   renamed tree loads even with cosmetic warnings. Probably loosen
   for the verify pass — we're not the upstream maintainer; their
   warnings aren't ours to fix.

## The longer-term vision

If this works for swank-lsp, the same mechanism unlocks:

- Other CL libraries adopting "ship with vendored renames" as a
  publishing pattern — relevant especially for libraries that pull
  in the hu.dwim.* family or other broad transitives.
- A `vendor-rename` Quicklisp/qlot publication so others can use it
  by name, not by cloning swank-lsp.
- An eventual blog post / writeup positioning this as a real
  ecosystem contribution (and a portfolio-visible artifact for
  CL ecosystem work).

Not chasing those in 0.1. The discipline is: ship the tool with
swank-lsp as its first user, then react to actual second-user feedback
before generalizing.
