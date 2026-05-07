(in-package #:swank-lsp/tests)

;;;; Tests for the SQLite index schema lifecycle (commit 1 of the
;;;; project-wide-references plan).
;;;;
;;;; Covers: open creates the .swank-lsp/ dir + the SQLite file,
;;;; ensure-schema is idempotent on a fresh DB, version mismatch
;;;; triggers drop-and-rebuild, foreign keys actually enforce.
;;;; No queries against populated data here — that's commits 2 and 4.

(in-suite all-tests)

(defun fresh-tmpdir ()
  (let* ((base (uiop:temporary-directory))
         (name (format nil "swank-lsp-index-test-~A-~A/"
                       (get-universal-time)
                       (random 1000000)))
         (p (uiop:merge-pathnames* name base)))
    (ensure-directories-exist p)
    p))

(defun cleanup-tmpdir (dir)
  (uiop:delete-directory-tree (uiop:ensure-directory-pathname dir)
                              :validate t
                              :if-does-not-exist :ignore))

(defmacro with-tmp-project ((root-var) &body body)
  `(let ((,root-var (fresh-tmpdir)))
     (unwind-protect (progn ,@body)
       (cleanup-tmpdir ,root-var))))

(test index-open-creates-dir-and-file
  "OPEN-INDEX creates .swank-lsp/ and index.sqlite under the project root."
  (with-tmp-project (root)
    (swank-lsp::with-index-connection (conn root)
      (is (typep conn 'sqlite:sqlite-handle))
      (is (probe-file (swank-lsp::index-dir-for root)))
      (is (probe-file (swank-lsp::index-path-for root))))))

(test index-fresh-stamps-current-version
  "ENSURE-SCHEMA on a fresh DB writes *CURRENT-SCHEMA-VERSION*."
  (with-tmp-project (root)
    (swank-lsp::with-index-connection (conn root)
      (is (= swank-lsp::*current-schema-version*
             (swank-lsp::schema-version conn))))))

(test index-reopen-is-noop-when-version-matches
  "Opening an existing index with matching version doesn't recreate
the schema (we'd see preserved rows in _meta if it weren't dropped)."
  (with-tmp-project (root)
    ;; First open: creates schema.
    (swank-lsp::with-index-connection (conn root)
      (sqlite:execute-non-query
       conn
       "INSERT INTO _meta (key, value) VALUES ('test_marker', 'present')"))
    ;; Second open: should NOT drop & recreate; marker survives.
    (swank-lsp::with-index-connection (conn root)
      (is (string= "present"
                   (sqlite:execute-single
                    conn
                    "SELECT value FROM _meta WHERE key='test_marker'"))))))

(test index-version-mismatch-rebuilds
  "If the on-disk schema version doesn't match the code's current
version, ENSURE-SCHEMA drops and recreates. The marker doesn't
survive."
  (with-tmp-project (root)
    ;; First open: stamp a marker plus a stale version.
    (swank-lsp::with-index-connection (conn root)
      (sqlite:execute-non-query
       conn
       "INSERT INTO _meta (key, value) VALUES ('test_marker', 'present')")
      (sqlite:execute-non-query
       conn
       "UPDATE _meta SET value='999' WHERE key='schema_version'"))
    ;; Second open: version 999 ≠ current → drop & recreate.
    (swank-lsp::with-index-connection (conn root)
      (is (= swank-lsp::*current-schema-version*
             (swank-lsp::schema-version conn)))
      (is (null (sqlite:execute-single
                 conn
                 "SELECT value FROM _meta WHERE key='test_marker'"))))))

(test index-foreign-keys-enforced
  "Inserting a forms row referencing a nonexistent file_id must
fail with the FK violation. SQLite has FKs OFF by default; we turn
them on per-connection."
  (with-tmp-project (root)
    (swank-lsp::with-index-connection (conn root)
      (signals sqlite:sqlite-error
        (sqlite:execute-non-query
         conn
         "INSERT INTO forms (file_id, start_offset, end_offset, package)
          VALUES (999, 0, 10, 'CL-USER')")))))

(test index-cascade-deletes-children
  "Deleting a file should cascade to its forms and the forms'
expanded-macros + occurrences. Verifies ON DELETE CASCADE wiring."
  (with-tmp-project (root)
    (swank-lsp::with-index-connection (conn root)
      ;; Set up: one file, one form, one expanded-macro, one occurrence.
      (sqlite:execute-non-query
       conn
       "INSERT INTO files (id, path, mtime, analyzed_at)
        VALUES (1, '/tmp/x.lisp', 0, 0)")
      (sqlite:execute-non-query
       conn
       "INSERT INTO forms (id, file_id, start_offset, end_offset, package)
        VALUES (10, 1, 0, 50, 'CL-USER')")
      (sqlite:execute-non-query
       conn
       "INSERT INTO form_expanded_macros (form_id, macro_name, macro_package)
        VALUES (10, 'WHEN', 'COMMON-LISP')")
      (sqlite:execute-non-query
       conn
       "INSERT INTO occurrences (id, file_id, form_id, start_offset, end_offset,
                                 name, prov_kind)
        VALUES (100, 1, 10, 5, 8, 'X', 'local')")
      ;; Sanity: rows present.
      (is (= 1 (sqlite:execute-single conn "SELECT COUNT(*) FROM files")))
      (is (= 1 (sqlite:execute-single conn "SELECT COUNT(*) FROM forms")))
      (is (= 1 (sqlite:execute-single conn "SELECT COUNT(*) FROM form_expanded_macros")))
      (is (= 1 (sqlite:execute-single conn "SELECT COUNT(*) FROM occurrences")))
      ;; Drop the file: everything below should cascade.
      (sqlite:execute-non-query conn "DELETE FROM files WHERE id=1")
      (is (zerop (sqlite:execute-single conn "SELECT COUNT(*) FROM forms")))
      (is (zerop (sqlite:execute-single conn "SELECT COUNT(*) FROM form_expanded_macros")))
      (is (zerop (sqlite:execute-single conn "SELECT COUNT(*) FROM occurrences"))))))
