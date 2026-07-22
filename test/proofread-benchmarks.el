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
;; Benchmark retained diagnostic aggregation and formatting with:
;;
;; nix run .#emacs31-with-proofread -- --batch \
;;   -l ./test/proofread-benchmarks.el \
;;   -f proofread-benchmark-diagnostic-aggregation
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
      (flymake-start)
      (cl-assert
       (= (length (flymake-diagnostics)) diagnostic-count))
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

(defun proofread-benchmark--diagnostic-aggregation-case
    (diagnostic-count)
  "Benchmark retained list construction for DIAGNOSTIC-COUNT items."
  (let (shared-diagnostics
        shared-entries
        source-aggregate
        source-diagnostics
        unique-entries
        measurements)
    (dotimes (index diagnostic-count)
      (let* ((diagnostic
              (list :beg 1 :end 2 :text "x" :kind 'style
                    :message "Issue" :suggestions '( "fixed")
                    :checker-name 'benchmark
                    :checker-ordinal index))
             (source-diagnostic
              (list :suggestions '( "fixed")
                    :checker-name
                    (format "benchmark-%d" index)))
             (unique (copy-sequence diagnostic))
             (unique-beg (1+ (* index 2))))
        (setq unique (plist-put unique :beg unique-beg))
        (setq unique (plist-put unique :end (1+ unique-beg)))
        (push diagnostic shared-diagnostics)
        (push (list diagnostic 1 2 index) shared-entries)
        (push source-diagnostic source-diagnostics)
        (push (list unique unique-beg (1+ unique-beg) index)
              unique-entries)))
    (setq shared-diagnostics (nreverse shared-diagnostics))
    (setq shared-entries (nreverse shared-entries))
    (setq source-diagnostics (nreverse source-diagnostics))
    (setq unique-entries (nreverse unique-entries))
    (setq source-aggregate
          (list :proofread-aggregate t
                :diagnostics source-diagnostics))
    (let* ((unique-result
            (proofread--aggregate-navigation-entries unique-entries))
           (shared-result
            (proofread--aggregate-navigation-entries shared-entries))
           (aggregate (caar shared-result))
           (description
            (proofread--format-diagnostic-description aggregate))
           (lines (split-string description "\n"))
           (source-records
            (proofread--diagnostic-suggestion-records source-aggregate))
           (sources (plist-get (car source-records) :sources)))
      (cl-assert (= (length unique-result) diagnostic-count))
      (cl-assert
       (equal (mapcar (lambda (entry)
                        (nth 3 entry))
                      unique-result)
              (number-sequence 0 (1- diagnostic-count))))
      (cl-assert (= (length shared-result) 1))
      (cl-assert
       (= (length (proofread--diagnostic-members aggregate))
          (length shared-diagnostics)))
      (cl-assert
       (cl-every
        #'identity
        (cl-mapcar #'eq
                   (proofread--diagnostic-members aggregate)
                   shared-diagnostics)))
      (cl-assert
       (equal (proofread--diagnostic-suggestions aggregate)
              '( "fixed")))
      (cl-assert
       (equal (proofread--diagnostic-source-labels aggregate)
              '( "benchmark")))
      (cl-assert (= (length lines) (+ diagnostic-count 12)))
      (cl-assert (equal (car lines) "Proofread diagnostic"))
      (cl-assert (equal (car (last lines)) "Sources: benchmark"))
      (cl-assert (= (length source-records) 1))
      (cl-assert (= (length sources) diagnostic-count))
      (cl-assert (equal (car sources) "benchmark-0"))
      (cl-assert
       (equal (car (last sources))
              (format "benchmark-%d" (1- diagnostic-count)))))
    (dotimes (_ 5)
      (garbage-collect)
      (push
       (benchmark-run 1
         (proofread--aggregate-navigation-entries unique-entries)
         (let ((aggregate
                (caar
                 (proofread--aggregate-navigation-entries
                  shared-entries))))
           (proofread--format-diagnostic-description aggregate))
         (proofread--diagnostic-suggestion-records source-aggregate))
       measurements))
    (setq measurements (nreverse measurements))
    (list :diagnostics diagnostic-count
          :operations 1
          :measurements measurements
          :median-elapsed
          (proofread-benchmark--median
           (mapcar #'car measurements)))))

(defun proofread-benchmark-diagnostic-aggregation ()
  "Benchmark retained construction with 500 and 2,000 diagnostics."
  (interactive)
  (let (results)
    (dolist (diagnostic-count '( 500 2000))
      (let ((result
             (proofread-benchmark--diagnostic-aggregation-case
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
