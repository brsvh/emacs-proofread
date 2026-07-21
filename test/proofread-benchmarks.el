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
;;
;; Count the sorts used by request conflict detection with:
;;
;; nix run .#emacs31-with-proofread -- --batch \
;;   -l ./test/proofread-benchmarks.el \
;;   -f proofread-benchmark-request-conflict-sorts

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

(defun proofread-benchmark--conflict-work (owner beg end id)
  "Return scheduled work owned by OWNER from BEG to END, named ID."
  (proofread--make-scheduled-work
   (list :id id
         :checker-owner owner
         :beg beg
         :end end)
   id id))

(defun proofread-benchmark--request-conflict-sort-case
    (owner-count request-count candidate-count)
  "Return one conflict-sort measurement for OWNER-COUNT owner buckets.
Each owner has REQUEST-COUNT new requests and CANDIDATE-COUNT pending
candidates."
  (let (requests candidates)
    (dotimes (owner-index owner-count)
      (let ((owner (list :checker-name owner-index)))
        (dotimes (request-index request-count)
          (let* ((range-index (% request-index candidate-count))
                 (beg (1+ (* range-index 4))))
            (push (proofread-benchmark--conflict-work
                   owner beg (+ beg 2)
                   (list 'request owner-index request-index))
                  requests)))
        (dotimes (candidate-index candidate-count)
          (let ((beg (1+ (* candidate-index 4))))
            (push (proofread-benchmark--conflict-work
                   owner beg (+ beg 2)
                   (list 'candidate owner-index candidate-index))
                  candidates)))))
    (let ((original-sort (symbol-function 'sort))
          (sort-count 0)
          conflicts)
      (cl-letf (((symbol-function 'sort)
                 (lambda (sequence predicate)
                   (setq sort-count (1+ sort-count))
                   (funcall original-sort sequence predicate))))
        (setq conflicts
              (proofread--conflicting-request-table
               requests candidates)))
      (list :owners owner-count
            :requests (* owner-count request-count)
            :candidates (* owner-count candidate-count)
            :conflicts (hash-table-count conflicts)
            :sorts sort-count))))

(defun proofread-benchmark-request-conflict-sorts ()
  "Show that conflict sorting scales by owner, not request count.
This benchmark counts deterministic sorting operations instead of
comparing elapsed wall-clock time.  Signal an error if increasing the
request count changes that count or if owner buckets do not scale it
linearly."
  (interactive)
  (let* ((one-request
          (proofread-benchmark--request-conflict-sort-case 1 1 64))
         (many-requests
          (proofread-benchmark--request-conflict-sort-case 1 128 64))
         (many-owners
          (proofread-benchmark--request-conflict-sort-case 4 128 64))
         (base-sorts (plist-get one-request :sorts)))
    (cl-assert (> base-sorts 0))
    (cl-assert (= (plist-get many-requests :sorts)
                  base-sorts))
    (cl-assert (= (plist-get many-owners :sorts)
                  (* 4 base-sorts)))
    (dolist (result (list one-request many-requests many-owners))
      (princ (format "%S\n" result)))
    (list one-request many-requests many-owners)))

(provide 'proofread-benchmarks)
;;; proofread-benchmarks.el ends here
