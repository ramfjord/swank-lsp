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
