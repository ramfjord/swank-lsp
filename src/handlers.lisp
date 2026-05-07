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
            (gethash "change"    sync-options) 1)
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
                   (document-line-starts doc) nil))))
       (when ver (setf (document-version doc) ver))))
    nil))

(defun did-close-handler (params)
  (let* ((td (gethash "textDocument" params))
         (uri (gethash "uri" td)))
    (remove-document uri)
    nil))

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
  "Strategy: ask cl-scope-resolver. Returns a Location or NIL.

The resolver returns a discriminated-union PROVENANCE:
  LOCAL       -- binder visible in this document; build a same-doc Location.
  VIA-MACROS  -- binder introduced by macroexpansion; the chain names
                the macros responsible. We jump to the *innermost user
                macro* in the chain (skipping CL/SB-* implementation
                macros) by asking swank where its defmacro lives.
  NONE        -- no actionable answer; fall through.

Resolver errors are swallowed: the swank strategy is the backstop."
  (let ((prov (handler-case
                  (cl-scope-resolver:resolve (defn-ctx-text ctx)
                                             (defn-ctx-sym-start ctx))
                (error () nil))))
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
  (let ((ctx (build-defn-ctx params)))
    (or (and ctx (local-references ctx))
        +json-null+)))

(defun local-references (ctx)
  "Find all references to the binder at the cursor. Returns an array
of LSP Locations, or NIL if cursor is not on a local binding."
  (let* ((text  (defn-ctx-text ctx))
         (sym-start (defn-ctx-sym-start ctx))
         (uri   (defn-ctx-uri ctx))
         (line-starts (defn-ctx-line-starts ctx))
         (prov  (handler-case (cl-scope-resolver:resolve text sym-start)
                  (error () nil))))
    (unless (and prov (typep prov 'cl-scope-resolver:local))
      (return-from local-references nil))
    (let* ((b-start (cl-scope-resolver:local-start prov))
           (b-end   (cl-scope-resolver:local-end   prov))
           (name    (subseq text b-start b-end))
           (refs '()))
      (dolist (pos (token-positions text name))
        (let ((p (handler-case (cl-scope-resolver:resolve text pos)
                   (error () nil))))
          (when (and p
                     (typep p 'cl-scope-resolver:local)
                     (= (cl-scope-resolver:local-start p) b-start)
                     (= (cl-scope-resolver:local-end   p) b-end))
            (push (lsp-location-from-range
                   uri
                   (char-range->lsp-range
                    text pos (+ pos (length name))
                    :encoding *server-position-encoding*
                    :line-starts line-starts))
                  refs))))
      (nreverse refs))))

(defun token-positions (text name)
  "Positions in TEXT where NAME appears as a complete token (not as a
substring of a longer identifier). Linear scan."
  (let ((positions '())
        (len (length name))
        (i 0))
    (loop
      (let ((found (search name text :start2 i)))
        (unless found (return (nreverse positions)))
        (let ((before (and (plusp found) (char text (1- found))))
              (after  (and (< (+ found len) (length text))
                           (char text (+ found len)))))
          (unless (or (lisp-symbol-char-p before)
                      (lisp-symbol-char-p after))
            (push found positions)))
        (setf i (1+ found))))))

(defun lisp-symbol-char-p (c)
  "T if C is a character that can appear inside a CL symbol name (so
finding NAME adjacent to it would be matching part of a longer
identifier, not the symbol itself)."
  (and c (not (or (member c '(#\Space #\Newline #\Tab #\Return
                              #\( #\) #\' #\` #\, #\; #\" #\#))
                  ;; brackets/braces aren't standard CL but treat as
                  ;; separators since they appear in some sources
                  (member c '(#\[ #\] #\{ #\}))))))

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

(defun path->file-uri (path)
  "Convert an absolute filesystem PATH to a file:// URI."
  (let ((p (etypecase path
             (string path)
             (pathname (namestring path)))))
    (if (search "://" p)
        p  ; already a URI
        (concatenate 'string "file://" p))))

(defun file-uri->path (uri)
  "Inverse of PATH->FILE-URI. Returns the path string, or NIL on
mis-matched scheme."
  (when (and uri (>= (length uri) 7) (string= "file://" uri :end2 7))
    (subseq uri 7)))

(defun read-file-as-string (path)
  (with-open-file (in path :direction :input
                           :external-format :utf-8
                           :if-does-not-exist :error)
    (let ((buf (make-string (file-length in))))
      (let ((n (read-sequence buf in)))
        (if (= n (length buf))
            buf
            (subseq buf 0 n))))))

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
          (let ((doc-string (handler-case
                                (with-swank-buffer-package
                                    ((current-package-for-document doc))
                                  (swank:documentation-symbol sym))
                              (error () nil))))
            (cond
              ((or (null doc-string) (string= doc-string ""))
               +json-null+)
              ((string-equal doc-string
                             (format nil "Can't find documentation for ~A" sym))
               +json-null+)
              (t
               (let ((h (make-hash-table :test 'equal))
                     (contents (make-hash-table :test 'equal)))
                 (setf (gethash "kind" contents) "plaintext"
                       (gethash "value" contents) doc-string)
                 (setf (gethash "contents" h) contents)
                 h)))))))))

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
