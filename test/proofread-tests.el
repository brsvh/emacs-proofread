;;; proofread-tests.el --- Tests for proofread  -*- lexical-binding: t; -*-

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

(defun proofread-test--chunk-ranges (chunks)
  "Return the buffer ranges from CHUNKS."
  (mapcar (lambda (chunk)
            (cons (plist-get chunk :beg)
                  (plist-get chunk :end)))
          chunks))

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

(defconst proofread-test--llm-provider 'proofread-test-provider
  "Provider object used for local LLM backend tests.")

(defconst proofread-test--llm-provider-identity "proofread-test-provider"
  "Stable provider identity used for local LLM backend tests.")

(defun proofread-test--llm-capabilities (_provider)
  "Return LLM capabilities used by local backend tests."
  '(json-response))

(defmacro proofread-test--with-llm-capabilities (&rest body)
  "Run BODY with the local test provider advertising structured output."
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
                (lambda (_provider _prompt success _error &optional _multi-output)
                  (funcall success ,content)
                  'proofread-test-llm-handle))
               ((symbol-function 'llm-capabilities)
                #'proofread-test--llm-capabilities))
       ,@body)))

(defmacro proofread-test--with-llm-error (error message &rest body)
  "Run BODY with `llm-chat-async' configured to signal ERROR and MESSAGE."
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

(defmacro proofread-test--with-popup-recorder (&rest body)
  "Run BODY while recording proofread child frame calls."
  (declare (indent 0) (debug (body)))
  `(let (proofread-test--popup-shows
         proofread-test--popup-hides
         proofread-test--popup-deletes)
     (cl-letf (((symbol-function 'posframe-workable-p)
                (lambda ()
                  t))
               ((symbol-function 'posframe-show)
                (lambda (buffer-or-name &rest args)
                  (push (cons buffer-or-name args)
                        proofread-test--popup-shows)
                  'proofread-test-posframe))
               ((symbol-function 'posframe-hide)
                (lambda (buffer-or-name)
                  (push buffer-or-name proofread-test--popup-hides)))
               ((symbol-function 'posframe-delete)
                (lambda (buffer-or-name)
                  (push buffer-or-name proofread-test--popup-deletes))))
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
    ("suggestions" . ,(vconcat (or suggestions '("hello"))))
    ("confidence" . 0.9)))

(defun proofread-test--response-diagnostic-with-fields
    (beg end text fields)
  "Return a structured response diagnostic for BEG, END, and TEXT plus FIELDS."
  (append (cl-remove-if (lambda (field)
                          (assoc (car field) fields))
                        (proofread-test--response-diagnostic beg end text))
          fields))

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
  (dolist (face '(proofread-face proofread-current-face
                                 proofread-popup-face))
    (should (facep face))
    (let ((spec (face-default-spec face)))
      (should-not (proofread-test--tree-member-p :foreground spec))
      (should-not (proofread-test--tree-member-p :background spec))
      (should-not (proofread-test--tree-member-p :color spec))
      (should-not (proofread-test--tree-member-p 'flyspell-incorrect spec))
      (should-not (proofread-test--tree-member-p 'flymake-warning spec))
      (should-not (proofread-test--tree-member-p 'flymake-error spec))
      (should-not (proofread-test--tree-member-p 'flycheck-error spec)))))

(ert-deftest proofread-test-face-uses-warning-severity ()
  "Diagnostic text uses a theme-aware warning color."
  (let ((spec (face-default-spec 'proofread-face)))
    (should (proofread-test--tree-member-p 'warning spec))
    (should (proofread-test--tree-member-p :underline spec))))

(ert-deftest proofread-test-popup-faces-use-own-defaults ()
  "Proofread popup faces do not depend on external face definitions."
  (let ((spec (face-default-spec 'proofread-popup-face)))
    (should-not (proofread-test--tree-member-p 'eldoc-box-body spec))
    (should-not (proofread-test--tree-member-p 'eldoc-box-border spec)))
  (should (equal (face-default-spec 'proofread-popup-border-face)
                 '((((background dark)) :background "white")
                   (((background light)) :background "black")))))

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

(ert-deftest proofread-test-disable-mode-clears-untracked-overlays ()
  "Disabling `proofread-mode' deletes untracked proofread overlays."
  (with-temp-buffer
    (insert "hello world again")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (tracked-overlay (proofread--create-overlay diagnostic))
           (orphan-overlay (make-overlay 8 13))
           (foreign-overlay (make-overlay 8 13)))
      (overlay-put orphan-overlay 'category proofread--overlay-category)
      (overlay-put orphan-overlay 'face 'proofread-face)
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--overlays (list tracked-overlay))
      (narrow-to-region 1 6)
      (proofread-mode -1)
      (should-not (overlay-buffer tracked-overlay))
      (should-not (overlay-buffer orphan-overlay))
      (should (overlay-buffer foreign-overlay))
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

(ert-deftest proofread-test-check-commands-require-mode ()
  "Proofread check commands require `proofread-mode'."
  (with-temp-buffer
    (insert "Alpha")
    (should-error (proofread-check-visible) :type 'user-error)
    (should-error (proofread-check-buffer) :type 'user-error)
    (should-error (proofread-check-region (point-min) (point-max))
                  :type 'user-error)
    (goto-char (point-min))
    (should-error (proofread-check-point) :type 'user-error)
    (should-not proofread--pending-ranges)))

(ert-deftest proofread-test-check-buffer-dispatches-accessible-buffer ()
  "`proofread-check-buffer' checks only accessible text with current options."
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
           (cl-letf (((symbol-function 'proofread-backend-check)
                      (plist-get recorder :function)))
             (proofread-check-buffer)
             (let ((requests (funcall (plist-get recorder :requests))))
               (should (equal
                        (mapcar (lambda (request)
                                  (plist-get request :text))
                                requests)
                        '("Alpha b" "eta." "Gamma.")))
               (dolist (request requests)
                 (should (equal (plist-get request :language) "en"))))
             (should (equal proofread--pending-ranges
                            (list (cons before-min before-max))))
             (should-not proofread-auto-check)
             (should (eq (current-buffer) source))
             (should (equal (buffer-string) before-text))
             (should (= (buffer-chars-modified-tick) before-tick))
             (should (= (point) before-point))
             (should (= (mark) before-mark))
             (should (eq mark-active before-mark-active))
             (should (= (point-min) before-min))
             (should (= (point-max) before-max)))))))))

(ert-deftest proofread-test-check-region-normalizes-and-filters-selection ()
  "`proofread-check-region' normalizes bounds and filters ignored text."
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
           (cl-letf (((symbol-function 'proofread-backend-check)
                      (plist-get recorder :function)))
             (proofread-check-region end beg)
             (should (equal proofread--pending-ranges
                            (list (cons beg end))))
             (should
              (equal
               (mapcar (lambda (request)
                         (plist-get request :text))
                       (funcall (plist-get recorder :requests)))
               '("Alpha " " beta."))))))))))

(ert-deftest proofread-test-check-region-interactively-requires-active-region ()
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
      (should-not proofread--pending-ranges)
      (should-not proofread--requests))))

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
            (should-not proofread--pending-ranges)
            (should-not proofread--requests))
        (kill-buffer other)))))

(ert-deftest proofread-test-check-region-interactive-feedback-is-shown ()
  "Interactive region checking reports feedback with messages inhibited."
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
                   (push (apply #'format format-string args) messages))))
        (call-interactively #'proofread-check-region)
        (should
         (equal messages
                (list (concat "proofread: collected 1 selected range; "
                              "no available backend"))))))))

(ert-deftest proofread-test-check-point-dispatches-containing-chunk ()
  "`proofread-check-point' checks one chunk and sends surrounding context."
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
         (cl-letf (((symbol-function 'proofread-backend-check)
                    (plist-get recorder :function)))
           (proofread-check-point)
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
           (should (equal proofread--pending-ranges
                          (list (cons beg end))))
           (should (= (point) before-point))))))))

(ert-deftest proofread-test-check-point-range-boundaries ()
  "Point range selection handles sentence, whitespace, and buffer boundaries."
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

(ert-deftest proofread-test-check-point-rejects-ignored-text ()
  "`proofread-check-point' rejects text excluded by ignored properties."
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
        (should-error (proofread-check-point) :type 'user-error)
        (should-not proofread--pending-ranges)
        (should-not proofread--requests)))))

(ert-deftest proofread-test-progress-messages-inhibited-by-default ()
  "Routine progress messages are quiet by default."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (should proofread-inhibit-progress-messages)
      (proofread--progress-message "proofread: %s" "checking")
      (should-not messages))))

(ert-deftest proofread-test-progress-messages-can-be-enabled ()
  "Routine progress messages can be enabled explicitly."
  (let ((proofread-inhibit-progress-messages nil)
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args) messages))))
      (proofread--progress-message "proofread: %s" "checking")
      (should (equal messages '("proofread: checking"))))))

(ert-deftest proofread-test-check-visible-background-progress-is-inhibited ()
  "`proofread-check-visible' is quiet when called noninteractively."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-background-message*")))
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
                (proofread-check-visible)
                (should-not messages))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-check-visible-interactive-progress-is-shown ()
  "`proofread-check-visible' reports feedback when called interactively."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-interactive-message*")))
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
                (call-interactively #'proofread-check-visible)
                (should
                 (equal messages
                        '("proofread: collected 1 visible range; no available backend"))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-auto-check-defaults-enabled-and-is-buffer-local ()
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

(ert-deftest proofread-test-auto-check-disabled-does-not-schedule-edit-work ()
  "Editing does not schedule work when automatic checking is disabled."
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
        (should (equal proofread--request-queue '(manual-request)))))))

(ert-deftest proofread-test-auto-check-disabled-does-not-schedule-window-work ()
  "Window activity does not schedule work when automatic checking is disabled."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-auto-check-window*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let ((proofread--request-queue '(manual-request))
                  timer-count)
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (_seconds _repeat _function &rest _args)
                           (setq timer-count (1+ (or timer-count 0)))
                           'proofread-test-timer)))
                (proofread--window-scroll (selected-window) (point-min))
                (proofread--window-configuration-change)
                (should-not timer-count)
                (should-not proofread--pending-work)
                (should-not proofread--idle-timer)
                (should (equal proofread--request-queue
                               '(manual-request))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-auto-check-disabled-allows-manual-visible-check ()
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
                         (lambda (&optional _window _update) (point-max)))
                        ((symbol-function 'proofread-backend-available-p)
                         (lambda () t))
                        ((symbol-function
                          'proofread--request-ready-visible-chunks)
                         (lambda () '((:text "Alpha"))))
                        ((symbol-function
                          'proofread--dispatch-request-ready-chunks)
                         (lambda (chunks)
                           (setq dispatched chunks)
                           '(proofread-test-request))))
                (proofread-check-visible)
                (should (equal proofread--pending-ranges
                               (list (cons (point-min) (point-max)))))
                (should (equal dispatched '((:text "Alpha")))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-disabled-auto-check-stale-timer-does-not-check ()
  "A stale timer does not check after automatic checking is disabled."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d" timer-count))))
                ((symbol-function 'proofread-check-visible)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
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
    (let ((proofread-backend 'llm)
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

(ert-deftest proofread-test-window-configuration-change-marks-buffer ()
  "Window configuration changes mark proofread buffers pending."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-config*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (proofread-mode 1))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format "proofread-test-window-timer-%d"
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
  "Sentence chunking records exact boundaries and text."
  (with-temp-buffer
    (insert "First paragraph. Second line.\n\nIgnored")
    (let* ((paragraph-end (save-excursion
                            (goto-char (point-min))
                            (search-forward "\n\n")
                            (- (point) 2)))
           (proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) paragraph-end)))))
      (should (= (length chunks) 2))
      (should (equal (proofread-test--chunk-texts chunks)
                     '("First paragraph." "Second line.")))
      (should (= (plist-get (car chunks) :beg) (point-min)))
      (should (= (plist-get (car (last chunks)) :end) paragraph-end))
      (dolist (chunk chunks)
        (should (equal (plist-get chunk :text)
                       (buffer-substring-no-properties
                        (plist-get chunk :beg)
                        (plist-get chunk :end))))))))

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

(ert-deftest proofread-test-sentence-chunking-splits-chinese-paragraph ()
  "Chinese sentence punctuation splits a paragraph into sentence chunks."
  (with-temp-buffer
    (insert "第一句。第二句！第三句？")
    (let* ((proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--chunk-texts chunks)
                     '("第一句。" "第二句！" "第三句？")))
      (dolist (chunk chunks)
        (should (equal (plist-get chunk :text)
                       (buffer-substring-no-properties
                        (plist-get chunk :beg)
                        (plist-get chunk :end))))))))

(ert-deftest proofread-test-sentence-chunking-keeps-hard-wrapped-sentence ()
  "A single hard-wrap newline does not split a logical sentence."
  (with-temp-buffer
    (insert "第一句\n第二句")
    (let* ((proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--chunk-texts chunks)
                     '("第一句\n第二句")))
      (should (equal (proofread-test--chunk-ranges chunks)
                     (list (cons (point-min) (point-max))))))))

(ert-deftest proofread-test-sentence-chunking-splits-english-paragraph ()
  "English punctuation splits sentences without breaking common inline forms."
  (with-temp-buffer
    (insert "Dr. Smith measured 3.14. It rained. Visit example.com/path? Done!")
    (let* ((proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--chunk-texts chunks)
                     '("Dr. Smith measured 3.14."
                       "It rained."
                       "Visit example.com/path?"
                       "Done!"))))))

(ert-deftest proofread-test-sentence-chunking-keeps-closing-quote ()
  "Closing quotes and brackets stay with preceding sentence punctuation."
  (with-temp-buffer
    (insert "他说“第一句。”第二句。")
    (let* ((proofread-context-size 0)
           (chunks (proofread--chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--chunk-texts chunks)
                     '("他说“第一句。”" "第二句。"))))))

(ert-deftest proofread-test-sentence-chunking-preserves-metadata-and-context ()
  "Sentence chunks preserve exact text, metadata, and context."
  (with-temp-buffer
    (org-mode)
    (let ((proofread-language "zh")
          (proofread-context-size 3))
      (insert "前文。目标句。后文。")
      (let* ((tick (buffer-chars-modified-tick))
             (chunks (proofread--chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (cadr chunks)))
        (should (equal (plist-get chunk :text) "目标句。"))
        (should (equal (plist-get chunk :text)
                       (buffer-substring-no-properties
                        (plist-get chunk :beg)
                        (plist-get chunk :end))))
        (should (eq (plist-get chunk :major-mode) 'org-mode))
        (should (equal (plist-get chunk :language) "zh"))
        (should (= (plist-get chunk :modified-tick) tick))
        (should (equal (plist-get chunk :context-before) "前文。"))
        (should (equal (plist-get chunk :context-after) "后文。"))))))

(ert-deftest proofread-test-sentence-chunking-bounds-oversized-sentence ()
  "A single oversized sentence still splits into bounded chunks."
  (with-temp-buffer
    (insert "一二三四五六。")
    (let ((proofread-max-chunk-size 3)
          (proofread-context-size 0))
      (let ((chunks (proofread--chunks-for-ranges
                     (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--chunk-texts chunks)
                       '("一二三" "四五六" "。")))
        (should (equal (proofread-test--chunk-ranges chunks)
                       '((1 . 4) (4 . 7) (7 . 8))))
        (should (cl-every (lambda (chunk)
                            (<= (length (plist-get chunk :text))
                                proofread-max-chunk-size))
                          chunks))))))

(ert-deftest proofread-test-sentence-chunking-keeps-unpunctuated-paragraph ()
  "Unpunctuated paragraphs stay one logical sentence."
  (with-temp-buffer
    (insert "第一句 第二句")
    (let ((proofread-context-size 0))
      (let ((chunks (proofread--chunks-for-ranges
                     (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--chunk-texts chunks)
                       '("第一句 第二句")))
        (should (= (length chunks) 1))))))

(ert-deftest proofread-test-sentence-chunking-filtering-still-applies ()
  "Request-ready filtering still excludes ignored text after sentence splitting."
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

(ert-deftest proofread-test-sentence-chunking-preserves-buffer-and-state ()
  "Sentence-aware chunking preserves buffer and proofread state."
  (with-temp-buffer
    (insert (propertize "第一句。第二句。" 'face 'bold 'proofread-test t))
    (proofread-mode 1)
    (goto-char 3)
    (push-mark 5 t t)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick))
          (before-point (point))
          (before-mark (mark t)))
      (let ((chunks (proofread--chunks-for-ranges
                     (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--chunk-texts chunks)
                       '("第一句。" "第二句。")))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (= (point) before-point))
        (should (= (mark t) before-mark))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
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

(ert-deftest proofread-test-request-ready-context-default-sentences ()
  "Request-ready chunks use one complete sentence of context by default."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标句。")))
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
           (chunk (proofread-test--chunk-with-text chunks "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest proofread-test-request-ready-context-keeps-hard-wrap-sentence ()
  "Hard-wrapped prose newlines do not split logical context sentences."
  (with-temp-buffer
    (insert "前半句\n后半句。目标句。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before)
                     "前半句\n后半句。"))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest proofread-test-request-ready-context-ignores-visual-wrapping ()
  "Visual wrapping does not affect request-ready sentence context."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (range (list (cons (point-min) (point-max))))
           (plain (proofread--request-ready-chunks-for-ranges range)))
      (visual-line-mode 1)
      (let ((wrapped (proofread--request-ready-chunks-for-ranges range)))
        (should (equal (proofread-test--chunk-texts wrapped)
                       (proofread-test--chunk-texts plain)))
        (cl-mapc
         (lambda (left right)
           (should (equal (plist-get left :context-before)
                          (plist-get right :context-before)))
           (should (equal (plist-get left :context-after)
                          (plist-get right :context-after))))
         plain wrapped)))))

(ert-deftest proofread-test-request-ready-context-stops-at-blank-lines ()
  "Blank lines stop request-ready sentence context search."
  (with-temp-buffer
    (insert "前文。\n\n目标句。\n\n后文。")
    (let* ((proofread-language "zh")
           (proofread-context-size 300)
           (chunks (proofread--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest proofread-test-request-ready-context-stops-at-org-structure ()
  "Org structural lines stop request-ready sentence context search."
  (dolist (text '("前文。\n* 标题\n目标句。"
                  "前文。\n#+TITLE: 标题\n目标句。"
                  "前文。\n:PROPERTIES:\n:CUSTOM_ID: x\n:END:\n目标句。"
                  "前文。\n- 项目\n目标句。"
                  "前文。\n| 表格 |\n目标句。"
                  "前文。\n#+begin_quote\n引用。\n#+end_quote\n目标句。"))
    (with-temp-buffer
      (org-mode)
      (insert text)
      (let* ((proofread-language "zh")
             (proofread-context-size 300)
             (chunks (proofread--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (proofread-test--chunk-with-text chunks "目标句。")))
        (should chunk)
        (should (equal (plist-get chunk :context-before) ""))))))

(ert-deftest proofread-test-request-ready-context-filters-ignored-text ()
  "Sentence context excludes ignored URL, email, invisible, face, and property."
  (with-temp-buffer
    (insert "访问 http://example.com，联系 user@example.com，保留 HIDDEN SKIP DROP。目标句。")
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
             (chunk (proofread-test--chunk-with-text chunks "目标句。"))
             (context (plist-get chunk :context-before)))
        (should chunk)
        (should-not (string-match-p "http://example.com" context))
        (should-not (string-match-p "user@example.com" context))
        (should-not (string-match-p "HIDDEN" context))
        (should-not (string-match-p "SKIP" context))
        (should-not (string-match-p "DROP" context))
        (should (string-match-p "访问" context))))))

(ert-deftest proofread-test-request-ready-context-oversized-fallback ()
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
          (proofread-prompt-version "prompt-a")
          (proofread-llm-provider proofread-test--llm-provider)
          (proofread-llm-provider-identity "provider-a")
          (proofread-cache-configuration-version 1))
      (insert "Alpha")
      (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                          (list (cons (point-min) (point-max))))))
             (base-key (proofread--cache-key chunk 'llm)))
        (let ((proofread-llm-provider-identity "provider-b"))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'llm))))
        (let ((proofread-prompt-version "prompt-b"))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'llm))))
        (let ((proofread-cache-configuration-version 2))
          (should-not (equal base-key
                             (proofread--cache-key chunk 'llm))))
        (let ((changed-language (copy-sequence chunk)))
          (setq changed-language
                (plist-put changed-language :language "fr"))
          (should-not (equal base-key
                             (proofread--cache-key changed-language 'llm))))
        (let ((changed-mode (copy-sequence chunk)))
          (setq changed-mode
                (plist-put changed-mode :major-mode 'org-mode))
          (should-not (equal base-key
                             (proofread--cache-key changed-mode 'llm))))
        (let ((changed-text (copy-sequence chunk)))
          (setq changed-text
                (plist-put changed-text :text "Beta"))
          (should-not (equal base-key
                             (proofread--cache-key changed-text 'llm))))))))

(ert-deftest proofread-test-cache-key-varies-by-context ()
  "Cache keys distinguish context strategy, configuration, and content."
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
      (should-not (equal base-key (proofread--cache-key changed 'llm))))))

(ert-deftest proofread-test-cache-key-context-excludes-volatile-values ()
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
      (should-not (proofread-test--tree-member-p (current-buffer) key))
      (should-not (proofread-test--tree-member-p proofread-llm-provider key))
      (should-not (proofread-test--tree-member-p "secret-token" key)))))

(ert-deftest proofread-test-cache-read-misses-old-context-strategy-key ()
  "Cache entries without context identity miss current request keys."
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
             "目标"))
           (old-key (list :text-hash
                          (proofread--chunk-text-hash
                           (plist-get request :text))
                          :language (plist-get request :language)
                          :major-mode (plist-get request :major-mode)
                          :backend (plist-get request :backend)
                          :prompt-version proofread-prompt-version
                          :configuration-version
                          proofread-cache-configuration-version)))
      (proofread--cache-write old-key
                              (proofread--make-cache-entry
                               request (list diagnostic)))
      (should-not (proofread--cache-read-request request)))))

(ert-deftest proofread-test-llm-backend-identity-is-cache-compatible ()
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
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (should (equal (proofread--backend-identity)
                     `(:backend llm
                                :provider ,proofread-test--llm-provider-identity
                                :response-strategy prompt-json
                                :diagnostic-passes 3
                                :prompt-version ,proofread-prompt-version)))
      (should (proofread--backend-identity-p (plist-get request :backend)))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request request)))))

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
  "Cached diagnostics convert ranges and locators between coordinate systems."
  (let* ((request '(:beg 10 :end 20 :text "0123456789" :backend llm))
         (diagnostic
          (plist-put (proofread-test--diagnostic-for-range 12 15 "234")
                     :locator
                     '(:kind char-range :beg 12 :end 15)))
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
    (should (equal (plist-get relative :locator)
                   '(:kind char-range :beg 2 :end 5)))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
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
                   (proofread-check-visible)
                   (should (= backend-calls 1))
                   (should (equal proofread--diagnostics
                                  (list diagnostic)))
                   (should (= (length proofread--overlays) 1))
                   (proofread-clear)
                   (setq proofread--diagnostics nil)
                   (proofread-check-visible)
                   (should (= backend-calls 1))
                   (should (equal proofread--diagnostics
                                  (list diagnostic)))
                   (should (= (length proofread--overlays) 1)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-backend-result-replaces-request-range-diagnostics ()
  "Repeated results for the same request range do not duplicate diagnostics."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let* ((request
            (list :buffer (current-buffer)
                  :beg (point-min)
                  :end (point-max)
                  :text (buffer-string)
                  :modified-tick (buffer-chars-modified-tick)
                  :backend 'llm))
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
                   (proofread-llm-provider proofread-test--llm-provider)
                   (proofread-llm-provider-identity
                    proofread-test--llm-provider-identity)
                   (recorder (proofread-test--make-backend-recorder)))
              (proofread-test--with-llm-capabilities
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
                                "helo"))))))
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
            (let* ((proofread-backend 'llm)
                   (proofread-llm-provider proofread-test--llm-provider)
                   (proofread-llm-provider-identity
                    proofread-test--llm-provider-identity)
                   (proofread-llm-response-strategy 'prompt-json)
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
                    (plist-put cached-request :backend 'llm))
              (proofread--cache-write-request
               cached-request (list cached-diagnostic))
              (proofread-test--with-llm-capabilities
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
                 (should (= (length proofread--overlays) 1))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-cache-invalidation-misses ()
  "Backend, prompt, configuration, and text changes miss old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider proofread-test--llm-provider)
           (proofread-llm-provider-identity "provider-a")
           (proofread-prompt-version "prompt-a")
           (proofread-cache-configuration-version 1)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (let ((proofread-llm-provider-identity "provider-b"))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk))))
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
      (setq request (plist-put request :backend 'llm))
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
        (setq fresh-request (plist-put fresh-request :backend 'llm))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-error-result
                      fresh-request 'llm-failure "LLM failure"))
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
      (setq request (plist-put request :backend 'llm))
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
  "Backend availability is limited to a configured LLM backend."
  (proofread-test--with-llm-capabilities
   (let ((proofread-backend 'llm)
         (proofread-llm-provider proofread-test--llm-provider))
     (should (proofread-backend-available-p))
     (should (proofread-backend-available-p 'llm))
     (should-not (proofread-backend-available-p 'unknown-backend)))))

(ert-deftest proofread-test-unknown-backend-is-unavailable-and-unsupported ()
  "Unknown backend symbols are unavailable and use unsupported dispatch."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-backend 'unknown-backend)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'unknown-backend))
           result)
      (should-not (proofread-backend-available-p))
      (should-not (proofread-backend-available-p 'unknown-backend))
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

(ert-deftest proofread-test-llm-backend-availability ()
  "LLM availability depends on provider and selected response strategy."
  (let ((proofread-backend 'llm)
        (proofread-llm-provider nil))
    (should-not (proofread-backend-available-p))
    (should-not (proofread-backend-available-p 'llm)))
  (let ((proofread-backend 'llm)
        (proofread-llm-provider 'proofread-test-provider))
    (should (proofread-backend-available-p))
    (should (proofread-backend-available-p 'llm)))
  (let ((proofread-backend 'llm)
        (proofread-llm-provider 'proofread-test-provider)
        (proofread-llm-response-strategy 'provider-json))
    (should-not (proofread-backend-available-p))
    (should-not (proofread-backend-available-p 'llm)))
  (proofread-test--with-llm-capabilities
   (let ((proofread-backend 'llm)
         (proofread-llm-provider proofread-test--llm-provider))
     (should (proofread-backend-available-p))
     (should (proofread-backend-available-p 'llm)))))

(ert-deftest proofread-test-llm-provider-unavailable-is-asynchronous-error ()
  "Missing LLM provider reports an asynchronous backend error."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider nil)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (should (proofread-backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'llm))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :error)
                  'llm-provider-unavailable)))))

(ert-deftest proofread-test-llm-structured-output-unavailable-is-asynchronous-error ()
  "Forced provider JSON reports an error when schema output is unavailable."
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
        (should (proofread-backend-check
                 request
                 (lambda (backend-result)
                   (setq result backend-result))
                 'llm))
        (should-not result)
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error)
                    'llm-structured-output-unavailable))))))

(ert-deftest proofread-test-deepseek-v4-flash-uses-prompt-json-fallback ()
  "DeepSeek v4 flash uses prompt-only JSON when schema output is absent."
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
        (should (proofread-backend-check
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
          (should (string-match-p "no Markdown code fence" prompt-text))
          (should (string-match-p "Text:\nhelo" prompt-text)))))))

(ert-deftest proofread-test-llm-provider-identity-is-stable ()
  "LLM identity uses stable provider metadata, not provider objects."
  (let ((proofread-backend 'llm)
        (proofread-llm-provider
         [:proofread-test-provider :api-key "secret-token"])
        (proofread-llm-provider-identity nil)
        (proofread-prompt-version "prompt-a"))
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
        (should (equal (plist-get identity :prompt-version) "prompt-a"))
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
  "Changing LLM provider objects misses cache without exposing the object."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider [:provider-a :api-key "secret-token"])
           (proofread-llm-provider-identity nil)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request
               (proofread--make-backend-request chunk)))
      (let ((proofread-llm-provider [:provider-b :api-key "secret-token"]))
        (let ((key (proofread--cache-key
                    (proofread--make-backend-request chunk))))
          (should-not (proofread-test--tree-member-p
                       proofread-llm-provider key))
          (should-not (proofread-test--tree-member-p
                       "secret-token" key)))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk)))))))

(ert-deftest proofread-test-llm-dispatch-builds-schema-prompt-asynchronously ()
  "LLM backend dispatches an async schema prompt built from request fields."
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
               (proofread-backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm)))
          (should (equal (plist-get handle :requests)
                         '(proofread-test-llm-handle)))
          (should (eq captured-provider proofread-llm-provider))
          (should-not captured-multi-output)
          (should (equal (llm-chat-prompt-response-format captured-prompt)
                         proofread--structured-response-schema))
          (let* ((interaction
                  (car (llm-chat-prompt-interactions captured-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "requested response schema"
                                    prompt-text))
            (should (string-match-p "Language: \"en\"" prompt-text))
            (should (string-match-p "Major mode: text-mode" prompt-text))
            (should (string-match-p "Text:\nhelo" prompt-text)))
          (should-not result)
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok))
          (should (eq (plist-get
                       (car (plist-get result :diagnostics))
                       :source)
                      'llm)))))))

(ert-deftest proofread-test-llm-prompt-uses-character-ranges ()
  "LLM prompts use character ranges without token locator hints."
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
          (proofread-backend-check request #'ignore 'llm)
          (let* ((interaction
                  (car (llm-chat-prompt-interactions captured-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "Text:\n青晨六点。" prompt-text))
            (should (string-match-p "range end is exclusive"
                                    prompt-text))
            (should-not (string-match-p "Tokens:" prompt-text))
            (should-not (string-match-p "token_index" prompt-text))
            (should-not (string-match-p "token_range" prompt-text))))))))

(ert-deftest proofread-test-llm-success-enters-overlay-pipeline ()
  "Fresh LLM diagnostics use the existing result, cache, and overlay path."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success content)))
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
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
        (should-not proofread--requests)
        (should (= (length proofread--diagnostics) 1))
        (should (= (length proofread--overlays) 1))
        (should (= (hash-table-count proofread--cache) 1))))))

(ert-deftest proofread-test-llm-collects-additional-diagnostic-passes ()
  "LLM backend can collect additional diagnostics in later passes."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
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
                   (intern (format "proofread-test-handle-%d" calls))))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (let ((handle (proofread-backend-check
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
            (should (string-match-p "Return only additional diagnostics"
                                    prompt-text)))
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok))
          (should (equal (mapcar (lambda (diagnostic)
                                   (plist-get diagnostic :text))
                                 (plist-get result :diagnostics))
                         '("helo" "wrld"))))))))

(ert-deftest proofread-test-llm-error-preserves-buffer-and-clears-request ()
  "LLM error callbacks preserve text and clear active request state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (before-text (buffer-string))
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt _success error
                                    &optional _multi-output)
                   (funcall error 'llm-error "boom")
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (should (proofread--dispatch-backend-request
                 request
                 (lambda (backend-result)
                   (setq result backend-result))
                 'llm))
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error) 'llm-error))
        (should (equal (buffer-string) before-text))
        (should-not proofread--requests)
        (should-not proofread--overlays)))))

(ert-deftest proofread-test-llm-invalid-success-response-is-error ()
  "Unparsable LLM success responses create no overlays and become errors."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (funcall success "not json")
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
        (should (proofread--dispatch-backend-request
                 request
                 (lambda (backend-result)
                   (setq result backend-result)
                   (proofread--handle-backend-result backend-result))
                 'llm))
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error) 'llm-invalid-response))
        (should-not proofread--requests)
        (should-not proofread--overlays)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-llm-stale-results-are-dropped ()
  "LLM results are stale after buffer, mode, tick, or text changes."
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
              (let* ((proofread-llm-provider 'proofread-test-provider)
                     (proofread-llm-max-diagnostic-passes 1)
                     (chunk (car (proofread--request-ready-chunks-for-ranges
                                  (list (cons (point-min)
                                              (point-max)))))))
                (setq request (proofread--make-backend-request chunk 'llm))
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
                 (insert "halo")
                 (plist-put request
                            :modified-tick
                            (buffer-chars-modified-tick)))))
            (funcall
             success
             (proofread-test--response-content
              (list (proofread-test--response-diagnostic 0 4 "helo"))))
            (should (proofread-test--wait-for (lambda () result)))
            (should (eq result 'stale))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (should-not proofread--diagnostics)
                (should-not proofread--overlays))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest proofread-test-structured-response-prompt-requests-contract ()
  "Diagnostic prompts describe schema output with chunk-relative ranges."
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
      (should (string-match-p "zero-based chunk-relative offsets" prompt))
      (should (string-match-p "range end is exclusive" prompt))
      (dolist (field '("kind" "message" "text" "range"
                       "suggestions" "confidence"))
        (should (string-match-p field prompt)))
      (should-not (string-match-p "source" prompt))
      (should-not (string-match-p "token_index" prompt))
      (should-not (string-match-p "token_range" prompt))
      (should (string-match-p "Language: \"en\"" prompt))
      (should (string-match-p "Major mode: text-mode" prompt))
      (should (string-match-p "Text:\nhelo" prompt))
      (should-not (string-match-p "absolute buffer" prompt)))))

(ert-deftest proofread-test-structured-response-prompt-has-no-token-contract ()
  "Structured response prompts do not expose token locator details."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (prompt (proofread--structured-response-prompt request)))
      (should-not (string-match-p "Tokens:" prompt))
      (should-not (string-match-p "When you can localize" prompt))
      (should-not (string-match-p "token_index" prompt))
      (should-not (string-match-p "token_range" prompt)))))

(ert-deftest proofread-test-structured-response-schema-encodes-json-false ()
  "Structured response schema encodes false as a JSON boolean."
  (let ((schema (proofread--structured-response-schema-text)))
    (should (string-match-p "\"additionalProperties\":false" schema))
    (should-not (string-match-p "\"source\"" schema))
    (should-not (string-match-p "\"token_index\"" schema))
    (should-not (string-match-p "\"token_range\"" schema))
    (should-not
     (string-match-p "\"additionalProperties\":\"false\"" schema))))

(ert-deftest proofread-test-structured-response-extra-text-around-payload-is-error ()
  "Structured response parser rejects extra text around a payload."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (concat "Result follows:\n"
                    (proofread-test--response-content
                     (list (proofread-test--response-diagnostic 0 4 "helo")))
                    "\nDone.")))
      (should-error
       (proofread--diagnostics-from-structured-response
        request content 'llm)))))

(ert-deftest proofread-test-structured-response-ambiguous-extra-json-is-error ()
  "Structured response parser rejects multiple payloads."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (payload
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo")))))
      (should-error
       (proofread--diagnostics-from-structured-response
        request (concat payload "\n" payload) 'llm)))))

(ert-deftest proofread-test-structured-response-non-json-content-is-error ()
  "Non-schema structured response text is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "I found a spelling issue." 'llm)))))

(ert-deftest proofread-test-structured-response-malformed-json-is-error ()
  "Malformed structured response JSON is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread--diagnostics-from-structured-response
        request "Before {\"diagnostics\":[} after" 'llm)))))

(ert-deftest proofread-test-structured-response-direct-payload ()
  "Structured response payloads can be consumed directly."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (payload
            '(:diagnostics
              ((:kind "spelling"
                      :message "Possible misspelling"
                      :text "helo"
                      :range (:beg 0 :end 4)
                      :suggestions ["hello"]
                      :confidence nil))))
           (diagnostics
            (proofread--diagnostics-from-structured-response
             request payload 'llm)))
      (should (= (length diagnostics) 1))
      (should (equal (plist-get (car diagnostics) :text) "helo"))
      (should (equal (plist-get (car diagnostics) :suggestions)
                     '("hello")))
      (should (eq (plist-get (car diagnostics) :source) 'llm))
      (should (equal (plist-get (car diagnostics) :locator)
                     '(:kind char-range :beg 1 :end 5))))))

(ert-deftest proofread-test-structured-response-uses-char-range-locator ()
  "Structured response diagnostics use internal character range locators."
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
      (should (equal (plist-get diagnostic :locator)
                     '(:kind char-range :beg 6 :end 8))))))

(ert-deftest proofread-test-structured-response-preserves-multiple-diagnostics ()
  "Structured response keeps multiple diagnostics from one request."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list
              (proofread-test--response-diagnostic 0 4 "helo" '("hello"))
              (proofread-test--response-diagnostic 5 9 "wrld" '("world")))))
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

(ert-deftest proofread-test-structured-response-unmatched-text-is-dropped ()
  "Structured response diagnostics whose text is outside the request are dropped."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 99 "world"))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (should-not diagnostics))))

(ert-deftest proofread-test-structured-response-repairs-mismatched-range ()
  "Structured response diagnostics recover from wrong ranges using exact text."
  (with-temp-buffer
    (insert "青晨六点半，小城的街到刚刚醒来。")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list
              (proofread-test--response-diagnostic 0 2 "青晨" '("清晨"))
              (proofread-test--response-diagnostic 7 9 "街到" '("街道")))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (should (= (length diagnostics) 2))
      (should (equal (mapcar (lambda (diagnostic)
                               (plist-get diagnostic :text))
                             diagnostics)
                     '("青晨" "街到")))
      (should (equal (mapcar (lambda (diagnostic)
                               (cons (plist-get diagnostic :beg)
                                     (plist-get diagnostic :end)))
                             diagnostics)
                     '((1 . 3) (10 . 12)))))))

(ert-deftest proofread-test-structured-response-text-mismatch-is-dropped ()
  "Structured response diagnostics whose text does not match the range are dropped."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "hola"))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (should-not diagnostics))))

(ert-deftest proofread-test-structured-response-invalid-candidate-preserves-valid ()
  "One invalid structured response diagnostic does not discard valid diagnostics."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list
              (proofread-test--response-diagnostic 0 99 "hola")
              (proofread-test--response-diagnostic-with-fields
               0 4 "helo" '(("kind" . "typo")))
              (proofread-test--response-diagnostic 5 9 "wrld" '("world")))))
           (diagnostics
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (should (= (length diagnostics) 1))
      (should (equal (plist-get (car diagnostics) :text) "wrld")))))

(ert-deftest proofread-test-structured-response-suggestions-preserve-order ()
  "Structured response suggestions keep string order and ignore non-strings."
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
              ("suggestions" . ["hello" 42 "hullo" nil "help"])
              ("confidence" . 0.9)))
           (content (proofread-test--response-content
                     (list candidate)))
           (diagnostic
            (car (proofread--diagnostics-from-structured-response
                  request content 'llm))))
      (should (equal (plist-get diagnostic :suggestions)
                     '("hello" "hullo" "help"))))))

(ert-deftest proofread-test-structured-response-optional-fields-conservative ()
  "Structured response optional confidence fields are validated."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (valid-optional
            '(("kind" . "spelling")
              ("message" . "Possible misspelling")
              ("text" . "helo")
              ("range" . (("beg" . 0)
                          ("end" . 4)))
              ("suggestions" . ["hello"])
              ("confidence" . 0.75)
              ("source" . "provider")))
           (invalid-optional
            '(("kind" . "spelling")
              ("message" . "Possible misspelling")
              ("text" . "wrld")
              ("range" . (("beg" . 5)
                          ("end" . 9)))
              ("suggestions" . ["world"])
              ("confidence" . 3)
              ("source" . 42)))
           (content
            (proofread-test--response-content
             (list valid-optional invalid-optional)))
           (diagnostics
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (should (= (length diagnostics) 2))
      (should (= (plist-get (car diagnostics) :confidence) 0.75))
      (should (eq (plist-get (car diagnostics) :source) 'llm))
      (should-not (plist-get (cadr diagnostics) :confidence))
      (should (eq (plist-get (cadr diagnostics) :source) 'llm)))))

(ert-deftest proofread-test-structured-response-cross-boundary-range ()
  "Character ranges can describe diagnostics across word-like boundaries."
  (let* ((request '(:beg 1
                         :end 15
                         :text "小城的街到刚刚醒来。"))
         (content
          (proofread-test--response-content
           (list
            (proofread-test--response-diagnostic 3 5 "街到" '("街道")))))
         (diagnostic
          (car (proofread--diagnostics-from-structured-response
                request content 'llm))))
    (should diagnostic)
    (should (= (plist-get diagnostic :beg) 4))
    (should (= (plist-get diagnostic :end) 6))
    (should (equal (plist-get diagnostic :locator)
                   '(:kind char-range :beg 4 :end 6)))))

(ert-deftest proofread-test-structured-response-without-range-and-text-is-rejected ()
  "Diagnostics without authoritative range and text are rejected."
  (let* ((request '(:beg 1 :end 5 :text "青晨六点"))
         (content
          (proofread-test--response-content
           (list '(("kind" . "spelling")
                   ("message" . "Possible misspelling")
                   ("suggestions" . ["清晨"]))))))
    (should-not (proofread--diagnostics-from-structured-response request content 'llm))))

(ert-deftest proofread-test-structured-response-parsed-results-still-stale-check ()
  "Parsed structured response diagnostics still require stale validation."
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
            (proofread--diagnostics-from-structured-response request content 'llm)))
      (goto-char (point-max))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request diagnostics))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays)
      (should (equal (buffer-string) "helo!")))))

(ert-deftest proofread-test-structured-response-prompt-version-cache-miss ()
  "Structured response cache entries miss when prompt version changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-backend 'llm)
           (proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-provider-identity "provider")
           (proofread-prompt-version "schema-v1")
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo")))
      (proofread--cache-write-request request (list diagnostic))
      (should (proofread--cache-read-request
               (proofread--make-backend-request chunk)))
      (let ((proofread-prompt-version "schema-v2"))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request chunk)))))))

(ert-deftest proofread-test-structured-response-strategy-cache-miss ()
  "Structured response cache entries miss when LLM response strategy changes."
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
                        (proofread--make-backend-request chunk)))))))))

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
      (should-not (string-match-p "secret-token" (prin1-to-string key)))
      (should-not (string-match-p (buffer-name) (prin1-to-string key))))))

(ert-deftest proofread-test-structured-response-stale-result-is-dropped ()
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
            (proofread--diagnostics-from-structured-response request content 'llm)))
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
       (should (proofread-backend-check
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
                                    (let* ((chunk (car (proofread--request-ready-chunks-for-ranges
                                                        (list (cons (point-min) (point-max))))))
                                           (request (proofread--make-backend-request chunk))
                                           result)
                                      (should (proofread-backend-check
                                               request
                                               (lambda (backend-result)
                                                 (setq result backend-result))
                                               'llm))
                                      (should-not result)
                                      (should (proofread-test--wait-for (lambda () result)))
                                      (should (eq (plist-get result :status) 'error))
                                      (should (eq (plist-get result :request) request))
                                      (should (eq (plist-get result :error) 'llm-failure))
                                      (should (equal (plist-get result :message) "LLM failure"))))))

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
                    (setq active-at-callback proofread--requests)))
                'llm))
       (should (proofread--active-request-p request))
       (should (proofread-test--wait-for (lambda () result)))
       (should (eq (plist-get result :status) 'ok))
       (should-not active-at-callback)
       (should-not (proofread--active-request-p request))))))

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
      (proofread-test--with-llm-error 'llm-failure "LLM failure"
                                      (should (proofread--dispatch-backend-request
                                               request
                                               (lambda (backend-result)
                                                 (setq result backend-result)
                                                 (with-current-buffer buffer
                                                   (setq active-at-callback proofread--requests)))
                                               'llm))
                                      (should (proofread--active-request-p request))
                                      (should (proofread-test--wait-for (lambda () result)))
                                      (should (eq (plist-get result :status) 'error))
                                      (should (equal (buffer-string) before-text))
                                      (should-not active-at-callback)
                                      (should-not (proofread--active-request-p request))))))

(ert-deftest proofread-test-check-visible-dispatches-request-ready-chunks ()
  "`proofread-check-visible' dispatches filtered visible chunks."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-dispatch*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  requests
                  callbacks)
              (proofread-test--with-llm-capabilities
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
                 (should-not proofread--overlays)))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-check-visible-dispatches-sentence-chunks ()
  "`proofread-check-visible' dispatches sentence-level visible chunks."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-sentences*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert (concat "青晨六点半，小城的街到刚刚醒来。"
                            "卖豆浆的滩主把炉子推到巷口。"
                            "几个上班的人撑着伞从桥边经过。"))
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
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
                          (lambda (&optional _window _update) (point-max)))
                         ((symbol-function 'proofread-backend-check)
                          (lambda (request callback &optional _backend)
                            (push request requests)
                            (push callback callbacks)
                            'proofread-test-handle)))
                 (proofread-check-visible)
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
                 (should (= (length proofread--requests) 3))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-max-concurrent-requests-queues-extra-work ()
  "`proofread-max-concurrent-requests' limits active backend requests."
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
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 2)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name buffer)))
              (proofread-test--with-llm-capabilities
               (cl-letf (((symbol-function 'window-start)
                          (lambda (&optional _window) (point-min)))
                         ((symbol-function 'window-end)
                          (lambda (&optional _window _update) (point-max)))
                         ((symbol-function 'proofread-backend-check)
                          (plist-get recorder :function)))
                 (proofread-show-buffer-requests buffer)
                 (proofread-check-visible)
                 (should (= (length (funcall
                                     (plist-get recorder :requests)))
                            2))
                 (should (= (length proofread--requests) 2))
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
                 (let* ((requests (funcall (plist-get recorder :requests)))
                        (callbacks (funcall (plist-get recorder :callbacks)))
                        (first-request (car requests))
                        (second-request (cadr requests))
                        (first-callback (car callbacks)))
                   (should (eq (funcall
                                first-callback
                                (proofread--backend-success-result
                                 first-request nil))
                               'applied))
                   (let* ((all-requests (funcall
                                         (plist-get recorder :requests)))
                          (third-request (caddr all-requests))
                          (active-ids
                           (mapcar (lambda (request)
                                     (plist-get request :id))
                                   proofread--requests)))
                     (should (= (length all-requests) 3))
                     (should (= (length proofread--requests) 2))
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
                     (should-not (member (plist-get first-request :id)
                                         active-ids))
                     (should (member (plist-get second-request :id)
                                     active-ids))
                     (should (member (plist-get third-request :id)
                                     active-ids))))))))
        (when-let* ((list-buffer (get-buffer
                                  (proofread--request-log-list-buffer-name
                                   buffer))))
          (kill-buffer list-buffer))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-active-requests-remain-buffer-local ()
  "Active request state is isolated between buffers."
  (let ((first-buffer (generate-new-buffer " *proofread-requests-a*"))
        (second-buffer (generate-new-buffer " *proofread-requests-b*")))
    (unwind-protect
        (let ((proofread-backend 'llm)
              (proofread-llm-provider proofread-test--llm-provider)
              (proofread-llm-provider-identity
               proofread-test--llm-provider-identity))
          (proofread-test--with-llm-capabilities
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
                           second-buffer))))))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
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
                   (should-not (proofread--active-request-p request)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-context-does-not-shift-diagnostic-overlays ()
  "Sentence-window context does not shift accepted diagnostic overlays."
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
        (should (= (overlay-start overlay) (plist-get diagnostic :beg)))
        (should (= (overlay-end overlay) (plist-get diagnostic :end)))))))

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
                   ((symbol-function 'proofread-backend-check)
                    (lambda (backend-request backend-callback
                                             &optional _backend)
                      (setq request backend-request)
                      (setq callback backend-callback)
                      'proofread-test-handle)))
           (proofread-check-visible))))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
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
                 (should-not proofread--requests)))))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
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
                 (should-not (proofread--active-request-p request))))))
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
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  request
                  callback)
              (proofread-test--with-llm-capabilities
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
                 (should-not (proofread--active-request-p request))))))
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
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (before-text (buffer-string))
                  request
                  callback)
              (proofread-test--with-llm-capabilities
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
                               request 'llm-failure "LLM failure"))
                             'error))
                 (should (equal (buffer-string) before-text))
                 (should-not proofread--diagnostics)
                 (should-not proofread--overlays)
                 (should-not (proofread--active-request-p request))))))
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

(ert-deftest proofread-test-show-buffer-diagnostics-lists-current-buffer ()
  "`proofread-show-buffer-diagnostics' lists diagnostics for the source buffer."
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
               :confidence 0.9
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
              (proofread-test--install-diagnostics (list second first))
              (goto-char 2)
              (proofread-show-buffer-diagnostics)
              (should (= (point) 2))
              (with-current-buffer name
                (should (eq major-mode 'proofread-diagnostics-buffer-mode))
                (should (eq proofread--diagnostics-buffer-source source))
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

(ert-deftest proofread-test-show-buffer-diagnostics-selects-diagnostic ()
  "`proofread-show-buffer-diagnostics' highlights the requested diagnostic."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (proofread-mode 1)
      (let* ((first (proofread-test--diagnostic-for-range 4 8 "helo"))
             (second (proofread-test--diagnostic-for-range 12 15 "teh"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list first second))
              (cl-letf (((symbol-function 'pulse-momentary-highlight-one-line)
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
                (cl-letf (((symbol-function 'pulse-momentary-highlight-region)
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
    (should-error (proofread-show-buffer-diagnostics) :type 'user-error)))

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

(ert-deftest proofread-test-popup-shows-message-above-diagnostic-start ()
  "The proofread child frame uses the diagnostic message and range start."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
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
         (proofread--popup-update)
         (should (= (length proofread-test--popup-shows) 1))
         (let* ((call (car proofread-test--popup-shows))
                (args (cdr call))
                (string (plist-get args :string)))
           (should (string-prefix-p proofread--popup-buffer-prefix
                                    (car call)))
           (should (equal (substring-no-properties string)
                          "Possible misspelling"))
           (should (eq (get-text-property 0 'face string)
                       'proofread-popup-face))
           (should (= (plist-get args :position) 4))
           (should (eq (plist-get args :poshandler)
                       #'posframe-poshandler-point-bottom-left-corner-upward))
           (should (= (plist-get args :internal-border-width) 1))
           (should (= (plist-get args :left-fringe) 3))
           (should (= (plist-get args :right-fringe) 3))
           (should (eq (plist-get args :accept-focus) nil))
           (should (member '(no-accept-focus . t)
                           (plist-get args :override-parameters)))
           (should (member '(no-focus-on-map . t)
                           (plist-get args :override-parameters)))))))))

(ert-deftest proofread-test-popup-uses-themed-face-colors ()
  "The proofread child frame forwards colors from the active face."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread--make-diagnostic
               :beg 1
               :end 5
               :text "helo"
               :message "Possible misspelling")))
         (proofread-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (cl-letf (((symbol-function 'face-attribute)
                    (lambda (face attribute &rest _args)
                      (pcase (list face attribute)
                        (`(proofread-popup-face :foreground)
                         "theme-foreground")
                        (`(proofread-popup-face :background)
                         "theme-background")
                        (`(proofread-popup-border-face :background)
                         "theme-border")))))
           (proofread--popup-update))
         (let* ((call (car proofread-test--popup-shows))
                (args (cdr call)))
           (should (equal (plist-get args :foreground-color)
                          "theme-foreground"))
           (should (equal (plist-get args :background-color)
                          "theme-background"))
           (should (equal (plist-get args :internal-border-color)
                          "theme-border"))))))))

(ert-deftest proofread-test-popup-does-not-refresh-same-diagnostic ()
  "Moving inside one diagnostic does not repeatedly redraw the child frame."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-test--diagnostic-for-range 4 8 "helo")))
         (proofread-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread--popup-update)
         (goto-char 7)
         (proofread--popup-update)
         (should (= (length proofread-test--popup-shows) 1)))))))

(ert-deftest proofread-test-popup-hides-away-from-diagnostic ()
  "The proofread child frame hides when point leaves diagnostics."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-test--diagnostic-for-range 4 8 "helo")))
         (proofread-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread--popup-update)
         (goto-char 10)
         (proofread--popup-update)
         (should proofread-test--popup-hides)
         (should-not proofread--popup-diagnostic))))))

(ert-deftest proofread-test-popup-disabled-does-not-show ()
  "Disabling proofread popup display prevents child frame creation."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((proofread-popup-enabled nil)
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
         (proofread-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (proofread--popup-update)
         (should-not proofread-test--popup-shows))))))

(ert-deftest proofread-test-popup-disable-mode-hides-frame ()
  "Disabling `proofread-mode' hides any proofread child frame."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
         (proofread-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (proofread--popup-update)
         (proofread-mode -1)
         (should proofread-test--popup-hides)
         (should proofread-test--popup-deletes)
         (should-not (memq #'proofread--popup-update
                           post-command-hook))
         (should-not proofread--popup-diagnostic))))))

(ert-deftest proofread-test-popup-correct-hides-frame ()
  "`proofread-correct' hides the child frame for the corrected diagnostic."
  (proofread-test--with-popup-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
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
         (proofread--popup-update)
         (proofread-correct)
         (should proofread-test--popup-hides)
         (should-not proofread--popup-diagnostic)
         (should (equal (buffer-string) "aa hello zz")))))))

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
           :source 'llm))
         (description
          (proofread--format-diagnostic-description diagnostic)))
    (should (string-match-p "Kind: spelling" description))
    (should (string-match-p "Message: Possible misspelling" description))
    (should (string-match-p "Original text:\nhelo" description))
    (should (string-match-p "1\\. hello" description))
    (should (string-match-p "Confidence: 0.92" description))
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
              :confidence 0.91
              :source 'llm)))
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

(ert-deftest proofread-test-correct-single-suggestion-replaces-range ()
  "`proofread-correct' applies one suggestion without prompting."
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
        (should (eq (proofread-correct) 'applied)))
      (should (equal (buffer-string) "aa hello zz")))))

(ert-deftest proofread-test-correct-multiple-suggestions-uses-completion ()
  "`proofread-correct' preserves candidate order for completion."
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
        (should (eq (proofread-correct) 'applied)))
      (should (equal candidates-seen '("hello" "hullo" "hallo")))
      (should (equal (buffer-string) "aa hullo zz")))))

(ert-deftest proofread-test-correct-uses-native-completion ()
  "`proofread-correct' uses `completing-read' for multiple suggestions."
  (let ((description-buffer (get-buffer proofread--description-buffer-name)))
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
        (should (eq (proofread-correct) 'applied)))
      (should (equal prompt-seen "Apply suggestion: "))
      (should (equal candidates-seen '("hello" "hullo" "hallo")))
      (should require-match-seen)
      (should (equal (buffer-string) "aa hallo zz"))
      (should-not (get-buffer proofread--description-buffer-name)))))

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
      (should-error (proofread-correct) :type 'user-error)
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
      (should-error (proofread-correct) :type 'user-error)
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
      (should-error (proofread-correct) :type 'user-error)
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
      (should-error (proofread-correct) :type 'user-error)
      (should (equal (buffer-string) "hell")))))

(ert-deftest proofread-test-apply-undo-restores-original-text ()
  "Undo restores text replaced by `proofread-correct'."
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
      (proofread-correct)
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
      (proofread-correct)
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
                    :backend 'llm))
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
  "Request events expose LLM request, response, parsed result, and final status."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (chunk (car (proofread--request-ready-chunks-for-ranges
                        (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-test--response-content
             (list (proofread-test--response-diagnostic 0 4 "helo"))))
           events
           status)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success content)))
                   'proofread-test-llm-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-test--llm-capabilities))
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
                (final-result
                 (car (last events))))
            (should (plist-get backend-request :schema))
            (should (plist-get backend-request :prompt))
            (should (equal (plist-get backend-response :response)
                           content))
            (should (eq (plist-get final-result :status)
                        'applied))))))))

(ert-deftest proofread-test-request-log-buffer-lists-recorded-requests ()
  "`proofread-show-buffer-requests' lists request ranges for a buffer."
  (save-window-excursion
    (let ((source (generate-new-buffer " *proofread-request-list-source*")))
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
                          :backend 'llm
                          :modified-tick
                          (buffer-chars-modified-tick)))
                   (name (proofread--request-log-list-buffer-name source)))
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
                        (should (= (plist-get id :request-id) 7))
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

(ert-deftest proofread-test-request-log-buffer-follows-visible-requests ()
  "`proofread-show-buffer-requests' follows real visible request dispatch."
  (save-window-excursion
    (let ((source (generate-new-buffer " *proofread-request-live-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert (concat "第一句。"
                            "第二句。"))
            (proofread-mode 1)
            (let ((proofread-backend 'llm)
                  (proofread-llm-provider proofread-test--llm-provider)
                  (proofread-llm-provider-identity
                   proofread-test--llm-provider-identity)
                  (proofread-context-size 0)
                  (proofread-max-concurrent-requests 1)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name source)))
              (unwind-protect
                  (proofread-test--with-llm-capabilities
                   (cl-letf (((symbol-function 'window-start)
                              (lambda (&optional _window) (point-min)))
                             ((symbol-function 'window-end)
                              (lambda (&optional _window _update)
                                (point-max)))
                             ((symbol-function 'proofread-backend-check)
                              (plist-get recorder :function)))
                     (proofread-show-buffer-requests source)
                     (proofread-check-visible)
                     (with-current-buffer name
                       (should (= (length tabulated-list-entries) 2))
                       (let ((statuses
                              (mapcar (lambda (entry)
                                        (aref (cadr entry) 1))
                                      tabulated-list-entries)))
                         (should (member "waiting" statuses))
                         (should (member "queued" statuses))))
                     (let* ((requests (funcall
                                       (plist-get recorder :requests)))
                            (callbacks (funcall
                                        (plist-get recorder :callbacks)))
                            (first-request (car requests))
                            (first-callback (car callbacks)))
                       (should (eq (funcall
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

(ert-deftest proofread-test-request-log-request-buffer-shows-lisp-data ()
  "Detailed proofread request buffers are read-only Lisp data buffers."
  (save-window-excursion
    (let ((source (generate-new-buffer " *proofread-request-detail-source*")))
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
                          :backend 'llm
                          :modified-tick
                          (buffer-chars-modified-tick)))
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
                    (proofread--request-log-request-buffer-name record)))
              (unwind-protect
                  (progn
                    (proofread--request-log-show-record record)
                    (with-current-buffer detail-name
                      (should buffer-read-only)
                      (should (eq major-mode
                                  (if (fboundp 'lisp-data-mode)
                                      'lisp-data-mode
                                    'emacs-lisp-mode)))
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

(provide 'proofread-tests)

;;; proofread-tests.el ends here
