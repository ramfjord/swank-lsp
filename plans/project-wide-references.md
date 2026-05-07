# Plan: project-wide xref via SQLite index

Make `textDocument/references` (and `textDocument/definition` where
useful) work across files, for globals AND for via-macros bindings.
Persistent SQLite index, refreshed incrementally on save. Hybrid with
swank's xref: union the results, dedup, don't try to choose.

This supersedes the earlier draft of this file, which proposed a
stateless source-scan with no persistence. That model doesn't scale
past small projects and doesn't capture the via-macros chain story
needed for "go to references" inside defmacros.

## Why

`gr` today is local-file only (we land this in the
ANALYZE-and-cache work that precedes this plan). The features that
this plan unlocks:

- **Cross-file references to globals**. Cursor on a defun, find every
  caller across the project.
- **Cross-file references to via-macros bindings**. The
  gr-from-inside-a-defmacro feature — cursor on `,name` in a defmacro
  template, find every call site whose expansion uses the binder.
- **Macro call-site enumeration**. Cursor on `with-service-scope`,
  find every form that invokes it (transitively, through wrapper
  macros).

Swank's xref tables (`who-calls`, `who-references`,
`who-macroexpands`) cover the first item well for *compiled* code in
the image. Our SQLite index covers the rest:

- Files swank hasn't compiled (the user typed `(ql:quickload :foo)`
  but never edited / recompiled file F).
- Via-macros chains: swank doesn't track these. cl-scope-resolver's
  ANALYSIS does.
- Auto-spawn mode (no image loaded at all): swank xref is empty;
  source-only index is the only useful answer.

The two are complementary. The query layer hits both, deduplicates on
`(uri, start, end)`, returns the union.

## Scope estimate

- ~800 LoC. **Entirely in swank-lsp** — cl-scope-resolver needs no
  changes. The orchestration that produces per-form data
  (in-package tracking, form ranges, per-form expanded-macros) lives
  in the indexer, calling `cl-scope-resolver:analyze` per form on the
  form's source substring with `*package*` bound appropriately.
- ~5 commits.
- Two real risks: (a) the byte-stream-translator-on-disk-read story
  for `.elp` (concrete but novel), (b) macro-redefinition invalidation
  via static defmacro scan (interns symbols in the right packages,
  which has a few edge cases).

## Architecture

### Storage: SQLite, 5 tables

```sql
CREATE TABLE files (
  id            INTEGER PRIMARY KEY,
  path          TEXT UNIQUE NOT NULL,
  mtime         INTEGER NOT NULL,        -- file's mtime at last analyze
  source_hash   TEXT,                    -- sha256, optional (for cross-host caches)
  analyzed_at   INTEGER NOT NULL         -- when we wrote these rows
);

CREATE TABLE forms (
  id            INTEGER PRIMARY KEY,
  file_id       INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  start_offset  INTEGER NOT NULL,
  end_offset    INTEGER NOT NULL,
  -- Package context at the start of this form: the *PACKAGE* binding
  -- in effect when eclector read this form. Tracked top-to-bottom
  -- through (in-package …) directives during analyze.
  --
  -- Load-bearing for: re-walking a form in isolation (substring
  -- sending), correctly-interning symbols in static defmacro scans,
  -- and disambiguating same-name symbols across packages.
  package       TEXT NOT NULL
);
CREATE INDEX idx_forms_file ON forms(file_id);

CREATE TABLE form_expanded_macros (
  form_id        INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
  macro_name     TEXT NOT NULL,
  macro_package  TEXT NOT NULL,
  PRIMARY KEY (form_id, macro_name, macro_package)
);
CREATE INDEX idx_fxm_macro ON form_expanded_macros(macro_name, macro_package);

CREATE TABLE occurrences (
  id              INTEGER PRIMARY KEY,
  file_id         INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  form_id         INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
  start_offset    INTEGER NOT NULL,
  end_offset      INTEGER NOT NULL,
  name            TEXT NOT NULL,
  package         TEXT,                  -- nil for uninterned / keyword
  prov_kind       TEXT NOT NULL,         -- 'local' | 'via-macros' | 'none'
  binder_file_id  INTEGER REFERENCES files(id),  -- for prov_kind='local'
  binder_start    INTEGER,
  binder_end      INTEGER
);
CREATE INDEX idx_occ_name      ON occurrences(name, package);
CREATE INDEX idx_occ_file      ON occurrences(file_id);
CREATE INDEX idx_occ_binder    ON occurrences(binder_file_id, binder_start, binder_end);

CREATE TABLE chains (
  occurrence_id  INTEGER NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
  step_index     INTEGER NOT NULL,
  macro_name     TEXT NOT NULL,
  macro_package  TEXT NOT NULL,
  PRIMARY KEY (occurrence_id, step_index)
);
CREATE INDEX idx_chains_macro ON chains(macro_name, macro_package);
```

`occurrences` carries `file_id` redundantly with `form_id` (each form
belongs to one file). The denormalization saves a join on the
hot-path query "all occurrences in file F" — worth it.

`forms.package` is **load-bearing** for several downstream features:

- **Substring re-walk** (deferred optimization): to send only one
  form's source to cl-scope-resolver, we need to bind `*package*`
  before reading; otherwise `(defun foo:bar …)` interns symbols in
  cl-user instead of foo.
- **Static defmacro scan** for invalidation: same problem — we walk
  CSTs looking for defmacro heads, and "this macro is foo:bar vs
  cl-user::bar" depends on the package context at scan time.
- **Symbol disambiguation in queries**: two packages can both define
  `foo`; without a per-form package tag, "find references to foo"
  collapses them.

This is why it's a column on `forms`, not a derived value: we'd
otherwise re-derive it on every refresh by scanning the file
top-to-bottom for in-package directives, which is exactly the work
cl-scope-resolver:analyze is already doing.

### Index location

`<project-root>/.swank-lsp/index.sqlite`. Project root is the
directory containing the LSP root marker (`.git`, `qlfile`,
`qlfile.lock` — same logic the lua plugin uses). One index per
project. Add `.swank-lsp/` to `.gitignore`.

### File enumeration

Filesystem glob: `**/*.{lisp,elp}` under project root, excluding:

- `.git/**`, `.qlot/**`, `tmp/**`, `.swank-lsp/**`
- `**/*.fasl` and other build artifacts (already extension-filtered)
- Anything matching the project's existing `.gitignore` patterns
  (read once at index startup; don't try to live-track gitignore
  edits)

ASDF-aware enumeration (read system definitions, walk components) is
a deferred refinement. Filesystem glob is wrong only for vendored
library directories that don't sit under one of the excluded paths,
and the noise from those is acceptable v1.

### .elp handling — byte-stream-translator on disk reads

Today the translator runs only inside `did-open-handler`. For
project indexing we read files from disk; the translator path
needs to fire there too. Two changes:

1. Generalize `apply-byte-stream-translator` to take a path (or both
   uri+path); dispatch on extension regardless. Existing
   uri-based callers keep working.
2. Indexer reads each file with `read-file-as-string` (already
   exists in handlers.lisp), then runs it through the translator
   before passing to cl-scope-resolver:analyze.

Constraint: the .elp translator only registers when ELP is loaded
into the image. .elp files in projects where ELP isn't loaded get
indexed as-is (and probably fail to read), so they're skipped with
a warning logged. Same constraint already exists in the LSP path;
not a regression.

### Indexing lifecycle

1. **On LSP startup**: schedule a background indexing pass. Walks
   the project, analyzes each unindexed (or stale-mtime) file,
   inserts rows. Async — does not block any LSP request.
2. **Lazy-on-query**: if a cross-file query needs data from a file
   that isn't yet indexed, index that file synchronously before
   answering. (Bounded: one file's analyze is ~10-100ms, acceptable
   in interactive flow.)
3. **Incremental on didSave**: file F was just saved. Pipeline:
   a. Nil F's in-memory analysis (already happens via didChange).
   b. swank:load-file F (already happens in did-save-handler).
   c. **NEW**: re-analyze F → produce new ANALYSIS.
   d. **NEW**: replace F's rows in SQLite (delete by file_id,
      insert from analysis). Single transaction.
   e. **NEW**: identify other files affected by macro
      redefinitions in F (see "Macro redefinition" below). For
      each, schedule re-analyze + SQLite refresh.
4. **No file watcher v1**. External-edit catching (vlime evals,
   editor-external file changes) deferred. The user's stated
   workflow is "save in nvim, didSave fires"; we cover that case.

### Macro redefinition invalidation

When file F is saved:

1. Static-scan F's source for top-level `defmacro` /
   `define-symbol-macro` / `define-compiler-macro` heads (CST-only;
   no eval needed). Collect a list of macro symbols that F (re)defines.

   **Package threading**: scan top-to-bottom, watching for
   `(in-package …)` directives. When we hit a defmacro, intern its
   name in the current package. (`forms.package` actually makes this
   easier post-index — we can also read it from SQLite without
   re-scanning, once F has been indexed once.)

2. For each redefined macro M:
   `SELECT DISTINCT form_id FROM form_expanded_macros
    WHERE macro_name = M.symbol-name AND macro_package = M.package`
   → list of form ids whose analysis depends on M.

3. Group those form_ids by file. For each affected file G:
   - Re-analyze G (whole file; per-form re-analyze is a deferred
     optimization).
   - Replace G's rows in SQLite.

4. In-memory analysis caches: nil any open document whose
   `analysis-expanded-macros` intersects the redefined macro set.
   (Replaces the coarse `invalidate-all-document-analyses`
   currently in did-save-handler.)

This is the load-bearing precision win. Without it, every save
nukes every cache and re-walks every open buffer; with it, most
saves touch nothing besides the saved file.

### Query layer

```lisp
(defun references-handler (params)
  (let ((ctx (build-defn-ctx params)))
    (or (and ctx (merged-references ctx)) +json-null+)))

(defun merged-references (ctx)
  "Union of: local refs (in-memory analysis), project refs (SQLite),
swank xref. Deduplicated on (uri, start, end)."
  (let ((all (append
              (local-references ctx)
              (project-references ctx)
              (swank-references ctx))))
    (and all (dedup-locations all))))
```

- `local-references`: as today; reads in-memory analysis.
- `project-references`: SQLite query against occurrences. Driven by
  the cursor's classification:
  - LOCAL binder → query by (binder_file_id, binder_start,
    binder_end). Catches via-macros chain bottoms in other files
    that resolve to this binder.
  - VIA-MACROS chain ending at macro M → query by chain steps
    mentioning M, plus call-site enumeration via swank:who-macroexpands.
  - Global symbol (cursor on a free reference, walker classifies
    as no local binder) → query by (name, package).
- `swank-references`: wrap `who-calls` / `who-references` /
  `who-macroexpands` as appropriate.

Dedup is on `(uri, start, end)` — the source location is the
identity, regardless of which oracle reported it.

## What this plan deliberately does NOT do

- **No `re-analyze-forms` in cl-scope-resolver.** Whole-file
  re-analyze on save is acceptable v1. Per-form is the optimization
  that earns its keep when files are large and sparse-in-macro-use;
  we add it when profiles say so.
- **No substring-only file reads.** Same logic — eclector parse on
  the rest of the file is ~10-20ms; not worth the package-context
  + offset-translation complexity until it's hot. (`forms.package`
  in the schema is what UNBLOCKS this work later — when we want it,
  we have the data.)
- **No file-system watcher.** External edits not caught v1. Add
  inotify wrapper later if vlime users need it.
- **No ASDF system enumeration.** Filesystem glob is good enough.
- **No multi-process indexer.** SBCL hosting swank-lsp does
  everything. Separate indexer process is a future enabler for
  multiple consumers (claude-code reading the index, etc.).

## How per-form data gets produced (no scope-resolver changes)

cl-scope-resolver:analyze takes a source string and walks every
top-level form in it. To produce per-form data WITHOUT changing
that API, the indexer orchestrates the per-form loop itself:

```
read whole file → cl-scope-resolver:cst-from-string  ; one parse, exposed API
for each top-level CST in source order:
  if (in-package …) form: update tracked-package
  extract form's source substring (CST has start/end)
  bind *package* to tracked-package, call analyze on substring
    → per-call expanded-macros = THIS form's expanded-macros
    → per-call occurrences are 0-based-in-substring
  add form's start_offset to each occurrence's start/end
  insert: forms row (range + tracked-package), form_expanded_macros
          rows (per-call expanded-macros), occurrences rows
```

This costs one extra eclector parse per file (the up-front top-level
walk; analyze re-parses each substring internally). Whether that
matters in practice depends on the file size / form count / image
load-state — not measured yet.

If profiling later shows parse cost is meaningful, the optimization
is a public `cl-scope-resolver:analyze-cst` that accepts an already-
parsed CST instead of a source string. Don't add until we have
numbers.

## Parallelism + worker pool

Re-walking is per-file-independent (one file's analysis doesn't read
or write another file's). With more than a handful of files to
refresh — startup scan or a macro-redefinition fan-out — running
walks in parallel uses available cores. SBCL has native threading
(we already use bordeaux-threads for the LSP server thread); macros
that mutate global state during expansion exist but are rare.

Queue mechanism: **in-memory Lisp queue, NOT SQLite.** Reasoning:

- One process consumes the queue; SQLite-as-queue earns its keep
  for cross-process work distribution (we have none).
- SQLite lacks `SELECT FOR UPDATE SKIP LOCKED` (PG has it; SQLite
  uses `BEGIN IMMEDIATE` with retry-on-lock, which adds latency).
- Crash safety isn't a concern: SQLite is the source of truth for
  what's stale. On restart we re-derive the work-list by comparing
  files' mtimes against `files.analyzed_at` — recovery doesn't need
  a persisted queue.
- In-memory queue gives us the primitives we actually want (cancel,
  pause, drain) at low overhead. lparallel's kernel or a
  bordeaux-threads condition-variable + list works.

Bottlenecks once you parallelize the walks:

- **SQLite writes serialize.** SQLite has one writer at a time
  regardless of WAL mode. Funnel results through a single writer
  thread; workers push `(file-path . rows)` to a write-queue.
  Writer drains, one transaction per file's rows.
- **swank:load-file is serial** — only one didSave fires it,
  already in the LSP request thread.

Cancel-on-edit: while a worker is mid-walk on file F, the user types
in F (didChange arrives). The walk's output will be stale before
it's even written. Track in-flight paths in a hash; `did-change-handler`
flips a cancel token; workers check the token between forms and
bail. Without this, you write stale rows that get clobbered by the
next refresh — wasted work, not incorrect, but worth getting right.

Default worker count: `(max 1 (1- (count-cpus)))` — leave one core
for the LSP request thread + writer.

## Tests

- **Cross-file globals**: `defun foo` in a.lisp; calls in b.lisp
  and c.lisp. `gr` from any of the three returns all three sites.
- **In-memory takes precedence**: edit b.lisp in nvim to add a new
  caller, don't save. `gr` should see the new caller (from
  in-memory analysis), the existing on-disk-indexed callers, no
  duplicates.
- **Macro redef invalidation**: file m.lisp defines macro `m1`; file
  u.lisp uses it. Edit m.lisp to change `m1`'s expansion shape (so
  via-macros chains differ); save. `gr` from a position in u.lisp
  whose chain involves `m1` should reflect the new chain.
- **Macro call sites**: `(defmacro with-x …)` in m.lisp; calls in
  several files. `gr` on `with-x` returns all call sites.
- **gr-into-defmacro**: cursor on a `,name` binder inside a defmacro
  template. `gr` returns positions in call-site bodies that
  reference the bound name.
- **Stale on-disk index**: rm `.swank-lsp/index.sqlite`, restart;
  background pass rebuilds. (Covers the "user blew away the index"
  recovery path.)
- **Per-form package**: file with `(in-package :foo)` then `(defun
  bar …)`. After index, the form row's package is "FOO", not
  "CL-USER". Query for `bar` in package FOO finds it; query in
  CL-USER doesn't.

The cross-file tests can't run in the existing
`bin/nvim-headless-verify.sh` shape (single buffer). We'll need a
multi-buffer test harness: spawn nvim with two files open, drive
requests in both. ~50 LoC of lua.

## Where we are (2026-05-06)

Three commits landed; cross-file query is next.

| Commit  | Status | Notes |
|---------|--------|-------|
| Schema + lifecycle (`d10aabc`) | ✅ | 5 tables + _meta. ON DELETE CASCADE. Drop-and-rebuild on schema-version mismatch. |
| Per-file indexer + git enumeration (`e3eb753`) | ✅ | `index-file`, `index-project`. `git ls-files` for source enumeration; in-package tracking for `forms.package`. |
| Bulk-on-startup + didSave refresh (`2c0f1b1`) | ✅ | Index attached to RUNNING-SERVER. Background bulk thread on start; per-file refresh on save. **No fan-out** — files whose macros depended on the saved file's defmacros stay stale until they're themselves saved. |
| Cross-file query layer | ⬜ | Next. See below. |
| Precise expanded-macros invalidation | ⬜ | Defer until the stale-fanout case actually bites. |
| Multi-buffer verify harness | ⬜ | Needed to actually exercise cross-file gr in the smoke test. |

**Measured indexing cost** (this project, 18 files): 0.45s total, ~25ms/file average. The "1s/file" estimate that was in earlier revisions of this plan was made up; actual numbers are ~40x faster. Bulk pass is sub-second on small/medium projects; ~50s extrapolated for 2000-file projects, still acceptable as a background startup pass.

## Cross-file query: design for the next commit

The piece that makes the index user-visible. `gr` (and eventually `gd`) consults the SQLite index for matches outside the open buffer, unions with in-memory + swank-xref results, dedups on (uri, start, end).

### Three queries the handler needs

The cursor's classification (from the in-memory analysis) determines which SQL runs:

1. **LOCAL binder** — cursor on a local binding or its use. Cross-file refs only meaningful if the binder leaks via macros. Query: `SELECT file_id, start_offset, end_offset FROM occurrences WHERE binder_file_id = ? AND binder_start = ? AND binder_end = ?`. The binder coordinates come from the in-memory cursor occurrence.
2. **VIA-MACROS chain** — cursor on a macro-introduced binder. The chain's macros tell us where the binding came from. Query joins `chains` to find occurrences whose chain shape matches.
3. **Free symbol (NONE)** — cursor on a global. Query: `SELECT … FROM occurrences WHERE name = ? AND package = ?`. This is the bread-and-butter "find references to foo:bar" query.

### Data flow per request

```
references-handler
  → build-defn-ctx (existing — gets cursor offset, doc, etc.)
  → in-memory analysis: classify cursor → LOCAL | VIA-MACROS | NONE | NIL
  → local-references (existing — same-file matches)
  → project-references (NEW)
       with-server-index (conn) → run the appropriate query above
       → list of (uri, start-line, start-char, end-line, end-char)
  → swank-references (NEW — wrap swank:who-calls / who-references / who-macroexpands)
       → list of (uri, range)
  → merge: union, dedup on (uri, start, end)
  → return Location[]
```

### File structure

- `src/index-query.lisp` — `project-references ctx`, `swank-references ctx`, `dedup-locations`. Pure functions of the request context + a connection. Uses WITH-SERVER-INDEX to grab the index.
- `src/handlers.lisp` — the existing `references-handler` becomes a small orchestrator that calls all three sources and merges.

### Open positions are FILE-relative; SQLite holds file paths

Per-file indexer writes file_id (rowid in `files`). To return a Location to the LSP client, we need:
- the file path (look up `files.path` from `file_id`)
- the LSP-position-encoded line/character for `(start_offset, end_offset)`

For position encoding: we read the file from disk, compute line-starts, convert. This is the same machinery handlers.lisp already uses for in-memory documents (`compute-line-starts`, `char-offset->lsp-position`). Cache the line-starts per file — multiple occurrences in the same file share them within one query.

### Estimate

- `src/index-query.lisp`: ~200 LoC. The three SQL queries + dedup + position encoding + line-starts cache. Most code is shape conversion (rows → LSP Location objects).
- `references-handler` rewrite: ~30 LoC. Just orchestration.
- swank-references wrappers: ~80 LoC. Each of who-calls / who-references / who-macroexpands needs a thin wrapper that converts swank's source-location shape to our Location shape.
- Tests: ~150 LoC. Multi-file fixtures under `tests/fixtures/`.

Total ~450 LoC. Roughly the same as the earlier estimate. Single commit.

### What this commit gives the user

`gr` working across files for:
- Globals (the common case): defun in a.lisp, callers in b.lisp / c.lisp / etc.
- Macro call sites: cursor on `with-x`, returns every form that invokes it.
- Cross-file lexical via macros: the gr-from-inside-a-defmacro feature.

What it does NOT give:
- Correct results immediately after redefining a macro in a file other than the one you're querying from. The stale-fanout window. Documented; will be the next commit when it bites.

## Commits

1. **SQLite schema + migrations**. Add cl-dbi + sqlite driver to
   qlfile. Schema as above, in `src/index/schema.lisp`. Migration
   versioning trivial (drop-and-rebuild on version mismatch — the
   index is derivative). ~150 LoC.

2. **Indexer + worker pool**. `src/index/indexer.lisp` +
   `src/index/jobs.lisp`. Filesystem glob,
   byte-stream-translator-on-disk, top-level CST walk with
   in-package tracking, per-form analyze with `*package*` bound,
   offset translation. Worker pool (lparallel or bordeaux), single
   writer thread draining a write-queue, in-flight cancel tokens
   tied to didChange. Background-scan entry point and macro-redef-
   fanout entry point both push into the same queue. ~400 LoC
   (orchestration + concurrency primitives).

3. **didSave precise invalidation**. Replace
   `invalidate-all-document-analyses` with the static-defmacro-scan
   + form_expanded_macros lookup pipeline described above. Refresh
   SQLite for affected files. ~150 LoC.

4. **Query layer + handler integration**. `src/index/query.lisp`
   with `project-references` + `swank-references` (the latter just
   wraps swank's xref calls). `merged-references` orchestrator in
   handlers.lisp. Dedup by location. ~150 LoC.

5. **Tests + multi-buffer verify harness**. ~150 LoC + a few
   fixture files under `tests/fixtures/`.

Total ~1000 LoC. Largest single piece in this project so far.
Expect the indexer + worker pool (commit 2) and the precise-
invalidation logic (commit 3) to each take more than one pass to
get right. cl-scope-resolver needs no changes — see "How per-form
data gets produced" above.

Performance numbers are unmeasured throughout. The plan structure
(per-form analysis, worker pool, async refresh) is shaped by
correctness and concurrency requirements, not by profiling. Add
benchmarks before optimizing.

## Open design questions for first commit

- **Schema-version migration story**: simplest is "drop and rebuild
  on version mismatch" — index is derivative data, no user content
  lost. Alternative: explicit ALTER TABLE migrations. Pick
  drop-and-rebuild; defer real migrations until the schema actually
  evolves.
- **SQLite from threads**: Lisp SQLite bindings have thread-safety
  varying by driver. Use a single connection guarded by a mutex,
  or use cl-dbi's connection pool. Punt to commit 2.
- **What "package" means for an unbound free symbol** in
  occurrences. Probably: the symbol's `symbol-package`. For
  uninterned (gensym-style) symbols, NULL.
- **Package interning vs storage**: forms.package as a TEXT (package
  name) vs an INTEGER (foreign key to a `packages` table). String
  is simpler; integer would denormalize across files. Pick string;
  packages table is a refinement if storage gets large.

## Dependents / blockers

Blocked by: nothing currently in flight. The ANALYZE + cache work
this conversation has been building IS the prerequisite, and it's
landed.

Blocks: gr-into-defmacro (the via-macros gr feature) needs this
plan's project-wide chain query. Macro-call-site enumeration also
needs the chains table. Future "rename" support across files would
also build on this index.
