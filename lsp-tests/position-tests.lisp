(in-package #:swank-lsp/tests)

;;;; Unit tests for the position-encoding module.
;;;; These are unit tests (not integration) — the conversion is pure
;;;; and complex enough to deserve focused tests on its own.

(in-suite position-suite)

(defmacro with-encoding ((kw) &body body)
  `(let ((swank-lsp:*server-position-encoding* ,kw))
     ,@body))

(test ascii-single-line
  (let ((s "hello"))
    (with-encoding (:utf-8)
      (is (= 0 (swank-lsp:lsp-position->char-offset s 0 0)))
      (is (= 5 (swank-lsp:lsp-position->char-offset s 0 5)))
      (is (= 5 (swank-lsp:lsp-position->char-offset s 0 99))) ; clamp
      (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s 3)
        (is (= 0 l)) (is (= 3 c))))))

(test multi-line-lf
  (let ((s (format nil "ab~%cd~%ef")))
    (with-encoding (:utf-8)
      (is (= 0 (swank-lsp:lsp-position->char-offset s 0 0)))
      (is (= 3 (swank-lsp:lsp-position->char-offset s 1 0)))
      (is (= 6 (swank-lsp:lsp-position->char-offset s 2 0)))
      (is (= 8 (swank-lsp:lsp-position->char-offset s 2 2)))
      (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s 4)
        (is (= 1 l)) (is (= 1 c))))))

(test multi-line-crlf
  (let ((s (format nil "ab~A~%cd~A~%ef" #\Return #\Return)))
    (with-encoding (:utf-8)
      (is (= 0 (swank-lsp:lsp-position->char-offset s 0 0)))
      ;; Line 1 starts after the CRLF — 4 chars in.
      (is (= 4 (swank-lsp:lsp-position->char-offset s 1 0)))
      ;; CRLF on line 1 → line 2 starts at 8.
      (is (= 8 (swank-lsp:lsp-position->char-offset s 2 0))))))

(test cr-only-line-endings
  (let ((s (format nil "ab~Acd~Aef" #\Return #\Return)))
    ;; Some old Mac files; LSP spec accepts CR alone.
    (with-encoding (:utf-8)
      (is (= 3 (swank-lsp:lsp-position->char-offset s 1 0)))
      (is (= 6 (swank-lsp:lsp-position->char-offset s 2 0))))))

(test em-dash-utf8
  ;; em-dash is 3 bytes in UTF-8.
  (let ((s (concatenate 'string "a" (string (code-char #x2014)) "b")))
    (with-encoding (:utf-8)
      ;; UTF-8 col 0 → char 0, col 1 → char 1 (a), col 4 (after em-dash 3 bytes) → char 2
      (is (= 0 (swank-lsp:lsp-position->char-offset s 0 0)))
      (is (= 1 (swank-lsp:lsp-position->char-offset s 0 1)))
      (is (= 2 (swank-lsp:lsp-position->char-offset s 0 4)))
      (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s 2)
        (is (= 0 l))
        (is (= 4 c))))))

(test em-dash-utf16
  ;; em-dash is BMP, so 1 utf-16 unit.
  (let ((s (concatenate 'string "a" (string (code-char #x2014)) "b")))
    (with-encoding (:utf-16)
      (is (= 1 (swank-lsp:lsp-position->char-offset s 0 1)))
      (is (= 2 (swank-lsp:lsp-position->char-offset s 0 2)))
      (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s 2)
        (is (= 0 l)) (is (= 2 c))))))

(test supplementary-plane-utf16-surrogate-pair
  ;; U+1F600 (grinning face) — supplementary plane → 2 utf-16 units, 4 utf-8 bytes.
  (let ((s (concatenate 'string "x" (string (code-char #x1F600)) "y")))
    (with-encoding (:utf-16)
      (is (= 1 (swank-lsp:lsp-position->char-offset s 0 1)))
      ;; col 3 (1 for x + 2 surrogates) → past the emoji = char 2
      (is (= 2 (swank-lsp:lsp-position->char-offset s 0 3)))
      (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s 2)
        (is (= 0 l)) (is (= 3 c))))
    (with-encoding (:utf-8)
      ;; col 5 (1 + 4) → char 2
      (is (= 2 (swank-lsp:lsp-position->char-offset s 0 5))))
    (with-encoding (:utf-32)
      (is (= 1 (swank-lsp:lsp-position->char-offset s 0 1)))
      (is (= 2 (swank-lsp:lsp-position->char-offset s 0 2))))))

(test round-trip-various
  (dolist (encoding '(:utf-8 :utf-16 :utf-32))
    (with-encoding (encoding)
      (let ((s (format nil "α~%~A~%~A" (code-char #x1F600) "ascii")))
        (loop for off from 0 below (length s) do
          (multiple-value-bind (l c) (swank-lsp:char-offset->lsp-position s off)
            (is (= off (swank-lsp:lsp-position->char-offset s l c))
                "round-trip failed for encoding=~A offset=~A line=~A char=~A"
                encoding off l c)))))))

(test negotiate-position-encoding
  (is (eq :utf-8  (swank-lsp::negotiate-position-encoding '("utf-8" "utf-16"))))
  (is (eq :utf-16 (swank-lsp::negotiate-position-encoding '("utf-16"))))
  (is (eq :utf-16 (swank-lsp::negotiate-position-encoding nil)))
  (is (eq :utf-32 (swank-lsp::negotiate-position-encoding '("utf-32" "utf-16"))))
  (is (eq :utf-8  (swank-lsp::negotiate-position-encoding '("utf-8" "utf-32"))))
  (is (eq :utf-16 (swank-lsp::negotiate-position-encoding '("foo")))))
