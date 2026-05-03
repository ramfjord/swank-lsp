(defsystem "cl-scope-resolver"
  :description "Lexical-scope-aware resolver for Common Lisp source ranges. Given a source string and a character offset pointing at a symbol, returns the source range of its lexical binder, or a sentinel meaning \"not local; ask elsewhere\". Pure function: no IO, no globals, no eval."
  :version "0.1.0"
  :author "swank-lsp contributors"
  :license "MIT"
  :depends-on ("eclector"
               "eclector-concrete-syntax-tree"
               "hu.dwim.walker")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "cst")
               (:file "walk")
               (:file "resolver"))
  :in-order-to ((test-op (test-op "cl-scope-resolver/tests"))))

(defsystem "cl-scope-resolver/tests"
  :description "Tests for cl-scope-resolver: corpus of (source, offset) → expected resolution."
  :depends-on ("cl-scope-resolver" "fiveam")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "corpus")
               (:file "suite"))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :all-tests :cl-scope-resolver/tests))))
