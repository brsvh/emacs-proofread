;;; proofread-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for proofread.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
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
   :source 'test))

(defun proofread-test--diagnostic-with-suggestions
    (beg end text suggestions)
  "Return a diagnostic for BEG, END, TEXT, and SUGGESTIONS."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions suggestions
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

(defun proofread-test--combined-chunk-text (chunks)
  "Return the text payloads from CHUNKS joined by newlines."
  (mapconcat (lambda (chunk)
               (plist-get chunk :text))
             chunks
             "\n"))

(defun proofread-test--chunk-ranges (chunks)
  "Return the buffer ranges from CHUNKS."
  (mapcar (lambda (chunk)
            (cons (plist-get chunk :beg)
                  (plist-get chunk :end)))
          chunks))

(defun proofread-test--span-texts (spans)
  "Return buffer text selected by SPANS."
  (mapcar (lambda (span)
            (buffer-substring-no-properties (car span) (cdr span)))
          spans))

(defun proofread-test--chunk-with-text (chunks text)
  "Return the first chunk from CHUNKS whose text is TEXT."
  (cl-find-if (lambda (chunk)
                (equal (plist-get chunk :text) text))
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

(defun proofread-test--window-state (buffer window)
  "Return point and window state for BUFFER and WINDOW."
  (list :selected-window (selected-window)
        :window-list (window-list)
        :selected-window-point (window-point (selected-window))
        :selected-window-start (window-start (selected-window))
        :buffer-point (with-current-buffer buffer (point))
        :window-point (window-point window)
        :window-start (window-start window)))

(defconst proofread-test--llm-provider 'proofread-test-provider
  "Provider object used for local LLM backend tests.")

(defconst proofread-test--llm-provider-identity
  "proofread-test-provider"
  "Stable provider identity used for local LLM backend tests.")

(defun proofread-test--llm-capabilities (_provider)
  "Return LLM capabilities used by local backend tests."
  '(json-response))

(defmacro proofread-test--with-llm-capabilities (&rest body)
  "Run BODY with structured output enabled for the local provider."
  (declare (indent 0) (debug (body)))
  `(cl-letf (((symbol-function 'llm-capabilities)
              #'proofread-test--llm-capabilities))
     ,@body))

(defmacro proofread-test--with-llm-success (content &rest body)
  "Run BODY with `llm-chat-async' configured to return CONTENT."
  (declare (indent 1) (debug (form body)))
  `(let ((proofread-llm-provider proofread-test--llm-provider)
         (proofread-llm-provider-identity
          proofread-test--llm-provider-identity))
     (cl-letf (((symbol-function 'llm-chat-async)
                (lambda (_provider _prompt success _error &optional
                                   _multi-output)
                  (funcall success ,content)
                  'proofread-test-llm-handle))
               ((symbol-function 'llm-capabilities)
                #'proofread-test--llm-capabilities))
       ,@body)))

(defmacro proofread-test--with-llm-error (error message &rest body)
  "Run BODY with `llm-chat-async' signaling ERROR and MESSAGE."
  (declare (indent 2) (debug (form form body)))
  `(let ((proofread-llm-provider proofread-test--llm-provider)
         (proofread-llm-provider-identity
          proofread-test--llm-provider-identity))
     (cl-letf (((symbol-function 'llm-chat-async)
                (lambda (_provider _prompt _success error-callback
                                   &optional _multi-output)
                  (funcall error-callback ,error ,message)
                  'proofread-test-llm-handle))
               ((symbol-function 'llm-capabilities)
                #'proofread-test--llm-capabilities))
       ,@body)))

(defun proofread-test--response-content (diagnostics)
  "Return structured response text containing DIAGNOSTICS."
  (json-encode `(("diagnostics" . ,(vconcat diagnostics)))))

(defun proofread-test--response-diagnostic
    (beg end text &optional suggestions)
  "Return a diagnostic alist for BEG, END, TEXT, and SUGGESTIONS."
  `(("kind" . "spelling")
    ("message" . "Possible misspelling")
    ("text" . ,text)
    ("range" . (("beg" . ,beg)
                ("end" . ,end)))
    ("suggestions" . ,(vconcat (or suggestions '("hello"))))))

(defun proofread-test--response-diagnostic-with-fields
    (beg end text fields)
  "Return a response diagnostic for BEG, END, TEXT, and FIELDS."
  (append (cl-remove-if (lambda (field)
                          (assoc (car field) fields))
                        (proofread-test--response-diagnostic beg end
                                                             text))
          fields))

(defun proofread-test--structured-batch (request diagnostics)
  "Return parsed diagnostic batch for REQUEST and DIAGNOSTICS."
  (proofread--diagnostic-batch-from-structured-response
   request (proofread-test--response-content diagnostics) 'llm))

(defun proofread-test--structured-issue-reason (request diagnostic)
  "Return the first issue reason for DIAGNOSTIC in REQUEST."
  (plist-get
   (car (plist-get
         (proofread-test--structured-batch request (list diagnostic))
         :issues))
   :reason))

(ert-deftest proofread-test-normalize-ranges-merges-adjacent-ranges ()
  "Normalize visible ranges, dropping invalid or duplicate ranges."
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
      (should-not (proofread-test--tree-member-p 'flyspell-incorrect
                                                 spec))
      (should-not (proofread-test--tree-member-p 'flymake-warning
                                                 spec))
      (should-not (proofread-test--tree-member-p 'flymake-error spec))
      (should-not (proofread-test--tree-member-p 'flycheck-error
                                                 spec)))))

(ert-deftest proofread-test-face-uses-warning-severity ()
  "Diagnostic text uses a theme-aware warning color."
  (let ((spec (face-default-spec 'proofread-face)))
    (should (proofread-test--tree-member-p 'warning spec))
    (should (proofread-test--tree-member-p :underline spec))))

(ert-deftest proofread-test-overlay-stores-diagnostic ()
  "Store ownership and metadata on created proofread overlays."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic)))
      (setq proofread--diagnostics (list diagnostic))
      (let ((overlay (proofread--create-overlay diagnostic)))
        (should (eq (overlay-get overlay 'category)
                    'proofread-overlay))
        (should (eq (overlay-get overlay 'face) 'proofread-face))
        (should (equal (overlay-get overlay 'proofread-diagnostic)
                       diagnostic))
        (should (memq overlay proofread--overlays))
        (should (equal proofread--diagnostics (list diagnostic)))))))

(ert-deftest proofread-test-clear-preserves-unrelated-overlays ()
  "Clearing diagnostics preserves unrelated overlays."
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
      (should-not proofread--diagnostics))))

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
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics))))

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

(ert-deftest proofread-test-disable-mode-clears-untracked-overlays ()
  "Disabling `proofread-mode' deletes untracked proofread overlays."
  (with-temp-buffer
    (insert "hello world again")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (tracked-overlay (proofread--create-overlay diagnostic))
           (orphan-overlay (make-overlay 8 13))
           (foreign-overlay (make-overlay 8 13)))
      (overlay-put orphan-overlay 'category
                   proofread--overlay-category)
      (overlay-put orphan-overlay 'face 'proofread-face)
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--overlays (list tracked-overlay))
      (narrow-to-region 1 6)
      (proofread-mode -1)
      (should-not (overlay-buffer tracked-overlay))
      (should-not (overlay-buffer orphan-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-check-visible-range-collects-single-window-range ()
  "Record the selected visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-single*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello visible world")
            (proofread-mode 1)
            (cl-letf (((symbol-function 'window-start)
                       (lambda (&optional _window) 3))
                      ((symbol-function 'window-end)
                       (lambda (&optional _window _update) 16)))
              (should (equal (proofread--visible-ranges) '((3 . 16))))
              (proofread-check-visible-range)
              (should-not proofread--diagnostics)
              (should-not proofread--overlays)
              (should-not proofread--active-requests)
              (should (= (hash-table-count proofread--cache) 0))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-deduplicates-multiple-windows
    ()
  "Merge overlapping visible ranges from multiple windows."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-multiple*")))
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
                (should (equal (proofread--visible-ranges) '((3 .
                                                                16))))
                (proofread-check-visible-range))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-no-window-produces-no-ranges ()
  "Do not use the whole buffer when no visible window exists."
  (with-temp-buffer
    (insert "hello hidden world")
    (proofread-mode 1)
    (proofread-check-visible-range)
    (should-not proofread--active-requests)))

(ert-deftest proofread-test-check-commands-require-mode ()
  "Proofread check commands require `proofread-mode'."
  (with-temp-buffer
    (insert "Alpha")
    (should-error (proofread-check-visible-range) :type 'user-error)
    (should-error (proofread-check-buffer) :type 'user-error)
    (should-error (proofread-check-region (point-min) (point-max))
                  :type 'user-error)
    (goto-char (point-min))
    (should-error (proofread-check-at-point) :type 'user-error)))

(ert-deftest proofread-test-check-buffer-dispatches-accessible-buffer
    ()
  "Check only accessible buffer text with the current options."
  (with-temp-buffer
    (insert "Outside. Alpha beta. Gamma. Outside.")
    (goto-char (point-min))
    (search-forward "Alpha")
    (let ((beg (match-beginning 0)))
      (search-forward "Gamma.")
      (let ((end (match-end 0)))
        (narrow-to-region beg end)
        (goto-char (+ (point-min) 2))
        (set-mark (+ (point-min) 4))
        (setq mark-active t)
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (let ((proofread-backend 'llm)
              (proofread-llm-provider proofread-test--llm-provider)
              (proofread-llm-provider-identity
               proofread-test--llm-provider-identity)
              (proofread-language "en")
              (proofread-context-size 0)
              (proofread-max-chunk-size 7)
              (proofread-max-concurrent-requests 10)
              (recorder (proofread-test--make-backend-recorder))
              (source (current-buffer))
              (before-text (buffer-string))
              (before-tick (buffer-chars-modified-tick))
              (before-point (point))
              (before-mark (mark))
              (before-mark-active mark-active)
              (before-min (point-min))
              (before-max (point-max)))
          (proofread-test--with-llm-capabilities
           (cl-letf (((symbol-function 'proofread--backend-check)
                      (plist-get recorder :function)))
             (proofread-check-buffer)
             (let ((requests (funcall (plist-get recorder
                                                 :requests))))
               (should (equal
                        (mapcar (lambda (request)
                                  (plist-get request :text))
                                requests)
                        '("Alpha " "beta." "Gamma.")))
               (dolist (request requests)
                 (should
                  (equal (plist-get request :language) "en"))))
             (should-not proofread-auto-check)
             (should (eq (current-buffer) source))
             (should (equal (buffer-string) before-text))
             (should (= (buffer-chars-modified-tick) before-tick))
             (should (= (point) before-point))
             (should (= (mark) before-mark))
             (should (eq mark-active before-mark-active))
             (should (= (point-min) before-min))
             (should (= (point-max) before-max)))))))))

(ert-deftest proofread-test-programming-checks-preserve-window-state
    ()
  "Preserve point and window position during programming checks."
  (dolist (command '(proofread-check-visible-range
                     proofread-check-buffer))
    (save-window-excursion
      (let ((buffer
             (generate-new-buffer
              (format " *proofread-programming-%s*" command))))
        (unwind-protect
            (progn
              (switch-to-buffer buffer)
              (emacs-lisp-mode)
              (insert ";; First prose sentence.\n"
                      "(setq cursor_should_stay_here 1)\n"
                      ";; Last prose sentence.\n")
              (setq-local proofread-auto-check nil)
              (setq-local proofread-targets 'comments)
              (proofread-mode 1)
              (goto-char (point-min))
              (search-forward "cursor_should")
              (let* ((proofread-backend 'llm)
                     (proofread-llm-provider
                      proofread-test--llm-provider)
                     (proofread-llm-provider-identity
                      proofread-test--llm-provider-identity)
                     (proofread-context-size 0)
                     (proofread-max-concurrent-requests 10)
                     (recorder
                      (proofread-test--make-backend-recorder))
                     (window (selected-window))
                     (before (proofread-test--window-state buffer
                                                           window)))
                (proofread-test--with-llm-capabilities
                 (cl-letf (((symbol-function
                             'proofread--backend-check)
                            (plist-get recorder :function)))
                   (funcall command)
                   (redisplay t)
                   (should (funcall (plist-get recorder :requests)))
                   (should (equal
                            (proofread-test--window-state buffer
                                                          window)
                            before))))))
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-check-region-normalizes-and-filters-selection ()
  "Normalize and filter regions passed to `proofread-check-region'."
  (with-temp-buffer
    (insert "Before. Alpha SECRET beta. After.")
    (goto-char (point-min))
    (search-forward "Alpha")
    (let ((beg (match-beginning 0)))
      (search-forward "SECRET")
      (add-text-properties (match-beginning 0) (match-end 0)
                           '(proofread-test-ignore t))
      (search-forward "beta.")
      (let ((end (match-end 0)))
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (let ((proofread-backend 'llm)
              (proofread-llm-provider proofread-test--llm-provider)
              (proofread-llm-provider-identity
               proofread-test--llm-provider-identity)
              (proofread-context-size 0)
              (proofread-ignored-properties '(proofread-test-ignore))
              (recorder (proofread-test--make-backend-recorder)))
          (proofread-test--with-llm-capabilities
           (cl-letf (((symbol-function 'proofread--backend-check)
                      (plist-get recorder :function)))
             (proofread-check-region end beg)
             (should
              (equal
               (mapcar (lambda (request)
                         (plist-get request :text))
                       (funcall (plist-get recorder :requests)))
               '("Alpha " " beta."))))))))))

(ert-deftest
    proofread-test-check-region-interactively-requires-active-region
    ()
  "`proofread-check-region' rejects an inactive region."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((transient-mark-mode t))
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active nil)
      (should-error (call-interactively #'proofread-check-region)
                    :type 'user-error)
      (should-not proofread--active-requests))))

(ert-deftest proofread-test-check-region-rejects-foreign-markers ()
  "`proofread-check-region' rejects markers from another buffer."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((other (generate-new-buffer " *proofread-region-marker*")))
      (unwind-protect
          (let ((foreign
                 (with-current-buffer other
                   (insert "Beta")
                   (copy-marker (point-min)))))
            (should-error
             (proofread-check-region foreign (point-max))
             :type 'user-error)
            (should-not proofread--active-requests))
        (kill-buffer other)))))

(ert-deftest
    proofread-test-check-region-interactive-feedback-is-shown ()
  "Show region feedback even when messages are inhibited."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((transient-mark-mode t)
          messages)
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active t)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args)
                         messages))))
        (call-interactively #'proofread-check-region)
        (should
         (equal messages
                (list (concat
                       "proofread: collected 1 selected range; "
                       "no available backend"))))))))

(ert-deftest
    proofread-test-check-at-point-dispatches-containing-chunk ()
  "Check the point's chunk with its surrounding context."
  (with-temp-buffer
    (insert "First.  Second sentence. Third.")
    (goto-char (point-min))
    (search-forward "Second sentence.")
    (let ((beg (match-beginning 0))
          (end (match-end 0)))
      (goto-char (+ beg 3))
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-backend 'llm)
            (proofread-llm-provider proofread-test--llm-provider)
            (proofread-llm-provider-identity
             proofread-test--llm-provider-identity)
            (proofread-language "en")
            (proofread-context-size 100)
            (proofread-context-sentences-before 1)
            (proofread-context-sentences-after 1)
            (recorder (proofread-test--make-backend-recorder))
            (before-point (point)))
        (proofread-test--with-llm-capabilities
         (cl-letf (((symbol-function 'proofread--backend-check)
                    (plist-get recorder :function)))
           (proofread-check-at-point)
           (let* ((requests (funcall (plist-get recorder :requests)))
                  (request (car requests)))
             (should (= (length requests) 1))
             (should (equal (plist-get request :text)
                            "Second sentence."))
             (should (equal (plist-get request :language) "en"))
             (should (string-match-p
                      "First" (plist-get request :context-before)))
             (should (string-match-p
                      "Third" (plist-get request :context-after))))
           (should (= (point) before-point))))))))

(ert-deftest proofread-test-request-ready-range-at-point-boundaries ()
  "Select point ranges at sentences, whitespace, and buffer edges."
  (with-temp-buffer
    (insert "First.  Second.")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "First.")
    (let ((first-beg (match-beginning 0))
          (first-end (match-end 0)))
      (search-forward "Second.")
      (let ((second-beg (match-beginning 0))
            (second-end (match-end 0)))
        (goto-char second-beg)
        (should (equal (proofread--request-ready-range-at-point)
                       (cons second-beg second-end)))
        (goto-char first-end)
        (should (equal (proofread--request-ready-range-at-point)
                       (cons first-beg first-end)))
        (goto-char (1+ first-end))
        (should-not (proofread--request-ready-range-at-point))
        (goto-char (point-max))
        (should (equal (proofread--request-ready-range-at-point)
                       (cons second-beg second-end))))))
  (with-temp-buffer
    (insert "abcdef")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((proofread-max-chunk-size 3))
      (goto-char 4)
      (should (equal (proofread--request-ready-range-at-point)
                     '(4 . 7)))))
  (with-temp-buffer
    (insert "First.\n\n")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-max))
    (should-not (proofread--request-ready-range-at-point)))
  (with-temp-buffer
    (insert "Alpha http://example.com")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-max))
    (should-not (proofread--request-ready-range-at-point))))

(ert-deftest proofread-test-check-at-point-rejects-ignored-text ()
  "Reject point text excluded by ignored properties."
  (with-temp-buffer
    (insert "Alpha SECRET beta.")
    (goto-char (point-min))
    (search-forward "SECRET")
    (let ((beg (match-beginning 0))
          (end (match-end 0)))
      (add-text-properties beg end '(proofread-test-ignore t))
      (goto-char beg)
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-ignored-properties '(proofread-test-ignore)))
        (should-error (proofread-check-at-point) :type 'user-error)
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-progress-messages-inhibited-by-default ()
  "Routine progress messages are quiet by default."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args)
                       messages))))
      (should proofread-inhibit-progress-messages)
      (proofread--progress-message "proofread: %s" "checking")
      (should-not messages))))

(ert-deftest proofread-test-progress-messages-can-be-enabled ()
  "Routine progress messages can be enabled explicitly."
  (let ((proofread-inhibit-progress-messages nil)
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args)
                       messages))))
      (proofread--progress-message "proofread: %s" "checking")
      (should (equal messages '("proofread: checking"))))))

(ert-deftest
    proofread-test-check-visible-range-is-quiet-in-background ()
  "Keep noninteractive visible-range checks quiet."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-background-message*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello")
            (proofread-mode 1)
            (let (messages)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args)
                                 messages)))
                        ((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update)
                           (point-max))))
                (proofread-check-visible-range)
                (should-not messages))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-interactive-progress-is-shown
    ()
  "Report progress for interactive visible-range checks."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-interactive-message*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello")
            (proofread-mode 1)
            (let (messages)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args)
                                 messages)))
                        ((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update)
                           (point-max))))
                (call-interactively #'proofread-check-visible-range)
                (should
                 (equal messages
                        '("proofread: collected 1 visible \
range; no available backend"))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-auto-check-defaults-enabled-and-is-buffer-local ()
  "`proofread-auto-check' defaults to enabled and localizes when set."
  (should (custom-variable-p 'proofread-auto-check))
  (should (default-value 'proofread-auto-check))
  (should (local-variable-if-set-p 'proofread-auto-check))
  (with-temp-buffer
    (setq proofread-auto-check nil)
    (should (local-variable-p 'proofread-auto-check))
    (should-not proofread-auto-check)
    (with-temp-buffer
      (should proofread-auto-check))))

(ert-deftest
    proofread-test-mode-enable-schedules-initial-idle-work ()
  "Enabling automatic checking schedules initial idle work."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-idle-delay 7)
          scheduled
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (seconds repeat function &rest args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (setq scheduled
                         (list seconds repeat function args))
                   'proofread-test-timer))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks
                         (1+ (or visible-checks 0))))))
        (proofread-mode 1)
        (should (= timer-count 1))
        (should proofread--pending-work)
        (should (eq proofread--idle-timer
                    'proofread-test-timer))
        (should (equal scheduled
                       (list 7 nil #'proofread--idle-timer-run
                             (list (current-buffer)))))
        (proofread--mark-pending-work)
        (should (= timer-count 1))
        (should (eq (proofread--idle-timer-run
                     (current-buffer))
                    'ran))
        (should (= visible-checks 1))
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest
    proofread-test-mode-enable-respects-disabled-auto-check ()
  "Enabling with automatic checking off schedules no initial work."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (let (timer-count)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   'proofread-test-timer)))
        (proofread-mode 1)
        (should-not timer-count)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest
    proofread-test-repeated-mode-enable-replaces-initial-timer ()
  "Repeated mode enable cancels and replaces the initial timer."
  (with-temp-buffer
    (insert "Alpha")
    (let (cancelled timers)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (let ((timer
                          (intern
                           (format "proofread-test-timer-%d"
                                   (1+ (length timers))))))
                     (push timer timers)
                     timer)))
                ((symbol-function 'timerp)
                 (lambda (object)
                   (memq object timers)))
                ((symbol-function 'cancel-timer)
                 (lambda (timer)
                   (push timer cancelled))))
        (add-hook 'proofread-diagnostics-changed-hook
                  #'proofread--mark-pending-work nil t)
        (proofread-mode 1)
        (let ((first-timer proofread--idle-timer))
          (proofread-mode 1)
          (let ((second-timer proofread--idle-timer))
            (should (= (length timers) 3))
            (should (equal cancelled (cdr timers)))
            (should-not (eq second-timer first-timer))
            (should (eq second-timer (car timers)))
            (should proofread--pending-work)
            (proofread-mode -1)
            (should (equal cancelled timers))
            (should-not proofread--pending-work)
            (should-not proofread--idle-timer)))))))

(ert-deftest proofread-test-positive-options-reject-zero-in-customize
    ()
  "Customize setters reject invalid positive Proofread options."
  (dolist (symbol '(proofread-max-chunk-size
                    proofread-llm-max-diagnostic-passes))
    (should (eq (get symbol 'custom-set)
                #'proofread--set-positive-integer-option))
    (should-error
     (funcall (get symbol 'custom-set) symbol 0))))

(ert-deftest
    proofread-test-auto-check-disabled-does-not-schedule-edit-work ()
  "Do not schedule edit work when automatic checking is off."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((proofread--request-queue '(manual-request))
          timer-count)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   'proofread-test-timer)))
        (insert "!")
        (should-not timer-count)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)
        (should (equal proofread--request-queue
                       '(manual-request)))))))

(ert-deftest
    proofread-test-auto-check-disabled-does-not-schedule-window-work
    ()
  "Do not schedule window work when automatic checking is off."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-auto-check-window*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let ((proofread--request-queue '(manual-request))
                  timer-count)
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (_seconds _repeat _function &rest
                                           _args)
                           (setq timer-count (1+ (or timer-count 0)))
                           'proofread-test-timer)))
                (proofread--window-scroll (selected-window)
                                          (point-min))
                (proofread--window-configuration-change)
                (should-not timer-count)
                (should-not proofread--pending-work)
                (should-not proofread--idle-timer)
                (should (equal proofread--request-queue
                               '(manual-request))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-auto-check-disabled-allows-manual-visible-check ()
  "Manual visible checking works when automatic checking is disabled."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-manual-check*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let (dispatched)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional _window) (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update)
                           (point-max)))
                        ((symbol-function
                          'proofread--supported-backend-p)
                         (lambda () t))
                        ((symbol-function
                          'proofread--request-ready-chunks-for-islands)
                         (lambda (_islands) '((:text "Alpha"))))
                        ((symbol-function
                          'proofread--dispatch-request-ready-chunks)
                         (lambda (chunks)
                           (setq dispatched chunks)
                           '(proofread-test-request))))
                (proofread-check-visible-range)
                (should (equal dispatched '((:text "Alpha")))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-disabled-auto-check-stale-timer-does-not-check ()
  "A stale timer does not check after automatic checking is disabled."
  (with-temp-buffer
    (insert "Alpha")
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (proofread-mode 1)
        (should (= timer-count 1))
        (setq proofread-auto-check nil)
        (should-not (proofread--idle-timer-run buffer))
        (should-not visible-checks)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)
        (setq proofread-auto-check t)
        (insert "?")
        (should (= timer-count 2))
        (should proofread--pending-work)))))

(ert-deftest proofread-test-edit-schedules-idle-work ()
  "Mark work pending and schedule a timer after an edit."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((proofread-idle-delay 7)
          scheduled)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (seconds repeat function &rest args)
                   (setq scheduled (list seconds repeat function
                                         args))
                   'proofread-test-timer)))
        (insert "!")
        (should proofread--pending-work)
        (should (eq proofread--idle-timer 'proofread-test-timer))
        (should (equal scheduled
                       (list 7 nil #'proofread--idle-timer-run
                             (list (current-buffer)))))))))

(ert-deftest proofread-test-edit-does-not-call-backend-synchronously
    ()
  "Editing schedules work without calling the backend inline."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((proofread-backend 'llm)
          backend-calls)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread--backend-check)
                 (lambda (_request _callback &optional _backend)
                   (setq backend-calls (1+ (or backend-calls 0))))))
        (insert "!")
        (should proofread--pending-work)
        (should-not backend-calls)))))

(ert-deftest proofread-test-repeated-edits-coalesce-before-idle ()
  "Repeated edits before idle time reuse one timer and run one check."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
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
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (should (eq (proofread--idle-timer-run buffer) 'ran))
        (insert "?")
        (should (= timer-count 2))
        (should (= visible-checks 1))
        (should proofread--pending-work)))))

(ert-deftest
    proofread-test-programming-idle-check-preserves-window-state ()
  "Preserve user and target windows during a programming idle check."
  (save-window-excursion
    (let ((user-buffer (generate-new-buffer " *proofread-idle-user*"))
          (target-buffer (generate-new-buffer
                          " *proofread-idle-target*")))
      (unwind-protect
          (let* ((user-window (selected-window))
                 (target-window (split-window-right))
                 (recorder (proofread-test--make-backend-recorder)))
            (set-window-buffer user-window user-buffer)
            (with-current-buffer user-buffer
              (dotimes (line 100)
                (insert (format "User line %03d must stay visible.\n"
                                line)))
              (goto-char (point-min))
              (forward-line 50)
              (move-to-column 8))
            (set-window-point
             user-window (with-current-buffer user-buffer (point)))
            (set-window-start
             user-window
             (with-current-buffer user-buffer
               (save-excursion
                 (goto-char (point-min))
                 (forward-line 30)
                 (point))))
            (with-current-buffer target-buffer
              (emacs-lisp-mode)
              (insert ";; First prose sentence.\n"
                      "(setq target_cursor_stays_here 1)\n"
                      ";; Last prose sentence.\n")
              (setq-local proofread-targets 'comments)
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t)
              (goto-char (point-min))
              (search-forward "target_cursor")
              (setq proofread--pending-work t))
            (set-window-buffer target-window target-buffer)
            (set-window-point
             target-window (with-current-buffer target-buffer
                             (point)))
            (set-window-start target-window 1)
            (select-window user-window)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 10)
                  (before
                   (proofread-test--window-state
                    target-buffer target-window)))
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'proofread--backend-check)
                          (plist-get recorder :function)))
                 (should (eq (proofread--idle-timer-run
                              target-buffer) 'ran))
                 (redisplay t)
                 (let ((requests (funcall (plist-get recorder
                                                     :requests)))
                       (callbacks (funcall (plist-get recorder
                                                      :callbacks))))
                   (should requests)
                   (let ((valid-index
                          (cl-position-if
                           (lambda (request)
                             (string-search
                              "First" (plist-get request :text)))
                           requests)))
                     (should valid-index)
                     (let* ((valid-request
                             (nth valid-index requests))
                            (valid-text (plist-get valid-request
                                                   :text))
                            (relative-beg
                             (string-search "First" valid-text)))
                       (dotimes (index (length requests))
                         (funcall
                          (nth index callbacks)
                          (if (= index valid-index)
                              (proofread--llm-success-result
                               valid-request
                               (proofread-test--response-content
                                (list
                                 (proofread-test--response-diagnostic
                                  relative-beg (+ relative-beg 5)
                                  "First" '("First"))))
                               1)
                            (proofread--backend-error-result
                             (nth index requests) 'test-error
                             (concat "Simulated background failure: "
                                     (make-string 600 ?x)))))))))
                 (redisplay t)
                 (should (equal
                          (proofread-test--window-state
                           target-buffer target-window)
                          before))))))
        (kill-buffer user-buffer)
        (kill-buffer target-buffer)))))

(ert-deftest proofread-test-window-activity-marks-proofread-buffer ()
  "Mark only live `proofread-mode' buffers after window activity."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-mode*"))
          (plain-buffer
           (generate-new-buffer " *proofread-window-plain*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t))
            (with-current-buffer plain-buffer
              (insert "Beta"))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest
                                         _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format
                                  "proofread-test-window-timer-%d"
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

(ert-deftest proofread-test-window-configuration-change-marks-buffer
    ()
  "Window configuration changes mark proofread buffers pending."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-config*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest
                                         _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format
                                  "proofread-test-window-timer-%d"
                                  timer-count)))))
              (switch-to-buffer proofread-buffer)
              (proofread--window-configuration-change)
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)))))

(ert-deftest proofread-test-disable-mode-clears-scheduled-work ()
  "Disabling `proofread-mode' clears pending work and timer state."
  (with-temp-buffer
    (insert "Alpha")
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_seconds _repeat _function &rest _args)
                 'proofread-test-timer)))
      (proofread-mode 1)
      (should proofread--pending-work)
      (should proofread--idle-timer)
      (proofread-mode -1)
      (should-not proofread--pending-work)
      (should-not proofread--idle-timer)
      (should-not (memq #'proofread--after-change
                        after-change-functions)))))

(ert-deftest
    proofread-test-disabled-mode-stale-timer-does-not-check-visible ()
  "A stale timer after mode disable does not run visible checking."
  (with-temp-buffer
    (insert "Alpha")
    (let ((buffer (current-buffer))
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (proofread-mode 1)
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

(ert-deftest proofread-test-chunk-spans-for-ranges-ordinary-paragraph
    ()
  "Sentence chunk spans record exact buffer boundaries."
  (with-temp-buffer
    (insert "First paragraph. Second line.\n\nIgnored")
    (let* ((paragraph-end (save-excursion
                            (goto-char (point-min))
                            (search-forward "\n\n")
                            (- (point) 2)))
           (spans (proofread--chunk-spans-for-ranges
                   (list (cons (point-min) paragraph-end)))))
      (should (= (length spans) 2))
      (should (equal (proofread-test--span-texts spans)
                     '("First paragraph." "Second line.")))
      (should (= (caar spans) (point-min)))
      (should (= (cdr (car (last spans))) paragraph-end)))))

(ert-deftest proofread-test-chunk-spans-for-ranges-skips-whitespace ()
  "Chunk spans skip empty and whitespace-only paragraphs."
  (with-temp-buffer
    (insert "  \n\t\n\n")
    (should-not (proofread--chunk-spans-for-ranges
                 (list (cons (point-min) (point-max)))))))

(ert-deftest proofread-test-chunk-spans-split-oversized-paragraph ()
  "Oversized paragraphs split into bounded contiguous chunks."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (let* ((proofread-max-chunk-size 5)
           (spans (proofread--chunk-spans-for-ranges
                   (list (cons (point-min) (point-max))))))
      (should (equal spans '((1 . 6) (6 . 11) (11 . 13))))
      (should (equal (proofread-test--span-texts spans)
                     '("abcde" "fghij" "kl")))
      (should (cl-every (lambda (span)
                          (<= (- (cdr span) (car span))
                              proofread-max-chunk-size))
                        spans)))))

(ert-deftest proofread-test-chunking-preserves-buffer-and-state ()
  "Preserve buffer contents, properties, and proofread state."
  (with-temp-buffer
    (insert (propertize "Alpha paragraph" 'face 'bold 'proofread-test
                        t))
    (proofread-mode 1)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick)))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (= (length spans) 1))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should-not proofread--active-requests)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest
    proofread-test-sentence-chunking-splits-chinese-paragraph ()
  "Split Chinese paragraphs at sentence punctuation."
  (with-temp-buffer
    (insert "第一句。第二句！第三句？")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '("第一句。" "第二句！" "第三句？"))))))

(ert-deftest
    proofread-test-sentence-chunking-keeps-hard-wrapped-sentence ()
  "A single hard-wrap newline does not split a logical sentence."
  (with-temp-buffer
    (insert "第一句\n第二句")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '("第一句\n第二句")))
      (should (equal spans
                     (list (cons (point-min) (point-max))))))))

(ert-deftest
    proofread-test-sentence-chunking-splits-english-paragraph ()
  "Split English sentences while keeping common inline forms."
  (with-temp-buffer
    (insert
     (concat "Dr. Smith measured 3.14. It rained. "
             "Visit example.com/path? Done!"))
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '("Dr. Smith measured 3.14."
                       "It rained."
                       "Visit example.com/path?"
                       "Done!"))))))

(ert-deftest proofread-test-sentence-chunking-keeps-closing-quote ()
  "Keep closing quotes and brackets with sentence punctuation."
  (with-temp-buffer
    (insert "他说“第一句。”第二句。")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '("他说“第一句。”" "第二句。"))))))

(ert-deftest
    proofread-test-sentence-chunking-bounds-oversized-sentence ()
  "A single oversized sentence still splits into bounded chunks."
  (with-temp-buffer
    (insert "一二三四五六。")
    (let ((proofread-max-chunk-size 3))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--span-texts spans)
                       '("一二三" "四五六" "。")))
        (should (equal spans
                       '((1 . 4) (4 . 7) (7 . 8))))
        (should (cl-every (lambda (span)
                            (<= (- (cdr span) (car span))
                                proofread-max-chunk-size))
                          spans))))))

(ert-deftest
    proofread-test-sentence-chunking-keeps-unpunctuated-paragraph ()
  "Unpunctuated paragraphs stay one logical sentence."
  (with-temp-buffer
    (insert "第一句 第二句")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '("第一句 第二句")))
      (should (= (length spans) 1)))))

(ert-deftest proofread-test-sentence-chunking-filtering-still-applies
    ()
  "Keep ignored text filtered after splitting sentences."
  (with-temp-buffer
    (insert (concat "甲 http://example.com 乙。"
                    "丙 user@example.com 丁。"
                    "戊 HIDDEN 己。"
                    "庚 SKIP 辛。"
                    "壬 DROP 癸。"))
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (drop-beg (progn
                      (goto-char (point-min))
                      (search-forward "DROP")
                      (match-beginning 0)))
          (drop-end (match-end 0))
          (proofread-ignored-faces '(proofread-test-ignore))
          (proofread-ignored-properties '(proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties hidden-beg hidden-end '(invisible t))
      (add-text-properties skip-beg skip-end
                           '(face proofread-test-ignore))
      (add-text-properties drop-beg drop-end
                           '(proofread-test-ignore t))
      (let* ((chunks (proofread--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (text (mapconcat #'identity
                              (proofread-test--chunk-texts chunks)
                              "")))
        (dolist (chunk chunks)
          (should (equal (plist-get chunk :text)
                         (buffer-substring-no-properties
                          (plist-get chunk :beg)
                          (plist-get chunk :end)))))
        (should-not (string-match-p "http://example.com" text))
        (should-not (string-match-p "user@example.com" text))
        (should-not (string-match-p "HIDDEN" text))
        (should-not (string-match-p "SKIP" text))
        (should-not (string-match-p "DROP" text))
        (should (string-match-p "甲 " text))
        (should (string-match-p " 癸。" text))))))

(ert-deftest
    proofread-test-sentence-chunking-preserves-buffer-and-state ()
  "Sentence-aware chunking preserves buffer and proofread state."
  (with-temp-buffer
    (insert (propertize "第一句。第二句。" 'face 'bold
                        'proofread-test t))
    (proofread-mode 1)
    (goto-char 3)
    (push-mark 5 t t)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick))
          (before-point (point))
          (before-mark (mark t)))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--span-texts spans)
                       '("第一句。" "第二句。")))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (= (point) before-point))
        (should (= (mark t) before-mark))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should-not proofread--active-requests)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-request-ready-chunks-filter-url ()
  "Exclude URLs but retain surrounding request text."
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

(ert-deftest proofread-test-request-ready-chunks-filter-ignored-face
    ()
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

(ert-deftest
    proofread-test-request-ready-chunks-filter-ignored-property ()
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
      (let ((chunks (proofread--request-ready-chunks-for-ranges
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
          (should-not
           (string-match-p "http://example.com"
                           (plist-get chunk :text)))
          (should-not
           (string-match-p "http://example.com"
                           (plist-get chunk :context-before)))
          (should-not
           (string-match-p
            "http://example.com"
            (plist-get chunk :context-after))))))))

(ert-deftest proofread-test-request-ready-context-default-sentences ()
  "Use one complete context sentence by default."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) "前文。"))
      (should (equal (plist-get chunk :context-after) "后文。")))))

(ert-deftest proofread-test-request-ready-context-configured-counts ()
  "Configured sentence counts change request-ready context windows."
  (with-temp-buffer
    (insert "一。二。三。目标。四。五。六。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (proofread-context-sentences-before 2)
           (proofread-context-sentences-after 2)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) "二。三。"))
      (should (equal (plist-get chunk :context-after) "四。五。")))))

(ert-deftest proofread-test-request-ready-context-zero-counts ()
  "Zero sentence counts disable the corresponding context direction."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (proofread-context-sentences-before 0)
           (proofread-context-sentences-after 0)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest
    proofread-test-request-ready-context-keeps-hard-wrap-sentence ()
  "Keep hard-wrapped prose as one logical context sentence."
  (with-temp-buffer
    (insert "前半句\n后半句。目标句。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before)
                     "前半句\n后半句。"))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest
    proofread-test-request-ready-context-ignores-visual-wrapping ()
  "Visual wrapping does not affect request-ready sentence context."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (range (list (cons (point-min) (point-max))))
           (plain (proofread--request-ready-chunks-for-ranges range)))
      (visual-line-mode 1)
      (let ((wrapped (proofread--request-ready-chunks-for-ranges
                      range)))
        (should (equal (proofread-test--chunk-texts wrapped)
                       (proofread-test--chunk-texts plain)))
        (cl-mapc
         (lambda (left right)
           (should (equal (plist-get left :context-before)
                          (plist-get right :context-before)))
           (should (equal (plist-get left :context-after)
                          (plist-get right :context-after))))
         plain wrapped)))))

(ert-deftest
    proofread-test-request-ready-context-stops-at-blank-lines ()
  "Blank lines stop request-ready sentence context search."
  (with-temp-buffer
    (insert "前文。\n\n目标句。\n\n后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest
    proofread-test-request-ready-context-stops-at-org-structure ()
  "Org structural lines stop request-ready sentence context search."
  (dolist
      (text
       '("前文。\n* 标题\n目标句。"
         "前文。\n#+TITLE: 标题\n目标句。"
         "前文。\n:PROPERTIES:\n\
:CUSTOM_ID: x\n:END:\n目标句。"
         "前文。\n- 项目\n目标句。"
         "前文。\n| 表格 |\n目标句。"
         "前文。\n#+begin_quote\n引用。\n\
#+end_quote\n目标句。"))
    (with-temp-buffer
      (org-mode)
      (insert text)
      (let* ((proofread-language "zh")
             (proofread-context-size 300)
             (chunks (proofread--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (proofread-test--chunk-with-text chunks
                                                     "目标句。")))
        (should chunk)
        (should (equal (plist-get chunk :context-before) ""))))))

(ert-deftest
    proofread-test-request-ready-context-filters-ignored-text ()
  "Exclude ignored text from sentence context.

This covers URLs, email, invisible text, faces, and properties."
  (with-temp-buffer
    (insert
     (concat "访问 http://example.com，联系 "
             "user@example.com，保留 HIDDEN SKIP DROP。目标句。"))
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (drop-beg (progn
                      (goto-char (point-min))
                      (search-forward "DROP")
                      (match-beginning 0)))
          (drop-end (match-end 0))
          (proofread-language "zh")
          (proofread-context-size 300)
          (proofread-ignored-faces '(proofread-test-ignore))
          (proofread-ignored-properties '(proofread-test-ignore)))
      (add-text-properties hidden-beg hidden-end '(invisible t))
      (add-text-properties skip-beg skip-end
                           '(face proofread-test-ignore))
      (add-text-properties drop-beg drop-end
                           '(proofread-test-ignore t))
      (let* ((chunks (proofread--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (proofread-test--chunk-with-text chunks
                                                     "目标句。"))
             (context (plist-get chunk :context-before)))
        (should chunk)
        (should-not (string-match-p "http://example.com" context))
        (should-not (string-match-p "user@example.com" context))
        (should-not (string-match-p "HIDDEN" context))
        (should-not (string-match-p "SKIP" context))
        (should-not (string-match-p "DROP" context))
        (should (string-match-p "访问" context))))))

(ert-deftest proofread-test-request-ready-context-oversized-fallback
    ()
  "Oversized single-sentence context uses bounded character fallback."
  (with-temp-buffer
    (insert "很长很长的前置句子。目标句。")
    (let* ((proofread-language "zh")
           (proofread-context-size 4)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标句。"))
           (beg (plist-get chunk :beg))
           (expected (buffer-substring-no-properties (- beg 4) beg)))
      (should chunk)
      (should (equal (plist-get chunk :context-before) expected))
      (should (<= (length (plist-get chunk :context-before))
                  proofread-context-size))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest proofread-test-request-ready-context-fragment-fallback ()
  "Oversized unpunctuated context uses bounded character context."
  (with-temp-buffer
    (insert "abcdefTARGETuvwxyz")
    (let ((proofread-context-size 3)
          (proofread-context-sentences-before 1)
          (proofread-context-sentences-after 1))
      (let ((chunk (proofread--make-request-ready-chunk 7 13)))
        (should (equal (plist-get chunk :text) "TARGET"))
        (should (equal (plist-get chunk :context-before) "def"))
        (should (equal (plist-get chunk :context-after) "uvw"))))))

(ert-deftest proofread-test-cache-key-varies-by-identity ()
  "Cache keys change when text or environment identity changes."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity "provider-a"))
      (insert "Alpha")
      (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                          (list (cons (point-min) (point-max))))))
             (base-key (proofread--cache-key chunk 'llm)))
        (let ((proofread-llm-provider-identity "provider-b"))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'llm))))
        (let ((changed-language (copy-sequence chunk)))
          (setq changed-language
                (plist-put changed-language :language "fr"))
          (should-not (equal base-key
                             (proofread--cache-key changed-language
                                                   'llm))))
        (let ((changed-mode (copy-sequence chunk)))
          (setq changed-mode
                (plist-put changed-mode :major-mode 'org-mode))
          (should-not (equal base-key
                             (proofread--cache-key changed-mode
                                                   'llm))))
        (let ((changed-text (copy-sequence chunk)))
          (setq changed-text
                (plist-put changed-text :text "Beta"))
          (should-not (equal base-key
                             (proofread--cache-key changed-text
                                                   'llm))))))))

(ert-deftest proofread-test-cache-key-varies-by-context ()
  "Cover context, configuration, and content in cache keys."
  (let* ((proofread-context-size 300)
         (proofread-context-sentences-before 1)
         (proofread-context-sentences-after 1)
         (chunk '(:text "目标句。"
                        :context-before "前文。"
                        :context-after "后文。"
                        :language "zh"
                        :major-mode org-mode))
         (base-key (proofread--cache-key chunk 'llm))
         (context (plist-get base-key :context)))
    (should (eq (plist-get context :strategy) 'sentence-window))
    (let ((proofread-context-sentences-before 2))
      (should-not (equal base-key (proofread--cache-key chunk 'llm))))
    (let ((proofread-context-size 40))
      (should-not (equal base-key (proofread--cache-key chunk 'llm))))
    (let ((changed (plist-put (copy-sequence chunk)
                              :context-before "别的前文。")))
      (should-not (equal base-key (proofread--cache-key changed
                                                        'llm))))))

(ert-deftest
    proofread-test-cache-key-context-excludes-volatile-values ()
  "Context-aware cache keys exclude volatile objects and raw secrets."
  (with-temp-buffer
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider [:api-key "secret-token"])
           (proofread-llm-provider-identity
            '(:provider "stable-provider"))
           (chunk (list :text "目标句。"
                        :context-before "secret-token 前文。"
                        :context-after "后文。"
                        :language "zh"
                        :major-mode 'org-mode
                        :buffer (current-buffer)
                        :callback #'ignore))
           (key (proofread--cache-key chunk)))
      (should-not (plist-member key :buffer))
      (should-not (plist-member key :callback))
      (should-not (proofread-test--tree-member-p (current-buffer)
                                                 key))
      (should-not (proofread-test--tree-member-p
                   proofread-llm-provider key))
      (should-not (proofread-test--tree-member-p "secret-token"
                                                 key)))))

(ert-deftest proofread-test-llm-backend-identity-is-cache-compatible
    ()
  "LLM backend identity is structured and usable for cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity
            proofread-test--llm-provider-identity)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (should (equal (proofread--backend-identity)
                     `(:backend llm
                                :provider
                                ,proofread-test--llm-provider-identity
                                :response-strategy prompt-json
                                :diagnostic-passes 3
                                :contract-version 2)))
      (should (proofread--backend-identity-p
               (plist-get request :backend-identity)))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request request)))))

(ert-deftest proofread-test-cache-read-write-hit-and-miss ()
  "Read and write cache entries only in active proofread buffers."
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
  "Cached diagnostics convert ranges between coordinate systems."
  (let* ((request '(:beg 10 :end 20 :text "0123456789" :backend llm))
         (diagnostic (proofread-test--diagnostic-for-range 12 15
                                                           "234"))
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
  "Reuse cached diagnostics for unchanged visible text."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-hit*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback
                  backend-calls)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update) 5))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq backend-calls
                                  (1+ (or backend-calls 0)))
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (should (= backend-calls 1))
                 (let ((diagnostic
                        (proofread-test--diagnostic-for-range
                         1 5 "helo")))
                   (should (eq (funcall
                                callback
                                (proofread--backend-success-result
                                 request (list diagnostic)))
                               'applied))
                   (should (= (hash-table-count proofread--cache) 1))
                   (proofread-check-visible-range)
                   (should (= backend-calls 1))
                   (should (equal proofread--diagnostics
                                  (list diagnostic)))
                   (should (= (length proofread--overlays) 1))
                   (proofread-clear)
                   (setq proofread--diagnostics nil)
                   (proofread-check-visible-range)
                   (should (= backend-calls 1))
                   (should (equal proofread--diagnostics
                                  (list diagnostic)))
                   (should (= (length proofread--overlays) 1)))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-backend-result-replaces-request-range-diagnostics
    ()
  "Replace rather than duplicate diagnostics for the same request."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'applied))
      (should (= (length proofread--diagnostics) 1))
      (should (= (length proofread--overlays) 1))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'applied))
      (should (equal proofread--diagnostics (list diagnostic)))
      (should (= (length proofread--overlays) 1))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result request nil))
                  'applied))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-partial-backend-result-merges-without-caching ()
  "Merge partial results without writing them to the cache."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (old (proofread-test--diagnostic-for-range 1 5 "helo"))
           (new (proofread-test--diagnostic-for-range 6 10 "wrld"))
           (partial
            (proofread--backend-partial-success-result
             request (list new new) '((:reason ambiguous-text)))))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result request (list
                                                               old)))
                  'applied))
      (proofread-clear-cache)
      (should (eq (proofread--handle-backend-result partial)
                  'applied))
      (should (equal proofread--diagnostics (list old new)))
      (should (= (length proofread--overlays) 2))
      (should (= (hash-table-count proofread--cache) 0))
      (should (eq (proofread--handle-backend-result partial)
                  'applied))
      (should (equal proofread--diagnostics (list old new)))
      (should (= (length proofread--overlays) 2)))))

(ert-deftest proofread-test-cache-miss-calls-backend ()
  "A visible chunk with no cache entry is sent to the backend."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-miss*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo")
            (proofread-mode 1)
            (let* ((proofread-backend 'llm)
                   (proofread-llm-provider
                    proofread-test--llm-provider)
                   (proofread-llm-provider-identity
                    proofread-test--llm-provider-identity)
                   (recorder (proofread-test--make-backend-recorder)))
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (plist-get recorder :function)))
                 (proofread-check-visible-range)
                 (should (= (length (funcall
                                     (plist-get recorder :requests)))
                            1))
                 (should (equal (plist-get
                                 (car (funcall
                                       (plist-get recorder
                                                  :requests)))
                                 :text)
                                "helo"))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-filtering-precedes-cache-and-backend-dispatch ()
  "Filtered chunks are used for cache lookup and backend dispatch."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-filter-cache*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let* ((proofread-backend 'llm)
                   (proofread-llm-provider
                    proofread-test--llm-provider)
                   (proofread-llm-provider-identity
                    proofread-test--llm-provider-identity)
                   (proofread-llm-response-strategy 'prompt-json)
                   (proofread-context-size 0)
                   (chunks (proofread--request-ready-chunks-for-ranges
                            (list (cons (point-min) (point-max)))))
                   (cached-request
                    (proofread--make-backend-request (car chunks)
                                                     'llm))
                   (cached-diagnostic
                    (proofread-test--diagnostic-with-kind
                     1 6 "Alpha" 'spelling))
                   (recorder (proofread-test--make-backend-recorder)))
              (proofread--cache-write-request
               cached-request (list cached-diagnostic))
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (plist-get recorder :function)))
                 (proofread-check-visible-range)
                 (should (equal (mapcar
                                 (lambda (request)
                                   (plist-get request :text))
                                 (funcall (plist-get recorder
                                                     :requests)))
                                '(" Beta")))
                 (should (equal proofread--diagnostics
                                (list cached-diagnostic)))
                 (should (= (length proofread--overlays) 1))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-cache-invalidation-misses ()
  "Backend identity and text changes miss old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider-a")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (let ((proofread-llm-provider-identity "provider-b"))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk))))
      (let ((changed-chunk (plist-put (copy-sequence chunk)
                                      :text "Beta")))
        (should-not
         (proofread--cache-read-request
          (proofread--make-backend-request changed-chunk)))))))

(ert-deftest proofread-test-stale-and-error-results-are-not-cached ()
  "Do not cache stale or failed backend results."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'stale))
      (should (= (hash-table-count proofread--cache) 0))
      (let ((fresh-request
             (proofread--make-backend-request
              (car (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
              'llm)))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-error-result
                      fresh-request 'llm-failure "LLM failure"))
                    'error))
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-cache-hit-validates-current-text ()
  "Drop cached diagnostics when their source text has changed."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (entry (proofread--make-cache-entry request (list
                                                        diagnostic))))
      (delete-region 1 5)
      (insert "hello")
      (should (eq (proofread--apply-cache-entry request entry)
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-supported-backend ()
  "Only the LLM backend symbol is supported."
  (proofread-test--with-llm-capabilities
   (let ((proofread-backend 'llm)
         (proofread-llm-provider proofread-test--llm-provider))
     (should (proofread--supported-backend-p))
     (should (proofread--supported-backend-p 'llm))
     (should-not
      (proofread--supported-backend-p 'unknown-backend)))))

(ert-deftest proofread-test-unknown-backend-is-unsupported ()
  "Unknown backend symbols use unsupported dispatch."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-backend 'unknown-backend)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request
            (proofread--make-backend-request
             chunk 'unknown-backend))
           result)
      (should-not (proofread--supported-backend-p))
      (should-not (proofread--supported-backend-p 'unknown-backend))
      (should (proofread--backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'unknown-backend))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :request) request))
      (should (eq (plist-get result :error) 'unsupported-backend)))))

(ert-deftest
    proofread-test-llm-backend-support-is-configuration-independent ()
  "Keep LLM support detectable despite configuration errors."
  (let ((proofread-backend 'llm)
        (proofread-llm-provider nil))
    (should (proofread--supported-backend-p))
    (should (proofread--supported-backend-p 'llm)))
  (let ((proofread-backend 'llm)
        (proofread-llm-provider 'proofread-test-provider))
    (should (proofread--supported-backend-p))
    (should (proofread--supported-backend-p 'llm)))
  (let ((proofread-backend 'llm)
        (proofread-llm-provider 'proofread-test-provider)
        (proofread-llm-response-strategy 'provider-json))
    (should (proofread--supported-backend-p))
    (should (proofread--supported-backend-p 'llm)))
  (proofread-test--with-llm-capabilities
   (let ((proofread-backend 'llm)
         (proofread-llm-provider proofread-test--llm-provider))
     (should (proofread--supported-backend-p))
     (should (proofread--supported-backend-p 'llm)))))

(ert-deftest
    proofread-test-llm-provider-unavailable-is-asynchronous-error ()
  "Missing LLM provider reports an asynchronous backend error."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider nil)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (should (proofread--backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'llm))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :error)
                  'llm-provider-unavailable)))))

(ert-deftest
    proofread-test-llm-structured-output-unavailable-is-asynchronous-error
    ()
  "Report missing schema output for forced provider JSON."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-response-strategy 'provider-json)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (cl-letf (((symbol-function 'llm-capabilities)
                 (lambda (_provider)
                   '(generation)))
                ((symbol-function 'llm-chat-async)
                 (lambda (&rest _)
                   (error "Unexpected llm-chat-async call"))))
        (should (proofread--backend-check
                 request
                 (lambda (backend-result)
                   (setq result backend-result))
                 'llm))
        (should-not result)
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error)
                    'llm-structured-output-unavailable))))))

(ert-deftest
    proofread-test-deepseek-v4-flash-uses-prompt-json-fallback ()
  "Use prompt-only JSON for DeepSeek v4 flash without schemas."
  (require 'llm-deepseek)
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider
            (make-llm-deepseek :chat-model "deepseek-v4-flash"))
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content (proofread-test--response-content nil))
           captured-prompt
           result)
      (should-not (memq 'json-response
                        (llm-capabilities proofread-llm-provider)))
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider prompt success _error
                                    &optional _multi-output)
                   (setq captured-prompt prompt)
                   (funcall success content)
                   'proofread-test-llm-handle)))
        (should (proofread--backend-check
                 request
                 (lambda (backend-result)
                   (setq result backend-result))
                 'llm))
        (should-not result)
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'ok))
        (should-not (plist-get result :diagnostics))
        (should-not (llm-chat-prompt-response-format captured-prompt))
        (let* ((interaction
                (car (llm-chat-prompt-interactions captured-prompt)))
               (prompt-text
                (llm-chat-prompt-interaction-content interaction)))
          (should (string-match-p "JSON schema:" prompt-text))
          (should (string-match-p "no Markdown code fence"
                                  prompt-text))
          (should (string-match-p "Text:\nhelo" prompt-text)))))))

(ert-deftest proofread-test-llm-provider-identity-is-stable ()
  "LLM identity uses stable provider metadata, not provider objects."
  (let ((proofread-backend 'llm)
        (proofread-llm-provider
         [:proofread-test-provider :api-key "secret-token"])
        (proofread-llm-provider-identity nil))
    (cl-letf (((symbol-function 'llm-name)
               (lambda (_provider)
                 "qwen3:1.7b")))
      (let ((identity (proofread--backend-identity)))
        (should (eq (plist-get identity :backend) 'llm))
        (let ((provider (plist-get identity :provider)))
          (should (equal (plist-get provider :name) "qwen3:1.7b"))
          (should (integerp (plist-get provider :session))))
        (should (eq (plist-get identity :response-strategy)
                    'prompt-json))
        (should (= (plist-get identity :contract-version) 2))
        (should-not (string-match-p
                     "secret-token"
                     (prin1-to-string identity)))
        (dolist (volatile-key
                 '(:id :buffer :callback :timer :process :request))
          (should-not (plist-member identity volatile-key)))))))

(ert-deftest proofread-test-llm-provider-identity-cache-miss ()
  "Changing stable LLM provider identity misses old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-provider-identity "provider-a")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request
               (proofread--make-backend-request chunk)))
      (let ((proofread-llm-provider-identity "provider-b"))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk)))))))

(ert-deftest proofread-test-llm-provider-object-cache-miss ()
  "Miss the cache when LLM provider objects change."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider [:provider-a :api-key
                                                "secret-token"])
           (proofread-llm-provider-identity nil)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request
               (proofread--make-backend-request chunk)))
      (let ((proofread-llm-provider [:provider-b :api-key
                                                 "secret-token"]))
        (let ((key (proofread--cache-key
                    (proofread--make-backend-request chunk))))
          (should-not (proofread-test--tree-member-p
                       proofread-llm-provider key))
          (should-not (proofread-test--tree-member-p
                       "secret-token" key)))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk)))))))

(ert-deftest
    proofread-test-llm-dispatch-builds-schema-prompt-asynchronously ()
  "Dispatch an async schema prompt built from request fields."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (let* ((proofread-language "en")
           (proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           captured-provider
           captured-prompt
           captured-multi-output
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (provider prompt success _error
                                   &optional multi-output)
                   (setq captured-provider provider)
                   (setq captured-prompt prompt)
                   (setq captured-multi-output multi-output)
                   (funcall success content)
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (let ((handle
               (proofread--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm)))
          (should (equal (plist-get handle :requests)
                         '(proofread-test-llm-handle)))
          (should (eq captured-provider proofread-llm-provider))
          (should-not captured-multi-output)
          (should (equal (llm-chat-prompt-response-format
                          captured-prompt)
                         proofread--structured-response-schema))
          (let* ((interaction
                  (car (llm-chat-prompt-interactions
                        captured-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "requested response schema"
                                    prompt-text))
            (should (string-match-p "Language: \"en\"" prompt-text))
            (should (string-match-p "Major mode: text-mode"
                                    prompt-text))
            (should (string-match-p "Text:\nhelo" prompt-text)))
          (should-not result)
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok))
          (should (eq (plist-get
                       (car (plist-get result :diagnostics))
                       :source)
                      'llm)))))))

(ert-deftest proofread-test-llm-prompt-describes-character-ranges ()
  "LLM prompts describe chunk-relative character ranges."
  (with-temp-buffer
    (org-mode)
    (insert "青晨六点。")
    (let ((proofread-language "zh")
          (proofread-context-size 0)
          (proofread-llm-provider 'proofread-test-provider)
          captured-prompt)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider prompt _success _error
                                    &optional _multi-output)
                   (setq captured-prompt prompt)
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                            (list (cons (point-min) (point-max))))))
               (request (proofread--make-backend-request chunk 'llm)))
          (proofread--backend-check request #'ignore 'llm)
          (let* ((interaction
                  (car (llm-chat-prompt-interactions
                        captured-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "Text:\n青晨六点。" prompt-text))
            (should (string-match-p "range end is exclusive"
                                    prompt-text))))))))

(ert-deftest proofread-test-llm-success-enters-overlay-pipeline ()
  "Send fresh LLM diagnostics through the normal result path."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 1 5 "helo"))))
           request
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success
                                                          content)))
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (setq request
              (proofread--make-backend-request
               (car (proofread--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max)))))
               'llm))
        (should (proofread--dispatch-backend-request
                 request
                 (lambda (backend-result)
                   (setq result backend-result)
                   (proofread--handle-backend-result backend-result))
                 'llm))
        (should (proofread-test--wait-for
                 (lambda ()
                   proofread--diagnostics)))
        (should (eq (plist-get result :status) 'ok))
        (should-not (plist-get result :partial))
        (should (= (length (plist-get result :repairs)) 1))
        (let ((repair (car (plist-get result :repairs))))
          (should (eq (plist-get repair :action) 'repaired))
          (should (= (plist-get repair :candidate-index) 0))
          (should (= (plist-get repair :pass) 1))
          (should (equal (plist-get repair :reported-range) '(1 . 5)))
          (should (equal (plist-get repair :range) '(0 . 4))))
        (should-not proofread--active-requests)
        (should (= (length proofread--diagnostics) 1))
        (should (= (length proofread--overlays) 1))
        (should (= (hash-table-count proofread--cache) 1))))))

(ert-deftest proofread-test-llm-collects-additional-diagnostic-passes
    ()
  "LLM backend can collect additional diagnostics in later passes."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           request
           (first
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           (second
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 5 9 "wrld"))))
           calls
           prompts
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider prompt success _error
                                    &optional _multi-output)
                   (push prompt prompts)
                   (setq calls (1+ (or calls 0)))
                   (funcall success
                            (if (= calls 1)
                                first
                              second))
                   (intern (format "proofread-test-handle-%d"
                                   calls))))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (setq request (proofread--make-backend-request chunk 'llm))
        (should (> (plist-get request :generation) 0))
        (let ((handle (proofread--backend-check
                       request
                       (lambda (backend-result)
                         (setq result backend-result))
                       'llm)))
          (should (= calls 2))
          (should (= (length (plist-get handle :requests)) 2))
          (let* ((second-prompt (car prompts))
                 (interaction
                  (car (llm-chat-prompt-interactions second-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "Already reported diagnostics"
                                    prompt-text))
            (should (string-match-p
                     "Return only additional diagnostics"
                     prompt-text)))
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok))
          (should (equal (mapcar (lambda (diagnostic)
                                   (plist-get diagnostic :text))
                                 (plist-get result :diagnostics))
                         '("helo" "wrld"))))))))

(ert-deftest
    proofread-test-llm-retries-candidate-issues-within-pass-limit ()
  "Recover from an unusable first pass while retaining partial state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity
            proofread-test--llm-provider-identity)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (invalid
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "hola"))))
           (valid
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           calls
           result)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success (if (= calls 1) invalid valid))
                    (intern (format "proofread-test-retry-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 2))
           (should (proofread-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'ok))
           (should (plist-get result :partial))
           (should (= (length (plist-get result :candidate-issues))
                      1))
           (let ((issue (car (plist-get result :candidate-issues))))
             (should (eq (plist-get issue :action) 'dropped))
             (should (= (plist-get issue :candidate-index) 0))
             (should (eq (plist-get issue :reason) 'unmatched-text))
             (should (= (plist-get issue :pass) 1))
             (should
              (equal (plist-get issue :reported-range)
                     '(0 . 4))))
           (should (equal (mapcar (lambda (diagnostic)
                                    (plist-get diagnostic :text))
                                  (plist-get result :diagnostics))
                          '("helo")))))))))

(ert-deftest
    proofread-test-llm-errors-after-candidate-retry-exhaustion ()
  "All-invalid candidate passes end in one terminal backend error."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity
            proofread-test--llm-provider-identity)
           (proofread-llm-max-diagnostic-passes 3)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (invalid
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "hola"))))
           calls
           result)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success invalid)
                    (intern (format "proofread-test-invalid-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 3))
           (should (proofread-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'error))
           (should (eq (plist-get result :error)
                       'llm-invalid-diagnostics))
           (should (= (length (plist-get result :candidate-issues))
                      3))
           (should-not (plist-get result :diagnostics))))))))

(ert-deftest
    proofread-test-llm-sticky-candidate-issues-exhaust-empty-passes ()
  "Exhaust pass limits after an invalid pass and empty retries."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity
            proofread-test--llm-provider-identity)
           (proofread-llm-max-diagnostic-passes 3)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (invalid
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "hola"))))
           (empty (proofread-test--response-content nil))
           calls
           result)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success (if (= calls 1) invalid empty))
                    (intern (format "proofread-test-empty-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 3))
           (should (proofread-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'error))
           (should (eq (plist-get result :error)
                       'llm-invalid-diagnostics))
           (should (= (length (plist-get result :candidate-issues))
                      1))))))))

(ert-deftest
    proofread-test-llm-later-transport-error-keeps-partial-results ()
  "Preserve partial results after a later transport error."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity
            proofread-test--llm-provider-identity)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (valid
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           calls
           result)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (if (= calls 1)
                        (funcall success valid)
                      (funcall error 'transport-error
                               "Network failed"))
                    (intern (format "proofread-test-transport-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 2))
           (should (proofread-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'ok))
           (should (plist-get result :partial))
           (should (= (length (plist-get result :diagnostics)) 1))
           (should (eq (proofread--handle-backend-result result)
                       'applied))
           (should (= (length proofread--diagnostics) 1))
           (should (= (length proofread--overlays) 1))
           (should (= (hash-table-count proofread--cache) 0))))))))

(ert-deftest
    proofread-test-managed-llm-request-stops-after-becoming-stale ()
  "Stop managed LLM requests after an edit or mode disable."
  (dolist (scenario '(edited disabled))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((proofread-llm-provider proofread-test--llm-provider)
            (proofread-llm-provider-identity
             proofread-test--llm-provider-identity)
            (proofread-llm-max-diagnostic-passes 2)
            (content
             (proofread-test--response-content
              (list (proofread-test--response-diagnostic 0 4
                                                         "helo"))))
            callbacks
            calls
            result)
        (proofread-test--with-llm-capabilities
         (let* ((chunk (car
                        (proofread--request-ready-chunks-for-ranges
                         (list (cons (point-min) (point-max))))))
                (request (proofread--make-backend-request chunk
                                                          'llm)))
           (should (> (plist-get request :generation) 0))
           (cl-letf (((symbol-function 'llm-chat-async)
                      (lambda (_provider _prompt success _error
                                         &optional _multi-output)
                        (setq calls (1+ (or calls 0)))
                        (push success callbacks)
                        (intern (format "proofread-test-managed-%d"
                                        calls)))))
             (proofread--backend-check
              request
              (lambda (backend-result)
                (setq result backend-result))
              'llm)
             (should (= calls 1))
             (pcase scenario
               ('edited
                (goto-char (point-min))
                (delete-char 1))
               ('disabled (proofread-mode -1)))
             (funcall (car callbacks) content)
             (should (proofread-test--wait-for (lambda () result)))
             (should (= calls 1)))))))))

(ert-deftest
    proofread-test-llm-error-preserves-buffer-and-clears-request ()
  "LLM error callbacks preserve text and clear active request state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((proofread-llm-provider 'proofread-test-provider)
          (before-text (buffer-string))
          result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt _success error
                                    &optional _multi-output)
                   (funcall error 'llm-error "boom")
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                            (list (cons (point-min) (point-max))))))
               (request (proofread--make-backend-request chunk 'llm)))
          (should (proofread--dispatch-backend-request
                   request
                   (lambda (backend-result)
                     (setq result backend-result))
                   'llm))
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'error))
          (should (eq (plist-get result :error) 'llm-error))
          (should (equal (buffer-string) before-text))
          (should-not proofread--active-requests)
          (should-not proofread--overlays))))))

(ert-deftest proofread-test-llm-invalid-success-response-is-error ()
  "Turn unparsable LLM success responses into errors."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((proofread-llm-provider 'proofread-test-provider)
          calls
          result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (setq calls (1+ (or calls 0)))
                   (funcall success "not json")
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                            (list (cons (point-min) (point-max))))))
               (request (proofread--make-backend-request chunk 'llm)))
          (should (proofread--dispatch-backend-request
                   request
                   (lambda (backend-result)
                     (setq result backend-result)
                     (proofread--handle-backend-result
                      backend-result))
                   'llm))
          (should (proofread-test--wait-for (lambda () result)))
          (should (= calls 1))
          (should (eq (plist-get result :status) 'error))
          (should (eq (plist-get result :error)
                      'llm-invalid-response))
          (should-not proofread--active-requests)
          (should-not proofread--overlays)
          (should (= (hash-table-count proofread--cache) 0)))))))

(ert-deftest proofread-test-llm-stale-results-are-dropped ()
  "Cancel or stale LLM results after invalidating their source."
  (dolist (scenario '(killed disabled modified text-mismatch))
    (let ((buffer (generate-new-buffer
                   (format " *proofread-llm-stale-%s*" scenario)))
          success
          request
          result)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (insert "helo")
              (proofread-mode 1)
              (let* ((proofread-llm-provider
                      'proofread-test-provider)
                     (proofread-llm-max-diagnostic-passes 1)
                     (chunk
                      (car
                       (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min)
                                    (point-max)))))))
                (cl-letf (((symbol-function 'llm-chat-async)
                           (lambda (_provider _prompt callback _error
                                              &optional _multi-output)
                             (setq success callback)
                             'proofread-test-llm-handle))
                          ((symbol-function 'llm-capabilities)
                           #'proofread-test--llm-capabilities)
                          ((symbol-function 'llm-cancel-request)
                           (lambda (_handle)
                             nil)))
                  (setq request
                        (proofread--make-backend-request chunk 'llm))
                  (should (proofread--dispatch-backend-request
                           request
                           (lambda (backend-result)
                             (setq result
                                   (proofread--handle-backend-result
                                    backend-result)))
                           'llm)))))
            (pcase scenario
              ('killed
               (kill-buffer buffer))
              ('disabled
               (with-current-buffer buffer
                 (proofread-mode -1)))
              ('modified
               (with-current-buffer buffer
                 (goto-char (point-max))
                 (insert "!")))
              ('text-mismatch
               (with-current-buffer buffer
                 (delete-region (point-min) (point-max))
                 (insert "halo"))))
            (funcall
             success
             (proofread-test--response-content
              (list (proofread-test--response-diagnostic 0 4
                                                         "helo"))))
            (if (or (memq scenario '(killed disabled))
                    (proofread--request-invalidated-p request))
                (progn
                  (accept-process-output nil 0.02)
                  (should-not result))
              (should (proofread-test--wait-for (lambda () result)))
              (should (eq result 'stale)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (should-not proofread--diagnostics)
                (should-not proofread--overlays))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-structured-response-prompt-requests-contract ()
  "Describe chunk-relative schema ranges in diagnostic prompts."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (let* ((proofread-language "en")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (prompt (proofread--structured-response-prompt request)))
      (should (string-match-p "requested response schema" prompt))
      (should (string-match-p "diagnostics array" prompt))
      (should (string-match-p "every independent problem" prompt))
      (should (string-match-p "Do not stop after the first" prompt))
      (should (string-match-p "one diagnostic per issue" prompt))
      (should (string-match-p "adjacent characters" prompt))
      (should (string-match-p "multiple suggestions" prompt))
      (should (string-match-p "best-first order" prompt))
      (should (string-match-p "only for the Text section" prompt))
      (should (string-match-p "zero-based chunk-relative offsets"
                              prompt))
      (should (string-match-p "range end is exclusive" prompt))
      (dolist (field '("kind" "message" "text" "range" "suggestions"))
        (should (string-match-p field prompt)))
      (should-not (string-match-p "source" prompt))
      (should (string-match-p "Language: \"en\"" prompt))
      (should (string-match-p "Major mode: text-mode" prompt))
      (should (string-match-p "Text:\nhelo" prompt))
      (should-not (string-match-p "absolute buffer" prompt)))))

(ert-deftest
    proofread-test-structured-response-schema-encodes-json-false ()
  "Structured response schema encodes false as a JSON boolean."
  (let ((schema (proofread--structured-response-schema-text)))
    (should (string-match-p "\"additionalProperties\":false" schema))
    (should-not (string-match-p "\"source\"" schema))
    (should-not
     (string-match-p "\"additionalProperties\":\"false\"" schema))))

(ert-deftest
    proofread-test-structured-response-extra-text-around-payload-is-error
    ()
  "Structured response parser rejects extra text around a payload."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (concat "Result follows:\n"
                    (proofread-test--response-content
                     (list
                      (proofread-test--response-diagnostic
                       0 4 "helo")))
                    "\nDone.")))
      (should-error
       (proofread--diagnostics-from-structured-response
        request content 'llm)))))

(ert-deftest
    proofread-test-structured-response-ambiguous-extra-json-is-error
    ()
  "Structured response parser rejects multiple payloads."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (payload
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4
                                                        "helo")))))
      (should-error
       (proofread--diagnostics-from-structured-response
        request (concat payload "\n" payload) 'llm)))))

(ert-deftest
    proofread-test-structured-response-non-json-content-is-error ()
  "Non-schema structured response text is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "I found a spelling issue." 'llm)))))

(ert-deftest
    proofread-test-structured-response-malformed-json-is-error ()
  "Malformed structured response JSON is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "Before {\"diagnostics\":[} after" 'llm)))))

(ert-deftest
    proofread-test-structured-response-rejects-non-json-payload ()
  "Structured responses reject non-JSON Lisp payloads."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (payload '(:diagnostics nil)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request payload 'llm)))))

(ert-deftest
    proofread-test-structured-response-uses-absolute-buffer-range ()
  "Structured response diagnostics use absolute buffer ranges."
  (with-temp-buffer
    (insert "青晨六点，小城。")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 5 7 "小城"))))
           (diagnostic
            (car (proofread--diagnostics-from-structured-response
                  request content 'llm))))
      (should (equal (proofread--diagnostic-range diagnostic)
                     '(6 . 8))))))

(ert-deftest
    proofread-test-structured-response-preserves-multiple-diagnostics
    ()
  "Structured response keeps multiple diagnostics from one request."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list
              (proofread-test--response-diagnostic 0 4 "helo"
                                                   '("hello"))
              (proofread-test--response-diagnostic 5 9 "wrld"
                                                   '("world")))))
           (diagnostics
            (proofread--diagnostics-from-structured-response
             request content 'llm)))
      (should (= (length diagnostics) 2))
      (should (equal (mapcar (lambda (diagnostic)
                               (plist-get diagnostic :text))
                             diagnostics)
                     '("helo" "wrld")))
      (should (equal (mapcar (lambda (diagnostic)
                               (cons (plist-get diagnostic :beg)
                                     (plist-get diagnostic :end)))
                             diagnostics)
                     '((1 . 5) (6 . 10)))))))

(ert-deftest
    proofread-test-structured-response-unmatched-text-is-isolated ()
  "A diagnostic whose text is outside the request becomes one issue."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (_ (setq request
                    (plist-put request :context-before "world")))
           (batch
            (proofread-test--structured-batch
             request
             (list (proofread-test--response-diagnostic 0 99
                                                        "world")))))
      (should-not (plist-get batch :diagnostics))
      (should-not (plist-get batch :repairs))
      (should (equal (mapcar (lambda (issue)
                               (plist-get issue :reason))
                             (plist-get batch :issues))
                     '(unmatched-text))))))

(ert-deftest
    proofread-test-structured-response-repairs-unique-exact-text ()
  "Repair a wrong range when its text has one unique request match."
  (with-temp-buffer
    (insert "青晨六点半，小城的街到刚刚醒来。")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-test--structured-batch
             request
             (list
              (proofread-test--response-diagnostic 0 2 "青晨"
                                                   '("清晨"))
              (proofread-test--response-diagnostic 7 9 "街到"
                                                   '("街道")))))
           (diagnostics (plist-get batch :diagnostics))
           (repair (car (plist-get batch :repairs))))
      (should-not (plist-get batch :issues))
      (should (= (length diagnostics) 2))
      (should (equal (mapcar #'proofread--diagnostic-range
                             diagnostics)
                     '((1 . 3) (10 . 12))))
      (should (equal (plist-get repair :reported-range) '(7 . 9)))
      (should (equal (plist-get repair :range) '(9 . 11))))))

(ert-deftest
    proofread-test-structured-response-ambiguous-text-is-isolated ()
  "A wrong range is not guessed when its text occurs more than once."
  (with-temp-buffer
    (insert "helo x helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-test--structured-batch
             request
             (list (proofread-test--response-diagnostic 6 10
                                                        "helo"))))
           (issue (car (plist-get batch :issues))))
      (should-not (plist-get batch :diagnostics))
      (should-not (plist-get batch :repairs))
      (should (eq (plist-get issue :reason) 'ambiguous-text))
      (should (equal (plist-get issue :occurrences)
                     '((0 . 4) (7 . 11)))))))

(ert-deftest
    proofread-test-structured-response-exact-repeated-text-is-accepted
    ()
  "Accept exact reported ranges even when their text repeats."
  (with-temp-buffer
    (insert "helo x helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-test--structured-batch
             request
             (list (proofread-test--response-diagnostic 7 11
                                                        "helo")))))
      (should (= (length (plist-get batch :diagnostics)) 1))
      (should-not (plist-get batch :issues))
      (should-not (plist-get batch :repairs)))))

(ert-deftest
    proofread-test-structured-response-invalid-empty-range-is-isolated
    ()
  "An empty insertion text is not used to repair a nonempty range."
  (let* ((request '(:beg 1 :end 5 :text "helo"))
         (batch
          (proofread-test--structured-batch
           request
           (list (proofread-test--response-diagnostic 0 1 ""
                                                      '("H")))))
         (issue (car (plist-get batch :issues))))
    (should-not (plist-get batch :diagnostics))
    (should (eq (plist-get issue :reason) 'range-text-mismatch))))

(ert-deftest
    proofread-test-structured-response-isolates-invalid-candidates ()
  "Keep valid diagnostics when a response has invalid candidates."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-test--structured-batch
             request
             (list
              (proofread-test--response-diagnostic 0 99 "hola")
              (proofread-test--response-diagnostic-with-fields
               0 4 "helo" '(("kind" . "typo")))
              42
              (proofread-test--response-diagnostic 5 9 "wrld"
                                                   '("world"))))))
      (should (equal (mapcar (lambda (diagnostic)
                               (plist-get diagnostic :text))
                             (plist-get batch :diagnostics))
                     '("wrld")))
      (should (equal (mapcar (lambda (issue)
                               (plist-get issue :reason))
                             (plist-get batch :issues))
                     '(unmatched-text invalid-shape invalid-shape)))
      (should-not (plist-get batch :repairs)))))

(ert-deftest
    proofread-test-structured-response-invalid-suggestions-are-isolated
    ()
  "A non-string suggestion invalidates only its candidate."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (candidate
            '(("kind" . "spelling")
              ("message" . "Possible misspelling")
              ("text" . "helo")
              ("range" . (("beg" . 0)
                          ("end" . 4)))
              ("suggestions" . ["hello" 42 "hullo"])))
           (batch
            (proofread-test--structured-batch
             request (list candidate))))
      (should-not (plist-get batch :diagnostics))
      (should (eq (plist-get (car (plist-get batch :issues)) :reason)
                  'invalid-shape)))))

(ert-deftest
    proofread-test-structured-response-null-arrays-are-isolated ()
  "Treat a null root as fatal but isolate null suggestions."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "{\"diagnostics\":null}" 'llm))
      (let ((batch
             (proofread--diagnostic-batch-from-structured-response
              request
              (concat "{\"diagnostics\":[{"
                      "\"kind\":\"spelling\","
                      "\"message\":\"issue\","
                      "\"text\":\"helo\","
                      "\"range\":{\"beg\":0,\"end\":4},"
                      "\"suggestions\":null}]}")
              'llm)))
        (should-not (plist-get batch :diagnostics))
        (should (eq (plist-get (car (plist-get batch :issues))
                               :reason)
                    'invalid-shape))))))

(ert-deftest
    proofread-test-structured-response-unknown-fields-are-scoped ()
  "Unknown root fields are fatal while candidate fields are isolated."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (candidate
            (proofread-test--response-diagnostic 0 4 "helo"))
           (candidate-extra
            (append candidate '(("extra" . true))))
           (range-extra
            (proofread-test--response-diagnostic-with-fields
             0 4 "helo"
             '(("range" . (("beg" . 0)
                           ("end" . 4)
                           ("extra" . true)))))))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "{\"diagnostics\":[],\"extra\":true}" 'llm))
      (dolist (candidate (list candidate-extra range-extra))
        (let ((batch
               (proofread-test--structured-batch
                request (list candidate))))
          (should-not (plist-get batch :diagnostics))
          (should (eq (plist-get (car (plist-get batch :issues))
                                 :reason)
                      'invalid-candidate-json))))
      (let ((batch
             (proofread-test--structured-batch
              request (list candidate-extra candidate))))
        (should (equal (mapcar (lambda (diagnostic)
                                 (plist-get diagnostic :text))
                               (plist-get batch :diagnostics))
                       '("helo")))
        (should (equal (mapcar (lambda (issue)
                                 (plist-get issue :reason))
                               (plist-get batch :issues))
                       '(invalid-candidate-json)))))))

(ert-deftest
    proofread-test-structured-response-duplicate-fields-are-scoped ()
  "Reject duplicate root fields but isolate candidate duplicates."
  (let ((request '(:beg 1 :end 5 :text "helo")))
    (should-error
     (proofread--diagnostics-from-structured-response
      request "{\"diagnostics\":false,\"diagnostics\":[]}" 'llm))
    (dolist
        (content
         '("{\"diagnostics\":[{\"kind\":\"spelling\",\
\"kind\":\"style\",\"message\":\"issue\",\
\"text\":\"helo\",\"range\":{\"beg\":0,\"end\":4},\
\"suggestions\":[]}]}"
           "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"beg\":1,\"end\":4},\
\"suggestions\":[]}]}"))
      (let ((batch
             (proofread--diagnostic-batch-from-structured-response
              request content 'llm)))
        (should-not (plist-get batch :diagnostics))
        (should (eq (plist-get (car (plist-get batch :issues))
                               :reason)
                    'invalid-candidate-json))))))

(ert-deftest
    proofread-test-structured-response-trailing-commas-are-error ()
  "Trailing commas at every array and object level are parse errors."
  (let ((request '(:beg 1 :end 5 :text "helo")))
    (dolist
        (content
         '("{\"diagnostics\":[],}"
           "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"end\":4},\"suggestions\":[]},]}"
           "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"end\":4},\"suggestions\":[],}]}"
           "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"end\":4,},\"suggestions\":[]}]}"
           "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"end\":4},\
\"suggestions\":[\"hello\",]}]}"))
      (should-error
       (proofread--diagnostics-from-structured-response
        request content 'llm)))))

(ert-deftest
    proofread-test-structured-response-does-not-intern-unknown-keys ()
  "Rejected JSON object keys do not enter the global symbol table."
  (let ((key "proofread-test-unknown-key-7dc65efef5634c08")
        (request '(:beg 1 :end 5 :text "helo")))
    (should-not (intern-soft key))
    (should-error
     (proofread--diagnostics-from-structured-response
      request (format "{\"diagnostics\":[],\"%s\":true}" key) 'llm))
    (should-not (intern-soft key))))

(ert-deftest
    proofread-test-structured-response-rejects-source-delimiters ()
  "Reject comment and docstring delimiters as proofreading targets."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; prose text\n")
    (let* ((text (buffer-string))
           (request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text text
                          :target-kind 'comment))
           (insertion-position
            (+ (string-search "prose" text) (length "prose")))
           (insertion
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic
                    insertion-position insertion-position ""
                    '("."))))))
      (should
       (eq (proofread-test--structured-issue-reason
            request
            (proofread-test--response-diagnostic 0 2 ";;"))
           'outside-target))
      (let ((diagnostic
             (car (proofread--diagnostics-from-structured-response
                   request insertion 'llm))))
        (should (= (plist-get diagnostic :beg)
                   (+ (point-min) insertion-position)))
        (should (= (plist-get diagnostic :beg)
                   (plist-get diagnostic :end))))))
  (with-temp-buffer
    (c-mode)
    (insert "/*helo*/")
    (let* ((text (buffer-string))
           (request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text text
                          :target-kind 'comment)))
      (should
       (eq (proofread-test--structured-issue-reason
            request
            (proofread-test--response-diagnostic 6 7 "*" '("")))
           'outside-target))
      (should
       (eq (proofread-test--structured-issue-reason
            request
            (proofread-test--response-diagnostic 2 4 "/*" '("")))
           'outside-target))))
  (with-temp-buffer
    (html-mode)
    (insert "<!--helo-->")
    (syntax-propertize (point-max))
    (let ((request (list :buffer (current-buffer)
                         :beg (point-min)
                         :end (point-max)
                         :text (buffer-string)
                         :target-kind 'comment)))
      (dolist (candidate '((8 9 "-") (9 10 "-") (10 11 ">")))
        (should
         (eq (proofread-test--structured-issue-reason
              request
              (proofread-test--response-diagnostic
               (nth 0 candidate) (nth 1 candidate) (nth 2 candidate)
               '("")))
             'outside-target)))))
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\"prose text\"")
    (let* ((text (buffer-string))
           (request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text text
                          :target-kind 'docstring)))
      (should
       (eq (proofread-test--structured-issue-reason
            request
            (proofread-test--response-diagnostic 0 1 "\""))
           'outside-target)))))

(ert-deftest
    proofread-test-structured-response-allows-safe-target-interiors ()
  "Allow prose punctuation and incomplete source containers."
  (dolist (spec '((c-mode "/*helo!*/" comment 6 7 "!")
                  (c-mode "/*helo" comment 2 6 "helo")
                  (emacs-lisp-mode "\"helo" docstring 1 5 "helo")))
    (with-temp-buffer
      (funcall (nth 0 spec))
      (insert (nth 1 spec))
      (syntax-propertize (point-max))
      (let* ((request (list :buffer (current-buffer)
                            :beg (point-min)
                            :end (point-max)
                            :text (buffer-string)
                            :target-kind (nth 2 spec)))
             (content
              (proofread-test--response-content
               (list (proofread-test--response-diagnostic
                      (nth 3 spec) (nth 4 spec) (nth 5 spec)
                      '("fixed"))))))
        (goto-char (point-max))
        (push-mark (point-min) t t)
        (let ((before-point (point))
              (before-mark (mark t))
              (before-mark-active mark-active))
          (should
           (proofread--diagnostics-from-structured-response
            request content 'llm))
          (should (= (point) before-point))
          (should (= (mark t) before-mark))
          (should (eq mark-active before-mark-active)))))))

(ert-deftest
    proofread-test-structured-response-rejects-string-escapes ()
  "Forbid docstring edits to escapes or quoted characters."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\"Say \\\"helo\\\".\"")
    (let ((request (list :buffer (current-buffer)
                         :beg (point-min)
                         :end (point-max)
                         :text (buffer-string)
                         :target-kind 'docstring)))
      (dolist (candidate '((5 6 "\\") (6 7 "\"")))
        (should
         (eq (proofread-test--structured-issue-reason
              request
              (proofread-test--response-diagnostic
               (nth 0 candidate) (nth 1 candidate) (nth 2 candidate)
               '("")))
             'outside-target))))))

(ert-deftest proofread-test-structured-response-cross-boundary-range
    ()
  "Accept diagnostic ranges across word-like boundaries."
  (let* ((request '(:beg 1
                         :end 15
                         :text "小城的街到刚刚醒来。"))
         (content
          (proofread-test--response-content
           (list
            (proofread-test--response-diagnostic 3 5 "街到"
                                                 '("街道")))))
         (diagnostic
          (car (proofread--diagnostics-from-structured-response
                request content 'llm))))
    (should diagnostic)
    (should (= (plist-get diagnostic :beg) 4))
    (should (= (plist-get diagnostic :end) 6))))

(ert-deftest
    proofread-test-structured-response-without-range-and-text-is-rejected
    ()
  "Diagnostics without authoritative range and text are rejected."
  (let* ((request '(:beg 1 :end 5 :text "青晨六点"))
         (content
          (proofread-test--response-content
           (list '(("kind" . "spelling")
                   ("message" . "Possible misspelling")
                   ("suggestions" . ["清晨"]))))))
    (let ((batch
           (proofread--diagnostic-batch-from-structured-response
            request content 'llm)))
      (should-not (plist-get batch :diagnostics))
      (should (eq (plist-get (car (plist-get batch :issues)) :reason)
                  'invalid-shape)))))

(ert-deftest
    proofread-test-structured-response-parsed-results-still-stale-check
    ()
  "Apply stale validation to parsed structured diagnostics."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request
                                                             content
                                                             'llm)))
      (goto-char (point-max))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request diagnostics))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays)
      (should (equal (buffer-string) "helo!")))))

(ert-deftest proofread-test-structured-response-strategy-cache-miss ()
  "Miss cached responses when the LLM response strategy changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider")
           (proofread-llm-response-strategy 'provider-json)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (proofread-test--with-llm-capabilities
       (let ((request (proofread--make-backend-request chunk)))
         (proofread--cache-write-request request (list diagnostic))
         (should (proofread--cache-read-request
                  (proofread--make-backend-request chunk)))
         (let ((proofread-llm-response-strategy 'prompt-json))
           (should-not (proofread--cache-read-request
                        (proofread--make-backend-request
                         chunk)))))))))

(ert-deftest proofread-test-llm-diagnostic-passes-cache-miss ()
  "Cache entries miss when LLM diagnostic pass count changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider")
           (proofread-llm-max-diagnostic-passes 1)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request
               (proofread--make-backend-request chunk)))
      (let ((proofread-llm-max-diagnostic-passes 2))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk)))))))

(ert-deftest proofread-test-cache-key-excludes-volatile-values ()
  "Cache keys exclude volatile objects and secrets."
  (with-temp-buffer
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider [:api-key "secret-token"])
           (proofread-llm-provider-identity "provider-a")
           (chunk (list :text "青晨"
                        :language "zh"
                        :major-mode 'org-mode
                        :buffer (current-buffer)
                        :callback #'ignore))
           (key (proofread--cache-key chunk)))
      (should-not (plist-member key :buffer))
      (should-not (plist-member key :callback))
      (should-not (string-match-p "secret-token" (prin1-to-string
                                                  key)))
      (should-not (string-match-p (buffer-name) (prin1-to-string
                                                 key))))))

(ert-deftest
    proofread-test-structured-response-stale-result-is-dropped ()
  "Structured successful results still require stale validation."
  (with-temp-buffer
    (insert "青晨")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 2 "青晨"))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request
                                                             content
                                                             'llm)))
      (goto-char (point-max))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request diagnostics))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-backend-request-records-chunk-fields ()
  "Backend requests preserve request-ready chunk metadata."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-language "en")
          (proofread-context-size 3))
      (insert "abcTARGETxyz")
      (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
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
        (should (eq (plist-get request :major-mode) 'text-mode))))))

(ert-deftest proofread-test-llm-backend-success-is-asynchronous ()
  "LLM backend success callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-test--with-llm-success
     (proofread-test--response-content nil)
     (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                         (list (cons (point-min) (point-max))))))
            (request (proofread--make-backend-request chunk))
            result)
       (should (proofread--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm))
       (should-not result)
       (should (proofread-test--wait-for (lambda () result)))
       (should (eq (plist-get result :status) 'ok))
       (should (eq (plist-get result :request) request))
       (should (listp (plist-get result :diagnostics)))))))

(ert-deftest proofread-test-llm-backend-error-is-asynchronous ()
  "LLM backend error callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-test--with-llm-error 'llm-failure "LLM failure"
                                    (let* ((chunk
                                            (car
                                             (proofread--request-ready-chunks-for-ranges
                                              (list (cons (point-min) (point-max))))))
                                           (request
                                            (proofread--make-backend-request chunk))
                                           result)
                                      (should
                                       (proofread--backend-check
                                        request
                                        (lambda (backend-result)
                                          (setq result backend-result))
                                        'llm))
                                      (should-not result)
                                      (should
                                       (proofread-test--wait-for (lambda () result)))
                                      (should (eq (plist-get result :status) 'error))
                                      (should (eq (plist-get result :request) request))
                                      (should (eq (plist-get result :error) 'llm-failure))
                                      (should
                                       (equal (plist-get result :message) "LLM failure"))))))

(ert-deftest proofread-test-unsupported-backend-error-is-asynchronous
    ()
  "Unsupported backends report an asynchronous protocol error."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result)
      (should (proofread--backend-check
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
    (proofread-test--with-llm-success
     (proofread-test--response-content nil)
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
                    (setq active-at-callback
                          proofread--active-requests)))
                'llm))
       (should (proofread--active-request-p request))
       (should (proofread-test--wait-for (lambda () result)))
       (should (eq (plist-get result :status) 'ok))
       (should-not active-at-callback)
       (should-not (proofread--active-request-p request))))))

(ert-deftest
    proofread-test-backend-error-preserves-buffer-and-clears-request
    ()
  "Preserve text and clear active state after backend errors."
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
      (proofread-test--with-llm-error 'llm-failure "LLM failure"
                                      (should
                                       (proofread--dispatch-backend-request
                                        request
                                        (lambda (backend-result)
                                          (setq result backend-result)
                                          (with-current-buffer buffer
                                            (setq active-at-callback
                                                  proofread--active-requests)))
                                        'llm))
                                      (should (proofread--active-request-p request))
                                      (should
                                       (proofread-test--wait-for (lambda () result)))
                                      (should (eq (plist-get result :status) 'error))
                                      (should (equal (buffer-string) before-text))
                                      (should-not active-at-callback)
                                      (should-not
                                       (proofread--active-request-p request))))))

(ert-deftest
    proofread-test-check-visible-range-dispatches-ready-chunks ()
  "Dispatch filtered chunks from the visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-dispatch*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  requests
                  callbacks)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (request callback &optional
                                           _backend)
                            (push request requests)
                            (push callback callbacks)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (setq requests (nreverse requests))
                 (should (equal (mapcar (lambda (request)
                                          (plist-get request :text))
                                        requests)
                                '("Alpha " " Beta")))
                 (should (= (length callbacks) 2))
                 (should (= (length proofread--active-requests) 2))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-dispatches-sentence-chunks ()
  "Dispatch sentence-level chunks from the visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-sentences*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert (concat "青晨六点半，小城的街到刚刚醒来。"
                            "卖豆浆的滩主把炉子推到巷口。"
                            "几个上班的人撑着伞从桥边经过。"))
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 10)
                  requests
                  callbacks)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (request callback &optional
                                           _backend)
                            (push request requests)
                            (push callback callbacks)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (setq requests (nreverse requests))
                 (should (equal
                          (mapcar (lambda (request)
                                    (plist-get request :text))
                                  requests)
                          '("青晨六点半，小城的街到刚刚醒来。"
                            "卖豆浆的滩主把炉子推到巷口。"
                            "几个上班的人撑着伞从桥边经过。")))
                 (dolist (request requests)
                   (should (equal
                            (plist-get request :text)
                            (buffer-substring-no-properties
                             (plist-get request :beg)
                             (plist-get request :end)))))
                 (should (= (length callbacks) 3))
                 (should (= (length proofread--active-requests)
                            3))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-max-concurrent-requests-queues-extra-work
    ()
  "Limit active backend requests with the concurrency option."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-queue*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert (concat "第一句。"
                            "第二句。"
                            "第三句。"))
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 2)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name
                         buffer)))
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (plist-get recorder :function)))
                 (proofread-show-buffer-requests buffer)
                 (proofread-check-visible-range)
                 (should (= (length (funcall
                                     (plist-get recorder :requests)))
                            2))
                 (should (= (length proofread--active-requests) 2))
                 (should (= (length proofread--request-queue) 1))
                 (proofread-check-visible-range)
                 (should (= (length (funcall
                                     (plist-get recorder :requests)))
                            2))
                 (should (= (length proofread--active-requests) 2))
                 (should (= (length proofread--request-queue) 1))
                 (with-current-buffer name
                   (let ((statuses (mapcar (lambda (entry)
                                             (aref (cadr entry) 1))
                                           tabulated-list-entries)))
                     (should (= (length statuses) 3))
                     (should (= (cl-count "waiting" statuses
                                          :test #'equal)
                                2))
                     (should (member "queued" statuses))))
                 (let* ((requests (funcall (plist-get recorder
                                                      :requests)))
                        (callbacks (funcall (plist-get recorder
                                                       :callbacks)))
                        (first-request (car requests))
                        (second-request (cadr requests))
                        (first-callback (car callbacks)))
                   (should (eq (funcall
                                first-callback
                                (proofread--backend-success-result
                                 first-request nil))
                               'applied))
                   (let* ((all-requests (funcall
                                         (plist-get recorder
                                                    :requests)))
                          (third-request (caddr all-requests))
                          (active-ids
                           (mapcar (lambda (request)
                                     (plist-get request :id))
                                   proofread--active-requests)))
                     (should (= (length all-requests) 3))
                     (should (= (length proofread--active-requests)
                                2))
                     (should-not proofread--request-queue)
                     (with-current-buffer name
                       (let ((statuses
                              (mapcar (lambda (entry)
                                        (aref (cadr entry) 1))
                                      tabulated-list-entries)))
                         (should (member "applied" statuses))
                         (should (= (cl-count "waiting" statuses
                                              :test #'equal)
                                    2))
                         (should-not (member "queued" statuses))))
                     (should-not
                      (member (plist-get first-request :id)
                              active-ids))
                     (should (member (plist-get second-request :id)
                                     active-ids))
                     (should (member (plist-get third-request :id)
                                     active-ids))))))))
        (when-let*
            ((list-buffer
              (get-buffer
               (proofread--request-log-list-buffer-name buffer))))
          (kill-buffer list-buffer))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-active-requests-remain-buffer-local ()
  "Active request state is isolated between buffers."
  (let ((first-buffer (generate-new-buffer " *proofread-requests-a*"))
        (second-buffer (generate-new-buffer
                        " *proofread-requests-b*")))
    (unwind-protect
        (let ((proofread-backend 'llm)
              (proofread-llm-provider proofread-test--llm-provider)
              (proofread-llm-provider-identity
               proofread-test--llm-provider-identity))
          (proofread-test--with-llm-capabilities
           (cl-letf (((symbol-function 'proofread--backend-check)
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
               (should (= (length proofread--active-requests) 1))
               (should (eq (plist-get (car
                                       proofread--active-requests)
                                      :buffer)
                           first-buffer)))
             (with-current-buffer second-buffer
               (should (= (length proofread--active-requests) 1))
               (should (eq (plist-get (car
                                       proofread--active-requests)
                                      :buffer)
                           second-buffer))))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest
    proofread-test-fresh-result-records-diagnostics-and-overlays ()
  "Fresh successful results record diagnostics and create overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-fresh-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (should (proofread--active-request-p request))
                 (let ((diagnostic
                        (proofread-test--diagnostic-for-range
                         1 5 "helo")))
                   (should (eq (funcall
                                callback
                                (proofread--backend-success-result
                                 request (list diagnostic)))
                               'applied))
                   (should
                    (equal proofread--diagnostics
                           (list diagnostic)))
                   (should (= (length proofread--overlays) 1))
                   (should
                    (overlay-buffer (car proofread--overlays)))
                   (should-not (proofread--active-request-p
                                request)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-live-range-does-not-mutate-backend-result
    ()
  "Keep backend results immutable when overlays move."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (result
            (proofread--backend-success-result request (list
                                                        diagnostic))))
      (should (eq (proofread--handle-backend-result result) 'applied))
      (let ((live (car proofread--diagnostics)))
        (should-not (eq live diagnostic))
        (goto-char (point-min))
        (insert "x")
        (should (equal (proofread--diagnostic-range live) '(2 . 6)))
        (should
         (equal (proofread--diagnostic-range diagnostic)
                '(1 . 5)))
        (should (eq (car (plist-get result :diagnostics))
                    diagnostic))))))

(ert-deftest
    proofread-test-context-does-not-shift-diagnostic-overlays ()
  "Do not shift accepted overlays for sentence-window context."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (proofread-mode 1)
    (let* ((proofread-language "zh")
           (proofread-backend 'llm)
           (proofread-context-size 300)
           (chunk (proofread-test--chunk-with-text
                   (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))
                   "目标句。"))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range
             (plist-get request :beg)
             (+ (plist-get request :beg) 2)
             "目标")))
      (should (equal (plist-get request :context-before) "前文。"))
      (should (equal (plist-get request :context-after) "后文。"))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'applied))
      (should (= (length proofread--overlays) 1))
      (let ((overlay (car proofread--overlays)))
        (should (= (overlay-start overlay) (plist-get diagnostic
                                                      :beg)))
        (should (= (overlay-end overlay) (plist-get diagnostic
                                                    :end)))))))

(ert-deftest proofread-test-killed-buffer-result-is-dropped ()
  "Results for killed buffers are dropped without recreating state."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-killed-result*"))
          request
          callback)
      (switch-to-buffer buffer)
      (insert "helo world")
      (proofread-mode 1)
      (let ((proofread-backend 'llm)
            (proofread-llm-provider proofread-test--llm-provider)
            (proofread-llm-provider-identity
             proofread-test--llm-provider-identity))
        (proofread-test--with-llm-capabilities
         (cl-letf (((symbol-function 'window-start)
                    (lambda (&optional _window) (point-min)))
                   ((symbol-function 'window-end)
                    (lambda (&optional _window _update) (point-max)))
                   ((symbol-function 'proofread--backend-check)
                    (lambda (backend-request
                             backend-callback
                             &optional _backend)
                      (setq request backend-request)
                      (setq callback backend-callback)
                      'proofread-test-handle)))
           (proofread-check-visible-range))))
      (kill-buffer buffer)
      (should-not (buffer-live-p buffer))
      (should (eq (funcall
                   callback
                   (proofread--backend-success-result
                    request
                    (list
                     (proofread-test--diagnostic-for-range
                      1 5 "helo"))))
                  'stale)))))

(ert-deftest proofread-test-disabled-mode-result-is-dropped ()
  "Do not mutate proofread state after disabling the mode."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-disabled-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (proofread-mode -1)
                 (should (eq (funcall
                              callback
                              (proofread--backend-success-result
                               request
                               (list
                                (proofread-test--diagnostic-for-range
                                 1 5 "helo"))))
                             'stale))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)
                 (should-not proofread--active-requests)))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-context-change-result-is-dropped ()
  "Results are stale after their surrounding context changes."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-tick-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update) 5))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (goto-char (point-max))
                 (insert "!")
                 (should (eq (funcall
                              callback
                              (proofread--backend-success-result
                               request
                               (list
                                (proofread-test--diagnostic-for-range
                                 1 5 "helo"))))
                             'stale))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)
                 (should-not (proofread--active-request-p
                              request))))))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update) 5))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (delete-region 1 5)
                 (insert "hello")
                 (should (eq (funcall
                              callback
                              (proofread--backend-success-result
                               request
                               (list
                                (proofread-test--diagnostic-for-range
                                 1 6 "hello"))))
                             'stale))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)
                 (should-not (proofread--active-request-p
                              request))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-backend-error-result-creates-no-overlays
    ()
  "Backend error results preserve text and create no overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-error-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (before-text (buffer-string))
                  request
                  callback)
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update)
                            (point-max)))
                         ((symbol-function 'proofread--backend-check)
                          (lambda (backend-request
                                   backend-callback
                                   &optional _backend)
                            (setq request backend-request)
                            (setq callback backend-callback)
                            'proofread-test-handle)))
                 (proofread-check-visible-range)
                 (should (eq (funcall
                              callback
                              (proofread--backend-error-result
                               request 'llm-failure "LLM failure"))
                             'error))
                 (should (equal (buffer-string) before-text))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)
                 (should-not (proofread--active-request-p
                              request))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-warning-report-preserves-detail-and-shortens-echo
    ()
  "Log full background warnings but echo a short summary."
  (let* ((detail (concat "Backend detail line one\n"
                         (make-string 600 ?x)))
         (summary (concat "backend request failed\n"
                          (make-string 600 ?y)))
         captured-echo
         captured-minimum-level
         captured-truncation
         captured-warning-args)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args)
                 (setq captured-minimum-level warning-minimum-level)
                 (setq captured-warning-args args)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq captured-truncation message-truncate-lines)
                 (setq captured-echo
                       (apply #'format format-string args)))))
      (proofread--report-warning-without-window detail summary))
    (should (equal captured-warning-args
                   (list 'proofread detail :warning)))
    (should (eq captured-minimum-level :error))
    (should captured-truncation)
    (should (string-prefix-p "proofread: backend request failed "
                             captured-echo))
    (should (<= (string-width captured-echo) 120))
    (should-not (string-match-p "[\n\r]" captured-echo))))

(ert-deftest
    proofread-test-backend-errors-are-aggregated-per-request-batch ()
  "Aggregate production errors and settle cancelled batch work."
  (with-temp-buffer
    (text-mode)
    (insert "onee\n\ntwoo\n\nthree\n\nfourr")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-max-concurrent-requests 10)
          echo-truncation
          echoes
          captured-warning-levels
          warnings)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (let* ((ranges '((1 . 5) (7 . 11) (13 . 18) (20 . 25)))
              (chunks
               (mapcar
                (lambda (range)
                  (car (proofread--request-ready-chunks-for-ranges
                        (list range))))
                ranges))
              (recorder (proofread-test--make-backend-recorder)))
         (cl-letf (((symbol-function 'display-warning)
                    (lambda (&rest args)
                      (push warning-minimum-level
                            captured-warning-levels)
                      (push args warnings)))
                   ((symbol-function 'message)
                    (lambda (format-string &rest args)
                      (push message-truncate-lines echo-truncation)
                      (push (apply #'format format-string args)
                            echoes)))
                   ((symbol-function 'proofread--backend-check)
                    (plist-get recorder :function)))
           (should (= (length
                       (proofread--dispatch-request-ready-chunks
                        chunks 'llm))
                      4))
           (let ((requests (funcall (plist-get recorder :requests)))
                 (callbacks (funcall (plist-get recorder
                                                :callbacks))))
             (should (= (length requests) 4))
             (should (cl-every
                      (lambda (request)
                        (plist-get
                         (plist-get request :state)
                         :batch))
                      requests))
             (dotimes (index 4)
               (funcall
                (nth index callbacks)
                (proofread--backend-error-result
                 (nth index requests)
                 'llm-invalid-diagnostics
                 (format "Failure kind %d" index)))
               (should (= (length warnings) (if (= index 3) 1 0))))
             (let ((message (nth 1 (car warnings))))
               (should (string-match-p "4 requests" message))
               (should
                (string-match-p "1 more error kind" message))))
           (let ((second-recorder
                  (proofread-test--make-backend-recorder)))
             (cl-letf (((symbol-function 'proofread--backend-check)
                        (plist-get second-recorder :function)))
               (proofread--dispatch-request-ready-chunks
                (cl-subseq chunks 0 2) 'llm)
               (let ((requests
                      (funcall
                       (plist-get second-recorder :requests)))
                     (callbacks
                      (funcall (plist-get second-recorder
                                          :callbacks))))
                 (funcall
                  (car callbacks)
                  (proofread--backend-error-result
                   (car requests) 'llm-failure "One failure"))
                 (should (= (length warnings) 1))
                 (proofread--retire-active-request
                  (cadr requests) nil 'test-cancelled)
                 (should (= (length warnings) 2)))))
           (let ((direct
                  (proofread--make-backend-request (car chunks)
                                                   'llm)))
             (should
              (eq (proofread--handle-backend-result
                   (proofread--backend-error-result
                    direct 'llm-failure "Direct failure"))
                  'error))
             (should (= (length warnings) 3))
             (should (equal captured-warning-levels
                            '(:error :error :error)))
             (should (equal echo-truncation '(t t t)))
             (should (= (length echoes) 3))
             (should (cl-every
                      (lambda (echo)
                        (and (< (string-width echo) 80)
                             (not (string-match-p "[\n\r]" echo))))
                      echoes)))))))))

(ert-deftest proofread-test-navigation-sorts-and-filters-diagnostics
    ()
  "Sort valid navigation diagnostics by start and end."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((marker (copy-marker 2))
           (first (proofread-test--diagnostic-for-range marker 5
                                                        "bcd"))
           (same-start-short
            (proofread-test--diagnostic-for-range 4 6 "de"))
           (same-start-long
            (proofread-test--diagnostic-for-range 4 9 "defgh"))
           (last (proofread-test--diagnostic-for-range 8 10 "hi"))
           (invalid-beg
            (proofread-test--diagnostic-for-range 'not-a-position 3
                                                  ""))
           (invalid-backward
            (proofread-test--diagnostic-for-range 7 6 "")))
      (setq proofread--diagnostics
            (list same-start-long invalid-beg last invalid-backward
                  same-start-short first))
      (mapc #'proofread--create-overlay
            (list same-start-long last same-start-short first))
      (should (equal (mapcar #'proofread--diagnostic-range
                             (proofread--navigation-diagnostics))
                     '((2 . 5) (4 . 6) (4 . 9) (8 . 10)))))))

(ert-deftest proofread-test-navigation-target-selection-around-point
    ()
  "Select strict non-wrapping targets for next and previous moves."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (proofread-mode 1)
    (let* ((first (proofread-test--diagnostic-for-range 3 4 "c"))
           (second (proofread-test--diagnostic-for-range 6 7 "f"))
           (third (proofread-test--diagnostic-for-range 9 10 "i"))
           (invalid (proofread-test--diagnostic-for-range 12 11 "")))
      (setq proofread--diagnostics (list third invalid first second))
      (mapc #'proofread--create-overlay (list third first second))
      (should (eq (proofread--next-diagnostic-after 1) first))
      (should (eq (proofread--next-diagnostic-after 3) second))
      (should (eq (proofread--next-diagnostic-after 6) third))
      (should-not (proofread--next-diagnostic-after 9))
      (should-not (proofread--previous-diagnostic-before 3))
      (should (eq (proofread--previous-diagnostic-before 6) first))
      (should (eq (proofread--previous-diagnostic-before 9) second))
      (should (eq (proofread--previous-diagnostic-before 11)
                  third)))))

(ert-deftest
    proofread-test-proofread-next-moves-to-nearest-diagnostic ()
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

(ert-deftest
    proofread-test-proofread-previous-moves-to-nearest-diagnostic ()
  "Move to the nearest earlier diagnostic with `proofread-previous'."
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

(ert-deftest proofread-test-navigation-empty-diagnostics-keeps-point
    ()
  "Preserve point when navigation finds no diagnostics."
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
  "Navigate using proofread diagnostics, not unrelated overlays."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((foreign-overlay (make-overlay 2 3))
           (diagnostic (proofread-test--diagnostic-for-range 6 7
                                                             "f")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 6))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-navigation-marks-one-current-diagnostic ()
  "Mark exactly one owned diagnostic as current during navigation."
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
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                first)
                               'face)
                  'proofread-current-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                second)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get foreign-overlay 'face) 'bold))
      (proofread-next)
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                first)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                second)
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
  "Clear current diagnostic state with overlays or mode disable."
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

(ert-deftest
    proofread-test-show-buffer-diagnostics-lists-current-buffer ()
  "List diagnostics for the source buffer."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (proofread-mode 1)
      (let* ((source (current-buffer))
             (first
              (proofread--make-diagnostic
               :beg 4
               :end 8
               :text "helo"
               :kind 'spelling
               :message "Possible misspelling"
               :suggestions '("hello")
               :source 'test))
             (second
              (proofread--make-diagnostic
               :beg 12
               :end 15
               :text "teh"
               :kind 'grammar
               :message "Use \"the\" here"
               :suggestions '("the")))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list second
                                                         first))
              (goto-char 2)
              (proofread-show-buffer-diagnostics)
              (should (= (point) 2))
              (with-current-buffer name
                (should (eq major-mode
                            'proofread-diagnostics-buffer-mode))
                (should (eq proofread--diagnostics-buffer-source
                            source))
                (should (= (length tabulated-list-entries) 2))
                (let* ((entry (car tabulated-list-entries))
                       (id (car entry))
                       (columns (cadr entry)))
                  (should (eq (plist-get id :diagnostic) first))
                  (should (eq (plist-get id :buffer) source))
                  (should (equal (aref columns 0) "1"))
                  (should (equal (aref columns 1) "3"))
                  (should (equal (aref columns 2) "spelling"))
                  (should (equal (aref columns 3) "test"))
                  (should (equal (aref columns 4) "helo"))
                  (should (equal (car (aref columns 5))
                                 "Possible misspelling")))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-selects-diagnostic ()
  "Highlight the requested diagnostic in the diagnostics list."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (proofread-mode 1)
      (let* ((first (proofread-test--diagnostic-for-range 4 8 "helo"))
             (second (proofread-test--diagnostic-for-range 12 15
                                                           "teh"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list first
                                                         second))
              (cl-letf (((symbol-function
                          'pulse-momentary-highlight-one-line)
                         (lambda (&rest _args)
                           'highlighted)))
                (proofread-show-buffer-diagnostics second))
              (with-current-buffer name
                (should (eq (plist-get (tabulated-list-get-id)
                                       :diagnostic)
                            second))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest proofread-test-show-diagnostic-visits-source ()
  "`proofread-show-diagnostic' visits the source diagnostic location."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo zz")
      (proofread-mode 1)
      (let* ((source (current-buffer))
             (diagnostic
              (proofread-test--diagnostic-for-range 4 8 "helo"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list diagnostic))
              (proofread-show-buffer-diagnostics)
              (with-current-buffer name
                (goto-char (point-min))
                (cl-letf (((symbol-function
                            'pulse-momentary-highlight-region)
                           (lambda (&rest _args)
                             'highlighted)))
                  (should (eq (proofread-show-diagnostic (point))
                              source))))
              (should (= (point) 4))
              (should (eq proofread--current-diagnostic diagnostic)))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest proofread-test-show-buffer-diagnostics-requires-mode ()
  "`proofread-show-buffer-diagnostics' requires `proofread-mode'."
  (with-temp-buffer
    (insert "helo")
    (should-error (proofread-show-buffer-diagnostics) :type
                  'user-error)))

(ert-deftest
    proofread-test-diagnostics-list-refreshes-visible-contents ()
  "An open diagnostics list redraws when source diagnostics change."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-diagnostics-refresh*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (let* ((diagnostic
                    (proofread-test--diagnostic-for-range 1 5 "helo"))
                   (name (proofread--diagnostics-buffer-name)))
              (proofread-test--install-diagnostics (list diagnostic))
              (proofread-show-buffer-diagnostics)
              (with-current-buffer name
                (goto-char (point-min))
                (should (search-forward "helo" nil t)))
              (with-current-buffer source
                (proofread-clear))
              (with-current-buffer name
                (should-not tabulated-list-entries)
                (goto-char (point-min))
                (should-not (search-forward "helo" nil t)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-diagnostic-at-point-finds-covering-diagnostic ()
  "Diagnostic lookup returns the proofread diagnostic covering point."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 6
                                                            "cde")))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 3)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (goto-char 5)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (goto-char 6)
      (should-not (proofread-diagnostic-at-point)))))

(ert-deftest proofread-test-diagnostic-at-point-uses-overlap-order ()
  "Overlapping diagnostic lookup uses navigation ordering."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((long (proofread-test--diagnostic-for-range 2 9 "bcdefgh"))
          (short (proofread-test--diagnostic-for-range 2 6 "bcde"))
          (later (proofread-test--diagnostic-for-range 4 5 "d")))
      (proofread-test--install-diagnostics (list later long short))
      (goto-char 4)
      (should (eq (proofread-diagnostic-at-point) short)))))

(ert-deftest
    proofread-test-diagnostic-at-point-ignores-foreign-overlays ()
  "Ignore foreign overlays and invalid ranges during lookup."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((foreign-overlay (make-overlay 3 6))
          (invalid-backward
           (proofread-test--diagnostic-for-range 7 6 ""))
          (invalid-beg
           (proofread-test--diagnostic-for-range 'not-a-position 5
                                                 "")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--diagnostics (list invalid-backward
                                         invalid-beg))
      (goto-char 4)
      (should-not (proofread-diagnostic-at-point)))))

(ert-deftest proofread-test-public-diagnostic-range-validates-range ()
  "The public diagnostic range accessor returns only valid ranges."
  (should (equal
           (proofread-diagnostic-range
            (proofread-test--diagnostic-for-range 3 6 "cde"))
           '(3 . 6)))
  (should-not (proofread-diagnostic-range '(:beg 7 :end 6)))
  (should-not (proofread-diagnostic-range '(:beg invalid :end 6))))

(ert-deftest
    proofread-test-public-diagnostic-at-point-requires-overlay ()
  "Return only live displayed diagnostics from the public lookup."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread-test--diagnostic-for-range 3 6 "cde"))
           overlay)
      (setq proofread--diagnostics (list diagnostic))
      (should-not (proofread-diagnostic-at-point 4))
      (setq overlay (proofread--create-overlay diagnostic))
      (should (eq (proofread-diagnostic-at-point 4) diagnostic))
      (delete-overlay overlay)
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest
    proofread-test-public-diagnostic-at-point-skips-stale-overlap ()
  "The public lookup skips an earlier stale overlapping diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((stale
           (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
          (live
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (setq proofread--diagnostics (list stale live))
      (proofread--create-overlay live)
      (should (eq (proofread-diagnostic-at-point 4) live)))))

(ert-deftest proofread-test-diagnostics-changed-hook-runs-after-clear
    ()
  "Notify optional frontends after clearing displayed diagnostics."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((calls 0)
          (diagnostic
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread-test--install-diagnostics (list diagnostic))
      (proofread-clear)
      (should (= calls 1))
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest
    proofread-test-diagnostics-hook-error-does-not-break-correction ()
  "Do not let optional frontend errors interrupt corrections."
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
            :suggestions '("hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (error "Simulated frontend failure"))
                nil t)
      (goto-char 2)
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "hello"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-backend-replace-notifies-diagnostics-once
    ()
  "One backend replacement emits one final diagnostics notification."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((calls 0)
          (old
           (proofread-test--diagnostic-for-range 1 5 "helo"))
          (new
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'grammar)))
      (proofread-test--install-diagnostics (list old))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread--replace-backend-diagnostics
       (list :beg 1 :end 5)
       (list new))
      (should (= calls 1))
      (should (equal proofread--diagnostics (list new))))))

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
           :source 'llm))
         (description
          (proofread--format-diagnostic-description diagnostic)))
    (should (string-match-p "Kind: spelling" description))
    (should (string-match-p "Message: Possible misspelling"
                            description))
    (should (string-match-p "Original text:\nhelo" description))
    (should (string-match-p "1\\. hello" description))
    (should (string-match-p "Source: llm" description))))

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
              :source 'llm)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Kind: spelling" description))
            (should (string-match-p "Message: Possible misspelling"
                                    description))
            (should (string-match-p "Original text:\nhelo"
                                    description))
            (should (string-match-p "1\\. hello" description))
            (should (string-match-p "Source: llm" description))))))))

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

(ert-deftest proofread-test-describe-handles-missing-optional-fields
    ()
  "Show available fields when optional diagnostic data is absent."
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
            (should (string-match-p "Message: Message only"
                                    description))
            (should (string-match-p "Original text:\nhelo"
                                    description))
            (should-not (string-match-p "Suggestions:" description))
            (should-not (string-match-p "Confidence:" description))
            (should-not (string-match-p "Source:" description))))))))

(ert-deftest proofread-test-describe-away-from-diagnostic-keeps-point
    ()
  "Report no diagnostic without moving point."
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
      (let ((diagnostic (proofread-test--diagnostic-for-range 1 5
                                                              "helo"))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (should (equal (buffer-string) text))))))

(ert-deftest
    proofread-test-describe-preserves-diagnostics-and-overlays ()
  "Do not mutate diagnostics or overlays while describing them."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let* ((diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo"))
             (overlays (proofread-test--install-diagnostics
                        (list diagnostic)))
             (diagnostics-before (copy-sequence
                                  proofread--diagnostics))
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
  "Apply suggestions through owned diagnostic and overlay state."
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
      (should (eq (proofread-diagnostic-at-point) diagnostic))
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

(ert-deftest proofread-test-correct-at-point-single-suggestion ()
  "Apply one point suggestion without prompting."
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
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal (buffer-string) "aa hello zz")))))

(ert-deftest proofread-test-correct-at-point-multiple-suggestions ()
  "Preserve suggestion order during point correction."
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
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal candidates-seen '("hello" "hullo" "hallo")))
      (should (equal (buffer-string) "aa hullo zz")))))

(ert-deftest proofread-test-correct-at-point-uses-native-completion ()
  "Use completion when correcting among multiple suggestions."
  (let ((description-buffer (get-buffer
                             proofread--description-buffer-name)))
    (when description-buffer
      (kill-buffer description-buffer)))
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
          prompt-seen
          candidates-seen
          require-match-seen)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt candidates _predicate require-match
                                 &rest _args)
                   (setq prompt-seen prompt)
                   (setq candidates-seen candidates)
                   (setq require-match-seen require-match)
                   "hallo")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal prompt-seen "Apply suggestion: "))
      (should (equal candidates-seen '("hello" "hullo" "hallo")))
      (should require-match-seen)
      (should (equal (buffer-string) "aa hallo zz"))
      (should-not (get-buffer proofread--description-buffer-name)))))

(ert-deftest proofread-test-correct-at-point-follows-preceding-edit ()
  "Track live diagnostics after earlier source text changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char (point-min))
      (insert "xx ")
      (should (equal (proofread-diagnostic-range diagnostic) '(4 .
                                                                 8)))
      (goto-char 5)
      (proofread-correct-at-point)
      (should (equal (buffer-string) "xx hello")))))

(ert-deftest
    proofread-test-correct-at-point-inserts-zero-width-suggestion ()
  "Point correction applies and removes a zero-width diagnostic."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '("X"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (proofread-correct-at-point)
      (should (equal (buffer-string) "aXb"))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-public-command-scope-names ()
  "Check and correction commands use matching scope suffixes."
  (dolist (operation '(check correct))
    (dolist (scope '(at-point region buffer visible-range))
      (should
       (commandp
        (intern (format "proofread-%s-%s" operation scope)))))))

(ert-deftest
    proofread-test-correct-region-applies-from-end-to-beginning ()
  "Correct reversed regions despite changing text lengths."
  (with-temp-buffer
    (insert "helo and wrld; ouut.")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            10 14 "wrld" '("world")))
          (outside
           (proofread-test--diagnostic-with-suggestions
            16 20 "ouut" '("out"))))
      (proofread-test--install-diagnostics
       (list first second outside))
      (should (eq (proofread-correct-region 14 1) 'applied))
      (should (equal (buffer-string) "hello and world; ouut."))
      (should (equal proofread--diagnostics (list outside)))
      (should
       (equal (proofread-diagnostic-range outside)
              '(18 . 22))))))

(ert-deftest
    proofread-test-correct-region-validates-interactive-bounds ()
  "Interactive region correction rejects inactive and foreign bounds."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((transient-mark-mode t))
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active nil)
      (should-error (call-interactively #'proofread-correct-region)
                    :type 'user-error))
    (let ((other (generate-new-buffer " *proofread-correct-marker*")))
      (unwind-protect
          (let ((foreign
                 (with-current-buffer other
                   (insert "wrld")
                   (copy-marker (point-min)))))
            (should-error
             (proofread-correct-region foreign (point-max))
             :type 'user-error))
        (kill-buffer other)))))

(ert-deftest proofread-test-correct-buffer-respects-narrowing ()
  "Correct only diagnostics in the accessible buffer portion."
  (with-temp-buffer
    (insert "helo middle wrld")
    (proofread-mode 1)
    (let ((outside
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (inside
           (proofread-test--diagnostic-with-suggestions
            13 17 "wrld" '("world"))))
      (proofread-test--install-diagnostics (list outside inside))
      (narrow-to-region 13 17)
      (should (eq (proofread-correct-buffer) 'applied))
      (should (= (point-min) 13))
      (should (= (point-max) 18))
      (widen)
      (should (equal (buffer-string) "helo middle world"))
      (should (equal proofread--diagnostics (list outside)))
      (should (equal (proofread-diagnostic-range outside) '(1 .
                                                              5))))))

(ert-deftest proofread-test-correct-visible-range-uses-all-ranges ()
  "Correct only diagnostics in visible ranges."
  (with-temp-buffer
    (insert "helo and wrld and ouut")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (hidden
           (proofread-test--diagnostic-with-suggestions
            10 14 "wrld" '("world")))
          (last
           (proofread-test--diagnostic-with-suggestions
            19 23 "ouut" '("out"))))
      (proofread-test--install-diagnostics (list first hidden last))
      (cl-letf (((symbol-function 'proofread--visible-ranges)
                 (lambda () '((1 . 5) (19 . 23)))))
        (should (eq (proofread-correct-visible-range) 'applied)))
      (should (equal (buffer-string) "hello and wrld and out"))
      (should (equal proofread--diagnostics (list hidden)))
      (should (equal (proofread-diagnostic-range hidden) '(11 .
                                                              15))))))

(ert-deftest
    proofread-test-correct-buffer-skips-unavailable-suggestions ()
  "Buffer correction skips diagnostics without suggestions."
  (with-temp-buffer
    (insert "note helo")
    (proofread-mode 1)
    (let ((unavailable
           (proofread-test--diagnostic-with-suggestions
            1 5 "note" nil))
          (available
           (proofread-test--diagnostic-with-suggestions
            6 10 "helo" '("hello"))))
      (proofread-test--install-diagnostics (list unavailable
                                                 available))
      (should (eq (proofread-correct-buffer) 'applied))
      (should (equal (buffer-string) "note hello"))
      (should (equal proofread--diagnostics (list unavailable))))))

(ert-deftest
    proofread-test-correct-buffer-keeps-adjacent-diagnostic-range ()
  "A correction preserves an adjacent diagnostic's exact range."
  (with-temp-buffer
    (insert "helowrld")
    (proofread-mode 1)
    (let ((available
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (adjacent
           (proofread-test--diagnostic-with-suggestions
            5 9 "wrld" nil)))
      (proofread-test--install-diagnostics (list available adjacent))
      (proofread-correct-buffer)
      (should (equal (buffer-string) "hellowrld"))
      (should (equal proofread--diagnostics (list adjacent)))
      (should (equal (proofread-diagnostic-range adjacent) '(6 . 10)))
      (should (equal (buffer-substring-no-properties 6 10) "wrld")))))

(ert-deftest proofread-test-correct-buffer-prefers-navigation-order ()
  "Skip overlapping diagnostics after the first correction."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let ((long
           (proofread-test--diagnostic-with-suggestions
            1 5 "abcd" '("long")))
          (short
           (proofread-test--diagnostic-with-suggestions
            1 3 "ab" '("XY"))))
      (proofread-test--install-diagnostics (list long short))
      (should (eq (proofread-correct-buffer) 'applied))
      (should (equal (buffer-string) "XYcdef"))
      (should-not proofread--diagnostics))))

(ert-deftest
    proofread-test-correct-buffer-deduplicates-zero-width-position ()
  "Apply one diagnostic at a shared insertion point."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '("X")))
          (second
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '("Y"))))
      (proofread-test--install-diagnostics (list first second))
      (proofread-correct-buffer)
      (should (equal (buffer-string) "aXb"))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-correct-buffer-is-one-undo-step ()
  "One undo restores every replacement made by buffer correction."
  (with-temp-buffer
    (insert "helo wrld tail")
    (buffer-enable-undo)
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '("world")))
          (survivor
           (proofread-test--diagnostic-with-suggestions
            11 15 "tail" nil)))
      (proofread-test--install-diagnostics (list first second
                                                 survivor))
      (setq buffer-undo-list nil)
      (proofread-correct-buffer)
      (should (equal (buffer-string) "hello world tail"))
      (should (equal (proofread-diagnostic-range survivor) '(13 .
                                                                17)))
      (undo)
      (should (equal (buffer-string) "helo wrld tail"))
      (should (equal (proofread-diagnostic-range survivor) '(11 .
                                                                15)))
      (should (equal (buffer-substring-no-properties 11 15)
                     "tail")))))

(ert-deftest proofread-test-correct-buffer-rolls-back-on-edit-error ()
  "Preserve text and diagnostics when correction raises an error."
  (with-temp-buffer
    (insert "helo wrld")
    (add-text-properties 1 5 '(read-only t))
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '("world"))))
      (proofread-test--install-diagnostics (list first second))
      (should-error (proofread-correct-buffer))
      (should (equal (buffer-string) "helo wrld"))
      (should (equal proofread--diagnostics (list first second)))
      (should (= (length (proofread--current-buffer-overlays)) 2)))))

(ert-deftest
    proofread-test-correct-buffer-revalidates-after-selection ()
  "Never overwrite edits made during suggestion selection."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello" "hullo"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (erase-buffer)
                   (insert "user text")
                   "hello")))
        (should-error (proofread-correct-buffer) :type 'user-error))
      (should (equal (buffer-string) "user text"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-correction-rejects-source-delimiter-suggestions ()
  "Corrections cannot introduce comment or string delimiters."
  (dolist (spec '((c-mode "/*helo*/" comment 2 6 "helo" "*/")
                  (emacs-lisp-mode "\"helo\"" docstring 1 5 "helo"
                                   "\"")
                  (emacs-lisp-mode "\"helo\"" docstring 1 5 "helo"
                                   "\\")))
    (with-temp-buffer
      (funcall (nth 0 spec))
      (insert (nth 1 spec))
      (syntax-propertize (point-max))
      (proofread-mode 1)
      (let* ((before (buffer-string))
             (request (list :buffer (current-buffer)
                            :beg (point-min)
                            :end (point-max)
                            :text before
                            :target-kind (nth 2 spec)))
             (content
              (proofread-test--response-content
               (list (proofread-test--response-diagnostic
                      (nth 3 spec) (nth 4 spec) (nth 5 spec)
                      (list (nth 6 spec))))))
             (diagnostic
              (car (proofread--diagnostics-from-structured-response
                    request content 'llm)))
             (overlay
              (car (proofread-test--install-diagnostics
                    (list diagnostic)))))
        (goto-char (plist-get diagnostic :beg))
        (should-error (proofread-correct-at-point) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal proofread--diagnostics (list diagnostic)))
        (should (overlay-buffer overlay))))))

(ert-deftest proofread-test-correction-allows-safe-comment-text ()
  "A source-aware correction still accepts ordinary comment prose."
  (with-temp-buffer
    (c-mode)
    (insert "/*helo*/")
    (syntax-propertize (point-max))
    (proofread-mode 1)
    (let* ((request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text (buffer-string)
                          :target-kind 'comment))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic
                    2 6 "helo" '("hello!")))))
           (diagnostic
            (car (proofread--diagnostics-from-structured-response
                  request content 'llm))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char (plist-get diagnostic :beg))
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "/*hello!*/")))))

(ert-deftest
    proofread-test-narrowed-correction-uses-full-source-container ()
  "Validate source delimiters outside the narrowed restriction."
  (dolist (spec '(("hello" . applied)
                  ("hello\\" . rejected)))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "\"helo\"")
      (syntax-propertize (point-max))
      (proofread-mode 1)
      (let* ((before (buffer-string))
             (diagnostic
              (proofread--make-diagnostic
               :beg 2 :end 6 :text "helo" :kind 'spelling
               :message "Possible misspelling"
               :suggestions (list (car spec)) :source 'test
               :target-kind 'docstring)))
        (proofread-test--install-diagnostics (list diagnostic))
        (narrow-to-region 2 6)
        (goto-char (point-min))
        (if (eq (cdr spec) 'applied)
            (should (eq (proofread-correct-at-point) 'applied))
          (should-error (proofread-correct-at-point) :type
                        'user-error))
        (widen)
        (should (equal (buffer-string)
                       (if (eq (cdr spec) 'applied)
                           "\"hello\""
                         before)))))))

(ert-deftest
    proofread-test-correction-invalidates-nested-same-buffer-edit ()
  "A correction hook cannot leave a remotely edited diagnostic stale."
  (with-temp-buffer
    (insert "helo tail")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "tail" '("tall")))
          nested-edit)
      (proofread-test--install-diagnostics (list first second))
      (add-hook
       'after-change-functions
       (lambda (&rest _)
         (unless nested-edit
           (setq nested-edit t)
           (save-excursion
             (goto-char (point-min))
             (when (search-forward "tail" nil t)
               (replace-match "fail" t t)))))
       nil t)
      (goto-char (point-min))
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "hello fail"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-correction-does-not-inhibit-other-buffer-edits ()
  "Limit correction invalidation inhibition to its source buffer."
  (let ((source (generate-new-buffer
                 " *proofread-correction-source*"))
        (other (generate-new-buffer " *proofread-correction-other*")))
    (unwind-protect
        (progn
          (with-current-buffer other
            (insert "helo")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" '("hello")))))
          (with-current-buffer source
            (insert "wrng")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "wrng" '("wrong"))))
            (let (nested-edit)
              (add-hook
               'after-change-functions
               (lambda (&rest _)
                 (unless nested-edit
                   (setq nested-edit t)
                   (with-current-buffer other
                     (goto-char 2)
                     (delete-char 1)
                     (insert "x"))))
               nil t)
              (goto-char (point-min))
              (should (eq (proofread-correct-at-point) 'applied))
              (should (equal (buffer-string) "wrong"))))
          (with-current-buffer other
            (should (equal (buffer-string) "hxlo"))
            (should-not proofread--diagnostics)
            (should-not proofread--overlays)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest
    proofread-test-failed-correction-repairs-other-buffer-edits ()
  "Repair edits in another buffer after rolling back a correction."
  (let ((source (generate-new-buffer " *proofread-failed-source*"))
        (other (generate-new-buffer " *proofread-failed-other*")))
    (unwind-protect
        (progn
          (with-current-buffer other
            (insert "helo")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" '("hello")))))
          (with-current-buffer source
            (emacs-lisp-mode)
            (insert "\"helo\"")
            (syntax-propertize (point-max))
            (proofread-mode 1)
            (let ((diagnostic
                   (proofread--make-diagnostic
                    :beg 2 :end 6 :text "helo" :kind 'spelling
                    :message "Possible misspelling"
                    :suggestions '("hello\\") :source 'test
                    :target-kind 'docstring))
                  nested-edit)
              (proofread-test--install-diagnostics (list diagnostic))
              (add-hook
               'after-change-functions
               (lambda (&rest _)
                 (unless nested-edit
                   (setq nested-edit t)
                   (with-current-buffer other
                     (goto-char 2)
                     (delete-char 1)
                     (insert "x"))))
               nil t)
              (goto-char 2)
              (should-error (proofread-correct-at-point) :type
                            'user-error)
              (should (equal (buffer-string) "\"helo\""))
              (should (equal proofread--diagnostics (list
                                                     diagnostic)))
              (should (= (length proofread--overlays) 1))))
          (with-current-buffer other
            (should (equal (buffer-string) "hxlo"))
            (should-not proofread--diagnostics)
            (should-not proofread--overlays)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest proofread-test-correct-buffer-notifies-diagnostics-once
    ()
  "Buffer correction emits one final diagnostics notification."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let ((calls 0)
          (first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '("hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '("world"))))
      (proofread-test--install-diagnostics (list first second))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread-correct-buffer)
      (should (= calls 1)))))

(ert-deftest proofread-test-apply-no-suggestion-reports-unavailable ()
  "Report missing suggestions without editing."
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
      (should-error (proofread-correct-at-point) :type 'user-error)
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
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-stale-overlay-rejected ()
  "Reject diagnostics without live owned overlays."
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
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-text-mismatch-rejected ()
  "Reject changed diagnostic text before replacement."
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
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "hell")))))

(ert-deftest proofread-test-apply-undo-restores-original-text ()
  "Undo restores text replaced by `proofread-correct-at-point'."
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
      (proofread-correct-at-point)
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
      (proofread-correct-at-point)
      (should-not (overlay-buffer target-overlay))
      (should-not (overlay-buffer overlap-overlay))
      (should (overlay-buffer outside-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--current-diagnostic)
      (should (equal proofread--diagnostics (list outside))))))

(ert-deftest
    proofread-test-non-apply-commands-do-not-apply-suggestions ()
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
  "Ignore keys include language and diagnostic meaning, not location."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (let ((proofread-language "en")
          (diagnostic
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
            10 14 "wrld" 'spelling))
          (different-message
           (proofread--make-diagnostic
            :beg 10 :end 14 :text "helo" :kind 'spelling
            :message "Different issue" :suggestions '("hello")
            :source 'test)))
      (should (equal (proofread--diagnostic-ignore-key diagnostic)
                     '(:language "en" :text "helo" :kind spelling
                                 :message "Possible issue" :source
                                 test)))
      (proofread--record-ignored-diagnostic diagnostic)
      (should (proofread--diagnostic-ignored-p same))
      (should-not (proofread--diagnostic-ignored-p different-kind))
      (should-not (proofread--diagnostic-ignored-p different-text))
      (should-not (proofread--diagnostic-ignored-p
                   different-message)))))

(ert-deftest proofread-test-ignore-command-removes-matching-overlays
    ()
  "Record ignored keys and remove their proofread overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
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
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
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
  "Filter ignored diagnostics before creating overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
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
                                   (overlay-get
                                    overlay
                                    'proofread-diagnostic))
                                 proofread--overlays)))
          (should (member different-kind displayed))
          (should (member different-text displayed))
          (should-not (member ignored displayed)))))))

(ert-deftest proofread-test-ignore-filters-backend-and-cache-results
    ()
  "Create no overlays for ignored backend or cached diagnostics."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let* ((chunk
              (car (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread--make-backend-request chunk 'llm))
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

(ert-deftest proofread-test-request-log-hook-observes-llm-lifecycle ()
  "Expose LLM request stages and final status in request events."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (content
            (proofread-test--response-content
             (list
              (proofread-test--response-diagnostic 1 5 "helo")
              (proofread-test--response-diagnostic 0 4 "hola"))))
           request
           events
           status)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success
                                                          content)))
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (setq request
              (proofread--make-backend-request
               (car (proofread--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max)))))
               'llm))
        (let ((proofread-request-log-hook
               (list (lambda (event)
                       (push event events)))))
          (should (proofread--dispatch-backend-request
                   request
                   (lambda (backend-result)
                     (setq status
                           (proofread--handle-backend-result
                            backend-result)))
                   'llm))
          (should (proofread-test--wait-for (lambda () status)))
          (setq events (nreverse events))
          (let ((types (mapcar (lambda (event)
                                 (plist-get event :type))
                               events)))
            (should (memq 'backend-request types))
            (should (memq 'backend-response types))
            (should (memq 'backend-result types))
            (should (memq 'final-result types)))
          (let ((backend-request
                 (cl-find-if (lambda (event)
                               (eq (plist-get event :type)
                                   'backend-request))
                             events))
                (backend-response
                 (cl-find-if (lambda (event)
                               (eq (plist-get event :type)
                                   'backend-response))
                             events))
                (backend-result
                 (cl-find-if (lambda (event)
                               (eq (plist-get event :type)
                                   'backend-result))
                             events))
                (final-result
                 (car (last events))))
            (should (plist-get backend-request :schema))
            (should (plist-get backend-request :prompt))
            (should (equal (plist-get backend-response :response)
                           content))
            (should (plist-get (plist-get backend-result :result)
                               :candidate-issues))
            (should (plist-get (plist-get backend-result :result)
                               :repairs))
            (should (eq (plist-get final-result :status)
                        'applied))))))))

(ert-deftest proofread-test-negative-request-log-limit-is-safe ()
  "A negative direct request-log limit is clamped instead of looping."
  (with-temp-buffer
    (proofread-mode 1)
    (setq proofread--request-log-enabled t)
    (let ((proofread-request-log-max-records -1))
      (proofread--request-log-record-event
       (list :type 'chunk-request
             :time (current-time)
             :log-id 1
             :request-id 1
             :buffer (current-buffer)
             :beg 1
             :end 1
             :request (list :log-id 1 :id 1 :buffer
                            (current-buffer))))
      (should-not proofread--request-log-order)
      (should (= (hash-table-count proofread--request-log-records)
                 0)))))

(ert-deftest
    proofread-test-request-log-buffer-lists-recorded-requests ()
  "List a buffer's request ranges."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-request-list-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "aa helo\nbb")
            (proofread-mode 1)
            (let* ((request
                    (list :log-id 9001
                          :id 7
                          :buffer source
                          :beg 4
                          :end 8
                          :text "helo"
                          :backend 'llm))
                   (name (proofread--request-log-list-buffer-name
                          source)))
              (unwind-protect
                  (progn
                    (proofread-show-buffer-requests source)
                    (proofread--request-log-record-event
                     (list :type 'chunk-request
                           :time (current-time)
                           :log-id 9001
                           :request-id 7
                           :buffer source
                           :beg 4
                           :end 8
                           :request request
                           :chunk request))
                    (with-current-buffer name
                      (should (eq major-mode
                                  'proofread-requests-buffer-mode))
                      (should (eq proofread--request-log-list-source
                                  source))
                      (should (= (length tabulated-list-entries) 1))
                      (let* ((entry (car tabulated-list-entries))
                             (id (car entry))
                             (columns (cadr entry)))
                        (should (= (plist-get id :key) 9001))
                        (should (equal (aref columns 0) "7"))
                        (should (equal (aref columns 1) "ready"))
                        (should (equal (aref columns 3) "1"))
                        (should (equal (aref columns 4) "3"))
                        (should (equal (aref columns 5) "4-8"))
                        (should (equal (aref columns 6) "llm"))
                        (should (equal (aref columns 7) "helo")))))
                (when-let* ((buffer (get-buffer name)))
                  (kill-buffer buffer)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-request-log-buffer-follows-visible-requests ()
  "Follow real visible dispatch in the request list."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-request-live-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert (concat "第一句。"
                            "第二句。"))
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider
                   proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 1)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name
                         source)))
              (unwind-protect
                  (proofread-test--with-llm-capabilities
                   (cl-letf (((symbol-function 'window-start)
                              (lambda (&optional _window)
                                (point-min)))
                             ((symbol-function 'window-end)
                              (lambda (&optional _window _update)
                                (point-max)))
                             ((symbol-function
                               'proofread--backend-check)
                              (plist-get recorder :function)))
                     (proofread-show-buffer-requests source)
                     (proofread-check-visible-range)
                     (with-current-buffer name
                       (should (= (length tabulated-list-entries) 2))
                       (let ((statuses
                              (mapcar (lambda (entry)
                                        (aref (cadr entry) 1))
                                      tabulated-list-entries)))
                         (should (member "waiting" statuses))
                         (should (member "queued" statuses))))
                     (let* ((requests (funcall
                                       (plist-get recorder
                                                  :requests)))
                            (callbacks (funcall
                                        (plist-get recorder
                                                   :callbacks)))
                            (first-request (car requests))
                            (first-callback (car callbacks)))
                       (should
                        (eq
                         (funcall
                          first-callback
                          (proofread--backend-success-result
                           first-request nil))
                         'applied)))
                     (with-current-buffer name
                       (let ((statuses
                              (mapcar (lambda (entry)
                                        (aref (cadr entry) 1))
                                      tabulated-list-entries)))
                         (should (member "applied" statuses))
                         (should (member "waiting" statuses))))))
                (when-let* ((buffer (get-buffer name)))
                  (kill-buffer buffer)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-source-kill-closes-associated-list-buffers ()
  "Killing a source closes its lists and releases request-log hooks."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-list-source-kill*"))
          diagnostics-name
          requests-name)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (setq diagnostics-name
                  (proofread--diagnostics-buffer-name))
            (setq requests-name
                  (proofread--request-log-list-buffer-name source))
            (proofread-show-buffer-diagnostics)
            (proofread-show-buffer-requests source)
            (should (get-buffer diagnostics-name))
            (should (get-buffer requests-name))
            (should (memq #'proofread--request-log-record-event
                          proofread-request-log-hook))
            (kill-buffer source)
            (should-not (get-buffer diagnostics-name))
            (should-not (get-buffer requests-name))
            (should-not (memq #'proofread--request-log-record-event
                              proofread-request-log-hook)))
        (when (buffer-live-p source)
          (kill-buffer source))
        (dolist (name (list diagnostics-name requests-name))
          (when-let* ((buffer (and name (get-buffer name))))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-list-major-mode-change-releases-source-hooks ()
  "Unregister source state when an auxiliary list changes mode."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-list-mode-change*"))
          diagnostics-buffer
          requests-buffer)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (proofread-show-buffer-diagnostics)
            (setq diagnostics-buffer
                  (get-buffer (proofread--diagnostics-buffer-name)))
            (proofread-show-buffer-requests source)
            (setq requests-buffer
                  (get-buffer
                   (proofread--request-log-list-buffer-name source)))
            (with-current-buffer requests-buffer
              (fundamental-mode))
            (with-current-buffer source
              (should-not proofread--request-log-enabled))
            (should-not (memq #'proofread--request-log-record-event
                              proofread-request-log-hook))
            (with-current-buffer diagnostics-buffer
              (fundamental-mode))
            (with-current-buffer source
              (should-not proofread--diagnostics-list-buffers)
              (should-not
               (memq #'proofread--refresh-diagnostics-list-buffers
                     proofread-diagnostics-changed-hook))))
        (dolist (buffer (list diagnostics-buffer requests-buffer
                              source))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-request-log-request-buffer-shows-lisp-data ()
  "Render detailed requests as read-only Lisp data."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-request-detail-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (let* ((request
                    (list :log-id 9002
                          :id 8
                          :buffer source
                          :beg 1
                          :end 5
                          :text "helo"
                          :backend 'llm))
                   (result
                    (proofread--backend-success-result
                     request
                     (list (proofread-test--diagnostic-for-range
                            1 5 "helo"))))
                   (record
                    (list :key 9002
                          :log-id 9002
                          :request-id 8
                          :source-buffer source
                          :buffer source
                          :beg 1
                          :end 5
                          :status 'applied
                          :chunk request
                          :request request
                          :backend-requests
                          (list (list :backend 'llm
                                      :pass 1
                                      :schema
                                      proofread--structured-response-schema
                                      :prompt nil))
                          :backend-responses
                          (list (list :backend 'llm
                                      :pass 1
                                      :response
                                      '(:diagnostics nil)))
                          :backend-results (list result)
                          :final-status 'applied
                          :final-result result))
                   (detail-name
                    (proofread--request-log-request-buffer-name
                     record)))
              (unwind-protect
                  (progn
                    (proofread--request-log-show-record record)
                    (with-current-buffer detail-name
                      (should buffer-read-only)
                      (should (eq major-mode 'lisp-data-mode))
                      (goto-char (point-min))
                      (dolist (heading '(";;; Summary"
                                         ";;; Chunk request"
                                         ";;; Lifecycle events"
                                         ";;; Backend requests"
                                         ";;; Backend responses"
                                         ";;; Parsed backend results"
                                         ";;; Final result"))
                        (should (search-forward heading nil t)))))
                (when-let* ((buffer (get-buffer detail-name)))
                  (kill-buffer buffer)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest proofread-test-targets-default-auto-and-buffer-local ()
  "`proofread-targets' defaults to automatic buffer-local selection."
  (should (custom-variable-p 'proofread-targets))
  (should (eq (default-value 'proofread-targets) 'auto))
  (should (local-variable-if-set-p 'proofread-targets))
  (with-temp-buffer
    (setq proofread-targets 'comments)
    (should (local-variable-p 'proofread-targets))
    (should (eq proofread-targets 'comments))
    (with-temp-buffer
      (should (eq proofread-targets 'auto)))))

(ert-deftest
    proofread-test-targets-auto-prog-selects-prose-containers ()
  "Select comments and docstrings as automatic programming targets."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n"
            ";; Comment prose token.\n"
            "(setq ordinary \"Ordinary string token.\")\n"
            "(defun sample ()\n"
            "  \"Docstring prose token.\"\n"
            "  code-token)\n")
    (let* ((chunks
            (proofread--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (eq proofread-targets 'auto))
      (should (string-match-p "Comment prose token" text))
      (should (string-match-p "Docstring prose token" text))
      (should-not (string-match-p "Ordinary string token" text))
      (should-not (string-match-p "setq code-token" text))
      (should (equal (delete-dups
                      (mapcar (lambda (chunk)
                                (plist-get chunk :target-kind))
                              chunks))
                     '(comment docstring))))))

(ert-deftest proofread-test-targets-auto-text-mode-selects-all-text ()
  "Automatic non-programming targets include the accessible text."
  (with-temp-buffer
    (text-mode)
    (insert "Plain prose sentence. Another sentence.")
    (let ((chunks
           (proofread--request-ready-chunks-for-ranges
            (list (cons (point-min) (point-max))))))
      (should (string-match-p
               "Plain prose sentence"
               (proofread-test--combined-chunk-text chunks)))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-policy) 'all))
        (should (eq (plist-get chunk :target-kind) 'text))
        (should (= (plist-get chunk :domain-beg) (point-min)))
        (should (= (plist-get chunk :domain-end) (point-max)))))))

(ert-deftest proofread-test-targets-explicit-programming-policies ()
  "Explicit target policies select their requested programming text."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n"
            ";; Comment prose token.\n"
            "(setq ordinary \"Ordinary string token.\")\n"
            "(defun sample ()\n"
            "  \"Docstring prose token.\"\n"
            "  code-token)\n")
    (dolist (case '((all t t t)
                    (comments t nil nil)
                    (docstrings nil t nil)
                    (comments-and-docstrings t t nil)))
      (setq-local proofread-targets (car case))
      (let* ((chunks
              (proofread--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (text (proofread-test--combined-chunk-text chunks)))
        (should (eq (not (null (string-match-p
                                "Comment prose token" text)))
                    (nth 1 case)))
        (should (eq (not (null (string-match-p
                                "Docstring prose token" text)))
                    (nth 2 case)))
        (should (eq (not (null (string-match-p
                                "setq code-token" text)))
                    (nth 3 case)))))))

(ert-deftest proofread-test-targets-auto-c-mode-selects-comments ()
  "Include C line and block comments but exclude strings."
  (with-temp-buffer
    (c-mode)
    (insert "int code_token = 1;\n"
            "// C line comment prose.\n"
            "char *ordinary = \"not // comment prose\";\n"
            "/* C block comment prose. */\n")
    (let* ((chunks
            (proofread--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (string-match-p "C line comment prose" text))
      (should (string-match-p "C block comment prose" text))
      (should-not (string-match-p "code_token" text))
      (should-not (string-match-p "not // comment prose" text))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-kind) 'comment))))))

(ert-deftest proofread-test-targets-auto-python-selects-docstrings ()
  "Include Python docstrings but exclude ordinary strings."
  (with-temp-buffer
    (insert "value = \"ordinary prose string\"\n\n"
            "def sample():\n"
            "    \"\"\"Python docstring prose.\"\"\"\n"
            "    return value\n")
    (python-mode)
    (let* ((chunks
            (proofread--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (string-match-p "Python docstring prose" text))
      (should-not (string-match-p "ordinary prose string" text))
      (should-not (string-match-p "return value" text))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-kind) 'docstring))))))

(ert-deftest proofread-test-target-region-and-narrowing-boundaries ()
  "Clip target regions and context to the current restriction."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Outside prefix. Before context sentence. "
            "Selected target sentence. After context sentence. "
            "Outside suffix.\n"
            "(setq code-token 1)\n")
    (goto-char (point-min))
    (search-forward "Before")
    (let ((narrow-beg (match-beginning 0)))
      (search-forward "Selected")
      (let ((selected-beg (match-beginning 0)))
        (search-forward "sentence.")
        (let ((selected-end (point)))
          (search-forward "Outside suffix")
          (let ((narrow-end (match-beginning 0)))
            (narrow-to-region narrow-beg narrow-end)
            (let* ((chunks
                    (proofread--request-ready-chunks-for-ranges
                     (list (cons selected-beg selected-end))))
                   (chunk (car chunks))
                   (payload
                    (concat (plist-get chunk :context-before)
                            (plist-get chunk :text)
                            (plist-get chunk :context-after))))
              (should (= (length chunks) 1))
              (should (= (plist-get chunk :beg) selected-beg))
              (should (= (plist-get chunk :end) selected-end))
              (should (= (plist-get chunk :domain-beg) (point-min)))
              (should (= (plist-get chunk :domain-end) (point-max)))
              (should (equal (plist-get chunk :text)
                             "Selected target sentence."))
              (should (string-match-p "Before context sentence"
                                      payload))
              (should (string-match-p "After context sentence"
                                      payload))
              (should-not (string-match-p "Outside prefix" payload))
              (should-not (string-match-p "Outside suffix" payload))
              (should-not (string-match-p "code-token"
                                          payload)))))))))

(ert-deftest proofread-test-check-at-point-programming-targets ()
  "Point checking rejects code and dispatches the containing comment."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n;; Comment point prose.\n")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "code-token")
    (should-error (proofread-check-at-point) :type 'user-error)
    (goto-char (point-min))
    (search-forward "point prose")
    (let ((proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (plist-get recorder :function)))
         (proofread-check-at-point)
         (let* ((requests (funcall (plist-get recorder :requests)))
                (request (car requests)))
           (should (= (length requests) 1))
           (should (eq (plist-get request :target-kind) 'comment))
           (should (string-match-p "Comment point prose"
                                   (plist-get request :text)))))))))

(ert-deftest
    proofread-test-target-metadata-is-part-of-request-and-cache-key ()
  "Carry target policy and kind into requests and cache keys."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Comment metadata prose.\n"
            "(defun sample ()\n  \"Docstring metadata prose.\")\n")
    (setq-local proofread-targets 'comments-and-docstrings)
    (let* ((chunks
            (proofread--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (comment
            (cl-find 'comment chunks
                     :key (lambda (chunk)
                            (plist-get chunk :target-kind))))
           (docstring
            (cl-find 'docstring chunks
                     :key (lambda (chunk)
                            (plist-get chunk :target-kind))))
           (request (proofread--make-backend-request comment 'llm))
           (key (proofread--cache-key comment 'llm)))
      (should comment)
      (should docstring)
      (should (eq (plist-get request :target-policy)
                  'comments-and-docstrings))
      (should (eq (plist-get request :target-kind) 'comment))
      (should (= (plist-get request :domain-beg)
                 (plist-get comment :domain-beg)))
      (should (= (plist-get request :domain-end)
                 (plist-get comment :domain-end)))
      (should (eq (plist-get key :target-policy)
                  'comments-and-docstrings))
      (should (eq (plist-get key :target-kind) 'comment))
      (let ((changed-kind (copy-sequence comment))
            (changed-policy (copy-sequence comment)))
        (setq changed-kind
              (plist-put changed-kind :target-kind 'docstring))
        (setq changed-policy
              (plist-put changed-policy :target-policy 'all))
        (should-not (equal key (proofread--cache-key changed-kind
                                                     'llm)))
        (should-not (equal key (proofread--cache-key changed-policy
                                                     'llm)))))))

(ert-deftest proofread-test-target-option-change-makes-request-stale
    ()
  "Reject old results after changing the target policy."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Comment stale prose.\n")
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (beg (plist-get request :beg))
           (diagnostic
            (proofread-test--diagnostic-for-range
             beg (+ beg 7)
             (buffer-substring-no-properties beg (+ beg 7)))))
      (setq-local proofread-targets 'all)
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-programming-request-freshness-preserves-point ()
  "Asynchronous comment freshness checks preserve point and mark."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Checked prose sentence.\n"
            "(setq cursor_and_mark_stay_here 1)\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (let* ((proofread-context-size 0)
           (chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (goto-char (point-min))
      (search-forward "cursor_and_mark")
      (push-mark (line-end-position) t t)
      (let ((before-point (point))
            (before-mark (mark t))
            (before-mark-active mark-active))
        (should (proofread--fresh-request-p request))
        (should (= (point) before-point))
        (should (= (mark t) before-mark))
        (should (eq mark-active before-mark-active))))))

(ert-deftest
    proofread-test-backend-nil-prunes-checked-out-of-target-diagnostics
    ()
  "A backend-less check prunes invalid checked diagnostics only."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Valid comment prose.\n"
            "(setq invalid-code 1)\n"
            "(setq outside-code 2)\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "Valid")
    (let* ((valid-beg (match-beginning 0))
           (valid-end (match-end 0))
           (valid
            (proofread-test--diagnostic-for-range
             valid-beg valid-end "Valid")))
      (search-forward "invalid-code")
      (let* ((invalid-beg (match-beginning 0))
             (invalid-end (match-end 0))
             (check-end (line-end-position))
             (invalid
              (proofread-test--diagnostic-for-range
               invalid-beg invalid-end "invalid-code")))
        (search-forward "outside-code")
        (let* ((outside-beg (match-beginning 0))
               (outside-end (match-end 0))
               (outside
                (proofread-test--diagnostic-for-range
                 outside-beg outside-end "outside-code"))
               (overlays
                (proofread-test--install-diagnostics
                 (list valid invalid outside)))
               (valid-overlay (nth 0 overlays))
               (invalid-overlay (nth 1 overlays))
               (outside-overlay (nth 2 overlays))
               (proofread-backend nil))
          (proofread-check-region (point-min) check-end)
          (should (equal proofread--diagnostics (list valid outside)))
          (should (overlay-buffer valid-overlay))
          (should-not (overlay-buffer invalid-overlay))
          (should (overlay-buffer outside-overlay)))))))

(ert-deftest
    proofread-test-target-pruning-keeps-zero-width-domain-end ()
  "Keep a zero-width diagnostic at its target's end."
  (with-temp-buffer
    (insert "Hello")
    (proofread-mode 1)
    (let* ((position (point-max))
           (diagnostic
            (proofread--make-diagnostic
             :beg position :end position :text "" :kind 'grammar
             :message "Missing punctuation" :suggestions '(".")
             :source 'test :target-kind 'text))
           (overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic)))))
      (proofread--prune-diagnostics-outside-targets
       (list (cons (point-min) (point-max)))
       (list (list :kind 'text
                   :target-policy 'all
                   :domain-beg (point-min)
                   :domain-end (point-max))))
      (should (equal proofread--diagnostics (list diagnostic)))
      (should (overlay-buffer overlay)))))

(ert-deftest
    proofread-test-consecutive-line-comments-share-context-domain ()
  "Indented adjacent line comments share context until a blank line."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "    ;; First context sentence.\n"
            "    ;; Later target sentence.\n"
            "\n"
            "    ;; Isolated comment sentence.\n")
    (setq-local proofread-targets 'comments)
    (goto-char (point-min))
    (search-forward "Later")
    (let ((later-beg (match-beginning 0)))
      (search-forward "sentence.")
      (let ((later-end (point)))
        (search-forward "Isolated")
        (let ((isolated-beg (match-beginning 0)))
          (search-forward "sentence.")
          (let* ((isolated-end (point))
                 (domains
                  (proofread--comment-domains-for-ranges
                   (list (cons (point-min) (point-max)))))
                 (first-domain (nth 0 domains))
                 (isolated-domain (nth 1 domains))
                 (proofread-context-size 300)
                 (proofread-context-sentences-before 1)
                 (proofread-context-sentences-after 1)
                 (later-chunk
                  (car (proofread--request-ready-chunks-for-ranges
                        (list (cons later-beg later-end)))))
                 (isolated-chunk
                  (car (proofread--request-ready-chunks-for-ranges
                        (list (cons isolated-beg isolated-end))))))
            (should (= (length domains) 2))
            (should (< (car first-domain) later-beg))
            (should (<= later-end (cdr first-domain)))
            (should (< (cdr first-domain) (car isolated-domain)))
            (should (= (plist-get later-chunk :domain-beg)
                       (car first-domain)))
            (should (= (plist-get later-chunk :domain-end)
                       (cdr first-domain)))
            (should (string-match-p
                     "First context sentence"
                     (plist-get later-chunk :context-before)))
            (should (= (plist-get isolated-chunk :domain-beg)
                       (car isolated-domain)))
            (should (= (plist-get isolated-chunk :domain-end)
                       (cdr isolated-domain)))
            (should-not (string-match-p
                         "Later target sentence"
                         (plist-get isolated-chunk
                                    :context-before)))))))))

(ert-deftest
    proofread-test-consecutive-comments-use-language-sentences ()
  "Use language sentences rather than comment source lines."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; This sentence begins here and\n"
            ";; ends on this line. A second sentence starts\n"
            ";; and ends here.\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (let ((proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 10)
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (plist-get recorder :function)))
         (proofread-check-buffer)
         (let ((requests (funcall (plist-get recorder :requests))))
           (should (= (length requests) 2))
           (should (string-match-p
                    "This sentence begins"
                    (plist-get (nth 0 requests) :text)))
           (should (string-match-p
                    "ends on this line\\."
                    (plist-get (nth 0 requests) :text)))
           (should (string-match-p
                    "A second sentence starts"
                    (plist-get (nth 1 requests) :text)))
           (should (string-match-p
                    "and ends here\\."
                    (plist-get (nth 1 requests) :text)))
           (dolist (request requests)
             (should (eq (plist-get request :target-kind) 'comment))
             (should (equal
                      (plist-get request :text)
                      (buffer-substring-no-properties
                       (plist-get request :beg)
                       (plist-get request :end)))))))))))

(ert-deftest
    proofread-test-comment-delimiters-follow-major-mode-syntax ()
  "Mode-specific comment delimiters do not split hard-wrapped prose."
  (dolist
      (case
       (list
        (list
         'emacs-lisp-mode
         (concat
          ";; This file is free software: you can redistribute it "
          "and/or modify\n"
          ";; it under the terms of the GNU General Public License "
          "as published\n"
          ";; by the Free Software Foundation, either version 3 "
          "of the License,\n"
          ";; or (at your option) any later version.\n")
         "This file is free software" "any later version")
        (list
         'c-mode
         (concat "// First C line continues\n"
                 "// through the next source line.\n")
         "First C line" "next source line")
        (list
         'c-mode
         (concat "/* First block line continues\n"
                 " * through the next source line. */\n")
         "First block line" "next source line")
        (list
         'html-mode
         (concat "<!-- First HTML line continues\n"
                 "through the next source line. -->\n")
         "First HTML line" "next source line")))
    (with-temp-buffer
      (funcall (nth 0 case))
      (setq-local proofread-targets 'comments)
      (insert (nth 1 case))
      (let* ((chunks
              (proofread--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (chunk (car chunks)))
        (should (= (length chunks) 1))
        (should (string-match-p (regexp-quote (nth 2 case))
                                (plist-get chunk :text)))
        (should (string-match-p (regexp-quote (nth 3 case))
                                (plist-get chunk :text)))
        (should (eq (plist-get chunk :target-kind) 'comment))
        (should (equal
                 (plist-get chunk :text)
                 (buffer-substring-no-properties
                  (plist-get chunk :beg)
                  (plist-get chunk :end))))))))

(ert-deftest
    proofread-test-hard-wrapped-comment-sentence-stays-in-context ()
  "Comment context keeps a logical sentence spanning source lines."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; First hard-wrapped part of one\n"
            ";; sentence ends here.\n"
            ";; Target sentence.\n")
    (setq-local proofread-targets 'comments)
    (goto-char (point-min))
    (search-forward "Target sentence.")
    (let* ((proofread-context-size 300)
           (proofread-context-sentences-before 1)
           (proofread-context-sentences-after 0)
           (chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (match-beginning 0) (match-end 0))))))
           (context (plist-get chunk :context-before)))
      (should (string-match-p "First hard-wrapped part" context))
      (should (string-match-p "sentence ends here\\." context)))))

(ert-deftest proofread-test-ignore-changes-make-request-stale ()
  "Stale requests only when relevant ignore settings change."
  (with-temp-buffer
    (insert "Alpha prose.")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-ignored-properties '(proofread-test-ignore))
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (chars-tick (buffer-chars-modified-tick)))
      (add-text-properties
       (plist-get request :beg)
       (1+ (plist-get request :beg))
       '(proofread-test-ignore t))
      (should (= chars-tick (buffer-chars-modified-tick)))
      (should-not (proofread--fresh-request-p request))))
  (with-temp-buffer
    (insert "Beta prose.")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (setq-local proofread-ignored-properties
                  '(proofread-test-ignore))
      (should (proofread--fresh-request-p request)))))

(ert-deftest
    proofread-test-python-docstring-predicate-receives-full-triple-string
    ()
  "Custom predicates receive a complete Python triple-quoted string."
  (with-temp-buffer
    (insert "def sample():\n"
            "    \"\"\"Python docstring prose.\n"
            "    Continued prose.\"\"\"\n"
            "    return 1\n")
    (python-mode)
    (goto-char (point-min))
    (search-forward "\"\"\"")
    (let ((expected-beg (match-beginning 0)))
      (search-forward "\"\"\"")
      (let ((expected-end (match-end 0))
            calls)
        (setq-local proofread-targets 'docstrings)
        (setq-local
         proofread-docstring-predicate-functions
         (list (lambda (beg end)
                 (push (cons beg end) calls)
                 t)))
        (cl-letf (((symbol-function
                    'proofread--font-lock-docstring-domain)
                   (lambda (_range) nil)))
          (let ((domains
                 (proofread--docstring-domains-for-ranges
                  (list (cons (point-min) (point-max))))))
            (should (equal domains
                           (list (cons expected-beg expected-end))))
            (should calls)
            (dolist (range calls)
              (should (equal range
                             (cons expected-beg expected-end))))))))))

(ert-deftest
    proofread-test-disable-reenable-rejects-old-generation-callback ()
  "Reject old callbacks from a re-enabled mode generation."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (plist-get recorder :function)))
         (let* ((old-request
                 (car (proofread--dispatch-request-ready-chunks
                       (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))
                       'llm)))
                (old-callback
                 (car (funcall (plist-get recorder :callbacks))))
                (old-generation (plist-get old-request :generation)))
           (proofread-mode -1)
           (proofread-mode 1)
           (let* ((new-request
                   (car (proofread--dispatch-request-ready-chunks
                         (proofread--request-ready-chunks-for-ranges
                          (list (cons (point-min) (point-max))))
                         'llm)))
                  (new-log-id (plist-get new-request :log-id)))
             (should-not (= old-generation
                            (plist-get new-request :generation)))
             (should (eq
                      (funcall
                       old-callback
                       (proofread--backend-success-result
                        old-request
                        (list (proofread-test--diagnostic-for-range
                               1 5 "helo"))))
                      'stale))
             (should (= (length proofread--active-requests) 1))
             (should (= (plist-get (car proofread--active-requests)
                                   :log-id)
                        new-log-id))
             (should-not proofread--diagnostics))))))))

(ert-deftest proofread-test-backend-callback-is-at-most-once ()
  "Complete requests only once when backends callback twice."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           captured-callback
           (calls 0))
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (lambda (_request callback &optional _backend)
                   (setq captured-callback callback)
                   'proofread-test-handle)))
        (proofread--dispatch-backend-request
         request
         (lambda (_result)
           (setq calls (1+ calls)))
         'llm)
        (let ((result (proofread--backend-success-result request
                                                         nil)))
          (funcall captured-callback result)
          (funcall captured-callback result))
        (should (= calls 1))
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-repeated-mode-enable-resets-owned-state ()
  "Explicitly enabling an enabled mode starts a clean generation."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((generation proofread--generation)
           (diagnostic (proofread-test--diagnostic-for-range 1 5
                                                             "helo"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (proofread--cache-write 'old-cache 'old-value)
      (proofread-mode 1)
      (should proofread-mode)
      (should-not (= proofread--generation generation))
      (should-not (overlay-buffer overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--active-requests)
      (should-not proofread--request-queue)
      (should (= (hash-table-count proofread--cache) 0)))))

(ert-deftest
    proofread-test-major-mode-change-tears-down-proofread-mode ()
  "Changing major mode removes Proofread hooks, state, and overlays."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic-for-range 1 5
                                                             "helo"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (text-mode)
      (should-not proofread-mode)
      (should-not (overlay-buffer overlay))
      (should-not (memq (current-buffer) proofread--mode-buffers))
      (should-not (memq #'proofread--before-change
                        before-change-functions)))))

(ert-deftest
    proofread-test-zero-width-diagnostic-invalidated-by-insertion ()
  "Clear owned state after inserting at a zero-width diagnostic."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread--make-diagnostic
             :beg 2 :end 2 :text "" :kind 'grammar
             :message "Missing punctuation" :suggestions '(",")
             :source 'test))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (goto-char 2)
      (insert ",")
      (should-not (overlay-buffer overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-edit-before-request-invalidates-shifted-duplicate
    ()
  "Stale requests after edits before their source range."
  (with-temp-buffer
    (insert "helo helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        '((6 . 10)))))
           (request (proofread--make-backend-request chunk 'llm)))
      (goto-char (point-min))
      (insert "helo ")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p request)))))

(ert-deftest
    proofread-test-request-cache-key-is-frozen-at-construction ()
  "Freeze request cache keys when constructing requests."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider-a")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (key (plist-get request :cache-key))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (let ((proofread-llm-provider-identity "provider-b"))
        (proofread--cache-write-request request (list diagnostic))
        (should (equal (plist-get request :cache-key) key))
        (should (gethash key proofread--cache))))))

(ert-deftest proofread-test-provider-identity-is-snapshotted ()
  "Destructive identity changes cannot mutate pending request keys."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((name (copy-sequence "alpha"))
           (proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity (list :provider name))
           (chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (work-key-text
            (prin1-to-string (proofread--request-work-key request))))
      (proofread--queue-request request 'llm)
      (aset name 0 ?o)
      (should
       (equal (plist-get (plist-get request :backend-identity)
                         :provider)
              '(:provider "alpha")))
      (should (equal (prin1-to-string (proofread--request-work-key
                                       request))
                     work-key-text))
      (should (proofread--request-work-pending-p request))
      (should-not (proofread--fresh-request-p request)))))

(ert-deftest proofread-test-provider-switch-makes-request-stale ()
  "Invalidate old requests when provider identity changes."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider-a")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (let ((proofread-llm-provider-identity "provider-b"))
        (should-not (proofread--fresh-request-p request))))))

(ert-deftest proofread-test-context-edit-makes-request-stale ()
  "Editing request context invalidates a still-unchanged target."
  (with-temp-buffer
    (insert "Before. Target. After.")
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "Target.")
    (let* ((beg (match-beginning 0))
           (end (match-end 0))
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons beg end)))))
           (request (proofread--make-backend-request chunk 'llm)))
      (goto-char (point-min))
      (delete-char 1)
      (insert "X")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p request)))))

(ert-deftest
    proofread-test-newer-overlapping-result-wins-out-of-order ()
  "A superseded result cannot overwrite a newer overlapping result."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (older (proofread--make-backend-request chunk 'llm))
           (newer (proofread--make-backend-request chunk 'llm))
           (old-diagnostic
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '("hullo")))
           (new-diagnostic
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '("hello"))))
      (proofread--register-active-request older)
      (proofread--finish-superseded-requests
       (proofread--supersede-conflicting-requests (list newer)))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    newer (list new-diagnostic)))
                  'applied))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    older (list old-diagnostic)))
                  'stale))
      (should (equal proofread--diagnostics (list new-diagnostic))))))

(ert-deftest proofread-test-cache-evicts-least-recently-used-entry ()
  "The buffer-local cache honors its least-recently-used size limit."
  (with-temp-buffer
    (proofread-mode 1)
    (let ((proofread-cache-max-entries 2))
      (proofread--cache-write 'a 1)
      (proofread--cache-write 'b 2)
      (should (= (proofread--cache-read 'a) 1))
      (proofread--cache-write 'c 3)
      (should (= (proofread--cache-read 'a) 1))
      (should-not (proofread--cache-read 'b))
      (should (= (proofread--cache-read 'c) 3))
      (should (= (hash-table-count proofread--cache) 2)))))

(ert-deftest proofread-test-zero-concurrency-prunes-stale-queue-heads
    ()
  "Prune stale queue heads and resume after capacity grows."
  (with-temp-buffer
    (insert "One. Two. Three.")
    (proofread-mode 1)
    (let* ((chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (requests
            (mapcar (lambda (chunk)
                      (proofread--make-backend-request chunk 'llm))
                    chunks))
           (invalidated (nth 0 requests))
           (superseded (nth 1 requests))
           (ready (nth 2 requests))
           dispatched)
      (should (= (length requests) 3))
      (dolist (request requests)
        (proofread--queue-request request 'llm))
      (proofread--invalidate-request invalidated)
      (proofread--set-request-state-flag superseded :superseded)
      (let ((proofread-max-concurrent-requests 0))
        (should-not (proofread--dispatch-queued-requests))
        (should (= (length proofread--request-queue) 1))
        (should (eq (plist-get (car proofread--request-queue)
                               :request)
                    ready))
        (should-not (proofread--request-work-pending-p invalidated))
        (should-not (proofread--request-work-pending-p superseded))
        (should (proofread--request-work-pending-p ready)))
      (let ((proofread-max-concurrent-requests 1))
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request _callback &optional _backend)
                     (setq dispatched request)
                     'proofread-test-handle)))
          (should (equal (proofread--dispatch-queued-requests)
                         (list ready)))))
      (should (eq dispatched ready))
      (should-not proofread--request-queue)
      (should-not proofread--request-queue-tail)
      (should (proofread--active-request-p ready)))))

(ert-deftest proofread-test-reentrant-queue-dispatch-submits-once ()
  "A freshness predicate cannot submit the queue head twice."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          reentered
          submitted-log-ids
          callback)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request chunk 'llm))
             (log-id (plist-get request :log-id)))
        (proofread--queue-request request 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread--dispatch-queued-requests))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (backend-request backend-callback
                                            &optional _backend)
                     (push (plist-get backend-request :log-id)
                           submitted-log-ids)
                     (setq callback backend-callback)
                     (list :backend 'test :log-id log-id))))
          (should (equal (proofread--dispatch-queued-requests)
                         (list request)))
          (should (equal submitted-log-ids (list log-id)))
          (should-not proofread--request-queue)
          (should-not proofread--claimed-requests)
          (should (= (length proofread--active-requests) 1))
          (should (equal
                   (gethash (proofread--request-work-key request)
                            proofread--pending-request-keys)
                   log-id))
          (funcall callback (proofread--backend-success-result
                             request nil))
          (should (equal submitted-log-ids (list log-id)))
          (should-not proofread--active-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys)
                     0)))))))

(ert-deftest
    proofread-test-reentrant-freshness-preserves-conflicting-new-work
    ()
  "Replace claimed requests with conflicting reentrant work."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          reentered
          submitted
          callback)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request old-chunk 'llm)))
        (proofread--queue-request old 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread--dispatch-request-ready-chunks
                        (list new-chunk) 'llm))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request backend-callback &optional
                                    _backend)
                     (push request submitted)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :log-id (plist-get request :log-id)))))
          (let ((dispatched (proofread--dispatch-queued-requests)))
            (should (= (length dispatched) 1))
            (should (eq (car dispatched) (car submitted))))
          (let* ((new (car submitted))
                 (new-log-id (plist-get new :log-id)))
            (should-not (equal new-log-id (plist-get old :log-id)))
            (should (proofread--request-state-flag-p old :superseded))
            (should (proofread--request-state-flag-p old :cancelled))
            (should (= (length submitted) 1))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)
            (should (equal
                     (mapcar (lambda (request)
                               (plist-get request :log-id))
                             proofread--active-requests)
                     (list new-log-id)))
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       1))
            (should (equal
                     (gethash (proofread--request-work-key new)
                              proofread--pending-request-keys)
                     new-log-id))
            (funcall callback
                     (proofread--backend-success-result new nil))
            (should-not proofread--active-requests)
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       0))))))))

(ert-deftest
    proofread-test-cancel-hook-reentrant-dispatch-does-not-duplicate
    ()
  "Cancellation hooks cannot submit a retained queue entry twice."
  (with-temp-buffer
    (insert "abc def")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          nested
          submitted-log-ids
          callbacks)
      (proofread-mode 1)
      (let* ((victim-chunk (proofread--make-request-ready-chunk 1 4))
             (new-chunk (proofread--make-request-ready-chunk 2 5))
             (unrelated-chunk (proofread--make-request-ready-chunk 5
                                                                   8))
             (victim (proofread--make-backend-request victim-chunk
                                                      'llm))
             (unrelated
              (proofread--make-backend-request unrelated-chunk 'llm))
             (victim-log-id (plist-get victim :log-id))
             (unrelated-log-id (plist-get unrelated :log-id))
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (and (not nested)
                            (eq (plist-get event :type) 'cancelled)
                            (equal (plist-get event :log-id)
                                   victim-log-id))
                   (setq nested t)
                   (proofread--dispatch-queued-requests))))))
        (setq victim (plist-put victim :handle 'victim-handle))
        (proofread--register-active-request victim)
        (proofread--queue-request unrelated 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request callback &optional _backend)
                     (let ((log-id (plist-get request :log-id)))
                       (push log-id submitted-log-ids)
                       (push (cons log-id callback) callbacks)
                       (list :backend 'test :log-id log-id)))))
          (proofread--dispatch-request-ready-chunks (list new-chunk)
                                                    'llm)
          (should (equal submitted-log-ids (list unrelated-log-id)))
          (should (proofread--request-state-flag-p victim
                                                   :superseded))
          (should (proofread--request-state-flag-p victim :cancelled))
          (should-not proofread--claimed-requests)
          (should (= (length proofread--request-queue) 1))
          (let* ((new
                  (plist-get (car proofread--request-queue) :request))
                 (new-log-id (plist-get new :log-id)))
            (funcall (cdr (assq unrelated-log-id callbacks))
                     (proofread--backend-success-result unrelated
                                                        nil))
            (should (= (cl-count unrelated-log-id submitted-log-ids)
                       1))
            (should (= (cl-count new-log-id submitted-log-ids) 1))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)
            (funcall (cdr (assq new-log-id callbacks))
                     (proofread--backend-success-result new nil))
            (should-not proofread--active-requests)
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       0))))))))

(ert-deftest
    proofread-test-edit-during-claimed-freshness-prevents-submit ()
  "Stop submission after an edit during freshness checks."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          edited
          backend-calls)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request chunk 'llm)))
        (proofread--queue-request request 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless edited
                       (setq edited t)
                       (goto-char (point-min))
                       (delete-char 1)
                       (insert "X"))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (&rest _)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest proofread-test-active-event-edit-prevents-backend-submit
    ()
  "Stop submission after active-request event edits."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          edited
          backend-calls)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request chunk 'llm))
             (log-id (plist-get request :log-id))
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (and (not edited)
                            (eq (plist-get event :type)
                                'active-request)
                            (equal (plist-get event :log-id) log-id))
                   (setq edited t)
                   (goto-char (point-min))
                   (delete-char 1)
                   (insert "X"))))))
        (proofread--queue-request request 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (&rest _)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-invalidated-active-releases-slot-for-queued-work ()
  "Free active request slots for queued work after edits."
  (with-temp-buffer
    (insert "aaa bbb")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles
          callback)
      (proofread-mode 1)
      (let* ((waiting-chunk (proofread--make-request-ready-chunk 1 4))
             (active-chunk (proofread--make-request-ready-chunk 5 8))
             (waiting (proofread--make-backend-request waiting-chunk
                                                       'llm))
             (active (proofread--make-backend-request active-chunk
                                                      'llm))
             (waiting-log-id (plist-get waiting :log-id)))
        (setq active (plist-put active :handle 'old-handle))
        (proofread--register-active-request active)
        (proofread--queue-request waiting 'llm)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request backend-callback &optional
                                    _backend)
                     (push (plist-get request :log-id)
                           submitted-log-ids)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :log-id (plist-get request :log-id))))
                  ((symbol-function 'proofread--cancel-request-handle)
                   (lambda (handle)
                     (push handle cancelled-handles))))
          (goto-char 6)
          (delete-char 1)
          (insert "b")
          (should
           (proofread-test--wait-for (lambda () submitted-log-ids)))
          (should (equal submitted-log-ids (list waiting-log-id)))
          (should (equal cancelled-handles (list 'old-handle)))
          (should (proofread--request-invalidated-p active))
          (should (proofread--request-state-flag-p active :cancelled))
          (should-not (proofread--active-request-p active))
          (should (proofread--active-request-p waiting))
          (should-not proofread--request-queue)
          (should-not proofread--claimed-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys) 1))
          (should (equal
                   (gethash (proofread--request-work-key waiting)
                            proofread--pending-request-keys)
                   waiting-log-id))
          (funcall callback
                   (proofread--backend-success-result waiting nil))
          (should-not proofread--active-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys)
                     0)))))))

(ert-deftest proofread-test-stale-active-request-does-not-block-queue
    ()
  "Prevent stale active work from holding request slots."
  (with-temp-buffer
    (insert "aaa bbb")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity "provider-a")
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (let* ((chunks
               (proofread--request-ready-chunks-for-ranges
                '((1 . 4) (5 . 8))))
              (active
               (proofread--make-backend-request
                (nth 1 chunks) 'llm)))
         (setq active (plist-put active :handle 'old-handle))
         (proofread--register-active-request active)
         (setq proofread-llm-provider-identity "provider-b")
         (let* ((waiting
                 (proofread--make-backend-request
                  (car chunks) 'llm))
                (waiting-log-id (plist-get waiting :log-id)))
           (proofread--queue-request waiting 'llm)
           (cl-letf (((symbol-function 'proofread--backend-check)
                      (lambda (request _callback &optional _backend)
                        (push (plist-get request :log-id)
                              submitted-log-ids)
                        (list :backend 'test
                              :log-id (plist-get request :log-id))))
                     ((symbol-function
                       'proofread--cancel-request-handle)
                      (lambda (handle)
                        (push handle cancelled-handles))))
             (should (equal (proofread--dispatch-queued-requests)
                            (list waiting))))
           (should (equal submitted-log-ids (list waiting-log-id)))
           (should (equal cancelled-handles (list 'old-handle)))
           (should (proofread--request-invalidated-p active))
           (should (proofread--request-state-flag-p active
                                                    :cancelled))
           (should-not (proofread--active-request-p active))
           (should (proofread--active-request-p waiting))
           (should-not proofread--request-queue)
           (should-not proofread--claimed-requests)))))))

(ert-deftest proofread-test-context-stale-active-resumes-queued-work
    ()
  "Resume queued work after editing saved context."
  (with-temp-buffer
    (insert "Aaa. Bbb. Ccc.")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-sentences-before 0)
          (proofread-context-sentences-after 1)
          (proofread-context-size 200)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (let* ((waiting-chunk
               (car (proofread--request-ready-chunks-for-ranges
                     '((1 . 5)))))
              (active-chunk
               (car (proofread--request-ready-chunks-for-ranges
                     '((6 . 10)))))
              (waiting
               (proofread--make-backend-request waiting-chunk 'llm))
              (active
               (proofread--make-backend-request active-chunk 'llm))
              (waiting-log-id (plist-get waiting :log-id)))
         (setq active (plist-put active :handle 'old-handle))
         (proofread--register-active-request active)
         (proofread--queue-request waiting 'llm)
         (cl-letf (((symbol-function 'proofread--backend-check)
                    (lambda (request _callback &optional _backend)
                      (push (plist-get request :log-id)
                            submitted-log-ids)
                      (list :backend 'test
                            :log-id (plist-get request :log-id))))
                   ((symbol-function
                     'proofread--cancel-request-handle)
                    (lambda (handle)
                      (push handle cancelled-handles))))
           (goto-char 11)
           (delete-char 1)
           (insert "X")
           (should-not (proofread--request-invalidated-p active))
           (should (timerp proofread--queue-dispatch-timer))
           (should
            (proofread-test--wait-for (lambda () submitted-log-ids)))
           (should (equal submitted-log-ids (list waiting-log-id)))
           (should (equal cancelled-handles (list 'old-handle)))
           (should (proofread--request-invalidated-p active))
           (should (proofread--request-state-flag-p active
                                                    :cancelled))
           (should-not (proofread--active-request-p active))
           (should (proofread--active-request-p waiting))
           (should-not proofread--request-queue)
           (should-not proofread--claimed-requests)))))))

(ert-deftest proofread-test-queue-inhibition-is-buffer-specific ()
  "Keep buffer lifecycle transactions independent."
  (let ((source (generate-new-buffer " *proofread-queue-source*"))
        (other (generate-new-buffer " *proofread-queue-other*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (proofread-mode 1))
          (with-current-buffer other
            (insert "Alpha")
            (proofread-mode 1))
          (let ((proofread--inhibit-queue-dispatch source)
                submitted-log-ids)
            (with-current-buffer other
              (let* ((chunk (proofread--make-request-ready-chunk 1 6))
                     (request (proofread--make-backend-request chunk
                                                               'llm))
                     (log-id (plist-get request :log-id)))
                (proofread--queue-request request 'llm)
                (cl-letf (((symbol-function
                            'proofread--fresh-request-p)
                           (lambda (_request) t))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request _callback
                                                    &optional
                                                    _backend)
                             (push (plist-get backend-request :log-id)
                                   submitted-log-ids)
                             (list :backend 'test :log-id log-id))))
                  (should (equal (proofread--dispatch-queued-requests)
                                 (list request))))
                (should (equal submitted-log-ids (list log-id)))
                (should-not proofread--request-queue)
                (should-not proofread--claimed-requests)))))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest proofread-test-submit-error-does-not-strand-claimed-work
    ()
  "Leave no claimed or pending work after submission errors."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request chunk 'llm)))
        (proofread--queue-request request 'llm)
        (cl-letf (((symbol-function 'proofread--submit-request)
                   (lambda (&rest _)
                     (error "Simulated submission failure"))))
          (should-error (proofread--dispatch-queued-requests)))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--queue-dispatch-active-p)
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-clear-rejects-work-enqueued-by-cancel-hook ()
  "Reject work enqueued by cancellation hooks during clearing."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          triggered
          new-request
          events)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request old-chunk 'llm))
             (old-log-id (plist-get old :log-id)))
        (proofread--queue-request old 'llm)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (push event events)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread--dispatch-request-ready-chunks
                     (list new-chunk) 'llm))
                   ((eq (plist-get event :reason) 'cleared)
                    (setq new-request (plist-get event
                                                 :request))))))))
          (proofread--clear-scheduled-work))
        (should triggered)
        (should new-request)
        (should (proofread--request-invalidated-p new-request))
        (should (proofread--request-state-flag-p new-request
                                                 :cancelled))
        (should-not
         (cl-find-if
          (lambda (event)
            (and (equal (plist-get event :log-id)
                        (plist-get new-request :log-id))
                 (eq (plist-get event :type) 'queued-request)))
          events))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should-not proofread--request-queue-tail)
        (should-not proofread--queue-dispatch-timer)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-request-cleanup-rejects-active-cancel-hook-work ()
  "Reject cancellation-hook work during active cleanup."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          triggered
          rejected)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request old-chunk 'llm))
             (old-log-id (plist-get old :log-id)))
        (setq old (plist-put old :handle 'old-handle))
        (proofread--register-active-request old)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread--dispatch-request-ready-chunks
                     (list new-chunk) 'llm))
                   ((eq (plist-get event :reason) 'cleared)
                    (setq rejected (plist-get event :request))))))))
          (proofread--clear-request-work))
        (should triggered)
        (should rejected)
        (should (proofread--request-invalidated-p rejected))
        (should (proofread--request-state-flag-p rejected :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-restored-edit-does-not-block-same-work-request ()
  "Resubmit restored work after invalidating an earlier request."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          backend-requests)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (lambda (request _callback &optional _backend)
                    (setq backend-requests
                          (append backend-requests (list request)))
                    (list :backend 'test
                          :request-id (plist-get request :id)))))
         (let* ((old-chunks
                 (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max)))))
                (old
                 (car (proofread--dispatch-request-ready-chunks
                       old-chunks 'llm))))
           (should old)
           (goto-char 2)
           (insert "x")
           (delete-region 2 3)
           (should (equal (buffer-string) "helo"))
           (should (proofread--request-invalidated-p old))
           (should-not (proofread--request-work-pending-p old))
           (let* ((new-chunks
                   (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
                  (new
                   (car (proofread--dispatch-request-ready-chunks
                         new-chunks 'llm))))
             (should new)
             (should (equal (proofread--request-work-key old)
                            (proofread--request-work-key new)))
             (should (= (length backend-requests) 2))
             (should-not (proofread--active-request-p old))
             (should (proofread--active-request-p new))
             (should (proofread--request-work-pending-p new)))))))))

(ert-deftest
    proofread-test-request-work-key-distinguishes-restrictions ()
  "Include accessible restrictions in request identity."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let* ((full-chunk
            (car (proofread--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (full-request
            (proofread--make-backend-request full-chunk 'llm))
           narrowed-request)
      (narrow-to-region 2 6)
      (setq narrowed-request
            (proofread--make-backend-request
             (car (proofread--request-ready-chunks-for-ranges
                   (list (cons (point-min) (point-max)))))
             'llm))
      (should-not (equal (proofread--request-work-key full-request)
                         (proofread--request-work-key
                          narrowed-request)))
      (should-not (proofread--fresh-request-p full-request))
      (should (proofread--fresh-request-p narrowed-request))
      (widen)
      (should (proofread--fresh-request-p full-request))
      (should-not (proofread--fresh-request-p narrowed-request)))))

(ert-deftest proofread-test-cache-hit-edit-invalidates-prepared-batch
    ()
  "Invalidate later batch work after synchronous cache-hit edits."
  (with-temp-buffer
    (insert "aaa aaa")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          calls)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (let* ((first
               (car (proofread--request-ready-chunks-for-ranges
                     '((1 . 4)))))
              (second
               (car (proofread--request-ready-chunks-for-ranges
                     '((5 . 8)))))
              (preview (proofread--make-backend-request first 'llm)))
         (should (equal (plist-get first :text) "aaa"))
         (should (equal (plist-get second :text) "aaa"))
         (proofread--cache-write-request preview nil)
         (add-hook
          'proofread-diagnostics-changed-hook
          (lambda ()
            (setq calls (1+ (or calls 0)))
            (when (= calls 1)
              (goto-char (point-min))
              (insert "aaa ")))
          nil t)
         (should-not
          (proofread--dispatch-request-ready-chunks
           (list first second) 'llm))
         (should (= calls 1))
         (should (equal (buffer-string) "aaa aaa aaa"))
         (should-not proofread--request-queue)
         (should (= (hash-table-count
                     proofread--pending-request-keys) 0)))))))

(ert-deftest
    proofread-test-full-queue-does-not-starve-later-cache-hit ()
  "Cached queued work runs even when earlier backend work is full."
  (with-temp-buffer
    (insert "aa bb cc")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          calls)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (let* ((active
               (proofread--make-backend-request
                (car (proofread--request-ready-chunks-for-ranges
                      '((1 . 3))))
                'llm))
              (waiting
               (proofread--make-backend-request
                (car (proofread--request-ready-chunks-for-ranges
                      '((4 . 6))))
                'llm))
              (cached
               (proofread--make-backend-request
                (car (proofread--request-ready-chunks-for-ranges
                      '((7 . 9))))
                'llm)))
         (proofread--register-active-request active)
         (proofread--queue-request waiting 'llm)
         (proofread--cache-write-request cached nil)
         (proofread--queue-request cached 'llm)
         (add-hook 'proofread-diagnostics-changed-hook
                   (lambda ()
                     (setq calls (1+ (or calls 0)))
                     (when (= calls 1)
                       (goto-char (point-min))
                       (insert "x")
                       (delete-char -1)))
                   nil t)
         (should-not (proofread--dispatch-queued-requests t))
         (should (= calls 1))
         (should-not proofread--request-queue)
         (should (proofread--request-invalidated-p waiting))
         (should-not (proofread--request-work-pending-p waiting))
         (should-not (proofread--request-work-pending-p cached)))))))

(ert-deftest
    proofread-test-conflicting-request-replaces-active-at-limit ()
  "Cancel conflicting active work before enforcing limits."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          backend-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (lambda (request _callback &optional _backend)
                    (setq backend-requests
                          (append backend-requests (list request)))
                    (list :backend 'test
                          :request-id (plist-get request :id))))
                 ((symbol-function 'proofread--cancel-request-handle)
                  (lambda (handle)
                    (push handle cancelled-handles))))
         (let* ((older-chunk
                 (car (proofread--request-ready-chunks-for-ranges
                       '((1 . 7)))))
                (newer-chunk
                 (car (proofread--request-ready-chunks-for-ranges
                       '((2 . 6)))))
                (older
                 (car (proofread--dispatch-request-ready-chunks
                       (list older-chunk) 'llm)))
                (newer
                 (car (proofread--dispatch-request-ready-chunks
                       (list newer-chunk) 'llm))))
           (should older)
           (should newer)
           (should (= (length backend-requests) 2))
           (should (= (length cancelled-handles) 1))
           (should (proofread--request-state-flag-p older
                                                    :superseded))
           (should-not (proofread--active-request-p older))
           (should (proofread--active-request-p newer))
           (should (equal (mapcar (lambda (request)
                                    (plist-get request :text))
                                  proofread--active-requests)
                          '("bcde")))
           (should-not proofread--request-queue)
           (should-not proofread--request-queue-tail)))))))

(ert-deftest
    proofread-test-superseding-cache-hit-drains-unrelated-queue ()
  "Drain unrelated work after a superseding cache hit."
  (with-temp-buffer
    (insert "abc def")
    (let ((proofread-auto-check nil)
          (proofread-backend 'llm)
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity
           proofread-test--llm-provider-identity)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          backend-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-llm-capabilities
       (cl-letf (((symbol-function 'proofread--backend-check)
                  (lambda (request _callback &optional _backend)
                    (setq backend-requests
                          (append backend-requests (list request)))
                    (list :backend 'test
                          :request-id (plist-get request :id))))
                 ((symbol-function 'proofread--cancel-request-handle)
                  (lambda (handle)
                    (push handle cancelled-handles))))
         (let* ((older-chunk
                 (car (proofread--request-ready-chunks-for-ranges
                       '((1 . 4)))))
                (cached-chunk
                 (car (proofread--request-ready-chunks-for-ranges
                       '((1 . 5)))))
                (unrelated-chunk
                 (car (proofread--request-ready-chunks-for-ranges
                       '((5 . 8)))))
                (cached-preview
                 (proofread--make-backend-request cached-chunk 'llm))
                (unrelated
                 (proofread--make-backend-request unrelated-chunk
                                                  'llm)))
           (proofread--cache-write-request cached-preview nil)
           (let ((older
                  (car (proofread--dispatch-request-ready-chunks
                        (list older-chunk) 'llm))))
             (should older)
             (proofread--queue-request unrelated 'llm)
             (should (= (length proofread--request-queue) 1))
             (should
              (equal
               (proofread--dispatch-request-ready-chunks
                (list cached-chunk) 'llm)
               (list unrelated)))
             (should (proofread--request-state-flag-p
                      older :superseded))
             (should (= (length cancelled-handles) 1))
             (should (equal (mapcar (lambda (request)
                                      (plist-get request :text))
                                    backend-requests)
                            '("abc" "def")))
             (should-not (proofread--active-request-p older))
             (should (proofread--active-request-p unrelated))
             (should-not proofread--request-queue)
             (should-not proofread--request-queue-tail))))))))

(ert-deftest proofread-test-synchronous-queued-callback-drains-once ()
  "Drain synchronous callbacks without duplicate submissions."
  (with-temp-buffer
    (insert "One. Two. Three.")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids)
      (proofread-mode 1)
      (let* ((chunks
              (proofread--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (requests
              (mapcar (lambda (chunk)
                        (proofread--make-backend-request chunk 'llm))
                      chunks))
             (expected-log-ids
              (mapcar (lambda (request)
                        (plist-get request :log-id))
                      requests)))
        (should (= (length requests) 3))
        (dolist (request requests)
          (proofread--queue-request request 'llm))
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request callback &optional _backend)
                     (push (plist-get request :log-id)
                           submitted-log-ids)
                     (funcall callback
                              (proofread--backend-success-result
                               request nil))
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
          (proofread--dispatch-queued-requests))
        (setq submitted-log-ids (nreverse submitted-log-ids))
        (should (equal submitted-log-ids expected-log-ids))
        (should (= (length (delete-dups (copy-sequence
                                         submitted-log-ids)))
                   (length requests)))
        (should-not proofread--active-requests)
        (should-not proofread--request-queue)
        (should-not proofread--request-queue-tail)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-adjacent-zero-width-diagnostic-keeps-owner ()
  "Keep boundary diagnostics until their owner is cleaned."
  (dolist (producer '(left right))
    (dolist (callback-order '((left right) (right left)))
      (with-temp-buffer
        (insert "abcdef")
        (let ((proofread-auto-check nil)
              (proofread-backend 'llm)
              (proofread-llm-provider proofread-test--llm-provider)
              (proofread-llm-provider-identity
               proofread-test--llm-provider-identity)
              (proofread-context-size 0)
              (proofread-cache-max-entries 0))
          (proofread-mode 1)
          (let* ((left-chunk
                  (car (proofread--request-ready-chunks-for-ranges
                        '((1 . 4)))))
                 (right-chunk
                  (car (proofread--request-ready-chunks-for-ranges
                        '((4 . 7)))))
                 (left-request
                  (proofread--make-backend-request left-chunk 'llm))
                 (right-request
                  (proofread--make-backend-request right-chunk 'llm))
                 (producer-request
                  (if (eq producer 'left)
                      left-request
                    right-request))
                 (boundary-diagnostic
                  (proofread--make-diagnostic
                   :beg 4 :end 4 :text "" :kind 'grammar
                   :message "Missing boundary punctuation"
                   :suggestions '(".") :source 'test))
                 (neighbor-diagnostic
                  (if (eq producer 'left)
                      (proofread-test--diagnostic-for-range 5 6 "e")
                    (proofread-test--diagnostic-for-range 2 3 "b"))))
            (dolist (side callback-order)
              (let ((request (if (eq side 'left)
                                 left-request
                               right-request))
                    (diagnostics
                     (if (eq side producer)
                         (list boundary-diagnostic)
                       (list neighbor-diagnostic))))
                (should
                 (eq (proofread--handle-backend-result
                      (proofread--backend-success-result
                       request diagnostics))
                     'applied))))
            (should (= (length proofread--diagnostics) 2))
            (let ((live-boundary
                   (cl-find boundary-diagnostic proofread--diagnostics
                            :test #'equal))
                  (live-neighbor
                   (cl-find neighbor-diagnostic proofread--diagnostics
                            :test #'equal)))
              (should live-boundary)
              (should live-neighbor)
              (should (proofread--overlay-for-diagnostic
                       live-boundary))
              (should (proofread--overlay-for-diagnostic
                       live-neighbor))
              (should
               (eq (proofread--handle-backend-result
                    (proofread--backend-success-result
                     producer-request nil))
                   'applied))
              (should-not (memq live-boundary proofread--diagnostics))
              (should-not (proofread--overlay-for-diagnostic
                           live-boundary))
              (should (equal proofread--diagnostics
                             (list neighbor-diagnostic)))
              (should (proofread--overlay-for-diagnostic
                       live-neighbor)))))))))

(provide 'proofread-tests)

;;; proofread-tests.el ends here
