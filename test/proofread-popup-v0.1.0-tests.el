;;; proofread-popup-v0.1.0-tests.el --- Compatibility tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Verify that the released proofread-popup 0.1.0 source loads and uses its
;; two historical core integration helpers with the current Proofread core.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)

(setq flymake-no-changes-timeout nil)

(declare-function proofread-popup--delete "proofread-popup")

(defconst proofread-popup-v0.1.0-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the popup 0.1.0 compatibility tests.")

(defconst proofread-popup-v0.1.0-test--fixture-sha256
  "3adf85448014c3da3bc50793eab0473f67b8261ba728d7ef6cfefa7d7c732b09"
  "SHA-256 of the released proofread-popup 0.1.0 source fixture.")

(defun proofread-popup-v0.1.0-test--fixture-file ()
  "Return the released proofread-popup 0.1.0 source fixture."
  (or (getenv "PROOFREAD_POPUP_V0_1_0_FIXTURE")
      (expand-file-name
       "fixtures/proofread-popup-v0.1.0.el.in"
       proofread-popup-v0.1.0-test--directory)))

(defun proofread-popup-v0.1.0-test--fixture-digest ()
  "Return the SHA-256 of the released popup source fixture."
  (with-temp-buffer
    (insert-file-contents-literally
     (proofread-popup-v0.1.0-test--fixture-file))
    (secure-hash 'sha256 (current-buffer))))

(ert-deftest proofread-popup-v0.1.0-test-loads-with-current-core ()
  "Load the released popup 0.1.0 source with the current core."
  (should-not (featurep 'proofread-popup))
  (should
   (equal (proofread-popup-v0.1.0-test--fixture-digest)
          proofread-popup-v0.1.0-test--fixture-sha256))
  (load-file (proofread-popup-v0.1.0-test--fixture-file))
  (should (featurep 'proofread-popup))
  (should (eq (symbol-function
               'proofread--set-positive-integer-option)
              'proofread-set-positive-integer-option))
  (should (eq (symbol-function
               'proofread--report-warning-without-window)
              'proofread-report-warning-without-window))
  (with-temp-buffer
    (set (make-local-variable 'proofread-popup--buffer-name)
         " *Proofread Popup compatibility*")
    (let (warning)
      (cl-letf (((symbol-function 'posframe-delete)
                 (lambda (_buffer-or-name)
                   (error "Compatibility test failure")))
                ((symbol-function
                  'proofread-report-warning-without-window)
                 (lambda (message summary)
                   (setq warning (cons message summary)))))
        (proofread-popup--delete))
      (should
       (string-prefix-p "Proofread popup delete error: "
                        (car warning)))
      (should
       (equal (cdr warning)
              "popup cleanup failed; see *Warnings*")))))

(provide 'proofread-popup-v0.1.0-tests)
;;; proofread-popup-v0.1.0-tests.el ends here
