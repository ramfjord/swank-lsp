(in-package #:swank-lsp)

;;;; Filesystem / URI utilities used by both the LSP handlers and
;;;; the indexer. Extracted from handlers.lisp so indexer.lisp can
;;;; use them without depending on handlers.lisp (load order:
;;;; util → indexer → handlers).

(defun path->file-uri (path)
  "Convert an absolute filesystem PATH to a file:// URI. If PATH
already looks like a URI, return as-is."
  (let ((p (etypecase path
             (string path)
             (pathname (namestring path)))))
    (if (search "://" p)
        p
        (concatenate 'string "file://" p))))

(defun file-uri->path (uri)
  "Inverse of PATH->FILE-URI. Returns the path string, or NIL on
mismatched scheme."
  (when (and uri (>= (length uri) 7) (string= "file://" uri :end2 7))
    (subseq uri 7)))

(defun read-file-as-string (path)
  "Read PATH as a UTF-8 string. Errors if the file doesn't exist."
  (with-open-file (in path :direction :input
                           :external-format :utf-8
                           :if-does-not-exist :error)
    (let ((buf (make-string (file-length in))))
      (let ((n (read-sequence buf in)))
        (if (= n (length buf))
            buf
            (subseq buf 0 n))))))

;;;; ---- swank protocol bridging ----
;;;;
;;;; Both index-query.lisp (callers of swank:xrefs) and handlers.lisp
;;;; (callers of swank:documentation-symbol, swank:operator-arglist,
;;;; etc.) need to bind swank's *buffer-package* / *buffer-readtable*
;;;; before calling those entry points -- swank assumes them present
;;;; under EVAL-FOR-EMACS but not when invoked directly.
;;;;
;;;; The macro lived in handlers.lisp originally; it's moved here so
;;;; index-query.lisp (which loads earlier) can macroexpand it at
;;;; compile time. Same for definition-entry->location-info, the
;;;; swank :location plist → LSP Location converter that both files
;;;; share.

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

(defun definition-entry->location-info (loc pkg)
  "Convert a swank :location plist to (URI START-LINE START-CHAR
END-LINE END-CHAR), or NIL if the location is not file-based.

Position math: swank's :position is 1-based for emacs convention;
convert to 0-based char offset in the file. End range derives from
the (string-trimmed) snippet length when present, else equals the
start (LSP allows zero-width ranges)."
  (declare (ignore pkg))
  (when (and (consp loc) (eq (first loc) :location))
    (let* ((file-form (assoc :file (rest loc)))
           (pos-form  (assoc :position (rest loc)))
           (snippet-form (assoc :snippet (rest loc))))
      (when (and file-form pos-form)
        (let* ((path (second file-form))
               (one-based (second pos-form))
               (snippet (and snippet-form (second snippet-form)))
               (uri (path->file-uri path))
               (file-text (handler-case (read-file-as-string path)
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
                  (list uri sl sc el ec))))))))))
