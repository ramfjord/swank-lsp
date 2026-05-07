(in-package #:swank-lsp/tests)

;;;; Tests for the per-file indexer + project enumeration (commit 2
;;;; of the project-wide-references plan).
;;;;
;;;; Coverage:
;;;;   - index-file writes the expected rows for a small file
;;;;   - re-indexing a file replaces (not duplicates) its rows
;;;;   - in-package tracking ends up in forms.package
;;;;   - project-source-files filters by extension and respects
;;;;     git's tracked-set
;;;;   - index-project counts files indexed
;;;;
;;;; The git-dependent tests shell out to git inside a tmpdir; if
;;;; git isn't available, those signal at test time. That's fine for
;;;; this project (we require git per README).

(in-suite all-tests)

(defun fresh-tmpdir-named (label)
  (let* ((base (uiop:temporary-directory))
         (name (format nil "swank-lsp-~A-~A-~A/"
                       label (get-universal-time) (random 1000000)))
         (p (uiop:merge-pathnames* name base)))
    (ensure-directories-exist p)
    p))

(defun cleanup-tmpdir (dir)
  (uiop:delete-directory-tree (uiop:ensure-directory-pathname dir)
                              :validate t
                              :if-does-not-exist :ignore))

(defun write-test-file (root relative content)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create)
      (write-string content out))
    path))

(defun git-init-and-add (root files)
  "Initialize a git repo under ROOT and `git add` FILES (relative
strings or pathnames). Returns ROOT."
  (let ((root-string (namestring (uiop:ensure-directory-pathname root))))
    (uiop:run-program (list "git" "-C" root-string "init" "-q"))
    (uiop:run-program (list "git" "-C" root-string "config" "user.email" "test@example.com"))
    (uiop:run-program (list "git" "-C" root-string "config" "user.name" "test"))
    (when files
      (uiop:run-program
       (append (list "git" "-C" root-string "add")
               (mapcar (lambda (f)
                         (etypecase f
                           (string f)
                           (pathname (namestring f))))
                       files))))
    root))

;;;; ---- index-file basics ----

(test index-file-writes-rows
  "Indexing a simple file produces files / forms / occurrences rows."
  (let ((root (fresh-tmpdir-named "indexer")))
    (unwind-protect
         (let ((path (write-test-file
                      root "x.lisp"
                      "(in-package :cl-user)
(let ((x 1)) (list x))
")))
           (swank-lsp::with-index-connection (conn root)
             (let ((file-id (swank-lsp::index-file conn path)))
               (is (integerp file-id))
               (is (= 1 (sqlite:execute-single
                         conn "SELECT COUNT(*) FROM files")))
               ;; (in-package …) + (let …) = 2 top-level forms.
               (is (= 2 (sqlite:execute-single
                         conn "SELECT COUNT(*) FROM forms WHERE file_id=?"
                         file-id)))
               ;; Some occurrences exist — at minimum the LET, X
               ;; binder, X use, LIST, etc.
               (is (plusp (sqlite:execute-single
                           conn "SELECT COUNT(*) FROM occurrences WHERE file_id=?"
                           file-id))))))
      (cleanup-tmpdir root))))

(test index-file-replaces-existing-rows
  "Re-indexing the same file removes the prior rows (atomic
transaction). Avoid the duplication-bloat-on-resave footgun."
  (let ((root (fresh-tmpdir-named "indexer")))
    (unwind-protect
         (let ((path (write-test-file
                      root "x.lisp"
                      "(let ((x 1)) (list x))
")))
           (swank-lsp::with-index-connection (conn root)
             (swank-lsp::index-file conn path)
             (let ((forms-after-first
                     (sqlite:execute-single
                      conn "SELECT COUNT(*) FROM forms")))
               (swank-lsp::index-file conn path)
               (is (= forms-after-first
                      (sqlite:execute-single
                       conn "SELECT COUNT(*) FROM forms")))
               (is (= 1 (sqlite:execute-single
                         conn "SELECT COUNT(*) FROM files"))))))
      (cleanup-tmpdir root))))

(test index-file-tracks-in-package
  "(in-package :swank-lsp) before a defun → the defun's forms.package
is SWANK-LSP, not CL-USER."
  (let ((root (fresh-tmpdir-named "indexer")))
    (unwind-protect
         (let ((path (write-test-file
                      root "x.lisp"
                      "(in-package :swank-lsp)
(defun foo (x) x)
")))
           (swank-lsp::with-index-connection (conn root)
             (swank-lsp::index-file conn path)
             ;; The defun is the second form (after in-package).
             ;; Grab forms in start_offset order.
             (let ((packages
                     (loop for row in (sqlite:execute-to-list
                                       conn
                                       "SELECT package FROM forms
                                        ORDER BY start_offset")
                           collect (first row))))
               (is (equal '("COMMON-LISP-USER" "SWANK-LSP") packages)))))
      (cleanup-tmpdir root))))

(test index-file-missing-path-returns-nil
  "Calling index-file on a nonexistent path returns NIL (not signal),
so a project walk doesn't blow up on a stat failure."
  (let ((root (fresh-tmpdir-named "indexer")))
    (unwind-protect
         (swank-lsp::with-index-connection (conn root)
           (is (null (swank-lsp::index-file
                      conn (merge-pathnames "nonexistent.lisp" root)))))
      (cleanup-tmpdir root))))

;;;; ---- Project enumeration via git ls-files ----

(test project-source-files-uses-git
  "project-source-files returns only files git tracks, filtered by
source extension."
  (let ((root (fresh-tmpdir-named "indexer-git")))
    (unwind-protect
         (progn
           (write-test-file root "tracked.lisp" "(defun tracked () 1)")
           (write-test-file root "untracked.lisp" "(defun untracked () 1)")
           (write-test-file root "readme.md" "# unrelated")
           (git-init-and-add root '("tracked.lisp" "readme.md"))
           (let ((paths (swank-lsp::project-source-files root)))
             (is (= 1 (length paths)))
             (is (search "tracked.lisp" (namestring (first paths))))))
      (cleanup-tmpdir root))))

(test project-source-files-extensions
  "Both .lisp and .elp tracked files are returned. Other extensions
(here .md) are filtered out even when git tracks them."
  (let ((root (fresh-tmpdir-named "indexer-ext")))
    (unwind-protect
         (progn
           (write-test-file root "a.lisp" "(defun a () 1)")
           (write-test-file root "b.elp" "<%= 1 %>")
           (write-test-file root "c.md" "# md")
           (git-init-and-add root '("a.lisp" "b.elp" "c.md"))
           (let* ((paths (swank-lsp::project-source-files root))
                  (names (mapcar #'file-namestring paths)))
             (is (= 2 (length paths)))
             (is (find "a.lisp" names :test #'string=))
             (is (find "b.elp" names :test #'string=))))
      (cleanup-tmpdir root))))

;;;; ---- index-project ----

(test index-project-walks-and-indexes
  "index-project indexes every tracked source file, returns the count."
  (let ((root (fresh-tmpdir-named "indexer-proj")))
    (unwind-protect
         (progn
           (write-test-file root "a.lisp" "(defun a () 1)")
           (write-test-file root "b.lisp" "(defun b (x) x)")
           (git-init-and-add root '("a.lisp" "b.lisp"))
           (swank-lsp::with-index-connection (conn root)
             (let ((n (swank-lsp::index-project conn root)))
               (is (= 2 n))
               (is (= 2 (sqlite:execute-single
                         conn "SELECT COUNT(*) FROM files"))))))
      (cleanup-tmpdir root))))
