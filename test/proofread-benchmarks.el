;;; proofread-benchmarks.el --- Manual benchmarks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Manual performance comparisons for Proofread.  Run the point lookup
;; benchmark with:
;;
;; nix run .#emacs31-with-proofread -- --batch \
;;   -l ./test/proofread-benchmarks.el \
;;   -f proofread-benchmark-diagnostic-at-point

;;; Code:

(require 'benchmark)
(require 'cl-lib)
(require 'proofread)

(defun proofread-benchmark--median (numbers)
  "Return the median of nonempty NUMBERS."
  (let* ((numbers (sort (copy-sequence numbers) #'<))
         (length (length numbers))
         (middle (/ length 2)))
    (if (cl-oddp length)
        (nth middle numbers)
      (/ (+ (nth (1- middle) numbers)
            (nth middle numbers))
         2.0))))

(defun proofread-benchmark--diagnostic-at-point-case
    (diagnostic-count)
  "Benchmark point lookup among DIAGNOSTIC-COUNT diagnostics."
  (with-temp-buffer
    (insert (make-string (1+ (* diagnostic-count 2)) ?x))
    (let ((proofread-auto-check nil)
          diagnostics
          measurements)
      (proofread-mode 1)
      (dotimes (index diagnostic-count)
        (let ((beg (1+ (* index 2))))
          (push
           (list :beg beg :end (1+ beg) :text "x"
                 :kind 'style :message "Issue"
                 :suggestions nil :source 'benchmark)
           diagnostics)))
      (setq proofread--diagnostics (nreverse diagnostics))
      (dolist (diagnostic proofread--diagnostics)
        (proofread--create-overlay diagnostic))
      (proofread-diagnostic-at-point 1)
      (dotimes (_ 5)
        (garbage-collect)
        (push
         (benchmark-run 200
           (proofread-diagnostic-at-point 1))
         measurements))
      (setq measurements (nreverse measurements))
      (list :diagnostics diagnostic-count
            :lookups 200
            :measurements measurements
            :median-elapsed
            (proofread-benchmark--median
             (mapcar #'car measurements))))))

(defun proofread-benchmark-diagnostic-at-point ()
  "Benchmark 200 point lookups with 500 and 2,000 diagnostics."
  (interactive)
  (let (results)
    (dolist (diagnostic-count '( 500 2000))
      (let ((result
             (proofread-benchmark--diagnostic-at-point-case
              diagnostic-count)))
        (push result results)
        (princ (format "%S\n" result))))
    (nreverse results)))

(provide 'proofread-benchmarks)
;;; proofread-benchmarks.el ends here
