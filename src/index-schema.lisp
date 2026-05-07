(in-package #:swank-lsp)

;;;; SQLite schema for the project-wide xref index.
;;;;
;;;; Five tables: files, forms, form_expanded_macros, occurrences,
;;;; chains. See plans/project-wide-references.md for the design and
;;;; rationale for each column / index.
;;;;
;;;; The on-disk file lives at <project-root>/.swank-lsp/index.sqlite.
;;;; The index is *derivative* — every row can be recomputed from
;;;; source by re-analyzing — so schema migrations are
;;;; drop-and-rebuild on version mismatch. No user data lives here;
;;;; users can rm -rf .swank-lsp/ at any time and the next LSP start
;;;; rebuilds.
;;;;
;;;; This module is concerned only with schema lifecycle (create,
;;;; drop, open, version-check). Population (commit 2) and querying
;;;; (commit 4) live in their own modules and consume the connection
;;;; this opens.

(defparameter *current-schema-version* 1
  "Bump when CREATE TABLE statements below change. Triggers
drop-and-rebuild on next OPEN-INDEX. The index is derivative data;
no user content lost.")

(defparameter *index-relative-dir* ".swank-lsp/"
  "Directory under project root holding index.sqlite and any future
co-located cache files. Mirrors how .swank-lsp-port lives at the
project root — index lives one level down so it's clearly grouped
as 'swank-lsp's working dir' rather than scattered loose files.")

(defparameter *index-relative-file* ".swank-lsp/index.sqlite"
  "Index path relative to project root. Single file so users know
exactly what to delete to nuke the index.")

;;;; ---- DDL ----

(defparameter *schema-ddl*
  '(;; Schema versioning.
    "CREATE TABLE _meta (
       key TEXT PRIMARY KEY,
       value TEXT NOT NULL
     )"

    ;; Files: one row per indexed file.
    "CREATE TABLE files (
       id          INTEGER PRIMARY KEY,
       path        TEXT UNIQUE NOT NULL,
       mtime       INTEGER NOT NULL,
       source_hash TEXT,
       analyzed_at INTEGER NOT NULL
     )"

    ;; Forms: one row per top-level form. The `package` column is
    ;; the *PACKAGE* in effect when eclector read this form
    ;; (tracked through (in-package …) directives during indexing).
    ;; Load-bearing for substring re-walks, static defmacro scans,
    ;; and same-name-different-package disambiguation.
    "CREATE TABLE forms (
       id           INTEGER PRIMARY KEY,
       file_id      INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       start_offset INTEGER NOT NULL,
       end_offset   INTEGER NOT NULL,
       package      TEXT NOT NULL
     )"
    "CREATE INDEX idx_forms_file ON forms(file_id)"

    ;; Per-form expanded-macros: which macros each form's analysis
    ;; depended on. The hot path for invalidation: when macro M is
    ;; redefined, SELECT form_id WHERE macro_name=M lists the
    ;; minimal re-analysis worklist.
    "CREATE TABLE form_expanded_macros (
       form_id       INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
       macro_name    TEXT NOT NULL,
       macro_package TEXT NOT NULL,
       PRIMARY KEY (form_id, macro_name, macro_package)
     )"
    "CREATE INDEX idx_fxm_macro ON form_expanded_macros(macro_name, macro_package)"

    ;; Occurrences: one row per symbol-atom in source, with its
    ;; provenance. file_id is denormalized (derivable via form_id)
    ;; to avoid a join on the hot 'all occurrences in this file'
    ;; query.
    "CREATE TABLE occurrences (
       id             INTEGER PRIMARY KEY,
       file_id        INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
       form_id        INTEGER NOT NULL REFERENCES forms(id) ON DELETE CASCADE,
       start_offset   INTEGER NOT NULL,
       end_offset     INTEGER NOT NULL,
       name           TEXT NOT NULL,
       package        TEXT,
       prov_kind      TEXT NOT NULL,
       binder_file_id INTEGER REFERENCES files(id),
       binder_start   INTEGER,
       binder_end     INTEGER
     )"
    "CREATE INDEX idx_occ_name   ON occurrences(name, package)"
    "CREATE INDEX idx_occ_file   ON occurrences(file_id)"
    "CREATE INDEX idx_occ_binder ON occurrences(binder_file_id, binder_start, binder_end)"

    ;; Chains: via-macros chain steps. Separate table (rather than a
    ;; JSON column on occurrences) so 'find all call sites of macro M'
    ;; can be an indexed lookup instead of a table scan with predicate
    ;; over JSON.
    "CREATE TABLE chains (
       occurrence_id INTEGER NOT NULL REFERENCES occurrences(id) ON DELETE CASCADE,
       step_index    INTEGER NOT NULL,
       macro_name    TEXT NOT NULL,
       macro_package TEXT NOT NULL,
       PRIMARY KEY (occurrence_id, step_index)
     )"
    "CREATE INDEX idx_chains_macro ON chains(macro_name, macro_package)")
  "Ordered list of DDL statements. Run in sequence to materialize
the schema. Order matters for FK references.")

(defparameter *schema-table-names*
  '("chains" "occurrences" "form_expanded_macros" "forms" "files" "_meta")
  "All tables, in DROP order — children first so FK cascade isn't
relied on to drop them.")

;;;; ---- Connection lifecycle ----

(defun index-path-for (project-root)
  "Return the absolute pathname of the index file for PROJECT-ROOT.
PROJECT-ROOT is a directory pathname or namestring (trailing slash
optional)."
  (let ((root (uiop:ensure-directory-pathname project-root)))
    (merge-pathnames *index-relative-file* root)))

(defun index-dir-for (project-root)
  (let ((root (uiop:ensure-directory-pathname project-root)))
    (merge-pathnames *index-relative-dir* root)))

(defun ensure-index-dir (project-root)
  "Make sure the .swank-lsp/ dir exists under PROJECT-ROOT."
  (ensure-directories-exist (index-dir-for project-root)))

(defun open-index (project-root)
  "Open (or create) the SQLite index at <PROJECT-ROOT>/.swank-lsp/
index.sqlite. Returns a sqlite:sqlite-handle.

Side effects:
  - Ensures the .swank-lsp/ directory exists.
  - Enables foreign keys on the connection.
  - Calls ENSURE-SCHEMA: creates the schema if absent, or
    drop-and-rebuilds if version doesn't match
    *CURRENT-SCHEMA-VERSION*.

Caller is responsible for CLOSE-INDEX. See WITH-INDEX-CONNECTION
for the auto-close form."
  (ensure-index-dir project-root)
  (let* ((path (index-path-for project-root))
         (conn (sqlite:connect (namestring path))))
    ;; FKs are off by default in SQLite — turn them on per-connection.
    (sqlite:execute-non-query conn "PRAGMA foreign_keys = ON")
    (handler-case
        (progn (ensure-schema conn) conn)
      (error (e)
        (sqlite:disconnect conn)
        (error e)))))

(defun close-index (conn)
  "Disconnect from the index. Idempotent on a NIL conn."
  (when conn (sqlite:disconnect conn))
  nil)

(defmacro with-index-connection ((var project-root) &body body)
  "Open the index for PROJECT-ROOT, bind it to VAR for BODY,
disconnect on unwind."
  `(let ((,var (open-index ,project-root)))
     (unwind-protect (progn ,@body)
       (close-index ,var))))

;;;; ---- Schema lifecycle ----

(defun has-meta-table-p (conn)
  "T if the _meta table exists. Used to distinguish 'fresh DB' from
'existing DB at unknown version'."
  (let ((row (sqlite:execute-single
              conn
              "SELECT name FROM sqlite_master WHERE type='table' AND name='_meta'")))
    (not (null row))))

(defun schema-version (conn)
  "Return the schema version stored in _meta as an integer, or NIL
if the _meta table or the version row is absent."
  (when (has-meta-table-p conn)
    (let ((s (sqlite:execute-single
              conn
              "SELECT value FROM _meta WHERE key='schema_version'")))
      (and s (parse-integer s :junk-allowed t)))))

(defun create-schema (conn)
  "Run the DDL on a connection assumed to be empty. Stamps the
schema version into _meta. Wrapped in a single transaction so a
failure leaves the DB unchanged."
  (sqlite:with-transaction conn
    (dolist (stmt *schema-ddl*)
      (sqlite:execute-non-query conn stmt))
    (sqlite:execute-non-query
     conn
     "INSERT INTO _meta (key, value) VALUES ('schema_version', ?)"
     (princ-to-string *current-schema-version*))))

(defun drop-schema (conn)
  "Drop every table the schema defines. For migration: drop, then
create fresh. Single transaction so we don't leave a half-dropped
DB on error."
  (sqlite:with-transaction conn
    (dolist (table *schema-table-names*)
      (sqlite:execute-non-query
       conn
       (format nil "DROP TABLE IF EXISTS ~A" table)))))

(defun ensure-schema (conn)
  "Bring CONN's schema up to *CURRENT-SCHEMA-VERSION*. Three cases:
  - No schema yet (fresh DB): create.
  - Schema at current version: no-op.
  - Schema at a different version: drop and recreate. The index is
    derivative data; nothing is lost."
  (let ((v (schema-version conn)))
    (cond
      ((null v)
       (create-schema conn))
      ((= v *current-schema-version*)
       nil)
      (t
       (drop-schema conn)
       (create-schema conn)))))
