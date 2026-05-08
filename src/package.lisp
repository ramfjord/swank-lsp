(defpackage #:swank-lsp
  (:use #:cl)
  (:export
   ;; lifecycle
   #:start-server
   #:start-and-publish
   #:stop-server
   #:*server*
   ;; introspection (mostly for tests / debugging)
   #:server-port
   #:server-transport-kind
   #:get-document
   #:document-count
   #:reset-document-store
   ;; embedded-language byte-stream translators (see document.lisp)
   #:*byte-stream-translators*
   #:apply-byte-stream-translator
   ;; position conversions (exported so Phase 2 / tests can call directly)
   #:lsp-position->char-offset
   #:char-offset->lsp-position
   #:compute-line-starts
   #:*server-position-encoding*
   ;; Hover knobs (see src/handlers.lisp)
   #:*hover-content-format*))

;; Internal symbols are reachable as swank-lsp::NAME -- the tests use
;; that form. We deliberately do NOT expose a separate "internal"
;; package; "double colons in tests" is an honest signal that those
;; helpers are not part of the public surface.
