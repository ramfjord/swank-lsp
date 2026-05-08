(in-package #:swank-lsp)

;;;; SBCL backend for the compile-derive trick. Loaded only on SBCL
;;;; via :if-feature :sbcl in the .asd; registers itself by setf-ing
;;;; *derive-backend* at load time.
;;;;
;;;; Mechanism: build (lambda (FREE-VARS...) (declare ...) INIT-FORM),
;;;; compile it silently (warnings/notes muffled to a broadcast stream
;;;; -- we don't want to spam the user's REPL with style-warnings
;;;; about their in-flight code), then read the stored ftype back via
;;;; SB-INTROSPECT:FUNCTION-TYPE. The lambda is never called -- COMPILE
;;;; is being used purely as a one-shot type oracle.

(require :sb-introspect)

(defun sbcl-compile-derived-type-of (init-form free-vars declares)
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

(setf *derive-backend* 'sbcl-compile-derived-type-of)

(defun sbcl-function-ftype (symbol)
  (and (fboundp symbol)
       (ignore-errors (sb-introspect:function-type symbol))))

(defun sbcl-function-lambda-list (symbol)
  (and (fboundp symbol)
       (ignore-errors (sb-introspect:function-lambda-list symbol))))

(setf *ftype-backend*        'sbcl-function-ftype)
(setf *lambda-list-backend*  'sbcl-function-lambda-list)
