(in-package #:swank-lsp/tests)

;;;; Unit tests for the in-memory document store and the symbol /
;;;; prefix extraction helpers.

(in-suite document-suite)

(test store-and-lookup
  (swank-lsp:reset-document-store)
  (let ((d (swank-lsp::make-document
            :uri "file:///tmp/x.lisp"
            :text "hello"
            :version 1
            :language-id "lisp")))
    (swank-lsp::store-document d)
    (is (= 1 (swank-lsp:document-count)))
    (is (eq d (swank-lsp::lookup-document "file:///tmp/x.lisp")))
    (is (swank-lsp::remove-document "file:///tmp/x.lisp"))
    (is (= 0 (swank-lsp:document-count)))))

(test extract-symbol-at-basics
  ;; cursor on each char of "list"
  (let ((s "(list 1 2)"))
    (loop for off from 1 to 4 do
      (is (string= "list" (swank-lsp::extract-symbol-at s off))
          "off=~A" off))
    ;; cursor exactly at offset 5 (just past 't') still considered "at" the symbol
    (is (string= "list" (swank-lsp::extract-symbol-at s 5)))
    ;; cursor at the open paren
    (is (null (swank-lsp::extract-symbol-at s 0)))))

(test extract-symbol-package-qualified
  (let ((s "(swank-lsp:start-server)"))
    (is (string= "swank-lsp:start-server"
                 (swank-lsp::extract-symbol-at s 5)))
    (is (string= "swank-lsp:start-server"
                 (swank-lsp::extract-symbol-at s 15)))))

(test extract-prefix-at
  (let ((s "(forma"))
    ;; offset 6 is end of buffer; prefix is "forma"
    (is (string= "forma" (swank-lsp::extract-prefix-at s 6)))
    ;; offset 1 is just after the (
    (is (string= "" (swank-lsp::extract-prefix-at s 1)))))

(test parse-in-package-keyword
  (is (string-equal "MY-PKG"
                    (swank-lsp::parse-in-package "(in-package :my-pkg)"))))

(test parse-in-package-uninterned
  (is (string-equal "MY-PKG"
                    (swank-lsp::parse-in-package "(in-package #:my-pkg)"))))

(test parse-in-package-string
  (is (string= "FOO"
               (swank-lsp::parse-in-package "(in-package \"FOO\")"))))

(test parse-in-package-with-leading-comment-form
  ;; The simple scanner doesn't truly skip comments -- but if the
  ;; in-package is the first paren-form we hit, it should still find it.
  (is (string-equal "BAR"
                    (swank-lsp::parse-in-package
                     (format nil ";; preface~%(in-package :bar)")))))

(test use-default-package-for-extension-falls-back
  ;; Per-extension default applies when the doc has no (in-package ...).
  (let ((swank-lsp::*default-package-for-extension* (make-hash-table :test 'equal)))
    (swank-lsp:use-default-package-for-extension "elp" "mediaserver")
    (let ((doc (swank-lsp::make-document
                :uri "file:///x/foo.elp"
                :text "(some-form 1 2)"
                :version 1
                :language-id "elp")))
      (is (string= "mediaserver"
                   (swank-lsp::current-package-for-document doc))))))

(test use-default-package-for-extension-accepts-leading-dot
  (let ((swank-lsp::*default-package-for-extension* (make-hash-table :test 'equal)))
    (swank-lsp:use-default-package-for-extension ".ELP" "foo")
    (let ((doc (swank-lsp::make-document
                :uri "file:///x/y.elp" :text "" :version 1 :language-id "elp")))
      (is (string= "foo" (swank-lsp::current-package-for-document doc))))))

(test explicit-in-package-beats-extension-default
  ;; If the doc has (in-package ...), the per-extension default is ignored.
  (let ((swank-lsp::*default-package-for-extension* (make-hash-table :test 'equal)))
    (swank-lsp:use-default-package-for-extension "elp" "mediaserver")
    (let ((doc (swank-lsp::make-document
                :uri "file:///x/foo.elp"
                :text "(in-package :explicit-pkg)"
                :version 1
                :language-id "elp")))
      (is (string-equal "EXPLICIT-PKG"
                        (swank-lsp::current-package-for-document doc))))))

(test register-byte-stream-translator-roundtrip
  (let ((swank-lsp::*byte-stream-translators* (make-hash-table :test 'equal)))
    (swank-lsp:register-byte-stream-translator
     ".upper" (lambda (uri text) (declare (ignore uri)) (string-upcase text)))
    (is (string= "HELLO" (swank-lsp::apply-byte-stream-translator
                          "file:///x/y.upper" "hello")))))
