(in-package #:cl-scope-resolver)

;;;; CST-side: read source text into eclector concrete-syntax-tree nodes
;;;; carrying source positions, and locate the leaf node enclosing a given
;;;; character offset.
;;;;
;;;; This file is a thin wrapper around eclector-concrete-syntax-tree. We
;;;; deliberately do not assume any structure beyond what the public API
;;;; gives us; readers should consult eclector docs (or `(describe ...)`
;;;; in the REPL) before assuming what slots exist.

(defun cst-from-string (source-string &key (start 0) (end nil))
  "Read every top-level form in SOURCE-STRING, returning a list of CST nodes.

Each node carries source-position metadata: a `(start . end)` cons of
**character positions** (0-based, end-exclusive — i.e. half-open
intervals matching Lisp's standard subseq convention). Eclector counts
character reads; UTF-16 / byte-offset translation is the LSP layer's
problem, not ours.

Forms before :START or after :END are not read.

Returns NIL if SOURCE-STRING contains no readable forms in the range."
  (let ((eclector.base:*client*
          (make-instance 'eclector.concrete-syntax-tree:cst-client))
        (results '()))
    (with-input-from-string (stream source-string :start start :end end)
      (loop for form = (eclector.concrete-syntax-tree:read stream nil :eof)
            until (eq form :eof)
            do (push form results)))
    (nreverse results)))

(defun cst-source-range (cst)
  "Return (values START END) character offsets for CST's source range,
or (values NIL NIL) if CST has no source position recorded.

Eclector stores source ranges in the CST's `source` slot as either
(start . end) conses or NIL."
  (let ((src (and (typep cst 'concrete-syntax-tree:cst)
                  (concrete-syntax-tree:source cst))))
    (cond
      ((null src) (values nil nil))
      ((consp src) (values (car src) (cdr src)))
      (t (values nil nil)))))

(defun cst-covers-offset-p (cst offset)
  "True if CST's source range covers OFFSET (inclusive of start, exclusive of end)."
  (multiple-value-bind (s e) (cst-source-range cst)
    (and s e (<= s offset) (< offset e))))

(defun cst-children (cst)
  "Return the immediate children of a CST node as a list, or NIL for atoms.
Walks the cons-list structure, stopping at non-CST tails."
  (when (typep cst 'concrete-syntax-tree:cons-cst)
    (loop for c = cst then (concrete-syntax-tree:rest c)
          while (typep c 'concrete-syntax-tree:cons-cst)
          collect (concrete-syntax-tree:first c))))

(defun cst-at-offset (cst offset)
  "Return the deepest CST node whose source range covers OFFSET, or NIL.

Descends into children when one of them covers OFFSET; otherwise
returns CST itself if it covers OFFSET, NIL if not."
  (cond
    ((not (cst-covers-offset-p cst offset)) nil)
    (t
     (or (loop for child in (cst-children cst)
               for hit = (cst-at-offset child offset)
               when hit return hit)
         cst))))

(defun cst-find-in-list (csts offset)
  "Find the deepest CST node in list CSTS covering OFFSET. Returns NIL if none."
  (loop for cst in csts
        for hit = (cst-at-offset cst offset)
        when hit return hit))
