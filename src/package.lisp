(defpackage #:cl-scope-resolver
  (:use #:cl)
  (:export
   ;; Public API
   #:resolve
   ;; Resolution kinds (returned as primary value of RESOLVE)
   #:+local+
   #:+foreign+
   ;; Internal-but-exported helpers, useful for tests and Phase 2 diagnostics
   #:cst-from-string
   #:cst-source-range
   #:cst-at-offset))
