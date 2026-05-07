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
