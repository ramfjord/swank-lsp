(in-package #:swank-lsp)

;;;; Position encoding for LSP.
;;;;
;;;; LSP Position is { line, character } where `line` is 0-based and
;;;; `character` is a 0-based code-unit offset within that line. The
;;;; "code unit" depends on the negotiated `positionEncoding`:
;;;;
;;;;   - "utf-16" (default; what every LSP client falls back to)
;;;;   - "utf-8"  (LSP 3.17+; advertised via general.positionEncodings)
;;;;   - "utf-32" (LSP 3.17+; same as character offset; rarely used)
;;;;
;;;; This module owns the round-trip between LSP positions and
;;;; character offsets within a string. Phase 2 / handlers always work
;;;; in character offsets internally; only the wire boundary speaks
;;;; LSP positions.
;;;;
;;;; Line breaks: LSP says any of \n, \r\n, \r are line terminators.
;;;; We treat \r\n as one terminator and \r-without-\n as one. Most
;;;; editors send \n.

(defvar *server-position-encoding* :utf-16
  "Negotiated position encoding for the running server. Set during
`initialize` based on the client's general.positionEncodings list.
One of :utf-8, :utf-16, :utf-32.")

;;;; Encoding selection

(defun negotiate-position-encoding (client-encodings)
  "Given the client's offered list of position encoding strings (or
NIL), return the keyword for the encoding the server should use.
Prefer UTF-8 (matches Lisp's char model) when available, otherwise
UTF-16 (LSP default), otherwise UTF-32."
  (let ((set (and client-encodings
                  (mapcar (lambda (s) (string-downcase (string s)))
                          (coerce client-encodings 'list)))))
    (cond
      ((member "utf-8"  set :test #'string=) :utf-8)
      ((member "utf-32" set :test #'string=) :utf-32)
      ;; If the client explicitly only offers utf-16 or doesn't negotiate
      ;; at all, fall back to utf-16 (LSP default).
      (t :utf-16))))

(defun position-encoding-name (kw)
  (ecase kw
    (:utf-8  "utf-8")
    (:utf-16 "utf-16")
    (:utf-32 "utf-32")))

;;;; Line-start cache

(defun compute-line-starts (text)
  "Return a vector of character offsets where each line starts.
Element 0 is always 0. The line containing offset N is the largest
index whose value is <= N. Line breaks recognized: \\r\\n, \\n, \\r."
  (let ((starts (make-array 32 :element-type 'fixnum
                            :adjustable t :fill-pointer 1
                            :initial-element 0))
        (len (length text))
        (i 0))
    (setf (aref starts 0) 0)
    ;; STARTS already has element 0 = 0 due to the fill-pointer init above.
    (loop while (< i len) do
      (let ((c (char text i)))
        (cond
          ((char= c #\Return)
           (incf i)
           (when (and (< i len) (char= (char text i) #\Newline))
             (incf i))
           (vector-push-extend i starts))
          ((char= c #\Newline)
           (incf i)
           (vector-push-extend i starts))
          (t
           (incf i)))))
    starts))

;;;; UTF-16 / UTF-8 width of a single Lisp character

(declaim (inline utf16-units utf8-units))

(defun utf16-units (char)
  "How many UTF-16 code units does CHAR occupy? 1 for BMP (<= #xFFFF),
2 for supplementary plane (surrogate pair)."
  (if (> (char-code char) #xFFFF) 2 1))

(defun utf8-units (char)
  "How many UTF-8 bytes does CHAR occupy?"
  (let ((cc (char-code char)))
    (cond ((< cc #x80)     1)
          ((< cc #x800)    2)
          ((< cc #x10000)  3)
          (t               4))))

(defun char-units (char encoding)
  (ecase encoding
    (:utf-8  (utf8-units  char))
    (:utf-16 (utf16-units char))
    (:utf-32 1)))

;;;; LSP position <-> char offset

(defun lsp-position->char-offset (text line lsp-character
                                  &key (encoding *server-position-encoding*)
                                       (line-starts nil))
  "Convert an LSP Position { line, character } to a 0-based character
offset within TEXT. ENCODING is :utf-8, :utf-16, or :utf-32.
LINE-STARTS may be precomputed; otherwise computed on demand.
If LINE is past the last line, clamps to end of text. If LSP-CHARACTER
exceeds the line's length in code units, clamps to the line end."
  (let* ((starts (or line-starts (compute-line-starts text)))
         (n-lines (length starts))
         (text-len (length text))
         (line (max 0 line)))
    (when (>= line n-lines)
      (return-from lsp-position->char-offset text-len))
    (let* ((line-start (aref starts line))
           (line-end (if (< (1+ line) n-lines)
                         (line-end-without-terminator text (aref starts (1+ line)))
                         text-len))
           (units 0)
           (offset line-start))
      (loop while (and (< offset line-end) (< units lsp-character)) do
        (let ((w (char-units (char text offset) encoding)))
          (incf units w)
          (incf offset 1)))
      ;; If the requested code-unit offset lands inside a multi-unit
      ;; character, the loop will have consumed past it. That's the LSP
      ;; spec's expected behavior -- round to the next character.
      offset)))

(defun line-end-without-terminator (text next-line-start)
  "Given the start offset of the *next* line, return the offset of the
end of the previous line *excluding* its terminator."
  (let ((p next-line-start))
    (when (and (> p 0) (char= (char text (1- p)) #\Newline))
      (decf p)
      (when (and (> p 0) (char= (char text (1- p)) #\Return))
        (decf p)))
    (when (and (> p 0)
               (= p next-line-start)  ; only \r case
               (char= (char text (1- p)) #\Return))
      (decf p))
    p))

(defun char-offset->lsp-position (text char-offset
                                  &key (encoding *server-position-encoding*)
                                       (line-starts nil))
  "Inverse of LSP-POSITION->CHAR-OFFSET. Returns (VALUES LINE
LSP-CHARACTER). If CHAR-OFFSET is beyond the text, clamps to end."
  (let* ((starts (or line-starts (compute-line-starts text)))
         (text-len (length text))
         (off (max 0 (min char-offset text-len)))
         ;; Binary-search for largest line-start <= off.
         (line (line-of-offset starts off))
         (line-start (aref starts line))
         (units 0))
    (loop for i from line-start below off do
      (incf units (char-units (char text i) encoding)))
    (values line units)))

(defun line-of-offset (line-starts offset)
  "Largest index in LINE-STARTS whose value is <= OFFSET. Binary search."
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (loop while (< lo hi) do
      (let ((mid (ceiling (+ lo hi) 2)))
        (if (<= (aref line-starts mid) offset)
            (setf lo mid)
            (setf hi (1- mid)))))
    lo))

;;;; LSP Range helpers (used by handlers)

(defun make-lsp-position (line character)
  "Construct a hash-table representing an LSP Position object."
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "line" h) line
          (gethash "character" h) character)
    h))

(defun make-lsp-range (start-line start-char end-line end-char)
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "start" h) (make-lsp-position start-line start-char)
          (gethash "end"   h) (make-lsp-position end-line   end-char))
    h))

(defun char-range->lsp-range (text start-offset end-offset
                              &key (encoding *server-position-encoding*)
                                   (line-starts nil))
  (let ((starts (or line-starts (compute-line-starts text))))
    (multiple-value-bind (sl sc)
        (char-offset->lsp-position text start-offset
                                   :encoding encoding :line-starts starts)
      (multiple-value-bind (el ec)
          (char-offset->lsp-position text end-offset
                                     :encoding encoding :line-starts starts)
        (make-lsp-range sl sc el ec)))))
