(in-package #:swank-lsp/tests)

;;;; Unit tests for the source-walking layer: BINDER-INFO-AT,
;;;; ENCLOSING-LEXICALS, LOCAL-DECLARES-FOR. End-to-end with
;;;; COMPILE-DERIVED-TYPE-OF on the user's headline `hi` case so we
;;;; have a regression guard for the full pipeline before hover
;;;; wiring lands in commit 3.

(in-suite derived-type-suite)

(defun open-doc (text)
  "Build and store a DOCUMENT for TEXT, return it. Each test gets a
unique URI so the global store doesn't leak between tests."
  (let* ((uri (format nil "file:///tmp/binder-context-~A.lisp"
                      (random 1000000)))
         (doc (swank-lsp::make-document :uri uri :text text :version 1)))
    (swank-lsp::store-document doc)
    doc))

(defun binder-at (text needle &key (start 0))
  "Open a doc with TEXT, find NEEDLE (a substring) at or after START,
return the BINDER-INFO at that offset (or NIL)."
  (let* ((doc (open-doc text))
         (offset (search needle text :start2 start)))
    (when offset
      (swank-lsp::binder-info-at doc offset))))

(test binder-info-at-let
  (let ((bi (binder-at "(defun frob (line-starts)
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (list lo hi)))" "hi" :start 30)))
    (is (not (null bi)))
    (is (eq 'hi (swank-lsp::binder-info-name bi)))
    (is (eq :let (swank-lsp::binder-info-kind bi)))
    (is (equal '(1- (length line-starts))
               (swank-lsp::binder-info-init-form bi)))))

(test binder-info-at-let*-includes-prior-binders
  (let ((bi (binder-at "(defun g (xs)
  (let* ((n (length xs))
         (m (1+ n)))
    m))" "m" :start 30)))
    (is (eq :let* (swank-lsp::binder-info-kind bi)))
    (is (equal '(1+ n) (swank-lsp::binder-info-init-form bi)))
    ;; ENCLOSING-LEXICALS for `m` in let* must include the earlier
    ;; binder N as well as the surrounding defun param XS.
    (let ((enclosing (swank-lsp::enclosing-lexicals bi)))
      (is (member 'xs enclosing) "expected XS in ~S" enclosing)
      (is (member 'n  enclosing) "expected N in ~S"  enclosing))))

(test binder-info-at-defun-param-with-declare
  (let ((bi (binder-at "(defun double (x)
  (declare (fixnum x))
  (* 2 x))" "x")))
    (is (eq :defun-param (swank-lsp::binder-info-kind bi)))
    (is (null (swank-lsp::binder-info-init-form bi)))
    (let ((decls (swank-lsp::local-declares-for bi (list 'x))))
      (is (equal '((type fixnum x)) decls)
          "expected canonicalised TYPE form; got ~S" decls))))

(test binder-info-at-lambda-param
  (let ((bi (binder-at "(mapcar (lambda (s) (length s)) '(\"a\" \"bb\"))" "s")))
    (is (eq :lambda-param (swank-lsp::binder-info-kind bi)))))

(test binder-info-at-non-binder-returns-nil
  ;; Cursor on a function-position symbol -- not a binder.
  (is (null (binder-at "(defun foo () (list a b))" "list"))))

(test compile-derived-type-of-end-to-end-on-hi
  ;; The user's exact example. Wires binder-context and the SBCL
  ;; backend together end-to-end, asserting the result is integer-shaped.
  (let* ((bi (binder-at "(defun frob (line-starts)
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (list lo hi)))" "hi" :start 30))
         (free (swank-lsp::enclosing-lexicals bi))
         (declares (swank-lsp::local-declares-for
                    bi (cons (swank-lsp::binder-info-name bi) free)))
         (type (swank-lsp::compile-derived-type-of
                (swank-lsp::binder-info-init-form bi)
                free declares)))
    (is (subtype-of-p type 'integer)
        "(1- (length line-starts)) should be integer-shaped; got ~S" type)))
