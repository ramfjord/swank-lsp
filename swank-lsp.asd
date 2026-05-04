(defsystem "swank-lsp"
  :description "A swank-backed LSP server for Common Lisp. Speaks vanilla LSP (over stdio or TCP) and dispatches requests directly to swank functions in the same image. No glue beyond the wire-shape conversion."
  :version "0.1.0"
  :author "swank-lsp contributors"
  :license "MIT"
  :depends-on ("jsonrpc"
               "jsonrpc/transport/tcp"
               "jsonrpc/transport/stdio"
               "swank"
               "yason"
               "bordeaux-threads"
               "usocket"
               "quri"
               "cl-scope-resolver")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               ;; jsonrpc-byte-fix removed: upstream PR (in tmp/jsonrpc/)
               ;; fixes the byte-vs-char read in jsonrpc/request-response
               ;; AND switches transports to binary streams. Our old
               ;; monkey-patch redefined read-message to use read-char,
               ;; which now errors on the binary streams the upstream
               ;; transport passes -- "Connection reset by peer" on every
               ;; wire test. Once the qlfile points at upstream-patched
               ;; jsonrpc, the monkey-patch is both redundant and breaks
               ;; things.
               (:file "position")
               (:file "document")
               (:file "handlers")
               (:file "server"))
  :in-order-to ((test-op (test-op "swank-lsp/tests"))))

(defsystem "swank-lsp/tests"
  :description "Wire-level integration tests for swank-lsp: opens a TCP socket, sends framed JSON-RPC, asserts on responses. Plus unit tests for the position-encoding module."
  :depends-on ("swank-lsp" "fiveam" "usocket" "yason" "bordeaux-threads")
  :pathname "tests/"
  :serial t
  :components ((:file "package")
               (:file "suite")
               (:file "client")
               (:file "position-tests")
               (:file "document-tests")
               (:file "wire-tests")
               (:file "local-definition-tests"))
  :perform (test-op (op c)
             (uiop:symbol-call :fiveam :run! (uiop:find-symbol* :all-tests :swank-lsp/tests))))
