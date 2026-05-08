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

(defvar *ftype-backend* nil
  "Function of (SYMBOL) returning the function's stored ftype list, or
NIL if unavailable. Used to plumb proclaimed parameter types into
hover when the source doesn't carry an in-body declare.")

(defvar *lambda-list-backend* nil
  "Function of (SYMBOL) returning the function's lambda list, or NIL.
Pairs with *FTYPE-BACKEND*: ftype gives types in lambda-list order;
the lambda list lets us map a parameter NAME to its position.")

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

(defun function-ftype (symbol)
  "Backend-delegated lookup of SYMBOL's stored ftype, or NIL."
  (and *ftype-backend* (funcall *ftype-backend* symbol)))

(defun function-lambda-list (symbol)
  "Backend-delegated lookup of SYMBOL's lambda list, or NIL."
  (and *lambda-list-backend* (funcall *lambda-list-backend* symbol)))

(defun param-type-from-ftype (fn-symbol param-name)
  "Locate PARAM-NAME in FN-SYMBOL's lambda list, then read the
matching argument type out of FN-SYMBOL's ftype. Returns the type
spec, or NIL if anything is missing or ambiguous (no ftype, no
lambda list, name not found, &rest/&aux).

The lambda list and ftype are read from the running image (via the
registered backend), which means this only pays off after the user
has compiled the surrounding defun. That trade -- staleness for not
re-walking source -- is intentional; same model as docstrings."
  (let ((ll  (function-lambda-list fn-symbol))
        (ft  (function-ftype       fn-symbol)))
    (when (and ll ft (consp ft) (eq (first ft) 'function))
      (let ((arglist (second ft)))
        (when (consp arglist)
          (param-type-from-arglist ll arglist param-name))))))

(defun param-type-from-arglist (lambda-list ftype-arglist param-name)
  "Walk LAMBDA-LIST and FTYPE-ARGLIST in lockstep across the section
boundaries (required, &optional, &rest, &key) to find the type
corresponding to PARAM-NAME. Returns the type spec, or NIL when not
found or unsupported.

Symbol comparison is by SYMBOL-NAME, not EQ: the lambda list comes
from the loaded image (function's home package, e.g. SWANK-LSP) but
the caller's PARAM-NAME comes from a separate read of source by
cl-scope-resolver and lives in some other package."
  (let ((target (symbol-name param-name))
        (ll-section :required)
        (ll lambda-list)
        (ft-section :required)
        (ft ftype-arglist))
    (flet ((advance-ll-section ()
             (loop while (and ll (member (first ll) lambda-list-keywords))
                   do (setf ll-section (first ll))
                      (setf ll (rest ll))))
           (advance-ft-section ()
             (loop while (and ft (member (first ft) lambda-list-keywords))
                   do (setf ft-section (first ft))
                      (setf ft (rest ft))))
           (name-matches-p (sym)
             (and (symbolp sym) (string= (symbol-name sym) target))))
      (advance-ll-section)
      (advance-ft-section)
      (loop
        (when (or (null ll) (null ft)) (return nil))
        (case ll-section
          ((:required &optional)
           (when (name-matches-p (param-name-of (first ll)))
             (return (param-type-of (first ft))))
           (setf ll (rest ll) ft (rest ft)))
          (&key
           (when (name-matches-p (param-name-of (first ll)))
             (let* ((ll-kw  (param-keyword-of (first ll)))
                    (kw-name (and ll-kw (symbol-name ll-kw)))
                    (entry (find kw-name ft
                                 :key (lambda (e)
                                        (and (consp e) (symbolp (first e))
                                             (symbol-name (first e))))
                                 :test #'string=)))
               (return (and entry (second entry)))))
           (setf ll (rest ll)))
          (t (return nil)))
        (advance-ll-section)
        (advance-ft-section)))))

(defun param-name-of (ll-entry)
  "Lambda-list entry -> bound symbol. Handles NAME, (NAME default),
(NAME default supplied-p), and the &key forms (NAME ...) and
((:KW VAR) ...)."
  (cond
    ((symbolp ll-entry) ll-entry)
    ((and (consp ll-entry) (consp (first ll-entry)))
     (second (first ll-entry)))                      ; ((:kw var) ...)
    ((consp ll-entry) (first ll-entry))
    (t nil)))

(defun param-keyword-of (ll-entry)
  "&key entry -> the keyword symbol used at the call site."
  (cond
    ((symbolp ll-entry)
     (intern (symbol-name ll-entry) :keyword))
    ((and (consp ll-entry) (consp (first ll-entry)))
     (first (first ll-entry)))                       ; ((:kw var) ...)
    ((consp ll-entry)
     (intern (symbol-name (first ll-entry)) :keyword))
    (t nil)))

(defun param-type-of (ft-entry)
  "FType arglist entries are bare types in :required and &optional
sections, so this is identity for those. Kept as a seam for any
future quirks (e.g. backends that emit (TYPE DEFAULT) shapes)."
  ft-entry)

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
  "Strip the (VALUES …) envelope to its first primary type when a
single-name binding can only see the primary value. Cases handled:
  (values X &optional)              -> X
  (values X &rest T)                -> X
  (values X Y … &optional)          -> X    (multi-value: bind only sees primary)
  (values X Y … &rest T)            -> X
Otherwise pass the whole values form through. The 'binding to a
single name only sees the primary' rule mirrors how let/let*
binding pairs evaluate their init-form -- consistent with hover's
caller, which is asking for the type of one bound name."
  (let ((tail (rest values-form)))
    (cond
      ((null tail) values-form)                         ; (values) -- weird; preserve
      ((member (first tail) '(&optional &rest))         ; (values &optional ...) -- preserve
       values-form)
      ;; Single primary, then &optional or &rest T closes it out.
      ((let ((after (member-if (lambda (x) (member x '(&optional &rest))) tail)))
         (or (null after)                               ; (values X) -- preserve as (values X)
             (and (eq (first after) '&optional))
             (and (eq (first after) '&rest)
                  (or (null (rest after))
                      (eq (second after) t)))))
       (first tail))
      (t values-form))))
