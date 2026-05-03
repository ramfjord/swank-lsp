(in-package #:cl-scope-resolver/tests)

(def-suite all-tests
  :description "All cl-scope-resolver tests.")

(in-suite all-tests)

(defun run-corpus-case (case)
  "Run RESOLVE on CASE and check against expectation. Returns:
  (values OK-P actual-kind actual-start actual-end actual-reason
          expected-kind expected-start expected-end)"
  (multiple-value-bind (source offset) (corpus-case-source-and-offset case)
    (multiple-value-bind (kind start end reason)
        (cl-scope-resolver:resolve source offset)
      (let ((expected-kind (getf case :expect))
            (expected-start nil)
            (expected-end nil))
        (when (eq expected-kind :local)
          (multiple-value-bind (s e)
              (expected-binder-range source (getf case :binder))
            (setf expected-start s expected-end e)))
        (let ((ok-p
                (and (eq kind expected-kind)
                     (or (not (eq expected-kind :local))
                         (and (eql start expected-start)
                              (eql end expected-end)))
                     (or (null (getf case :reason))
                         (eq reason (getf case :reason))))))
          (values ok-p kind start end reason
                  expected-kind expected-start expected-end))))))

(test corpus
  "Run every corpus case as a single test, with per-case failure messages."
  (dolist (case *corpus*)
    (multiple-value-bind (ok-p kind start end reason
                          expected-kind expected-start expected-end)
        (run-corpus-case case)
      (declare (ignore reason))
      (is ok-p
          "case ~A: got (~S ~S ~S), expected (~S ~S ~S)~@[~%  note: ~A~]"
          (getf case :name)
          kind start end
          expected-kind expected-start expected-end
          (getf case :note)))))
