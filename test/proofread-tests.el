;;; proofread-tests.el --- Tests for proofread  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for proofread.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)

(defun proofread-test--tree-member-p (needle tree)
  "Return non-nil if NEEDLE appears anywhere in TREE."
  (cond
   ((eq needle tree) t)
   ((consp tree)
    (or (proofread-test--tree-member-p needle (car tree))
        (proofread-test--tree-member-p needle (cdr tree))))
   (t nil)))

(defun proofread-test--diagnostic ()
  "Return a sample proofread diagnostic."
  (proofread--make-diagnostic
   :beg 1
   :end 6
   :text "helo"
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions '("hello")
   :confidence 0.9
   :source 'test))

(defun proofread-test--diagnostic-for-range (beg end text)
  "Return a sample diagnostic for BEG, END, and TEXT."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions '("hello")
   :confidence 0.9
   :source 'test))

(defun proofread-test--chunk-texts (chunks)
  "Return the text payloads from CHUNKS."
  (mapcar (lambda (chunk)
            (plist-get chunk :text))
          chunks))

(defun proofread-test--wait-for (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 1.0)))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(ert-deftest proofread-test-normalize-ranges-merges-adjacent-ranges ()
  "Visible range normalization discards invalid ranges and merges duplicates."
  (should (equal (proofread--normalize-ranges
                  '((30 . 35)
                    (1 . 1)
                    (10 . 20)
                    (40 . 39)
                    (20 . 30)))
                 '((10 . 35)))))

(ert-deftest proofread-test-face-defaults-avoid-fixed-colors ()
  "Proofread faces are defined without fixed color attributes."
  (dolist (face '(proofread-face proofread-current-face))
    (should (facep face))
    (let ((spec (face-default-spec face)))
      (should-not (proofread-test--tree-member-p :foreground spec))
      (should-not (proofread-test--tree-member-p :background spec))
      (should-not (proofread-test--tree-member-p :color spec))
      (should-not (proofread-test--tree-member-p 'flyspell-incorrect spec))
      (should-not (proofread-test--tree-member-p 'flymake-error spec))
      (should-not (proofread-test--tree-member-p 'flycheck-error spec)))))

(ert-deftest proofread-test-overlay-stores-diagnostic ()
  "Created proofread overlays store ownership and diagnostic metadata."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic)))
      (setq proofread--diagnostics (list diagnostic))
      (let ((overlay (proofread--create-overlay diagnostic)))
        (should (eq (overlay-get overlay 'category) 'proofread-overlay))
        (should (eq (overlay-get overlay 'face) 'proofread-face))
        (should (equal (overlay-get overlay 'proofread-diagnostic)
                       diagnostic))
        (should (memq overlay proofread--overlays))
        (should (equal proofread--diagnostics (list diagnostic)))))))

(ert-deftest proofread-test-clear-preserves-unrelated-overlays ()
  "Clearing proofread overlays preserves unrelated overlays and diagnostics."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (setq proofread--diagnostics (list diagnostic))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-clear)
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--overlays)
      (should (equal proofread--diagnostics (list diagnostic))))))

(ert-deftest proofread-test-edit-invalidates-proofread-overlay ()
  "Editing covered text deletes only the proofread-owned overlay."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (goto-char 3)
      (insert "x")
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-disable-mode-clears-proofread-overlays ()
  "Disabling `proofread-mode' deletes proofread overlays only."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (setq proofread--diagnostics (list diagnostic))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-mode -1)
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-check-visible-collects-single-window-range ()
  "`proofread-check-visible' records the selected visible window range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-single*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello visible world")
            (proofread-mode 1)
            (cl-letf (((symbol-function 'window-start)
                       (lambda (&optional _window) 3))
                      ((symbol-function 'window-end)
                       (lambda (&optional _window _update) 16)))
              (proofread-check-visible)
              (should (equal proofread--pending-ranges '((3 . 16))))
              (should-not proofread--diagnostics)
              (should-not proofread--overlays)
              (should-not proofread--requests)
              (should (= (hash-table-count proofread--cache) 0))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-check-visible-deduplicates-multiple-windows ()
  "`proofread-check-visible' merges overlapping ranges from visible windows."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-multiple*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello visible world")
            (proofread-mode 1)
            (let* ((first-window (selected-window))
                   (second-window (split-window-right))
                   (window-ranges
                    `((,first-window . (3 . 12))
                      (,second-window . (8 . 16)))))
              (set-window-buffer second-window buffer)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional window)
                           (car (cdr (assq window window-ranges)))))
                        ((symbol-function 'window-end)
                         (lambda (&optional window _update)
                           (cdr (cdr (assq window window-ranges))))))
                (proofread-check-visible)
                (should (equal proofread--pending-ranges '((3 . 16)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-check-visible-no-window-produces-no-ranges ()
  "`proofread-check-visible' does not fall back to the whole buffer."
  (with-temp-buffer
    (insert "hello hidden world")
    (proofread-mode 1)
    (setq proofread--pending-ranges '((1 . 7)))
    (proofread-check-visible)
    (should-not proofread--pending-ranges)))

(ert-deftest proofread-test-edit-schedules-idle-work ()
  "Editing in `proofread-mode' marks pending work and schedules a timer."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((proofread-idle-delay 7)
          scheduled)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (seconds repeat function &rest args)
                   (setq scheduled (list seconds repeat function args))
                   'proofread-test-timer)))
        (insert "!")
        (should proofread--pending-work)
        (should (eq proofread--idle-timer 'proofread-test-timer))
        (should (equal scheduled
                       (list 7 nil #'proofread--idle-timer-run
                             (list (current-buffer)))))))))

(ert-deftest proofread-test-edit-does-not-call-backend-synchronously ()
  "Editing schedules work without calling the backend inline."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((proofread-backend 'mock)
          backend-calls)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread-backend-check)
                 (lambda (_request _callback &optional _backend)
                   (setq backend-calls (1+ (or backend-calls 0))))))
        (insert "!")
        (should proofread--pending-work)
        (should-not backend-calls)))))

(ert-deftest proofread-test-repeated-edits-coalesce-before-idle ()
  "Repeated edits before idle time reuse one timer and run one check."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (insert "?")
        (should (= timer-count 1))
        (should proofread--pending-work)
        (should (eq (proofread--idle-timer-run buffer) 'ran))
        (should (= visible-checks 1))
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest proofread-test-activity-after-idle-can-reschedule ()
  "Activity after an idle callback can schedule later work."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (should (eq (proofread--idle-timer-run buffer) 'ran))
        (insert "?")
        (should (= timer-count 2))
        (should (= visible-checks 1))
        (should proofread--pending-work)))))

(ert-deftest proofread-test-window-activity-marks-proofread-buffer ()
  "Window activity marks only live buffers with `proofread-mode' enabled."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-mode*"))
          (plain-buffer
           (generate-new-buffer " *proofread-window-plain*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (proofread-mode 1))
            (with-current-buffer plain-buffer
              (insert "Beta"))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format "proofread-test-window-timer-%d"
                                         timer-count)))))
              (switch-to-buffer proofread-buffer)
              (proofread--window-scroll (selected-window) (point-min))
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (switch-to-buffer plain-buffer)
              (proofread--window-scroll (selected-window) (point-min))
              (with-current-buffer plain-buffer
                (should-not proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)
        (kill-buffer plain-buffer)))))

(ert-deftest proofread-test-disable-mode-clears-scheduled-work ()
  "Disabling `proofread-mode' clears pending work and timer state."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_seconds _repeat _function &rest _args)
                 'proofread-test-timer)))
      (insert "!")
      (should proofread--pending-work)
      (should proofread--idle-timer)
      (proofread-mode -1)
      (should-not proofread--pending-work)
      (should-not proofread--idle-timer)
      (should-not (memq #'proofread--after-change after-change-functions)))))

(ert-deftest proofread-test-disabled-mode-stale-timer-does-not-check-visible ()
  "A stale timer after mode disable does not run visible checking."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((buffer (current-buffer))
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread-check-visible)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (proofread-mode -1)
        (should-not (proofread--idle-timer-run buffer))
        (should-not visible-checks)))))

(ert-deftest proofread-test-killed-buffer-idle-timer-is-ignored ()
  "An idle timer targeting a killed buffer is ignored without error."
  (let ((buffer (generate-new-buffer " *proofread-idle-killed*")))
    (with-current-buffer buffer
      (insert "Alpha")
      (proofread-mode 1))
    (kill-buffer buffer)
    (should-not (buffer-live-p buffer))
    (should-not (proofread--idle-timer-run buffer))))

(ert-deftest proofread-test-chunks-for-ranges-ordinary-paragraph ()
  "Paragraph chunking records exact boundaries and text."
  (with-temp-buffer
    (insert "First paragraph.\nSecond line.\n\nIgnored")
    (let* ((paragraph-end (save-excursion
                            (goto-char (point-min))
                            (search-forward "\n\n")
                            (- (point) 2)))
           (proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) paragraph-end))))
           (chunk (car chunks)))
      (should (= (length chunks) 1))
      (should (= (plist-get chunk :beg) (point-min)))
      (should (= (plist-get chunk :end) paragraph-end))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest proofread-test-chunks-for-ranges-skips-whitespace ()
  "Paragraph chunking skips empty and whitespace-only paragraphs."
  (with-temp-buffer
    (insert "  \n\t\n\n")
    (should-not (proofread--chunks-for-ranges
                 (list (cons (point-min) (point-max)))))))

(ert-deftest proofread-test-chunks-for-ranges-splits-oversized-paragraph ()
  "Oversized paragraphs split into bounded contiguous chunks."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (let* ((proofread-max-chunk-size 5)
           (proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
      (should (equal (mapcar (lambda (chunk)
                               (cons (plist-get chunk :beg)
                                     (plist-get chunk :end)))
                             chunks)
                     '((1 . 6) (6 . 11) (11 . 13))))
      (should (equal (mapcar (lambda (chunk)
                               (plist-get chunk :text))
                             chunks)
                     '("abcde" "fghij" "kl")))
      (should (cl-every (lambda (chunk)
                          (<= (length (plist-get chunk :text))
                              proofread-max-chunk-size))
                        chunks)))))

(ert-deftest proofread-test-chunk-records-metadata-and-context ()
  "Constructed chunks record mode, language, context, and modified tick."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-context-size 3))
      (insert (propertize "abcTARGETxyz" 'face 'shadow))
      (let* ((tick (buffer-chars-modified-tick))
             (chunk (proofread--make-chunk 4 10)))
        (should (= (plist-get chunk :beg) 4))
        (should (= (plist-get chunk :end) 10))
        (should (equal (plist-get chunk :text) "TARGET"))
        (should (eq (plist-get chunk :major-mode) 'text-mode))
        (should (equal (plist-get chunk :language) "en"))
        (should (equal (plist-get chunk :context-before) "abc"))
        (should (equal (plist-get chunk :context-after) "xyz"))
        (should (= (plist-get chunk :modified-tick) tick))
        (should-not (text-properties-at 0 (plist-get chunk :text)))
        (should-not (text-properties-at
                     0 (plist-get chunk :context-before)))
        (should-not (text-properties-at
                     0 (plist-get chunk :context-after)))))))

(ert-deftest proofread-test-chunking-preserves-buffer-and-state ()
  "Chunking preserves buffer contents, text properties, and proofread state."
  (with-temp-buffer
    (insert (propertize "Alpha paragraph" 'face 'bold 'proofread-test t))
    (proofread-mode 1)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick)))
      (let ((chunks (proofread--chunks-for-ranges
                     (list (cons (point-min) (point-max))))))
        (should (= (length chunks) 1))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
        (should-not (text-properties-at 0 (plist-get (car chunks) :text)))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should-not proofread--requests)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-request-ready-chunks-filter-url ()
  "Request-ready chunks exclude URLs while retaining surrounding text."
  (with-temp-buffer
    (insert "Alpha http://example.com/path Beta")
    (let* ((proofread-context-size 0)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (texts (proofread-test--chunk-texts chunks)))
      (should (equal texts '("Alpha " " Beta")))
      (should-not (string-match-p "http://example.com/path"
                                  (mapconcat #'identity texts ""))))))

(ert-deftest proofread-test-request-ready-chunks-filter-email ()
  "Request-ready chunks exclude email addresses while retaining text."
  (with-temp-buffer
    (insert "Alpha user@example.com Beta")
    (let* ((proofread-context-size 0)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (texts (proofread-test--chunk-texts chunks)))
      (should (equal texts '("Alpha " " Beta")))
      (should-not (string-match-p "user@example.com"
                                  (mapconcat #'identity texts ""))))))

(ert-deftest proofread-test-request-ready-chunks-filter-ignored-face ()
  "Request-ready chunks exclude text with ignored faces."
  (with-temp-buffer
    (insert "Alpha SKIP Beta")
    (let ((skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (proofread-ignored-faces '(proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties skip-beg skip-end
                           '(face (bold proofread-test-ignore)))
      (should (equal
               (proofread-test--chunk-texts
                (proofread--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '("Alpha " " Beta"))))))

(ert-deftest proofread-test-request-ready-chunks-filter-ignored-property ()
  "Request-ready chunks exclude text with ignored properties."
  (with-temp-buffer
    (insert "Alpha SKIP Beta")
    (let ((skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (proofread-ignored-properties '(proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties skip-beg skip-end
                           '(proofread-test-ignore t))
      (should (equal
               (proofread-test--chunk-texts
                (proofread--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '("Alpha " " Beta"))))))

(ert-deftest proofread-test-request-ready-chunks-filter-invisible ()
  "Request-ready chunks exclude invisible text by default."
  (with-temp-buffer
    (insert "Alpha HIDDEN Beta")
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (proofread-context-size 0))
      (add-text-properties hidden-beg hidden-end '(invisible t))
      (should (equal
               (proofread-test--chunk-texts
                (proofread--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '("Alpha " " Beta"))))))

(ert-deftest proofread-test-request-ready-chunks-preserve-metadata ()
  "Filtered chunks preserve exact text and stale-result metadata."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-context-size 80))
      (insert "Keep http://example.com TARGET tail")
      (let* ((tick (buffer-chars-modified-tick))
             (chunks (proofread--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--chunk-texts chunks)
                       '("Keep " " TARGET tail")))
        (dolist (chunk chunks)
          (should (equal (plist-get chunk :text)
                         (buffer-substring-no-properties
                          (plist-get chunk :beg)
                          (plist-get chunk :end))))
          (should (eq (plist-get chunk :major-mode) 'text-mode))
          (should (equal (plist-get chunk :language) "en"))
          (should (= (plist-get chunk :modified-tick) tick))
          (should-not (string-match-p "http://example.com"
                                      (plist-get chunk :text)))
          (should-not (string-match-p "http://example.com"
                                      (plist-get chunk :context-before)))
          (should-not (string-match-p "http://example.com"
                                      (plist-get chunk :context-after))))))))

(ert-deftest proofread-test-cache-key-varies-by-identity ()
  "Cache keys change when text or environment identity changes."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-prompt-version "prompt-a")
          (proofread-cache-configuration-version 1))
      (insert "Alpha")
      (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                          (list (cons (point-min) (point-max))))))
             (base-key (proofread--cache-key chunk 'mock)))
        (should-not (equal base-key
                           (proofread--cache-key chunk 'other-backend)))
        (let ((proofread-prompt-version "prompt-b"))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'mock))))
        (let ((proofread-cache-configuration-version 2))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'mock))))
        (let ((changed-language (copy-sequence chunk)))
          (setq changed-language
                (plist-put changed-language :language "fr"))
          (should-not (equal base-key
                             (proofread--cache-key changed-language 'mock))))
        (let ((changed-mode (copy-sequence chunk)))
          (setq changed-mode
                (plist-put changed-mode :major-mode 'org-mode))
          (should-not (equal base-key
                             (proofread--cache-key changed-mode 'mock))))
        (let ((changed-text (copy-sequence chunk)))
          (setq changed-text
                (plist-put changed-text :text "Beta"))
          (should-not (equal base-key
                             (proofread--cache-key changed-text 'mock))))))))

(ert-deftest proofread-test-cache-read-write-hit-and-miss ()
  "Cache helpers read and write entries only for active proofread buffers."
  (with-temp-buffer
    (insert "Alpha")
    (should-not (proofread--cache-write 'key 'value))
    (should-not proofread--cache)
    (proofread-mode 1)
    (should (proofread--cache-write 'key 'value))
    (should (equal (proofread--cache-read 'key) 'value))
    (should-not (proofread--cache-read 'missing-key))
    (proofread-mode -1)
    (should-not proofread--cache)
    (should-not (proofread--cache-read 'key))))

(ert-deftest proofread-test-cache-relative-diagnostic-conversion ()
  "Cached diagnostics convert exactly between absolute and relative ranges."
  (let* ((request '(:beg 10 :end 20 :text "0123456789" :backend mock))
         (diagnostic
          (proofread-test--diagnostic-for-range 12 15 "234"))
         (relative
          (proofread--diagnostic-to-relative diagnostic request))
         (absolute
          (proofread--diagnostic-to-absolute relative request)))
    (should (= (plist-get relative :beg) 2))
    (should (= (plist-get relative :end) 5))
    (should-not (= (plist-get relative :beg)
                   (plist-get diagnostic :beg)))
    (should-not (= (plist-get relative :end)
                   (plist-get diagnostic :end)))
    (should (equal absolute diagnostic))))

(ert-deftest proofread-test-cache-hit-skips-backend-dispatch ()
  "Unchanged visible text reuses cached diagnostics without backend dispatch."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-hit*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  request
                  callback
                  backend-calls)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) 5))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq backend-calls
                                 (1+ (or backend-calls 0)))
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (should (= backend-calls 1))
                (let ((diagnostic
                       (proofread-test--diagnostic-for-range 1 5 "helo")))
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                request (list diagnostic)))
                              'applied))
                  (should (= (hash-table-count proofread--cache) 1))
                  (proofread-clear)
                  (setq proofread--diagnostics nil)
                  (proofread-check-visible)
                  (should (= backend-calls 1))
                  (should (equal proofread--diagnostics
                                 (list diagnostic)))
                  (should (= (length proofread--overlays) 1))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-cache-invalidation-misses ()
  "Backend, prompt, configuration, and text changes miss old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-prompt-version "prompt-a")
           (proofread-cache-configuration-version 1)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (setq request (plist-put request :backend 'mock))
      (proofread--cache-write-request request (list diagnostic))
      (let ((other-backend (plist-put (copy-sequence request)
                                      :backend 'other-backend)))
        (should-not (proofread--cache-read-request other-backend)))
      (let ((proofread-prompt-version "prompt-b"))
        (should-not (proofread--cache-read-request request)))
      (let ((proofread-cache-configuration-version 2))
        (should-not (proofread--cache-read-request request)))
      (let ((changed-text (plist-put (copy-sequence request)
                                     :text "Beta")))
        (should-not (proofread--cache-read-request changed-text))))))

(ert-deftest proofread-test-stale-and-error-results-are-not-cached ()
  "Stale and error backend results do not write diagnostics to the cache."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (setq request (plist-put request :backend 'mock))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'stale))
      (should (= (hash-table-count proofread--cache) 0))
      (let ((fresh-request (proofread--make-backend-request
                            (car (proofread--request-ready-chunks-for-ranges
                                  (list (cons (point-min)
                                              (point-max))))))))
        (setq fresh-request (plist-put fresh-request :backend 'mock))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-error-result
                      fresh-request 'mock-failure "Mock failure"))
                    'error))
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-cache-hit-validates-current-text ()
  "Cached diagnostics are dropped when current text no longer matches."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (entry (proofread--make-cache-entry request (list diagnostic))))
      (setq request (plist-put request :backend 'mock))
      (delete-region 1 5)
      (insert "hello")
      (let ((stale-request
             (plist-put (copy-sequence request)
                        :modified-tick
                        (buffer-chars-modified-tick))))
        (should (eq (proofread--apply-cache-entry stale-request entry)
                    'stale))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)))))

(ert-deftest proofread-test-backend-availability ()
  "Backend availability reports support for the built-in mock backend."
  (let ((proofread-backend 'mock))
    (should (proofread-backend-available-p))
    (should (proofread-backend-available-p 'mock))
    (should-not (proofread-backend-available-p 'unknown-backend))))

(ert-deftest proofread-test-backend-request-records-chunk-fields ()
  "Backend requests preserve request-ready chunk metadata."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-context-size 3))
      (insert "abcTARGETxyz")
      (let* ((tick (buffer-chars-modified-tick))
             (chunk (car (proofread--request-ready-chunks-for-ranges
                          '((4 . 10)))))
             (request (proofread--make-backend-request chunk)))
        (dolist (key proofread--backend-request-keys)
          (should (plist-member request key)))
        (should (integerp (plist-get request :id)))
        (should (eq (plist-get request :buffer) (current-buffer)))
        (should (= (plist-get request :beg) 4))
        (should (= (plist-get request :end) 10))
        (should (equal (plist-get request :text) "TARGET"))
        (should (equal (plist-get request :context-before) "abc"))
        (should (equal (plist-get request :context-after) "xyz"))
        (should (equal (plist-get request :language) "en"))
        (should (eq (plist-get request :major-mode) 'text-mode))
        (should (= (plist-get request :modified-tick) tick))))))

(ert-deftest proofread-test-mock-backend-success-is-asynchronous ()
  "Mock backend success callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result)
      (should (proofread-backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'mock))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'ok))
      (should (eq (plist-get result :request) request))
      (should (listp (plist-get result :diagnostics))))))

(ert-deftest proofread-test-mock-backend-error-is-asynchronous ()
  "Mock backend error callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result)
      (setq request (plist-put request :mock-error 'mock-failure))
      (setq request (plist-put request :mock-message "Mock failure"))
      (should (proofread-backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'mock))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :request) request))
      (should (eq (plist-get result :error) 'mock-failure))
      (should (equal (plist-get result :message) "Mock failure")))))

(ert-deftest proofread-test-unsupported-backend-error-is-asynchronous ()
  "Unsupported backends report an asynchronous protocol error."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result)
      (should (proofread-backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'unknown-backend))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :request) request))
      (should (eq (plist-get result :error) 'unsupported-backend)))))

(ert-deftest proofread-test-backend-success-clears-active-request ()
  "Successful backend callbacks clear active request state first."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((buffer (current-buffer))
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result
           active-at-callback)
      (should (proofread--dispatch-backend-request
               request
               (lambda (backend-result)
                 (setq result backend-result)
                 (with-current-buffer buffer
                   (setq active-at-callback proofread--requests)))
               'mock))
      (should (proofread--active-request-p request))
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'ok))
      (should-not active-at-callback)
      (should-not (proofread--active-request-p request)))))

(ert-deftest proofread-test-backend-error-preserves-buffer-and-clears-request ()
  "Backend error callbacks preserve text and clear active request state."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((buffer (current-buffer))
           (before-text (buffer-string))
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result
           active-at-callback)
      (setq request (plist-put request :mock-error 'mock-failure))
      (should (proofread--dispatch-backend-request
               request
               (lambda (backend-result)
                 (setq result backend-result)
                 (with-current-buffer buffer
                   (setq active-at-callback proofread--requests)))
               'mock))
      (should (proofread--active-request-p request))
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (equal (buffer-string) before-text))
      (should-not active-at-callback)
      (should-not (proofread--active-request-p request)))))

(ert-deftest proofread-test-check-visible-dispatches-request-ready-chunks ()
  "`proofread-check-visible' dispatches filtered visible chunks."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-dispatch*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  (proofread-context-size 0)
                  requests
                  callbacks)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (request callback &optional _backend)
                           (push request requests)
                           (push callback callbacks)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (setq requests (nreverse requests))
                (should (equal proofread--pending-ranges
                               (list (cons (point-min) (point-max)))))
                (should (equal (mapcar (lambda (request)
                                         (plist-get request :text))
                                       requests)
                               '("Alpha " " Beta")))
                (should (= (length callbacks) 2))
                (should (= (length proofread--requests) 2))
                (should-not proofread--diagnostics)
                (should-not proofread--overlays))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-active-requests-remain-buffer-local ()
  "Active request state is isolated between buffers."
  (let ((first-buffer (generate-new-buffer " *proofread-requests-a*"))
        (second-buffer (generate-new-buffer " *proofread-requests-b*")))
    (unwind-protect
        (let ((proofread-backend 'mock))
          (cl-letf (((symbol-function 'proofread-backend-check)
                     (lambda (_request _callback &optional _backend)
                       'proofread-test-handle)))
            (with-current-buffer first-buffer
              (insert "Alpha")
              (proofread-mode 1)
              (proofread--dispatch-request-ready-chunks
               (proofread--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
            (with-current-buffer second-buffer
              (insert "Beta")
              (proofread-mode 1)
              (proofread--dispatch-request-ready-chunks
               (proofread--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
            (with-current-buffer first-buffer
              (should (= (length proofread--requests) 1))
              (should (eq (plist-get (car proofread--requests) :buffer)
                          first-buffer)))
            (with-current-buffer second-buffer
              (should (= (length proofread--requests) 1))
              (should (eq (plist-get (car proofread--requests) :buffer)
                          second-buffer)))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest proofread-test-fresh-result-records-diagnostics-and-overlays ()
  "Fresh successful results record diagnostics and create overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-fresh-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  request
                  callback)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (should (proofread--active-request-p request))
                (let ((diagnostic
                       (proofread-test--diagnostic-for-range 1 5 "helo")))
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                request (list diagnostic)))
                              'applied))
                  (should (equal proofread--diagnostics (list diagnostic)))
                  (should (= (length proofread--overlays) 1))
                  (should (overlay-buffer (car proofread--overlays)))
                  (should-not (proofread--active-request-p request))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-killed-buffer-result-is-dropped ()
  "Results for killed buffers are dropped without recreating state."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-killed-result*"))
          request
          callback)
      (switch-to-buffer buffer)
      (insert "helo world")
      (proofread-mode 1)
      (let ((proofread-backend 'mock))
        (cl-letf (((symbol-function 'window-start)
                   (lambda (&optional _window) (point-min)))
                  ((symbol-function 'window-end)
                   (lambda (&optional _window _update) (point-max)))
                  ((symbol-function 'proofread-backend-check)
                   (lambda (backend-request backend-callback
                                            &optional _backend)
                     (setq request backend-request)
                     (setq callback backend-callback)
                     'proofread-test-handle)))
          (proofread-check-visible)))
      (kill-buffer buffer)
      (should-not (buffer-live-p buffer))
      (should (eq (funcall
                   callback
                   (proofread--backend-success-result
                    request
                    (list (proofread-test--diagnostic-for-range 1 5 "helo"))))
                  'stale)))))

(ert-deftest proofread-test-disabled-mode-result-is-dropped ()
  "Results after disabling `proofread-mode' do not mutate proofread state."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-disabled-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  request
                  callback)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (proofread-mode -1)
                (should (eq (funcall
                             callback
                             (proofread--backend-success-result
                              request
                              (list (proofread-test--diagnostic-for-range
                                     1 5 "helo"))))
                            'stale))
                (should-not proofread--diagnostics)
                (should-not proofread--overlays)
                (should-not proofread--requests))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-modified-tick-result-is-dropped ()
  "Results are stale after any buffer modified tick change."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-tick-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  request
                  callback)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) 5))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (goto-char (point-max))
                (insert "!")
                (should (eq (funcall
                             callback
                             (proofread--backend-success-result
                              request
                              (list (proofread-test--diagnostic-for-range
                                     1 5 "helo"))))
                            'stale))
                (should-not proofread--diagnostics)
                (should-not proofread--overlays)
                (should-not (proofread--active-request-p request)))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-text-mismatch-result-is-dropped ()
  "Results are stale when the request range text no longer matches."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-text-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  request
                  callback)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) 5))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (delete-region 1 5)
                (insert "hello")
                (let ((mismatched-request
                       (plist-put (copy-sequence request)
                                  :modified-tick
                                  (buffer-chars-modified-tick))))
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                mismatched-request
                                (list (proofread-test--diagnostic-for-range
                                       1 6 "hello"))))
                              'stale)))
                (should-not proofread--diagnostics)
                (should-not proofread--overlays)
                (should-not (proofread--active-request-p request)))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-backend-error-result-creates-no-overlays ()
  "Backend error results preserve text and create no overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-error-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'mock)
                  (before-text (buffer-string))
                  request
                  callback)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (lambda (backend-request backend-callback
                                                  &optional _backend)
                           (setq request backend-request)
                           (setq callback backend-callback)
                           'proofread-test-handle)))
                (proofread-check-visible)
                (should (eq (funcall
                             callback
                             (proofread--backend-error-result
                              request 'mock-failure "Mock failure"))
                            'error))
                (should (equal (buffer-string) before-text))
                (should-not proofread--diagnostics)
                (should-not proofread--overlays)
                (should-not (proofread--active-request-p request)))))
        (kill-buffer buffer)))))

(provide 'proofread-tests)

;;; proofread-tests.el ends here
