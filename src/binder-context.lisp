(in-package #:swank-lsp)

;;;; Source-walking for the lexical type-inference plan. Given a
;;;; document and a character offset on a binder name, find:
;;;;   - the kind of binding form (let, let*, mvb, lambda/defun param)
;;;;   - the init expression, if any
;;;;   - the lexicals visible at that point from enclosing scopes
;;;;   - any in-body (declare (type ...)) decls relevant to those names
;;;;
;;;; All four pieces feed COMPILE-DERIVED-TYPE-OF in the next commit's
;;;; hover wiring. This file is impl-agnostic -- pure CL on top of
;;;; cl-scope-resolver's CST helpers and concrete-syntax-tree's API.
;;;;
;;;; The walker is intentionally narrow in v1: it recognises the
;;;; canonical binder shapes (LET / LET* / MULTIPLE-VALUE-BIND /
;;;; LAMBDA / DEFUN) and falls through to :OTHER otherwise. Adding
;;;; DOLIST / LOOP / DESTRUCTURING-BIND is straightforward but each
;;;; needs its own shape rule; we file them as follow-ups so the
;;;; first pass ships on the user's headline case.

(defstruct binder-info
  name              ;; symbol
  kind              ;; :let / :let* / :mvb / :lambda-param / :defun-param / :other
  binder-start      ;; integer, char offset of the name's first char
  binder-end        ;; integer, char offset of the name's end (exclusive)
  init-form         ;; sexp or NIL (nil for params and unhandled kinds)
  mvb-index         ;; integer or NIL (which value position for :mvb)
  cst-path)         ;; list of CST nodes, top-form first, binder-name last

(defun cst-children (cst)
  "Return the immediate children of a CST node as a list, or NIL for
atoms. Walks the cons-cst spine, stopping at non-cons tails."
  (when (typep cst 'concrete-syntax-tree:cons-cst)
    (loop for c = cst then (concrete-syntax-tree:rest c)
          while (typep c 'concrete-syntax-tree:cons-cst)
          collect (concrete-syntax-tree:first c))))

(defun cst-covers-p (cst offset)
  (multiple-value-bind (s e) (cl-scope-resolver:cst-source-range cst)
    (and s e (<= s offset) (< offset e))))

(defun cst-path-to-offset (top-csts offset)
  "Return a list of CST nodes from outermost top-level form down to
the deepest node covering OFFSET. NIL if no top-form covers OFFSET."
  (loop for top in top-csts
        when (cst-covers-p top offset)
          return (descend-cst top offset (list top))))

(defun descend-cst (cst offset acc)
  (let ((child (loop for c in (cst-children cst)
                     when (cst-covers-p c offset)
                       return c)))
    (cond
      (child (descend-cst child offset (cons child acc)))
      (t     (nreverse acc)))))

(defun cst-as-sexp (cst)
  (concrete-syntax-tree:raw cst))

(defun cst-head-symbol (cst)
  "If CST is a cons-cst whose first child is a symbol, return that
symbol. Otherwise NIL."
  (when (typep cst 'concrete-syntax-tree:cons-cst)
    (let ((first (cst-as-sexp (concrete-syntax-tree:first cst))))
      (and (symbolp first) first))))

;;;; Binder identification

(defun binder-info-at (doc offset)
  "Look up the binder at OFFSET in DOC. Returns a BINDER-INFO if the
cursor sits on a recognised lexical binder, NIL otherwise. NIL means
\"don't infer a type here\" -- the hover handler degrades cleanly to
the existing arglist + docstring path.

Uses the document's cached cl-scope-resolver analysis to confirm the
position is on a LOCAL provenance, then re-reads the surrounding
top-level form into a CST to extract structural context. The CST
read is cheap and not cached yet; if profiling shows it's hot, the
document struct can grow a CST cache parallel to ANALYSIS."
  (let* ((analysis (and doc (ensure-document-analysis doc)))
         (occ (and analysis (occurrence-covering analysis offset)))
         (prov (and occ (cl-scope-resolver:occurrence-provenance occ))))
    (when (and prov (cl-scope-resolver:local-p prov))
      (let* ((text (document-text doc))
             (csts (handler-case (cl-scope-resolver:cst-from-string text)
                     (error () nil)))
             (path (and csts (cst-path-to-offset csts offset))))
        (when path
          (build-binder-info path occ))))))

(defun build-binder-info (path occ)
  "Given the CST PATH down to a name node, classify the surrounding
binding form and extract init-form / kind / index."
  (let* ((name-cst (car (last path)))
         (name-sexp (cst-as-sexp name-cst)))
    (multiple-value-bind (start end) (cl-scope-resolver:cst-source-range name-cst)
      (declare (ignore start end))
      (multiple-value-bind (kind init mvb-index)
          (classify-binding-context path name-cst)
        (when (and (symbolp name-sexp) kind)
          (make-binder-info
           :name        name-sexp
           :kind        kind
           :binder-start (cl-scope-resolver:occurrence-start occ)
           :binder-end   (cl-scope-resolver:occurrence-end occ)
           :init-form   init
           :mvb-index   mvb-index
           :cst-path    path))))))

(defun classify-binding-context (path name-cst)
  "Look at fixed positions in PATH (top-form first, NAME-CST last)
to recognise a known binding-form shape around NAME-CST. Returns
(VALUES KIND INIT-FORM MVB-INDEX). KIND is NIL when nothing matches
-- caller treats that as 'no inference here'."
  (declare (ignore name-cst))
  (let* ((n (length path))
         (parent       (and (>= n 2) (nth (- n 2) path)))
         (grandparent  (and (>= n 3) (nth (- n 3) path)))
         (great-gp     (and (>= n 4) (nth (- n 4) path)))
         (last         (nth (1- n) path)))
    (cond
      ;; (let ((NAME INIT) ...) BODY)
      ;; path tail: ... let-form, bindings-list, binding-pair, NAME
      ((and great-gp grandparent parent
            (let ((head (cst-head-symbol great-gp)))
              (or (eq head 'cl:let) (eq head 'cl:let*)))
            (let-form-children-match-p great-gp grandparent)
            (binding-pair-position-p grandparent parent)
            (eq last (concrete-syntax-tree:first parent)))
       (let ((kind (if (eq (cst-head-symbol great-gp) 'cl:let) :let :let*))
             (init (binding-pair-init parent)))
         (values kind init nil)))
      ;; (multiple-value-bind (N1 N2 ...) VALUES-FORM body)
      ;; path tail: ... mvb-form, names-list, NAME
      ((and grandparent parent
            (eq (cst-head-symbol grandparent) 'cl:multiple-value-bind)
            (mvb-names-position-p grandparent parent))
       (let ((idx (position last (cst-children parent)))
             (vals (mvb-values-form-cst grandparent)))
         (when (and idx vals)
           (values :mvb (cst-as-sexp vals) idx))))
      ;; (lambda (P1 P2 ...) body)
      ;; path tail: ... lambda-form, params-list, NAME
      ((and grandparent parent
            (eq (cst-head-symbol grandparent) 'cl:lambda)
            (lambda-params-position-p grandparent parent)
            (member last (cst-children parent)))
       (values :lambda-param nil nil))
      ;; (defun FOO (P1 P2 ...) body)
      ;; path tail: ... defun-form, params-list, NAME
      ((and grandparent parent
            (eq (cst-head-symbol grandparent) 'cl:defun)
            (defun-params-position-p grandparent parent)
            (member last (cst-children parent)))
       (values :defun-param nil nil))
      (t (values nil nil nil)))))

;;;; Shape predicates -- check that a child sits at the canonical
;;;; position within its parent. CST children list ordering matches
;;;; source order; we use raw indexing rather than sexp-level
;;;; pattern matching to keep this honest about tree shape.

(defun let-form-children-match-p (let-cst bindings-cst)
  "True if BINDINGS-CST is the second child of LET-CST (i.e. the
canonical bindings list slot)."
  (let ((children (cst-children let-cst)))
    (and (cdr children) (eq (second children) bindings-cst))))

(defun binding-pair-position-p (bindings-cst pair-cst)
  (member pair-cst (cst-children bindings-cst)))

(defun mvb-names-position-p (mvb-cst names-cst)
  (let ((children (cst-children mvb-cst)))
    (and (cdr children) (eq (second children) names-cst))))

(defun lambda-params-position-p (lambda-cst params-cst)
  (let ((children (cst-children lambda-cst)))
    (and (cdr children) (eq (second children) params-cst))))

(defun defun-params-position-p (defun-cst params-cst)
  (let ((children (cst-children defun-cst)))
    (and (cddr children) (eq (third children) params-cst))))

(defun binding-pair-init (binding-pair-cst)
  "Given the binding pair (NAME INIT), return the init sexp, or NIL
for the (NAME) shape."
  (let ((children (cst-children binding-pair-cst)))
    (when (and children (cdr children))
      (cst-as-sexp (second children)))))

(defun mvb-values-form-cst (mvb-cst)
  (let ((children (cst-children mvb-cst)))
    (and (cddr children) (third children))))

;;;; Enclosing-lexicals + declares
;;;;
;;;; Both walk the CST PATH outward from the binder and inspect each
;;;; ancestor that's a binding form, collecting names visible at our
;;;; position and any (declare (type X NAME)) decls in scope.

(defun enclosing-lexicals (binder-info)
  "Return the list of symbols visible as lexicals at the binder's
position, from outer scopes. The binder itself is NOT included; for
a let* the earlier siblings ARE included.

Used to populate the synthetic lambda's parameter list so the
init-form's free variables are bound when COMPILE sees them."
  (let ((path (binder-info-cst-path binder-info))
        (acc  '()))
    (loop for tail on (reverse path)
          for parent = (second tail)
          for grandparent = (third tail)
          while parent
          do (collect-lexicals-from-form parent grandparent (first tail)
                                         binder-info
                                         (lambda (name)
                                           (pushnew name acc))))
    (remove (binder-info-name binder-info) acc)))

(defun collect-lexicals-from-form (parent grandparent current binder add)
  "Inspect a single ancestor PARENT/GRANDPARENT pair in the path.
If GRANDPARENT names a binding form, add the names it introduces
that are visible at our position to the accumulator via ADD."
  (declare (ignore current))
  (when (and grandparent (typep grandparent 'concrete-syntax-tree:cons-cst))
    (let ((head (cst-head-symbol grandparent)))
      (cond
        ;; (let ((N I) ...) BODY)
        ((eq head 'cl:let)
         (when (let-bindings-list-p parent grandparent)
           (when (eq (binder-info-kind binder) :let)
             ;; In a let, our binder's siblings in the bindings list
             ;; are NOT visible to its init-form -- skip them.
             nil))
         (when (in-let-body-p parent grandparent)
           (dolist (name (let-binder-names grandparent)) (funcall add name))))
        ((eq head 'cl:let*)
         (when (let-bindings-list-p parent grandparent)
           (dolist (name (let*-prior-binders grandparent parent binder))
             (funcall add name))))
        (t
         (when (or (eq head 'cl:lambda) (eq head 'cl:defun))
           (dolist (name (lambda-or-defun-params grandparent head))
             (funcall add name))))))))

(defun let-bindings-list-p (cst grandparent)
  (let ((gp-children (cst-children grandparent)))
    (and (cdr gp-children) (eq cst (second gp-children)))))

(defun in-let-body-p (cst grandparent)
  (let ((gp-children (cst-children grandparent)))
    (and (cddr gp-children)
         (member cst (cddr gp-children)))))

(defun let-binder-names (let-cst)
  (let* ((children (cst-children let-cst))
         (bindings (and (cdr children) (second children))))
    (loop for pair in (cst-children bindings)
          for first = (and (typep pair 'concrete-syntax-tree:cons-cst)
                           (cst-as-sexp (concrete-syntax-tree:first pair)))
          when (symbolp first) collect first)))

(defun let*-prior-binders (let*-cst bindings-cst binder)
  "Names bound earlier in the same let* than BINDER's position."
  (declare (ignore let*-cst))
  (let ((mine (binder-info-name binder)))
    (loop for pair in (cst-children bindings-cst)
          for first = (and (typep pair 'concrete-syntax-tree:cons-cst)
                           (cst-as-sexp (concrete-syntax-tree:first pair)))
          while (or (not (symbolp first)) (not (eq first mine)))
          when (symbolp first) collect first)))

(defun lambda-or-defun-params (form head)
  (let* ((children (cst-children form))
         (params-cst (cond
                       ((eq head 'cl:lambda) (and (cdr children) (second children)))
                       ((eq head 'cl:defun)  (and (cddr children) (third children))))))
    (when params-cst
      (loop for c in (cst-children params-cst)
            for sym = (cst-as-sexp c)
            when (and (symbolp sym)
                      (not (member sym lambda-list-keywords)))
              collect sym))))

(defun local-declares-for (binder-info names)
  "Collect (declare (type ...)) specs in scope at BINDER-INFO that
mention any of NAMES. Returns a list of decl specs to forward into
the synthetic lambda. Both abbreviated form '(fixnum x)' and the
explicit form '(type fixnum x)' are recognised."
  (let ((acc '())
        (path (binder-info-cst-path binder-info)))
    (loop for cst in path
          when (typep cst 'concrete-syntax-tree:cons-cst)
            do (let ((head (cst-head-symbol cst)))
                 (when (and head
                            (member head '(cl:defun cl:lambda cl:let cl:let*
                                           cl:multiple-value-bind cl:locally)))
                   (dolist (decl (find-declares-in-body cst head))
                     (dolist (spec (decl-relevant-specs decl names))
                       (push spec acc))))))
    (delete-duplicates (nreverse acc) :test #'equal)))

(defun find-declares-in-body (form-cst head)
  "Return the list of decl specs (as raw sexps) inside this binding
form's body. We accept declares appearing in the canonical body
position of each form head."
  (let* ((children (cst-children form-cst))
         (body-start (case head
                       (cl:defun  3)
                       (cl:lambda 2)
                       (cl:let    2)
                       (cl:let*   2)
                       (cl:multiple-value-bind 3)
                       (cl:locally 1))))
    (loop for child in (and body-start (nthcdr body-start children))
          for sexp = (cst-as-sexp child)
          while (and (consp sexp) (eq (car sexp) 'cl:declare))
          append (cdr sexp))))

(defun decl-relevant-specs (decl names)
  "DECL is a single declaration spec, like (FIXNUM X) or (TYPE LIST Y).
Return a list of decl specs (in canonical (TYPE T NAMES) form), filtered
to only those whose names overlap NAMES."
  (when (consp decl)
    (let ((head (first decl)))
      (cond
        ;; (TYPE T NAMES...)
        ((eq head 'cl:type)
         (let* ((type-spec (second decl))
                (decl-names (cddr decl))
                (relevant (intersection decl-names names)))
           (when relevant
             (list `(type ,type-spec ,@relevant)))))
        ;; Abbreviated: (TYPENAME NAMES...) where TYPENAME is a CL type.
        ;; We don't validate -- if the user wrote it, SBCL will tell us.
        ((symbolp head)
         (let* ((decl-names (cdr decl))
                (relevant (intersection decl-names names)))
           (when relevant
             (list `(type ,head ,@relevant)))))
        (t nil)))))
