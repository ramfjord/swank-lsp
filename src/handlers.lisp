(in-package #:swank-lsp)

;;;; LSP request/notification handlers.
;;;;
;;;; Each handler is a thin defun that:
;;;;   - parses the LSP `params` hash-table
;;;;   - calls a swank function (or document-store function)
;;;;   - shapes the return into LSP's wire structures (hash-tables for
;;;;     yason).
;;;;
;;;; Handlers are registered with the jsonrpc server in server.lisp.
;;;;
;;;; PARAMS shape: jsonrpc parses incoming JSON via yason, so `params`
;;;; arrives as a hash-table whose keys are JSON property names
;;;; (strings) and whose values are nested hash-tables / lists / scalars.
;;;; Use (gethash "key" params) at every level. NEVER assume plist.

(defvar *server-state* (make-hash-table :test 'equal)
  "Whole-server state shared across handlers.
Keys: \"shutdown-requested\" (bool), \"client-pid\" (int|nil),
\"client-capabilities\" (hash-table)." )

(defun reset-server-state ()
  (clrhash *server-state*))

(defun get-state (key &optional default)
  (multiple-value-bind (v present) (gethash key *server-state*)
    (if present v default)))

(defun set-state (key value)
  (setf (gethash key *server-state*) value))

;;;; Helpers shared by handlers

(defun text-document-uri (params)
  (gethash "uri" (gethash "textDocument" params)))

(defun text-document-version (params)
  (gethash "version" (gethash "textDocument" params)))

(defun position-of (params &optional (key "position"))
  "Return (VALUES LINE CHARACTER) from the LSP Position hash-table at
KEY in PARAMS. Returns (0 0) if the key is missing or the hash lacks
line/character -- defensive against clients that pass weird params."
  (let ((pos (gethash key params)))
    (cond
      ((hash-table-p pos)
       (values (or (gethash "line" pos) 0)
               (or (gethash "character" pos) 0)))
      (t
       (values 0 0)))))

(defun document-from-params (params &key error-on-missing)
  (let ((uri (text-document-uri params)))
    (and uri (get-document uri :error-on-missing error-on-missing))))

(defun current-package-or-default (params)
  (let ((doc (document-from-params params)))
    (current-package-for-document doc)))

;;;; jsonrpc:null: yason needs a sentinel for JSON null. yason:encode
;;;; encodes :null as JSON null when *symbol-encoder* / 'symbol' shape;
;;;; safest is yason's :null special.

(defparameter +json-null+ :null
  "Sentinel that yason:encode renders as JSON null.")

;;;; Calling swank functions
;;;;
;;;; Many swank entry points (find-definitions-for-emacs,
;;;; documentation-symbol, operator-arglist, simple-completions, etc.)
;;;; were written assuming they're called from within EVAL-FOR-EMACS,
;;;; which binds swank::*buffer-package* and swank::*buffer-readtable*.
;;;; When called from arbitrary Lisp code (like our LSP handlers),
;;;; those bindings are absent and the call signals UNBOUND-VARIABLE.
;;;;
;;;; This macro establishes the same bindings EVAL-FOR-EMACS would,
;;;; for a given target package name.

;; Wrapper: catch any error from a handler, log to *error-output*
;; (which the stdio entrypoint redirected to a log file), return null.
;; This stops jsonrpc/mapper's `dissect:present` from writing to
;; *standard-output* -- which over stdio would corrupt the LSP wire.
(defun safe-handler (name fn)
  (lambda (params)
    (handler-case (funcall fn params)
      (error (e)
        (format *error-output* "~&swank-lsp ~A handler error: ~A~%" name e)
        (force-output *error-output*)
        +json-null+))))

(defmacro with-swank-buffer-package ((pkg-name) &body body)
  "Establish the dynamic bindings swank's emacs-rex protocol normally
provides, so handlers can call swank entry points directly. PKG-NAME
is a string naming the buffer's package (e.g. \"CL-USER\")."
  `(let* ((__pkg-name ,pkg-name)
          (swank::*buffer-package* (or (and __pkg-name
                                            (find-package
                                             (string-upcase
                                              (if (and (> (length __pkg-name) 0)
                                                       (char= (char __pkg-name 0) #\:))
                                                  (subseq __pkg-name 1)
                                                  __pkg-name))))
                                       *package*))
          (swank::*buffer-readtable* *readtable*))
     (declare (ignorable swank::*buffer-package* swank::*buffer-readtable*))
     ,@body))

;;;; -- Lifecycle: initialize / initialized / shutdown / exit --

(defun initialize-handler (params)
  "Negotiate position encoding, declare capabilities, return InitializeResult."
  (let* ((capabilities (gethash "capabilities" params))
         (general (and capabilities (gethash "general" capabilities)))
         (encodings (and general (gethash "positionEncodings" general)))
         (chosen (negotiate-position-encoding encodings)))
    (setf *server-position-encoding* chosen)
    (set-state "client-pid" (gethash "processId" params))
    (set-state "client-capabilities" capabilities)
    (set-state "shutdown-requested" nil)
    (let ((result (make-hash-table :test 'equal))
          (caps (make-hash-table :test 'equal))
          (sync-options (make-hash-table :test 'equal))
          (info (make-hash-table :test 'equal))
          (completion-options (make-hash-table :test 'equal))
          (signature-options (make-hash-table :test 'equal)))
      ;; serverCapabilities
      (setf (gethash "positionEncoding" caps) (position-encoding-name chosen))
      ;; textDocumentSync.openClose=true, change=1 (full text sync).
      ;; LSP also accepts the integer form 1; using object form for
      ;; clarity since nvim's lspconfig handles both.
      (setf (gethash "openClose" sync-options) t
            (gethash "change"    sync-options) 1
            ;; Request didSave notifications. We don't need the file
            ;; text in the notification (the LSP version we have on
            ;; disk matches the buffer at save time), so :includeText
            ;; stays unset.
            (gethash "save"      sync-options) t)
      (setf (gethash "textDocumentSync" caps) sync-options)
      (setf (gethash "definitionProvider" caps) t)
      (setf (gethash "referencesProvider" caps) t)
      (setf (gethash "hoverProvider"      caps) t)
      ;; completionProvider with trigger characters that make sense for Lisp.
      (setf (gethash "triggerCharacters" completion-options)
            (list ":" "*" "+" "-" "/"))
      (setf (gethash "completionProvider" caps) completion-options)
      ;; signatureHelpProvider triggers on `(`.
      (setf (gethash "triggerCharacters" signature-options) (list "(" " "))
      (setf (gethash "signatureHelpProvider" caps) signature-options)
      ;; Assemble result.
      (setf (gethash "name" info) "swank-lsp"
            (gethash "version" info) "0.1.0")
      (setf (gethash "capabilities" result) caps
            (gethash "serverInfo"   result) info)
      result)))

(defun initialized-handler (params)
  "Notification -- no response. PARAMS may be NIL or empty."
  (declare (ignore params))
  nil)

(defun shutdown-handler (params)
  "Spec: server returns null result. Sets a flag; subsequent requests
should be rejected (we don't enforce that strictly in v0)."
  (declare (ignore params))
  (set-state "shutdown-requested" t)
  +json-null+)

(defun exit-handler (params)
  "Notification -- process should exit. We stop the server's transport;
the SBCL image continues (we can't sb-ext:exit because the LSP server
might be running alongside swank in a long-lived dev image)."
  (declare (ignore params))
  ;; The server-stop happens via the dispatch path; the running server
  ;; is held in *server*. See server.lisp for the wiring.
  (signal-server-exit)
  nil)

(defgeneric signal-server-exit ()
  (:documentation "Hook overridden by server.lisp once the server is bound."))

(defmethod signal-server-exit ()
  ;; default: no-op (used at load time before server.lisp is loaded)
  nil)

;;;; -- Document sync: didOpen / didChange / didClose --

(defun did-open-handler (params)
  "PARAMS.textDocument: { uri, languageId, version, text }"
  (let* ((td   (gethash "textDocument" params))
         (uri  (gethash "uri" td))
         (text (apply-byte-stream-translator uri (gethash "text" td)))
         (ver  (gethash "version" td))
         (lang (gethash "languageId" td)))
    (store-document
     (make-document :uri uri :text text :version ver :language-id lang))
    nil))

(defun did-change-handler (params)
  "Phase 1 only supports full-text sync (change = 1). The contentChanges
array contains a single { text } entry whose text is the new whole
document. If incremental changes arrive (range present), we currently
fall back to applying the change as a full text replacement; that's
wrong for partial edits but only happens if the client ignores our
serverCapabilities. Test verifies our ack of full sync."
  (let* ((td (gethash "textDocument" params))
         (uri (gethash "uri" td))
         (ver (gethash "version" td))
         (changes (gethash "contentChanges" params))
         (doc (lookup-document uri)))
    (cond
      ((null doc)
       (warn "didChange for untracked URI ~A -- ignoring" uri))
      ((and changes (listp changes))
       ;; Last change wins for full-sync; iterate and replace.
       (dolist (change changes)
         (let ((new-text (apply-byte-stream-translator
                          uri (gethash "text" change))))
           (when new-text
             (setf (document-text doc) new-text
                   (document-line-starts doc) nil
                   (document-analysis doc) nil))))
       (when ver (setf (document-version doc) ver))))
    nil))

(defun did-close-handler (params)
  (let* ((td (gethash "textDocument" params))
         (uri (gethash "uri" td)))
    (remove-document uri)
    nil))

(defun did-save-handler (params)
  "On save: load the file into the running image (so any defmacro /
defun edits become visible to subsequent gd / gr / hover),
re-index the saved file in the SQLite project index, and invalidate
every cached in-memory document analysis (so via-macros chains
recompute against the now-current image state).

This is the auto-eval-on-save loop: the user's save replaces the
manual `C-c C-c` they'd otherwise do in vlime. The LSP and the
image are in the same SBCL, so swank functions are direct calls.

Index refresh is per-saved-file only — no fan-out to other files
that might have used the saved file's macros. Documented v1
limitation: those files keep stale via-macros chains until they're
themselves saved (or the project is re-indexed). Precise
expanded-macros-driven invalidation is the next step.

Errors during load or index are logged and swallowed; the LSP wire
stays clean."
  (let* ((td (gethash "textDocument" params))
         (uri (gethash "uri" td))
         (path (file-uri->path uri)))
    (when path
      (handler-case
          (with-swank-buffer-package
              ((current-package-or-default params))
            (swank:load-file path))
        (error (e)
          (format *error-output*
                  "~&swank-lsp didSave: load-file ~A: ~A~%" path e)
          (force-output *error-output*)))
      (handler-case
          (with-server-index (conn)
            (index-file conn path))
        (error (e)
          (format *error-output*
                  "~&swank-lsp didSave: index-file ~A: ~A~%" path e)
          (force-output *error-output*))))
    (invalidate-all-document-analyses)
    nil))

(defun invalidate-all-document-analyses ()
  "Nil the ANALYSIS slot on every cached document. Called after a
save's load-file runs, on the conservative assumption that the load
may have redefined macros that other documents' analyses depend on.

Coarse but correct: each document re-analyzes lazily on its next gd
/ gr query. A precision upgrade — invalidating only documents whose
ANALYSIS-EXPANDED-MACROS intersects the saved file's defmacros —
lives behind a static defmacro scan with package-aware interning;
deferred until the coarse cost shows up in profiles."
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (maphash (lambda (uri doc)
               (declare (ignore uri))
               (setf (document-analysis doc) nil))
             *document-store*)))

;;;; -- textDocument/definition --
;;;;
;;;; Two-stage resolution:
;;;;
;;;; 1. LOCAL: ask cl-scope-resolver to find a binder in the *current*
;;;;    document. If it answers :LOCAL with a (start, end) range, build
;;;;    a Location pointing at that range in this same URI and return.
;;;; 2. FOREIGN: the resolver said this isn't a local reference (free
;;;;    variable, global function, special, quoted, macro-introduced,
;;;;    walker-error, etc.). Fall through to swank:find-definitions-for-emacs
;;;;    and shape its result into an LSP Location[].
;;;;
;;;; swank returns:
;;;;   ((dspec (:location (:file "/path") (:position N) (:snippet "...")))
;;;;    ...)
;;;; or sometimes (:error "msg") for the location.
;;;; :position is a 1-based file character offset (CL FILE-POSITION).

;;;; textDocument/definition
;;;;
;;;; "Where is this symbol defined?" is one question with several
;;;; possible sources of answer. We try them in order; the first
;;;; non-NIL Location wins.
;;;;
;;;; Strategies (in order):
;;;;   1. CL-SCOPE-RESOLVER  -- pure-source analysis. Handles both
;;;;        LOCAL bindings (binder visible in this document) and
;;;;        VIA-MACROS bindings (chain to a defmacro that introduces
;;;;        the binding; we jump to the defmacro of the innermost
;;;;        user macro in the chain via swank lookup).
;;;;   2. SWANK              -- ask the running image where the symbol
;;;;        is defined globally.
;;;;
;;;; Each strategy is a function (defn-ctx) -> Location | Location[] | NIL.
;;;; Adding a new source (project tags, symbol index, ...) is one new
;;;; strategy function added to *DEFINITION-STRATEGIES*.

(defstruct defn-ctx
  "Inputs every definition strategy needs. Built once per request."
  doc text uri sym sym-start line-starts pkg)

(defun build-defn-ctx (params)
  "Extract everything strategies need from the LSP request. Returns a
DEFN-CTX, or NIL if the request can't be answered (no doc, cursor not
on a symbol)."
  (let ((doc (document-from-params params :error-on-missing nil)))
    (when doc
      (let* ((text (document-text doc))
             (uri  (text-document-uri params)))
        (multiple-value-bind (line character) (position-of params)
          (let* ((line-starts (compute-line-starts text))
                 (offset (lsp-position->char-offset
                          text line character
                          :encoding *server-position-encoding*
                          :line-starts line-starts)))
            ;; extract-symbol-at is forgiving about cursor placement
            ;; (works even when cursor is just past the symbol's end).
            ;; The resolver requires an offset *inside* the symbol;
            ;; we always give it sym-start.
            (multiple-value-bind (sym sym-start sym-end)
                (extract-symbol-at text offset)
              (declare (ignore sym-end))
              (when (and sym (plusp (length sym)))
                (make-defn-ctx :doc doc :text text :uri uri
                               :sym sym :sym-start sym-start
                               :line-starts line-starts
                               :pkg (current-package-for-document doc))))))))))

(defparameter *definition-strategies*
  '(definition-via-resolver
    definition-via-swank)
  "Strategies tried in order by DEFINITION-HANDLER. Each is a function
of (DEFN-CTX) returning a Location, an array of Locations, or NIL.
First non-NIL wins.")

(defun definition-handler (params)
  (let ((ctx (build-defn-ctx params)))
    (or (and ctx
             (some (lambda (strat) (funcall strat ctx))
                   *definition-strategies*))
        +json-null+)))

(defun definition-via-resolver (ctx)
  "Strategy: read the cursor's provenance from the document's cached
analysis. Returns a Location or NIL.

Provenance is one of:
  LOCAL       -- binder visible in this document; build a same-doc Location.
  VIA-MACROS  -- binder introduced by macroexpansion; the chain names
                the macros responsible. We jump to the *innermost user
                macro* in the chain (skipping CL/SB-* implementation
                macros) by asking swank where its defmacro lives.
  NONE        -- no actionable answer; fall through.

The analysis is built once per document (lazy + cached on the
DOCUMENT struct, invalidated on didChange). Re-using it across gd /
gr / hover means a buffer pays for one cl-scope-resolver walk per
edit, not one per query."
  (let* ((analysis (ensure-document-analysis (defn-ctx-doc ctx)))
         (occ (and analysis
                   (occurrence-covering analysis (defn-ctx-sym-start ctx))))
         (prov (and occ (cl-scope-resolver:occurrence-provenance occ))))
    (etypecase prov
      (null nil)
      (cl-scope-resolver:local      (location-from-local-binder prov ctx))
      (cl-scope-resolver:via-macros (location-from-macro-chain prov ctx))
      (cl-scope-resolver:none       nil))))

(defun definition-via-swank (ctx)
  "Strategy: ask swank's FIND-DEFINITIONS-FOR-EMACS about the symbol
at the cursor. Returns a Location, an array of Locations, or NIL."
  (swank-definitions-of (defn-ctx-sym ctx) (defn-ctx-pkg ctx)))

(defun location-from-local-binder (local ctx)
  "LOCAL provenance -> same-doc Location at the binder name."
  (let ((range (char-range->lsp-range
                (defn-ctx-text ctx)
                (cl-scope-resolver:local-start local)
                (cl-scope-resolver:local-end local)
                :encoding *server-position-encoding*
                :line-starts (defn-ctx-line-starts ctx))))
    (lsp-location-from-range (defn-ctx-uri ctx) range)))

(defun location-from-macro-chain (via-macros ctx)
  "VIA-MACROS provenance -> Location of the defmacro of the innermost
user macro in the chain. Returns NIL if the chain is empty after
filtering implementation packages, or if swank has no source for the
macro."
  (let* ((chain (cl-scope-resolver:via-macros-chain via-macros))
         (names (cl-scope-resolver:chain-macro-names chain))
         (user-macros (remove-if #'system-symbol-p names))
         (innermost (car (last user-macros))))
    (when innermost
      (swank-definitions-of (symbol-name innermost) (defn-ctx-pkg ctx)))))

(defun swank-definitions-of (sym-name pkg)
  "Ask swank for SYM-NAME's source location(s). Returns a single
Location, an array of Locations, or NIL. Used by both the swank
strategy directly and by the resolver strategy when it's chasing a
macro chain to its defmacro."
  (let* ((defs (handler-case
                   (with-swank-buffer-package (pkg)
                     (swank:find-definitions-for-emacs sym-name))
                 (error () nil)))
         (locations (loop for entry in defs
                          for loc = (and (consp entry) (second entry))
                          for url-and-range = (definition-entry->location-info loc pkg)
                          when url-and-range
                            collect (apply #'make-lsp-location url-and-range))))
    (cond
      ((null locations) nil)
      ((= 1 (length locations)) (first locations))
      (t locations))))

(defun lsp-location-from-range (uri range)
  "Wrap an existing LSP Range in a Location."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "uri" h) uri
          (gethash "range" h) range)
    h))

;;;; textDocument/references
;;;;
;;;; v0: local references only. For a cursor on a let-bound (or
;;;; lambda-, dolist-, etc.) name, return every other use of the SAME
;;;; binder in the same source. Cross-file / global references would
;;;; need swank's xref machinery; deferred.
;;;;
;;;; Algorithm: cl-scope-resolver tells us which binder the cursor's
;;;; symbol points at. We then scan the source for every textual
;;;; occurrence of the binder NAME, call resolve at each candidate,
;;;; and keep those whose binder range matches the cursor's. Naive
;;;; O(matches * resolve-cost) but the candidate set is small (just
;;;; the textual occurrences of one specific name), and cursor on a
;;;; same-name binder in a different scope filters out automatically
;;;; because resolve gives a different binder range there.

(defun references-handler (params)
  "Cross-file references via the union of:
  - LOCAL    — same-file refs from the in-memory analysis (lexicals)
  - PROJECT  — SQLite project index (cross-file occurrences)
  - SWANK    — swank's xref tables, where the compiler recorded callers
Deduped on (uri, range). When the cursor's classification is LOCAL,
we stay intra-file (lexicals don't escape). Returns Location[] or null."
  (let ((ctx (build-defn-ctx params)))
    (cond
      ((null ctx) +json-null+)
      (t
       (let ((merged (merged-references ctx)))
         (or merged +json-null+))))))

(defun merged-references (ctx)
  "Strategy:
  - If the cursor's classification is LOCAL: return LOCAL only.
    Lexical bindings are intra-file by definition; including the
    name-keyed cross-file matches would conflate distinct bindings
    that share a name.
  - Otherwise: union project + swank refs."
  (let* ((analysis (ensure-document-analysis (defn-ctx-doc ctx)))
         (cursor-occ (and analysis
                          (occurrence-covering
                           analysis (defn-ctx-sym-start ctx))))
         (cursor-prov (and cursor-occ
                           (cl-scope-resolver:occurrence-provenance cursor-occ))))
    (cond
      ((typep cursor-prov 'cl-scope-resolver:local)
       (local-references ctx))
      (t
       (dedup-locations
        (append
         (project-references ctx)
         (swank-references ctx)))))))

(defun occurrence-covering (analysis offset)
  "Return the OCCURRENCE in ANALYSIS whose [start, end) covers OFFSET, or NIL."
  (find-if (lambda (o)
             (and (<= (cl-scope-resolver:occurrence-start o) offset)
                  (< offset (cl-scope-resolver:occurrence-end o))))
           (cl-scope-resolver:analysis-occurrences analysis)))

(defun local-references (ctx)
  "Find all references to the binder at the cursor. Returns an array
of LSP Locations, or NIL if cursor is not on a local binding.

Uses cl-scope-resolver:analyze to walk the document once and visit
every symbol-atom with a precomputed provenance. Two occurrences are
references to the same binder iff their LOCAL provenances point at
the same (start, end) source range — that's the binder identity."
  (let* ((text (defn-ctx-text ctx))
         (sym-start (defn-ctx-sym-start ctx))
         (uri (defn-ctx-uri ctx))
         (line-starts (defn-ctx-line-starts ctx))
         (analysis (ensure-document-analysis (defn-ctx-doc ctx))))
    (unless analysis
      (return-from local-references nil))
    (let* ((cursor-occ (occurrence-covering analysis sym-start))
           (cursor-prov (and cursor-occ
                             (cl-scope-resolver:occurrence-provenance cursor-occ))))
      (unless (typep cursor-prov 'cl-scope-resolver:local)
        (return-from local-references nil))
      (let ((b-start (cl-scope-resolver:local-start cursor-prov))
            (b-end   (cl-scope-resolver:local-end   cursor-prov))
            (refs '()))
        (dolist (occ (cl-scope-resolver:analysis-occurrences analysis))
          (let ((p (cl-scope-resolver:occurrence-provenance occ)))
            (when (and (typep p 'cl-scope-resolver:local)
                       (= (cl-scope-resolver:local-start p) b-start)
                       (= (cl-scope-resolver:local-end   p) b-end))
              (push (lsp-location-from-range
                     uri
                     (char-range->lsp-range
                      text
                      (cl-scope-resolver:occurrence-start occ)
                      (cl-scope-resolver:occurrence-end occ)
                      :encoding *server-position-encoding*
                      :line-starts line-starts))
                    refs))))
        (nreverse refs)))))

(defun system-symbol-p (sym)
  "T if SYM lives in an implementation/standard package whose contents
we don't want to surface as a definition target. Filters COMMON-LISP,
KEYWORD, and SB-* (SBCL implementation packages); user packages and
COMMON-LISP-USER pass through."
  (let ((p (symbol-package sym)))
    (when p
      (let ((name (package-name p)))
        (or (string= name "COMMON-LISP")
            (string= name "KEYWORD")
            (and (>= (length name) 3)
                 (string= name "SB-" :end1 3)))))))

(defun make-lsp-location (uri start-line start-char end-line end-char)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "uri" h) uri
          (gethash "range" h)
          (make-lsp-range start-line start-char end-line end-char))
    h))

(defun definition-entry->location-info (loc pkg)
  "Convert a swank :location plist to (URI START-LINE START-CHAR END-LINE END-CHAR)
or NIL if the location is not file-based."
  (declare (ignore pkg))
  (when (and (consp loc) (eq (first loc) :location))
    (let* ((file-form (assoc :file (rest loc)))
           (pos-form  (assoc :position (rest loc)))
           (snippet-form (assoc :snippet (rest loc))))
      (when (and file-form pos-form)
        (let* ((path (second file-form))
               (one-based (second pos-form))
               (snippet (and snippet-form (second snippet-form)))
               (uri (path->file-uri path)))
          ;; swank's :position is 1-based for emacs convention; convert
          ;; to 0-based char offset in the *file*. Then convert to LSP
          ;; line/character. We have to read the file to learn its line
          ;; structure for the encoding mapping. For a v0, snippet length
          ;; gives us a usable end range without re-reading.
          (let ((file-text (handler-case
                               (read-file-as-string path)
                             (error () nil))))
            (when file-text
              (let* ((char-offset (max 0 (1- one-based)))
                     (file-line-starts (compute-line-starts file-text))
                     (snippet-len (and snippet
                                       (length (string-trim '(#\Newline) snippet)))))
                (multiple-value-bind (sl sc)
                    (char-offset->lsp-position file-text char-offset
                                               :encoding *server-position-encoding*
                                               :line-starts file-line-starts)
                  (multiple-value-bind (el ec)
                      (char-offset->lsp-position file-text
                                                 (+ char-offset (or snippet-len 0))
                                                 :encoding *server-position-encoding*
                                                 :line-starts file-line-starts)
                    (list uri sl sc el ec)))))))))))

;;;; -- textDocument/completion --
;;;;
;;;; swank:simple-completions returns a flat list of triples
;;;;   (("label" "classification" "fully-qualified-name") ...)
;;;; (Some swank versions also wrap a (matches longest-prefix) two-list;
;;;;  this branch handles both.)

(defun completion-handler (params)
  (let ((doc (document-from-params params :error-on-missing nil)))
    (unless doc (return-from completion-handler +json-null+))
    (let* ((text (document-text doc))
           (line-starts (compute-line-starts text)))
      (multiple-value-bind (line character) (position-of params)
        (let* ((offset (lsp-position->char-offset
                        text line character
                        :encoding *server-position-encoding*
                        :line-starts line-starts))
               (prefix (extract-prefix-at text offset))
               (pkg (current-package-for-document doc))
               (raw (handler-case
                        (with-swank-buffer-package (pkg)
                          (swank:simple-completions prefix pkg))
                      (error () nil))))
          (let ((items (swank-completions->lsp-items raw)))
            (if items
                (make-completion-list items)
                +json-null+)))))))

(defun swank-completions->lsp-items (raw)
  "RAW is one of:
  - NIL
  - (matches longest-prefix)  where matches is a list of strings
  - ((label classification ...) ...)   modern swank shape
Return a list of LSP CompletionItem hashes (without sorting)."
  (cond
    ((null raw) nil)
    ;; old shape: (matches longest)  matches is list of strings
    ((and (= (length raw) 2)
          (listp (first raw))
          (or (stringp (second raw)) (null (second raw)))
          (every (lambda (m) (or (stringp m) (consp m))) (first raw)))
     (mapcar #'completion-item-from-strings-or-triples (first raw)))
    (t
     (mapcar #'completion-item-from-strings-or-triples raw))))

(defun completion-item-from-strings-or-triples (entry)
  (let ((h (make-hash-table :test 'equal)))
    (etypecase entry
      (string
       (setf (gethash "label" h) entry))
      (cons
       (let ((label (first entry))
             (classification (second entry))
             (qualified (third entry)))
         (setf (gethash "label" h) label)
         (when (stringp classification)
           (setf (gethash "detail" h) classification))
         (when (stringp qualified)
           (setf (gethash "documentation" h) qualified)))))
    h))

(defun make-completion-list (items)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "isIncomplete" h) nil
          (gethash "items" h) items)
    h))

;;;; -- textDocument/hover --
;;;;
;;;; Two paths, tried in order:
;;;;   1. LEXICAL: cursor is on a lexical binder or one of its uses.
;;;;      Resolve the binding via cl-scope-resolver, derive the type
;;;;      via the SBCL backend, render `**name** : type` plus a
;;;;      `name = init-form` code block when an init exists.
;;;;   2. DOCSTRING: cursor is on a global. Ask swank for the
;;;;      documentation string. Existing behaviour.
;;;;
;;;; The lexical path returns NIL (rather than +json-null+) when it
;;;; has nothing useful to say -- e.g. an undeclared lambda param
;;;; whose only inferable type is T -- so the docstring path gets a
;;;; chance.

(defvar *hover-content-format* "markdown"
  "LSP MarkupKind for the lexical-hover content. \"markdown\" or
\"plaintext\". Defaulting to markdown so K renders the code-fenced
init-form nicely; flip to \"plaintext\" if your client doesn't
render markdown.")

(defun hover-handler (params)
  (let ((doc (document-from-params params :error-on-missing nil)))
    (unless doc (return-from hover-handler +json-null+))
    (let* ((text (document-text doc))
           (line-starts (compute-line-starts text)))
      (multiple-value-bind (line character) (position-of params)
        (let* ((offset (lsp-position->char-offset
                        text line character
                        :encoding *server-position-encoding*
                        :line-starts line-starts))
               (sym (extract-symbol-at text offset)))
          (declare (ignore line-starts))
          (unless (and sym (plusp (length sym)))
            (return-from hover-handler +json-null+))
          (or (lexical-hover doc offset sym)
              (docstring-hover doc sym)
              +json-null+))))))

(defun lexical-hover (doc offset sym)
  "Hover content for a cursor on a lexical binder (or a use of one).
Returns an LSP Hover hash with markdown content, or NIL when the
cursor isn't on a lexical we can describe -- caller falls through to
the docstring path."
  (declare (ignore sym))
  (let* ((text   (document-text doc))
         (lookup (binder-info-offset-redirected text offset))
         (bi (and lookup
                  (handler-case (cl-scope-resolver:binder-info-at text lookup)
                    (error () nil)))))
    (when bi
      (let* ((name      (cl-scope-resolver:binder-info-name bi))
             (init      (cl-scope-resolver:binder-info-init-form bi))
             (free      (cl-scope-resolver:enclosing-lexicals bi))
             (declares  (cl-scope-resolver:local-declares-for
                         bi (cons name free)))
             (type-spec (derive-type-for-binder doc bi name init free declares))
             (enclosing (cl-scope-resolver:binder-info-enclosing-function-name bi))
             (mutations (lexical-mutations-for bi text))
             (value     (build-lexical-hover-value
                         name type-spec init enclosing mutations)))
        (lsp-hover-markup value)))))

(defun lexical-mutations-for (bi text)
  "List of (LINE . SNIPPET) pairs, one per write occurrence of BI's
binder, in source order. SNIPPET is the source text of the smallest
enclosing form that contains the write atom (typically `(setf X v)'
or `(incf X)'); LINE is its 1-based line number.

Returns NIL when no writes — the hover renderer omits the block in
that case."
  (let* ((analysis (handler-case (cl-scope-resolver:analyze text)
                     (error () nil)))
         (writes (and analysis
                      (cl-scope-resolver:binder-info-write-occurrences
                       bi analysis))))
    (loop for occ in writes
          for occ-start = (cl-scope-resolver:occurrence-start occ)
          for snippet   = (mutation-snippet-at text occ-start)
          when snippet
            collect (cons (1+ (line-number-of text occ-start)) snippet))))

(defun line-number-of (text offset)
  "0-based line number of OFFSET in TEXT."
  (line-of-offset (compute-line-starts text) offset))

(defun mutation-snippet-at (text occ-start)
  "Return the source slice of the smallest cons CST that encloses
OCC-START -- i.e. the assignment form like `(incf i)' or `(setf i
(+ i 1))'. NIL on failure or when no enclosing cons is found."
  (let* ((csts (handler-case (cl-scope-resolver:cst-from-string text)
                 (error () nil)))
         (path (and csts (cl-scope-resolver:cst-path-to-offset
                          csts occ-start)))
         (enclosing-cons (and path (last-enclosing-cons (butlast path)))))
    (when enclosing-cons
      (multiple-value-bind (s e)
          (cl-scope-resolver:cst-source-range enclosing-cons)
        (and s e (subseq text s e))))))

(defun last-enclosing-cons (path)
  "Right-most CONS-CST in PATH (a list of CSTs, top-first). Returns
NIL when PATH has no cons -- e.g. the user clicked at the very top
level. Walks from the deep end so we get the *immediate* parent
cons, not the outermost top form."
  (loop for c in (reverse path)
        when (typep c 'concrete-syntax-tree:cons-cst)
          return c))

(defun binder-info-offset-redirected (text offset)
  "Workaround for the upstream gap in cl-scope-resolver:binder-info-at:
when the cursor is on a USE of a local binder, RESOLVE points at the
binder via LOCAL's start/end but BINDER-INFO-AT itself only
classifies binder-position cursors. Redirect uses to the binder
location before calling. Returns the offset to call BINDER-INFO-AT
with.

Note: RESOLVE returns NONE :NOT-A-REFERENCE when the cursor sits on
a binder name -- by design, since a binder isn't a reference. In
that case we just hand back OFFSET, since BINDER-INFO-AT itself
handles binder-position cursors correctly. Only when RESOLVE
returns a LOCAL pointing elsewhere do we redirect.

TODO(upstream): cl-scope-resolver:binder-info-at should follow LOCAL
provenance back to the binder internally; once that lands, this
shim collapses to (text offset)."
  (let ((prov (handler-case (cl-scope-resolver:resolve text offset)
                (error () nil))))
    (cond
      ((and prov
            (cl-scope-resolver:local-p prov)
            (not (cl-scope-resolver:local-cursor-on-binder-p prov)))
       (cl-scope-resolver:local-start prov))
      (t offset))))

(defun derive-type-for-binder (doc bi name init free declares)
  "For let/let*/mvb: derive the init-form's type. For params (no
init): derive the type of the binder NAME itself, with DECLARES
forwarded -- so a (declare (fixnum x)) on a defun param yields
FIXNUM.

When the synth-lambda result is uninformative (T/*) and the binder
is a defun parameter, fall back to the enclosing function's
proclaimed ftype: this is what makes a top-level (declaim (ftype
(function (string) ...) FOO)) pay off for K on FOO's params even
without an in-body declare. Returns NIL if no backend is registered."
  (cond
    (init (compile-derived-type-of init free declares))
    (t    (let ((primary (compile-derived-type-of name (cons name free) declares)))
            (if (lexical-hover-uninformative-p primary)
                (or (param-type-via-doc doc bi name) primary)
                primary)))))

(defun param-type-via-doc (doc bi param-name)
  "If BI is a :defun-param with an enclosing function whose name we
can resolve in DOC's package, return the param's type from the
function's stored ftype. Otherwise NIL.

cl-scope-resolver returns the function name as the symbol it read
during its CST pass -- usually CL-USER -- so we re-resolve by
SYMBOL-NAME in the document's package to land on the actual symbol
the loaded image knows about."
  (let ((raw (cl-scope-resolver:binder-info-enclosing-function-name bi)))
    (when raw
      (let* ((pkg-name (current-package-for-document doc))
             (pkg (or (and pkg-name (find-package (string-upcase pkg-name)))
                      *package*))
             (sym (find-symbol (symbol-name raw) pkg)))
        (when sym
          (param-type-from-ftype sym param-name))))))

(defun lexical-hover-uninformative-p (type)
  "T and * are SBCL's spellings of \"no information.\" Treating both
as suppress-the-type-line until commit 4's simplifier subsumes the
rule."
  (or (null type) (eq type t) (eq type '*)))

(defun build-lexical-hover-value (name type init
                                  &optional enclosing-fn mutations)
  "Markdown hover value. Skeleton:

  **NAME** : `TYPE`               (omit \" : ...\" when TYPE is uninformative)
  *param of `FN`*                  (only when ENCLOSING-FN is non-NIL)

  ```lisp
  NAME := INIT                     (omit when INIT is NIL)
  ```

  Mutated at:                      (whole block omitted when MUTATIONS is NIL)
  - LINE: `SNIPPET`
  - ...

ENCLOSING-FN is shown so the user can tell at a glance that they're
hovering on a parameter (vs a let binding).

MUTATIONS is a list of (LINE . SNIPPET) pairs — one per syntactic
write site (setq/setf/incf/decf/multiple-value-setq). Showing them
inline only when present is intentional: an unmutated lexical gets
a calm hover; a mutated one gets the audit trail.

Returns NIL when nothing carries useful information."
  (let ((show-type   (not (lexical-hover-uninformative-p type)))
        (show-init   (not (null init)))
        (show-encl   (not (null enclosing-fn)))
        (show-mut    (not (null mutations))))
    (cond
      ((not (or show-type show-init show-encl show-mut)) nil)
      (t
       (with-output-to-string (s)
         (cond
           (show-type (format s "**~A** : `~S`" name type))
           (t         (format s "**~A**" name)))
         (when show-encl
           (format s "~%~%*param of `~A`*" (symbol-name enclosing-fn)))
         (when show-init
           (format s "~%~%```lisp~%~A := ~S~%```" name init))
         (when show-mut
           (format s "~%~%Mutated at:")
           (dolist (m mutations)
             (format s "~%- ~A: `~A`" (car m) (cdr m)))))))))

(defun lsp-hover-markup (value &key (kind *hover-content-format*))
  "Wrap VALUE in the LSP Hover hash-table shape. Returns NIL when
VALUE is NIL or empty so call sites can chain with OR."
  (when (and value (plusp (length value)))
    (let ((h (make-hash-table :test 'equal))
          (c (make-hash-table :test 'equal)))
      (setf (gethash "kind" c) kind
            (gethash "value" c) value
            (gethash "contents" h) c)
      h)))

(defun docstring-hover (doc sym)
  "Hover content for a global symbol: arglist (when fbound) plus
docstring (when documented). Returns the combined markdown payload,
or NIL when the symbol carries neither — falling through to JSON
null.

Showing the arglist regardless of docstring is the win here: many
CL builtins (e.g. VECTOR-PUSH-EXTEND on SBCL) have no docstring but
a perfectly serviceable lambda list, and seeing
\"(vector-push-extend new-element vector &optional min-extension)\"
on K is exactly the help the user needs."
  (let* ((pkg (current-package-for-document doc))
         (arglist  (function-arglist-string sym pkg))
         (doc-text (function-doc-string sym pkg))
         (home-pkg (function-home-package sym pkg)))
    (cond
      ((and (null arglist) (null doc-text)) nil)
      (t (lsp-hover-markup
          (build-docstring-hover-value arglist doc-text home-pkg))))))

(defun function-home-package (sym pkg-name)
  "Resolve the string SYM to a CL symbol in PKG-NAME and return its
home package's NAME (a string), or NIL when we can't resolve it.

The home package is an honest bit of info even when SBCL ships no
docstring: a hover for VECTOR-PUSH-EXTEND that says \"in
COMMON-LISP\" tells the user this is a standard function and
they're not looking at something local that happens to share the
name."
  (let ((p (and pkg-name (find-package (string-upcase pkg-name)))))
    (when p
      (let ((s (find-symbol (string-upcase sym) p)))
        (and s (symbol-package s)
             (package-name (symbol-package s)))))))

(defun function-arglist-string (sym pkg)
  "Ask swank for SYM's arglist in PKG. Returns the formatted string
or NIL when swank has nothing useful (empty / errored / not fbound)."
  (let ((arglist (handler-case
                     (with-swank-buffer-package (pkg)
                       (swank:operator-arglist sym pkg))
                   (error () nil))))
    (cond
      ((null arglist) nil)
      ((string= arglist "") nil)
      (t arglist))))

(defun function-doc-string (sym pkg)
  "Ask swank for SYM's docstring in PKG, filtering out swank's
\"Can't find documentation for X\" placeholder."
  (let ((s (handler-case
               (with-swank-buffer-package (pkg)
                 (swank:documentation-symbol sym))
             (error () nil))))
    (cond
      ((or (null s) (string= s "")) nil)
      ((string-equal s (format nil "Can't find documentation for ~A" sym)) nil)
      (t s))))

(defun build-docstring-hover-value (arglist doc-text home-pkg)
  "Markdown layout:

  ```lisp
  ARGLIST
  ```
  *in `HOME-PKG`*

  DOC-TEXT

ARGLIST and DOC-TEXT are optional independently; HOME-PKG only
renders when ARGLIST does (it labels the arglist's home, so the
two go together)."
  (with-output-to-string (s)
    (when arglist
      (format s "```lisp~%~A~%```" arglist)
      (when home-pkg
        (format s "~%~%*in `~A`*" home-pkg)))
    (when (and (or arglist home-pkg) doc-text)
      (format s "~%~%"))
    (when doc-text
      (format s "~A" doc-text))))

;;;; -- textDocument/signatureHelp --

(defun signature-help-handler (params)
  (let ((doc (document-from-params params :error-on-missing nil)))
    (unless doc (return-from signature-help-handler +json-null+))
    (let* ((text (document-text doc))
           (line-starts (compute-line-starts text)))
      (multiple-value-bind (line character) (position-of params)
        (let* ((offset (lsp-position->char-offset
                        text line character
                        :encoding *server-position-encoding*
                        :line-starts line-starts))
               (op (extract-operator-before text offset))
               (pkg (current-package-for-document doc)))
          (declare (ignore line-starts))
          (unless (and op (plusp (length op)))
            (return-from signature-help-handler +json-null+))
          (let ((arglist (handler-case
                             (with-swank-buffer-package (pkg)
                               (swank:operator-arglist op pkg))
                           (error () nil))))
            (cond
              ((or (null arglist) (string= arglist ""))
               +json-null+)
              (t
               (let ((sig (make-hash-table :test 'equal))
                     (top (make-hash-table :test 'equal)))
                 (setf (gethash "label" sig) arglist)
                 (setf (gethash "signatures" top) (list sig)
                       (gethash "activeSignature" top) 0
                       (gethash "activeParameter" top) 0)
                 top)))))))))

(defun extract-operator-before (text offset)
  "Walk backward from OFFSET looking for the operator of the innermost
unclosed `(`. Conservative: scans for the nearest `(` not yet closed,
then reads the symbol immediately following it. Doesn't handle string
literals or comments specially -- good enough for v0."
  (let ((depth 0)
        (p (1- offset)))
    (loop while (>= p 0) do
      (let ((c (char text p)))
        (cond
          ((char= c #\)) (incf depth))
          ((char= c #\()
           (cond
             ((zerop depth)
              (let ((start (1+ p)))
                (multiple-value-bind (name end)
                    (read-symbolish text start (length text))
                  (declare (ignore end))
                  (return-from extract-operator-before name))))
             (t (decf depth))))))
      (decf p))
    nil))
