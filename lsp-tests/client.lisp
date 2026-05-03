(in-package #:swank-lsp/tests)

;;;; Tiny LSP client helper for wire-level integration tests.
;;;; Opens a TCP socket to the running swank-lsp server, sends framed
;;;; JSON-RPC requests/notifications, parses responses.
;;;;
;;;; Editor-agnostic: same wire shape any real LSP client uses.

(defvar *test-port* nil
  "Port the test fixture started the server on.")

(defun next-id ()
  (let ((c 0))
    (lambda ()
      (incf c))))

(defparameter +id-counter+ (next-id))

(defun make-rpc-request-string (method &key params id)
  "Encode an LSP request (or notification if ID is NIL) as the framed
JSON string ready to write to a socket."
  (let* ((body
           (with-output-to-string (s)
             (yason:with-output (s)
               (yason:with-object ()
                 (yason:encode-object-element "jsonrpc" "2.0")
                 (when id (yason:encode-object-element "id" id))
                 (yason:encode-object-element "method" method)
                 (when params
                   (yason:with-object-element ("params")
                     (yason:encode params s)))))))
         (body-bytes (sb-ext:string-to-octets body :external-format :utf-8))
         (header (format nil "Content-Length: ~A~C~C~:*~:*~C~C"
                         (length body-bytes) #\Return #\Newline)))
    (values header body-bytes)))

(defun send-lsp-message (stream method &key params id)
  "Write a framed message and flush."
  (multiple-value-bind (header body) (make-rpc-request-string method :params params :id id)
    (write-sequence (sb-ext:string-to-octets header :external-format :ascii) stream)
    (write-sequence body stream)
    (force-output stream)))

(defun read-lsp-headers (stream)
  "Read CRLF-terminated headers, return a hash-table (lowercased keys)."
  (let ((buf (make-array 256 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0))
        (state :body))
    (declare (ignore state))
    ;; Accumulate until CRLFCRLF.
    (loop
      (let ((b (read-byte stream nil nil)))
        (unless b (error "EOF reading LSP headers"))
        (vector-push-extend b buf)
        (when (and (>= (length buf) 4)
                   (= (aref buf (- (length buf) 4)) (char-code #\Return))
                   (= (aref buf (- (length buf) 3)) (char-code #\Newline))
                   (= (aref buf (- (length buf) 2)) (char-code #\Return))
                   (= (aref buf (- (length buf) 1)) (char-code #\Newline)))
          (return))))
    (let* ((str (sb-ext:octets-to-string buf :external-format :ascii))
           (lines (uiop:split-string str :separator #(#\Newline)))
           (h (make-hash-table :test 'equal)))
      (dolist (line lines)
        (let* ((trimmed (string-trim '(#\Return #\Space #\Tab) line))
               (colon (position #\: trimmed)))
          (when (and colon (plusp colon))
            (let ((k (string-downcase (string-trim '(#\Space) (subseq trimmed 0 colon))))
                  (v (string-trim '(#\Space) (subseq trimmed (1+ colon)))))
              (setf (gethash k h) v)))))
      h)))

(defun read-lsp-message (stream)
  "Read a single framed LSP message from STREAM, parse JSON. Returns a
hash-table (yason parse) representing the JSON-RPC envelope."
  (let* ((headers (read-lsp-headers stream))
         (cl-str (gethash "content-length" headers))
         (len (and cl-str (parse-integer cl-str)))
         (body (make-array len :element-type '(unsigned-byte 8))))
    (read-sequence body stream)
    (yason:parse (sb-ext:octets-to-string body :external-format :utf-8))))

(defun send-and-receive (stream method &key params)
  "Issue a request (auto-id), wait for the matching response. Returns
the parsed JSON envelope hash-table."
  (let ((id (funcall +id-counter+)))
    (send-lsp-message stream method :params params :id id)
    (loop
      (let ((msg (read-lsp-message stream)))
        ;; Could be a notification from the server (e.g. window/logMessage),
        ;; skip until we see our id.
        (let ((mid (gethash "id" msg)))
          (when (and mid (eql mid id))
            (return msg)))))))

(defun notify (stream method &key params)
  (send-lsp-message stream method :params params :id nil))

;;;; Test fixture macros

(defun ensure-test-server ()
  "Start a single shared LSP server for the test suite, reusing it
across tests. Tearing down jsonrpc's per-connection threads cleanly is
brittle (the TCP transport spawns reading + processing threads inside
the listener and doesn't track them on the server side), so the simpler
shape is one server for the whole suite. State is reset between tests
in WITH-TEST-SERVER's prelude.

Returns the port number."
  (cond
    (swank-lsp:*server*
     (swank-lsp:server-port))
    (t
     (swank-lsp:start-server :transport :tcp :port 0)
     (swank-lsp:server-port))))

(defun reset-test-server-state ()
  "Wipe per-connection state so the next test starts clean."
  (swank-lsp:reset-document-store)
  (swank-lsp::reset-server-state)
  (setf swank-lsp:*server-position-encoding* :utf-16))

(defmacro with-test-server ((port-var &key transport) &body body)
  "Bind PORT-VAR to a (possibly shared) test server's port, reset its
state, run BODY. Each invocation opens a fresh client socket inside
WITH-CLIENT-SOCKET; tests don't share connections."
  (declare (ignore transport))
  `(let* ((,port-var (ensure-test-server)))
     (setf *test-port* ,port-var)
     (reset-test-server-state)
     ,@body))

(defmacro with-client-socket ((stream-var port) &body body)
  `(let* ((sock (usocket:socket-connect "127.0.0.1" ,port
                                        :element-type '(unsigned-byte 8)))
          (,stream-var (usocket:socket-stream sock)))
     (unwind-protect (progn ,@body)
       (handler-case (usocket:socket-close sock) (error () nil)))))

(defun initialize-and-open (stream &key uri text)
  "Convenience: send initialize + initialized + didOpen so the server
is ready to answer requests against URI/TEXT. Returns the InitializeResult
envelope so tests can also assert on capabilities if they want."
  (let* ((cap-h (make-hash-table :test 'equal))
         (gen-h (make-hash-table :test 'equal))
         (init-params (make-hash-table :test 'equal)))
    (setf (gethash "positionEncodings" gen-h) '("utf-8" "utf-16"))
    (setf (gethash "general" cap-h) gen-h)
    (setf (gethash "processId" init-params) 0)
    (setf (gethash "capabilities" init-params) cap-h)
    (let ((init-resp (send-and-receive stream "initialize" :params init-params)))
      (notify stream "initialized" :params (make-hash-table :test 'equal))
      (when uri
        (let ((p (make-hash-table :test 'equal))
              (td (make-hash-table :test 'equal)))
          (setf (gethash "uri"        td) uri
                (gethash "languageId" td) "lisp"
                (gethash "version"    td) 1
                (gethash "text"       td) text)
          (setf (gethash "textDocument" p) td)
          (notify stream "textDocument/didOpen" :params p)))
      init-resp)))
