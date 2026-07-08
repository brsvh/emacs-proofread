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

(defun proofread-test--diagnostic-with-kind (beg end text kind)
  "Return a sample diagnostic for BEG, END, TEXT, and KIND."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind kind
   :message "Possible issue"
   :suggestions '("fixed")
   :confidence 0.9
   :source 'test))

(defun proofread-test--install-diagnostics (diagnostics)
  "Install DIAGNOSTICS and return their proofread overlays."
  (setq proofread--diagnostics diagnostics)
  (mapcar #'proofread--create-overlay diagnostics))

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

(defun proofread-test--make-backend-recorder ()
  "Return a plist containing a backend recorder and accessors."
  (let (requests callbacks)
    (list :function
          (lambda (request callback &optional _backend)
            (push request requests)
            (push callback callbacks)
            'proofread-test-handle)
          :requests
          (lambda ()
            (reverse requests))
          :callbacks
          (lambda ()
            (reverse callbacks)))))

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

(ert-deftest proofread-test-cache-miss-calls-backend ()
  "A visible chunk with no cache entry is sent to the backend."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-miss*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo")
            (proofread-mode 1)
            (let* ((proofread-backend 'mock)
                   (recorder (proofread-test--make-backend-recorder)))
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (plist-get recorder :function)))
                (proofread-check-visible)
                (should (= (length (funcall
                                    (plist-get recorder :requests)))
                           1))
                (should (equal (plist-get
                                (car (funcall
                                      (plist-get recorder :requests)))
                                :text)
                               "helo")))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-filtering-precedes-cache-and-backend-dispatch ()
  "Filtered chunks are used for cache lookup and backend dispatch."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-filter-cache*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let* ((proofread-backend 'mock)
                   (proofread-context-size 0)
                   (chunks (proofread--request-ready-chunks-for-ranges
                            (list (cons (point-min) (point-max)))))
                   (cached-request
                    (proofread--make-backend-request (car chunks)))
                   (cached-diagnostic
                    (proofread-test--diagnostic-with-kind
                     1 6 "Alpha" 'spelling))
                   (recorder (proofread-test--make-backend-recorder)))
              (setq cached-request
                    (plist-put cached-request :backend 'mock))
              (proofread--cache-write-request
               cached-request (list cached-diagnostic))
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-check)
                         (plist-get recorder :function)))
                (proofread-check-visible)
                (should (equal (mapcar
                                (lambda (request)
                                  (plist-get request :text))
                                (funcall (plist-get recorder :requests)))
                               '(" Beta")))
                (should (equal proofread--diagnostics
                               (list cached-diagnostic)))
                (should (= (length proofread--overlays) 1)))))
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

(ert-deftest proofread-test-navigation-sorts-and-filters-diagnostics ()
  "Navigation diagnostics are valid and sorted by start and end position."
  (with-temp-buffer
    (insert "abcdefghij")
    (let* ((marker (copy-marker 2))
           (first (proofread-test--diagnostic-for-range marker 5 "bcd"))
           (same-start-short
            (proofread-test--diagnostic-for-range 4 6 "de"))
           (same-start-long
            (proofread-test--diagnostic-for-range 4 9 "defgh"))
           (last (proofread-test--diagnostic-for-range 8 10 "hi"))
           (invalid-beg
            (proofread-test--diagnostic-for-range 'not-a-position 3 ""))
           (invalid-backward
            (proofread-test--diagnostic-for-range 7 6 "")))
      (setq proofread--diagnostics
            (list same-start-long invalid-beg last invalid-backward
                  same-start-short first))
      (should (equal (mapcar #'proofread--diagnostic-range
                             (proofread--navigation-diagnostics))
                     '((2 . 5) (4 . 6) (4 . 9) (8 . 10)))))))

(ert-deftest proofread-test-navigation-target-selection-around-point ()
  "Next and previous target helpers select strict non-wrapping targets."
  (with-temp-buffer
    (let* ((first (proofread-test--diagnostic-for-range 3 4 "c"))
           (second (proofread-test--diagnostic-for-range 6 7 "f"))
           (third (proofread-test--diagnostic-for-range 9 10 "i"))
           (invalid (proofread-test--diagnostic-for-range 12 11 "")))
      (setq proofread--diagnostics (list third invalid first second))
      (should (eq (proofread--next-diagnostic-after 1) first))
      (should (eq (proofread--next-diagnostic-after 3) second))
      (should (eq (proofread--next-diagnostic-after 6) third))
      (should-not (proofread--next-diagnostic-after 9))
      (should-not (proofread--previous-diagnostic-before 3))
      (should (eq (proofread--previous-diagnostic-before 6) first))
      (should (eq (proofread--previous-diagnostic-before 9) second))
      (should (eq (proofread--previous-diagnostic-before 11) third)))))

(ert-deftest proofread-test-proofread-next-moves-to-nearest-diagnostic ()
  "`proofread-next' moves point to the nearest later diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list second first))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (should (equal proofread--current-diagnostic first))
      (proofread-next)
      (should (= (point) 7))
      (should (equal proofread--current-diagnostic second)))))

(ert-deftest proofread-test-proofread-previous-moves-to-nearest-diagnostic ()
  "`proofread-previous' moves point to the nearest earlier diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list second first))
      (goto-char (point-max))
      (proofread-previous)
      (should (= (point) 7))
      (should (equal proofread--current-diagnostic second))
      (proofread-previous)
      (should (= (point) 3))
      (should (equal proofread--current-diagnostic first)))))

(ert-deftest proofread-test-navigation-empty-diagnostics-keeps-point ()
  "Navigation with no diagnostics reports an error and leaves point unchanged."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (goto-char 5)
    (let ((position (point))
          (text (buffer-string)))
      (should-error (proofread-next) :type 'user-error)
      (should (= (point) position))
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) position))
      (should (equal (buffer-string) text)))))

(ert-deftest proofread-test-navigation-boundaries-do-not-wrap ()
  "Navigation commands use a no-wrap boundary policy."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list first second))
      (goto-char 7)
      (should-error (proofread-next) :type 'user-error)
      (should (= (point) 7))
      (goto-char 3)
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) 3)))))

(ert-deftest proofread-test-navigation-ignores-foreign-overlays ()
  "Navigation uses proofread diagnostics instead of unrelated overlays."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((foreign-overlay (make-overlay 2 3))
           (diagnostic (proofread-test--diagnostic-for-range 6 7 "f")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 6))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-navigation-marks-one-current-diagnostic ()
  "Navigating marks exactly one proofread-owned diagnostic as current."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((first (proofread-test--diagnostic-for-range 3 4 "c"))
           (second (proofread-test--diagnostic-for-range 7 8 "g"))
           (foreign-overlay (make-overlay 1 2)))
      (overlay-put foreign-overlay 'face 'bold)
      (proofread-test--install-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (should (eq (overlay-get (proofread--overlay-for-diagnostic first)
                               'face)
                  'proofread-current-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic second)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get foreign-overlay 'face) 'bold))
      (proofread-next)
      (should (eq (overlay-get (proofread--overlay-for-diagnostic first)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic second)
                               'face)
                  'proofread-current-face))
      (should (= (cl-count 'proofread-current-face
                           (mapcar (lambda (overlay)
                                     (overlay-get overlay 'face))
                                   proofread--overlays))
                 1))
      (should (eq (overlay-get foreign-overlay 'face) 'bold)))))

(ert-deftest proofread-test-navigation-preserves-buffer-text ()
  "Navigation commands move point without changing buffer text."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g"))
          (text (buffer-string)))
      (proofread-test--install-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (goto-char (point-max))
      (proofread-previous)
      (should (equal (buffer-string) text)))))

(ert-deftest proofread-test-navigation-clears-current-state ()
  "Clearing overlays or disabling mode removes current diagnostic state."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c")))
      (proofread-test--install-diagnostics (list diagnostic))
      (proofread--mark-current-diagnostic diagnostic)
      (should proofread--current-diagnostic)
      (proofread-clear)
      (should-not proofread--current-diagnostic)
      (should-not proofread--overlays)))
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (proofread--mark-current-diagnostic diagnostic)
      (proofread-mode -1)
      (should-not proofread--current-diagnostic)
      (should-not (overlay-buffer overlay)))))

(ert-deftest proofread-test-diagnostic-at-point-finds-covering-diagnostic ()
  "Diagnostic lookup returns the proofread diagnostic covering point."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 6 "cde")))
      (setq proofread--diagnostics (list diagnostic))
      (goto-char 3)
      (should (eq (proofread--diagnostic-at-point) diagnostic))
      (goto-char 5)
      (should (eq (proofread--diagnostic-at-point) diagnostic))
      (goto-char 6)
      (should-not (proofread--diagnostic-at-point)))))

(ert-deftest proofread-test-diagnostic-at-point-uses-overlap-order ()
  "Overlapping diagnostic lookup uses navigation ordering."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((long (proofread-test--diagnostic-for-range 2 9 "bcdefgh"))
          (short (proofread-test--diagnostic-for-range 2 6 "bcde"))
          (later (proofread-test--diagnostic-for-range 4 5 "d")))
      (setq proofread--diagnostics (list later long short))
      (goto-char 4)
      (should (eq (proofread--diagnostic-at-point) short)))))

(ert-deftest proofread-test-diagnostic-at-point-ignores-foreign-overlays ()
  "Diagnostic lookup ignores foreign overlays and invalid diagnostic ranges."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((foreign-overlay (make-overlay 3 6))
          (invalid-backward
           (proofread-test--diagnostic-for-range 7 6 ""))
          (invalid-beg
           (proofread-test--diagnostic-for-range 'not-a-position 5 "")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--diagnostics (list invalid-backward invalid-beg))
      (goto-char 4)
      (should-not (proofread--diagnostic-at-point)))))

(ert-deftest proofread-test-format-diagnostic-description-details ()
  "Diagnostic description includes stable package-level fields."
  (let* ((diagnostic
          (proofread--make-diagnostic
           :beg 1
           :end 5
           :text "helo"
           :kind 'spelling
           :message "Possible misspelling"
           :suggestions '("hello")
           :confidence 0.92
           :source 'mock))
         (description
          (proofread--format-diagnostic-description diagnostic)))
    (should (string-match-p "Kind: spelling" description))
    (should (string-match-p "Message: Possible misspelling" description))
    (should (string-match-p "Original text:\nhelo" description))
    (should (string-match-p "1\\. hello" description))
    (should (string-match-p "Confidence: 0.92" description))
    (should (string-match-p "Source: mock" description))))

(ert-deftest proofread-test-describe-displays-diagnostic-details ()
  "`proofread-describe' displays diagnostic details at point."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '("hello")
              :confidence 0.91
              :source 'mock)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Kind: spelling" description))
            (should (string-match-p "Message: Possible misspelling"
                                    description))
            (should (string-match-p "Original text:\nhelo" description))
            (should (string-match-p "1\\. hello" description))
            (should (string-match-p "Confidence: 0.91" description))
            (should (string-match-p "Source: mock" description))))))))

(ert-deftest proofread-test-describe-preserves-suggestion-order ()
  "`proofread-describe' displays suggestions in stored order."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '("hello" "help" "hero"))))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let* ((description (buffer-string))
                 (first (string-match-p "1\\. hello" description))
                 (second (string-match-p "2\\. help" description))
                 (third (string-match-p "3\\. hero" description)))
            (should first)
            (should second)
            (should third)
            (should (< first second))
            (should (< second third))))))))

(ert-deftest proofread-test-describe-handles-missing-optional-fields ()
  "`proofread-describe' displays available fields when optional data is absent."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :message "Message only")))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Message: Message only" description))
            (should (string-match-p "Original text:\nhelo" description))
            (should-not (string-match-p "Suggestions:" description))
            (should-not (string-match-p "Confidence:" description))
            (should-not (string-match-p "Source:" description))))))))

(ert-deftest proofread-test-describe-away-from-diagnostic-keeps-point ()
  "`proofread-describe' reports absence away from proofread diagnostics."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 5 "cd"))
          (text (buffer-string)))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 8)
      (let ((position (point)))
        (should-error (proofread-describe) :type 'user-error)
        (should (= (point) position))
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-describe-preserves-source-buffer-text ()
  "`proofread-describe' does not modify source buffer text."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let ((diagnostic (proofread-test--diagnostic-for-range 1 5 "helo"))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-describe-preserves-diagnostics-and-overlays ()
  "`proofread-describe' does not mutate source diagnostics or overlays."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let* ((diagnostic (proofread-test--diagnostic-for-range 1 5 "helo"))
             (overlays (proofread-test--install-diagnostics
                        (list diagnostic)))
             (diagnostics-before (copy-sequence proofread--diagnostics))
             (overlays-before (copy-sequence proofread--overlays))
             (faces-before
              (mapcar (lambda (overlay)
                        (overlay-get overlay 'face))
                      proofread--overlays)))
        (goto-char 2)
        (proofread-describe)
        (should (equal proofread--diagnostics diagnostics-before))
        (should (equal proofread--overlays overlays-before))
        (should (equal (mapcar (lambda (overlay)
                                 (overlay-get overlay 'face))
                               proofread--overlays)
                       faces-before))
        (dolist (overlay overlays)
          (should (overlay-buffer overlay)))))))

(ert-deftest proofread-test-apply-target-overlay-lookup ()
  "Suggestion application uses proofread-owned diagnostic and overlay state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (proofread-overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic))))
           (foreign-overlay (make-overlay 1 5)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (overlay-put foreign-overlay 'proofread-diagnostic diagnostic)
      (goto-char 2)
      (should (eq (proofread--diagnostic-at-point) diagnostic))
      (should (eq (proofread--overlay-for-diagnostic diagnostic)
                  proofread-overlay))
      (delete-overlay proofread-overlay)
      (should-not (proofread--overlay-for-diagnostic diagnostic))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-apply-suggestion-helper-returns-strings ()
  "Suggestion extraction returns strings in stored order."
  (let ((diagnostic
         (proofread--make-diagnostic
          :beg 1
          :end 5
          :text "helo"
          :suggestions '(hello "hullo" 42))))
    (should (equal (proofread--diagnostic-suggestions diagnostic)
                   '("hello" "hullo" "42")))))

(ert-deftest proofread-test-apply-single-suggestion-replaces-range ()
  "`proofread-apply-suggestion' applies one suggestion without prompting."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '("hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args)
                   (error "Unexpected completion prompt"))))
        (should (eq (proofread-apply-suggestion) 'applied)))
      (should (equal (buffer-string) "aa hello zz")))))

(ert-deftest proofread-test-apply-multiple-suggestions-uses-completion ()
  "`proofread-apply-suggestion' preserves candidate order for completion."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '("hello" "hullo" "hallo")))
          candidates-seen)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _args)
                   (setq candidates-seen candidates)
                   "hullo")))
        (should (eq (proofread-apply-suggestion) 'applied)))
      (should (equal candidates-seen '("hello" "hullo" "hallo")))
      (should (equal (buffer-string) "aa hullo zz")))))

(ert-deftest proofread-test-apply-no-suggestion-reports-unavailable ()
  "Suggestion application reports no available suggestion without editing."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 5
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling")))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-apply-suggestion) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-invalid-range-rejected ()
  "Suggestion application rejects out-of-buffer diagnostic ranges."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 999
            :text "helo"
            :kind 'spelling
            :suggestions '("hello"))))
      (setq proofread--diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-apply-suggestion) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-stale-overlay-rejected ()
  "Suggestion application rejects diagnostics without a live proofread overlay."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread--make-diagnostic
             :beg 1
             :end 5
             :text "helo"
             :kind 'spelling
             :suggestions '("hello")))
           (overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic)))))
      (delete-overlay overlay)
      (goto-char 2)
      (should-error (proofread-apply-suggestion) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-text-mismatch-rejected ()
  "Suggestion application rejects changed text before replacing anything."
  (with-temp-buffer
    (insert "hell")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 5
            :text "helo"
            :kind 'spelling
            :suggestions '("hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-apply-suggestion) :type 'user-error)
      (should (equal (buffer-string) "hell")))))

(ert-deftest proofread-test-apply-undo-restores-original-text ()
  "Undo restores text replaced by `proofread-apply-suggestion'."
  (with-temp-buffer
    (insert "aa helo zz")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :suggestions '("hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (proofread-apply-suggestion)
      (should (equal (buffer-string) "aa hello zz"))
      (undo)
      (should (equal (buffer-string) "aa helo zz")))))

(ert-deftest proofread-test-apply-invalidates-proofread-overlays ()
  "Suggestion application removes affected proofread overlays only."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let* ((target
            (proofread--make-diagnostic
             :beg 4
             :end 8
             :text "helo"
             :kind 'spelling
             :suggestions '("hello")))
           (overlap
            (proofread-test--diagnostic-for-range 5 8 "elo"))
           (outside
            (proofread-test--diagnostic-for-range 9 11 "zz"))
           (overlays
            (proofread-test--install-diagnostics
             (list target overlap outside)))
           (target-overlay (nth 0 overlays))
           (overlap-overlay (nth 1 overlays))
           (outside-overlay (nth 2 overlays))
           (foreign-overlay (make-overlay 3 9)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread--mark-current-diagnostic target)
      (goto-char 5)
      (proofread-apply-suggestion)
      (should-not (overlay-buffer target-overlay))
      (should-not (overlay-buffer overlap-overlay))
      (should (overlay-buffer outside-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--current-diagnostic)
      (should (equal proofread--diagnostics (list outside))))))

(ert-deftest proofread-test-non-apply-commands-do-not-apply-suggestions ()
  "Navigation and description do not apply suggestions automatically."
  (save-window-excursion
    (with-temp-buffer
      (insert " helo world")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 2
              :end 6
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '("hello")))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 1)
        (proofread-next)
        (should (equal (buffer-string) text))
        (proofread-describe)
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-ignore-key-exact-text-and-kind ()
  "Ignore keys match exact diagnostic text and kind only."
  (let ((proofread--ignored-diagnostics (make-hash-table :test #'equal)))
    (let ((diagnostic
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'spelling))
          (same
           (proofread-test--diagnostic-with-kind
            10 14 "helo" 'spelling))
          (different-kind
           (proofread-test--diagnostic-with-kind
            10 14 "helo" 'grammar))
          (different-text
           (proofread-test--diagnostic-with-kind
            10 14 "wrld" 'spelling)))
      (should (equal (proofread--diagnostic-ignore-key diagnostic)
                     '(:text "helo" :kind spelling)))
      (proofread--record-ignored-diagnostic diagnostic)
      (should (proofread--diagnostic-ignored-p same))
      (should-not (proofread--diagnostic-ignored-p different-kind))
      (should-not (proofread--diagnostic-ignored-p different-text)))))

(ert-deftest proofread-test-ignore-command-removes-matching-overlays ()
  "`proofread-ignore' records a key and removes matching proofread overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert "helo wrld helo")
      (proofread-mode 1)
      (let* ((target
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'spelling))
             (unrelated
              (proofread-test--diagnostic-with-kind
               6 10 "wrld" 'spelling))
             (same-key
              (proofread-test--diagnostic-with-kind
               11 15 "helo" 'spelling))
             (overlays
              (proofread-test--install-diagnostics
               (list target unrelated same-key)))
             (target-overlay (nth 0 overlays))
             (unrelated-overlay (nth 1 overlays))
             (same-key-overlay (nth 2 overlays))
             (foreign-overlay (make-overlay 1 15))
             (text (buffer-string)))
        (overlay-put foreign-overlay 'category 'foreign-overlay)
        (proofread--mark-current-diagnostic target)
        (goto-char 2)
        (should (eq (proofread-ignore) 'ignored))
        (should (proofread--diagnostic-ignored-p target))
        (should-not (overlay-buffer target-overlay))
        (should-not (overlay-buffer same-key-overlay))
        (should (overlay-buffer unrelated-overlay))
        (should (overlay-buffer foreign-overlay))
        (should-not proofread--current-diagnostic)
        (should (equal proofread--diagnostics (list unrelated)))
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-ignore-command-away-from-diagnostic ()
  "`proofread-ignore' away from diagnostics reports no target."
  (let ((proofread--ignored-diagnostics (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert "helo wrld")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread-test--diagnostic-with-kind
              1 5 "helo" 'spelling))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 8)
        (should-error (proofread-ignore) :type 'user-error)
        (should (equal (buffer-string) text))
        (should-not (proofread--diagnostic-ignored-p diagnostic))
        (should (= (length proofread--overlays) 1))))))

(ert-deftest proofread-test-ignore-filter-preserves-different-key ()
  "Ignored diagnostics are filtered before creating proofread overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert "helo helo wrld")
      (proofread-mode 1)
      (let ((ignored
             (proofread-test--diagnostic-with-kind
              1 5 "helo" 'spelling))
            (different-kind
             (proofread-test--diagnostic-with-kind
              6 10 "helo" 'grammar))
            (different-text
             (proofread-test--diagnostic-with-kind
              11 15 "wrld" 'spelling)))
        (proofread--record-ignored-diagnostic ignored)
        (proofread--apply-backend-diagnostics
         (list ignored different-kind different-text))
        (should (equal proofread--diagnostics
                       (list different-kind different-text)))
        (should (= (length proofread--overlays) 2))
        (let ((displayed (mapcar (lambda (overlay)
                                   (overlay-get overlay
                                                'proofread-diagnostic))
                                 proofread--overlays)))
          (should (member different-kind displayed))
          (should (member different-text displayed))
          (should-not (member ignored displayed)))))))

(ert-deftest proofread-test-ignore-filters-backend-and-cache-results ()
  "Ignored diagnostics from backend results or cache hits create no overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let* ((request
              (list :buffer (current-buffer)
                    :beg 1
                    :end 5
                    :text "helo"
                    :modified-tick (buffer-chars-modified-tick)
                    :backend 'mock))
             (diagnostic
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'spelling))
             (entry (proofread--make-cache-entry
                     request (list diagnostic))))
        (proofread--record-ignored-diagnostic diagnostic)
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should (eq (proofread--apply-cache-entry request entry)
                    'applied))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)))))

(provide 'proofread-tests)

;;; proofread-tests.el ends here
