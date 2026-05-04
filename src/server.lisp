(in-package #:swank-lsp)

;;;; LSP server lifecycle on jsonrpc.
;;;;
;;;; A single global *SERVER* holds the running jsonrpc server instance
;;;; and the bookkeeping needed to stop it. The server runs in a
;;;; background thread (TCP) or in the calling thread (stdio); START-SERVER
;;;; returns once the listening socket is live.
;;;;
;;;; The caller's expected pattern (in a long-lived dev image):
;;;;
;;;;   (swank:create-server :port 4007 :dont-close t)
;;;;   (asdf:load-system :swank-lsp)
;;;;   (swank-lsp:start-server :transport :tcp :port 7000)   ; or :stdio
;;;;
;;;; nvlime/Vlime attaches to swank on 4007 in parallel; nvim's
;;;; lspconfig spawns an SBCL process that runs bin/swank-lsp-stdio.lisp.

(defclass running-server ()
  ((jsonrpc        :initarg :jsonrpc        :accessor running-server-jsonrpc)
   (transport-kind :initarg :transport-kind :accessor running-server-transport-kind)
   (port           :initarg :port           :initform nil :accessor running-server-port)
   (thread         :initarg :thread         :initform nil :accessor running-server-thread)
   (exit-thunk     :initarg :exit-thunk     :initform nil :accessor running-server-exit-thunk)))

(defvar *server* nil
  "Currently-running RUNNING-SERVER, or NIL.")

(defun server-port ()
  (and *server* (running-server-port *server*)))

(defun server-transport-kind ()
  (and *server* (running-server-transport-kind *server*)))

;;;; Method registration

(defun register-lsp-methods (jsonrpc)
  "Bind LSP method names to handler defuns on the jsonrpc instance.
Each handler is wrapped in SAFE-HANDLER so an internal error returns
JSON null and logs to *error-output* instead of letting jsonrpc's
default dissect:present write to *standard-output* (which would
corrupt the stdio LSP wire)."
  (jsonrpc:expose jsonrpc "initialize"
                  (safe-handler "initialize" #'initialize-handler))
  (jsonrpc:expose jsonrpc "initialized"
                  (safe-handler "initialized" #'initialized-handler))
  (jsonrpc:expose jsonrpc "shutdown"
                  (safe-handler "shutdown" #'shutdown-handler))
  (jsonrpc:expose jsonrpc "exit"
                  (safe-handler "exit" #'exit-handler))
  (jsonrpc:expose jsonrpc "textDocument/didOpen"
                  (safe-handler "didOpen" #'did-open-handler))
  (jsonrpc:expose jsonrpc "textDocument/didChange"
                  (safe-handler "didChange" #'did-change-handler))
  (jsonrpc:expose jsonrpc "textDocument/didClose"
                  (safe-handler "didClose" #'did-close-handler))
  (jsonrpc:expose jsonrpc "textDocument/definition"
                  (safe-handler "definition" #'definition-handler))
  (jsonrpc:expose jsonrpc "textDocument/references"
                  (safe-handler "references" #'references-handler))
  (jsonrpc:expose jsonrpc "textDocument/completion"
                  (safe-handler "completion" #'completion-handler))
  (jsonrpc:expose jsonrpc "textDocument/hover"
                  (safe-handler "hover" #'hover-handler))
  (jsonrpc:expose jsonrpc "textDocument/signatureHelp"
                  (safe-handler "signatureHelp" #'signature-help-handler))
  jsonrpc)

;;;; Public entrypoint

(defun start-server (&key (transport :tcp) (port 0) (host "127.0.0.1")
                          input output)
  "Start the LSP server.
TRANSPORT: :tcp or :stdio.
For :tcp -- PORT 0 picks a random free port (returned via SERVER-PORT).
For :stdio -- uses INPUT/OUTPUT (default *standard-input*/*standard-output*).
Returns the RUNNING-SERVER instance."
  (when *server*
    (error "swank-lsp server is already running on ~A; call STOP-SERVER first."
           (running-server-transport-kind *server*)))
  (reset-server-state)
  (reset-document-store)
  (let ((jsonrpc (jsonrpc:make-server)))
    (register-lsp-methods jsonrpc)
    (ecase transport
      (:tcp
       (let* ((bound-port (if (zerop port) (find-free-port host) port))
              (rs (make-instance 'running-server
                                 :jsonrpc jsonrpc
                                 :transport-kind :tcp
                                 :port bound-port)))
         (setf *server* rs)
         (let ((thread
                 (bordeaux-threads:make-thread
                  (lambda ()
                    (handler-case
                        (jsonrpc:server-listen jsonrpc :mode :tcp
                                               :port bound-port
                                               :host host)
                      (error (e)
                        (format *error-output* "~&swank-lsp tcp server: ~A~%" e))))
                  :name (format nil "swank-lsp tcp ~A" bound-port))))
           (setf (running-server-thread rs) thread)
           ;; Wait briefly until the port is actually listening.
           (wait-until-listening host bound-port 5)
           rs)))
      (:stdio
       (let ((rs (make-instance 'running-server
                                :jsonrpc jsonrpc
                                :transport-kind :stdio
                                :port nil)))
         (setf *server* rs)
         ;; stdio start-server blocks the calling thread on the read loop.
         (let ((bt:*default-special-bindings* nil))
           (declare (ignorable bt:*default-special-bindings*)))
         (jsonrpc:server-listen jsonrpc :mode :stdio
                                :input  (or input  *standard-input*)
                                :output (or output *standard-output*))
         rs)))))

(defvar *published-port-file* nil
  "Pathname of the .swank-lsp-port file we wrote, so STOP-SERVER can
clean it up. Bound by START-AND-PUBLISH; nil otherwise.")

(defun stop-server ()
  "Stop the running server, if any. Returns T if a server was stopped.
If START-AND-PUBLISH wrote a port-file, delete it on stop."
  (let ((rs *server*))
    (unless rs
      (return-from stop-server nil))
    (handler-case
        (let ((thread (running-server-thread rs)))
          (when (and thread (bordeaux-threads:thread-alive-p thread))
            (bordeaux-threads:destroy-thread thread)))
      (error () nil))
    (setf *server* nil)
    (when *published-port-file*
      (handler-case (delete-file *published-port-file*) (error () nil))
      (setf *published-port-file* nil))
    t))

(defun start-and-publish (&key (port 0) (host "127.0.0.1")
                               (port-file ".swank-lsp-port"))
  "Start a TCP LSP server and write the bound port to PORT-FILE.

PORT-FILE is resolved relative to *DEFAULT-PATHNAME-DEFAULTS* (so call
this from your project root, or pass an absolute path). PORT 0 picks
a free port; the actual bound port goes into the file.

The convention -- mirroring how swank's bootstrap script writes
.swank-port -- is that any consumer (editor, tooling, attach shim)
discovers the port by reading the file, not by hardcoding it. Stop-
server deletes the file so a stale .swank-lsp-port can never point
at a dead listener."
  (let* ((rs (start-server :transport :tcp :port port :host host))
         (bound (running-server-port rs))
         (path (merge-pathnames port-file)))
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (format out "~A~%" bound))
    (setf *published-port-file* path)
    rs))

;;;; signal-server-exit hook (filled in here, called from exit-handler)

(defmethod signal-server-exit ()
  "Spawn a thread that stops the server shortly after exit-handler
returns its (empty) response. We can't tear down the listening thread
synchronously from inside a handler -- destroy-thread on self is
unspecified and the response hasn't yet been written."
  (when *server*
    (bordeaux-threads:make-thread
     (lambda ()
       (sleep 0.1)
       (stop-server))
     :name "swank-lsp exit")))

;;;; Helpers

(defun find-free-port (host)
  "Bind to port 0 and read back the assigned port, then close. Tiny race."
  (let ((sock (usocket:socket-listen host 0 :reuse-address t)))
    (unwind-protect
         (usocket:get-local-port sock)
      (usocket:socket-close sock))))

(defun wait-until-listening (host port timeout-seconds)
  "Block (briefly) until a TCP connection to HOST:PORT succeeds or
TIMEOUT-SECONDS elapses."
  (let ((deadline (+ (get-internal-real-time)
                     (* timeout-seconds internal-time-units-per-second))))
    (loop
      (when (handler-case
                (let ((sock (usocket:socket-connect host port
                                                    :timeout 1)))
                  (usocket:socket-close sock)
                  t)
              (error () nil))
        (return t))
      (when (>= (get-internal-real-time) deadline)
        (warn "swank-lsp: server did not become reachable on ~A:~A within ~A s"
              host port timeout-seconds)
        (return nil))
      (sleep 0.05))))
