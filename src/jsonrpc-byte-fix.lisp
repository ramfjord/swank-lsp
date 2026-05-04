(in-package #:swank-lsp)

;;;; Monkey-patch for jsonrpc/request-response::read-message.
;;;;
;;;; Bug: jsonrpc reads the body using `(make-string LENGTH)` and
;;;; `read-sequence body stream` -- both character-counted. LSP's
;;;; Content-Length header is in *bytes*, not characters. For ASCII
;;;; bodies these are identical; for any multi-byte UTF-8 in the
;;;; body the reader takes too few bytes from the stream and the
;;;; next message header parses garbage, hanging the read loop.
;;;;
;;;; Original (jsonrpc/request-response.lisp:192-198):
;;;;
;;;;   (defun read-message (stream)
;;;;     (let* ((headers (read-headers stream))
;;;;            (length (ignore-errors
;;;;                     (parse-integer (gethash "content-length" headers)))))
;;;;       (when length
;;;;         (let ((body (make-string length)))
;;;;           (read-sequence body stream)
;;;;           (parse-message body)))))
;;;;
;;;; Fix shape: read characters until their cumulative UTF-8 byte
;;;; width hits LENGTH. Uses the same character stream the upstream
;;;; uses, so no changes to read-headers or to the stream setup are
;;;; needed.
;;;;
;;;; Caveat: this is an internal-symbol monkey-patch. It will silently
;;;; break if upstream renames `read-message` or moves it to a
;;;; different package. Tracked in our README; the proper fix is the
;;;; PR to fukamachi/jsonrpc.

(defun utf8-byte-width (char)
  "How many UTF-8 bytes does CHAR encode to. 1 for ASCII, 2/3/4 for
multi-byte."
  (let ((cc (char-code char)))
    (cond ((< cc #x80)    1)
          ((< cc #x800)   2)
          ((< cc #x10000) 3)
          (t              4))))

(defun byte-correct-read-message (stream)
  "Replacement for jsonrpc/request-response::read-message that
honors Content-Length as bytes, not characters.

Reads the headers via the upstream read-headers (which is fine --
LSP headers are pure ASCII), then reads characters from STREAM and
accumulates them into the body until their UTF-8 byte width totals
LENGTH. Returns the parsed message via the upstream parse-message."
  (let* ((headers (funcall (find-symbol "READ-HEADERS" :jsonrpc/request-response)
                           stream))
         (raw-length (gethash "content-length" headers))
         (length (and raw-length (ignore-errors (parse-integer raw-length)))))
    (when length
      (let ((body (make-string-output-stream))
            (bytes-read 0))
        (loop while (< bytes-read length)
              for c = (read-char stream nil nil)
              do (when (null c)
                   ;; EOF before we got LENGTH bytes; bail with
                   ;; whatever we have. Upstream's behavior on EOF
                   ;; is also to return whatever was read.
                   (return))
                 (write-char c body)
                 (incf bytes-read (utf8-byte-width c)))
        (funcall (find-symbol "PARSE-MESSAGE" :jsonrpc/request-response)
                 (get-output-stream-string body))))))

(defun install-jsonrpc-byte-fix ()
  "Replace jsonrpc/request-response::read-message with our byte-correct
version. Idempotent: re-installing is a no-op (the new function is
already in place). Logs to *error-output* on first install."
  (let* ((sym (find-symbol "READ-MESSAGE" :jsonrpc/request-response))
         (current (and sym (symbol-function sym))))
    (unless (eq current #'byte-correct-read-message)
      (setf (symbol-function sym) #'byte-correct-read-message)
      (format *error-output*
              "~&swank-lsp: installed byte-correct read-message patch ~
               for jsonrpc/request-response~%")
      (force-output *error-output*))))

;; Install at load time. The asd loads this file after :jsonrpc has
;; been pulled in (because :swank-lsp depends on :jsonrpc), so the
;; symbol exists by the time we get here.
(install-jsonrpc-byte-fix)
