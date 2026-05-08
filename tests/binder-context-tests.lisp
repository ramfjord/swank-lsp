(in-package #:swank-lsp/tests)

;;;; Integration test: cl-scope-resolver:binder-info-at + the SBCL
;;;; backend's compile-derived-type-of compose end-to-end on the
;;;; user's headline `hi' case. Regression guard for the consumer
;;;; wiring; per-binder-kind unit tests live upstream in
;;;; cl-scope-resolver/tests/binder-context.lisp.

(in-suite derived-type-suite)

(test compile-derived-type-of-end-to-end-on-hi
  (let* ((text "(defun frob (line-starts)
  (let ((lo 0)
        (hi (1- (length line-starts))))
    (list lo hi)))")
         (offset (search "hi" text :start2 30))
         (bi (cl-scope-resolver:binder-info-at text offset))
         (free (cl-scope-resolver:enclosing-lexicals bi))
         (declares (cl-scope-resolver:local-declares-for
                    bi (cons (cl-scope-resolver:binder-info-name bi) free)))
         (type (swank-lsp::compile-derived-type-of
                (cl-scope-resolver:binder-info-init-form bi)
                free declares)))
    (is (subtype-of-p type 'integer)
        "(1- (length line-starts)) should be integer-shaped; got ~S" type)))
