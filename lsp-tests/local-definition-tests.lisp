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
          ;; Binder is x at offset 7 → line 0, characters 7..8.
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
        ;; "(list 1 2 3)" — call to cl:list, swank should find a file location.
        (text "(list 1 2 3)"))
    (with-defn-fixture (sock uri text)
      ;; cursor on the `l` of list at character 1
      (let* ((result (definition-at sock uri 0 1))
             (loc (result-as-single-location result)))
        ;; Either a Location with a *different* URI than the current doc,
        ;; or a list of such Locations. If swank can't find it (image
        ;; without sources), result may be null — but in our test image
        ;; sbcl-source is installed, so we expect a Location.
        (is (hash-table-p loc) "Expected swank fallthrough to return a Location, got ~S" result)
        (is (not (equal uri (gethash "uri" loc)))
            "Local branch should NOT have hijacked the global resolution; got URI ~S"
            (gethash "uri" loc))))))

(test free-variable-falls-through-to-swank
  ;; Free variable (no binder in source). Resolver returns :FOREIGN,
  ;; handler falls through to swank. Swank may or may not find a global
  ;; — what matters is the local branch didn't return a (wrong)
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
        ;; Result null is also acceptable — swank had nothing.
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
      ;; The use of x is at offset 19. character=20 is one past — same
      ;; symbol still under-cursor for editor purposes.
      (let* ((result (definition-at sock uri 0 20))
             (loc (result-as-single-location result)))
        (is (hash-table-p loc) "Expected a Location even with cursor past symbol, got ~S" result)
        (is (equal uri (gethash "uri" loc)))
        (is (eql 7 (gethash "character" (range-start loc))))))))
