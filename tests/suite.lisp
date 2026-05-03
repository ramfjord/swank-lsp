(in-package #:swank-lsp/tests)

;;;; Aggregate runner. Fiveam's `run!` works on a *symbol* — either
;;;; a single test or a suite. We define ALL-TESTS as the umbrella
;;;; suite that contains the three child suites, so `(run! 'all-tests)`
;;;; runs everything.

(def-suite all-tests :description "All swank-lsp tests (umbrella).")

;; Re-parent each child suite under all-tests. Fiveam stores parent on
;; the suite object's `in` slot; the simplest portable way is to
;; explicitly re-define each suite naming all-tests as their parent.

(def-suite position-suite :in all-tests
  :description "LSP <-> char offset conversion.")

(def-suite document-suite :in all-tests
  :description "Document store and text helpers.")

(def-suite wire-suite :in all-tests
  :description "End-to-end LSP wire tests.")

(def-suite local-definition-suite :in all-tests
  :description "Local jump-to-def via cl-scope-resolver — wire-level integration.")

(defun run-all ()
  (run! 'all-tests))
