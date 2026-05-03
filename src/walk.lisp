(in-package #:cl-scope-resolver)

;;;; Walker-side: walk a (raw, post-read) form with hu.dwim.walker and
;;;; expose the AST in whatever shape we end up needing for resolution.
;;;;
;;;; This file is intentionally light at first commit; it grows once
;;;; resolver.lisp tells us what queries we need.

(defun walk-form (form &key (lexenv nil))
  "Walk FORM with hu.dwim.walker and return the AST root.

Errors from the walker propagate; callers catch when appropriate
(see `safely-walk' below)."
  (declare (ignore lexenv))
  ;; hu.dwim.walker:walk-form takes a form and an optional environment;
  ;; the public entry point is WALK-FORM. We pass NIL for the lexical env
  ;; (top-level walk).
  (hu.dwim.walker:walk-form form))

(defun safely-walk (form)
  "Walk FORM, returning (values AST NIL) on success or (values NIL CONDITION)
if the walker signals. Resolution treats walker failure as :foreign."
  (handler-case
      (values (walk-form form) nil)
    (error (c) (values nil c))))
