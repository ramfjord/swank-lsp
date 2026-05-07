(in-package #:swank-lsp)

;;;; Derive the type of an expression by compiling a throwaway lambda
;;;; whose body is that expression, then reading SBCL's stored ftype
;;;; back via SB-INTROSPECT:FUNCTION-TYPE. The lambda is never called;
;;;; we use COMPILE only as a one-shot type oracle.
;;;;
;;;; Loaded only on SBCL via :if-feature in the .asd. Other
;;;; implementations have similar machinery (CCL has CCL::FUNCTION-TYPE)
;;;; but the wiring is impl-specific and out of scope for v1.
;;;;
;;;; This file ships only the mechanism. Source-walking (find a binder
;;;; at a cursor, extract its init-form) and hover integration are
;;;; separate commits.

(require :sb-introspect)

(defun compile-derived-type-of (init-form free-vars &optional declares)
  "Return the SBCL-derived type of INIT-FORM evaluated under
FREE-VARS (treated as T-typed unless declared) and DECLARES (a list
of declaration specs forwarded into the synthetic lambda's body, e.g.
'((fixnum x) (type list ys))). Returns the values type with the
single-value envelope stripped (so '(values X &optional)' becomes
'X'). Returns NIL if compilation fails for any reason -- the feature
must degrade gracefully on undefined helpers, broken init-forms, etc.

The compile is silent: warnings and notes are routed through a
broadcast stream to nowhere, so eval'ing this from a swank session
doesn't pollute the REPL with style-warnings about ignored params or
unknown functions in the user's in-flight code."
  (let* ((lambda-form
           `(lambda ,free-vars
              (declare (ignorable ,@free-vars))
              ,@(when declares `((declare ,@declares)))
              ,init-form))
         (fn (handler-case
                 (let ((*error-output* (make-broadcast-stream))
                       (*standard-output* (make-broadcast-stream)))
                   (handler-bind ((warning #'muffle-warning))
                     (compile nil lambda-form)))
               (error () nil))))
    (when fn
      (let ((ftype (ignore-errors (sb-introspect:function-type fn))))
        (and ftype (extract-return-type ftype))))))

(defun extract-return-type (ftype)
  "Pull the return type out of a `(function (...) RETURN)' ftype.
When RETURN is a `(values PRIMARY &optional)' or `(values PRIMARY
&rest T)' shape -- both ways SBCL spells \"single primary, rest of
the values list unconstrained\" -- strip to PRIMARY. Otherwise
return RETURN as-is, which preserves multi-value shapes like
`(values X Y &optional)' for callers that care."
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
