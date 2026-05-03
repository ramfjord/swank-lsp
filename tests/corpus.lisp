(in-package #:cl-scope-resolver/tests)

;;;; Test corpus: a list of cases, each saying "given this source, with
;;;; cursor at this offset, here's what we expect."
;;;;
;;;; Each case is a plist for readability:
;;;;   :name      -- short identifier, also used as the test name
;;;;   :source    -- source string
;;;;   :marker    -- a unique string to find in :source; the offset is
;;;;                 the position of its first character. Avoids
;;;;                 brittle hand-counted offsets.
;;;;   :expect    -- :LOCAL or :FOREIGN
;;;;   :binder    -- (only for :LOCAL) a unique substring of :source whose
;;;;                 position is the expected binder start. Length of the
;;;;                 matched name is the expected binder width. So given
;;;;                 marker pointing at a use of `x' bound by `(let ((x 1))
;;;;                 ...)', set :binder to the binder occurrence of "x".
;;;;   :reason    -- (optional) expected :REASON keyword for diagnostics;
;;;;                 if absent, any reason is accepted.
;;;;   :note      -- (optional) comment carried into test failure output.
;;;;
;;;; Marker convention: when the same name appears in both binding and
;;;; reference position, we need a way to point at the *use*. The
;;;; convention: prepend "@" to the use site as a sentinel, then strip
;;;; it before reading. So "(let ((x 1)) (+ @x x))" puts the cursor at
;;;; the first use of `x', and the source actually read is
;;;; "(let ((x 1)) (+ x x))".

(defun strip-marker (source marker)
  "Remove the first occurrence of MARKER from SOURCE; return
(values stripped-source offset). Errors if MARKER not found."
  (let ((pos (search marker source)))
    (unless pos
      (error "Marker ~S not found in source ~S" marker source))
    (values (concatenate 'string
                         (subseq source 0 pos)
                         (subseq source (+ pos (length marker))))
            pos)))

(defun expected-binder-range (stripped-source binder-needle &optional binder-name)
  "Locate the binder's source range in STRIPPED-SOURCE.

BINDER-NEEDLE picks the surrounding context (used for disambiguation
when the binder name itself is ambiguous, e.g. in shadowing tests);
BINDER-NAME (or BINDER-NEEDLE if BINDER-NAME is NIL) is the actual
substring whose range we want.

The expected range always points at the binder *name* — not the
enclosing binding form. This matches the resolver's API (`(values
:LOCAL name-start name-end :OK)`)."
  (let* ((needle-pos (search binder-needle stripped-source))
         (name (or binder-name binder-needle)))
    (unless needle-pos
      (error "Binder needle ~S not found in source ~S"
             binder-needle stripped-source))
    (let ((name-pos
            (search name stripped-source :start2 needle-pos)))
      (unless name-pos
        (error "Binder name ~S not found in source ~S after needle pos ~D"
               name stripped-source needle-pos))
      (values name-pos (+ name-pos (length name))))))

(defparameter *corpus*
  '(;; --- LET family ---
    (:name simple-let
     :source "(let ((x 1)) @x)"
     :marker "@"
     :expect :local
     :binder "x")
    (:name let-shadowing
     :source "(let ((x 1)) (let ((x 2)) @x))"
     :marker "@"
     :expect :local
     ;; Inner binder. There are two "x" tokens before @x (outer and inner);
     ;; we want the second-to-last; use a more specific needle.
     :binder "((x 2"
     :binder-name "x"
     :note "shadowed: inner LET wins. Binder needle includes context to disambiguate from outer.")
    (:name let-star-sequential
     :source "(let* ((x 1) (y x)) @y)"
     :marker "@"
     :expect :local
     :binder "(y "
     :binder-name "y")
    ;; --- LAMBDA / FLET / LABELS ---
    (:name lambda-param
     :source "((lambda (x) (+ @x 1)) 10)"
     :marker "@"
     :expect :local
     :binder "x")
    (:name flet-binding
     :source "(flet ((helper (n) (* n 2))) (@helper 5))"
     :marker "@"
     :expect :local
     :binder "helper")
    (:name labels-recursive
     :source "(labels ((rec (n) (if (zerop n) 0 (@rec (1- n))))) (rec 10))"
     :marker "@"
     :expect :local
     :binder "rec")
    ;; --- DEFUN body ---
    (:name defun-param
     :source "(defun add (a b) (+ @a b))"
     :marker "@"
     :expect :local
     :binder "(a b"
     :binder-name "a"
     :note "cursor on parameter reference inside DEFUN body")
    ;; --- DESTRUCTURING-BIND ---
    (:name destructuring-bind-simple
     :source "(destructuring-bind (a b) '(1 2) (+ @a b))"
     :marker "@"
     :expect :local
     :binder "(a b"
     :binder-name "a")
    (:name destructuring-bind-nested
     :source "(destructuring-bind (a (b c)) '(1 (2 3)) (list a @b c))"
     :marker "@"
     :expect :local
     :binder "(b c"
     :binder-name "b")
    ;; --- DOLIST / DOTIMES (expand to LET/BLOCK) ---
    (:name dolist-binding
     :source "(dolist (item '(1 2 3)) (print @item))"
     :marker "@"
     :expect :local
     :binder "item"
     :note "DOLIST expands to LET+BLOCK; binder still maps to source ITEM")
    (:name dotimes-binding
     :source "(dotimes (i 10) (print @i))"
     :marker "@"
     :expect :local
     :binder "(i 10"
     :binder-name "i")
    ;; --- Nested binders, inner shadowing outer ---
    (:name nested-flet-let
     :source "(flet ((f (x) (let ((x (* x 2))) @x))) (f 3))"
     :marker "@"
     :expect :local
     :binder "((x ("
     :binder-name "x"
     :note "inner LET shadows FLET's parameter")
    ;; --- FOREIGN cases ---
    (:name free-variable
     :source "(let ((x 1)) (+ x @y))"
     :marker "@"
     :expect :foreign
     :note "Y is free")
    (:name global-function
     :source "(let ((x 1)) (@print x))"
     :marker "@"
     :expect :foreign
     :note "PRINT is a global function, not in this scope")
    (:name special-variable
     :source "(let ((x 1)) (declare (special x)) (+ @x 1))"
     :marker "@"
     :expect :foreign
     :note "declared SPECIAL: dynamic, not lexical. Resolver should sentinel."
     :reason :special)
    (:name symbol-macrolet
     :source "(symbol-macrolet ((it 42)) (+ @it 1))"
     :marker "@"
     :expect :foreign
     :note "symbol-macrolet rewrites IT during walk; binder is macro-introduced. Document policy: punt to swank.")
    ;; --- Macroexpansion seam ---
    (:name when-body-reference
     :source "(let ((x 1)) (when (plusp x) (+ @x 2)))"
     :marker "@"
     :expect :local
     :binder "x"
     :note "WHEN expands to IF+PROGN; X reference is in a body that survives expansion.")
    ;; --- Cursor on the binding occurrence itself ---
    (:name cursor-on-binder
     :source "(let ((@x 1)) x)"
     :marker "@"
     :expect :local
     :binder "x"
     :note "Cursor on the binder itself: should resolve to itself.")
    ;; --- LOOP keywords ---
    (:name loop-for-as
     :source "(loop for i below 10 collect @i)"
     :marker "@"
     :expect :local
     :binder "i"
     :note "LOOP's FOR introduces a binding; walker may or may not reach it. Document.")
    ;; --- Quoted symbols (should be foreign / not-a-reference) ---
    (:name quoted-symbol
     :source "(let ((x 1)) (list 'x @x))"
     :marker "@"
     :expect :local
     :binder "x"
     :note "First X is quoted (not a reference); second X is the local. Cursor is on the local.")
    (:name cursor-on-quoted
     :source "(let ((x 1)) (list '@x x))"
     :marker "@"
     :expect :foreign
     :note "Cursor is on a quoted symbol; not a variable reference at all.")
    ;; --- Special forms with bindings ---
    (:name multiple-value-bind
     :source "(multiple-value-bind (a b) (values 1 2) (+ @a b))"
     :marker "@"
     :expect :local
     :binder "(a b"
     :binder-name "a")
    ;; --- Optional / keyword params ---
    (:name optional-param
     :source "(defun f (a &optional (b 10)) (+ a @b))"
     :marker "@"
     :expect :local
     :binder "b")
    (:name keyword-param
     :source "(defun f (&key (count 0)) (1+ @count))"
     :marker "@"
     :expect :local
     :binder "count"))
  "Phase-0 corpus: drives both the test suite and ad-hoc REPL exploration.")

(defun corpus-case-source-and-offset (case)
  "Return (values STRIPPED-SOURCE OFFSET) for CASE."
  (strip-marker (getf case :source) (getf case :marker)))
