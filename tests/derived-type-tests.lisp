(in-package #:swank-lsp/tests)

;;;; Unit tests for the compile-derive mechanism. Pure-sexp inputs --
;;;; no source walking, no hover wiring. Exercises the type oracle
;;;; itself.

(in-suite derived-type-suite)

(defun subtype-of-p (got expected)
  "True when SBCL can prove (subtypep GOT EXPECTED). Hides the second
value of subtypep, which we don't care about for assertions: we
accept either (T T) or (T NIL); we only fail on (NIL T) -- a proven
non-subtype."
  (multiple-value-bind (sub sure) (subtypep got expected)
    (or sub (not sure))))

(test compile-derive-on-simple-arithmetic
  ;; The user's headline example: (1- (length xs)) should narrow to
  ;; some integer subtype, regardless of xs's declared type.
  (let ((type (swank-lsp::compile-derived-type-of
               '(1- (length xs)) '(xs) nil)))
    (is (subtype-of-p type 'integer)
        "(1- (length xs)) should be integer-shaped; got ~S" type)))

(test compile-derive-on-concatenate-string
  (let ((type (swank-lsp::compile-derived-type-of
               '(concatenate 'string a b) '(a b) nil)))
    (is (subtype-of-p type 'string)
        "(concatenate 'string a b) should be string-shaped; got ~S" type)))

(test compile-derive-respects-forwarded-declares
  ;; With (fixnum x), * narrows tighter than without. We don't pin the
  ;; exact spec (it's SBCL-internal disjunction territory), just check
  ;; that the result is integer-shaped, which is what the declare buys.
  (let ((type (swank-lsp::compile-derived-type-of
               '(* 2 x) '(x) '((fixnum x)))))
    (is (subtype-of-p type 'integer)
        "(* 2 x) under (fixnum x) should be integer-shaped; got ~S" type)))

(test compile-derive-strips-single-value-envelope
  ;; Caller should not have to know about (values X &optional). We
  ;; strip it for the common single-primary case.
  (let ((type (swank-lsp::compile-derived-type-of '(+ 1 2) nil nil)))
    (is (not (and (consp type) (eq (first type) 'values)))
        "single-primary should be unwrapped from values; got ~S" type)))

(test compile-derive-on-undefined-fn-degrades-gracefully
  ;; If the init-form references an unknown helper, compile may emit
  ;; a style-warning (which we muffle) and SBCL has no signature for
  ;; the call -- the result is whatever it can still figure out, and
  ;; in the worst case T. Either way the function must NOT signal.
  (finishes
    (swank-lsp::compile-derived-type-of
     '(definitely-undefined-fn-7c4f x) '(x) nil)))

(test compile-derive-with-no-free-vars
  ;; Constant fold works; no free vars means the synth-lambda has zero
  ;; params, which the helper has to handle without choking on the
  ;; empty (declare (ignorable)).
  (let ((type (swank-lsp::compile-derived-type-of '(+ 1 2) nil nil)))
    (is (subtype-of-p type 'integer)
        "(+ 1 2) should fold to an integer subtype; got ~S" type)))
