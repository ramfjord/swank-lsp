(in-package #:swank-lsp)

;;;; In-memory document store keyed by URI.
;;;;
;;;; Phase 1 implements full-text didChange (textDocumentSync = 1).
;;;; Each STORE-DOCUMENT replaces the existing entry. Incremental sync
;;;; is a Phase 4 candidate; for typical dev usage on files small
;;;; enough to retype every keystroke, full-text is unproblematic.

(defstruct (document (:conc-name document-))
  uri
  text
  version
  language-id
  ;; Cached line-starts vector — invalidated on text change. Built
  ;; lazily by ENSURE-LINE-STARTS.
  (line-starts nil))

(defvar *document-store* (make-hash-table :test 'equal)
  "URI string → DOCUMENT.")

(defvar *document-store-lock* (bordeaux-threads:make-lock "swank-lsp document store"))

(defun store-document (doc)
  "Insert or replace DOC keyed by its URI."
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (setf (gethash (document-uri doc) *document-store*) doc)))

(defun lookup-document (uri)
  "Return the DOCUMENT for URI, or NIL."
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (gethash uri *document-store*)))

(defun remove-document (uri)
  "Remove the DOCUMENT for URI from the store. Returns T if it existed."
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (let ((existed (gethash uri *document-store*)))
      (remhash uri *document-store*)
      (and existed t))))

(defun document-count ()
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (hash-table-count *document-store*)))

(defun reset-document-store ()
  "Clear the document store. For tests."
  (bordeaux-threads:with-lock-held (*document-store-lock*)
    (clrhash *document-store*)))

(defun get-document (uri &key error-on-missing)
  "Public accessor — looks up by URI. With ERROR-ON-MISSING, signals
SIMPLE-ERROR if not found. Otherwise returns NIL."
  (or (lookup-document uri)
      (and error-on-missing
           (error "No document tracked for URI ~A" uri))))

(defun ensure-line-starts (doc)
  "Build the line-starts vector for DOC on demand. Cached on DOC."
  (or (document-line-starts doc)
      (setf (document-line-starts doc)
            (compute-line-starts (document-text doc)))))

;;;; Heuristics over document text — used by handlers to extract a
;;;; symbol or completion prefix at a given character offset.

(defun symbol-char-p (c)
  "Conservative \"part of a Lisp symbol name\" predicate. Includes
characters commonly appearing in CL package-qualified symbols. Excludes
whitespace, parens, quote/quasiquote, comma, semicolon (comment),
backslash, and double-quote."
  (and (characterp c)
       (not (member c '(#\Space #\Tab #\Newline #\Return
                        #\( #\) #\' #\` #\, #\; #\\ #\")
                    :test #'char=))))

(defun extract-symbol-at (text offset)
  "Return (VALUES SYMBOL-NAME START END) where SYMBOL-NAME is the
substring of TEXT containing the symbol at OFFSET, START is its
inclusive start offset, END is its exclusive end offset. If the
character at OFFSET is not part of a symbol, returns NIL.
A symbol that ends exactly at OFFSET (cursor-after-name) is still
considered to be \"at\" OFFSET — hover/definition want this."
  (let ((len (length text)))
    (when (zerop len)
      (return-from extract-symbol-at nil))
    (let ((scan-pos (cond
                      ((and (< offset len)
                            (symbol-char-p (char text offset)))
                       offset)
                      ((and (> offset 0)
                            (symbol-char-p (char text (1- offset))))
                       (1- offset))
                      (t (return-from extract-symbol-at nil)))))
      (let ((start scan-pos)
            (end scan-pos))
        (loop while (and (> start 0)
                         (symbol-char-p (char text (1- start))))
              do (decf start))
        (loop while (and (< end len)
                         (symbol-char-p (char text end)))
              do (incf end))
        (if (= start end)
            nil
            (values (subseq text start end) start end))))))

(defun extract-prefix-at (text offset)
  "For completion: return the substring of TEXT immediately before
OFFSET that looks like a partial symbol. May be empty. Always returns
a string and the start offset of the prefix."
  (let ((start offset))
    (loop while (and (> start 0)
                     (symbol-char-p (char text (1- start))))
          do (decf start))
    (values (subseq text start offset) start)))

;;;; Default package selection
;;;;
;;;; When swank takes a "package name" argument, we want to give it
;;;; something sensible. Phase 2 may parse the buffer for an
;;;; (in-package …) form; for Phase 1 we return :CL-USER unless one of
;;;; the document's first ~20 lines has a recognizable in-package form.

(defun current-package-for-document (doc)
  "Best-effort package name for DOC. Returns a string suitable for
swank's PACKAGE arg."
  (let ((text (and doc (document-text doc))))
    (or (and text (parse-in-package text))
        "CL-USER")))

(defun parse-in-package (text)
  "Scan TEXT for the first (in-package …) form near the top. Returns
the package name as a string, or NIL. Conservative: only recognizes
(in-package :NAME) and (in-package #:NAME) and (in-package \"NAME\")."
  (let ((scan-start 0)
        (limit (min (length text) 4096)))
    (loop while (< scan-start limit) do
      (let ((open (position #\( text :start scan-start :end limit)))
        (unless open (return-from parse-in-package nil))
        (let ((after-open (1+ open)))
          (multiple-value-bind (head head-end)
              (read-symbolish text after-open limit)
            (cond
              ((and head (string-equal head "in-package"))
               (let ((arg-start (skip-ws text head-end limit)))
                 (return-from parse-in-package
                   (parse-in-package-arg text arg-start limit))))
              (t (setf scan-start (1+ open))))))))))

(defun skip-ws (text start limit)
  (loop while (and (< start limit)
                   (let ((c (char text start)))
                     (or (char= c #\Space) (char= c #\Tab)
                         (char= c #\Newline) (char= c #\Return))))
        do (incf start))
  start)

(defun read-symbolish (text start limit)
  "Read what looks like a leading symbol name at START. Returns
(VALUES NAME END) or (VALUES NIL START) on failure."
  (let ((p start))
    (loop while (and (< p limit) (symbol-char-p (char text p)))
          do (incf p))
    (if (= p start)
        (values nil start)
        (values (subseq text start p) p))))

(defun parse-in-package-arg (text start limit)
  (when (>= start limit) (return-from parse-in-package-arg nil))
  (let ((c (char text start)))
    (cond
      ((char= c #\:)
       (multiple-value-bind (name end) (read-symbolish text (1+ start) limit)
         (declare (ignore end))
         name))
      ((and (char= c #\#)
            (< (1+ start) limit)
            (char= (char text (1+ start)) #\:))
       (multiple-value-bind (name end) (read-symbolish text (+ start 2) limit)
         (declare (ignore end))
         name))
      ((char= c #\")
       (let ((end (position #\" text :start (1+ start) :end limit)))
         (when end (subseq text (1+ start) end))))
      (t
       (multiple-value-bind (name end) (read-symbolish text start limit)
         (declare (ignore end))
         name)))))
