(in-package #:cl-scope-resolver)

;;;; The resolver: given a source string and a character offset pointing
;;;; at a symbol, return either the source range of its lexical binder
;;;; (:local) or a sentinel meaning "ask elsewhere" (:foreign).
;;;;
;;;; Architecture (the "bridge" between eclector-CST and hu.dwim.walker):
;;;;
;;;; Eclector's CST nodes carry exact source ranges but no lexical
;;;; resolution. hu.dwim.walker computes lexical resolution but its AST
;;;; nodes carry only the raw read form in their SOURCE slot, with no
;;;; positions. The bridge exploits one invariant: when the walker stores
;;;; a non-atom (a cons) in its SOURCE slot, that cons is EQ to a cons
;;;; in the original read form, which is also EQ to some CST node's RAW
;;;; slot. So `cons → CST` and `cons → walker-node` tables, both keyed
;;;; on EQ, give us a round-trip.
;;;;
;;;; This invariant fails for atom sources (a walker reference's source
;;;; is the symbol it refers to — and the same symbol object is shared
;;;; across all occurrences of that name in the form). For atoms we
;;;; disambiguate by the *parent cons* and the *child index within it*.
;;;;
;;;; Resolution policy (`+foreign+` reasons exposed for diagnostics):
;;;;   :NO-FORM        offset is outside any top-level form
;;;;   :NOT-LEAF       offset is on whitespace/comment, not a leaf atom
;;;;   :NOT-A-SYMBOL   leaf is a number, string, etc.
;;;;   :QUOTED         leaf is inside a quoted form (not a reference)
;;;;   :WALKER-ERROR   hu.dwim.walker refused to walk the form
;;;;   :NO-PARENT      atom-cst is the entire top form (degenerate)
;;;;   :NO-WALKER-MATCH parent cons has no walker node — the walker
;;;;                   skipped this region (often: declarations)
;;;;   :SPECIAL        symbol is declared SPECIAL — dynamic, not lexical
;;;;   :SYMBOL-MACRO   binder is a SYMBOL-MACROLET — punt to swank
;;;;   :MACRO-INTRODUCED binder exists only post-expansion — needs
;;;;                   Phase-3 macroexpansion-aware navigation
;;;;   :GLOBAL         walker classifies as free / unresolved
;;;;   :NOT-A-REFERENCE leaf appears in a non-reference position
;;;;                   (operator of a free function call, declaration
;;;;                   target outside SPECIAL, LOOP keyword, etc.)
;;;;   :UNRESOLVED     fallthrough — walker didn't find a binding
;;;;                   and we couldn't classify why

(defconstant +local+ :local
  "Primary value of RESOLVE: symbol at OFFSET is a lexical reference and we found its binder in the same source string.")

(defconstant +foreign+ :foreign
  "Primary value of RESOLVE: symbol at OFFSET is not a resolvable local. Caller should fall through to swank.")

;;;; ---- helpers: parent / index / quoted-ancestor on the CST side ----

(defun cst-find-parent-and-index (root target)
  "Walk ROOT depth-first; return (values PARENT-CONS-CST INDEX) such that
the INDEX-th immediate child of PARENT-CONS-CST is EQ to TARGET. Returns
(values NIL NIL) if TARGET is not under ROOT (or is ROOT itself).

INDEX is 0 for the operator of a function call form, 1 for its first
argument, and so on. (LOOP's RETURN drops multiple values, so we use
RETURN-FROM throughout.)"
  (when (typep root 'concrete-syntax-tree:cons-cst)
    (let ((i 0))
      (dolist (k (cst-children root))
        (when (eq k target)
          (return-from cst-find-parent-and-index (values root i)))
        (multiple-value-bind (p idx) (cst-find-parent-and-index k target)
          (when p
            (return-from cst-find-parent-and-index (values p idx))))
        (incf i))))
  (values nil nil))

(defun cst-ancestors (root target)
  "Return list of CST nodes on the path from ROOT to TARGET, root first,
TARGET last. NIL if TARGET is not under ROOT."
  (cond
    ((eq root target) (list root))
    ((typep root 'concrete-syntax-tree:cons-cst)
     (loop for k in (cst-children root)
           for path = (cst-ancestors k target)
           when path return (cons root path)))
    (t nil)))

(defun cst-quoted-ancestor-p (root target)
  "True if TARGET lies inside a quoted/quasiquoted subform of ROOT.
Detects '(...) — i.e. a CONS-CST whose first child is the symbol QUOTE.
Quasiquote is recognized by symbol name to be implementation-portable
(SBCL prints `,X as a list whose car is SB-INT:QUASIQUOTE)."
  (let ((path (cst-ancestors root target)))
    (loop for cst in path
          when (and (typep cst 'concrete-syntax-tree:cons-cst)
                    (let ((head (concrete-syntax-tree:first cst)))
                      (and (typep head 'concrete-syntax-tree:atom-cst)
                           (let ((s (concrete-syntax-tree:raw head)))
                             (and (symbolp s)
                                  (member (symbol-name s)
                                          '("QUOTE" "QUASIQUOTE")
                                          :test #'string=))))))
            ;; Cursor is "in" a quote when target is strictly inside the
            ;; quoted form (not the QUOTE symbol itself).
            return (not (eq cst target)))))

;;;; ---- helpers: cons → walker-node, cons → CST tables ----

(defun build-cons-tables (cst ast)
  "Walk CST and AST, producing two EQ hash-tables:
  CONS->CST     — every cons-CST keyed on its RAW
  CONS->WALKER  — every walker node whose SOURCE is a cons, keyed on it
Returns (values CONS->CST CONS->WALKER)."
  (let ((cons->cst (make-hash-table :test 'eq))
        (cons->walker (make-hash-table :test 'eq)))
    (labels ((walk-cst (n)
               (when (typep n 'concrete-syntax-tree:cons-cst)
                 (let ((raw (concrete-syntax-tree:raw n)))
                   (when (consp raw)
                     (setf (gethash raw cons->cst) n)))
                 (dolist (k (cst-children n)) (walk-cst k)))))
      (walk-cst cst))
    (when ast
      (hu.dwim.walker::map-ast
       (lambda (n)
         (when (and (slot-exists-p n 'hu.dwim.walker::source)
                    (slot-boundp n 'hu.dwim.walker::source))
           (let ((src (slot-value n 'hu.dwim.walker::source)))
             (when (consp src)
               ;; Last writer wins is fine: when multiple AST nodes claim
               ;; the same cons, we want the *innermost* (last visited
               ;; in MAP-AST's depth-first order). MAP-AST visits parent
               ;; first, then children, so this gives the deepest.
               (setf (gethash src cons->walker) n))))
         n)
       ast))
    (values cons->cst cons->walker)))

;;;; ---- helpers: walker AST navigation ----

(defun walker-children (n)
  "Return immediate walker children of N as a flat list. We only enumerate
the slots resolution actually traverses; this is intentionally narrow."
  (let ((kids '()))
    (flet ((collect (slot)
             (when (and (slot-exists-p n slot) (slot-boundp n slot))
               (let ((v (slot-value n slot)))
                 (cond ((listp v) (dolist (x v) (when x (push x kids))))
                       (v        (push v kids)))))))
      (dolist (s '(hu.dwim.walker::operator
                   hu.dwim.walker::arguments
                   hu.dwim.walker::body
                   hu.dwim.walker::bindings
                   hu.dwim.walker::value
                   hu.dwim.walker::initial-value
                   hu.dwim.walker::declarations
                   hu.dwim.walker::then
                   hu.dwim.walker::else
                   hu.dwim.walker::condition
                   hu.dwim.walker::test
                   hu.dwim.walker::default-value))
        (collect s)))
    (nreverse kids)))

(defun walker-find-reference-near (parent-walker name &optional ignored)
  "Inside PARENT-WALKER (a walker AST node, often a free-application or
let body element), find a WALKED-LEXICAL-VARIABLE-REFERENCE-FORM whose
NAME-OF matches NAME. Returns the matching walker reference form, or NIL.

Visits only PARENT-WALKER's immediate walker children — we don't cross
form boundaries. The ambiguous case (multiple references to the same
NAME inside the parent) is handled by the caller's parent-cons lookup:
the parent-cons is unique per source position, so for non-macroexpanded
forms there's a unique match per occurrence. Inside macroexpanded
forms (e.g. MULTIPLE-VALUE-BIND) all refs share the macro form's
source — but they all have the same DEFINITION-OF (one binding), so
returning any of them yields the right answer."
  (declare (ignore ignored))
  (dolist (c (walker-children parent-walker))
    (when (and (typep c 'hu.dwim.walker:walked-lexical-variable-reference-form)
               (eq (hu.dwim.walker:name-of c) name))
      (return-from walker-find-reference-near c)))
  nil)

(defun walker-binding-source-cons (binding)
  "Return the cons cell that locates BINDING in the original form, or NIL
if BINDING's source is a bare atom (e.g. a lambda param without a
default).

For LET/LET*/MULTIPLE-VALUE-BIND etc. the binding's source is `(name init)`
or just `name`; we want the cons when present."
  (and (slot-exists-p binding 'hu.dwim.walker::source)
       (slot-boundp binding 'hu.dwim.walker::source)
       (let ((s (slot-value binding 'hu.dwim.walker::source)))
         (and (consp s) s))))

(defun cst-binder-range-for (binding cons->cst)
  "Find the source range (START . END) of the *name* introduced by
walker BINDING. Returns (values START END) or (values NIL NIL).

Strategy:
  1. If binding's SOURCE is `(name init)` cons, look up that cons in
     CONS->CST → its first child is the name's CST → return its range.
  2. Otherwise, walk up walker parent chain to find the enclosing form
     whose SOURCE is a cons we *do* know (e.g. the LAMBDA form);
     descend that CST to find the symbol whose RAW is EQ to
     (NAME-OF BINDING).

Step 2 handles lambda/optional/key params, which the walker often
records as bare atoms in their source slot."
  (let* ((name (and (slot-exists-p binding 'hu.dwim.walker::name)
                    (slot-boundp binding 'hu.dwim.walker::name)
                    (slot-value binding 'hu.dwim.walker::name)))
         (binding-cons (walker-binding-source-cons binding)))
    ;; Path 1: source is `(name …)` — the head is the name.
    (when (and binding-cons (eq (car binding-cons) name))
      (let ((bc (gethash binding-cons cons->cst)))
        (when (typep bc 'concrete-syntax-tree:cons-cst)
          (let ((head (concrete-syntax-tree:first bc)))
            (when (typep head 'concrete-syntax-tree:atom-cst)
              (let ((src (concrete-syntax-tree:source head)))
                (when (consp src)
                  (return-from cst-binder-range-for
                    (values (car src) (cdr src))))))))))
    ;; Path 2: lambda parameter / function-arg / etc. The walker stores
    ;; the *whole form* in source for these. Find the smallest enclosing
    ;; CST whose RAW is a cons that contains NAME structurally, and
    ;; locate the binder occurrence positionally inside it.
    (when name
      (let ((host-cst (find-binding-host-cst binding cons->cst)))
        (when host-cst
          (multiple-value-bind (s e)
              (cst-find-binder-occurrence-of host-cst name)
            (when s (return-from cst-binder-range-for (values s e)))))))
    (values nil nil)))

(defun find-binding-host-cst (binding cons->cst)
  "For a non-(name init) binding (lambda param / required-arg / etc.),
return the CST of the enclosing form that hosts the binder syntactically.
Walks the walker parent chain, returning the *first* cons-source CST
we encounter — for a lambda param that's the LAMBDA / DEFUN / DEFMETHOD
form; for an FLET param it's the FLET binding itself."
  (loop for p = binding
                  then (and p (slot-exists-p p 'hu.dwim.walker::parent)
                            (slot-boundp p 'hu.dwim.walker::parent)
                            (slot-value p 'hu.dwim.walker::parent))
        while p
        do (let* ((src (and (slot-exists-p p 'hu.dwim.walker::source)
                            (slot-boundp p 'hu.dwim.walker::source)
                            (slot-value p 'hu.dwim.walker::source)))
                  (cst (and (consp src) (gethash src cons->cst))))
             (when cst
               (return-from find-binding-host-cst cst)))))

(defun cst-find-binder-occurrence-of (host-cst name)
  "Walk HOST-CST looking for the symbol-atom-CST that introduces NAME as
a binder. Recognizes the binder slot in: lambda lists, FLET/LABELS
binding lists, LET bindings, DESTRUCTURING-BIND/MULTIPLE-VALUE-BIND
binders, DOLIST/DOTIMES specs.

This is more conservative than CST-FIND-NAME-OCCURRENCE — that one would
match ANY occurrence of the symbol; here we only match where the symbol
syntactically introduces a binding."
  (labels ((scan (cst)
             (when (typep cst 'concrete-syntax-tree:cons-cst)
               (let ((opname (cst-head-symbol-name cst))
                     (kids (cst-children cst)))
                 (cond
                   ((member opname '("LAMBDA") :test #'string=)
                    (visit-ll (second kids)))
                   ((member opname '("DEFUN" "DEFMACRO" "DEFMETHOD")
                            :test #'string=)
                    (visit-ll (third kids)))
                   ((member opname '("FLET" "LABELS" "MACROLET")
                            :test #'string=)
                    (let ((bl (second kids)))
                      (when (typep bl 'concrete-syntax-tree:cons-cst)
                        (dolist (b (cst-children bl))
                          (when (typep b 'concrete-syntax-tree:cons-cst)
                            (let ((bk (cst-children b)))
                              ;; First child is the function name (binder
                              ;; for the function in the body's lex env).
                              (let ((fn-name (first bk)))
                                (when (and (typep fn-name 'concrete-syntax-tree:atom-cst)
                                           (eq (concrete-syntax-tree:raw fn-name) name))
                                  (return-binder fn-name)))
                              ;; Second child is the lambda-list — its
                              ;; params are also binders.
                              (visit-ll (second bk))
                              ;; Body might contain nested binders.
                              (dolist (form (cddr bk)) (scan form))))))))
                   ((member opname '("LET" "LET*" "SYMBOL-MACROLET")
                            :test #'string=)
                    (let ((bl (second kids)))
                      (when (typep bl 'concrete-syntax-tree:cons-cst)
                        (dolist (b (cst-children bl))
                          (cond
                            ((and (typep b 'concrete-syntax-tree:atom-cst)
                                  (eq (concrete-syntax-tree:raw b) name))
                             (return-binder b))
                            ((typep b 'concrete-syntax-tree:cons-cst)
                             (let ((nm (first (cst-children b))))
                               (when (and (typep nm 'concrete-syntax-tree:atom-cst)
                                          (eq (concrete-syntax-tree:raw nm) name))
                                 (return-binder nm))))))
                        ;; And recurse into init forms / body for nested.
                        (dolist (form (cddr kids)) (scan form)))))
                   ((member opname '("DESTRUCTURING-BIND" "MULTIPLE-VALUE-BIND")
                            :test #'string=)
                    (visit-tree (second kids))
                    (dolist (form (cddr kids)) (scan form)))
                   ((member opname '("DOLIST" "DOTIMES") :test #'string=)
                    (let ((spec (second kids)))
                      (when (typep spec 'concrete-syntax-tree:cons-cst)
                        (let ((var (first (cst-children spec))))
                          (when (and (typep var 'concrete-syntax-tree:atom-cst)
                                     (eq (concrete-syntax-tree:raw var) name))
                            (return-binder var))))
                      (dolist (form (cddr kids)) (scan form))))
                   (t
                    ;; Unknown op: recurse into all children.
                    (dolist (k kids) (scan k)))))))
           (visit-ll (ll)
             ;; Walk a lambda-list; recognize binder names skipping defaults
             ;; and lambda-list keywords.
             (when (typep ll 'concrete-syntax-tree:cons-cst)
               (dolist (item (cst-children ll))
                 (cond
                   ((and (typep item 'concrete-syntax-tree:atom-cst)
                         (let ((r (concrete-syntax-tree:raw item)))
                           (and (eq r name)
                                (not (lambda-list-keyword-name-p r)))))
                    (return-binder item))
                   ((typep item 'concrete-syntax-tree:cons-cst)
                    ;; (name default) or (name default supplied-p) or
                    ;; ((:k name) default).
                    (let ((nm (first (cst-children item))))
                      (cond
                        ((and (typep nm 'concrete-syntax-tree:atom-cst)
                              (eq (concrete-syntax-tree:raw nm) name))
                         (return-binder nm))
                        ((typep nm 'concrete-syntax-tree:cons-cst)
                         ;; ((:k name) ...) — name is second child of nm.
                         (let ((real (second (cst-children nm))))
                           (when (and (typep real 'concrete-syntax-tree:atom-cst)
                                      (eq (concrete-syntax-tree:raw real) name))
                             (return-binder real)))))))))))
           (visit-tree (tree)
             ;; Walk a destructuring tree, returning binders matching NAME.
             (cond ((null tree) nil)
                   ((typep tree 'concrete-syntax-tree:atom-cst)
                    (when (eq (concrete-syntax-tree:raw tree) name)
                      (return-binder tree)))
                   ((typep tree 'concrete-syntax-tree:cons-cst)
                    (dolist (k (cst-children tree)) (visit-tree k)))))
           (return-binder (atom-cst)
             (let ((src (concrete-syntax-tree:source atom-cst)))
               (when (consp src)
                 (return-from cst-find-binder-occurrence-of
                   (values (car src) (cdr src)))))))
    (scan host-cst))
  (values nil nil))

(defun cst-find-name-occurrence (root name)
  "Find the first (depth-first, source-order) atom-CST under ROOT whose
RAW is EQ to NAME and that is *not* inside a quoted subform. Returns
(values START END) or (values NIL NIL).

\"Source order\" meaning: lambda/let/etc. lists put the binder names
syntactically before the body; the first occurrence we hit is therefore
the binder, not a use."
  (labels ((visit (n)
             (cond
               ;; Skip quoted subforms entirely.
               ((and (typep n 'concrete-syntax-tree:cons-cst)
                     (let ((h (concrete-syntax-tree:first n)))
                       (and (typep h 'concrete-syntax-tree:atom-cst)
                            (let ((s (concrete-syntax-tree:raw h)))
                              (and (symbolp s)
                                   (string= (symbol-name s) "QUOTE"))))))
                nil)
               ((typep n 'concrete-syntax-tree:cons-cst)
                (dolist (k (cst-children n))
                  (multiple-value-bind (s e) (visit k)
                    (when s (return-from cst-find-name-occurrence (values s e))))))
               ((typep n 'concrete-syntax-tree:atom-cst)
                (when (eq (concrete-syntax-tree:raw n) name)
                  (let ((src (concrete-syntax-tree:source n)))
                    (when (consp src)
                      (return-from cst-find-name-occurrence
                        (values (car src) (cdr src))))))))))
    (visit root)
    (values nil nil)))

;;;; ---- declarations ----

(defun atom-declared-special-p (atom-cst containing-cst)
  "True if ATOM-CST sits inside a `(SPECIAL …)` clause — i.e. cursor is
on a name being declared SPECIAL. We don't check the declared name's
identity; if cursor is anywhere inside the clause, this is a special
declaration target, which the resolver punts on (caller treats as
:foreign :special)."
  (some (lambda (p)
          (and (typep p 'concrete-syntax-tree:cons-cst)
               (cst-head-name= p "SPECIAL")
               (not (eq p atom-cst))))
        (cst-ancestors containing-cst atom-cst)))

(defun atom-in-declare-form-p (containing-cst atom-cst)
  "True if ATOM-CST lies inside a (DECLARE ...) form."
  (let ((path (cst-ancestors containing-cst atom-cst)))
    (some (lambda (p)
            (and (typep p 'concrete-syntax-tree:cons-cst)
                 (let ((h (concrete-syntax-tree:first p)))
                   (and (typep h 'concrete-syntax-tree:atom-cst)
                        (let ((s (concrete-syntax-tree:raw h)))
                          (and (symbolp s)
                               (string= (symbol-name s) "DECLARE")))))))
          path)))

;;;; ---- main entrypoint ----

(defmacro %fail (reason)
  "Local: return (+foreign+ nil nil REASON) from the enclosing block."
  `(return-from resolve (values +foreign+ nil nil ,reason)))

(defun resolve (source-string offset)
  "Resolve the symbol at character OFFSET in SOURCE-STRING.

Returns four values:
  KIND   :LOCAL or :FOREIGN
  START  character offset of binder (when :LOCAL), else NIL
  END    character offset just past binder (when :LOCAL), else NIL
  REASON keyword diagnostic (always present; see source for taxonomy)

Pure function. No IO, no global mutation, no EVAL. Eclector does the
read; hu.dwim.walker does the lexical analysis. The bridge is here."
  (let* ((csts (handler-case (cst-from-string source-string)
                 (error () nil))))
    (unless csts (%fail :read-error))
    (let* ((containing-cst
             (loop for c in csts
                     thereis (and (cst-covers-offset-p c offset) c))))
      (unless containing-cst (%fail :no-form))
      (let ((atom-cst (cst-at-offset containing-cst offset)))
        (unless (typep atom-cst 'concrete-syntax-tree:atom-cst)
          (%fail :not-leaf))
        (let ((name (concrete-syntax-tree:raw atom-cst)))
          (unless (symbolp name) (%fail :not-a-symbol))
          (resolve-symbol-occurrence containing-cst atom-cst name))))))

(defun resolve-symbol-occurrence (containing-cst atom-cst name)
  "Inner half of RESOLVE: a symbol-atom CST is at the cursor; classify it."
  ;; CST-only sentinels (no need to walk).
  (when (cst-quoted-ancestor-p containing-cst atom-cst)
    (return-from resolve-symbol-occurrence
      (values +foreign+ nil nil :quoted)))
  (when (or (atom-declared-special-p atom-cst containing-cst)
            (atom-use-shadowed-by-special-p containing-cst atom-cst name))
    (return-from resolve-symbol-occurrence
      (values +foreign+ nil nil :special)))
  (when (atom-under-symbol-macrolet-p containing-cst atom-cst name)
    (return-from resolve-symbol-occurrence
      (values +foreign+ nil nil :symbol-macro)))
  ;; CST-only :LOCAL fast path: cursor is on a binder occurrence.
  (let ((br (cst-binder-occurrence-range containing-cst atom-cst)))
    (when br
      (return-from resolve-symbol-occurrence
        (values +local+ (car br) (cdr br) :binder))))
  ;; CST-only :LOCAL: cursor is a use inside a known binder. Handles
  ;; macros whose expansion strips positions (DOLIST, DOTIMES,
  ;; MULTIPLE-VALUE-BIND, DESTRUCTURING-BIND, LET*-style sequential
  ;; bindings — the walker can't tell us where the source binder is).
  ;; This must beat the walker because the walker's positions for
  ;; macroexpanded forms point at the whole macro form, not the binder.
  (let ((br (cst-lexical-binder-for-use containing-cst atom-cst name)))
    (when br
      (return-from resolve-symbol-occurrence
        (values +local+ (car br) (cdr br) :ok))))
  ;; Names inside (DECLARE …) that we didn't sentinel as :SPECIAL above:
  ;; they're declaration targets (TYPE / IGNORE / DYNAMIC-EXTENT etc.) —
  ;; names of an existing binding, not references that need resolving.
  (when (atom-in-declare-form-p containing-cst atom-cst)
    (return-from resolve-symbol-occurrence
      (values +foreign+ nil nil :not-a-reference)))
  ;; Bring in the walker for everything else.
  (multiple-value-bind (ast walker-error)
      (safely-walk (concrete-syntax-tree:raw containing-cst))
    (declare (ignore walker-error))
    (unless ast
      (return-from resolve-symbol-occurrence
        (values +foreign+ nil nil :walker-error)))
    (multiple-value-bind (cons->cst cons->walker)
        (build-cons-tables containing-cst ast)
      (resolve-with-walker containing-cst atom-cst name
                           cons->cst cons->walker))))

(defun cst-lexical-binder-for-use (root atom-cst name)
  "Walk ROOT's ancestor chain at ATOM-CST, looking for an enclosing
binder (LET/LET*/LAMBDA/DEFUN/FLET/LABELS/DOLIST/DOTIMES/MULTIPLE-VALUE-BIND/
DESTRUCTURING-BIND) that introduces NAME with NAME in scope at ATOM-CST.

Returns (START . END) of the binder name's source range, or NIL if no
known enclosing binder introduces NAME visible from ATOM-CST.

Resolution finds the *innermost* shadowing binder (walks ancestors from
deepest outward; first match wins). For LET*, sequential semantics:
ATOM-CST inside an init form sees only earlier bindings of the same
LET*."
  (let ((path (cst-ancestors root atom-cst)))
    (loop for cst in (reverse path)
          for binder = (cst-find-shadowing-binder cst atom-cst name)
          when binder return binder)))

(defun cst-find-shadowing-binder (cst atom-cst name)
  "If CST is a binder form that introduces NAME visible at ATOM-CST,
return the (START . END) of NAME's binder occurrence in CST. Otherwise
NIL.

Visibility rules respected:
  - LET / LAMBDA / DEFUN / DEFMACRO / DEFMETHOD / DESTRUCTURING-BIND /
    MULTIPLE-VALUE-BIND / DOLIST / DOTIMES: NAME is visible in the body
    only, not in init / value / range expressions.
  - LET*: NAME is visible from the next binding onward and in the body.
  - FLET: function NAME is visible in the body only (not in the binding
    bodies). Lambda-list params of an FLET binding are visible inside
    that binding's body.
  - LABELS: function NAME is visible in all bindings and the body.
  - SYMBOL-MACROLET / MACROLET: handled separately (sentinels)."
  (unless (typep cst 'concrete-syntax-tree:cons-cst)
    (return-from cst-find-shadowing-binder nil))
  (let ((opname (cst-head-symbol-name cst))
        (kids (cst-children cst)))
    (cond
      ;; LET: bindings are second child; body is rest. ATOM-CST must be
      ;; in body (or in the bindings list itself, but that's the
      ;; cursor-on-binder case handled earlier).
      ((member opname '("LET") :test #'string=)
       (when (cst-atom-in-let-body-p kids atom-cst)
         (cst-find-binder-in-let-bindings (second kids) name)))
      ;; LET*: each binding's NAME is visible from the next binding's
      ;; init form onward, and in the body.
      ((string= opname "LET*")
       (cst-let*-binder-for-use kids atom-cst name))
      ;; LAMBDA: lambda-list is second child; body is rest.
      ((string= opname "LAMBDA")
       (when (cst-atom-in-children-p (cddr kids) atom-cst)
         (cst-find-binder-in-lambda-list (second kids) name)))
      ;; DEFUN/DEFMACRO/DEFMETHOD: lambda-list is third child; body is rest.
      ((member opname '("DEFUN" "DEFMACRO" "DEFMETHOD") :test #'string=)
       (when (cst-atom-in-children-p (cdddr kids) atom-cst)
         (cst-find-binder-in-lambda-list (third kids) name)))
      ;; DOLIST / DOTIMES: spec is second child = `(var range)`; body is rest.
      ((member opname '("DOLIST" "DOTIMES") :test #'string=)
       (when (cst-atom-in-children-p (cddr kids) atom-cst)
         (let ((spec (second kids)))
           (when (typep spec 'concrete-syntax-tree:cons-cst)
             (let ((var (first (cst-children spec))))
               (when (and (typep var 'concrete-syntax-tree:atom-cst)
                          (eq (concrete-syntax-tree:raw var) name))
                 (let ((src (concrete-syntax-tree:source var)))
                   (and (consp src) (cons (car src) (cdr src))))))))))
      ;; MULTIPLE-VALUE-BIND: vars are second child; body is rest of
      ;; (mvb (vars…) values-form body…) — values-form is third child.
      ((string= opname "MULTIPLE-VALUE-BIND")
       (when (cst-atom-in-children-p (cdddr kids) atom-cst)
         (cst-find-binder-in-tree (second kids) name)))
      ;; DESTRUCTURING-BIND: tree is second; values is third; body is rest.
      ((string= opname "DESTRUCTURING-BIND")
       (when (cst-atom-in-children-p (cdddr kids) atom-cst)
         (cst-find-binder-in-tree (second kids) name)))
      ;; FLET: binding function names visible in body (rest after second
      ;; child). Inside each binding's body, the binding's own params are
      ;; visible.
      ((string= opname "FLET")
       (cond
         ((cst-atom-in-children-p (cddr kids) atom-cst)
          (cst-find-binder-name-in-fn-list (second kids) name))
         (t (cst-find-binder-in-fn-list-bindings (second kids) atom-cst name))))
      ;; LABELS: binding function names visible everywhere (all bindings + body).
      ((string= opname "LABELS")
       (or (cst-find-binder-name-in-fn-list (second kids) name)
           (cst-find-binder-in-fn-list-bindings (second kids) atom-cst name)))
      ;; LOOP: extended-form parsing is large. Recognize the most common
      ;; binder shapes: `(loop for VAR …)`, `(loop with VAR …)`,
      ;; `(loop as VAR …)`, `(loop … into VAR …)`, ignoring `for VAR =`
      ;; vs. `for VAR in EXPR` distinctions (they all bind VAR). VAR can
      ;; be a destructuring tree.
      ((string= opname "LOOP")
       (cst-loop-binder-for-use (rest kids) name)))))

(defun cst-loop-binder-for-use (clauses name)
  "Scan LOOP CLAUSES (a list of CST atoms / conses) for a binder of NAME.
Returns (START . END) for the matching binder atom, or NIL.

Recognized binder slots:
  (FOR | AS | WITH) <var> …
  … INTO <var> …

VAR may be an atom or a destructuring tree. The first matching atom is
returned (innermost = textually-leftmost, since LOOP doesn't shadow)."
  (loop for (clause next . _) on clauses
        when (and (typep clause 'concrete-syntax-tree:atom-cst)
                  (let ((s (concrete-syntax-tree:raw clause)))
                    (and (symbolp s)
                         (member (symbol-name s)
                                 '("FOR" "AS" "WITH" "INTO")
                                 :test #'string=))))
          do (let ((r (cst-find-binder-in-tree next name)))
               (when r (return r)))))

(defun cst-atom-in-children-p (children atom-cst)
  (some (lambda (c) (cst-atom-anywhere-under-p c atom-cst)) children))

(defun cst-atom-in-let-body-p (let-kids atom-cst)
  "True if ATOM-CST is in any of the body forms of a LET (cddr of children)."
  (cst-atom-in-children-p (cddr let-kids) atom-cst))

(defun cst-find-binder-in-let-bindings (bindings-cst name)
  "BINDINGS-CST is the second child of LET — `((n1 e1) n2 (n3 e3))`.
Find the binder whose name is NAME and return its (START . END)."
  (when (typep bindings-cst 'concrete-syntax-tree:cons-cst)
    (dolist (b (cst-children bindings-cst))
      (cond
        ((and (typep b 'concrete-syntax-tree:atom-cst)
              (eq (concrete-syntax-tree:raw b) name))
         (let ((s (concrete-syntax-tree:source b)))
           (when (consp s) (return-from cst-find-binder-in-let-bindings
                             (cons (car s) (cdr s))))))
        ((typep b 'concrete-syntax-tree:cons-cst)
         (let ((nm (first (cst-children b))))
           (when (and (typep nm 'concrete-syntax-tree:atom-cst)
                      (eq (concrete-syntax-tree:raw nm) name))
             (let ((s (concrete-syntax-tree:source nm)))
               (when (consp s) (return-from cst-find-binder-in-let-bindings
                                 (cons (car s) (cdr s)))))))))))
  nil)

(defun cst-let*-binder-for-use (let*-kids atom-cst name)
  "LET* sequential semantics: a binding's NAME is visible from the next
binding's init form onward. Find the most-recent prior binding of NAME
whose scope encloses ATOM-CST."
  (let* ((bindings-cst (second let*-kids))
         (body (cddr let*-kids))
         (bindings (and (typep bindings-cst 'concrete-syntax-tree:cons-cst)
                        (cst-children bindings-cst))))
    (let ((found nil))
      (loop for (b . rest) on bindings
            for binding-name-cst = (cond
                                     ((typep b 'concrete-syntax-tree:atom-cst) b)
                                     ((typep b 'concrete-syntax-tree:cons-cst)
                                      (first (cst-children b))))
            do (when (and (typep binding-name-cst 'concrete-syntax-tree:atom-cst)
                          (eq (concrete-syntax-tree:raw binding-name-cst) name))
                 (when (or
                        ;; ATOM-CST is in any later binding's init form
                        (some (lambda (later)
                                (when (typep later 'concrete-syntax-tree:cons-cst)
                                  (let ((init (second (cst-children later))))
                                    (and init (cst-atom-anywhere-under-p
                                               init atom-cst)))))
                              rest)
                        ;; ATOM-CST is in body
                        (cst-atom-in-children-p body atom-cst))
                   (let ((s (concrete-syntax-tree:source binding-name-cst)))
                     (when (consp s)
                       (setf found (cons (car s) (cdr s))))))))
      found)))

(defun cst-find-binder-in-lambda-list (lambda-list-cst name)
  "Find a parameter named NAME in LAMBDA-LIST-CST and return its (START . END)."
  (when (typep lambda-list-cst 'concrete-syntax-tree:cons-cst)
    (dolist (item (cst-children lambda-list-cst))
      (cond
        ((and (typep item 'concrete-syntax-tree:atom-cst)
              (eq (concrete-syntax-tree:raw item) name)
              (not (lambda-list-keyword-name-p name)))
         (let ((s (concrete-syntax-tree:source item)))
           (when (consp s) (return-from cst-find-binder-in-lambda-list
                             (cons (car s) (cdr s))))))
        ((typep item 'concrete-syntax-tree:cons-cst)
         (let ((nm (first (cst-children item))))
           (cond
             ((and (typep nm 'concrete-syntax-tree:atom-cst)
                   (eq (concrete-syntax-tree:raw nm) name))
              (let ((s (concrete-syntax-tree:source nm)))
                (when (consp s) (return-from cst-find-binder-in-lambda-list
                                  (cons (car s) (cdr s))))))
             ((typep nm 'concrete-syntax-tree:cons-cst)
              ;; ((:k name) default)
              (let ((real (second (cst-children nm))))
                (when (and (typep real 'concrete-syntax-tree:atom-cst)
                           (eq (concrete-syntax-tree:raw real) name))
                  (let ((s (concrete-syntax-tree:source real)))
                    (when (consp s) (return-from cst-find-binder-in-lambda-list
                                      (cons (car s) (cdr s))))))))))))))
  nil)

(defun cst-find-binder-in-tree (tree-cst name)
  "Walk a destructuring tree CST looking for an atom whose RAW is NAME."
  (cond
    ((null tree-cst) nil)
    ((typep tree-cst 'concrete-syntax-tree:atom-cst)
     (when (eq (concrete-syntax-tree:raw tree-cst) name)
       (let ((s (concrete-syntax-tree:source tree-cst)))
         (when (consp s) (cons (car s) (cdr s))))))
    ((typep tree-cst 'concrete-syntax-tree:cons-cst)
     (dolist (k (cst-children tree-cst))
       (let ((r (cst-find-binder-in-tree k name)))
         (when r (return r)))))))

(defun cst-find-binder-name-in-fn-list (bindings-cst name)
  "FLET/LABELS bindings list. Return (START . END) of the function-name
in a binding `(NAME (args) body…)` matching NAME."
  (when (typep bindings-cst 'concrete-syntax-tree:cons-cst)
    (dolist (b (cst-children bindings-cst))
      (when (typep b 'concrete-syntax-tree:cons-cst)
        (let ((nm (first (cst-children b))))
          (when (and (typep nm 'concrete-syntax-tree:atom-cst)
                     (eq (concrete-syntax-tree:raw nm) name))
            (let ((s (concrete-syntax-tree:source nm)))
              (when (consp s) (return-from cst-find-binder-name-in-fn-list
                                (cons (car s) (cdr s))))))))))
  nil)

(defun cst-find-binder-in-fn-list-bindings (bindings-cst atom-cst name)
  "When ATOM-CST is inside one of the FLET/LABELS bindings' bodies, the
lambda-list params of that binding are also in scope. Find a matching
param."
  (when (typep bindings-cst 'concrete-syntax-tree:cons-cst)
    (dolist (b (cst-children bindings-cst))
      (when (typep b 'concrete-syntax-tree:cons-cst)
        (let* ((bk (cst-children b))
               (ll (second bk))
               (body (cddr bk)))
          (when (and ll
                     (some (lambda (form) (cst-atom-anywhere-under-p form atom-cst))
                           body))
            (let ((r (cst-find-binder-in-lambda-list ll name)))
              (when r (return-from cst-find-binder-in-fn-list-bindings r))))))))
  nil)

(defun resolve-with-walker (containing-cst atom-cst name cons->cst cons->walker)
  "Use the walker to classify ATOM-CST as a reference and look up its binder."
  (multiple-value-bind (parent-cst child-index)
      (cst-find-parent-and-index containing-cst atom-cst)
    (unless parent-cst
      (return-from resolve-with-walker
        (values +foreign+ nil nil :no-parent)))
    (let* ((parent-cons   (concrete-syntax-tree:raw parent-cst))
           (parent-walker (gethash parent-cons cons->walker)))
      (cond
        ;; Lexical function call site: parent is `(helper …)`, atom-cst is
        ;; the function name at index 0. The walker encodes this as a
        ;; WALKED-LEXICAL-APPLICATION-FORM whose DEFINITION-OF is the
        ;; FLET/LABELS binding form. There's no separate VAR-reference
        ;; child for the function name — handle the application form
        ;; directly.
        ((and (typep parent-walker
                     'hu.dwim.walker:walked-lexical-application-form)
              (eql child-index 0))
         (let ((def (hu.dwim.walker:definition-of parent-walker)))
           (cond
             ((null def) (values +foreign+ nil nil :unresolved))
             (t (resolve-binding def cons->cst)))))
        ((null parent-walker)
         (values +foreign+ nil nil :no-walker-match))
        (t
         (let ((ref (walker-find-reference-near parent-walker name name)))
           (cond
             ((null ref)
              (values +foreign+ nil nil :not-a-reference))
             (t
              (resolve-reference ref cons->cst)))))))))

(defun resolve-reference (ref cons->cst)
  "Given a walker REF (variable or function reference), look up its
binding and translate the binding back to a CST source range."
  (resolve-binding (hu.dwim.walker:definition-of ref) cons->cst))

(defun resolve-binding (binding cons->cst)
  "Translate a walker BINDING (var binding, function binding, lambda
param) back to a CST source range. Returns the four RESOLVE values."
  (cond
    ((null binding)
     (values +foreign+ nil nil :unresolved))
    ((and (slot-exists-p binding 'hu.dwim.walker::result-of-macroexpansion?)
          (slot-boundp binding 'hu.dwim.walker::result-of-macroexpansion?)
          (slot-value binding 'hu.dwim.walker::result-of-macroexpansion?))
     (values +foreign+ nil nil :macro-introduced))
    (t
     (multiple-value-bind (s e) (cst-binder-range-for binding cons->cst)
       (if s
           (values +local+ s e :ok)
           (values +foreign+ nil nil :unresolved))))))

(defun cst-binder-occurrence-range (root atom-cst)
  "If ATOM-CST is itself a binder occurrence (the name in a LET binding,
a lambda parameter, etc.), return (START . END). Otherwise NIL.

Uses purely structural CST cues — cheaper and more reliable than
asking the walker, since the walker doesn't keep separate AST nodes
for binder occurrences inside lambda lists."
  (let ((path (cst-ancestors root atom-cst)))
    ;; Look at the parent of atom-cst.
    (let* ((rev (reverse path))
           (parent (second rev)))
      (when (typep parent 'concrete-syntax-tree:cons-cst)
        ;; Case A: parent is a `(name init)` binding inside LET/LET*/etc.
        ;; AND atom-cst is the FIRST child.
        ;; AND grandparent's grandparent's head is a known binder.
        (let* ((grand (third rev))
               (great (fourth rev)))
          (when (and (typep grand 'concrete-syntax-tree:cons-cst)
                     (typep great 'concrete-syntax-tree:cons-cst))
            (let ((great-head (concrete-syntax-tree:first great)))
              (when (and (typep great-head 'concrete-syntax-tree:atom-cst)
                         (let ((s (concrete-syntax-tree:raw great-head)))
                           (and (symbolp s)
                                (member (symbol-name s)
                                        '("LET" "LET*" "SYMBOL-MACROLET"
                                          "FLET" "LABELS"
                                          "MACROLET")
                                        :test #'string=))))
                ;; And atom-cst is first child of parent.
                (let ((kids (cst-children parent)))
                  (when (and kids
                             (eq (first kids) atom-cst)
                             ;; And parent is a binding (member of grand's children)
                             (member parent (cst-children grand)))
                    (return-from cst-binder-occurrence-range
                      (cons (car (concrete-syntax-tree:source atom-cst))
                            (cdr (concrete-syntax-tree:source atom-cst))))))))))
        ;; Case B: parent is a lambda list (children of LAMBDA, FLET binding,
        ;; LABELS binding, DEFUN). E.g. `(lambda (x y) ...)`, `(defun f (x) ...)`.
        ;; The lambda-list is the second element of LAMBDA / DEFUN /
        ;; (binding for FLET/LABELS).
        (when (cst-atom-in-lambda-list-p root atom-cst)
          (return-from cst-binder-occurrence-range
            (cons (car (concrete-syntax-tree:source atom-cst))
                  (cdr (concrete-syntax-tree:source atom-cst)))))
        ;; Case C: DESTRUCTURING-BIND / MULTIPLE-VALUE-BIND vars.
        (when (cst-atom-in-binder-list-p root atom-cst)
          (return-from cst-binder-occurrence-range
            (cons (car (concrete-syntax-tree:source atom-cst))
                  (cdr (concrete-syntax-tree:source atom-cst)))))
        ;; Case D: DOLIST / DOTIMES — `(dolist (var list) body)`.
        (when (cst-atom-is-do-binder-p root atom-cst)
          (return-from cst-binder-occurrence-range
            (cons (car (concrete-syntax-tree:source atom-cst))
                  (cdr (concrete-syntax-tree:source atom-cst))))))))
  nil)

(defun lambda-list-keyword-name-p (name)
  (and (symbolp name)
       (member (symbol-name name)
               '("&OPTIONAL" "&KEY" "&REST" "&BODY" "&AUX"
                 "&ALLOW-OTHER-KEYS" "&WHOLE" "&ENVIRONMENT")
               :test #'string=)))

(defun cst-head-symbol-name (cst)
  "If CST is a CONS-CST whose first child is an atom-cst with a symbol
RAW, return its SYMBOL-NAME (string). Otherwise NIL."
  (when (typep cst 'concrete-syntax-tree:cons-cst)
    (let ((h (concrete-syntax-tree:first cst)))
      (when (typep h 'concrete-syntax-tree:atom-cst)
        (let ((s (concrete-syntax-tree:raw h)))
          (when (symbolp s) (symbol-name s)))))))

(defun cst-atom-in-lambda-list-p (root atom-cst)
  "True if ATOM-CST is a parameter name in a lambda-list belonging to
LAMBDA / DEFUN / DEFMACRO / DEFMETHOD / FLET / LABELS / MACROLET. Skips
lambda-list keyword symbols (&OPTIONAL etc.) and default-value forms."
  (when (lambda-list-keyword-name-p (concrete-syntax-tree:raw atom-cst))
    (return-from cst-atom-in-lambda-list-p nil))
  (dolist (p (cst-ancestors root atom-cst))
    (let ((opname (cst-head-symbol-name p)))
      (when opname
        (cond
          ;; LAMBDA: lambda-list is the second child.
          ;; DEFUN / DEFMACRO / DEFMETHOD: third child.
          ((member opname '("LAMBDA" "DEFUN" "DEFMACRO" "DEFMETHOD")
                   :test #'string=)
           (let* ((kids (cst-children p))
                  (ll (if (string= opname "LAMBDA") (second kids) (third kids))))
             (when (and ll (atom-under-cst-skipping-defaults-p ll atom-cst))
               (return-from cst-atom-in-lambda-list-p t))))
          ;; FLET / LABELS / MACROLET: each binding is (name (ll) body…).
          ((member opname '("FLET" "LABELS" "MACROLET") :test #'string=)
           (let ((bindings-list (second (cst-children p))))
             (when (typep bindings-list 'concrete-syntax-tree:cons-cst)
               (dolist (binding (cst-children bindings-list))
                 (when (typep binding 'concrete-syntax-tree:cons-cst)
                   (let ((ll (second (cst-children binding))))
                     (when (and ll (atom-under-cst-skipping-defaults-p
                                    ll atom-cst))
                       (return-from cst-atom-in-lambda-list-p t)))))))))))))

(defun atom-under-cst-skipping-defaults-p (lambda-list-cst atom-cst)
  "True if ATOM-CST is one of the parameter-name positions of LAMBDA-LIST-CST,
ignoring default-value forms.

Lambda list shape (simplified):
  (req1 req2 &optional (opt1 default) (opt2 default) &rest r &key (k1 default))

A parameter name is at the first position of a `(name default)` cons,
or is a bare symbol immediately at top level of the lambda-list."
  (when (typep lambda-list-cst 'concrete-syntax-tree:cons-cst)
    (dolist (item (cst-children lambda-list-cst))
      (cond
        ;; Bare symbol at top level — that's a parameter name.
        ((and (typep item 'concrete-syntax-tree:atom-cst)
              (eq item atom-cst))
         (return-from atom-under-cst-skipping-defaults-p t))
        ;; (name default) form — parameter is the first child.
        ((typep item 'concrete-syntax-tree:cons-cst)
         (let ((first-child (first (cst-children item))))
           (when (and (typep first-child 'concrete-syntax-tree:atom-cst)
                      (eq first-child atom-cst))
             (return-from atom-under-cst-skipping-defaults-p t)))))))
  nil)

(defun cst-atom-in-binder-list-p (root atom-cst)
  "True if ATOM-CST is a name in a DESTRUCTURING-BIND or
MULTIPLE-VALUE-BIND binder list."
  (let ((path (cst-ancestors root atom-cst)))
    (loop for (p . rest) on path
          when (and (typep p 'concrete-syntax-tree:cons-cst) rest)
            do (let ((head (concrete-syntax-tree:first p)))
                 (when (typep head 'concrete-syntax-tree:atom-cst)
                   (let ((opname (concrete-syntax-tree:raw head)))
                     (when (and (symbolp opname)
                                (member (symbol-name opname)
                                        '("DESTRUCTURING-BIND"
                                          "MULTIPLE-VALUE-BIND")
                                        :test #'string=))
                       ;; Binder list is the second child.
                       (let* ((kids (cst-children p))
                              (binder-list (second kids)))
                         (when (and binder-list
                                    (cst-atom-anywhere-under-p
                                     binder-list atom-cst))
                           (return-from cst-atom-in-binder-list-p t))))))))
    nil))

(defun cst-atom-anywhere-under-p (root target)
  "True if TARGET is anywhere in ROOT's subtree, including ROOT itself."
  (cond ((eq root target) t)
        ((typep root 'concrete-syntax-tree:cons-cst)
         (some (lambda (k) (cst-atom-anywhere-under-p k target))
               (cst-children root)))
        (t nil)))

(defun cst-atom-is-do-binder-p (root atom-cst)
  "True if ATOM-CST is the binder name in a DOLIST/DOTIMES form:
`(dolist (var list-form) body)` — VAR is the binder."
  (let ((path (cst-ancestors root atom-cst)))
    (loop for (p . rest) on path
          when (and (typep p 'concrete-syntax-tree:cons-cst) rest)
            do (let ((head (concrete-syntax-tree:first p)))
                 (when (typep head 'concrete-syntax-tree:atom-cst)
                   (let ((opname (concrete-syntax-tree:raw head)))
                     (when (and (symbolp opname)
                                (member (symbol-name opname)
                                        '("DOLIST" "DOTIMES")
                                        :test #'string=))
                       ;; Spec is the second child: `(var list-form)`.
                       (let* ((kids (cst-children p))
                              (spec (second kids)))
                         (when (typep spec 'concrete-syntax-tree:cons-cst)
                           (let ((var-cst (first (cst-children spec))))
                             (when (eq var-cst atom-cst)
                               (return-from cst-atom-is-do-binder-p t))))))))))
    nil))

;;;; ---- special-declared shadowing ----

(defun atom-use-shadowed-by-special-p (root atom-cst name)
  "True if ATOM-CST is a *use* of NAME and some enclosing binder also has
an `(declare (special NAME))` — meaning the binding is special, the
reference is dynamic, lexical resolution doesn't apply.

Walks ancestors of ATOM-CST, looking for binder forms (LET/LET*/LAMBDA/
DEFUN/FLET/LABELS); for each, checks whether one of the children is a
`(declare (special ... name ...))` clause."
  (let ((path (cst-ancestors root atom-cst)))
    (loop for cst in path
          when (and (typep cst 'concrete-syntax-tree:cons-cst)
                    (let ((head (concrete-syntax-tree:first cst)))
                      (and (typep head 'concrete-syntax-tree:atom-cst)
                           (let ((s (concrete-syntax-tree:raw head)))
                             (and (symbolp s)
                                  (member (symbol-name s)
                                          '("LET" "LET*" "LAMBDA" "DEFUN"
                                            "FLET" "LABELS"
                                            "MULTIPLE-VALUE-BIND"
                                            "DESTRUCTURING-BIND")
                                          :test #'string=))))))
            do (when (cst-binder-has-special-decl-p cst name)
                 (return-from atom-use-shadowed-by-special-p t)))
    nil))

(defun cst-head-name= (cst expected-name)
  (let ((n (cst-head-symbol-name cst)))
    (and n (string= n expected-name))))

(defun cst-binder-has-special-decl-p (binder-cst name)
  "True if BINDER-CST's body contains `(declare (special ... NAME ...))`."
  (dolist (child (cst-children binder-cst))
    (when (cst-head-name= child "DECLARE")
      (dolist (clause (rest (cst-children child)))
        (when (cst-head-name= clause "SPECIAL")
          (dolist (n (rest (cst-children clause)))
            (when (and (typep n 'concrete-syntax-tree:atom-cst)
                       (eq (concrete-syntax-tree:raw n) name))
              (return-from cst-binder-has-special-decl-p t))))))))

;;;; ---- symbol-macrolet detection ----

(defun atom-under-symbol-macrolet-p (root atom-cst name)
  "True if NAME is bound by an enclosing SYMBOL-MACROLET. We punt on
symbol-macros: the binder is structurally a name but semantically a
macro-introduced rewrite, and asking 'where is the binder' is the wrong
question. Phase 2 routes these to swank, which can show the expansion."
  (declare (ignore atom-cst))
  (labels ((scan (cst)
             (when (typep cst 'concrete-syntax-tree:cons-cst)
               (let ((head (concrete-syntax-tree:first cst)))
                 (when (and (typep head 'concrete-syntax-tree:atom-cst)
                            (let ((s (concrete-syntax-tree:raw head)))
                              (and (symbolp s)
                                   (string= (symbol-name s) "SYMBOL-MACROLET"))))
                   ;; Bindings are second child: ((name1 expansion1) ...)
                   (let* ((kids (cst-children cst))
                          (bindings (second kids)))
                     (when (typep bindings 'concrete-syntax-tree:cons-cst)
                       (dolist (b (cst-children bindings))
                         (when (typep b 'concrete-syntax-tree:cons-cst)
                           (let ((bname (first (cst-children b))))
                             (when (and (typep bname 'concrete-syntax-tree:atom-cst)
                                        (eq (concrete-syntax-tree:raw bname) name))
                               (return-from atom-under-symbol-macrolet-p t)))))))))
               (dolist (k (cst-children cst))
                 (scan k)))))
    (scan root))
  nil)
