(in-package #:swank-lsp/tests)

;;;; Integration tests through the real LSP wire protocol over TCP.
;;;; Each test spins up a fresh swank-lsp server, opens a TCP socket
;;;; from another connection, sends framed JSON-RPC, asserts the
;;;; response. This exercises framing + JSON-RPC + handler dispatch +
;;;; swank integration in one shot.
;;;;
;;;; Tests are intentionally light on swank-result content (which
;;;; depends on what's loaded in the image and is not the layer we're
;;;; testing). We assert the *shape* of the LSP response is right.

(in-suite wire-suite)

(test initialize-handshake
  (with-test-server (port)
    (with-client-socket (sock port)
      (let ((cap-h (make-hash-table :test 'equal))
            (gen-h (make-hash-table :test 'equal))
            (params (make-hash-table :test 'equal)))
        (setf (gethash "positionEncodings" gen-h) '("utf-8" "utf-16"))
        (setf (gethash "general" cap-h) gen-h)
        (setf (gethash "processId" params) 0)
        (setf (gethash "capabilities" params) cap-h)
        (let* ((resp (send-and-receive sock "initialize" :params params))
               (result (gethash "result" resp))
               (caps (gethash "capabilities" result))
               (info (gethash "serverInfo" result)))
          (is (equal "2.0" (gethash "jsonrpc" resp)))
          (is (not (null result)))
          (is (equal "swank-lsp" (gethash "name" info)))
          (is (equal "0.1.0"     (gethash "version" info)))
          ;; Negotiated UTF-8 because we offered it.
          (is (equal "utf-8" (gethash "positionEncoding" caps)))
          (is (gethash "definitionProvider" caps))
          (is (gethash "hoverProvider" caps))
          (is (not (null (gethash "completionProvider" caps))))
          (is (not (null (gethash "signatureHelpProvider" caps))))
          (is (not (null (gethash "textDocumentSync" caps)))))))))

(test initialize-falls-back-to-utf16-when-only-utf16-offered
  (with-test-server (port)
    (with-client-socket (sock port)
      (let ((cap-h (make-hash-table :test 'equal))
            (gen-h (make-hash-table :test 'equal))
            (params (make-hash-table :test 'equal)))
        (setf (gethash "positionEncodings" gen-h) '("utf-16"))
        (setf (gethash "general" cap-h) gen-h)
        (setf (gethash "capabilities" params) cap-h)
        (let* ((resp (send-and-receive sock "initialize" :params params))
               (caps (gethash "capabilities" (gethash "result" resp))))
          (is (equal "utf-16" (gethash "positionEncoding" caps))))))))

(defun wait-until (predicate &key (timeout 2.0) (interval 0.02))
  "Block until PREDICATE returns truthy or TIMEOUT-SEC elapses. Returns
the predicate's last value (truthy on success, falsy on timeout)."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second)))
        (result nil))
    (loop
      (setf result (funcall predicate))
      (when result (return result))
      (when (>= (get-internal-real-time) deadline) (return result))
      (sleep interval))))

(test did-open-stores-document-then-did-close-removes
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock
                           :uri "file:///tmp/wire-test.lisp"
                           :text "(defun foo (x) x)")
      (wait-until (lambda () (= 1 (swank-lsp:document-count))))
      (is (= 1 (swank-lsp:document-count)))
      ;; close
      (let ((p (make-hash-table :test 'equal))
            (td (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-test.lisp")
        (setf (gethash "textDocument" p) td)
        (notify sock "textDocument/didClose" :params p))
      (wait-until (lambda () (= 0 (swank-lsp:document-count))))
      (is (= 0 (swank-lsp:document-count))))))

(test did-change-replaces-text
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock
                           :uri "file:///tmp/wire-change.lisp"
                           :text "(defun foo (x) x)")
      (let ((p (make-hash-table :test 'equal))
            (td (make-hash-table :test 'equal))
            (change (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-change.lisp"
              (gethash "version" td) 2)
        (setf (gethash "text" change) "(defun bar (y) y)")
        (setf (gethash "textDocument" p) td
              (gethash "contentChanges" p) (list change))
        (notify sock "textDocument/didChange" :params p))
      (wait-until (lambda ()
                    (let ((d (swank-lsp:get-document "file:///tmp/wire-change.lisp")))
                      (and d (equal "(defun bar (y) y)" (swank-lsp::document-text d))))))
      (let ((doc (swank-lsp:get-document "file:///tmp/wire-change.lisp")))
        (is (equal "(defun bar (y) y)"
                   (swank-lsp::document-text doc)))
        (is (eql 2 (swank-lsp::document-version doc)))))))

(test definition-on-known-global-returns-location
  (with-test-server (port)
    (with-client-socket (sock port)
      ;; A tiny lisp buffer using `cl:list` -- global, definitely findable.
      (initialize-and-open sock
                           :uri "file:///tmp/wire-def.lisp"
                           :text "(list 1 2 3)")
      ;; Position at column 1 (= first char of `list` in 1-based; LSP is
      ;; 0-based, so character=1 lands on 'l' in "(list ...)"
      (let* ((params (make-hash-table :test 'equal))
             (td (make-hash-table :test 'equal))
             (pos (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-def.lisp")
        (setf (gethash "line" pos) 0
              (gethash "character" pos) 1)
        (setf (gethash "textDocument" params) td
              (gethash "position" params) pos)
        (let* ((resp (send-and-receive sock "textDocument/definition" :params params))
               (result (gethash "result" resp)))
          ;; Result is either a Location, an array of Location, or null.
          ;; For `list` swank typically returns several. Either way: not null.
          (is (or (consp result)
                  (hash-table-p result))
              "Expected a Location or array; got ~S" result)
          ;; If it's a Location object, must have uri + range.
          (when (hash-table-p result)
            (is (gethash "uri" result))
            (is (gethash "range" result)))
          (when (consp result)
            (let ((first (first result)))
              (is (gethash "uri" first))
              (is (gethash "range" first)))))))))

(test completion-returns-list
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock
                           :uri "file:///tmp/wire-comp.lisp"
                           :text "(forma")
      ;; Cursor at end of buffer (line 0, character 6)
      (let* ((params (make-hash-table :test 'equal))
             (td (make-hash-table :test 'equal))
             (pos (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-comp.lisp")
        (setf (gethash "line" pos) 0
              (gethash "character" pos) 6)
        (setf (gethash "textDocument" params) td
              (gethash "position" params) pos)
        (let* ((resp (send-and-receive sock "textDocument/completion" :params params))
               (result (gethash "result" resp)))
          (is (hash-table-p result) "Got: ~S" result)
          (let ((items (gethash "items" result)))
            (is (consp items))
            (is (every (lambda (it) (and (hash-table-p it)
                                         (stringp (gethash "label" it))))
                       items))
            ;; Should include at least format / formatter
            (is (some (lambda (it) (search "format" (gethash "label" it)))
                      items))))))))

(test hover-on-known-symbol-returns-contents
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock
                           :uri "file:///tmp/wire-hover.lisp"
                           :text "(list 1 2)")
      (let* ((params (make-hash-table :test 'equal))
             (td (make-hash-table :test 'equal))
             (pos (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-hover.lisp")
        (setf (gethash "line" pos) 0
              (gethash "character" pos) 2)
        (setf (gethash "textDocument" params) td
              (gethash "position" params) pos)
        (let* ((resp (send-and-receive sock "textDocument/hover" :params params))
               (result (gethash "result" resp)))
          ;; Result should be a Hover object with .contents
          (is (hash-table-p result) "Got: ~S" result)
          (let ((contents (gethash "contents" result)))
            (is (hash-table-p contents))
            (is (stringp (gethash "value" contents)))
            (is (plusp (length (gethash "value" contents))))))))))

(test hover-on-lexical-let-binder-shows-type-and-init
  ;; The headline case: K on `hi` shows "hi : <integer-shaped type>"
  ;; and a code block with "hi = (1- (length line-starts))".
  (with-test-server (port)
    (with-client-socket (sock port)
      (let ((text "(defun frob (line-starts)
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (list lo hi)))"))
        (initialize-and-open sock
                             :uri "file:///tmp/wire-hover-let.lisp"
                             :text text)
        (let* ((hi-offset (search "hi" text :start2 30))
               (hi-line   (count #\Newline text :end hi-offset))
               (hi-char   (- hi-offset
                             (or (position #\Newline text :end hi-offset
                                           :from-end t) -1)
                             1))
               (params (make-hash-table :test 'equal))
               (td (make-hash-table :test 'equal))
               (pos (make-hash-table :test 'equal)))
          (setf (gethash "uri" td) "file:///tmp/wire-hover-let.lisp")
          (setf (gethash "line" pos) hi-line
                (gethash "character" pos) hi-char)
          (setf (gethash "textDocument" params) td
                (gethash "position" params) pos)
          (let* ((resp (send-and-receive sock "textDocument/hover" :params params))
                 (result (gethash "result" resp))
                 (contents (and (hash-table-p result)
                                (gethash "contents" result)))
                 (kind  (and contents (gethash "kind" contents)))
                 (value (and contents (gethash "value" contents))))
            (is (equal "markdown" kind) "kind should be markdown; got ~S" kind)
            (is (and (stringp value) (search "HI" (string-upcase value)))
                "hover should mention HI; got ~S" value)
            (is (search "INTEGER" (string-upcase value))
                "hover should include integer-shaped type; got ~S" value)
            (is (search "(1-" value)
                "hover should include the init-form (1- ...); got ~S" value)))))))

(test hover-on-use-of-lexical-binder-redirects-to-binder
  ;; K on a USE of `hi` (not the binder) should produce the same
  ;; hover as K on the binder. Regression guard for the resolve-and-
  ;; redirect workaround in BINDER-INFO-OFFSET-REDIRECTED.
  (with-test-server (port)
    (with-client-socket (sock port)
      (let ((text "(defun frob (line-starts)
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (list lo hi)))"))
        (initialize-and-open sock
                             :uri "file:///tmp/wire-hover-use.lisp"
                             :text text)
        (let* ((use-prefix "(list lo ")
               (use-anchor (search use-prefix text))
               (use-offset (and use-anchor (+ use-anchor (length use-prefix))))
               (use-line   (count #\Newline text :end use-offset))
               (use-char   (- use-offset
                              (or (position #\Newline text :end use-offset
                                            :from-end t) -1)
                              1))
               (params (make-hash-table :test 'equal))
               (td (make-hash-table :test 'equal))
               (pos (make-hash-table :test 'equal)))
          (setf (gethash "uri" td) "file:///tmp/wire-hover-use.lisp")
          (setf (gethash "line" pos) use-line
                (gethash "character" pos) use-char)
          (setf (gethash "textDocument" params) td
                (gethash "position" params) pos)
          (let* ((resp (send-and-receive sock "textDocument/hover" :params params))
                 (result (gethash "result" resp))
                 (contents (and (hash-table-p result) (gethash "contents" result)))
                 (value (and contents (gethash "value" contents))))
            (is (and (stringp value) (search "INTEGER" (string-upcase value)))
                "use-site hover should mirror binder hover; got ~S" value)
            (is (search "(1-" value)
                "use-site hover should include the binder's init-form; got ~S" value)))))))

(test hover-on-declared-fixnum-param-shows-fixnum
  (with-test-server (port)
    (with-client-socket (sock port)
      (let ((text "(defun double (x)
  (declare (fixnum x))
  (* 2 x))"))
        (initialize-and-open sock
                             :uri "file:///tmp/wire-hover-param.lisp"
                             :text text)
        (let* ((x-offset (search "x" text))
               (x-line   (count #\Newline text :end x-offset))
               (x-char   (- x-offset
                            (or (position #\Newline text :end x-offset
                                          :from-end t) -1)
                            1))
               (params (make-hash-table :test 'equal))
               (td (make-hash-table :test 'equal))
               (pos (make-hash-table :test 'equal)))
          (setf (gethash "uri" td) "file:///tmp/wire-hover-param.lisp")
          (setf (gethash "line" pos) x-line
                (gethash "character" pos) x-char)
          (setf (gethash "textDocument" params) td
                (gethash "position" params) pos)
          (let* ((resp (send-and-receive sock "textDocument/hover" :params params))
                 (result (gethash "result" resp))
                 (contents (and (hash-table-p result)
                                (gethash "contents" result)))
                 (value (and contents (gethash "value" contents))))
            (is (and (stringp value) (search "FIXNUM" (string-upcase value)))
                "hover for declared-fixnum param should include FIXNUM; got ~S"
                value)))))))

(test signature-help-returns-arglist
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock
                           :uri "file:///tmp/wire-sig.lisp"
                           :text "(list ")
      ;; Cursor inside the call, just after the space
      (let* ((params (make-hash-table :test 'equal))
             (td (make-hash-table :test 'equal))
             (pos (make-hash-table :test 'equal)))
        (setf (gethash "uri" td) "file:///tmp/wire-sig.lisp")
        (setf (gethash "line" pos) 0
              (gethash "character" pos) 6)
        (setf (gethash "textDocument" params) td
              (gethash "position" params) pos)
        (let* ((resp (send-and-receive sock "textDocument/signatureHelp" :params params))
               (result (gethash "result" resp)))
          (is (hash-table-p result) "Got: ~S" result)
          (let ((sigs (gethash "signatures" result)))
            (is (consp sigs))
            (is (stringp (gethash "label" (first sigs))))
            (is (search "list" (string-downcase (gethash "label" (first sigs)))))))))))

(test shutdown-returns-null-result
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock :uri nil :text nil)
      (let* ((resp (send-and-receive sock "shutdown")))
        (is (equal "2.0" (gethash "jsonrpc" resp)))
        (is (or (null (gethash "result" resp))
                (eq (gethash "result" resp) :null)))))))

;;;; NOTE: a true exit-stops-server test is omitted from the suite
;;;; because the test fixture shares a single server across tests for
;;;; cleanup-determinism reasons. EXIT-HANDLER is exercised by the
;;;; standalone-fixture test below, which restarts the server afterward.

(test exit-handler-stops-server-then-restarts
  ;; This test deliberately tears down the shared server and re-creates
  ;; it so subsequent tests in the suite still find one.
  (with-test-server (port)
    (with-client-socket (sock port)
      (initialize-and-open sock :uri nil :text nil)
      (notify sock "exit")))
  ;; The exit-thunk runs in a side thread (~0.1s after exit).
  (wait-until (lambda () (null swank-lsp:*server*)) :timeout 2.0)
  (is (null swank-lsp:*server*))
  ;; Re-create the server for downstream tests.
  (ensure-test-server)
  (is (not (null swank-lsp:*server*))))
