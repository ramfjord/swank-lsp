(in-package #:swank-lsp/tests)

;;;; Tests for project-references / dedup-locations / row->location.
;;;;
;;;; The cross-file gr path: cursor names a symbol; SQLite returns
;;;; every other occurrence of (name, package). Verified by setting
;;;; up a temporary git project with two .lisp files cross-
;;;; referencing each other, indexing it, and asserting the right
;;;; locations come back.
;;;;
;;;; swank-references isn't tested here — it requires the symbol
;;;; to actually be loaded into the image, which is awkward to set
;;;; up in unit tests. Covered indirectly via the headless verify
;;;; once we add the multi-buffer harness.

(in-suite all-tests)

;;;; ---- Helpers shared with indexer-tests.lisp ----
;;;;
;;;; (fresh-tmpdir-named, cleanup-tmpdir, write-test-file,
;;;;  git-init-and-add are defined in indexer-tests.lisp.)

;;;; ---- row->location ----

(test row->location-basics
  "row->location wraps (path, char-start, char-end) into the LSP
Location shape with a file:// URI and the correct line/character."
  (let ((root (fresh-tmpdir-named "query")))
    (unwind-protect
         (let* ((path (write-test-file
                       root "x.lisp"
                       "(defun foo (x) x)
")))
           (let* ((cache (make-hash-table :test 'equal))
                  ;; cursor on the second `x` (offset 15)
                  (loc (swank-lsp::row->location
                        cache (namestring path) 15 16)))
             (is (not (null loc)))
             (let* ((range (gethash "range" loc))
                    (start (gethash "start" range))
                    (end (gethash "end" range)))
               (is (search "x.lisp" (gethash "uri" loc)))
               (is (= 0 (gethash "line" start)))
               (is (= 15 (gethash "character" start)))
               (is (= 0 (gethash "line" end)))
               (is (= 16 (gethash "character" end))))))
      (cleanup-tmpdir root))))

;;;; ---- dedup-locations ----

(defun loc (uri start-line start-char end-line end-char)
  "Test helper: build an LSP Location."
  (swank-lsp::make-lsp-location uri start-line start-char end-line end-char))

(test dedup-locations-removes-duplicates
  "Two identical locations dedup to one."
  (let ((a (loc "file:///x.lisp" 1 2 1 5))
        (b (loc "file:///x.lisp" 1 2 1 5))
        (c (loc "file:///y.lisp" 0 0 0 3)))
    (let ((result (swank-lsp::dedup-locations (list a b c))))
      (is (= 2 (length result))))))

(test dedup-locations-preserves-order
  "First occurrence wins; relative order of unique entries is kept."
  (let ((a (loc "file:///x.lisp" 1 2 1 5))
        (b (loc "file:///y.lisp" 0 0 0 3))
        (a-dup (loc "file:///x.lisp" 1 2 1 5)))
    (let* ((result (swank-lsp::dedup-locations (list a b a-dup)))
           (uris (mapcar (lambda (l) (gethash "uri" l)) result)))
      (is (equal '("file:///x.lisp" "file:///y.lisp") uris)))))

;;;; ---- project-references via the SQLite query ----
;;;;
;;;; We build a tiny project, index it, then exercise
;;;; project-references against a synthetic CTX. project-references
;;;; needs WITH-SERVER-INDEX to find a connection — we open the
;;;; index directly and bind *server* to a stub that exposes it.

(defun stub-server-with-index (conn root)
  "Build a RUNNING-SERVER-shaped object that just carries the
index conn + a lock, so project-references can pull them via
WITH-SERVER-INDEX."
  (let ((s (make-instance 'swank-lsp::running-server
                          :jsonrpc nil
                          :transport-kind :tcp)))
    (setf (swank-lsp::running-server-index-conn s) conn
          (swank-lsp::running-server-index-lock s)
          (bordeaux-threads:make-lock "test")
          (swank-lsp::running-server-index-root s) root)
    s))

(test project-references-finds-cross-file-name
  "Symbol foo defined in a.lisp and called from b.lisp. With cursor
on foo in b.lisp, project-references returns a location in a.lisp
too."
  (let ((root (fresh-tmpdir-named "query-xref")))
    (unwind-protect
         (let* ((a (write-test-file
                    root "a.lisp"
                    "(defun foo () 42)
"))
                (b (write-test-file
                    root "b.lisp"
                    "(defun caller () (foo))
")))
           (git-init-and-add root '("a.lisp" "b.lisp"))
           ;; Build the index by hand.
           (swank-lsp::with-index-connection (conn root)
             (swank-lsp::index-project conn root)
             ;; Stub the server so WITH-SERVER-INDEX finds the conn.
             (let ((swank-lsp::*server* (stub-server-with-index conn root)))
               (unwind-protect
                    ;; Synthesize a CTX with cursor on `foo` in b.lisp.
                    ;; b.lisp text: "(defun caller () (foo))"
                    ;;                                  ^ char 18
                    (let* ((b-text (with-open-file (in b)
                                     (let ((buf (make-string (file-length in))))
                                       (read-sequence buf in)
                                       buf)))
                           (b-uri (swank-lsp::path->file-uri (namestring b)))
                           (doc (swank-lsp::make-document
                                 :uri b-uri :text b-text :version 1
                                 :language-id "lisp"))
                           (ctx (swank-lsp::make-defn-ctx
                                 :doc doc :text b-text :uri b-uri
                                 :sym "FOO" :sym-start 18
                                 :line-starts
                                 (swank-lsp::compute-line-starts b-text)
                                 :pkg "COMMON-LISP-USER"))
                           (results (swank-lsp::project-references ctx)))
                      ;; Expect at least one location in a.lisp.
                      (is (not (null results)))
                      (is (some (lambda (loc)
                                  (search "a.lisp" (gethash "uri" loc)))
                                results)))
                 (setf swank-lsp::*server* nil)))))
      (cleanup-tmpdir root))))

(test project-references-skips-local-bindings
  "Cursor on a LOCAL binding doesn't fan out to project-wide query —
that would conflate same-name distinct lexical bindings."
  (let ((root (fresh-tmpdir-named "query-local")))
    (unwind-protect
         (let* ((a (write-test-file
                    root "a.lisp"
                    "(let ((x 1)) x)
")))
           (git-init-and-add root '("a.lisp"))
           (swank-lsp::with-index-connection (conn root)
             (swank-lsp::index-project conn root)
             (let ((swank-lsp::*server* (stub-server-with-index conn root)))
               (unwind-protect
                    (let* ((text (with-open-file (in a)
                                   (let ((buf (make-string (file-length in))))
                                     (read-sequence buf in)
                                     buf)))
                           (uri (swank-lsp::path->file-uri (namestring a)))
                           (doc (swank-lsp::make-document
                                 :uri uri :text text :version 1
                                 :language-id "lisp"))
                           ;; cursor at 13 = the body x (the use)
                           (ctx (swank-lsp::make-defn-ctx
                                 :doc doc :text text :uri uri
                                 :sym "X" :sym-start 13
                                 :line-starts
                                 (swank-lsp::compute-line-starts text)
                                 :pkg "COMMON-LISP-USER")))
                      (is (null (swank-lsp::project-references ctx))))
                 (setf swank-lsp::*server* nil)))))
      (cleanup-tmpdir root))))
