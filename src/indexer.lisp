(in-package #:swank-lsp)

;;;; Per-file indexer + project enumeration.
;;;;
;;;; Reads source from disk, runs cl-scope-resolver:analyze per
;;;; top-level form with the right *package* binding, serializes
;;;; occurrences + chains + per-form deps into the SQLite index
;;;; opened by index-schema.
;;;;
;;;; Synchronous (no worker pool yet — deferred per the
;;;; project-wide-references plan, possibly indefinitely).
;;;;
;;;; Two public entry points:
;;;;   INDEX-FILE conn path     — reindex one file (replace its rows)
;;;;   INDEX-PROJECT conn root  — walk the project, index every file
;;;;
;;;; Every public op runs inside a single SQLite transaction so a
;;;; partial failure leaves the existing rows for that file
;;;; untouched.

;;;; ---- In-package tracking ----
;;;;
;;;; cl-scope-resolver:cst-from-string reads a file's top-level
;;;; forms but does NOT execute (in-package …) directives — eclector
;;;; just reads. We walk the CSTs ourselves and update a tracked
;;;; package as we go, then bind *package* before re-reading each
;;;; form's substring inside analyze.
;;;;
;;;; This is the package context that ends up in forms.package.

(defun cst-head-symbol-eq (cst expected-name)
  "T if CST is a cons-cst whose first child is an atom-cst with a
symbol whose symbol-name (case-insensitive) matches EXPECTED-NAME.
Used for recognizing IN-PACKAGE without depending on which package
IN-PACKAGE was read into."
  (when (typep cst 'concrete-syntax-tree:cons-cst)
    (let ((head (concrete-syntax-tree:first cst)))
      (and (typep head 'concrete-syntax-tree:atom-cst)
           (let ((r (concrete-syntax-tree:raw head)))
             (and (symbolp r)
                  (string-equal (symbol-name r) expected-name)))))))

(defun cst-in-package-designator (cst)
  "If CST is (IN-PACKAGE designator), return the designated package
name as a string (uppercased to match find-package's behavior).
Returns NIL if the shape isn't recognized.

Recognizes:  (in-package :foo)  (in-package #:foo)  (in-package \"foo\")
plus a bare symbol form  (in-package foo).  The arg's CST raw is
either a keyword/symbol (use symbol-name) or a string."
  (when (cst-head-symbol-eq cst "IN-PACKAGE")
    (let* ((kids (cl-scope-resolver::cst-children cst))
           (arg (second kids)))
      (when (typep arg 'concrete-syntax-tree:atom-cst)
        (let ((r (concrete-syntax-tree:raw arg)))
          (cond ((symbolp r) (string-upcase (symbol-name r)))
                ((stringp r) (string-upcase r))
                (t nil)))))))

(defun resolve-package-or-default (package-name)
  "find-package PACKAGE-NAME, falling back to COMMON-LISP-USER and
logging if the named package doesn't exist in the image. Used
during analysis: if the user's file says (in-package :foo) but :foo
hasn't been defined yet, we'd rather index it (even with wrong
symbol homes) than skip the whole file."
  (or (find-package package-name)
      (progn
        (format *error-output*
                "~&swank-lsp indexer: package ~A not found, falling back to CL-USER~%"
                package-name)
        (find-package "COMMON-LISP-USER"))))

;;;; ---- Per-form analysis ----

(defstruct analyzed-form
  "One top-level form's analysis result, with positions translated
to be file-relative. Internal — bridges cl-scope-resolver output to
SQLite serialization.

PACKAGE-NAME is the *package* in effect when this form was read,
as a string (the name of the package), not a package object —
serialization-friendly."
  start
  end
  package-name
  occurrences          ; list of cl-scope-resolver:occurrence
  expanded-macros)     ; list of macro symbols

(defun analyze-file-source (source)
  "Walk SOURCE's top-level forms with in-package tracking. Returns a
list of ANALYZED-FORM in source order.

For each top-level form: extracts its substring, binds *package* to
the tracked package, calls cl-scope-resolver:analyze on the
substring, then translates each occurrence's start/end by adding the
form's start offset (to convert from substring-relative back to
file-relative)."
  (let ((csts (handler-case (cl-scope-resolver:cst-from-string source)
                (error () nil)))
        (current-package "COMMON-LISP-USER")
        (results '()))
    (dolist (cst csts)
      ;; Analyze BEFORE applying (in-package …): the in-package form
      ;; itself was read by eclector in the prior *package* (the
      ;; directive takes effect after the read, not during it). So
      ;; the in-package form's PACKAGE column is the package that
      ;; was active *before* it.
      (multiple-value-bind (form-start form-end)
          (cl-scope-resolver:cst-source-range cst)
        (when (and form-start form-end)
          (let* ((substring (subseq source form-start form-end))
                 (analysis
                   (let ((*package* (resolve-package-or-default
                                     current-package)))
                     (handler-case
                         (cl-scope-resolver:analyze substring)
                       (error () nil)))))
            (when analysis
              (push (make-analyzed-form
                     :start form-start
                     :end form-end
                     :package-name current-package
                     :occurrences (translate-occurrences
                                   (cl-scope-resolver:analysis-occurrences
                                    analysis)
                                   form-start)
                     :expanded-macros
                     (cl-scope-resolver:analysis-expanded-macros analysis))
                    results))))
        ;; Apply (in-package …) directive *after* recording this
        ;; form, so the next form is analyzed under the new package.
        (let ((pkg (cst-in-package-designator cst)))
          (when pkg (setf current-package pkg)))))
    (nreverse results)))

(defun translate-occurrences (occurrences form-start)
  "Add FORM-START to each OCCURRENCE's start/end so positions are
file-relative instead of substring-relative. LOCAL provenance's
binder range gets the same treatment — it's a position in the
substring too."
  (mapcar
   (lambda (o)
     (cl-scope-resolver:make-occurrence
      :start (+ form-start (cl-scope-resolver:occurrence-start o))
      :end   (+ form-start (cl-scope-resolver:occurrence-end o))
      :name  (cl-scope-resolver:occurrence-name o)
      :provenance (translate-provenance
                   (cl-scope-resolver:occurrence-provenance o)
                   form-start)))
   occurrences))

(defun translate-provenance (prov form-start)
  "For LOCAL provenance, shift its (start, end) by FORM-START.
Other provenance kinds carry no source positions on the occurrence
side (VIA-MACROS positions live in the chain steps, which point at
conses we don't serialize positions for)."
  (etypecase prov
    (cl-scope-resolver:local
     (cl-scope-resolver:make-local
      :start (+ form-start (cl-scope-resolver:local-start prov))
      :end   (+ form-start (cl-scope-resolver:local-end prov))
      :cursor-on-binder-p
      (cl-scope-resolver:local-cursor-on-binder-p prov)))
    (cl-scope-resolver:via-macros prov)
    (cl-scope-resolver:none prov)))

;;;; ---- SQLite serialization ----

(defun symbol-package-name (sym)
  "Return SYM's home package name as a string, or NIL if uninterned.
Keyword symbols return \"KEYWORD\"."
  (let ((p (and sym (symbol-package sym))))
    (and p (package-name p))))

(defun delete-file-rows (conn path)
  "Remove the file's row (and via cascade, its forms / occurrences /
chains / form_expanded_macros). No-op if the file isn't indexed yet."
  (sqlite:execute-non-query conn "DELETE FROM files WHERE path = ?" path))

(defun insert-file-row (conn path mtime)
  "Insert a row in `files` and return its rowid."
  (sqlite:execute-non-query
   conn
   "INSERT INTO files (path, mtime, analyzed_at) VALUES (?, ?, ?)"
   path mtime (get-universal-time))
  (sqlite:last-insert-rowid conn))

(defun insert-form-row (conn file-id form)
  "Insert a `forms` row from ANALYZED-FORM, return its rowid."
  (sqlite:execute-non-query
   conn
   "INSERT INTO forms (file_id, start_offset, end_offset, package)
    VALUES (?, ?, ?, ?)"
   file-id
   (analyzed-form-start form)
   (analyzed-form-end form)
   (analyzed-form-package-name form))
  (sqlite:last-insert-rowid conn))

(defun insert-form-expanded-macros (conn form-id macros)
  "Insert one form_expanded_macros row per (macro-name, package)
pair. Skips uninterned macro symbols (rare; can't satisfy
NOT NULL macro_package)."
  (dolist (sym macros)
    (let ((pkg (symbol-package-name sym)))
      (when pkg
        (sqlite:execute-non-query
         conn
         "INSERT OR IGNORE INTO form_expanded_macros (form_id, macro_name, macro_package)
          VALUES (?, ?, ?)"
         form-id (symbol-name sym) pkg)))))

(defun provenance->row-fields (prov file-id)
  "Convert a PROVENANCE to (prov_kind, binder_file_id, binder_start,
binder_end). LOCAL fills the binder slots; everything else leaves
them NULL."
  (etypecase prov
    (cl-scope-resolver:local
     (values "local" file-id
             (cl-scope-resolver:local-start prov)
             (cl-scope-resolver:local-end prov)))
    (cl-scope-resolver:via-macros
     (values "via-macros" nil nil nil))
    (cl-scope-resolver:none
     (values "none" nil nil nil))))

(defun insert-occurrence-row (conn file-id form-id occ)
  "Insert one occurrences row, return its rowid."
  (let ((sym (cl-scope-resolver:occurrence-name occ)))
    (multiple-value-bind (prov-kind b-file b-start b-end)
        (provenance->row-fields
         (cl-scope-resolver:occurrence-provenance occ) file-id)
      (sqlite:execute-non-query
       conn
       "INSERT INTO occurrences
          (file_id, form_id, start_offset, end_offset, name, package,
           prov_kind, binder_file_id, binder_start, binder_end)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
       file-id form-id
       (cl-scope-resolver:occurrence-start occ)
       (cl-scope-resolver:occurrence-end occ)
       (symbol-name sym)
       (symbol-package-name sym)
       prov-kind b-file b-start b-end)
      (sqlite:last-insert-rowid conn))))

(defun insert-chain-rows (conn occ-id prov)
  "If PROV is VIA-MACROS, insert one chains row per chain step.
Skip steps whose macro symbol is uninterned (rare; can't satisfy
NOT NULL macro_package)."
  (when (typep prov 'cl-scope-resolver:via-macros)
    (loop for step in (cl-scope-resolver:via-macros-chain prov)
          for i from 0
          for sym = (cl-scope-resolver:chain-step-macro-name step)
          for pkg = (symbol-package-name sym)
          when (and sym pkg)
            do (sqlite:execute-non-query
                conn
                "INSERT INTO chains (occurrence_id, step_index, macro_name, macro_package)
                 VALUES (?, ?, ?, ?)"
                occ-id i (symbol-name sym) pkg))))

(defun write-analyzed-form (conn file-id form)
  "Insert one form's worth of rows: the forms row, its
form_expanded_macros, its occurrences, each occurrence's chain steps."
  (let ((form-id (insert-form-row conn file-id form)))
    (insert-form-expanded-macros conn form-id
                                 (analyzed-form-expanded-macros form))
    (dolist (occ (analyzed-form-occurrences form))
      (let ((occ-id (insert-occurrence-row conn file-id form-id occ)))
        (insert-chain-rows conn occ-id
                           (cl-scope-resolver:occurrence-provenance occ))))))

;;;; ---- Per-file entry point ----

(defun index-file (conn path)
  "Re-index PATH into CONN. Atomic: reads source from disk, applies
any byte-stream-translator registered for the file extension,
analyzes per-form, replaces all rows for this file in a single
transaction.

Returns the file_id, or NIL if the file couldn't be read.

This is the synchronous primitive — every entry point that wants a
file indexed lands here. Concurrency (worker pool) is a future
layer above this; index-file itself is a single transaction."
  (let ((probed (probe-file path)))
    (unless probed (return-from index-file nil))
    (let* ((path-string (namestring probed))
           (source (handler-case (read-file-as-string path-string)
                     (error () nil))))
      (unless source (return-from index-file nil))
      (let* ((translated (apply-byte-stream-translator
                          (path->file-uri path-string) source))
             (forms (analyze-file-source translated))
             (mtime (or (file-write-date path-string) 0)))
        (sqlite:with-transaction conn
          (delete-file-rows conn path-string)
          (let ((file-id (insert-file-row conn path-string mtime)))
            (dolist (form forms)
              (write-analyzed-form conn file-id form))
            file-id))))))

;;;; ---- Project enumeration ----
;;;;
;;;; Source files are whatever `git ls-files` reports under the
;;;; project root, filtered to extensions we know how to analyze.
;;;; Requires the project to be a git working tree; no fallback. The
;;;; payoff: gitignore is respected for free, vendored deps and
;;;; build artifacts are skipped automatically, no exclude-list to
;;;; maintain.

(defparameter *project-source-extensions*
  '("lisp" "elp")
  "File extensions the indexer scans for. ELP is in here even though
its translator only fires when ELP is loaded into the image; we let
the per-file analyze attempt fail with a logged warning rather than
silently skipping .elp files in non-ELP-loaded images.")

(defun source-extension-p (path)
  (let ((type (pathname-type path)))
    (and type
         (member (string-downcase type) *project-source-extensions*
                 :test #'string=))))

(defun git-ls-files (project-root)
  "Return the relative pathnames `git ls-files` reports inside
PROJECT-ROOT, as strings. Errors (via uiop:run-program's default
:error-output handling) if PROJECT-ROOT is not a git working tree
or `git` isn't on PATH."
  (let* ((root (uiop:ensure-directory-pathname project-root))
         (output (uiop:run-program
                  (list "git" "-C" (namestring root) "ls-files")
                  :output :string)))
    (remove-if (lambda (s) (zerop (length s)))
               (uiop:split-string output :separator '(#\Newline)))))

(defun project-source-files (project-root)
  "Return absolute pathnames of source files (.lisp / .elp) that git
tracks under PROJECT-ROOT. Sorted by namestring for determinism.

Tracked-but-deleted files are filtered (probe-file). git ls-files
will report a deleted-but-still-tracked path; we skip it because
the indexer would just fail on the read."
  (let* ((root (uiop:ensure-directory-pathname project-root))
         (relatives (git-ls-files root)))
    (sort
     (loop for rel in relatives
           for abs = (merge-pathnames rel root)
           when (and (source-extension-p abs)
                     (probe-file abs))
             collect abs)
     #'string<
     :key #'namestring)))

;;;; ---- Project entry point ----

(defun index-project (conn project-root)
  "Index every source file under PROJECT-ROOT into CONN. Each file
is its own transaction (so a failure on one file doesn't roll back
others). Returns the count of files successfully indexed.

Synchronous: walks files in sequence. A worker pool would parallelize
the walks; deferred until needed."
  (let ((paths (project-source-files project-root))
        (count 0))
    (dolist (path paths count)
      (when (index-file conn path)
        (incf count)))))

;;;; ---- In-memory document analysis (the cache layer) ----
;;;;
;;;; Same per-form in-package tracking as the on-disk indexer, so
;;;; symbols interned during the in-memory analysis match what's in
;;;; the SQLite index. Without this, the LSP request thread's
;;;; *package* (whatever swank-lsp happens to be bound to) ends up
;;;; interning the document's symbols in the wrong package; a query
;;;; that joins on (name, package) misses cross-file matches.

(defun analyze-source-into-analysis (source)
  "Run the per-form analyzer (with in-package tracking) on SOURCE,
then collapse the per-form results into a single
CL-SCOPE-RESOLVER:ANALYSIS struct so callers see the same shape
they'd get from CL-SCOPE-RESOLVER:ANALYZE directly. Used by the
in-memory cache; the on-disk indexer keeps the per-form structure
because it writes per-form rows."
  (let ((forms (analyze-file-source source))
        (occurrences '())
        (macros (make-hash-table :test 'eq)))
    (dolist (form forms)
      (dolist (o (analyzed-form-occurrences form))
        (push o occurrences))
      (dolist (m (analyzed-form-expanded-macros form))
        (when m (setf (gethash m macros) t))))
    (cl-scope-resolver:make-analysis
     :occurrences (nreverse occurrences)
     :expanded-macros (loop for k being each hash-key of macros collect k))))

(defun ensure-document-analysis (doc)
  "Build the cl-scope-resolver analysis of DOC's text on demand and
cache it on the document. Returns the analysis, or NIL on signal
(caller treats NIL the same as 'nothing classifiable')."
  (or (document-analysis doc)
      (setf (document-analysis doc)
            (handler-case
                (analyze-source-into-analysis (document-text doc))
              (error () nil)))))

;;;; ---- Server-attached index lifecycle ----
;;;;
;;;; The LSP server holds a single SQLite handle for the project's
;;;; index, plus a mutex guarding it (sqlite handles aren't
;;;; thread-safe; the bulk-index thread and the LSP request thread
;;;; both touch it). The lifecycle:
;;;;
;;;;   start-server-index server project-root
;;;;     - opens index, stores on server
;;;;     - kicks off background thread to bulk-index the project
;;;;     - returns immediately (LSP requests aren't blocked on the
;;;;       initial scan)
;;;;
;;;;   stop-server-index server
;;;;     - disconnects the SQLite handle. The bulk-index thread, if
;;;;       still running, will signal on its next sqlite call and
;;;;       die. We don't join it.
;;;;
;;;;   with-server-index (conn-var) ...body...
;;;;     - grabs the lock and binds CONN-VAR. Returns NIL (and
;;;;       skips body) if no index is active. Used by handlers.

(defun start-server-index (server project-root)
  "Open the index for PROJECT-ROOT, store it on SERVER, and start
the background bulk-index pass. SERVER is a RUNNING-SERVER. Idempotent
on a server that already has an index."
  (when (running-server-index-conn server)
    (return-from start-server-index server))
  (let ((conn (open-index project-root))
        (lock (bordeaux-threads:make-lock "swank-lsp index")))
    (setf (running-server-index-conn server) conn
          (running-server-index-lock server) lock
          (running-server-index-root server) project-root)
    (setf (running-server-index-thread server)
          (bordeaux-threads:make-thread
           (lambda ()
             (handler-case
                 (bordeaux-threads:with-lock-held (lock)
                   (when (running-server-index-conn server)
                     (index-project conn project-root)))
               (error (e)
                 (format *error-output*
                         "~&swank-lsp: bulk index failed: ~A~%" e)
                 (force-output *error-output*))))
           :name "swank-lsp index bulk"))
    server))

(defun stop-server-index (server)
  "Close the index attached to SERVER. The background thread (if
running) will signal on its next sqlite call. Idempotent."
  (let ((conn (running-server-index-conn server)))
    (when conn
      ;; Take the lock so we don't disconnect mid-statement on the
      ;; bulk thread. Once we have it, the bulk thread is between
      ;; statements; safe to close.
      (let ((lock (running-server-index-lock server)))
        (if lock
            (bordeaux-threads:with-lock-held (lock)
              (close-index conn))
            (close-index conn)))
      (setf (running-server-index-conn server) nil
            (running-server-index-lock server) nil
            (running-server-index-root server) nil
            (running-server-index-thread server) nil)))
  server)

(defmacro with-server-index ((conn-var &key (server '*server*)) &body body)
  "Run BODY with CONN-VAR bound to the active index connection,
under the index lock. If no server / no index, BODY does not run
and the form returns NIL.

Use for any handler that wants to read or write the index. The
lock is held for the duration of BODY, so keep BODY tight (one
SQL statement, or one INDEX-FILE call)."
  (let ((s (gensym "SERVER"))
        (l (gensym "LOCK")))
    `(let ((,s ,server))
       (when ,s
         (let ((,conn-var (running-server-index-conn ,s))
               (,l        (running-server-index-lock ,s)))
           (when (and ,conn-var ,l)
             (bordeaux-threads:with-lock-held (,l)
               ,@body)))))))
