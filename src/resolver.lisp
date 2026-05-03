(in-package #:cl-scope-resolver)

;;;; The resolver: given a source string and a character offset pointing
;;;; at a symbol, return either the source range of its lexical binder
;;;; (:local) or a sentinel meaning "ask elsewhere" (:foreign).
;;;;
;;;; Skeleton form. Real implementation lands in a later commit, after
;;;; REPL exploration of eclector + walker has settled the bridge policy.

(defconstant +local+ :local
  "Primary value of RESOLVE when the symbol at OFFSET is a lexical reference and we found its binder in the same source string.")

(defconstant +foreign+ :foreign
  "Primary value of RESOLVE when the symbol at OFFSET is not a resolvable local: free variable, global function, special variable, macro-introduced binding, or a case the resolver punts on. Caller (typically Phase 2 LSP layer) should fall through to swank.")

(defun resolve (source-string offset)
  "Resolve the symbol at character OFFSET in SOURCE-STRING.

Returns four values:
  KIND   -- :LOCAL or :FOREIGN
  START  -- character offset of binder (when KIND is :LOCAL), else NIL
  END    -- character offset just past binder (when :LOCAL), else NIL
  REASON -- keyword describing why we returned this answer (always present)

Pure function. No IO, no global mutation, no EVAL."
  ;; Skeleton: real implementation lands in the bridge commit.
  (declare (ignore source-string offset))
  (values +foreign+ nil nil :not-implemented))
