;;;; swank-lsp stdio entrypoint.
;;;;
;;;; nvim's lspconfig spawns this via:
;;;;
;;;;   sbcl --script bin/swank-lsp-stdio.lisp
;;;;
;;;; or, with qlot:
;;;;
;;;;   ~/.roswell/bin/qlot exec sbcl --script bin/swank-lsp-stdio.lisp
;;;;
;;;; The script:
;;;;   1. Loads quicklisp / qlot setup so deps resolve.
;;;;   2. Pushes the project root onto asdf:*central-registry*.
;;;;   3. Loads :swank-lsp.
;;;;   4. Redirects *standard-output* / *error-output* / *trace-output*
;;;;      to a log file. The LSP wire is on stdin/stdout; ANY stray
;;;;      print to *standard-output* corrupts the framed stream and
;;;;      nvim disconnects.
;;;;   5. Optionally starts a swank server on a side port so the user
;;;;      can attach nvlime / Vlime to inspect the same image.
;;;;   6. Calls (swank-lsp:start-server :transport :stdio).

(in-package #:cl-user)

(require :asdf)

;;; --- 0) Capture original stdio FIRST and redirect all other output
;;;        to a log file. This must happen before any (load ...) call,
;;;        because qlot/ASDF/swank/jsonrpc all write to *standard-output*
;;;        during load and a single byte on stdout corrupts the LSP wire.

(defparameter *swank-lsp-real-stdin*  *standard-input*)
(defparameter *swank-lsp-real-stdout* *standard-output*)

(defparameter *swank-lsp-log-file*
  (merge-pathnames "swank-lsp.log" (uiop:temporary-directory)))

(defparameter *swank-lsp-log-stream*
  (open *swank-lsp-log-file*
        :direction :output
        :if-exists :append
        :if-does-not-exist :create))

(setf *standard-output* *swank-lsp-log-stream*
      *error-output*    *swank-lsp-log-stream*
      *trace-output*    *swank-lsp-log-stream*
      *debug-io*        (make-two-way-stream
                         (make-string-input-stream "")
                         *swank-lsp-log-stream*))

(format *swank-lsp-log-stream* "~&-- swank-lsp stdio starting (pid ~A) --~%"
        (uiop:getenv "PPID"))
(force-output *swank-lsp-log-stream*)

;;; --- 1) Quicklisp / qlot ---

(let* ((this-file *load-pathname*)
       (project-root (and this-file
                          (make-pathname
                           :directory (butlast (pathname-directory this-file))
                           :name nil
                           :type nil
                           :version nil
                           :defaults this-file))))
  (defparameter *swank-lsp-project-root* project-root)
  (let ((qlot-setup (and project-root
                         (probe-file
                          (merge-pathnames ".qlot/setup.lisp" project-root)))))
    (cond
      (qlot-setup (load qlot-setup))
      ((probe-file (merge-pathnames "quicklisp/setup.lisp"
                                    (user-homedir-pathname)))
       (load (merge-pathnames "quicklisp/setup.lisp"
                              (user-homedir-pathname))))
      (t (error "neither .qlot/setup.lisp nor ~~/quicklisp/setup.lisp found"))))
  (when project-root
    (push project-root asdf:*central-registry*)))

;;; --- 2) Load swank-lsp ---

(asdf:load-system :swank-lsp :verbose nil)

;;; --- 3) Optionally start an attached swank server on a side port ---
;;;
;;; Read a port from $SWANK_LSP_ATTACH_SWANK_PORT, default off.
;;; nvlime/Vlime can then attach for live REPL alongside the LSP server.

(let ((env-port (uiop:getenv "SWANK_LSP_ATTACH_SWANK_PORT")))
  (when (and env-port (plusp (length env-port)))
    (let ((p (parse-integer env-port :junk-allowed t)))
      (when p
        (handler-case
            (progn
              (asdf:load-system :swank :verbose nil)
              (funcall (find-symbol "CREATE-SERVER" :swank)
                       :port p :dont-close t)
              (format *swank-lsp-log-stream*
                      "swank attached on port ~A~%" p)
              (force-output *swank-lsp-log-stream*))
          (error (e)
            (format *swank-lsp-log-stream*
                    "FAILED to attach swank: ~A~%" e)
            (force-output *swank-lsp-log-stream*)))))))

;;; --- 4) Run ---
;;;
;;; Wrap in handler so EOF on stdin (client closed pipe / nvim quit)
;;; exits cleanly rather than landing in --disable-debugger mode.

(handler-case
    (swank-lsp:start-server :transport :stdio
                            :input  *swank-lsp-real-stdin*
                            :output *swank-lsp-real-stdout*)
  (end-of-file ()
    (format *swank-lsp-log-stream* "~&-- swank-lsp stdio: client closed; exiting --~%")
    (force-output *swank-lsp-log-stream*))
  (error (e)
    (format *swank-lsp-log-stream* "~&-- swank-lsp stdio: ~A; exiting --~%" e)
    (force-output *swank-lsp-log-stream*)))

(uiop:quit 0)
