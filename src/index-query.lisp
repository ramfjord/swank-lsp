(in-package #:swank-lsp)

;;;; Cross-file references via the SQLite project index + swank's
;;;; xref tables. The handler-side glue is in handlers.lisp; this
;;;; file owns:
;;;;
;;;;   project-references ctx  → list of LSP Locations from SQLite
;;;;   swank-references   ctx  → list of LSP Locations from swank xref
;;;;   dedup-locations locs    → unique by (uri, start, end)
;;;;
;;;; The cursor's classification (LOCAL / VIA-MACROS / NONE / NIL)
;;;; gates which sources we hit — see the strategy notes on each
;;;; function. References to LOCAL bindings stay intra-file (handled
;;;; by local-references in handlers.lisp); free / via-macros
;;;; symbols fan out to project + swank.

;;;; ---- File position cache ----
;;;;
;;;; SQLite stores char offsets; LSP wants line/column. Converting
;;;; needs the file's text + line-starts. A query touches multiple
;;;; rows in the same file; cache keyed by path so we read+parse
;;;; once per file per request.

(defstruct file-pos-info text line-starts)

(defun get-file-pos-info (cache path)
  "Return the FILE-POS-INFO for PATH, building it on first access.
NIL if the file can't be read (deleted between index and query)."
  (or (gethash path cache)
      (let ((text (handler-case (read-file-as-string path)
                    (error () nil))))
        (when text
          (setf (gethash path cache)
                (make-file-pos-info
                 :text text
                 :line-starts (compute-line-starts text)))))))

(defun row->location (cache path start end)
  "Build an LSP Location from (path, char-start, char-end). NIL if
PATH is unreadable."
  (let ((info (get-file-pos-info cache path)))
    (when info
      (let ((text (file-pos-info-text info))
            (ls (file-pos-info-line-starts info)))
        (multiple-value-bind (sl sc)
            (char-offset->lsp-position
             text start
             :encoding *server-position-encoding*
             :line-starts ls)
          (multiple-value-bind (el ec)
              (char-offset->lsp-position
               text end
               :encoding *server-position-encoding*
               :line-starts ls)
            (make-lsp-location (path->file-uri path) sl sc el ec)))))))

;;;; ---- SQLite query: occurrences by (name, package) ----

(defun query-refs-by-name (conn name package)
  "Return rows (path start end) for every occurrence of (NAME, PACKAGE)
across the indexed project. PACKAGE may be NIL (uninterned symbol);
we don't query for those (would match all NULL-package rows, which
isn't useful)."
  (when package
    (sqlite:execute-to-list
     conn
     "SELECT f.path, o.start_offset, o.end_offset
      FROM occurrences o JOIN files f ON o.file_id = f.id
      WHERE o.name = ? AND o.package = ?"
     name package)))

;;;; ---- Project entry: project-references ----

(defun project-references (ctx)
  "SQLite-backed cross-file references to the symbol at the cursor.
Returns a list of LSP Locations or NIL.

Strategy:
  - LOCAL provenance → NIL. Lexical bindings are intra-file by
    definition; the cross-file 'gr from inside a defmacro' feature
    is a separate query (deferred).
  - Anything else (VIA-MACROS / NONE / no provenance) → query by
    (symbol-name, symbol-package). Catches global function refs,
    macro call sites, variable refs, all the bread-and-butter
    cross-file gr cases.

Returns NIL if there's no active index (LSP started outside a git
project, or before the bulk pass had a chance to run)."
  (let* ((doc (defn-ctx-doc ctx))
         (analysis (and doc (ensure-document-analysis doc)))
         (cursor-occ (and analysis
                          (occurrence-covering
                           analysis (defn-ctx-sym-start ctx)))))
    (when (and cursor-occ
               (not (typep (cl-scope-resolver:occurrence-provenance cursor-occ)
                           'cl-scope-resolver:local)))
      (let* ((sym (cl-scope-resolver:occurrence-name cursor-occ))
             (name (and sym (symbol-name sym)))
             (package (symbol-package-name sym)))
        (when (and name package)
          (with-server-index (conn)
            (let ((rows (query-refs-by-name conn name package))
                  (cache (make-hash-table :test 'equal))
                  (results '()))
              (dolist (row rows)
                (destructuring-bind (path start end) row
                  (let ((loc (row->location cache path start end)))
                    (when loc (push loc results)))))
              (nreverse results))))))))

;;;; ---- Swank xref wrapper: swank-references ----
;;;;
;;;; swank:xrefs returns ((dspec . location) ...) for each xref kind.
;;;; Location shape mirrors find-definitions-for-emacs: either a
;;;; (:location (:file path) (:position N) (:snippet s)) form or
;;;; (:error msg). We reuse definition-entry->location-info which
;;;; already converts that shape to (uri start-line start-char
;;;; end-line end-char).

(defun swank-references (ctx)
  "Cross-file references via swank's xref tables. Queries :calls,
:references, and :macroexpands for the cursor's symbol; unions the
results.

Returns NIL when:
  - cursor is on a LOCAL binding (lexicals don't escape; swank xref
    can't help)
  - swank has no xref data for this symbol (uncompiled / not loaded)
  - swank xref errors

Hybrid pairing: project-references covers symbols swank doesn't
know about (uncompiled files); swank covers symbols whose source-
recorded callers aren't textually present (compiler-introduced
calls, eval'd code, etc.). Union catches both."
  (let* ((doc (defn-ctx-doc ctx))
         (analysis (and doc (ensure-document-analysis doc)))
         (cursor-occ (and analysis
                          (occurrence-covering
                           analysis (defn-ctx-sym-start ctx)))))
    (when (and cursor-occ
               (not (typep (cl-scope-resolver:occurrence-provenance cursor-occ)
                           'cl-scope-resolver:local)))
      (let* ((sym-name (defn-ctx-sym ctx))
             (pkg-name (defn-ctx-pkg ctx))
             (root (and *server* (running-server-project-root *server*)))
             (xrefs (handler-case
                        (with-swank-buffer-package (pkg-name)
                          (swank:xrefs '(:calls :references :macroexpands)
                                       sym-name))
                      (error () nil)))
             (results '()))
        (dolist (kind-block xrefs)
          ;; kind-block = (:calls (("dspec" location-plist) ...)).
          ;; Each entry is a TWO-ELEMENT LIST, not a cons pair --
          ;; (cdr entry) would yield (loc) and the location-info
          ;; converter returns NIL on the wrapped form.
          ;;
          ;; swank's xref tables are image-global; without the project-
          ;; root filter, gr on a common name (gethash, list, char=)
          ;; would pull callers from every loaded system: babel, sbcl-
          ;; source, alexandria, and so on. We want refs inside *this*
          ;; project. ROOT NIL means "no filter" (don't silently swallow
          ;; refs when we forgot to capture a root).
          (let ((entries (rest kind-block)))
            (dolist (entry entries)
              (let* ((loc (second entry)))
                (when (xref-loc-in-project-p loc root)
                  (let ((info (definition-entry->location-info loc pkg-name)))
                    (when info
                      (push (apply #'make-lsp-location info) results))))))))
        (nreverse results)))))

(defun xref-loc-in-project-p (loc root)
  "True when swank's :location plist points at a file under ROOT.
NIL ROOT → t (no filter). Non-file locations (eg :error, :buffer)
return nil — we can't render them as LSP Locations anyway."
  (cond
    ((null root) t)
    ((not (and (consp loc) (eq (first loc) :location))) nil)
    (t
     (let* ((file-form (assoc :file (rest loc)))
            (path (and file-form (second file-form))))
       (and path
            (let ((p (handler-case (truename path) (error () nil))))
              (and p (uiop:subpathp p root))))))))

;;;; ---- Dedup ----

(defun location-key (loc)
  "(uri start-line start-char end-line end-char) — the identity of a
Location for dedup. Uses string and integer equality."
  (let ((range (gethash "range" loc))
        (uri (gethash "uri" loc)))
    (let ((s (gethash "start" range))
          (e (gethash "end" range)))
      (list uri
            (gethash "line" s) (gethash "character" s)
            (gethash "line" e) (gethash "character" e)))))

(defun dedup-locations (locations)
  "Remove duplicates by location-key. Preserves first occurrence's
order."
  (let ((seen (make-hash-table :test 'equal))
        (result '()))
    (dolist (loc locations)
      (let ((k (location-key loc)))
        (unless (gethash k seen)
          (setf (gethash k seen) t)
          (push loc result))))
    (nreverse result)))
