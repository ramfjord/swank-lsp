(in-package #:swank-lsp)

;;;; Implementation-agnostic core for expression type derivation.
;;;;
;;;; The "compile-derive trick" -- build a throwaway lambda whose body
;;;; is the expression to type, compile it, and read the compiler's
;;;; stored ftype back -- is portable in spirit, but the introspection
;;;; call (`sb-introspect:function-type` on SBCL, `ccl:function-type`
;;;; on CCL, etc.) is impl-specific. Same story for the simplifier:
;;;; cleaning up bound-int / array-tag noise is impl-specific because
;;;; the noise is.
;;;;
;;;; This file holds:
;;;;   - the registry vars
;;;;   - the public entry points that delegate to whatever backend
;;;;     registered itself at load time
;;;;   - extract-return-type, which is pure CL (operates on the
;;;;     standard (function (...) (values ...)) shape) and so lives
;;;;     here rather than per-impl
;;;;
;;;; SBCL backend: src/derived-type-sbcl.lisp.
;;;; A future CCL backend would drop in src/derived-type-ccl.lisp
;;;; with :if-feature :ccl and register the same way; no changes
;;;; here, no changes in handlers.lisp.

(defvar *derive-backend* nil
  "Function of (INIT-FORM FREE-VARS DECLARES) returning a type spec
or NIL. NIL when no impl has registered -- COMPILE-DERIVED-TYPE-OF
then returns NIL and callers degrade gracefully.")

(defvar *simplify-backend* nil
  "Function of (TYPE-SPEC) returning a type spec. NIL means pass
through unchanged -- not every impl needs a simplifier (others may
emit cleaner derived types in the first place).")

(defun compile-derived-type-of (init-form free-vars &optional declares)
  "Return the compiler-derived type of INIT-FORM, evaluated under
FREE-VARS (treated as T-typed unless overridden by DECLARES).
DECLARES is a list of declaration specs forwarded into the synthetic
lambda's body, e.g. '((fixnum x) (type list ys)). Returns the
single-value primary stripped from any (values X &optional) envelope.
Returns NIL if no backend is registered or if the backend signaled."
  (and *derive-backend*
       (funcall *derive-backend* init-form free-vars declares)))

(defun simplify-type (type-spec)
  "Run TYPE-SPEC through the registered simplifier, if any."
  (if *simplify-backend*
      (funcall *simplify-backend* type-spec)
      type-spec))

(defun extract-return-type (ftype)
  "Pull the return type out of a `(function (...) RETURN)' ftype.
When RETURN is a `(values PRIMARY &optional)' or `(values PRIMARY
&rest T)' shape -- both ways a CL ftype spells \"single primary, rest
of the values list unconstrained\" -- strip to PRIMARY. Otherwise
return RETURN as-is (preserves multi-value shapes for callers that
care).

Pure CL: operates on the standard ftype shape. Backends call it
after their introspection step."
  (when (and (consp ftype) (eq (first ftype) 'function))
    (let ((return-spec (third ftype)))
      (if (and (consp return-spec) (eq (first return-spec) 'values))
          (single-primary-or-values return-spec)
          return-spec))))

(defun single-primary-or-values (values-form)
  (let ((tail (rest values-form)))
    (cond
      ((and (consp tail)
            (consp (rest tail))
            (eq (second tail) '&optional)
            (null (cddr tail)))
       (first tail))
      ((and (consp tail)
            (consp (rest tail))
            (eq (second tail) '&rest)
            (or (null (cddr tail))
                (and (eq (third tail) t) (null (cdddr tail)))))
       (first tail))
      (t values-form))))
