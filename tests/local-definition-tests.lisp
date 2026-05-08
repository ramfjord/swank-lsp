(in-package #:swank-lsp/tests)

;;;; Wire-level integration tests for local jump-to-definition (Phase 2).
;;;;
;;;; Each test opens a document via didOpen, sends a textDocument/definition
;;;; request at a specific position, and asserts:
;;;;   - For locals: the response is a single Location whose URI is the
;;;;     same document and whose range points at the binder name.
;;;;   - For non-locals (globals / free vars): the response either falls
;;;;     through to swank (URI != current doc) or is null. The local
;;;;     branch must not corrupt the existing swank path.
;;;;
;;;; Position math reminder: LSP Positions are 0-based (line, character).
;;;; For the buffers below, character offset == LSP character (ASCII only).

(in-suite local-definition-suite)

(defun definition-at (sock uri line character)
  "Send textDocument/definition for URI at (LINE, CHARACTER), return result."
  (let* ((params (make-hash-table :test 'equal))
         (td (make-hash-table :test 'equal))
         (pos (make-hash-table :test 'equal)))
    (setf (gethash "uri" td) uri)
    (setf (gethash "line" pos) line
          (gethash "character" pos) character)
    (setf (gethash "textDocument" params) td
          (gethash "position" params) pos)
    (gethash "result"
             (send-and-receive sock "textDocument/definition" :params params))))

(defun result-as-single-location (result)
  "Coerce a definition result to a single Location hash, or NIL if the
result is null or empty. If it's an array of Locations, returns the
first."
  (cond
    ((null result) nil)
    ((eq result :null) nil)
    ((hash-table-p result) result)
    ((and (consp result) (hash-table-p (first result))) (first result))
    (t nil)))

(defun range-start (loc)
  (let ((r (gethash "range" loc)))
    (and r (gethash "start" r))))

(defun range-end (loc)
  (let ((r (gethash "range" loc)))
    (and r (gethash "end" r))))

(defmacro with-defn-fixture ((sock uri text) &body body)
  "Wire fixture: ensure a server, open URI with TEXT, bind SOCK, run BODY."
  `(with-test-server (port)
     (with-client-socket (,sock port)
       (initialize-and-open ,sock :uri ,uri :text ,text)
       ,@body)))

;;; --- Local binder cases (resolver returns :LOCAL) ---

(test let-bound-use-jumps-to-binder-name
  (let ((uri "file:///tmp/wire-let.lisp")
        ;; "(let ((x 1)) (list x))"
        ;;  0123456789012345678901
        ;;            1111111111222
        (text "(let ((x 1)) (list x))"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the use of x at character 19
      (let* ((result (definition-at sock uri 0 19))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location, got ~S" result)
        (is (equal uri (gethash "uri" loc))
            "Expected same-document URI, got ~S" (gethash "uri" loc))
        (let ((start (range-start loc))
              (end (range-end loc)))
          ;; Binder is x at offset 7 -> line 0, characters 7..8.
          (is (eql 0 (gethash "line" start)))
          (is (eql 7 (gethash "character" start)))
          (is (eql 0 (gethash "line" end)))
          (is (eql 8 (gethash "character" end))))))))

(test lambda-param-use-jumps-to-param-name
  (let ((uri "file:///tmp/wire-lambda.lisp")
        ;; "(lambda (a) (list a))"
        ;;  012345678901234567890
        ;;            11111111112
        (text "(lambda (a) (list a))"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the use of a at character 18
      (let* ((result (definition-at sock uri 0 18))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc))
        (is (equal uri (gethash "uri" loc)))
        (let ((start (range-start loc))
              (end (range-end loc)))
          ;; Binder a at offset 9.
          (is (eql 0 (gethash "line" start)))
          (is (eql 9 (gethash "character" start)))
          (is (eql 10 (gethash "character" end))))))))

(test labels-call-jumps-to-defn-name
  (let ((uri "file:///tmp/wire-labels.lisp")
        ;; "(labels ((helper (n) n)) (helper 5))"
        ;;  0         1         2         3
        ;;  0123456789012345678901234567890123456
        (text "(labels ((helper (n) n)) (helper 5))"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the use of helper at character 26
      (let* ((result (definition-at sock uri 0 26))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (let ((start (range-start loc))
              (end (range-end loc)))
          ;; Defn name "helper" starts at offset 10, ends at 16.
          (is (eql 0 (gethash "line" start)))
          (is (eql 10 (gethash "character" start)))
          (is (eql 16 (gethash "character" end))))))))

(test flet-call-jumps-to-defn-name
  (let ((uri "file:///tmp/wire-flet.lisp")
        ;; "(flet ((helper (n) n)) (helper 5))"
        ;;  0         1         2         3
        ;;  0123456789012345678901234567890123
        (text "(flet ((helper (n) n)) (helper 5))"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the use of helper at character 24
      (let* ((result (definition-at sock uri 0 24))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (let ((start (range-start loc))
              (end (range-end loc)))
          ;; Defn name "helper" starts at offset 8, ends at 14.
          (is (eql 0 (gethash "line" start)))
          (is (eql 8 (gethash "character" start)))
          (is (eql 14 (gethash "character" end))))))))

(test let-multiline-resolves-binder-position
  (let* ((uri "file:///tmp/wire-let-ml.lisp")
         ;; "(let ((x 1))\n  (list x))"
         ;;  Line 0: "(let ((x 1))"          chars 0-11
         ;;  Line 1: "  (list x))"            chars 0-10 (offset starts after \n)
         (text (format nil "(let ((x 1))~%  (list x))")))
    (with-defn-fixture (sock uri text)
      ;; cursor on use of x at line 1, character 8
      (let* ((result (definition-at sock uri 1 8))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (let ((start (range-start loc))
              (end (range-end loc)))
          ;; Binder x is on line 0, offset 7.
          (is (eql 0 (gethash "line" start)))
          (is (eql 7 (gethash "character" start)))
          (is (eql 0 (gethash "line" end)))
          (is (eql 8 (gethash "character" end))))))))

(test inner-let-shadowing-jumps-to-inner-binder
  (let ((uri "file:///tmp/wire-shadow.lisp")
        ;; "(let ((x 1)) (let ((x 2)) (list x)))"
        ;;  0         1         2         3
        ;;  0123456789012345678901234567890123456
        ;; outer x at 7, inner x at 20, use at 32
        (text "(let ((x 1)) (let ((x 2)) (list x)))"))
    (with-defn-fixture (sock uri text)
      ;; cursor on inner use of x at character 32
      (let* ((result (definition-at sock uri 0 32))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (let ((start (range-start loc)))
          ;; Should be the *inner* binder at offset 20, not outer at 7.
          (is (eql 20 (gethash "character" start))
              "Expected inner binder at char 20, got ~S"
              (gethash "character" start)))))))

;;; --- Fall-through cases (resolver returns :FOREIGN) ---

(test global-function-call-still-falls-through-to-swank
  ;; Regression guard: global symbols must continue to resolve via the
  ;; existing swank path. The Location URI must NOT be the current
  ;; document.
  (let ((uri "file:///tmp/wire-fallthrough-global.lisp")
        ;; "(list 1 2 3)" -- call to cl:list, swank should find a file location.
        (text "(list 1 2 3)"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the `l` of list at character 1
      (let* ((result (definition-at sock uri 0 1))
             (loc (result-as-single-location result)))
        ;; Either a Location with a *different* URI than the current doc,
        ;; or a list of such Locations. If swank can't find it (image
        ;; without sources), result may be null -- but in our test image
        ;; sbcl-source is installed, so we expect a Location.
        (is (hash-table-p loc) "Expected swank fallthrough to return a Location, got ~S" result)
        (is (not (equal uri (gethash "uri" loc)))
            "Local branch should NOT have hijacked the global resolution; got URI ~S"
            (gethash "uri" loc))))))

(test free-variable-falls-through-to-swank
  ;; Free variable (no binder in source). Resolver returns :FOREIGN,
  ;; handler falls through to swank. Swank may or may not find a global
  ;; -- what matters is the local branch didn't return a (wrong)
  ;; same-document Location.
  (let ((uri "file:///tmp/wire-fallthrough-free.lisp")
        (text "(+ y 1)"))
    (with-defn-fixture (sock uri text)
      (let* ((result (definition-at sock uri 0 3))
             (loc (result-as-single-location result)))
        (when (hash-table-p loc)
          (is (not (equal uri (gethash "uri" loc)))
              "Free variable y must not resolve to current document; got URI ~S"
              (gethash "uri" loc)))
        ;; Result null is also acceptable -- swank had nothing.
        (is (or (null loc)
                (and (hash-table-p loc)
                     (not (equal uri (gethash "uri" loc)))))
            "Expected null or a different-URI Location, got ~S" result)))))

(test cursor-just-past-symbol-end-still-resolves-local
  ;; Editor cursor often sits one past the symbol's last char.
  ;; extract-symbol-at handles this; the resolver branch must too.
  (let ((uri "file:///tmp/wire-cursor-end.lisp")
        (text "(let ((x 1)) (list x))"))
    (with-defn-fixture (sock uri text)
      ;; The use of x is at offset 19. character=20 is one past -- same
      ;; symbol still under-cursor for editor purposes.
      (let* ((result (definition-at sock uri 0 20))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location even with cursor past symbol, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (is (eql 7 (gethash "character" (range-start loc))))))))

;;; --- VIA-MACROS cases (resolver returns VIA-MACROS) ---
;;;
;;; The resolver returns VIA-MACROS when the cursor lands on a symbol
;;; bound by a macro expansion. We test the full strategy: chain ->
;;; filter system symbols -> ask swank where the innermost user macro
;;; is defined -> return its source location.
;;;
;;; For swank to find a meaningful source location, the macros must be
;;; LOADED FROM A FILE (not just eval'd) so swank's source-tracking has
;;; a file path to point at.

(test via-macros-jumps-to-innermost-user-defmacro
  ;; Inner macro introduces a binding via `let`; outer macro just
  ;; passes through. Cursor on the macro-introduced symbol ->
  ;; resolver returns VIA-MACROS with chain (OUTER INNER) ->
  ;; we jump to INNER's defmacro source.
  (let* ((macro-file (uiop:tmpize-pathname "/tmp/swank-lsp-test-vm-macros.lisp"))
         (macro-text "(in-package :cl-user)
(defmacro %wire-vm-inner (x &body body)
  `(let ((%wire-vm-name ,x)) ,@body))
(defmacro %wire-vm-outer (&body body)
  `(%wire-vm-inner :tag ,@body))
"))
    (unwind-protect
         (progn
           (uiop:with-output-file (s macro-file :if-exists :supersede)
             (write-string macro-text s))
           ;; Define the macros in the test image so:
           ;;  (a) macroexpansion fires inside cl-scope-resolver, and
           ;;  (b) swank's find-definitions-for-emacs has a file path
           ;;      to return.
           (load macro-file)
           ;; Now exercise the LSP wire path on a use site.
           (let* ((use-uri "file:///tmp/swank-lsp-vm-use.lisp")
                  (use-text "(in-package :cl-user)
(%wire-vm-outer (print %wire-vm-name))"))
             (with-defn-fixture (sock use-uri use-text)
               ;; cursor inside %wire-vm-name on line 1 (0-indexed).
               ;; Line 1 is "(%wire-vm-outer (print %wire-vm-name))"
               ;;            012345678901234567890123456789012345678
               ;;                      1111111111222222222233333333
               ;; %wire-vm-name starts at character 23.
               (let* ((result (definition-at sock use-uri 1 25))
                      (loc (result-as-single-location result)))
                 (is (hash-table-p loc)
                     "Expected a Location for via-macros, got ~S" result)
                 ;; Should jump to the macro file, not the use-site doc
                 ;; (and not be null).
                 (is (search "swank-lsp-test-vm-macros" (gethash "uri" loc))
                     "Expected URI in macro file, got ~S" (gethash "uri" loc))
                 (is (not (equal use-uri (gethash "uri" loc)))
                     "Should not point back at the use-site document")))))
      (ignore-errors (delete-file macro-file)))))

(test via-macros-filters-system-macros-from-chain
  ;; The resolver's chain often includes CL standard macros (DOLIST,
  ;; UNLESS, ...) that the walker expanded along the way. Those are not
  ;; useful jump targets -- jumping to SBCL's source for `unless` is
  ;; never what the user wants. system-symbol-p filters them; the test
  ;; verifies a chain containing both kinds collapses to the user macro.
  (let* ((macro-file (uiop:tmpize-pathname "/tmp/swank-lsp-test-filter-macros.lisp"))
         ;; This macro expands to a DOLIST + UNLESS combination that the
         ;; walker will macroexpand. The resulting chain will contain
         ;; CL macros mixed with our user macro.
         (macro-text "(in-package :cl-user)
(defmacro %wire-filter-binder (var src &body body)
  `(dolist (,var ,src)
     (unless (null ,var) ,@body)))
"))
    (unwind-protect
         (progn
           (uiop:with-output-file (s macro-file :if-exists :supersede)
             (write-string macro-text s))
           (load macro-file)
           (let* ((use-uri "file:///tmp/swank-lsp-filter-use.lisp")
                  (use-text "(in-package :cl-user)
(%wire-filter-binder item '(1 2 3) (print item))"))
             (with-defn-fixture (sock use-uri use-text)
               ;; cursor on use of `item` near end. Find it manually.
               ;; Line 1: "(%wire-filter-binder item '(1 2 3) (print item))"
               ;;          0         1         2         3         4
               ;;          0123456789012345678901234567890123456789012345678
               ;; The use of `item` is at character 43.
               (let* ((result (definition-at sock use-uri 1 43))
                      (loc (result-as-single-location result)))
                 ;; The result type isn't the headline assertion -- what
                 ;; matters is we did NOT get a result pointing into
                 ;; SBCL's source for DOLIST or UNLESS. Either we get
                 ;; the user's macro file (filter worked) or null
                 ;; (resolver returned LOCAL -- `item` is genuinely the
                 ;; dolist binder from the user macro's perspective);
                 ;; both are correct. We just must not see system paths.
                 (when (hash-table-p loc)
                   (let ((uri (gethash "uri" loc)))
                     (is (not (search "/sbcl-source/" uri))
                         "Filter failed: chain leaked SBCL source path ~S" uri)
                     (is (not (search "/usr/share/sbcl" uri))
                         "Filter failed: chain leaked SBCL system path ~S" uri)))))))
      (ignore-errors (delete-file macro-file)))))

;;; --- textDocument/references (gr) for local bindings ---

(defun references-at (sock uri line character &key (include-declaration t))
  "Send textDocument/references for URI at (LINE, CHARACTER), return result."
  (let* ((params (make-hash-table :test 'equal))
         (td (make-hash-table :test 'equal))
         (pos (make-hash-table :test 'equal))
         (ctx (make-hash-table :test 'equal)))
    (setf (gethash "uri" td) uri)
    (setf (gethash "line" pos) line
          (gethash "character" pos) character)
    (setf (gethash "includeDeclaration" ctx) include-declaration)
    (setf (gethash "textDocument" params) td
          (gethash "position" params) pos
          (gethash "context" params) ctx)
    (gethash "result"
             (send-and-receive sock "textDocument/references" :params params))))

(test references-on-let-bound-finds-binder-and-all-uses
  (let ((uri "file:///tmp/wire-refs-let.lisp")
        ;; Source contains 1 binder + 3 uses of `x'.
        ;;
        ;; "(let ((x 1))     " 0..16
        ;; "  (list x x (* 2 x)))" 17..40
        (text "(let ((x 1))
  (list x x (* 2 x)))"))
    (with-defn-fixture (sock uri text)
      ;; Cursor on the use of x at line 1 character 8 (the first `x' use)
      (let ((result (references-at sock uri 1 8)))
        (is (and (consp result) (= 4 (length result)))
            "Expected 4 references (1 binder + 3 uses), got ~A" result)))))

(test references-on-shadowed-binder-finds-only-inner-scope
  (let ((uri "file:///tmp/wire-refs-shadow.lisp")
        (text "(let ((x 1))
  (let ((x 2))
    (list x x)))"))
    (with-defn-fixture (sock uri text)
      ;; Cursor on the inner `x' use at line 2, character 10 (first x in body)
      (let ((result (references-at sock uri 2 10)))
        ;; Inner scope: 1 binder (line 1, char 9) + 2 uses on line 2.
        ;; Outer x (line 0) must NOT appear because it's a different binder.
        (is (and (consp result) (= 3 (length result)))
            "Expected 3 references in inner scope only, got ~A" result)
        (let ((lines (mapcar (lambda (loc)
                               (gethash "line" (gethash "start" (gethash "range" loc))))
                             result)))
          (is (not (member 0 lines))
              "Outer-scope binder (line 0) should not appear; got lines ~A" lines))))))

(test references-on-non-local-returns-project-xrefs
  "Cursor on a global like `list` lands cross-file refs out of the
SQLite project index. swank-lsp's own source uses `list` heavily,
so we expect ≥1 location, all under the project root.

Filter correctness — no .qlot/ deps, no SBCL xref noise — is
asserted via the under-root check.

Synchronization: the bulk-index thread runs async; we wait for it
to finish so the test isn't racy."
  (let ((uri "file:///tmp/wire-refs-list.lisp")
        (text "(list 1 2 3)"))
    (with-defn-fixture (sock uri text)
      ;; The shared test server was started via START-SERVER, which
      ;; does not attach a project index (only START-AND-PUBLISH does).
      ;; Attach one here pointing at the swank-lsp source root, then
      ;; wait for the bulk-index thread before querying.
      (let ((root (truename "/home/tramfjord/projects/swank-lsp/")))
        (unless (swank-lsp::running-server-index-conn swank-lsp::*server*)
          (swank-lsp::start-server-index swank-lsp::*server* root))
        (let ((idx-thread (swank-lsp::running-server-index-thread
                           swank-lsp::*server*)))
          (when idx-thread
            (handler-case (bordeaux-threads:join-thread idx-thread)
              (error () nil))))
        ;; Set project-root too so the local-references path / future
        ;; under-root checks see the same value.
        (setf (swank-lsp::running-server-project-root swank-lsp::*server*)
              root))
      (let ((result (references-at sock uri 0 1)))   ; cursor on `list'
        (is (and (listp result) (not (null result)))
            "Expected non-empty cross-file refs, got ~A" result)
        (let ((root (truename (swank-lsp::running-server-project-root
                               swank-lsp::*server*))))
          (dolist (loc result)
            (let* ((u (gethash "uri" loc))
                   (path (subseq u 7))) ; strip "file://"
              (is (uiop:subpathp (truename path) root)
                  "Expected ~A to be under project root ~A" path root))))))))
