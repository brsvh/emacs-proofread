;;; proofread-languagetool-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the local Proofread LanguageTool backend.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'proofread)
(require 'proofread-languagetool)

;;;; Test support

(defun proofread-languagetool-test--request (&rest properties)
  "Return a sample backend request extended by PROPERTIES."
  (append properties
          (list :beg 20
                :end 28
                :text "This are"
                :context-before "😀 "
                :context-after " fine."
                :language "en-US"
                :target-kind 'text
                :buffer (current-buffer))))

(defun proofread-languagetool-test--match
    (offset match-length &optional issue-type message replacements)
  "Return a LanguageTool match at OFFSET with MATCH-LENGTH.
ISSUE-TYPE, MESSAGE, and REPLACEMENTS customize the match."
  `((offset . ,offset)
    (length . ,match-length)
    (message . ,(or message "Possible problem"))
    (replacements .
                  ,(mapcar (lambda (value)
                             `((value . ,value)))
                           replacements))
    (rule . ((issueType . ,(or issue-type "grammar"))))))

(defun proofread-languagetool-test--response-buffer (status body)
  "Return a URL response buffer with HTTP STATUS and BODY."
  (let ((buffer (generate-new-buffer " *proofread-lt-response*")))
    (with-current-buffer buffer
      (insert (format "HTTP/1.1 %d Test\r\n\r\n" status))
      (set (make-local-variable 'url-http-response-status) status)
      (set (make-local-variable 'url-http-end-of-headers)
           (copy-marker (point)))
      (insert body))
    buffer))

(defun proofread-languagetool-test--complete-call
    (call status body &optional callback-status)
  "Complete recorded URL CALL with HTTP STATUS and BODY.
CALLBACK-STATUS is the status plist passed to the URL callback."
  (let ((buffer (plist-get call :buffer)))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "HTTP/1.1 %d Test\r\n\r\n" status))
      (set (make-local-variable 'url-http-response-status) status)
      (set (make-local-variable 'url-http-end-of-headers)
           (copy-marker (point)))
      (insert body)
      (apply (plist-get call :callback)
             (cons callback-status (plist-get call :arguments))))))

(defun proofread-languagetool-test--assert-no-redirects (buffer)
  "Assert that redirects remain disabled in retrieval BUFFER."
  (should (buffer-live-p buffer))
  (with-current-buffer buffer
    (should (local-variable-p 'url-max-redirections))
    (should (= (symbol-value 'url-max-redirections) 0))))

(defun proofread-languagetool-test--wait-for
    (predicate &optional timeout)
  "Wait for PREDICATE until TIMEOUT seconds have elapsed."
  (let ((deadline (+ (float-time) (or timeout 1.0)))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(defun proofread-languagetool-test--server-log-snapshot
    (point-offset)
  "Return a filtered server-log snapshot from POINT-OFFSET.
POINT-OFFSET is a zero-based offset or the symbol `end'."
  (with-temp-buffer
    (insert "abcdefgh")
    (goto-char
     (if (eq point-offset 'end)
         (point-max)
       (+ (point-min) point-offset)))
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'process-buffer)
                 (lambda (_process) buffer)))
        (proofread-languagetool--process-filter
         'proofread-languagetool-test-process "ijkl")))
    (list :text (buffer-string)
          :point (point)
          :point-min (point-min)
          :point-max (point-max)
          :following
          (buffer-substring-no-properties (point) (point-max)))))

(defun proofread-languagetool-test--run-scheduled-probe ()
  "Run the currently scheduled LanguageTool probe immediately."
  (let ((token proofread-languagetool--probe-retry-token))
    (proofread-languagetool--cancel-global-timer
     'proofread-languagetool--probe-retry-timer)
    (apply #'proofread-languagetool--run-probe
           (append token (list token)))))

(defun proofread-languagetool-test--cleanup-state ()
  "Cancel dynamically bound LanguageTool test resources."
  (dolist (timer
           (list proofread-languagetool--startup-timer
                 proofread-languagetool--probe-timeout-timer
                 proofread-languagetool--probe-retry-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (proofread-languagetool--kill-url-buffer
   proofread-languagetool--probe-buffer)
  (dolist (handle (copy-sequence
                   proofread-languagetool--live-handles))
    (proofread-languagetool--cancel handle)))

(defun proofread-languagetool-test--assert-no-readiness-work ()
  "Assert that no LanguageTool readiness resource remains published."
  (should-not proofread-languagetool--startup-timer)
  (should-not proofread-languagetool--probe-retry-timer)
  (should-not proofread-languagetool--probe-retry-token)
  (should-not proofread-languagetool--probe-timeout-timer)
  (should-not proofread-languagetool--probe-buffer))

(defmacro proofread-languagetool-test--with-state (&rest body)
  "Run BODY with isolated LanguageTool session state."
  (declare (indent 0) (debug (body)))
  `(let ((proofread-languagetool--server-process nil)
         (proofread-languagetool--server-process-session nil)
         (proofread-languagetool--server-state 'unknown)
         (proofread-languagetool--server-session nil)
         (proofread-languagetool--server-waiters nil)
         (proofread-languagetool--live-handles nil)
         (proofread-languagetool--server-generation 0)
         (proofread-languagetool--startup-timer nil)
         (proofread-languagetool--probe-timeout-timer nil)
         (proofread-languagetool--probe-retry-timer nil)
         (proofread-languagetool--probe-retry-token nil)
         (proofread-languagetool--probe-buffer nil)
         (proofread-languagetool--shutting-down-p nil)
         (proofread-languagetool--force-start-p nil))
     (unwind-protect
         (progn ,@body)
       (proofread-languagetool-test--cleanup-state))))

;;;; Registration, configuration, and identity

(ert-deftest proofread-languagetool-test-registered-backend ()
  "The LanguageTool feature registers all backend operations."
  (let ((descriptor
         (gethash 'languagetool proofread--backend-registry)))
    (should (eq (plist-get descriptor :check)
                #'proofread-languagetool--check))
    (should (eq (plist-get descriptor :identity)
                #'proofread-languagetool--identity))
    (should (eq (plist-get descriptor :snapshot-options)
                #'proofread-languagetool--snapshot-checker-options))
    (should (eq (plist-get descriptor :checker-identity)
                #'proofread-languagetool--checker-identity))
    (should (eq (plist-get descriptor :source-label)
                #'proofread-languagetool--checker-source-label))
    (should
     (equal
      (funcall (plist-get descriptor :source-label)
               '( :profile test :name local
                  :backend languagetool
                  :options ( :language "de-DE")))
      "languagetool"))
    (should (eq (plist-get descriptor :cancel)
                #'proofread-languagetool--cancel))))

(ert-deftest
    proofread-languagetool-test-checker-options-normalize-and-detach ()
  "Normalize checker options without retaining mutable input values."
  (let* ((property-value (list "secret"))
         (language
          (propertize (copy-sequence " en-US ")
                      'proofread-test property-value))
         (variant-de
          (propertize (copy-sequence " de-DE ")
                      'proofread-test property-value))
         (variant-en (copy-sequence "en-US"))
         (preferred-variants
          (list variant-de variant-en variant-de))
         (mother-tongue
          (propertize (copy-sequence " zh-CN ")
                      'proofread-test property-value))
         (rule-b (copy-sequence " RULE_B "))
         (rule-a
          (propertize (copy-sequence "RULE_A")
                      'proofread-test property-value))
         (enabled-rules (list rule-b rule-a rule-b))
         (disabled-rules (list (copy-sequence " OFF ")))
         (enabled-categories (list (copy-sequence " STYLE ")))
         (disabled-categories (list (copy-sequence " TYPO ")))
         (raw-options
          (list :language language
                :level 'picky
                :preferred-variants preferred-variants
                :mother-tongue mother-tongue
                :enabled-rules enabled-rules
                :disabled-rules disabled-rules
                :enabled-categories enabled-categories
                :disabled-categories disabled-categories
                :enabled-only nil))
         (expected
          '( :language "en-US"
             :level picky
             :preferred-variants ( "de-DE" "en-US")
             :mother-tongue "zh-CN"
             :enabled-rules ( "RULE_A" "RULE_B")
             :disabled-rules ( "OFF")
             :enabled-categories ( "STYLE")
             :disabled-categories ( "TYPO")
             :enabled-only nil))
         (snapshot
          (proofread-languagetool--snapshot-checker-options
           raw-options)))
    (should (equal snapshot expected))
    (should-not (eq language (plist-get snapshot :language)))
    (should-not (eq mother-tongue
                    (plist-get snapshot :mother-tongue)))
    (let ((strings
           (list (plist-get snapshot :language)
                 (plist-get snapshot :mother-tongue))))
      (dolist (key '( :preferred-variants
                      :enabled-rules
                      :disabled-rules
                      :enabled-categories
                      :disabled-categories))
        (setq strings (append strings (plist-get snapshot key))))
      (dolist (value strings)
        (should-not (text-properties-at 0 value))))
    (dolist (key '( :preferred-variants
                    :enabled-rules
                    :disabled-rules
                    :enabled-categories
                    :disabled-categories))
      (let ((input (plist-get raw-options key))
            (output (plist-get snapshot key)))
        (should-not (eq input output))
        (dolist (value output)
          (should-not (memq value input)))))
    (aset language 1 ?X)
    (aset mother-tongue 1 ?X)
    (aset variant-de 1 ?X)
    (aset rule-a 0 ?X)
    (setcdr preferred-variants nil)
    (setcdr enabled-rules nil)
    (setcar property-value "changed")
    (should (equal snapshot expected))))

(ert-deftest
    proofread-languagetool-test-checker-options-preserve-explicit-nil ()
  "Distinguish absent checker options from explicitly nil options."
  (let ((proofread-languagetool-level 'picky)
        (proofread-languagetool-preferred-variants '( "en-US"))
        (proofread-languagetool-mother-tongue "zh-CN")
        (proofread-languagetool-enabled-rules '( "RULE"))
        (proofread-languagetool-disabled-rules '( "OFF"))
        (proofread-languagetool-enabled-categories '( "STYLE"))
        (proofread-languagetool-disabled-categories '( "TYPO"))
        (proofread-languagetool-enabled-only nil))
    (let ((fallbacks
           (proofread-languagetool--snapshot-checker-options nil)))
      (should-not (plist-member fallbacks :language))
      (should (equal fallbacks
                     '( :level picky
                        :preferred-variants ( "en-US")
                        :mother-tongue "zh-CN"
                        :enabled-rules ( "RULE")
                        :disabled-rules ( "OFF")
                        :enabled-categories ( "STYLE")
                        :disabled-categories ( "TYPO")
                        :enabled-only nil))))
    (dolist (key '( :language
                    :preferred-variants
                    :mother-tongue
                    :enabled-rules
                    :disabled-rules
                    :enabled-categories
                    :disabled-categories))
      (let ((snapshot
             (proofread-languagetool--snapshot-checker-options
              (list key nil))))
        (should (plist-member snapshot key))
        (should-not (plist-get snapshot key)))))
  (let ((proofread-languagetool-enabled-only t)
        (proofread-languagetool-enabled-rules '( "RULE"))
        (proofread-languagetool-disabled-rules nil)
        (proofread-languagetool-enabled-categories nil)
        (proofread-languagetool-disabled-categories nil))
    (should
     (plist-get
      (proofread-languagetool--snapshot-checker-options nil)
      :enabled-only))
    (let ((snapshot
           (proofread-languagetool--snapshot-checker-options
            '( :enabled-only nil))))
      (should (plist-member snapshot :enabled-only))
      (should-not (plist-get snapshot :enabled-only)))))

(ert-deftest
    proofread-languagetool-test-checker-options-freeze-fallbacks ()
  "Freeze fallback options for later identity and request construction."
  (let* ((variant (copy-sequence "en-US"))
         (mother-tongue (copy-sequence "zh-CN"))
         (rule (copy-sequence "RULE_A"))
         (proofread-languagetool-server-url
          "http://127.0.0.1:8081/v2")
         (proofread-languagetool-auto-start nil)
         (proofread-languagetool-level 'picky)
         (proofread-languagetool-preferred-variants (list variant))
         (proofread-languagetool-mother-tongue mother-tongue)
         (proofread-languagetool-enabled-rules (list rule))
         (proofread-languagetool-disabled-rules nil)
         (proofread-languagetool-enabled-categories nil)
         (proofread-languagetool-disabled-categories nil)
         (proofread-languagetool-enabled-only t)
         (snapshot
          (proofread-languagetool--snapshot-checker-options nil))
         (checker
          (list :profile 'test :name 'local :backend 'languagetool
                :options snapshot))
         (request
          (proofread-languagetool-test--request
           :language nil :checker-options snapshot))
         (identity
          (proofread-languagetool--checker-identity checker))
         (body
          (plist-get (proofread-languagetool--request-data request)
                     :body)))
    (should (equal snapshot
                   '( :level picky
                      :preferred-variants ( "en-US")
                      :mother-tongue "zh-CN"
                      :enabled-rules ( "RULE_A")
                      :disabled-rules nil
                      :enabled-categories nil
                      :disabled-categories nil
                      :enabled-only t)))
    (aset variant 0 ?X)
    (aset mother-tongue 0 ?X)
    (aset rule 0 ?X)
    (setq proofread-languagetool-level 'default
          proofread-languagetool-preferred-variants nil
          proofread-languagetool-mother-tongue nil
          proofread-languagetool-enabled-rules nil
          proofread-languagetool-enabled-only nil)
    (should (equal (proofread-languagetool--checker-identity checker)
                   identity))
    (should (equal
             (plist-get (proofread-languagetool--request-data request)
                        :body)
             body))))

(ert-deftest
    proofread-languagetool-test-checker-options-reject-invalid-input ()
  "Reject malformed, unknown, duplicate, and invalid checker options."
  (dolist
      (options
       '(not-a-plist
         ( :language)
         (language "en-US")
         ( :unknown t)
         ( :level picky :level default)
         ( :language 42)
         ( :language "  ")
         ( :level nil)
         ( :level ordinary)
         ( :preferred-variants "en-US")
         ( :preferred-variants ( "en-US" "en-GB"))
         ( :preferred-variants ( "en-US" . "en-GB"))
         ( :mother-tongue "")
         ( :enabled-rules ( "RULE,"))
         ( :enabled-rules ( "RULE" . "OTHER"))
         ( :disabled-rules ( 42))
         ( :enabled-categories t)
         ( :enabled-only yes)
         ( :enabled-only t
           :enabled-rules nil
           :enabled-categories nil
           :disabled-rules nil
           :disabled-categories nil)
         ( :enabled-only t
           :enabled-rules ( "RULE")
           :disabled-rules ( "OTHER"))))
    (should-error
     (proofread-languagetool--snapshot-checker-options options)))
  (dolist (case '( ( :preferred-variants . "en-US")
                   ( :enabled-rules . "RULE")))
    (let ((cycle (list (cdr case))))
      (setcdr cycle cycle)
      (unwind-protect
          (should-error
           (proofread-languagetool--snapshot-checker-options
            (list (car case) cycle)))
        (setcdr cycle nil)))))

(ert-deftest
    proofread-languagetool-test-explicit-nil-language-overrides-request ()
  "An explicitly nil checker language selects automatic detection."
  (let* ((options
          (proofread-languagetool--snapshot-checker-options
           '( :language nil)))
         (explicit-request
          (proofread-languagetool-test--request
           :language "fr-FR" :checker-options options))
         (absent-request
          (proofread-languagetool-test--request
           :language "fr-FR" :checker-options nil))
         (checker
          (list :profile 'test :name 'local :backend 'languagetool
                :options options))
         (identity
          (proofread-languagetool--checker-identity checker)))
    (should (equal (proofread-languagetool--request-language
                    explicit-request)
                   "auto"))
    (should (equal (proofread-languagetool--request-language
                    absent-request)
                   "fr-FR"))
    (should (plist-member identity :language))
    (should (equal (plist-get identity :language) "auto"))))

(ert-deftest proofread-languagetool-test-identity-covers-rules ()
  "Cache identity includes every response-affecting request option."
  (let ((proofread-languagetool-server-url
         "http://127.0.0.1:8081/v2/")
        (proofread-languagetool-auto-start t)
        (proofread-languagetool-level 'picky)
        (proofread-languagetool-preferred-variants
         '( "de-DE" "en-US" "de-DE"))
        (proofread-languagetool-mother-tongue "zh-CN")
        (proofread-languagetool-enabled-rules '( "B" "A"))
        (proofread-languagetool-disabled-rules '( "D" "C"))
        (proofread-languagetool-enabled-categories '( "STYLE"))
        (proofread-languagetool-disabled-categories '( "TYPO"))
        (proofread-languagetool-enabled-only nil)
        (proofread-languagetool-command
         "proofread-languagetool-missing-test-command"))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_command) nil)))
      (let ((command-identity
             (proofread-languagetool--command-identity-for-snapshot
              proofread-languagetool-command)))
        (should
         (equal
          (proofread-languagetool--identity)
          `( :backend languagetool
             :server-url "http://127.0.0.1:8081/v2"
             :server-config nil
             :server-command ,command-identity
             :level picky
             :preferred-variants ("de-DE" "en-US")
             :mother-tongue "zh-CN"
             :enabled-rules ("A" "B")
             :disabled-rules ("C" "D")
             :enabled-categories ("STYLE")
             :disabled-categories ("TYPO")
             :enabled-only nil
             :contract-version 1)))))))

(ert-deftest proofread-languagetool-test-port-requirements ()
  "External URLs may omit a port, but managed startup may not."
  (should
   (equal
    (proofread-languagetool--normalize-server-url
     "https://example.com/v2")
    "https://example.com/v2"))
  (should
   (equal
    (proofread-languagetool--normalize-server-url
     "https://example.com/tools/languagetool/v2")
    "https://example.com/tools/languagetool/v2"))
  (should-error
   (proofread-languagetool--normalize-server-url
    "http://example.com/v2"))
  (let* ((proofread-languagetool-auto-start nil)
         (proofread-languagetool-server-url
          "http://127.0.0.1/v2")
         (session
          (proofread-languagetool--server-session-snapshot)))
    (should-error
     (proofread-languagetool--managed-port session)))
  (let* ((proofread-languagetool-auto-start nil)
         (proofread-languagetool-server-url
          "http://127.0.0.1:18081/proxy/v2")
         (session
          (proofread-languagetool--server-session-snapshot)))
    (should-error
     (proofread-languagetool--managed-port session))))

(ert-deftest
    proofread-languagetool-test-auto-start-needs-managed-url ()
  "Automatic startup requires a direct, explicit local endpoint."
  (dolist (url '( "https://example.com/v2"
                  "https://example.com/proxy/v2"
                  "http://127.0.0.1/v2"
                  "http://127.0.0.1:18081/proxy/v2"))
    (let ((proofread-languagetool-server-url url)
          (proofread-languagetool-auto-start t))
      (should-error
       (proofread-languagetool--server-session-snapshot)))
    (let ((proofread-languagetool-server-url url)
          (proofread-languagetool-auto-start nil))
      (should
       (proofread-languagetool--server-session-snapshot)))))

(ert-deftest
    proofread-languagetool-test-config-file-must-be-local-absolute ()
  "Server config paths cannot depend on a buffer or remote host."
  (dolist (path '( "languagetool.properties"
                   "../languagetool.properties"
                   "/ssh:user@example.test:/etc/languagetool.properties"))
    (let ((proofread-languagetool-auto-start t)
          (proofread-languagetool-config-file path))
      (should-error
       (proofread-languagetool--server-session-snapshot)))))

(ert-deftest
    proofread-languagetool-test-config-identity-follows-symlink ()
  "Server identity follows the resolved config-file target."
  (let* ((directory (make-temp-file "proofread-lt-config-" t))
         (first (expand-file-name "first.properties" directory))
         (second (expand-file-name "second.properties" directory))
         (link (expand-file-name "current.properties" directory)))
    (unwind-protect
        (progn
          (write-region "key=first\n" nil first nil 'silent)
          (write-region "key=second\n" nil second nil 'silent)
          (make-symbolic-link first link)
          (let ((proofread-languagetool-auto-start t)
                (proofread-languagetool-config-file link)
                first-session)
            (setq first-session
                  (proofread-languagetool--server-session-snapshot))
            (should (equal (plist-get first-session :config-file)
                           (file-truename first)))
            (delete-file link)
            (make-symbolic-link second link)
            (let ((second-session
                   (proofread-languagetool--server-session-snapshot)))
              (should (equal (plist-get second-session :config-file)
                             (file-truename second)))
              (should-not
               (proofread-languagetool--same-session-p
                first-session second-session)))))
      (delete-directory directory t))))

(ert-deftest
    proofread-languagetool-test-config-content-invalidates-cache-identity
    ()
  "Config content changes invalidate backend and cache identity."
  (let* ((directory (make-temp-file "proofread-lt-content-" t))
         (config (expand-file-name "languagetool.properties" directory))
         (first-content
          "apiKey=proofread-task12-secret-alpha\n")
         (second-content
          "apiKey=proofread-task12-secret-omega\n"))
    (unwind-protect
        (progn
          (should (= (length first-content) (length second-content)))
          (write-region first-content nil config nil 'silent)
          (let ((proofread-languagetool-auto-start t)
                (proofread-languagetool-command
                 "proofread-languagetool-missing-test-command")
                (proofread-languagetool-config-file config))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (_command) nil)))
              (with-temp-buffer
                (insert "Alpha")
                (setq-local proofread-auto-check nil)
                (proofread-mode 1)
                (let* ((attributes (file-attributes config))
                       (size (file-attribute-size attributes))
                       (mtime
                        (file-attribute-modification-time attributes))
                       (chunk
                        (proofread--make-request-ready-chunk
                         (point-min) (point-max) "en-US"))
                       (first-identity
                        (proofread-languagetool--identity))
                       (first-session
                        (proofread-languagetool--server-session-snapshot))
                       (first-request
                        (proofread--make-backend-request
                         chunk 'languagetool))
                       (diagnostic
                        '( :beg 1 :end 6 :text "Alpha"
                           :kind grammar :message "Cached"
                           :suggestions ("Beta")
                           :source languagetool)))
                  (proofread--cache-write-request
                   first-request (list diagnostic))
                  (should
                   (proofread--cache-read-request
                    (proofread--make-backend-request
                     chunk 'languagetool)))
                  (write-region second-content nil config nil 'silent)
                  (set-file-times config mtime)
                  (let* ((new-attributes (file-attributes config))
                         (second-identity
                          (proofread-languagetool--identity))
                         (second-session
                          (proofread-languagetool--server-session-snapshot))
                         (second-request
                          (proofread--make-backend-request
                           chunk 'languagetool)))
                    (should
                     (= size
                        (file-attribute-size new-attributes)))
                    (should
                     (time-equal-p
                      mtime
                      (file-attribute-modification-time
                       new-attributes)))
                    (should-not (equal first-identity second-identity))
                    (should-not
                     (proofread-languagetool--same-session-p
                      first-session second-session))
                    (should-not
                     (equal (plist-get first-request :cache-key)
                            (plist-get second-request :cache-key)))
                    (should-not
                     (proofread--cache-read-request second-request))))))))
      (delete-directory directory t))))

(ert-deftest
    proofread-languagetool-test-unchanged-config-is-stable-and-safe ()
  "Unchanged config content neither leaks nor restarts a ready server."
  (proofread-languagetool-test--with-state
    (let* ((directory (make-temp-file "proofread-lt-stable-" t))
           (config (expand-file-name "languagetool.properties" directory))
           (secret "proofread-task12-stable-secret")
           (content (format "apiKey=%s\n" secret)))
      (unwind-protect
          (progn
            (write-region content nil config nil 'silent)
            (let ((proofread-languagetool-auto-start t)
                  (proofread-languagetool-command
                   "proofread-languagetool-missing-test-command")
                  (proofread-languagetool-config-file config))
              (cl-letf (((symbol-function 'executable-find)
                         (lambda (_command) nil)))
                (let* ((identity (proofread-languagetool--identity))
                       (config-identity
                        (plist-get identity :server-config))
                       (digest
                        (plist-get config-identity :content-digest))
                       (session
                        (proofread-languagetool--server-session-snapshot))
                       (proofread-languagetool--server-state 'ready)
                       (proofread-languagetool--server-session session)
                       (proofread-languagetool--server-process
                        'owned-process)
                       (proofread-languagetool--server-process-session
                        session)
                       call events handle)
                  (should
                   (string-match-p
                    "\\`[[:xdigit:]]\\{64\\}\\'" digest))
                  (set-file-times
                   config
                   (time-add
                    (file-attribute-modification-time
                     (file-attributes config))
                    10))
                  (should (equal identity
                                 (proofread-languagetool--identity)))
                  (should
                   (proofread-languagetool--same-session-p
                    session
                    (proofread-languagetool--server-session-snapshot)))
                  (should-not
                   (string-match-p
                    (regexp-quote secret)
                    (prin1-to-string identity)))
                  (cl-letf
                      (((symbol-function
                         'proofread-languagetool--begin-readiness-check)
                        (lambda (&rest _ignored)
                          (ert-fail "Stable config restarted readiness")))
                       ((symbol-function
                         'proofread-languagetool--stop-owned-process)
                        (lambda ()
                          (ert-fail "Stable config stopped its process")))
                       ((symbol-function 'url-retrieve)
                        (lambda (url _callback _arguments &rest _ignored)
                          (setq call
                                (list :url url
                                      :method url-request-method
                                      :buffer
                                      (generate-new-buffer
                                       " *proofread-lt-stable-config*")))
                          (plist-get call :buffer))))
                    (with-temp-buffer
                      (let ((proofread-request-log-hook
                             (list
                              (lambda (event) (push event events)))))
                        (setq handle
                              (proofread-languagetool--check
                               (proofread-languagetool-test--request)
                               #'ignore))))
                    (should (equal (plist-get call :method) "POST"))
                    (should (string-suffix-p
                             "/check" (plist-get call :url)))
                    (should
                     (eq proofread-languagetool--server-state 'ready))
                    (let ((printed-events (prin1-to-string events)))
                      (should-not
                       (string-match-p
                        (regexp-quote secret) printed-events))
                      (should-not
                       (string-match-p
                        (regexp-quote content) printed-events)))
                    (proofread-languagetool--cancel handle))))))
        (delete-directory directory t)))))

(ert-deftest
    proofread-languagetool-test-config-rewrite-restarts-owned-server ()
  "Explicit startup replaces an owned server after a config rewrite."
  (proofread-languagetool-test--with-state
    (let* ((directory (make-temp-file "proofread-lt-restart-" t))
           (config (expand-file-name "languagetool.properties" directory))
           (first-content "languageModel=alpha\n")
           (second-content "languageModel=omega\n"))
      (unwind-protect
          (progn
            (should (= (length first-content) (length second-content)))
            (write-region first-content nil config nil 'silent)
            (let ((proofread-languagetool-auto-start nil)
                  (proofread-languagetool-command
                   "proofread-languagetool-missing-test-command")
                  (proofread-languagetool-config-file config))
              (cl-letf (((symbol-function 'executable-find)
                         (lambda (_command) nil)))
                (let* ((old-session
                        (proofread-languagetool--server-session-snapshot
                         nil t))
                       (attributes (file-attributes config))
                       (mtime
                        (file-attribute-modification-time attributes))
                       (proofread-languagetool--server-state 'ready)
                       (proofread-languagetool--server-session old-session)
                       (proofread-languagetool--server-process
                        'owned-process)
                       (proofread-languagetool--server-process-session
                        old-session)
                       deleted scheduled)
                  (write-region second-content nil config nil 'silent)
                  (set-file-times config mtime)
                  (cl-letf
                      (((symbol-function 'process-live-p)
                        (lambda (process) (eq process 'owned-process)))
                       ((symbol-function 'set-process-query-on-exit-flag)
                        #'ignore)
                       ((symbol-function 'delete-process)
                        (lambda (process) (setq deleted process)))
                       ((symbol-function
                         'proofread-languagetool--schedule-probe)
                        (lambda (generation phase session delay)
                          (setq scheduled
                                (list generation phase session delay)))))
                    (proofread-languagetool-start-server))
                  (should (eq deleted 'owned-process))
                  (should-not proofread-languagetool--server-process)
                  (should-not
                   proofread-languagetool--server-process-session)
                  (should (eq proofread-languagetool--server-state
                              'probing))
                  (should proofread-languagetool--force-start-p)
                  (should-not
                   (proofread-languagetool--same-managed-session-p
                    old-session proofread-languagetool--server-session))
                  (should
                   (equal scheduled
                          (list
                           proofread-languagetool--server-generation
                           'external
                           proofread-languagetool--server-session 0)))))))
        (delete-directory directory t)))))

(ert-deftest proofread-languagetool-test-snapshots-resolved-command ()
  "A resolvable managed command is fixed in the server session."
  (let ((executable (make-temp-file "proofread-lt-command-"))
        (proofread-languagetool-auto-start t)
        (proofread-languagetool-command
         '( "test-languagetool" "--fixed" "argument")))
    (unwind-protect
        (progn
          (set-file-modes executable #o700)
          (let ((session
                 (cl-letf (((symbol-function 'executable-find)
                            (lambda (_command) executable)))
                   (proofread-languagetool--server-session-snapshot))))
            (should
             (equal (plist-get session :command)
                    (list (file-truename executable)
                          "--fixed" "argument")))
            (cl-letf (((symbol-function 'executable-find)
                       (lambda (_command)
                         (ert-fail
                          (concat "The snapshotted command was "
                                  "searched again")))))
              (should (equal
                       (proofread-languagetool--server-command
                        session)
                       (list (file-truename executable)
                             "--fixed" "argument"))))))
      (delete-file executable))))

(ert-deftest
    proofread-languagetool-test-command-cache-identity-is-safe ()
  "Command changes invalidate cache identity.
The identity does not expose arguments."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_command) nil)))
    (let* ((secret "proofread-languagetool-test-secret")
           (proofread-languagetool-auto-start t)
           (proofread-languagetool-command
            (list "missing-languagetool" (concat "--token=" secret)))
           (first (proofread-languagetool--identity)))
      (should-not (string-match-p secret (prin1-to-string first)))
      (setq proofread-languagetool-command
            '( "different-missing-languagetool" "--fixed"))
      (should-not
       (equal first (proofread-languagetool--identity))))))

(ert-deftest
    proofread-languagetool-test-command-replacement-changes-identity ()
  "Replacing a resolved executable at the same path changes identity."
  (let* ((directory (make-temp-file "proofread-lt-command-content-" t))
         (executable (expand-file-name "languagetool-server" directory))
         (replacement (expand-file-name "replacement" directory))
         (first-content "#!/bin/sh\nexit 0\n")
         (second-content "#!/bin/sh\nexit 1\n")
         (secret "proofread-task12-command-secret"))
    (unwind-protect
        (progn
          (should (= (length first-content) (length second-content)))
          (write-region first-content nil executable nil 'silent)
          (write-region second-content nil replacement nil 'silent)
          (set-file-modes executable #o700)
          (set-file-modes replacement #o700)
          (set-file-times
           replacement
           (file-attribute-modification-time
            (file-attributes executable)))
          (let* ((proofread-languagetool-auto-start t)
                 (proofread-languagetool-command
                  (list executable (concat "--token=" secret)))
                 (first-identity (proofread-languagetool--identity))
                 (first-session
                  (proofread-languagetool--server-session-snapshot)))
            (rename-file replacement executable t)
            (let ((second-identity
                   (proofread-languagetool--identity))
                  (second-session
                   (proofread-languagetool--server-session-snapshot)))
              (should-not (equal first-identity second-identity))
              (should-not
               (proofread-languagetool--same-managed-session-p
                first-session second-session))
              (should
               (equal (plist-get first-session :command)
                      (plist-get second-session :command)))
              (should-not
               (string-match-p
                (regexp-quote secret)
                (prin1-to-string second-identity))))))
      (delete-directory directory t))))

(ert-deftest
    proofread-languagetool-test-external-identity-ignores-managed-options ()
  "External identities ignore settings used only for managed startup."
  (let ((proofread-languagetool-auto-start nil)
        (proofread-languagetool-command "first-command")
        (proofread-languagetool-config-file
         "/tmp/first-languagetool.properties")
        (proofread-languagetool-startup-timeout 10)
        (proofread-languagetool-health-timeout 3.0))
    (let ((backend-identity (proofread-languagetool--identity))
          (session (proofread-languagetool--server-session-snapshot)))
      (should-not (plist-member backend-identity :server-config))
      (should-not (plist-member backend-identity :server-command))
      (dolist (key '( :server-config :command :startup-timeout))
        (should-not (plist-member (plist-get session :identity) key)))
      (setq proofread-languagetool-command 42)
      (setq proofread-languagetool-config-file "relative.properties")
      (setq proofread-languagetool-startup-timeout 0)
      (should (equal backend-identity
                     (proofread-languagetool--identity)))
      (should
       (proofread-languagetool--same-session-p
        session (proofread-languagetool--server-session-snapshot)))
      (let ((proofread-languagetool-health-timeout 7.5))
        (should-not
         (proofread-languagetool--same-session-p
          session (proofread-languagetool--server-session-snapshot))))
      (let ((proofread-languagetool-health-timeout 0))
        (should-error
         (proofread-languagetool--server-session-snapshot))))))

(ert-deftest
    proofread-languagetool-test-managed-start-validates-managed-options ()
  "Automatic and explicit managed startup validate managed settings."
  (proofread-languagetool-test--with-state
    (let ((proofread-languagetool-server-url
           "http://127.0.0.1:8081/v2")
          (proofread-languagetool-auto-start nil)
          (proofread-languagetool-command "languagetool-http-server")
          (proofread-languagetool-config-file nil)
          (proofread-languagetool-startup-timeout 15.0))
      (let ((proofread-languagetool-command 42))
        (let ((err (should-error
                    (proofread-languagetool-start-server))))
          (should (string-match-p "command must"
                                  (error-message-string err)))))
      (let ((proofread-languagetool-config-file "relative.properties"))
        (let ((err (should-error
                    (proofread-languagetool-start-server))))
          (should (string-match-p "must be an absolute path"
                                  (error-message-string err)))))
      (let ((proofread-languagetool-startup-timeout 0))
        (let ((err (should-error
                    (proofread-languagetool-start-server))))
          (should (string-match-p "must be a positive number"
                                  (error-message-string err)))))
      (with-temp-buffer
        (let ((proofread-languagetool-auto-start t)
              (proofread-languagetool-command 42)
              result)
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq result value)))
          (should-not result)
          (should
           (proofread-languagetool-test--wait-for (lambda () result)))
          (should (eq (plist-get result :error)
                      'languagetool-configuration-error))
          (should (string-match-p "command must"
                                  (plist-get result :message))))))))

;;;; Request encoding and response parsing

(ert-deftest proofread-languagetool-test-request-parameters ()
  "Request data contains context, language, and rule controls."
  (let ((proofread-languagetool-level 'picky)
        (proofread-languagetool-preferred-variants
         '( "en-US" "de-DE"))
        (proofread-languagetool-mother-tongue "zh-CN")
        (proofread-languagetool-enabled-rules
         '( "RULE_B" "RULE_A"))
        (proofread-languagetool-disabled-rules nil)
        (proofread-languagetool-enabled-categories '( "STYLE"))
        (proofread-languagetool-disabled-categories nil)
        (proofread-languagetool-enabled-only t))
    (let* ((request
            (proofread-languagetool-test--request :language nil))
           (data (proofread-languagetool--request-data request))
           (parameters (plist-get data :parameters))
           (body (plist-get data :body)))
      (should (equal (plist-get data :text)
                     "😀 This are fine."))
      (should (= (plist-get data :target-beg) 2))
      (should (= (plist-get data :target-end) 10))
      (should (equal (cdr (assoc "text" parameters))
                     "😀 This are fine."))
      (dolist (part
               '( "language=auto"
                  "level=picky"
                  "preferredVariants=en-US%2Cde-DE"
                  "motherTongue=zh-CN"
                  "enabledRules=RULE_A%2CRULE_B"
                  "enabledCategories=STYLE"
                  "enabledOnly=true"
                  "text=%F0%9F%98%80%20This%20are%20fine."))
        (should (string-match-p (regexp-quote part) body))))))

(ert-deftest
    proofread-languagetool-test-checker-options-override-parameters ()
  "Checker-local LanguageTool request options override defcustoms."
  (let ((proofread-languagetool-level 'default)
        (proofread-languagetool-preferred-variants nil)
        (proofread-languagetool-mother-tongue nil)
        (proofread-languagetool-enabled-rules nil)
        (proofread-languagetool-disabled-rules '( "GLOBAL_OFF"))
        (proofread-languagetool-enabled-categories nil)
        (proofread-languagetool-disabled-categories nil)
        (proofread-languagetool-enabled-only nil))
    (let* ((options
            (proofread-languagetool--snapshot-checker-options
             '( :language nil
                :level picky
                :preferred-variants ( "en-US")
                :mother-tongue "zh-CN"
                :enabled-rules ( "RULE_B" "RULE_A")
                :disabled-rules nil
                :enabled-categories ( "STYLE")
                :disabled-categories nil
                :enabled-only t)))
           (request
            (proofread-languagetool-test--request
             :language "fr-FR"
             :checker-options options))
           (data (proofread-languagetool--request-data request))
           (body (plist-get data :body)))
      (dolist (part
               '( "language=auto"
                  "level=picky"
                  "preferredVariants=en-US"
                  "motherTongue=zh-CN"
                  "enabledRules=RULE_A%2CRULE_B"
                  "enabledCategories=STYLE"
                  "enabledOnly=true"))
        (should (string-match-p (regexp-quote part) body)))
      (should-not (string-match-p
                   (regexp-quote "GLOBAL_OFF")
                   body)))))

(ert-deftest
    proofread-languagetool-test-checker-identity-covers-options ()
  "Checker identity covers detached normalized request options."
  (let ((proofread-languagetool-server-url
         "http://127.0.0.1:8081/v2/")
        (proofread-languagetool-level 'default)
        (proofread-languagetool-enabled-rules nil)
        (proofread-languagetool-auto-start nil))
    (let* ((base-options
            (proofread-languagetool--snapshot-checker-options
             '( :language nil
                :level picky
                :enabled-rules ( "RULE_B" "RULE_A"))))
           (equivalent-options
            (proofread-languagetool--snapshot-checker-options
             '( :enabled-rules ( " RULE_A " "RULE_B" "RULE_A")
                :language nil
                :level picky)))
           (changed-options
            (proofread-languagetool--snapshot-checker-options
             '( :language nil
                :level default
                :enabled-rules ( "RULE_B" "RULE_A"))))
           (base
            (list :profile 'multi
                  :name 'local
                  :backend 'languagetool
                  :options base-options))
           (equivalent
            (list :profile 'multi
                  :name 'local
                  :backend 'languagetool
                  :options equivalent-options))
           (changed-option
            (list :profile 'multi
                  :name 'local
                  :backend 'languagetool
                  :options changed-options))
           (identity
            (proofread-languagetool--checker-identity base)))
      (should (equal (plist-get identity :server-url)
                     "http://127.0.0.1:8081/v2"))
      (should (equal (plist-get identity :language) "auto"))
      (should (equal (plist-get identity :level) 'picky))
      (should (equal (plist-get identity :enabled-rules)
                     '( "RULE_A" "RULE_B")))
      (should (equal identity
                     (proofread-languagetool--checker-identity
                      equivalent)))
      (should-not (equal
                   identity
                   (proofread-languagetool--checker-identity
                    changed-option))))))

(ert-deftest proofread-languagetool-test-preferred-variant-order ()
  "Preferred variants preserve order and reject base conflicts."
  (should
   (equal
    (proofread-languagetool--normalized-preferred-variants
     '( "en-US" "de-DE" "en-US"))
    '( "en-US" "de-DE")))
  (should-error
   (proofread-languagetool--normalized-preferred-variants
    '( "en-US" "en-GB")))
  (dolist (invalid '( "en" "en-" "-US"))
    (should-error
     (proofread-languagetool--normalized-preferred-variants
      (list invalid)))))

(ert-deftest proofread-languagetool-test-enabled-only-validation ()
  "Enabled-only mode rejects contradictory rule configuration."
  (let ((proofread-languagetool-enabled-only t)
        (proofread-languagetool-enabled-rules '( "RULE"))
        (proofread-languagetool-disabled-rules '( "OTHER")))
    (should-error
     (proofread-languagetool--request-data
      (proofread-languagetool-test--request))))
  (let ((proofread-languagetool-enabled-only t)
        (proofread-languagetool-enabled-rules nil)
        (proofread-languagetool-enabled-categories nil))
    (should-error
     (proofread-languagetool--request-data
      (proofread-languagetool-test--request)))))

(ert-deftest proofread-languagetool-test-utf16-offset-conversion ()
  "UTF-16 offsets convert around non-BMP Emacs characters."
  (let ((text "😀 This"))
    (should (= (proofread-languagetool--utf16-offset-to-index
                text 0)
               0))
    (should-not
     (proofread-languagetool--utf16-offset-to-index text 1))
    (should (= (proofread-languagetool--utf16-offset-to-index
                text 2)
               1))
    (should (= (proofread-languagetool--utf16-offset-to-index
                text 3)
               2))
    (should-not
     (proofread-languagetool--utf16-offset-to-index text 99))))

(ert-deftest
    proofread-languagetool-test-matches-require-json-array ()
  "Distinguish the response `matches' array from false values."
  (with-temp-buffer
    (let* ((request (proofread-languagetool-test--request))
           (request-data
            (proofread-languagetool--request-data request)))
      (should-not
       (proofread-languagetool--parse-response
        request request-data "{\"matches\":[]}"))
      (dolist (response '( "{\"matches\":null}"
                           "{\"matches\":false}"
                           "{\"matches\":{}}"
                           "{}"))
        (should-error
         (proofread-languagetool--parse-response
          request request-data response))))))

(ert-deftest proofread-languagetool-test-json-keys-are-not-interned ()
  "Unknown response object keys do not grow the Emacs obarray."
  (with-temp-buffer
    (let* ((request (proofread-languagetool-test--request))
           (request-data
            (proofread-languagetool--request-data request))
           (suffix
            (secure-hash
             'sha256
             (format "%s-%s" (float-time) (random))))
           (key (concat "proofread-languagetool-unknown-" suffix))
           (nested-key
            (concat "proofread-languagetool-nested-" suffix))
           (response
            (format
             "{\"matches\":[],\"%s\":{\"%s\":true}}"
             key nested-key)))
      (should-not (intern-soft key))
      (should-not (intern-soft nested-key))
      (should-not
       (proofread-languagetool--parse-response
        request request-data response))
      (should-not (intern-soft key))
      (should-not (intern-soft nested-key)))))

(ert-deftest
    proofread-languagetool-test-matches-filter-context-and-zero-width
    ()
  "Convert matches that stay within the target.
Reject context-only and target-crossing matches."
  (with-temp-buffer
    (let* ((request (proofread-languagetool-test--request))
           (request-data
            (proofread-languagetool--request-data request))
           (payload
            `((matches .
                       (,(proofread-languagetool-test--match
                          0 2 "style" "Context" nil)
                        ,(proofread-languagetool-test--match
                          2 2 "grammar" "Crossing" nil)
                        ,(proofread-languagetool-test--match
                          3 8 "grammar" "Agreement" '( "This is"))
                        ,(proofread-languagetool-test--match
                          3 0 "style" "Insert" '( "Well, "))))))
           (diagnostics
            (proofread-languagetool--parse-response
             request request-data (json-encode payload))))
      (should (= (length diagnostics) 2))
      (let ((agreement (car diagnostics))
            (insertion (cadr diagnostics)))
        (should (= (plist-get agreement :beg) 20))
        (should (= (plist-get agreement :end) 28))
        (should (equal (plist-get agreement :text) "This are"))
        (should (eq (plist-get agreement :kind) 'grammar))
        (should (equal (plist-get agreement :suggestions)
                       '( "This is")))
        (should (= (plist-get insertion :beg) 20))
        (should (= (plist-get insertion :end) 20))
        (should (equal (plist-get insertion :text) ""))))))

(ert-deftest
    proofread-languagetool-test-match-uses-shared-constructor ()
  "Normalize LanguageTool matches before shared construction."
  (with-temp-buffer
    (let* ((request (proofread-languagetool-test--request))
           (request-data
            (proofread-languagetool--request-data request))
           (payload
            `((matches .
                       (,(proofread-languagetool-test--match
                          3 8 "grammar" "Agreement"
                          '( "This is" "This is"))))))
           calls)
      (cl-letf
          (((symbol-function
             'proofread--diagnostic-from-request-relative-range)
            (lambda (actual-request range properties)
              (push (list actual-request range properties) calls)
              'sentinel)))
        (should
         (equal
          (proofread-languagetool--parse-response
           request request-data (json-encode payload))
          '( sentinel))))
      (should
       (equal calls
              (list
               (list request '( 0 . 8)
                     '( :kind grammar
                        :message "Agreement"
                        :suggestions ("This is")
                        :source languagetool))))))))

(ert-deftest proofread-languagetool-test-comment-delimiter-is-safe ()
  "LanguageTool matches cannot edit comment delimiters."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; teh")
    (syntax-propertize (point-max))
    (let* ((request
            (list :beg 1
                  :end 7
                  :text ";; teh"
                  :context-before ""
                  :context-after ""
                  :language "en-US"
                  :target-kind 'comment
                  :buffer (current-buffer)))
           (request-data
            (proofread-languagetool--request-data request))
           (payload
            `((matches .
                       (,(proofread-languagetool-test--match
                          0 2 "typographical" "Delimiter" '( ""))
                        ,(proofread-languagetool-test--match
                          3 3 "misspelling" "Spelling" '( "the"))))))
           (diagnostics
            (proofread-languagetool--parse-response
             request request-data (json-encode payload))))
      (should (= (length diagnostics) 1))
      (should (= (plist-get (car diagnostics) :beg) 4))
      (should (= (plist-get (car diagnostics) :end) 7))
      (should (equal (plist-get (car diagnostics) :text) "teh")))))

;;;; HTTP request lifecycle

(ert-deftest proofread-languagetool-test-ready-server-posts-async ()
  "A ready external server receives an asynchronous POST request."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            call events result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (url callback arguments &optional _silent
                           _inhibit-cookies)
                (let ((buffer
                       (generate-new-buffer " *proofread-lt-http*")))
                  (setq call
                        (list :url url
                              :callback callback
                              :arguments arguments
                              :buffer buffer
                              :method url-request-method
                              :data url-request-data
                              :max-redirections
                              (symbol-value 'url-max-redirections)
                              :headers url-request-extra-headers))
                  buffer))))
          (let ((proofread-request-log-hook
                 (list (lambda (event) (push event events)))))
            (let ((handle
                   (proofread-languagetool--check
                    (proofread-languagetool-test--request
                     :display-language "American English")
                    (lambda (value) (setq result value)))))
              (should (listp handle))
              (should-not result)
              (should (equal (plist-get call :method) "POST"))
              (should (= (plist-get call :max-redirections) 0))
              (proofread-languagetool-test--assert-no-redirects
               (plist-get call :buffer))
              (should (string-suffix-p "/v2/check"
                                       (plist-get call :url)))
              (should (string-match-p "language=en-US"
                                      (plist-get call :data)))
              (should-not
               (string-match-p "American%20English"
                               (plist-get call :data)))
              (proofread-languagetool-test--complete-call
               call 200 "{\"matches\":[]}")
              (should (eq (plist-get result :status) 'ok))
              (should-not (plist-get result :diagnostics))
              (should (plist-get handle :delivered))
              (setq events (nreverse events))
              (should
               (equal (mapcar (lambda (event)
                                (plist-get event :type))
                              events)
                      '( backend-request backend-response
                         backend-result)))
              (let ((request-event (nth 0 events))
                    (response-event (nth 1 events))
                    (result-event (nth 2 events)))
                (should (eq (plist-get request-event :backend)
                            'languagetool))
                (should (equal (plist-get request-event :method)
                               "POST"))
                (let ((parameters
                       (plist-get request-event :parameters)))
                  (should (stringp parameters))
                  (should (string-match-p
                           "language=en-US" parameters))
                  (should-not
                   (string-match-p "American%20English"
                                   parameters))
                  (should (string-match-p
                           (regexp-quote
                            (concat
                             "text=%F0%9F%98%80%20This%20are%20"
                             "fine."))
                           parameters)))
                (should (= (plist-get response-event :http-status)
                           200))
                (should (equal (plist-get response-event :response)
                               "{\"matches\":[]}"))
                (let ((logged-result
                       (plist-get result-event :result)))
                  (should-not (eq logged-result result))
                  (should (eq (plist-get logged-result :status) 'ok))
                  (should-not
                   (plist-get logged-result :diagnostics))
                  (should
                   (equal
                    (plist-get
                     (plist-get logged-result :request) :text)
                    "This are")))))))))))

(ert-deftest proofread-languagetool-test-http-error-is-not-json ()
  "A non-success response produces a bounded backend error."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            (legacy-error-name "languagetool-http-599")
            call events result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer (generate-new-buffer
                               " *proofread-lt-error*")))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer))))
          (let ((proofread-request-log-hook
                 (list (lambda (event) (push event events)))))
            (proofread-languagetool--check
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))
            (should-not (intern-soft legacy-error-name))
            (proofread-languagetool-test--complete-call
             call 599 "Error: invalid language")
            (should (eq (plist-get result :status) 'error))
            (should (eq (plist-get result :error)
                        'languagetool-http-error))
            (should (equal (plist-get result :message)
                           (concat "LanguageTool HTTP status 599: "
                                   "Error: invalid language")))
            (should-not (intern-soft legacy-error-name))
            (let ((response-event
                   (cl-find-if
                    (lambda (event)
                      (eq (plist-get event :type)
                          'backend-response))
                    events)))
              (should (= (plist-get response-event :http-status)
                         599))
              (should (eq (plist-get response-event :error)
                          'languagetool-http-error))
              (should (equal (plist-get response-event :message)
                             "Backend request failed")))))))))

(ert-deftest
    proofread-languagetool-test-http-callback-errors-retain-response ()
  "HTTP callback errors retain bounded response details.
They leave a reachable server ready without scheduling a probe."
  (dolist (http-status '( 400 500))
    (proofread-languagetool-test--with-state
      (with-temp-buffer
        (let* ((proofread-languagetool--server-state 'ready)
               (proofread-languagetool--server-session
                (proofread-languagetool--server-session-snapshot))
               (long-body-p (= http-status 500))
               (body
                (if long-body-p
                    (concat "Internal\nserver\tfailure "
                            (make-string 600 ?x)
                            " tail-marker")
                  "Bad request: unsupported language"))
               call events handle result response-buffer
               (probes 0))
          (cl-letf
              (((symbol-function 'url-retrieve)
                (lambda (_url callback arguments &rest _ignored)
                  (let ((buffer
                         (generate-new-buffer
                          " *proofread-lt-http-callback-error*")))
                    (setq call (list :callback callback
                                     :arguments arguments
                                     :buffer buffer))
                    buffer)))
               ((symbol-function
                 'proofread-languagetool--schedule-probe)
                (lambda (&rest _ignored) (cl-incf probes))))
            (let ((proofread-request-log-hook
                   (list (lambda (event) (push event events)))))
              (setq handle
                    (proofread-languagetool--check
                     (proofread-languagetool-test--request)
                     (lambda (value) (setq result value))))
              (setq response-buffer (plist-get call :buffer))
              (proofread-languagetool-test--complete-call
               call http-status body
               `( :error (error http ,http-status)))
              (should (eq (plist-get result :status) 'error))
              (should (eq (plist-get result :error)
                          'languagetool-http-error))
              (should (= (plist-get result :http-status)
                         http-status))
              (let ((response (plist-get result :response))
                    (message (plist-get result :message)))
                (should (stringp response))
                (should (stringp message))
                (should (<= (string-width response) 500))
                (should (<= (string-width message) 500))
                (should
                 (string-prefix-p
                  (format "LanguageTool HTTP status %d: "
                          http-status)
                  message))
                (if long-body-p
                    (progn
                      (should
                       (string-prefix-p
                        "Internal server failure " response))
                      (should-not (string-match-p "[\n\t]" response))
                      (should-not
                       (string-match-p "tail-marker" response))
                      (should-not
                       (string-match-p "tail-marker" message)))
                  (should (equal response body))
                  (should
                   (equal message
                          (format
                           "LanguageTool HTTP status %d: %s"
                           http-status body)))))
              (should (eq proofread-languagetool--server-state
                          'ready))
              (should (= probes 0))
              (should (plist-get handle :delivered))
              (should-not (buffer-live-p response-buffer))
              (let* ((response-event
                      (cl-find-if
                       (lambda (event)
                         (eq (plist-get event :type)
                             'backend-response))
                       events))
                     (result-event
                      (cl-find-if
                       (lambda (event)
                         (eq (plist-get event :type)
                             'backend-result))
                       events))
                     (logged-result
                      (plist-get result-event :result)))
                (should (= (plist-get response-event :http-status)
                           http-status))
                (should (eq (plist-get response-event :error)
                            'languagetool-http-error))
                (should
                 (equal (plist-get response-event :response)
                        (plist-get result :response)))
                (should
                 (equal (plist-get response-event :message)
                        "Backend request failed"))
                (should (eq (plist-get logged-result :status) 'error))
                (should (eq (plist-get logged-result :error)
                            'languagetool-http-error))
                (should
                 (equal (plist-get logged-result :message)
                        "Backend request failed"))))))))))

(ert-deftest
    proofread-languagetool-test-invalid-http-status-is-transport-error ()
  "Callback errors with invalid HTTP statuses are transport errors."
  (dolist (http-status '( 0 600))
    (proofread-languagetool-test--with-state
      (with-temp-buffer
        (let ((proofread-languagetool--server-state 'ready)
              (proofread-languagetool--server-session
               (proofread-languagetool--server-session-snapshot))
              call result response-buffer)
          (cl-letf
              (((symbol-function 'url-retrieve)
                (lambda (_url callback arguments &rest _ignored)
                  (let ((buffer
                         (generate-new-buffer
                          " *proofread-lt-invalid-http-status*")))
                    (setq call (list :callback callback
                                     :arguments arguments
                                     :buffer buffer))
                    buffer))))
            (proofread-languagetool--check
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))
            (setq response-buffer (plist-get call :buffer))
            (proofread-languagetool-test--complete-call
             call http-status "Unusable response status"
             `( :error (error http ,http-status)))
            (should (eq (plist-get result :status) 'error))
            (should (eq (plist-get result :error)
                        'languagetool-transport-error))
            (should-not (plist-member result :http-status))
            (should (eq proofread-languagetool--server-state
                        'unknown))
            (should-not (buffer-live-p response-buffer))))))))

(ert-deftest
    proofread-languagetool-test-request-timeout-cleans-buffer ()
  "A current timeout invalidates readiness.
A stale timeout leaves readiness unchanged."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            url-buffers current-result stale-result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (&rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-timeout*")))
                  (push buffer url-buffers)
                  buffer))))
          (let ((current-handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  (lambda (value) (setq current-result value)))))
            (proofread-languagetool--request-timeout current-handle)
            (should (eq (plist-get current-result :error)
                        'languagetool-request-timeout))
            (should (eq proofread-languagetool--server-state
                        'unknown))
            (proofread-languagetool--request-timeout current-handle)
            (should (plist-get current-handle :delivered)))
          (setq proofread-languagetool--server-state 'ready)
          (let ((stale-handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  (lambda (value) (setq stale-result value)))))
            (cl-incf proofread-languagetool--server-generation)
            (proofread-languagetool--request-timeout stale-handle)
            (should (eq (plist-get stale-result :error)
                        'languagetool-request-timeout))
            (should (eq proofread-languagetool--server-state
                        'ready)))
          (dolist (buffer url-buffers)
            (should-not (buffer-live-p buffer))))))))

(ert-deftest
    proofread-languagetool-test-sync-submit-error-is-deferred ()
  "A synchronous URL submission failure still calls back later."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            (callbacks 0)
            result)
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (&rest _ignored)
                     (error "Synchronous URL failure"))))
          (let ((handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  (lambda (value)
                    (cl-incf callbacks)
                    (setq result value)))))
            (should-not result)
            (should-not (plist-get handle :delivered))
            (should (memq handle
                          proofread-languagetool--live-handles))
            (should
             (proofread-languagetool-test--wait-for
              (lambda () result)))
            (should (= callbacks 1))
            (should (eq (plist-get result :error)
                        'languagetool-request-error))
            (should-not
             (memq handle proofread-languagetool--live-handles))))))))

;;;; Backend and server teardown

(ert-deftest proofread-languagetool-test-stop-settles-live-handles ()
  "Stopping settles HTTP, waiting, deferred, and reentrant work."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let* ((session
              (proofread-languagetool--server-session-snapshot))
             (proofread-languagetool--server-state 'ready)
             (proofread-languagetool--server-session session)
             (original-kill
              (symbol-function
               'proofread-languagetool--kill-url-buffer))
             call handle reentrant-handle waiting-handle
             deferred-handle
             result reentrant-result waiting-result deferred-result
             scheduled)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer " *proofread-lt-stop*")))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer)))
             ((symbol-function
               'proofread-languagetool--schedule-probe)
              (lambda (&rest _ignored) (setq scheduled t)))
             ((symbol-function
               'proofread-languagetool--kill-url-buffer)
              (lambda (buffer)
                (funcall original-kill buffer)
                (when (and buffer (eq buffer (plist-get call :buffer)))
                  (setq reentrant-handle
                        (proofread-languagetool--check
                         (proofread-languagetool-test--request)
                         (lambda (value)
                           (setq reentrant-result value))))
                  (proofread-languagetool--begin-readiness-check
                   session)))))
          (setq handle
                (proofread-languagetool--check
                 (proofread-languagetool-test--request)
                 (lambda (value) (setq result value))))
          (setq waiting-handle
                (proofread-languagetool--new-handle
                 (proofread-languagetool-test--request)
                 (lambda (value) (setq waiting-result value))))
          (push waiting-handle
                proofread-languagetool--server-waiters)
          (setq deferred-handle
                (proofread-languagetool--new-handle
                 (proofread-languagetool-test--request)
                 (lambda (value) (setq deferred-result value))))
          (proofread-languagetool--deliver-error-later
           deferred-handle 'test-deferred "Deferred")
          (proofread-languagetool-stop-server)
          (dolist (settled-handle
                   (list handle reentrant-handle waiting-handle
                         deferred-handle))
            (should (plist-get settled-handle :delivered))
            (should-not (plist-get settled-handle :cancelled))
            (should-not (plist-get settled-handle :timer)))
          (dolist (settled-result
                   (list result reentrant-result waiting-result
                         deferred-result))
            (should (eq (plist-get settled-result :error)
                        'languagetool-stopped)))
          (should-not scheduled)
          (should-not proofread-languagetool--live-handles)
          (should-not proofread-languagetool--server-waiters)
          (should-not
           (buffer-live-p (plist-get call :buffer)))
          (let ((response
                 (proofread-languagetool-test--response-buffer
                  200 "{\"matches\":[]}")))
            (with-current-buffer response
              (apply (plist-get call :callback)
                     (cons nil (plist-get call :arguments)))))
          (should (eq (plist-get result :error)
                      'languagetool-stopped)))))))

(ert-deftest proofread-languagetool-test-stop-retires-core-request ()
  "Stopping settles the core request lifecycle, not only its handle."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (insert "This are")
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            call result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-core-stop*")))
                  (with-current-buffer buffer
                    (add-hook
                     'kill-buffer-query-functions
                     (lambda () nil) nil t)
                    (add-hook
                     'kill-buffer-hook
                     (lambda () (error "Kill hook failure")) nil t))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer))))
          (let* ((chunk
                  (car
                   (proofread--request-ready-chunks-for-islands
                    (proofread--target-islands-for-ranges
                     (list (cons (point-min) (point-max)))))))
                 (request
                  (proofread--make-backend-request
                   chunk 'languagetool)))
            (should
             (proofread--dispatch-backend-request
              request
              (lambda (value) (setq result value))
              'languagetool))
            (should (proofread--active-request-p request))
            (proofread-languagetool-stop-server)
            (should (eq (plist-get result :error)
                        'languagetool-stopped))
            (should-not (proofread--active-request-p request))
            (should-not proofread--active-requests)
            (should-not proofread-languagetool--live-handles)
            (should-not proofread-languagetool--server-waiters)
            (should-not (buffer-live-p (plist-get call :buffer)))))))))

(ert-deftest proofread-languagetool-test-teardown-clears-lifecycle ()
  "Teardown releases every readiness and owned-process resource."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 4)
           (proofread-languagetool--server-state 'starting)
           (proofread-languagetool--server-process 'owned-process)
           (proofread-languagetool--server-process-session session)
           (proofread-languagetool--force-start-p t)
           (proofread-languagetool--startup-timer
            (run-at-time 60 nil #'ignore))
           (proofread-languagetool--probe-retry-timer
            (run-at-time 60 nil #'ignore))
           (proofread-languagetool--probe-retry-token '( retry))
           (proofread-languagetool--probe-timeout-timer
            (run-at-time 60 nil #'ignore))
           (probe-buffer
            (generate-new-buffer " *proofread-lt-teardown*"))
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value))))
           deleted)
      (setq proofread-languagetool--probe-buffer probe-buffer)
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf
          (((symbol-function 'process-live-p)
            (lambda (process) (eq process 'owned-process)))
           ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
           ((symbol-function 'delete-process)
            (lambda (process) (setq deleted process))))
        (proofread-languagetool--teardown
         'languagetool-test-stop "Test stop"))
      (should (= proofread-languagetool--server-generation 5))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not (buffer-live-p probe-buffer))
      (should (eq deleted 'owned-process))
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should-not proofread-languagetool--server-session)
      (should-not proofread-languagetool--force-start-p)
      (should-not proofread-languagetool--server-waiters)
      (should-not proofread-languagetool--live-handles)
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-test-stop)))))

(ert-deftest proofread-languagetool-test-unload-kills-server-log ()
  "Unloading kills the managed log despite buffer kill hooks."
  (let ((buffer
         (get-buffer-create
          proofread-languagetool--server-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (add-hook 'kill-buffer-query-functions
                      (lambda () nil) nil t)
            (add-hook 'kill-buffer-hook
                      (lambda () (error "Kill hook failure")) nil t))
          (cl-letf (((symbol-function 'remove-hook) #'ignore)
                    ((symbol-function 'proofread-unregister-backend)
                     #'ignore)
                    ((symbol-function
                      'proofread-languagetool--teardown)
                     #'ignore))
            (proofread-languagetool-unload-function))
          (should-not (buffer-live-p buffer)))
      (proofread-languagetool--kill-url-buffer buffer))))

(ert-deftest
    proofread-languagetool-test-failing-waiter-does-not-orphan-next ()
  "One signaling callback cannot prevent later waiter settlement."
  (proofread-languagetool-test--with-state
    (let* ((bad
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (_value) (error "Callback failure"))))
           good-result
           (good
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq good-result value)))))
      (setq proofread-languagetool--server-waiters
            (list good bad))
      (proofread-languagetool--fail-waiters
       'languagetool-test-error "Test error")
      (should (plist-get bad :delivered))
      (should (plist-get good :delivered))
      (should (eq (plist-get good-result :error)
                  'languagetool-test-error))
      (should-not proofread-languagetool--server-waiters)
      (should-not proofread-languagetool--live-handles))))

;;;; Server sessions and readiness

(ert-deftest
    proofread-languagetool-test-waiter-uses-check-time-snapshot ()
  "A waiting request posts the options and endpoint it captured."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool-server-url
             "http://127.0.0.1:18081/v2")
            (proofread-languagetool-level 'default)
            calls result handle)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-snapshot*")))
                  (setq calls
                        (append calls
                                (list (list :url url
                                            :callback callback
                                            :arguments arguments
                                            :buffer buffer
                                            :method url-request-method
                                            :data url-request-data))))
                  buffer))))
          (setq handle
                (proofread-languagetool--check
                 (proofread-languagetool-test--request)
                 (lambda (value) (setq result value))))
          (setq proofread-languagetool-server-url
                "http://127.0.0.1:18082/v2")
          (setq proofread-languagetool-level 'picky)
          (setq proofread-languagetool-command "changed-command")
          (setq proofread-languagetool-config-file
                "/tmp/changed-language-tool.properties")
          (proofread-languagetool-test--run-scheduled-probe)
          (proofread-languagetool-test--complete-call
           (car calls) 200 "OK")
          (should (= (length calls) 2))
          (let ((post (cadr calls)))
            (should (equal (plist-get post :method) "POST"))
            (should
             (string-prefix-p
              "http://127.0.0.1:18081/v2/check"
              (plist-get post :url)))
            (should (string-match-p "level=default"
                                    (plist-get post :data)))
            (should-not (string-match-p "level=picky"
                                        (plist-get post :data))))
          (should
           (equal (plist-get (plist-get handle :session) :base-url)
                  "http://127.0.0.1:18081/v2"))
          (proofread-languagetool-test--complete-call
           (cadr calls) 200 "{\"matches\":[]}")
          (should (eq (plist-get result :status) 'ok)))))))

(ert-deftest
    proofread-languagetool-test-session-change-invalidates-ready ()
  "Changing URL, config, or command invalidates a ready session."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let* ((proofread-languagetool-server-url
              "http://127.0.0.1:18081/v2")
             (proofread-languagetool-auto-start t)
             (old-session
              (proofread-languagetool--server-session-snapshot))
             (proofread-languagetool--server-state 'ready)
             (proofread-languagetool--server-session old-session)
             (proofread-languagetool--server-process 'old-process)
             (proofread-languagetool--server-process-session
              old-session)
             calls deleted result)
        (setq proofread-languagetool-server-url
              "http://127.0.0.1:18082/v2")
        (setq proofread-languagetool-command "new-command")
        (setq proofread-languagetool-config-file
              "/tmp/new-language-tool.properties")
        (cl-letf
            (((symbol-function 'process-live-p)
              (lambda (process) (eq process 'old-process)))
             ((symbol-function 'set-process-query-on-exit-flag)
              #'ignore)
             ((symbol-function 'delete-process)
              (lambda (process) (setq deleted process)))
             ((symbol-function 'make-process)
              (lambda (&rest _ignored)
                (ert-fail
                 "A healthy changed endpoint was not reused")))
             ((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-session-change*")))
                  (setq calls
                        (append calls
                                (list (list :url url
                                            :callback callback
                                            :arguments arguments
                                            :buffer buffer
                                            :method url-request-method
                                            :max-redirections
                                            (symbol-value
                                             'url-max-redirections)))))
                  buffer))))
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq result value)))
          (should (eq deleted 'old-process))
          (should (eq proofread-languagetool--server-state 'probing))
          (should-not calls)
          (proofread-languagetool-test--run-scheduled-probe)
          (should (= (length calls) 1))
          (should (equal (plist-get (car calls) :method) "GET"))
          (should (= (plist-get (car calls) :max-redirections) 0))
          (proofread-languagetool-test--assert-no-redirects
           (plist-get (car calls) :buffer))
          (should
           (string-prefix-p
            "http://127.0.0.1:18082/v2/healthcheck"
            (plist-get (car calls) :url)))
          (proofread-languagetool-test--complete-call
           (car calls) 200 "OK")
          (should (= (length calls) 2))
          (should (equal (plist-get (cadr calls) :method) "POST"))
          (should (= (plist-get (cadr calls) :max-redirections) 0))
          (proofread-languagetool-test--assert-no-redirects
           (plist-get (cadr calls) :buffer))
          (proofread-languagetool-test--complete-call
           (cadr calls) 200 "{\"matches\":[]}")
          (should (eq (plist-get result :status) 'ok)))))))

(ert-deftest
    proofread-languagetool-test-session-identity-covers-lifecycle ()
  "Server identity includes every managed-process lifecycle option."
  (let* ((proofread-languagetool-auto-start t)
         (base (proofread-languagetool--server-session-snapshot)))
    (let ((proofread-languagetool-server-url
           "http://127.0.0.1:18082/v2"))
      (should-not
       (proofread-languagetool--same-session-p
        base (proofread-languagetool--server-session-snapshot))))
    (let ((proofread-languagetool-config-file
           "/tmp/another-language-tool.properties"))
      (should-not
       (proofread-languagetool--same-session-p
        base (proofread-languagetool--server-session-snapshot))))
    (let ((proofread-languagetool-command "another-command"))
      (should-not
       (proofread-languagetool--same-session-p
        base (proofread-languagetool--server-session-snapshot))))
    (let ((proofread-languagetool-auto-start
           (not proofread-languagetool-auto-start)))
      (should-not
       (proofread-languagetool--same-session-p
        base (proofread-languagetool--server-session-snapshot))))
    (let ((proofread-languagetool-startup-timeout 99))
      (should-not
       (proofread-languagetool--same-session-p
        base (proofread-languagetool--server-session-snapshot))))
    (let ((proofread-languagetool-health-timeout 7.5))
      (let ((changed
             (proofread-languagetool--server-session-snapshot)))
        (should-not
         (proofread-languagetool--same-session-p base changed))
        (should (= (plist-get changed :health-timeout) 7.5))))
    (let ((proofread-languagetool-health-timeout 0))
      (should-error
       (proofread-languagetool--server-session-snapshot)))
    (let ((proofread-languagetool-request-timeout 99))
      (let ((changed
             (proofread-languagetool--server-session-snapshot)))
        (should
         (proofread-languagetool--same-session-p base changed))
        (should (= (plist-get changed :request-timeout) 99))))))

(ert-deftest proofread-languagetool-test-probe-uses-health-timeout ()
  "A health probe uses the timeout captured in its server session."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-health-timeout 7.5)
           (session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (token (list 'probe-token))
           buffer armed-delay)
      (setq proofread-languagetool--probe-retry-token token)
      (cl-letf
          (((symbol-function 'url-retrieve)
            (lambda (&rest _ignored)
              (setq buffer
                    (generate-new-buffer
                     " *proofread-lt-health-timeout*"))))
           ((symbol-function 'run-at-time)
            (lambda (delay &rest _ignored)
              (setq armed-delay delay)
              'proofread-languagetool-test-timer)))
        (proofread-languagetool--run-probe
         1 'external session token))
      (should (= armed-delay 7.5))
      (proofread-languagetool--kill-url-buffer buffer))))

(ert-deftest
    proofread-languagetool-test-probe-schedule-error-is-atomic ()
  "A timer error cannot publish half of a scheduled health probe."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest _ignored)
                   (error "Timer creation failed"))))
        (should-error
         (proofread-languagetool--schedule-probe
          1 'external session 0)))
      (should-not proofread-languagetool--probe-retry-timer)
      (should-not proofread-languagetool--probe-retry-token))))

(ert-deftest
    proofread-languagetool-test-probe-schedule-error-rolls-back ()
  "A probe scheduling error leaves readiness retryable."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'unknown)
           (proofread-languagetool--force-start-p t)
           result
           scheduled
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf
          (((symbol-function 'proofread-languagetool--schedule-probe)
            (lambda (&rest _ignored)
              (error "Timer creation failed"))))
        (should-error
         (proofread-languagetool--begin-readiness-check session)))
      (should (eq proofread-languagetool--server-state 'unknown))
      (should-not proofread-languagetool--force-start-p)
      (should-not proofread-languagetool--server-waiters)
      (should (eq (plist-get result :error)
                  'languagetool-unavailable))
      (proofread-languagetool-test--assert-no-readiness-work)
      (cl-letf
          (((symbol-function 'proofread-languagetool--schedule-probe)
            (lambda (generation phase candidate delay)
              (setq scheduled
                    (list generation phase candidate delay)))))
        (proofread-languagetool--begin-readiness-check session))
      (should (eq proofread-languagetool--server-state 'probing))
      (should
       (equal scheduled
              (list proofread-languagetool--server-generation
                    'external session 0))))))

(ert-deftest
    proofread-languagetool-test-probe-timeout-setup-cleans-buffer ()
  "A probe timeout timer error cannot leak its retrieval buffer."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (token (list 'probe-token))
           buffer)
      (setq proofread-languagetool--probe-retry-token token)
      (cl-letf
          (((symbol-function 'url-retrieve)
            (lambda (&rest _ignored)
              (setq buffer
                    (generate-new-buffer
                     " *proofread-lt-probe-timer-error*"))))
           ((symbol-function 'run-at-time)
            (lambda (&rest _ignored)
              (error "Timer creation failed"))))
        (proofread-languagetool--run-probe
         1 'external session token))
      (should (eq proofread-languagetool--server-state 'unknown))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not (buffer-live-p buffer)))))

(ert-deftest
    proofread-languagetool-test-probe-timeout-cleans-attempt ()
  "A current health-probe timeout releases and fails its attempt."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (proofread-languagetool--probe-timeout-timer
            (run-at-time 60 nil #'ignore))
           (buffer
            (generate-new-buffer " *proofread-lt-probe-timeout*"))
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--probe-buffer buffer)
      (setq proofread-languagetool--server-waiters (list waiter))
      (proofread-languagetool--probe-timeout
       1 'external session buffer)
      (should (= proofread-languagetool--server-generation 2))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not (buffer-live-p buffer))
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-unavailable)))))

(ert-deftest
    proofread-languagetool-test-rejects-buffer-local-session-option ()
  "The server manager rejects buffer-local settings when they apply."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (setq-local proofread-languagetool-server-url
                  "http://127.0.0.1:18082/v2")
      (let (result)
        (proofread-languagetool--check
         (proofread-languagetool-test--request)
         (lambda (value) (setq result value)))
        (should-not result)
        (should
         (proofread-languagetool-test--wait-for
          (lambda () result)))
        (should (eq (plist-get result :error)
                    'languagetool-configuration-error))
        (should (string-match-p "must not be buffer-local"
                                (plist-get result :message)))
        (should-not proofread-languagetool--probe-retry-timer)
        (should-not proofread-languagetool--server-waiters))))
  (with-temp-buffer
    (setq-local proofread-languagetool-health-timeout 7.5)
    (should-error
     (proofread-languagetool--server-session-snapshot)))
  (with-temp-buffer
    (setq-local proofread-languagetool-command 42)
    (let ((proofread-languagetool-auto-start nil))
      (should (proofread-languagetool--server-session-snapshot))
      (should-error
       (proofread-languagetool--server-session-snapshot nil t)))
    (let ((proofread-languagetool-auto-start t))
      (should-error
       (proofread-languagetool--server-session-snapshot)))))

(ert-deftest
    proofread-languagetool-test-snapshots-in-request-buffer ()
  "Request-local options are captured from the request's buffer."
  (proofread-languagetool-test--with-state
    (let ((source (generate-new-buffer " *proofread-lt-source*"))
          (caller (generate-new-buffer " *proofread-lt-caller*"))
          request call handle dead-result)
      (unwind-protect
          (progn
            (with-current-buffer source
              (setq-local proofread-languagetool-level 'picky)
              (setq-local proofread-languagetool-request-timeout 23)
              (setq request
                    (proofread-languagetool-test--request)))
            (with-current-buffer caller
              (setq-local proofread-languagetool-level 'default)
              (setq-local proofread-languagetool-request-timeout 7)
              (let ((proofread-languagetool--server-state 'ready)
                    (proofread-languagetool--server-session
                     (proofread-languagetool--server-session-snapshot)))
                (cl-letf
                    (((symbol-function 'url-retrieve)
                      (lambda (_url _callback _arguments
                                    &rest _ignored)
                        (setq call
                              (list :data url-request-data
                                    :buffer
                                    (generate-new-buffer
                                     " *proofread-lt-source-request*")))
                        (plist-get call :buffer))))
                  (setq handle
                        (proofread-languagetool--check
                         request #'ignore)))))
            (should (string-match-p "level=picky"
                                    (plist-get call :data)))
            (should (= (plist-get (plist-get handle :session)
                                  :request-timeout)
                       23))
            (proofread-languagetool--cancel handle)
            (kill-buffer source)
            (with-current-buffer caller
              (proofread-languagetool--check
               request (lambda (value) (setq dead-result value))))
            (should-not dead-result)
            (should
             (proofread-languagetool-test--wait-for
              (lambda () dead-result)))
            (should (eq (plist-get dead-result :error)
                        'languagetool-configuration-error)))
        (when (buffer-live-p source) (kill-buffer source))
        (when (buffer-live-p caller) (kill-buffer caller))))))

(ert-deftest
    proofread-languagetool-test-manual-start-forces-active-probe ()
  "Manual start replaces an external probe with a managed snapshot."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (proofread-languagetool-config-file nil)
           (proofread-languagetool-command "languagetool-http-server")
           (proofread-languagetool-startup-timeout 15.0)
           (session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           scheduled
           started)
      (cl-letf
          (((symbol-function
             'proofread-languagetool--start-managed-server)
            (lambda (generation candidate)
              (setq started (list generation candidate))))
           ((symbol-function 'proofread-languagetool--schedule-probe)
            (lambda (generation phase candidate delay)
              (setq scheduled
                    (list generation phase candidate delay)))))
        (proofread-languagetool-start-server)
        (should proofread-languagetool--force-start-p)
        (should (= proofread-languagetool--server-generation 2))
        (should
         (proofread-languagetool--same-session-p
          session proofread-languagetool--server-session))
        (dolist (key '( :command :config-file :startup-timeout
                        :managed-identity))
          (should (plist-member proofread-languagetool--server-session
                                key)))
        (should
         (equal scheduled
                (list 2 'external
                      proofread-languagetool--server-session 0)))
        (proofread-languagetool--probe-failed
         1 'external session)
        (should-not started)
        (proofread-languagetool--probe-failed
         2 'external proofread-languagetool--server-session)
        (should
         (equal started
                (list 2 proofread-languagetool--server-session)))))))

(ert-deftest
    proofread-languagetool-test-manual-start-replaces-changed-owned-process ()
  "Manual start replaces an owned process.
Replacement occurs when managed settings have changed."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (proofread-languagetool-config-file nil)
           (proofread-languagetool-command "old-command")
           (proofread-languagetool-startup-timeout 15.0)
           (old-session
            (proofread-languagetool--server-session-snapshot nil t))
           (proofread-languagetool--server-state 'ready)
           (proofread-languagetool--server-session old-session)
           (proofread-languagetool--server-process 'owned-process)
           (proofread-languagetool--server-process-session old-session)
           deleted
           scheduled)
      (setq proofread-languagetool-command "new-command")
      (cl-letf
          (((symbol-function 'process-live-p)
            (lambda (process) (eq process 'owned-process)))
           ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
           ((symbol-function 'delete-process)
            (lambda (process) (setq deleted process)))
           ((symbol-function 'proofread-languagetool--schedule-probe)
            (lambda (generation phase session delay)
              (setq scheduled
                    (list generation phase session delay)))))
        (proofread-languagetool-start-server))
      (should (eq deleted 'owned-process))
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should proofread-languagetool--force-start-p)
      (should (eq proofread-languagetool--server-state 'probing))
      (should (= proofread-languagetool--server-generation 1))
      (should
       (proofread-languagetool--same-session-p
        old-session proofread-languagetool--server-session))
      (should-not
       (proofread-languagetool--same-managed-session-p
        old-session proofread-languagetool--server-session))
      (should
       (equal scheduled
              (list 1 'external
                    proofread-languagetool--server-session 0))))))

(ert-deftest
    proofread-languagetool-test-repeated-manual-start-is-idempotent ()
  "Repeated manual start keeps an equivalent managed probe in flight."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (proofread-languagetool-config-file nil)
           (proofread-languagetool-command "languagetool-http-server")
           (proofread-languagetool-startup-timeout 15.0)
           (session
            (proofread-languagetool--server-session-snapshot nil t))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing))
      (cl-letf
          (((symbol-function
             'proofread-languagetool--begin-readiness-check)
            (lambda (&rest _ignored)
              (ert-fail "Equivalent managed probe was restarted"))))
        (proofread-languagetool-start-server))
      (should proofread-languagetool--force-start-p)
      (should (= proofread-languagetool--server-generation 1))
      (should (eq proofread-languagetool--server-session session)))))

(ert-deftest
    proofread-languagetool-test-stale-probe-keeps-current-timer ()
  "A stale probe callback cannot clear a newer probe's resources."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 2)
           (proofread-languagetool--server-state 'probing)
           (old-buffer
            (proofread-languagetool-test--response-buffer 200 "OK"))
           (current-buffer
            (generate-new-buffer " *proofread-lt-current-probe*"))
           (current-timer (run-at-time 60 nil #'ignore)))
      (setq proofread-languagetool--probe-buffer current-buffer)
      (setq proofread-languagetool--probe-timeout-timer current-timer)
      (with-current-buffer old-buffer
        (proofread-languagetool--probe-response
         nil 1 'external session))
      (should-not (buffer-live-p old-buffer))
      (should (eq proofread-languagetool--probe-buffer
                  current-buffer))
      (should (eq proofread-languagetool--probe-timeout-timer
                  current-timer))
      (should (eq proofread-languagetool--server-state 'probing)))))

(ert-deftest
    proofread-languagetool-test-malformed-probe-is-contained ()
  "A malformed probe body fails once.
The failure does not escape or leak state."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (buffer
            (proofread-languagetool-test--response-buffer 200 "OK"))
           (timer (run-at-time 60 nil #'ignore))
           (failures 0))
      (with-current-buffer buffer
        (set (make-local-variable 'url-http-end-of-headers)
             (+ (point-max) 100)))
      (setq proofread-languagetool--probe-buffer buffer)
      (setq proofread-languagetool--probe-timeout-timer timer)
      (cl-letf
          (((symbol-function 'proofread-languagetool--probe-failed)
            (lambda (_generation _phase _session)
              (cl-incf failures))))
        (with-current-buffer buffer
          (proofread-languagetool--probe-response
           nil 1 'external session)))
      (should (= failures 1))
      (should-not (buffer-live-p buffer))
      (should-not proofread-languagetool--probe-buffer)
      (should-not proofread-languagetool--probe-timeout-timer))))

(ert-deftest
    proofread-languagetool-test-health-probe-requires-exact-ok ()
  "A successful health probe requires the complete trimmed body `OK'."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (buffer
            (proofread-languagetool-test--response-buffer
             200 " OK-but-not-healthy\n"))
           (timer (run-at-time 60 nil #'ignore))
           (failures 0))
      (setq proofread-languagetool--probe-buffer buffer)
      (setq proofread-languagetool--probe-timeout-timer timer)
      (cl-letf
          (((symbol-function 'proofread-languagetool--probe-failed)
            (lambda (_generation _phase _session)
              (cl-incf failures)))
           ((symbol-function 'proofread-languagetool--server-ready)
            (lambda (&rest _ignored)
              (ert-fail "A prefixed health response was accepted"))))
        (with-current-buffer buffer
          (proofread-languagetool--probe-response
           nil 1 'external session)))
      (should (= failures 1))
      (should-not (buffer-live-p buffer))
      (should-not proofread-languagetool--probe-buffer)
      (should-not proofread-languagetool--probe-timeout-timer))))

(ert-deftest
    proofread-languagetool-test-malformed-check-is-contained ()
  "Malformed check responses clean resources and deliver one error."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            call (callbacks 0) result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-malformed-check*")))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer))))
          (let ((handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  (lambda (value)
                    (cl-incf callbacks)
                    (setq result value)))))
            (with-current-buffer (plist-get call :buffer)
              (set (make-local-variable 'url-http-response-status)
                   200)
              (set (make-local-variable 'url-http-end-of-headers)
                   (+ (point-max) 100))
              (apply (plist-get call :callback)
                     (cons nil (plist-get call :arguments))))
            (should (= callbacks 1))
            (should (eq (plist-get result :error)
                        'languagetool-invalid-response))
            (should (plist-get handle :delivered))
            (should-not (plist-get handle :timer))
            (should-not
             (buffer-live-p (plist-get call :buffer)))
            (let ((stale
                   (proofread-languagetool-test--response-buffer
                    200 "{\"matches\":[]}")))
              (with-current-buffer stale
                (apply (plist-get call :callback)
                       (cons nil (plist-get call :arguments)))))
            (proofread-languagetool--request-timeout handle)
            (should (= callbacks 1))))))))

(ert-deftest
    proofread-languagetool-test-malformed-http-200-is-invalid-response ()
  "Malformed JSON in an HTTP 200 response is invalid response data."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            (body "{\"matches\": [")
            call events handle result response-buffer
            (probes 0))
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-malformed-http-200*")))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer)))
             ((symbol-function
               'proofread-languagetool--schedule-probe)
              (lambda (&rest _ignored) (cl-incf probes))))
          (let ((proofread-request-log-hook
                 (list (lambda (event) (push event events)))))
            (setq handle
                  (proofread-languagetool--check
                   (proofread-languagetool-test--request)
                   (lambda (value) (setq result value))))
            (setq response-buffer (plist-get call :buffer))
            (proofread-languagetool-test--complete-call
             call 200 body)
            (should (eq (plist-get result :status) 'error))
            (should (eq (plist-get result :error)
                        'languagetool-invalid-response))
            (should (stringp (plist-get result :message)))
            (should-not
             (string-empty-p (plist-get result :message)))
            (should (eq proofread-languagetool--server-state 'ready))
            (should (= probes 0))
            (should (plist-get handle :delivered))
            (should-not (buffer-live-p response-buffer))
            (let* ((response-event
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-response))
                     events))
                   (result-event
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-result))
                     events))
                   (logged-result
                    (plist-get result-event :result)))
              (should (= (plist-get response-event :http-status)
                         200))
              (should (equal (plist-get response-event :response)
                             body))
              (should (eq (plist-get logged-result :status) 'error))
              (should (eq (plist-get logged-result :error)
                          'languagetool-invalid-response))
              (should
               (equal (plist-get logged-result :message)
                      "Backend request failed")))))))))

(ert-deftest
    proofread-languagetool-test-url-rejects-secrets-and-controls ()
  "Unsafe URLs are rejected without exposing them through identity."
  (dolist (url
           '( "http://secret-user:hunter2@127.0.0.1:8081/v2"
              "http://:hunter2@127.0.0.1:8081/v2"
              "http://127.0.0.1:8081/v2\nAuthorization:hunter2"
              "http://127.0.0.1:8081/v2\t"
              "http://127.0.0.1:8081/%0d%0a/v2"
              "http://127.0.0.1:99999/v2"))
    (let ((proofread-languagetool-server-url url))
      (should-error
       (proofread-languagetool--normalized-server-url))
      (let ((printed (prin1-to-string
                      (proofread-languagetool--identity))))
        (should-not (string-match-p "hunter2" printed))
        (should-not (string-match-p "secret-user" printed)))))
  (let* ((proofread-languagetool-config-file
          "/tmp/private-token-language-tool.properties")
         (printed
          (prin1-to-string (proofread-languagetool--identity))))
    (should-not (string-match-p "private-token" printed))))

(ert-deftest
    proofread-languagetool-test-transport-reprobes-owned-process ()
  "A transport failure reprobes an owned process.
The reprobe never overwrites the process."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let* ((session
              (proofread-languagetool--server-session-snapshot))
             (proofread-languagetool--server-state 'ready)
             (proofread-languagetool--server-session session)
             (proofread-languagetool--server-process 'owned-process)
             (proofread-languagetool--server-process-session session)
             calls events first-result second-result make-count
             first-buffer)
        (cl-letf
            (((symbol-function 'process-live-p)
              (lambda (process) (eq process 'owned-process)))
             ((symbol-function 'make-process)
              (lambda (&rest _ignored)
                (cl-incf make-count)
                'replacement-process))
             ((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-owned-process*")))
                  (setq calls
                        (append calls
                                (list (list :url url
                                            :callback callback
                                            :arguments arguments
                                            :buffer buffer
                                            :method
                                            url-request-method))))
                  buffer))))
          (let ((proofread-request-log-hook
                 (list (lambda (event) (push event events)))))
            (proofread-languagetool--check
             (proofread-languagetool-test--request)
             (lambda (value) (setq first-result value)))
            (setq first-buffer (plist-get (car calls) :buffer))
            (with-current-buffer first-buffer
              (apply
               (plist-get (car calls) :callback)
               (cons
                '( :error
                   (error connection-failed
                          "failed with code 111\n"
                          :host "127.0.0.1"
                          :service 8081))
                (plist-get (car calls) :arguments)))))
          (should (eq (plist-get first-result :error)
                      'languagetool-transport-error))
          (should-not (plist-member first-result :http-status))
          (should-not (plist-member first-result :response))
          (should (string-match-p
                   "connection-failed"
                   (plist-get first-result :message)))
          (should (<= (string-width
                       (plist-get first-result :message))
                      500))
          (should-not (buffer-live-p first-buffer))
          (let* ((response-event
                  (cl-find-if
                   (lambda (event)
                     (eq (plist-get event :type)
                         'backend-response))
                   events))
                 (result-event
                  (cl-find-if
                   (lambda (event)
                     (eq (plist-get event :type)
                         'backend-result))
                   events))
                 (logged-result (plist-get result-event :result)))
            (should-not (plist-get response-event :http-status))
            (should-not (plist-get response-event :response))
            (should (eq (plist-get response-event :error)
                        'languagetool-transport-error))
            (should
             (equal (plist-get response-event :message)
                    "Backend request failed"))
            (should (eq (plist-get logged-result :error)
                        'languagetool-transport-error)))
          (should (eq proofread-languagetool--server-state 'unknown))
          (should (eq proofread-languagetool--server-process
                      'owned-process))
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq second-result value)))
          (proofread-languagetool-test--run-scheduled-probe)
          (proofread-languagetool-test--complete-call
           (cadr calls) 503 "Unavailable")
          (should-not second-result)
          (should-not make-count)
          (should (eq proofread-languagetool--server-process
                      'owned-process))
          (should (eq proofread-languagetool--server-state
                      'starting)))))))

(ert-deftest
    proofread-languagetool-test-startup-timeout-clears-retry ()
  "Startup timeout invalidates every outstanding readiness resource."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'starting)
           (proofread-languagetool--server-process 'owned-process)
           (proofread-languagetool--server-process-session session)
           (proofread-languagetool--force-start-p t)
           (startup (run-at-time 60 nil #'ignore))
           (retry (run-at-time 60 nil #'ignore))
           (probe-timeout (run-at-time 60 nil #'ignore))
           (probe-buffer
            (generate-new-buffer " *proofread-lt-startup-timeout*"))
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value))))
           deleted)
      (setq proofread-languagetool--startup-timer startup)
      (setq proofread-languagetool--probe-retry-timer retry)
      (setq proofread-languagetool--probe-retry-token '( retry))
      (setq proofread-languagetool--probe-timeout-timer probe-timeout)
      (setq proofread-languagetool--probe-buffer probe-buffer)
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf
          (((symbol-function 'process-live-p)
            (lambda (process) (eq process 'owned-process)))
           ((symbol-function 'set-process-query-on-exit-flag)
            #'ignore)
           ((symbol-function 'delete-process)
            (lambda (process) (setq deleted process))))
        (proofread-languagetool--startup-timeout 1 session))
      (should (eq deleted 'owned-process))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not (buffer-live-p probe-buffer))
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should-not proofread-languagetool--force-start-p)
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-startup-timeout)))))

(ert-deftest
    proofread-languagetool-test-start-error-cleans-lifecycle ()
  "A synchronous managed-start error releases its entire attempt."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (proofread-languagetool--force-start-p t)
           (timer-calls 0)
           deleted
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf
          (((symbol-function 'proofread-languagetool--server-command)
            (lambda (_session) '( "languagetool-http-server")))
           ((symbol-function 'proofread-languagetool--server-arguments)
            (lambda (_session) nil))
           ((symbol-function 'get-buffer-create) (lambda (_name) nil))
           ((symbol-function 'make-process)
            (lambda (&rest _ignored) 'new-process))
           ((symbol-function 'process-live-p)
            (lambda (process) (eq process 'new-process)))
           ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
           ((symbol-function 'delete-process)
            (lambda (process) (setq deleted process)))
           ((symbol-function 'run-at-time)
            (lambda (&rest _ignored)
              (cl-incf timer-calls)
              (if (= timer-calls 1)
                  'startup-timer
                (error "Timer creation failed")))))
        (proofread-languagetool--start-managed-server 1 session))
      (should (= timer-calls 2))
      (should (eq deleted 'new-process))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should-not proofread-languagetool--force-start-p)
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-startup-error)))))

(ert-deftest
    proofread-languagetool-test-dead-startup-process-is-forgotten ()
  "A failed startup probe immediately forgets its dead owned process."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'starting)
           (proofread-languagetool--server-process 'dead-process)
           (proofread-languagetool--server-process-session session)
           (proofread-languagetool--force-start-p t)
           (proofread-languagetool--startup-timer
            (run-at-time 60 nil #'ignore))
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf (((symbol-function 'process-live-p)
                 (lambda (_process) nil)))
        (proofread-languagetool--probe-failed
         1 'startup session))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should-not proofread-languagetool--force-start-p)
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-startup-failed)))))

;;;; Process and cancellation lifecycle

(ert-deftest proofread-languagetool-test-server-log-follows-at-end ()
  "Server output follows appended text when point was at the end."
  (let* ((proofread-languagetool--log-limit 8)
         (snapshot
          (proofread-languagetool-test--server-log-snapshot 'end)))
    (should (equal (plist-get snapshot :text) "efghijkl"))
    (should (= (plist-get snapshot :point)
               (plist-get snapshot :point-max)))))

(ert-deftest
    proofread-languagetool-test-server-log-preserves-retained-point ()
  "Server output preserves point within text retained after truncation."
  (let* ((proofread-languagetool--log-limit 8)
         (snapshot
          (proofread-languagetool-test--server-log-snapshot 6)))
    (should (equal (plist-get snapshot :text) "efghijkl"))
    (should (< (plist-get snapshot :point)
               (plist-get snapshot :point-max)))
    (should (equal (plist-get snapshot :following) "ghijkl"))))

(ert-deftest
    proofread-languagetool-test-server-log-clamps-truncated-point ()
  "Server output clamps point whose previous text was truncated."
  (let* ((proofread-languagetool--log-limit 8)
         (snapshot
          (proofread-languagetool-test--server-log-snapshot 1)))
    (should (equal (plist-get snapshot :text) "efghijkl"))
    (should (= (plist-get snapshot :point)
               (plist-get snapshot :point-min)))
    (should (equal (plist-get snapshot :following) "efghijkl"))))

(ert-deftest
    proofread-languagetool-test-starting-process-exit-cleans-lifecycle
    ()
  "A starting process exit invalidates and settles its whole attempt."
  (proofread-languagetool-test--with-state
    (let* ((session
            (proofread-languagetool--server-session-snapshot))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'starting)
           (proofread-languagetool--server-process 'owned-process)
           (proofread-languagetool--server-process-session session)
           (proofread-languagetool--force-start-p t)
           (proofread-languagetool--startup-timer
            (run-at-time 60 nil #'ignore))
           (proofread-languagetool--probe-retry-timer
            (run-at-time 60 nil #'ignore))
           (proofread-languagetool--probe-retry-token '( retry))
           (proofread-languagetool--probe-timeout-timer
            (run-at-time 60 nil #'ignore))
           (probe-buffer
            (generate-new-buffer " *proofread-lt-process-exit*"))
           result
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--probe-buffer probe-buffer)
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf (((symbol-function 'process-status)
                 (lambda (_process) 'exit))
                ((symbol-function 'process-exit-status)
                 (lambda (_process) 23)))
        (proofread-languagetool--process-sentinel
         'owned-process "exited"))
      (should (= proofread-languagetool--server-generation 2))
      (proofread-languagetool-test--assert-no-readiness-work)
      (should-not (buffer-live-p probe-buffer))
      (should-not proofread-languagetool--server-process)
      (should-not proofread-languagetool--server-process-session)
      (should-not proofread-languagetool--force-start-p)
      (should (eq proofread-languagetool--server-state 'unknown))
      (should (eq (plist-get result :error)
                  'languagetool-startup-failed)))))

(ert-deftest
    proofread-languagetool-test-probing-process-exit-restarts-readiness ()
  "A probing process exit invalidates its readiness attempt.
It then restarts readiness for the current session."
  (proofread-languagetool-test--with-state
    (let* ((proofread-languagetool-auto-start nil)
           (session
            (proofread-languagetool--server-session-snapshot nil t))
           (proofread-languagetool--server-session session)
           (proofread-languagetool--server-generation 1)
           (proofread-languagetool--server-state 'probing)
           (proofread-languagetool--server-process 'owned-process)
           (proofread-languagetool--server-process-session session)
           (proofread-languagetool--force-start-p t)
           (proofread-languagetool--probe-timeout-timer
            (run-at-time 60 nil #'ignore))
           (probe-buffer
            (generate-new-buffer " *proofread-lt-probing-exit*"))
           result
           scheduled
           started
           (waiter
            (proofread-languagetool--new-handle
             (proofread-languagetool-test--request)
             (lambda (value) (setq result value)))))
      (setq proofread-languagetool--probe-buffer probe-buffer)
      (setq proofread-languagetool--server-waiters (list waiter))
      (cl-letf
          (((symbol-function 'process-status)
            (lambda (_process) 'exit))
           ((symbol-function 'proofread-languagetool--schedule-probe)
            (lambda (generation phase candidate delay)
              (setq scheduled
                    (list generation phase candidate delay))))
           ((symbol-function
             'proofread-languagetool--start-managed-server)
            (lambda (generation candidate)
              (setq started (list generation candidate)))))
        (proofread-languagetool--process-sentinel
         'owned-process "exited")
        (should (= proofread-languagetool--server-generation 2))
        (proofread-languagetool-test--assert-no-readiness-work)
        (should-not (buffer-live-p probe-buffer))
        (should-not proofread-languagetool--server-process)
        (should-not proofread-languagetool--server-process-session)
        (should (eq proofread-languagetool--server-state 'probing))
        (should proofread-languagetool--force-start-p)
        (should-not result)
        (should (memq waiter proofread-languagetool--server-waiters))
        (should (equal scheduled (list 2 'external session 0)))
        (proofread-languagetool--server-ready 1 session)
        (should (eq proofread-languagetool--server-state 'probing))
        (proofread-languagetool--probe-failed
         1 'external session)
        (should-not started)
        (proofread-languagetool--probe-failed
         2 'external session)
        (should (equal started (list 2 session)))))))

(ert-deftest proofread-languagetool-test-cancel-suppresses-callback ()
  "Cancelling a request kills retrieval and suppresses its callback."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool--server-state 'ready)
            (proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot))
            call result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (_url callback arguments &rest _ignored)
                (let ((buffer (generate-new-buffer
                               " *proofread-lt-cancel*")))
                  (setq call (list :callback callback
                                   :arguments arguments
                                   :buffer buffer))
                  buffer))))
          (let ((handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  (lambda (value) (setq result value)))))
            (proofread-languagetool--cancel handle)
            (should (plist-get handle :cancelled))
            (should-not (buffer-live-p (plist-get call :buffer)))
            (let ((response
                   (proofread-languagetool-test--response-buffer
                    200 "{\"matches\":[]}")))
              (with-current-buffer response
                (apply (plist-get call :callback)
                       (cons nil (plist-get call :arguments)))))
            (should-not result)))))))

;;;; External and managed server integration

(ert-deftest
    proofread-languagetool-test-external-server-ignores-managed-files
    ()
  "External identity and readiness never inspect managed files."
  (proofread-languagetool-test--with-state
    (let ((proofread-languagetool-server-url
           "https://example.test/languagetool/v2")
          (proofread-languagetool-auto-start nil)
          (proofread-languagetool-command
           "/secret/first-languagetool-command")
          (proofread-languagetool-config-file
           "/secret/first-languagetool.properties"))
      (cl-letf
          (((symbol-function
             'proofread-languagetool--file-content-digest)
            (lambda (_file)
              (ert-fail "External identity inspected a managed file"))))
        (let ((identity (proofread-languagetool--identity))
              (session
               (proofread-languagetool--server-session-snapshot)))
          (setq proofread-languagetool-command
                "/secret/second-languagetool-command")
          (setq proofread-languagetool-config-file
                "/secret/second-languagetool.properties")
          (should (equal identity
                         (proofread-languagetool--identity)))
          (should
           (proofread-languagetool--same-session-p
            session (proofread-languagetool--server-session-snapshot)))
          (let ((proofread-languagetool--server-state 'ready)
                (proofread-languagetool--server-session session)
                call handle)
            (cl-letf
                (((symbol-function
                   'proofread-languagetool--begin-readiness-check)
                  (lambda (&rest _ignored)
                    (ert-fail "External server readiness restarted")))
                 ((symbol-function
                   'proofread-languagetool--stop-owned-process)
                  (lambda ()
                    (ert-fail "External server was stopped")))
                 ((symbol-function
                   'proofread-languagetool--start-managed-server)
                  (lambda (&rest _ignored)
                    (ert-fail "External check started a managed server")))
                 ((symbol-function 'url-retrieve-synchronously)
                  (lambda (&rest _ignored)
                    (ert-fail "External version discovery was attempted")))
                 ((symbol-function 'url-retrieve)
                  (lambda (url _callback _arguments &rest _ignored)
                    (should-not call)
                    (setq call
                          (list :url url
                                :method url-request-method
                                :buffer
                                (generate-new-buffer
                                 " *proofread-lt-external-managed*")))
                    (plist-get call :buffer))))
              (with-temp-buffer
                (setq handle
                      (proofread-languagetool--check
                       (proofread-languagetool-test--request)
                       #'ignore)))
              (should (equal (plist-get call :method) "POST"))
              (should
               (equal (plist-get call :url)
                      "https://example.test/languagetool/v2/check"))
              (should (eq proofread-languagetool--server-state 'ready))
              (should-not proofread-languagetool--server-process)
              (proofread-languagetool--cancel handle))))))))

(ert-deftest
    proofread-languagetool-test-external-check-ignores-managed-options
    ()
  "A healthy external server needs no valid managed startup settings."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool-auto-start nil)
            (proofread-languagetool-command 42)
            (proofread-languagetool-config-file "relative.properties")
            (proofread-languagetool-startup-timeout 0)
            calls
            result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-external-only*")))
                  (setq calls
                        (append calls
                                (list (list :url url
                                            :callback callback
                                            :arguments arguments
                                            :buffer buffer
                                            :method
                                            url-request-method))))
                  buffer)))
             ((symbol-function 'make-process)
              (lambda (&rest _ignored)
                (ert-fail
                 "External check attempted managed startup"))))
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq result value)))
          (should proofread-languagetool--probe-retry-token)
          (proofread-languagetool-test--run-scheduled-probe)
          (should (= (length calls) 1))
          (should (equal (plist-get (car calls) :method) "GET"))
          (proofread-languagetool-test--complete-call
           (car calls) 200 "OK")
          (should (= (length calls) 2))
          (should (equal (plist-get (cadr calls) :method) "POST"))
          (proofread-languagetool-test--complete-call
           (cadr calls) 200 "{\"matches\":[]}")
          (should (eq (plist-get result :status) 'ok)))))))

(ert-deftest
    proofread-languagetool-test-external-failure-skips-managed-startup
    ()
  "An unavailable external server does not start a process.
It also does not validate managed settings."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool-auto-start nil)
            (proofread-languagetool-command 42)
            (proofread-languagetool-config-file "relative.properties")
            (proofread-languagetool-startup-timeout 0)
            call
            result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer
                        " *proofread-lt-external-failure*")))
                  (setq call (list :url url
                                   :callback callback
                                   :arguments arguments
                                   :buffer buffer
                                   :method url-request-method))
                  buffer)))
             ((symbol-function 'make-process)
              (lambda (&rest _ignored)
                (ert-fail
                 "External failure attempted managed startup"))))
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq result value)))
          (proofread-languagetool-test--run-scheduled-probe)
          (should (equal (plist-get call :method) "GET"))
          (proofread-languagetool-test--complete-call call 200 "DOWN")
          (should (eq (plist-get result :error)
                      'languagetool-unavailable))
          (should
           (eq proofread-languagetool--server-state 'unknown)))))))

(ert-deftest
    proofread-languagetool-test-external-ready-ignores-managed-changes
    ()
  "An external check does not disturb a ready manually owned session."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let* ((proofread-languagetool-auto-start nil)
             (proofread-languagetool-command "old-command")
             (proofread-languagetool-config-file nil)
             (proofread-languagetool-startup-timeout 15.0)
             (session
              (proofread-languagetool--server-session-snapshot nil t))
             (proofread-languagetool--server-state 'ready)
             (proofread-languagetool--server-session session)
             (proofread-languagetool--server-process 'owned-process)
             (proofread-languagetool--server-process-session session)
             request-buffer)
        (setq proofread-languagetool-command 42)
        (setq proofread-languagetool-config-file "relative.properties")
        (setq proofread-languagetool-startup-timeout 0)
        (cl-letf
            (((symbol-function
               'proofread-languagetool--begin-readiness-check)
              (lambda (&rest _ignored)
                (ert-fail
                 "Managed changes restarted external readiness")))
             ((symbol-function
               'proofread-languagetool--stop-owned-process)
              (lambda ()
                (ert-fail
                 "Managed changes stopped the owned process")))
             ((symbol-function 'url-retrieve)
              (lambda (_url _callback _arguments &rest _ignored)
                (should (equal url-request-method "POST"))
                (setq request-buffer
                      (generate-new-buffer
                       " *proofread-lt-external-ready*")))))
          (let ((handle
                 (proofread-languagetool--check
                  (proofread-languagetool-test--request)
                  #'ignore)))
            (should (buffer-live-p request-buffer))
            (proofread-languagetool--cancel handle)))))))

(ert-deftest proofread-languagetool-test-reuses-healthy-server ()
  "The first request reuses a healthy server without spawning Java."
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let (calls result)
        (cl-letf
            (((symbol-function 'url-retrieve)
              (lambda (url callback arguments &rest _ignored)
                (let ((buffer
                       (generate-new-buffer " *proofread-lt-probe*")))
                  (setq calls
                        (append calls
                                (list (list :url url
                                            :callback callback
                                            :arguments arguments
                                            :buffer buffer
                                            :method
                                            url-request-method))))
                  buffer)))
             ((symbol-function 'make-process)
              (lambda (&rest _ignored)
                (ert-fail "Healthy external server was not reused"))))
          (proofread-languagetool--check
           (proofread-languagetool-test--request)
           (lambda (value) (setq result value)))
          (proofread-languagetool-test--run-scheduled-probe)
          (should (= (length calls) 1))
          (should (equal (plist-get (car calls) :method) "GET"))
          (proofread-languagetool-test--complete-call
           (car calls) 200 "OK")
          (should (eq proofread-languagetool--server-state 'ready))
          (should (= (length calls) 2))
          (should (equal (plist-get (cadr calls) :method) "POST"))
          (proofread-languagetool-test--complete-call
           (cadr calls) 200 "{\"matches\":[]}")
          (should (eq (plist-get result :status) 'ok)))))))

(ert-deftest proofread-languagetool-test-managed-command-is-local ()
  "Managed startup uses the URL port without public server options."
  (proofread-languagetool-test--with-state
    (let ((proofread-languagetool-server-url
           "http://127.0.0.1:18081/v2")
          (proofread-languagetool-config-file nil)
          (proofread-languagetool--server-generation 1)
          command)
      (let ((proofread-languagetool--server-session
             (proofread-languagetool--server-session-snapshot)))
        (cl-letf
            (((symbol-function 'proofread-languagetool--server-command)
              (lambda (_session)
                '( "/opt/languagetool/bin/languagetool-http-server"
                   "--fixed" "argument")))
             ((symbol-function 'make-process)
              (lambda (&rest arguments)
                (setq command (plist-get arguments :command))
                'proofread-languagetool-test-process))
             ((symbol-function 'process-put) #'ignore)
             ((symbol-function
               'set-process-query-on-exit-flag)
              #'ignore)
             ((symbol-function 'process-live-p)
              (lambda (process) (and process t))))
          (proofread-languagetool--start-managed-server
           1 proofread-languagetool--server-session)
          (should
           (equal command
                  '( "/opt/languagetool/bin/languagetool-http-server"
                     "--fixed" "argument"
                     "--port" "18081")))
          (should-not (member "--public" command))
          (should-not (member "--allow-origin" command))
          (setq proofread-languagetool--server-process nil))))))

;;;; Live integration

(ert-deftest proofread-languagetool-test-live-local-server ()
  "Check one sentence with a real local LanguageTool when requested."
  (skip-unless (getenv "PROOFREAD_LANGUAGETOOL_TEST_LIVE"))
  (skip-unless
   (condition-case nil
       (proofread-languagetool--find-command-executable
        (car (proofread-languagetool--command-prefix
              proofread-languagetool-command)))
     (error nil)))
  (proofread-languagetool-test--with-state
    (with-temp-buffer
      (let ((proofread-languagetool-server-url
             (or (getenv "PROOFREAD_LANGUAGETOOL_TEST_URL")
                 "http://127.0.0.1:18091/v2"))
            (proofread-languagetool-auto-start t)
            (proofread-languagetool-startup-timeout 20.0)
            (proofread-languagetool-request-timeout 20.0)
            result)
        (unwind-protect
            (progn
              (proofread-languagetool--check
               (list :beg 1
                     :end 14
                     :text "This are bad."
                     :context-before ""
                     :context-after ""
                     :language "en-US"
                     :target-kind 'text
                     :buffer (current-buffer))
               (lambda (value) (setq result value)))
              (should
               (proofread-languagetool-test--wait-for
                (lambda () result) 45.0))
              (should (eq (plist-get result :status) 'ok))
              (should (plist-get result :diagnostics)))
          (proofread-languagetool-stop-server))))))

(provide 'proofread-languagetool-tests)
;;; proofread-languagetool-tests.el ends here
