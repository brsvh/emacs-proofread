;;; proofread-llm-tests.el --- LLM tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the Proofread LLM backend.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'proofread)
(require 'proofread-llm)

(declare-function make-llm-deepseek "llm-deepseek" (&rest rest))

;;;; Test fixtures

(defconst proofread-llm-test--provider 'proofread-llm-test-provider
  "Provider object used for local LLM backend tests.")

(defconst proofread-llm-test--provider-identity
  "proofread-llm-test-provider"
  "Stable provider identity used for local LLM backend tests.")

(defconst proofread-llm-test--profile 'llm-test
  "Profile selected by LLM backend tests.")

(defconst proofread-llm-test--checker 'llm-test
  "Checker selected by LLM backend tests.")

(defun proofread-llm-test--profiles
    (&optional language display-language)
  "Return the LLM test profile using LANGUAGE and DISPLAY-LANGUAGE."
  `((,proofread-llm-test--profile
     :language ,language
     :display-language ,display-language
     :checkers
     (( :name ,proofread-llm-test--checker
        :backend llm)))))

(defun proofread-llm-test--current-profile-checker
    (&optional profile)
  "Return the first normalized checker from PROFILE.
When PROFILE is nil, use the current profile."
  (car (plist-get (or profile (proofread--current-profile))
                  :checkers)))

(defun proofread-llm-test--make-profile-request (chunk)
  "Return an LLM backend request for CHUNK under the current profile."
  (let* ((profile (proofread--current-profile))
         (checker
          (proofread-llm-test--current-profile-checker profile)))
    (proofread--make-backend-request
     chunk (plist-get checker :backend) checker profile)))

(defmacro proofread-llm-test--with-profile (language &rest body)
  "Run BODY with an LLM test profile using LANGUAGE."
  (declare (indent 1) (debug (form body)))
  `(let ((proofread-profiles
          (proofread-llm-test--profiles ,language))
         (proofread-profile proofread-llm-test--profile))
     ,@body))

(defun proofread-llm-test--tree-member-p (needle tree)
  "Return non-nil if NEEDLE appears anywhere in TREE."
  (cond
   ((eq needle tree) t)
   ((consp tree)
    (or (proofread-llm-test--tree-member-p needle (car tree))
        (proofread-llm-test--tree-member-p needle (cdr tree))))
   (t nil)))

(defun proofread-llm-test--schema-property-names (schema)
  "Return the property names declared by object SCHEMA."
  (let ((properties (plist-get schema :properties))
        names)
    (while properties
      (push (substring (symbol-name (car properties)) 1) names)
      (setq properties (cddr properties)))
    (nreverse names)))

(defun proofread-llm-test--diagnostic-for-range (beg end text)
  "Return a sample diagnostic for BEG, END, and TEXT."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions '( "hello")
   :source 'proofread-llm-test-source))

(defun proofread-llm-test--request-ready-chunks-for-ranges (ranges)
  "Return request-ready chunks for target islands in RANGES."
  (proofread--request-ready-chunks-for-islands
   (proofread--target-islands-for-ranges ranges)))

(defun proofread-llm-test--whole-buffer-chunk ()
  "Return the first request-ready chunk for the whole buffer."
  (car (proofread-llm-test--request-ready-chunks-for-ranges
        (list (cons (point-min) (point-max))))))

(defun proofread-llm-test--wait-for (predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE to return non-nil."
  (let ((deadline (+ (float-time) (or timeout 1.0)))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(defun proofread-llm-test--invoke-timer-callback (timer)
  "Invoke TIMER's callback even when TIMER has been cancelled."
  (apply (timer--function timer) (timer--args timer)))

(defun proofread-llm-test--assert-handle-shape (handle)
  "Assert that HANDLE has the canonical LLM backend shape."
  (should (eq (plist-get handle :backend) 'llm))
  (dolist (key '( :request-timeout :watchdog-timer
                  :requests :timer :delivered :cancelled :settled))
    (should (plist-member handle key))))

(defun proofread-llm-test--capabilities (_provider)
  "Return LLM capabilities used by the local backend fixture."
  '( json-response))

(defmacro proofread-llm-test--with-capabilities (&rest body)
  "Run BODY with structured output enabled for the local provider."
  (declare (indent 0) (debug (body)))
  `(cl-letf (((symbol-function 'llm-capabilities)
              #'proofread-llm-test--capabilities))
     ,@body))

(defmacro proofread-llm-test--with-success (content &rest body)
  "Run BODY with `llm-chat-async' configured to return CONTENT."
  (declare (indent 1) (debug (form body)))
  `(let ((proofread-llm-provider proofread-llm-test--provider)
         (proofread-llm-provider-identity
          proofread-llm-test--provider-identity))
     (cl-letf (((symbol-function 'llm-chat-async)
                (lambda (_provider _prompt success _error &optional
                                   _multi-output)
                  (funcall success ,content)
                  'proofread-llm-test-handle))
               ((symbol-function 'llm-capabilities)
                #'proofread-llm-test--capabilities))
       ,@body)))

(defmacro proofread-llm-test--with-error (error message &rest body)
  "Run BODY with `llm-chat-async' signaling ERROR and MESSAGE."
  (declare (indent 2) (debug (form form body)))
  `(let ((proofread-llm-provider proofread-llm-test--provider)
         (proofread-llm-provider-identity
          proofread-llm-test--provider-identity))
     (cl-letf (((symbol-function 'llm-chat-async)
                (lambda (_provider _prompt _success error-callback
                                   &optional _multi-output)
                  (funcall error-callback ,error ,message)
                  'proofread-llm-test-handle))
               ((symbol-function 'llm-capabilities)
                #'proofread-llm-test--capabilities))
       ,@body)))

(defun proofread-llm-test--response-content (diagnostics)
  "Return structured response text containing DIAGNOSTICS."
  (json-encode `(("diagnostics" . ,(vconcat diagnostics)))))

(defun proofread-llm-test--response-diagnostic
    (beg end text &optional suggestions)
  "Return a diagnostic alist for BEG, END, TEXT, and SUGGESTIONS."
  `(("kind" . "spelling")
    ("message" . "Possible misspelling")
    ("text" . ,text)
    ("range" . (("beg" . ,beg)
                ("end" . ,end)))
    ("suggestions" . ,(vconcat (or suggestions '( "hello"))))))

(defun proofread-llm-test--response-for-range
    (beg end text &optional suggestions)
  "Return response text for BEG, END, TEXT, and SUGGESTIONS."
  (proofread-llm-test--response-content
   (list (proofread-llm-test--response-diagnostic
          beg end text suggestions))))

(defun proofread-llm-test--response-diagnostic-with-fields
    (beg end text fields)
  "Return a response diagnostic for BEG, END, TEXT, and FIELDS."
  (append (cl-remove-if (lambda (field)
                          (assoc (car field) fields))
                        (proofread-llm-test--response-diagnostic
                         beg end text))
          fields))

(defun proofread-llm-test--structured-batch (request diagnostics)
  "Return parsed diagnostic batch for REQUEST and DIAGNOSTICS."
  (proofread-llm--parse-structured-response
   request (proofread-llm-test--response-content diagnostics) 'llm))

(defun proofread-llm-test--structured-issue-reason
    (request diagnostic)
  "Return the first issue reason for DIAGNOSTIC in REQUEST."
  (plist-get
   (car (plist-get
         (proofread-llm-test--structured-batch
          request (list diagnostic))
         :issues))
   :reason))

;;;; Options and backend registration

(ert-deftest
    proofread-llm-test-positive-option-rejects-zero-in-customize ()
  "Customize rejects a non-positive LLM diagnostic pass count."
  (let ((symbol 'proofread-llm-max-diagnostic-passes))
    (should (eq (get symbol 'custom-set)
                #'proofread-set-positive-integer-option))
    (should-error
     (funcall (get symbol 'custom-set) symbol 0))))

(ert-deftest proofread-llm-test-request-timeout-configuration ()
  "Validate global and checker-local LLM watchdog configuration."
  (let ((symbol 'proofread-llm-request-timeout))
    (should (= (default-value symbol) 120))
    (should (functionp (get symbol 'custom-set)))
    (dolist (invalid '(0 -1 "120"))
      (should-error
       (funcall (get symbol 'custom-set) symbol invalid))))
  (let ((proofread-llm-request-timeout nil))
    (should-not (proofread-llm--effective-request-timeout nil)))
  (let ((proofread-llm-request-timeout 120))
    (should (= (proofread-llm--effective-request-timeout nil)
               120))
    (should (= (proofread-llm--effective-request-timeout
                '( :options ( :request-timeout 2.5)))
               2.5))
    (should-not
     (proofread-llm--effective-request-timeout
      '( :options ( :request-timeout nil))))
    (dolist (invalid '(0 -0.5 invalid))
      (should-error
       (proofread-llm--effective-request-timeout
        `( :options ( :request-timeout ,invalid))))))
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-request-timeout nil)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           handle)
      (proofread-llm-test--with-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (&rest _ignored)
                    'proofread-llm-test-request)))
         (setq handle
               (proofread-llm--backend-check request #'ignore))
         (should-not (plist-get handle :request-timeout))
         (should-not (plist-get handle :watchdog-timer))
         (proofread-llm--cancel-request-handle handle)
         (should-not proofread-llm--live-handles))))))

(ert-deftest proofread-llm-test-source-label-configuration ()
  "Resolve validated global and checker-local LLM source labels."
  (let ((symbol 'proofread-llm-source-label))
    (should (eq (get symbol 'custom-set)
                #'proofread-llm--set-source-label-option))
    (dolist (invalid '(42 "" " \t\n"))
      (should-error
       (funcall (get symbol 'custom-set) symbol invalid))))
  (let ((proofread-llm-provider 'global-provider)
        (proofread-llm-source-label
         (propertize "  Global\nlabel  " 'face 'bold))
        (provider-name-calls 0))
    (cl-letf (((symbol-function 'llm-name)
               (lambda (_provider)
                 (setq provider-name-calls
                       (1+ provider-name-calls))
                 "Unexpected")))
      (should
       (equal
        (proofread-llm--checker-source-label
         '( :profile multi :name global :backend llm :options nil))
        "Global label"))
      (should
       (equal
        (proofread-llm--checker-source-label
         '( :profile multi :name local :backend llm
            :options ( :source-label "  Local label  ")))
        "Local label"))
      (should (= provider-name-calls 0))))
  (let ((proofread-llm-provider 'global-provider)
        (proofread-llm-source-label "Global label")
        seen-provider)
    (cl-letf (((symbol-function 'llm-name)
               (lambda (provider)
                 (setq seen-provider provider)
                 (propertize "  Local\nmodel  " 'face 'italic))))
      (should
       (equal
        (proofread-llm--checker-source-label
         '( :profile multi :name local :backend llm
            :options ( :provider local-provider
                       :source-label nil)))
        "Local model"))
      (should (eq seen-provider 'local-provider))))
  (dolist (invalid '(42 "" " \t\n"))
    (should-error
     (proofread-llm--checker-source-label
      `( :profile multi :name local :backend llm
         :options ( :source-label ,invalid))))))

(ert-deftest proofread-llm-test-source-label-provider-fallback ()
  "Use the effective provider name safely before falling back to llm."
  (let ((proofread-llm-provider 'global-provider)
        (proofread-llm-source-label nil)
        seen-provider)
    (cl-letf (((symbol-function 'llm-name)
               (lambda (provider)
                 (setq seen-provider provider)
                 "Global model")))
      (should
       (equal
        (proofread-llm--checker-source-label
         '( :profile multi :name global :backend llm :options nil))
        "Global model"))
      (should (eq seen-provider 'global-provider)))
    (dolist (provider-name '(nil "" " \t\n" invalid))
      (cl-letf (((symbol-function 'llm-name)
                 (lambda (_provider) provider-name)))
        (should
         (equal
          (proofread-llm--checker-source-label
           '( :profile multi :name global :backend llm :options nil))
          "llm"))))
    (cl-letf (((symbol-function 'llm-name)
               (lambda (_provider)
                 (error "Provider name failed"))))
      (should
       (equal
        (proofread-llm--checker-source-label
         '( :profile multi :name global :backend llm :options nil))
        "llm"))))
  (let ((proofread-llm-provider nil)
        (proofread-llm-source-label nil))
    (should
     (equal
      (proofread-llm--checker-source-label
       '( :profile multi :name unconfigured :backend llm :options nil))
      "llm"))))

(ert-deftest proofread-llm-test-source-label-does-not-change-identity ()
  "Keep display source labels out of LLM cache identities."
  (let ((proofread-llm-provider proofread-llm-test--provider)
        (proofread-llm-provider-identity
         proofread-llm-test--provider-identity))
    (should
     (equal
      (proofread-llm--checker-identity
       '( :profile multi :name local :backend llm
          :options ( :source-label "First")))
      (proofread-llm--checker-identity
       '( :profile multi :name local :backend llm
          :options ( :source-label "Second")))))
    (let ((proofread-llm-source-label "First"))
      (let ((first (proofread-llm--provider-identity)))
        (let ((proofread-llm-source-label "Second"))
          (should (equal first
                         (proofread-llm--provider-identity))))))))

(ert-deftest proofread-llm-test-timeout-does-not-change-identity ()
  "Keep backend and cache identity independent of watchdog timeout."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((proofread-llm-provider proofread-llm-test--provider)
                                             (proofread-llm-provider-identity
                                              proofread-llm-test--provider-identity)
                                             (profile '( :name llm-test :language nil))
                                             (first-checker
                                              '( :profile llm-test
                                                 :name local
                                                 :checker-ordinal 0
                                                 :backend llm
                                                 :options ( :request-timeout 1)))
                                             (second-checker
                                              '( :profile llm-test
                                                 :name local
                                                 :checker-ordinal 0
                                                 :backend llm
                                                 :options ( :request-timeout nil)))
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range
                                               1 6 "Alpha"))
                                             first-request second-request)
                                        (proofread-llm-test--with-capabilities
                                         (let ((proofread-llm-request-timeout 20))
                                           (setq first-request
                                                 (proofread--make-backend-request
                                                  chunk 'llm first-checker profile)))
                                         (let ((proofread-llm-request-timeout nil))
                                           (setq second-request
                                                 (proofread--make-backend-request
                                                  chunk 'llm second-checker profile))))
                                        (should (= (proofread-llm--effective-request-timeout
                                                    first-request)
                                                   1))
                                        (should-not
                                         (proofread-llm--effective-request-timeout second-request))
                                        (should
                                         (equal (plist-get first-request :backend-identity)
                                                (plist-get second-request :backend-identity)))
                                        (should
                                         (equal (plist-get first-request :checker-identity)
                                                (plist-get second-request :checker-identity)))
                                        (should (equal (plist-get first-request :cache-key)
                                                       (plist-get second-request :cache-key)))
                                        (proofread--cache-write-request
                                         first-request (list diagnostic))
                                        (should (proofread--cache-read-request second-request))))))

(ert-deftest proofread-llm-test-backend-identity-is-cache-compatible
    ()
  "LLM backend identity is structured and usable for cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-llm-test--with-profile
     nil
     (let* ((proofread-llm-provider proofread-llm-test--provider)
            (proofread-llm-provider-identity
             proofread-llm-test--provider-identity)
            (chunk (proofread-llm-test--whole-buffer-chunk))
            (request
             (proofread-llm-test--make-profile-request chunk))
            (diagnostic
             (proofread-llm-test--diagnostic-for-range 1 6 "Alpha")))
       (should (equal (proofread--backend-identity 'llm)
                      `( :backend llm
                         :provider
                         ,proofread-llm-test--provider-identity
                         :response-strategy prompt-json
                         :diagnostic-passes 3
                         :instructions-identity nil
                         :contract-version 3)))
       (should (proofread--backend-identity-p
                (plist-get request :backend-identity)))
       (proofread--cache-write-request request (list diagnostic))
       (should (proofread--cache-read-request request))))))

(ert-deftest proofread-llm-test-backend-registers-adapter ()
  "Register all LLM backend adapter functions."
  (let ((descriptor (gethash 'llm proofread--backend-registry)))
    (should (eq (plist-get descriptor :check)
                #'proofread-llm--backend-check))
    (should (eq (plist-get descriptor :identity)
                #'proofread-llm--provider-identity))
    (should (eq (plist-get descriptor :checker-identity)
                #'proofread-llm--checker-identity))
    (should (eq (plist-get descriptor :source-label)
                #'proofread-llm--checker-source-label))
    (should (eq (plist-get descriptor :cancel)
                #'proofread-llm--cancel-request-handle))))

(ert-deftest
    proofread-llm-test-backend-support-is-configuration-independent ()
  "Keep LLM support detectable despite configuration errors."
  (let ((proofread-llm-provider nil))
    (should (proofread--supported-backend-p 'llm)))
  (let ((proofread-llm-provider 'proofread-llm-test-provider))
    (should (proofread--supported-backend-p 'llm)))
  (let ((proofread-llm-provider 'proofread-llm-test-provider)
        (proofread-llm-response-strategy 'provider-json))
    (should (proofread--supported-backend-p 'llm)))
  (proofread-llm-test--with-capabilities
   (let ((proofread-llm-provider proofread-llm-test--provider))
     (should (proofread--supported-backend-p 'llm)))))

;;;; Submission and cancellation

(ert-deftest
    proofread-llm-test-provider-unavailable-is-asynchronous-error ()
  "Missing LLM provider reports an asynchronous backend error."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (let ((handle
             (proofread--backend-check
              request
              (lambda (backend-result)
                (setq result backend-result))
              'llm)))
        (proofread-llm-test--assert-handle-shape handle))
      (should-not result)
      (should (proofread-llm-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :error)
                  'llm-provider-unavailable)))))

(ert-deftest
    proofread-llm-test-checker-nil-provider-is-unconfigured ()
  "Checker-local nil provider overrides the configured global provider."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-response-strategy 'auto)
           (checker
            '( :profile multi
               :name local
               :backend llm
               :options ( :provider nil)))
           (profile '( :name multi :language "en"))
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (capability-calls 0)
           (provider-calls 0)
           (callback-calls 0)
           result)
      (should-not (proofread-llm--effective-provider checker))
      (cl-letf (((symbol-function 'llm-capabilities)
                 (lambda (_provider)
                   (cl-incf capability-calls)
                   '( json-response)))
                ((symbol-function 'llm-chat-async)
                 (lambda (&rest _)
                   (cl-incf provider-calls))))
        (let* ((request
                (proofread--make-backend-request
                 chunk 'llm checker profile))
               (identity (plist-get request :backend-identity))
               (handle
                (proofread-llm--backend-check
                 request
                 (lambda (backend-result)
                   (cl-incf callback-calls)
                   (setq result backend-result)))))
          (should (eq (plist-get identity :provider) 'unconfigured))
          (should-not (plist-get identity :response-strategy))
          (proofread-llm-test--assert-handle-shape handle))
        (should (= capability-calls 0))
        (should (= provider-calls 0))
        (should-not result)
        (should (proofread-llm-test--wait-for (lambda () result)))
        (should (= callback-calls 1))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error)
                    'llm-provider-unavailable))))))

(ert-deftest
    proofread-llm-test-structured-output-unavailable-is-asynchronous-error
    ()
  "Report missing schema output for forced provider JSON."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-response-strategy 'provider-json)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           result)
      (cl-letf (((symbol-function 'llm-capabilities)
                 (lambda (_provider)
                   '( generation)))
                ((symbol-function 'llm-chat-async)
                 (lambda (&rest _)
                   (error "Unexpected llm-chat-async call"))))
        (let ((handle
               (proofread--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm)))
          (proofread-llm-test--assert-handle-shape handle))
        (should-not result)
        (should (proofread-llm-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (eq (plist-get result :error)
                    'llm-structured-output-unavailable))))))

(ert-deftest
    proofread-llm-test-check-resolves-response-strategy-once ()
  "Resolve one response strategy snapshot for each LLM check."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-response-strategy 'provider-json)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request
           (capability-calls 0))
      (proofread-llm-test--with-capabilities
       (setq request (proofread--make-backend-request chunk 'llm)))
      (cl-letf
          (((symbol-function 'llm-capabilities)
            (lambda (_provider)
              (cl-incf capability-calls)
              '( json-response)))
           ((symbol-function 'llm-chat-async)
            (lambda (&rest _ignored)
              'proofread-llm-test-request)))
        (let ((handle
               (proofread-llm--backend-check request #'ignore)))
          (proofread-llm-test--assert-handle-shape handle)
          (should (= capability-calls 1))
          (should (equal (plist-get handle :requests)
                         '( proofread-llm-test-request)))
          (should (memq handle proofread-llm--live-handles))
          (proofread-llm--cancel-request-handle handle)
          (should (plist-get handle :settled))
          (should-not proofread-llm--live-handles))))))

(ert-deftest proofread-llm-test-cancel-handle-cancels-all-work ()
  "Cancel both deferred and provider work recorded by an LLM handle."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider nil)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           result
           (handle
            (proofread-llm--backend-check
             request (lambda (value) (setq result value)))))
      (proofread-llm-test--assert-handle-shape handle)
      (should (memq handle proofread-llm--live-handles))
      (proofread-llm--cancel-request-handle handle)
      (should (plist-get handle :cancelled))
      (should (plist-get handle :settled))
      (should-not proofread-llm--live-handles)
      (accept-process-output nil 0.02)
      (should-not result)))
  (let ((handle (list :backend 'llm
                      :requests '( provider-request-a
                                   provider-request-b)
                      :timer nil
                      :delivered nil
                      :cancelled nil
                      :settled nil))
        cancelled)
    (cl-letf (((symbol-function 'llm-cancel-request)
               (lambda (request-handle)
                 (push request-handle cancelled)
                 (when (eq request-handle 'provider-request-a)
                   (error "Cancellation failed")))))
      (proofread-llm--cancel-request-handle handle))
    (should (plist-get handle :cancelled))
    (should (plist-get handle :settled))
    (should (equal (nreverse cancelled)
                   '( provider-request-a provider-request-b)))))

(ert-deftest
    proofread-llm-test-never-callback-times-out-and-releases-slot ()
  "Timeout a silent provider and retire all request lifecycle state."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let* ((proofread-max-concurrent-requests 1)
           (proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 0.01)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle provider-success provider-error result
           cancelled
           (callbacks 0))
      (proofread-llm-test--with-capabilities
       (setq request (proofread--make-backend-request chunk 'llm))
       (cl-letf
           (((symbol-function 'llm-chat-async)
             (lambda (_provider _prompt success error
                                &optional _multi-output)
               (setq provider-success success)
               (setq provider-error error)
               'provider-request-a))
            ((symbol-function 'llm-cancel-request)
             (lambda (provider-handle)
               (push provider-handle cancelled))))
         (setq handle
               (proofread--dispatch-backend-request
                request
                (lambda (value)
                  (cl-incf callbacks)
                  (setq result value))
                'llm))
         (push 'provider-request-b
               (plist-get handle :requests))
         (should (timerp (plist-get handle :watchdog-timer)))
         (should (proofread--active-request-p request))
         (should (proofread--request-work-pending-p request))
         (should (= (proofread--active-request-slots) 0))
         (should (proofread-llm-test--wait-for
                  (lambda () result)))
         (should (= callbacks 1))
         (should (eq (plist-get result :status) 'error))
         (should (eq (plist-get result :error)
                     'llm-request-timeout))
         (should (eq (plist-get result :request) request))
         (should (plist-get handle :cancelled))
         (should (plist-get handle :delivered))
         (should (plist-get handle :settled))
         (should-not (plist-get handle :watchdog-timer))
         (should-not (plist-get handle :timer))
         (should-not (plist-get handle :requests))
         (should-not proofread-llm--live-handles)
         (dolist (provider-handle
                  '( provider-request-a provider-request-b))
           (should (= (cl-count provider-handle cancelled) 1)))
         (should-not (proofread--active-request-p request))
         (should-not proofread--active-requests)
         (should-not
          (proofread--request-work-pending-p request))
         (should (= (proofread--active-request-slots) 1))
         (funcall provider-success
                  (proofread-llm-test--response-content nil))
         (funcall provider-error 'late-provider-error "Late error")
         (proofread-llm--watchdog-expired handle)
         (proofread-llm--cancel-request-handle handle)
         (accept-process-output nil 0.02)
         (should (= callbacks 1))
         (dolist (provider-handle
                  '( provider-request-a provider-request-b))
           (should (= (cl-count provider-handle cancelled) 1))))))))

(ert-deftest proofread-llm-test-success-settles-live-handle ()
  "Settle and forget a live handle after normal success delivery."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 60)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle watchdog provider-success provider-error result
           (callbacks 0))
      (proofread-llm-test--with-capabilities
       (setq request (proofread--make-backend-request chunk 'llm))
       (cl-letf
           (((symbol-function 'llm-chat-async)
             (lambda (_provider _prompt success error
                                &optional _multi-output)
               (setq provider-success success)
               (setq provider-error error)
               'proofread-llm-test-request)))
         (setq handle
               (proofread-llm--backend-check
                request
                (lambda (value)
                  (cl-incf callbacks)
                  (setq result value))))
         (proofread-llm-test--assert-handle-shape handle)
         (should (memq handle proofread-llm--live-handles))
         (should-not (plist-get handle :settled))
         (setq watchdog (plist-get handle :watchdog-timer))
         (should (timerp watchdog))
         (should (functionp provider-success))
         (should (functionp provider-error))
         (funcall provider-success
                  (proofread-llm-test--response-content nil))
         (should (plist-get handle :delivered))
         (should-not (plist-get handle :settled))
         (should-not (plist-get handle :watchdog-timer))
         (should (timerp (plist-get handle :timer)))
         (should (memq handle proofread-llm--live-handles))
         (proofread-llm-test--invoke-timer-callback watchdog)
         (should (= callbacks 0))
         (should-not result)
         (should (proofread-llm-test--wait-for
                  (lambda () result)))
         (should (= callbacks 1))
         (should (eq (plist-get result :status) 'ok))
         (should (plist-get handle :settled))
         (should-not (plist-get handle :timer))
         (should-not proofread-llm--live-handles)
         (funcall provider-error 'late-provider-error "Late error")
         (funcall provider-success
                  (proofread-llm-test--response-content nil))
         (should (= callbacks 1)))))))

(ert-deftest proofread-llm-test-error-beats-late-watchdog ()
  "Deliver one provider error when its cancelled watchdog runs late."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 60)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle watchdog provider-success provider-error result
           (callbacks 0))
      (proofread-llm-test--with-capabilities
       (setq request (proofread--make-backend-request chunk 'llm))
       (cl-letf
           (((symbol-function 'llm-chat-async)
             (lambda (_provider _prompt success error
                                &optional _multi-output)
               (setq provider-success success)
               (setq provider-error error)
               'proofread-llm-test-request)))
         (setq handle
               (proofread-llm--backend-check
                request
                (lambda (value)
                  (cl-incf callbacks)
                  (setq result value))))
         (setq watchdog (plist-get handle :watchdog-timer))
         (should (timerp watchdog))
         (funcall provider-error
                  'provider-failure "Provider failed")
         (should (plist-get handle :delivered))
         (should-not (plist-get handle :settled))
         (should-not (plist-get handle :watchdog-timer))
         (should (timerp (plist-get handle :timer)))
         (proofread-llm-test--invoke-timer-callback watchdog)
         (should (= callbacks 0))
         (should-not result)
         (should (proofread-llm-test--wait-for
                  (lambda () result)))
         (should (= callbacks 1))
         (should (eq (plist-get result :status) 'error))
         (should (eq (plist-get result :error) 'provider-failure))
         (should (plist-get handle :settled))
         (should-not (plist-get handle :watchdog-timer))
         (should-not (plist-get handle :timer))
         (should-not proofread-llm--live-handles)
         (funcall provider-success
                  (proofread-llm-test--response-content nil))
         (funcall provider-error
                  'late-provider-error "Late error")
         (proofread-llm-test--invoke-timer-callback watchdog)
         (proofread-llm--cancel-request-handle handle)
         (should (= callbacks 1)))))))

(ert-deftest
    proofread-llm-test-explicit-cancel-ignores-late-callbacks ()
  "Explicit cancellation settles once and ignores provider callbacks."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 60)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle watchdog provider-success provider-error result
           cancelled
           (callbacks 0))
      (proofread-llm-test--with-capabilities
       (setq request (proofread--make-backend-request chunk 'llm))
       (cl-letf
           (((symbol-function 'llm-chat-async)
             (lambda (_provider _prompt success error
                                &optional _multi-output)
               (setq provider-success success)
               (setq provider-error error)
               'proofread-llm-test-request))
            ((symbol-function 'llm-cancel-request)
             (lambda (provider-handle)
               (push provider-handle cancelled))))
         (setq handle
               (proofread-llm--backend-check
                request
                (lambda (value)
                  (cl-incf callbacks)
                  (setq result value))))
         (should (memq handle proofread-llm--live-handles))
         (setq watchdog (plist-get handle :watchdog-timer))
         (should (timerp watchdog))
         (proofread-llm--cancel-request-handle handle)
         (should (plist-get handle :cancelled))
         (should (plist-get handle :settled))
         (should-not (plist-get handle :delivered))
         (should-not (plist-get handle :requests))
         (should-not (plist-get handle :timer))
         (should-not (plist-get handle :watchdog-timer))
         (should-not proofread-llm--live-handles)
         (should (equal cancelled
                        '( proofread-llm-test-request)))
         (proofread-llm-test--invoke-timer-callback watchdog)
         (funcall provider-success
                  (proofread-llm-test--response-content nil))
         (funcall provider-error 'late-provider-error "Late error")
         (proofread-llm--cancel-request-handle handle)
         (accept-process-output nil 0.02)
         (should (= callbacks 0))
         (should-not result)
         (should (equal cancelled
                        '( proofread-llm-test-request))))))))

(ert-deftest proofread-llm-test-unload-retires-active-request-once ()
  "Unload one active request and ignore callbacks after code removal."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let* ((proofread-max-concurrent-requests 1)
           (proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 60)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle watchdog provider-success provider-error result
           settled-result callback-saw-provider-cancel cancelled
           (callbacks 0))
      (unwind-protect
          (proofread-llm-test--with-capabilities
           (setq request
                 (proofread--make-backend-request chunk 'llm))
           (cl-letf
               (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success error
                                    &optional _multi-output)
                   (setq provider-success success)
                   (setq provider-error error)
                   'proofread-llm-test-request))
                ((symbol-function 'llm-cancel-request)
                 (lambda (provider-handle)
                   (push provider-handle cancelled))))
             (setq handle
                   (proofread--dispatch-backend-request
                    request
                    (lambda (value)
                      (cl-incf callbacks)
                      (setq callback-saw-provider-cancel
                            (equal cancelled
                                   '( proofread-llm-test-request)))
                      (setq result value))
                    'llm))
             (should (proofread--active-request-p request))
             (should (proofread--request-work-pending-p request))
             (should (= (proofread--active-request-slots) 0))
             (should (memq handle proofread-llm--live-handles))
             (setq watchdog (plist-get handle :watchdog-timer))
             (should (timerp watchdog))
             (should (functionp provider-success))
             (should (functionp provider-error))
             (unload-feature 'proofread-llm t)
             (should-not (featurep 'proofread-llm))
             (should (= callbacks 1))
             (should callback-saw-provider-cancel)
             (should (eq (plist-get result :status) 'error))
             (should (eq (plist-get result :error) 'llm-unloaded))
             (setq settled-result result)
             (should (plist-get handle :cancelled))
             (should (plist-get handle :delivered))
             (should (plist-get handle :settled))
             (should-not (plist-get handle :requests))
             (should-not (plist-get handle :timer))
             (should-not (plist-get handle :watchdog-timer))
             (should (equal cancelled
                            '( proofread-llm-test-request)))
             (should-not (proofread--active-request-p request))
             (should-not proofread--active-requests)
             (should-not
              (proofread--request-work-pending-p request))
             (should (= (hash-table-count
                         proofread--pending-request-keys)
                        0))
             (should (= (proofread--active-request-slots) 1))
             (proofread-llm-test--invoke-timer-callback watchdog)
             (funcall provider-success
                      (proofread-llm-test--response-content nil))
             (funcall provider-error
                      'late-provider-error "Late error")
             (should (= callbacks 1))
             (should (eq result settled-result))
             (should (equal cancelled
                            '( proofread-llm-test-request)))))
        (ignore-errors
          (unload-feature 'proofread-llm t))
        (require 'proofread-llm))
      (should (proofread--supported-backend-p 'llm))
      (should-not proofread-llm--live-handles))))

(ert-deftest
    proofread-llm-test-log-hook-unload-skips-provider-submit ()
  "Skip provider submission when request logging unloads the backend."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 1)
           (proofread-llm-request-timeout 60)
           (proofread-llm--live-handles nil)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request handle watchdog result
           (callbacks 0)
           (provider-calls 0)
           unloaded)
      (unwind-protect
          (proofread-llm-test--with-capabilities
           (setq request
                 (proofread--make-backend-request chunk 'llm))
           (cl-letf
               (((symbol-function 'llm-chat-async)
                 (lambda (&rest _ignored)
                   (cl-incf provider-calls)
                   'unexpected-provider-request)))
             (let ((proofread-request-log-hook
                    (list
                     (lambda (event)
                       (when (and
                              (not unloaded)
                              (eq (plist-get event :type)
                                  'backend-request))
                         (setq unloaded t)
                         (setq watchdog
                               (plist-get
                                (car proofread-llm--live-handles)
                                :watchdog-timer))
                         (unload-feature 'proofread-llm t))))))
               (setq handle
                     (proofread-llm--backend-check
                      request
                      (lambda (value)
                        (cl-incf callbacks)
                        (setq result value))))))
           (should unloaded)
           (should-not (featurep 'proofread-llm))
           (should (= provider-calls 0))
           (should (= callbacks 1))
           (should (eq (plist-get result :error) 'llm-unloaded))
           (should (timerp watchdog))
           (should (plist-get handle :cancelled))
           (should (plist-get handle :delivered))
           (should (plist-get handle :settled))
           (should-not (plist-get handle :watchdog-timer))
           (proofread-llm-test--invoke-timer-callback watchdog)
           (should (= provider-calls 0))
           (should (= callbacks 1)))
        (ignore-errors
          (unload-feature 'proofread-llm t))
        (require 'proofread-llm))
      (should (proofread--supported-backend-p 'llm))
      (should-not proofread-llm--live-handles))))

;;;; Provider selection and cache identity

(ert-deftest
    proofread-llm-test-deepseek-v4-flash-uses-prompt-json-fallback ()
  "Use prompt-only JSON for DeepSeek v4 flash without schemas."
  (require 'llm-deepseek)
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-llm-provider
            (make-llm-deepseek :chat-model "deepseek-v4-flash"))
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content (proofread-llm-test--response-content nil))
           captured-prompt
           result)
      (should-not (memq 'json-response
                        (llm-capabilities proofread-llm-provider)))
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider prompt success _error
                                    &optional _multi-output)
                   (setq captured-prompt prompt)
                   (funcall success content)
                   'proofread-llm-test-handle)))
        (should (proofread--backend-check
                 request
                 (lambda (backend-result)
                   (setq result backend-result))
                 'llm))
        (should-not result)
        (should (proofread-llm-test--wait-for (lambda () result)))
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

(ert-deftest proofread-llm-test-provider-identity-is-stable ()
  "LLM identity uses stable provider metadata, not provider objects."
  (let ((proofread-llm-provider
         [:proofread-llm-test-provider :api-key "secret-token"])
        (proofread-llm-provider-identity nil))
    (cl-letf (((symbol-function 'llm-name)
               (lambda (_provider)
                 "qwen3:1.7b")))
      (let ((identity (proofread--backend-identity 'llm)))
        (should (eq (plist-get identity :backend) 'llm))
        (should-not
         (proofread-llm-test--tree-member-p
          proofread-llm-provider identity))
        (let ((provider (plist-get identity :provider)))
          (should (equal (plist-get provider :name) "qwen3:1.7b"))
          (should (integerp (plist-get provider :session))))
        (should (eq (plist-get identity :response-strategy)
                    'prompt-json))
        (should (= (plist-get identity :contract-version) 3))
        (should-not (string-match-p
                     "secret-token"
                     (prin1-to-string identity)))
        (dolist (volatile-key
                 '( :id :buffer :callback :timer :process
                    :request :requests))
          (should-not (plist-member identity volatile-key)))))))

(ert-deftest
    proofread-llm-test-fallback-identity-changes-after-reload ()
  "Distinguish same-named fallback providers across feature reloads."
  (let ((first-provider
         [:provider-a :api-key "first-secret-token"])
        (second-provider
         [:provider-b :api-key "second-secret-token"])
        first-identity second-identity)
    (unwind-protect
        (proofread-llm-test--with-capabilities
         (cl-letf (((symbol-function 'llm-name)
                    (lambda (_provider) "same-provider-name")))
           (let ((proofread-llm-provider first-provider)
                 (proofread-llm-provider-identity nil))
             (setq first-identity
                   (proofread--backend-identity 'llm)))
           (unload-feature 'proofread-llm t)
           (require 'proofread-llm)
           (let ((proofread-llm-provider second-provider)
                 (proofread-llm-provider-identity nil))
             (setq second-identity
                   (proofread--backend-identity 'llm)))
           (should-not (eq first-provider second-provider))
           (should
            (equal
             (plist-get
              (plist-get first-identity :provider) :name)
             (plist-get
              (plist-get second-identity :provider) :name)))
           (should-not (equal first-identity second-identity))
           (dolist (entry
                    `((,first-provider
                       "first-secret-token" ,first-identity)
                      (,second-provider
                       "second-secret-token" ,second-identity)))
             (let ((provider (nth 0 entry))
                   (secret (nth 1 entry))
                   (identity (nth 2 entry)))
               (should-not
                (proofread-llm-test--tree-member-p
                 provider identity))
               (should-not
                (string-match-p
                 (regexp-quote secret)
                 (prin1-to-string identity)))))))
      (ignore-errors
        (unload-feature 'proofread-llm t))
      (require 'proofread-llm))))

(ert-deftest
    proofread-llm-test-explicit-identity-reuses-cache-after-reload ()
  "Reuse cache across reload for an explicitly stable provider identity."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((first-provider [:provider-a :api-key "first-secret"])
                                             (second-provider
                                              [:provider-b :api-key "second-secret"])
                                             (stable-identity "shared-provider")
                                             (unrelated-key
                                              '( proofread-llm-test-unrelated-cache))
                                             (unrelated-entry '( :source unrelated-backend))
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range
                                               1 6 "Alpha"))
                                             first-request first-backend-identity)
                                        (unwind-protect
                                            (proofread-llm-test--with-capabilities
                                             (let ((proofread-llm-provider first-provider)
                                                   (proofread-llm-provider-identity
                                                    stable-identity))
                                               (setq first-request
                                                     (proofread-llm-test--make-profile-request
                                                      chunk))
                                               (setq first-backend-identity
                                                     (plist-get first-request :backend-identity))
                                               (proofread--cache-write-request
                                                first-request (list diagnostic)))
                                             (proofread--cache-write unrelated-key unrelated-entry)
                                             (unload-feature 'proofread-llm t)
                                             (require 'proofread-llm)
                                             (let* ((proofread-llm-provider second-provider)
                                                    (proofread-llm-provider-identity
                                                     stable-identity)
                                                    (second-request
                                                     (proofread-llm-test--make-profile-request
                                                      chunk)))
                                               (should
                                                (equal first-backend-identity
                                                       (plist-get
                                                        second-request :backend-identity)))
                                               (should
                                                (proofread--cache-read-request second-request)))
                                             (should
                                              (equal (proofread--cache-read unrelated-key)
                                                     unrelated-entry)))
                                          (ignore-errors
                                            (unload-feature 'proofread-llm t))
                                          (require 'proofread-llm))))))

(ert-deftest proofread-llm-test-provider-identity-cache-miss ()
  "Changing stable LLM provider identity misses old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((proofread-llm-provider 'proofread-llm-test-provider)
                                             (proofread-llm-provider-identity "provider-a")
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (request
                                              (proofread-llm-test--make-profile-request chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range 1 6 "Alpha")))
                                        (proofread--cache-write-request request (list diagnostic))
                                        (should (proofread--cache-read-request
                                                 (proofread-llm-test--make-profile-request chunk)))
                                        (let ((proofread-llm-provider-identity "provider-b"))
                                          (should-not (proofread--cache-read-request
                                                       (proofread-llm-test--make-profile-request
                                                        chunk))))))))

(ert-deftest proofread-llm-test-provider-object-cache-miss ()
  "Miss the cache when LLM provider objects change."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((proofread-llm-provider [:provider-a :api-key
                                                                                  "secret-token"])
                                             (proofread-llm-provider-identity nil)
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (request
                                              (proofread-llm-test--make-profile-request chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range 1 6 "Alpha")))
                                        (proofread--cache-write-request request (list diagnostic))
                                        (should (proofread--cache-read-request
                                                 (proofread-llm-test--make-profile-request chunk)))
                                        (let ((proofread-llm-provider [:provider-b :api-key
                                                                                   "secret-token"]))
                                          (let ((key
                                                 (proofread--cache-key
                                                  (proofread-llm-test--make-profile-request chunk))))
                                            (should-not (proofread-llm-test--tree-member-p
                                                         proofread-llm-provider key))
                                            (should-not (proofread-llm-test--tree-member-p
                                                         "secret-token" key)))
                                          (should-not (proofread--cache-read-request
                                                       (proofread-llm-test--make-profile-request
                                                        chunk))))))))

;;;; Prompt submission and multi-pass results

(ert-deftest
    proofread-llm-test-dispatch-builds-schema-prompt-asynchronously ()
  "Dispatch an async schema prompt built from request fields."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (proofread-llm-test--with-profile "en"
                                      (let* ((proofread-llm-provider 'proofread-llm-test-provider)
                                             (proofread-llm-max-diagnostic-passes 1)
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (request
                                              (proofread-llm-test--make-profile-request chunk))
                                             (content
                                              (proofread-llm-test--response-for-range 0 4 "helo"))
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
                                                     'proofread-llm-test-handle))
                                                  ((symbol-function 'llm-capabilities)
                                                   #'proofread-llm-test--capabilities))
                                          (let ((handle
                                                 (proofread--backend-check
                                                  request
                                                  (lambda (backend-result)
                                                    (setq result backend-result))
                                                  'llm)))
                                            (proofread-llm-test--assert-handle-shape handle)
                                            (should (equal (plist-get handle :requests)
                                                           '( proofread-llm-test-handle)))
                                            (should (eq captured-provider proofread-llm-provider))
                                            (should-not captured-multi-output)
                                            (should (equal (llm-chat-prompt-response-format
                                                            captured-prompt)
                                                           proofread-llm--structured-response-schema))
                                            (let* ((interaction
                                                    (car (llm-chat-prompt-interactions
                                                          captured-prompt)))
                                                   (prompt-text
                                                    (llm-chat-prompt-interaction-content interaction)))
                                              (should (string-match-p "requested response schema"
                                                                      prompt-text))
                                              (should (string-match-p "Language: \"en\""
                                                                      prompt-text))
                                              (should (string-match-p "Major mode: text-mode"
                                                                      prompt-text))
                                              (should (string-match-p "Text:\nhelo" prompt-text)))
                                            (should-not result)
                                            (should (proofread-llm-test--wait-for
                                                     (lambda () result)))
                                            (should (eq (plist-get result :status) 'ok))
                                            (should (eq (plist-get
                                                         (car (plist-get result :diagnostics))
                                                         :source)
                                                        'llm))))))))

(ert-deftest
    proofread-llm-test-checker-options-build-local-prompt ()
  "Checker-local LLM options select provider and prompt extras."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (let* ((proofread-llm-provider 'proofread-global-provider)
           (proofread-llm-provider-identity "global-provider")
           (proofread-llm-response-strategy 'provider-json)
           (proofread-llm-max-diagnostic-passes 3)
           (checker
            '( :profile multi
               :name local
               :backend llm
               :options ( :provider proofread-checker-provider
                          :provider-identity "checker-provider"
                          :response-strategy prompt-json
                          :diagnostic-passes 1
                          :instructions-function
                          proofread-llm-test--instructions
                          :instructions-identity "instructions-v1")))
           (profile '( :name multi :language "en"))
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request
            (cl-letf
                (((symbol-function
                   'proofread-llm-test--instructions)
                  (lambda (backend-request)
                    (format "Prefer concise fixes for %s."
                            (plist-get backend-request
                                       :target-kind)))))
              (proofread--make-backend-request
               chunk 'llm checker profile)))
           (content
            (proofread-llm-test--response-for-range 0 4 "helo"))
           captured-provider
           captured-prompt
           result)
      (should
       (equal
        (plist-get request :backend-identity)
        '( :backend llm
           :provider "checker-provider"
           :response-strategy prompt-json
           :diagnostic-passes 1
           :instructions-identity "instructions-v1"
           :contract-version 3)))
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (provider prompt success _error
                                   &optional _multi-output)
                   (setq captured-provider provider)
                   (setq captured-prompt prompt)
                   (funcall success content)
                   'proofread-llm-test-handle))
                ((symbol-function
                  'proofread-llm-test--instructions)
                 (lambda (backend-request)
                   (format "Prefer concise fixes for %s."
                           (plist-get backend-request
                                      :target-kind)))))
        (let ((handle
               (proofread-llm--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result)))))
          (proofread-llm-test--assert-handle-shape handle)
          (should (eq captured-provider 'proofread-checker-provider))
          (should (equal (llm-chat-prompt-response-format
                          captured-prompt)
                         nil))
          (let* ((interaction
                  (car (llm-chat-prompt-interactions
                        captured-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "Additional instructions:"
                                    prompt-text))
            (should (string-match-p "Prefer concise fixes for text"
                                    prompt-text))
            (should (string-match-p "JSON schema:" prompt-text))
            (should (string-match-p "Text:\nhelo" prompt-text)))
          (should (proofread-llm-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok)))))))

(ert-deftest proofread-llm-test-prompt-describes-character-ranges ()
  "LLM prompts describe chunk-relative character ranges."
  (with-temp-buffer
    (org-mode)
    (insert "青晨六点。")
    (proofread-llm-test--with-profile "zh"
                                      (let ((proofread-context-size 0)
                                            (proofread-llm-provider
                                             'proofread-llm-test-provider)
                                            (proofread-llm--live-handles nil)
                                            captured-prompt)
                                        (cl-letf
                                            (((symbol-function 'llm-chat-async)
                                              (lambda (_provider prompt _success _error
                                                                 &optional _multi-output)
                                                (setq captured-prompt prompt)
                                                'proofread-llm-test-handle))
                                             ((symbol-function 'llm-capabilities)
                                              #'proofread-llm-test--capabilities))
                                          (let* ((chunk
                                                  (proofread-llm-test--whole-buffer-chunk))
                                                 (request
                                                  (proofread-llm-test--make-profile-request
                                                   chunk))
                                                 (handle
                                                  (proofread--backend-check
                                                   request #'ignore 'llm)))
                                            (let* ((interaction
                                                    (car (llm-chat-prompt-interactions
                                                          captured-prompt)))
                                                   (prompt-text
                                                    (llm-chat-prompt-interaction-content
                                                     interaction)))
                                              (should
                                               (string-match-p "Text:\n青晨六点。" prompt-text))
                                              (should
                                               (string-match-p
                                                "range end is exclusive" prompt-text)))
                                            (proofread-llm--cancel-request-handle handle)
                                            (should-not proofread-llm--live-handles)))))))

(ert-deftest proofread-llm-test-success-enters-overlay-pipeline ()
  "Send fresh LLM diagnostics through the normal result path."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-llm-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (content
            (proofread-llm-test--response-for-range 1 5 "helo"))
           request
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success
                                                          content)))
                   'proofread-llm-test-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-llm-test--capabilities))
        (setq request
              (proofread--make-backend-request
               (proofread-llm-test--whole-buffer-chunk)
               'llm))
        (should (proofread--dispatch-backend-request
                 request
                 (lambda (backend-result)
                   (setq result backend-result)
                   (proofread--handle-backend-result backend-result))
                 'llm))
        (should (proofread-llm-test--wait-for
                 (lambda ()
                   proofread--diagnostics)))
        (should (eq (plist-get result :status) 'ok))
        (should-not (plist-get result :partial))
        (should (= (length (plist-get result :repairs)) 1))
        (let ((repair (car (plist-get result :repairs))))
          (should (eq (plist-get repair :action) 'repaired))
          (should (= (plist-get repair :candidate-index) 0))
          (should (= (plist-get repair :pass) 1))
          (should (equal (plist-get repair :reported-range)
                         '( 1 . 5)))
          (should (equal (plist-get repair :range) '( 0 . 4))))
        (should-not proofread--active-requests)
        (should (= (length proofread--diagnostics) 1))
        (should (= (length proofread--overlays) 1))
        (should (= (hash-table-count proofread--cache) 1))))))

(ert-deftest proofread-llm-test-collects-additional-diagnostic-passes
    ()
  "Collect unique LLM diagnostics in first-seen order across passes."
  (with-temp-buffer
    (insert "helo wrld agin")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-llm-test-provider)
           (proofread-llm-max-diagnostic-passes 3)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           request
           (first
            (proofread-llm-test--response-for-range 0 4 "helo"))
           (second
            (proofread-llm-test--response-content
             (list
              (proofread-llm-test--response-diagnostic 0 4 "helo")
              (proofread-llm-test--response-diagnostic 5 9 "wrld")
              (proofread-llm-test--response-diagnostic 5 9 "wrld"))))
           (third
            (proofread-llm-test--response-content
             (list
              (proofread-llm-test--response-diagnostic 5 9 "wrld")
              (proofread-llm-test--response-diagnostic
               10 14 "agin")
              (proofread-llm-test--response-diagnostic
               10 14 "agin"))))
           calls
           prompts
           result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider prompt success _error
                                    &optional _multi-output)
                   (push prompt prompts)
                   (setq calls (1+ (or calls 0)))
                   (funcall success
                            (pcase calls
                              (1 first)
                              (2 second)
                              (_ third)))
                   (intern (format "proofread-llm-test-handle-%d"
                                   calls))))
                ((symbol-function 'llm-capabilities)
                 #'proofread-llm-test--capabilities))
        (setq request (proofread--make-backend-request chunk 'llm))
        (should (> (plist-get request :generation) 0))
        (let ((handle (proofread--backend-check
                       request
                       (lambda (backend-result)
                         (setq result backend-result))
                       'llm)))
          (should (= calls 3))
          (should (= (length (plist-get handle :requests)) 3))
          (let* ((later-prompt (car prompts))
                 (interaction
                  (car (llm-chat-prompt-interactions later-prompt)))
                 (prompt-text
                  (llm-chat-prompt-interaction-content interaction)))
            (should (string-match-p "Already reported diagnostics"
                                    prompt-text))
            (should (string-match-p
                     "Return only additional diagnostics"
                     prompt-text)))
          (should (proofread-llm-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok))
          (should (equal (mapcar (lambda (diagnostic)
                                   (plist-get diagnostic :text))
                                 (plist-get result :diagnostics))
                         '( "helo" "wrld" "agin"))))))))

(ert-deftest
    proofread-llm-test-retries-candidate-issues-within-pass-limit ()
  "Recover from an unusable first pass while retaining partial state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (invalid
            (proofread-llm-test--response-for-range 0 4 "hola"))
           (valid
            (proofread-llm-test--response-for-range 0 4 "helo"))
           calls
           result)
      (proofread-llm-test--with-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success (if (= calls 1) invalid valid))
                    (intern (format "proofread-llm-test-retry-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 2))
           (should (proofread-llm-test--wait-for (lambda () result)))
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
                     '( 0 . 4))))
           (should (equal (mapcar (lambda (diagnostic)
                                    (plist-get diagnostic :text))
                                  (plist-get result :diagnostics))
                          '( "helo")))))))))

(ert-deftest
    proofread-llm-test-errors-after-candidate-retry-exhaustion ()
  "All-invalid candidate passes end in one terminal backend error."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 3)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (invalid
            (proofread-llm-test--response-for-range 0 4 "hola"))
           calls
           result)
      (proofread-llm-test--with-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success invalid)
                    (intern (format "proofread-llm-test-invalid-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 3))
           (should (proofread-llm-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'error))
           (should (eq (plist-get result :error)
                       'llm-invalid-diagnostics))
           (should (= (length (plist-get result :candidate-issues))
                      3))
           (should-not (plist-get result :diagnostics))))))))

(ert-deftest
    proofread-llm-test-sticky-candidate-issues-exhaust-empty-passes ()
  "Exhaust pass limits after an invalid pass and empty retries."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 3)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (invalid
            (proofread-llm-test--response-for-range 0 4 "hola"))
           (empty (proofread-llm-test--response-content nil))
           calls
           result)
      (proofread-llm-test--with-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success _error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (funcall success (if (= calls 1) invalid empty))
                    (intern (format "proofread-llm-test-empty-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 3))
           (should (proofread-llm-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'error))
           (should (eq (plist-get result :error)
                       'llm-invalid-diagnostics))
           (should (= (length (plist-get result :candidate-issues))
                      1))))))))

(ert-deftest
    proofread-llm-test-later-transport-error-keeps-partial-results ()
  "Preserve partial results after a later transport error."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity
            proofread-llm-test--provider-identity)
           (proofread-llm-max-diagnostic-passes 2)
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (valid
            (proofread-llm-test--response-for-range 0 4 "helo"))
           calls
           result)
      (proofread-llm-test--with-capabilities
       (cl-letf (((symbol-function 'llm-chat-async)
                  (lambda (_provider _prompt success error
                                     &optional _multi-output)
                    (setq calls (1+ (or calls 0)))
                    (if (= calls 1)
                        (funcall success valid)
                      (funcall error 'transport-error
                               "Network failed"))
                    (intern (format "proofread-llm-test-transport-%d"
                                    calls)))))
         (let ((request
                (proofread--make-backend-request chunk 'llm)))
           (proofread--backend-check
            request (lambda (backend-result) (setq result
                                                   backend-result))
            'llm)
           (should (= calls 2))
           (should (proofread-llm-test--wait-for (lambda () result)))
           (should (eq (plist-get result :status) 'ok))
           (should (plist-get result :partial))
           (should (= (length (plist-get result :diagnostics)) 1))
           (should (eq (proofread--handle-backend-result result)
                       'applied))
           (should (= (length proofread--diagnostics) 1))
           (should (= (length proofread--overlays) 1))
           (should (= (hash-table-count proofread--cache) 0))))))))

(ert-deftest
    proofread-llm-test-managed-request-stops-after-becoming-stale ()
  "Stop managed LLM requests after an edit or mode disable."
  (dolist (scenario '( edited disabled))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((proofread-llm-provider proofread-llm-test--provider)
            (proofread-llm-provider-identity
             proofread-llm-test--provider-identity)
            (proofread-llm-max-diagnostic-passes 2)
            (content
             (proofread-llm-test--response-for-range 0 4 "helo"))
            callbacks
            calls
            result)
        (proofread-llm-test--with-capabilities
         (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
                (request (proofread--make-backend-request chunk
                                                          'llm)))
           (should (> (plist-get request :generation) 0))
           (cl-letf (((symbol-function 'llm-chat-async)
                      (lambda (_provider _prompt success _error
                                         &optional _multi-output)
                        (setq calls (1+ (or calls 0)))
                        (push success callbacks)
                        (intern
                         (format "proofread-llm-test-managed-%d"
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
             (should
              (proofread-llm-test--wait-for (lambda () result)))
             (should (= calls 1)))))))))

(ert-deftest
    proofread-llm-test-error-preserves-buffer-and-clears-request ()
  "LLM error callbacks preserve text and clear active request state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((proofread-llm-provider 'proofread-llm-test-provider)
          (before-text (buffer-string))
          result)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt _success error
                                    &optional _multi-output)
                   (funcall error 'llm-error "boom")
                   'proofread-llm-test-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-llm-test--capabilities))
        (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
               (request (proofread--make-backend-request chunk 'llm)))
          (should (proofread--dispatch-backend-request
                   request
                   (lambda (backend-result)
                     (setq result backend-result))
                   'llm))
          (should (proofread-llm-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'error))
          (should (eq (plist-get result :error) 'llm-error))
          (should (equal (buffer-string) before-text))
          (should-not proofread--active-requests)
          (should-not proofread--overlays))))))

(ert-deftest proofread-llm-test-invalid-success-response-is-error ()
  "Turn malformed and non-string LLM success responses into errors."
  (dolist (response '( "not json" ( :diagnostics nil)))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((proofread-llm-provider 'proofread-llm-test-provider)
            calls
            result)
        (cl-letf (((symbol-function 'llm-chat-async)
                   (lambda (_provider _prompt success _error
                                      &optional _multi-output)
                     (setq calls (1+ (or calls 0)))
                     (funcall success response)
                     'proofread-llm-test-handle))
                  ((symbol-function 'llm-capabilities)
                   #'proofread-llm-test--capabilities))
          (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
                 (request
                  (proofread--make-backend-request chunk 'llm)))
            (should (proofread--dispatch-backend-request
                     request
                     (lambda (backend-result)
                       (setq result backend-result)
                       (proofread--handle-backend-result
                        backend-result))
                     'llm))
            (should (proofread-llm-test--wait-for (lambda () result)))
            (should (= calls 1))
            (should (eq (plist-get result :status) 'error))
            (should (eq (plist-get result :error)
                        'llm-invalid-response))
            (should-not proofread--active-requests)
            (should-not proofread--overlays)
            (should (= (hash-table-count proofread--cache) 0))))))))

(ert-deftest proofread-llm-test-stale-results-are-dropped ()
  "Cancel or stale LLM results after invalidating their source."
  (dolist (scenario '( killed disabled modified text-mismatch))
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
                      'proofread-llm-test-provider)
                     (proofread-llm-max-diagnostic-passes 1)
                     (chunk
                      (proofread-llm-test--whole-buffer-chunk)))
                (cl-letf (((symbol-function 'llm-chat-async)
                           (lambda (_provider _prompt callback _error
                                              &optional _multi-output)
                             (setq success callback)
                             'proofread-llm-test-handle))
                          ((symbol-function 'llm-capabilities)
                           #'proofread-llm-test--capabilities)
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
             (proofread-llm-test--response-for-range 0 4 "helo"))
            (if (or (memq scenario '( killed disabled))
                    (proofread--request-invalidated-p request))
                (progn
                  (accept-process-output nil 0.02)
                  (should-not result))
              (should
               (proofread-llm-test--wait-for (lambda () result)))
              (should (eq result 'stale)))
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (should-not proofread--diagnostics)
                (should-not proofread--overlays))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

;;;; Structured response contract and parsing

(ert-deftest
    proofread-llm-test-structured-response-prompt-requests-contract ()
  "Describe chunk-relative schema ranges in diagnostic prompts."
  (with-temp-buffer
    (text-mode)
    (insert "helo")
    (proofread-llm-test--with-profile "en"
                                      (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
                                             (request
                                              (proofread-llm-test--make-profile-request chunk))
                                             (prompt
                                              (proofread-llm--structured-response-prompt request)))
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
                                        (dolist (field '( "kind" "message" "text" "range"
                                                          "suggestions"))
                                          (should (string-match-p field prompt)))
                                        (should-not (string-match-p "source" prompt))
                                        (should (string-match-p "Language: \"en\"" prompt))
                                        (should (string-match-p "Major mode: text-mode" prompt))
                                        (should (string-match-p "Text:\nhelo" prompt))
                                        (should-not (string-match-p "absolute buffer" prompt))))))

(ert-deftest proofread-llm-test-prompt-uses-profile-language-label ()
  "Prefer a display name, then a language code, in LLM prompts."
  (dolist (case
           '( ("zh-Hans" "Simplified Chinese"
               "Simplified Chinese")
              ("zh-Hans" nil "zh-Hans")
              (nil nil nil)))
    (pcase-let ((`(,language ,display-language ,expected) case))
      (with-temp-buffer
        (text-mode)
        (insert "helo")
        (let ((proofread-profile proofread-llm-test--profile)
              (proofread-profiles
               (proofread-llm-test--profiles
                language display-language)))
          (let* ((chunk
                  (proofread-llm-test--whole-buffer-chunk))
                 (request
                  (proofread-llm-test--make-profile-request chunk))
                 (prompt
                  (proofread-llm--structured-response-prompt
                   request))
                 (expected-line
                  (and expected
                       (format "Language: %S" expected))))
            (should (equal (plist-get request :language) language))
            (should (equal
                     (plist-get request :display-language)
                     display-language))
            (if expected-line
                (should
                 (string-match-p
                  (regexp-quote expected-line) prompt))
              (should-not (string-match-p "Language:" prompt)))
            (when display-language
              (should-not
               (string-match-p
                (regexp-quote (format "Language: %S" language))
                prompt)))))))))

(ert-deftest
    proofread-llm-test-structured-response-schema-matches-parser-contract ()
  "Keep every response object closed under the parser contract."
  (let* ((root proofread-llm--structured-response-schema)
         (diagnostics
          (plist-get (plist-get root :properties) :diagnostics))
         (candidate (plist-get diagnostics :items))
         (range
          (plist-get (plist-get candidate :properties) :range)))
    (dolist
        (entry
         (list (list root '( "diagnostics"))
               (list candidate
                     '( "kind" "message" "text" "range"
                        "suggestions"))
               (list range '( "beg" "end"))))
      (let ((schema (car entry))
            (fields (cadr entry)))
        (should (equal (plist-get schema :type) "object"))
        (should
         (equal (proofread-llm-test--schema-property-names schema)
                fields))
        (should (equal (append (plist-get schema :required) nil)
                       fields))
        (should (plist-member schema :additionalProperties))
        (should (eq (plist-get schema :additionalProperties)
                    json-false))))
    (should-not (proofread-llm--json-schema-property root "source"))
    (let ((schema-text
           (proofread-llm--structured-response-schema-text)))
      (should (string-match-p "\"additionalProperties\":false"
                              schema-text))
      (should-not (string-match-p "\"source\"" schema-text))
      (should-not
       (string-match-p "\"additionalProperties\":\"false\""
                       schema-text)))))

(ert-deftest
    proofread-llm-test-structured-response-extra-text-around-payload-is-error
    ()
  "Structured response parser rejects extra text around a payload."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (concat "Result follows:\n"
                    (proofread-llm-test--response-for-range
                     0 4 "helo")
                    "\nDone.")))
      (should-error
       (proofread-llm--parse-structured-response
        request content 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-ambiguous-extra-json-is-error
    ()
  "Structured response parser rejects multiple payloads."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (payload
            (proofread-llm-test--response-for-range 0 4 "helo")))
      (should-error
       (proofread-llm--parse-structured-response
        request (concat payload "\n" payload) 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-non-json-content-is-error
    ()
  "Non-schema structured response text is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread-llm--parse-structured-response
        request "I found a spelling issue." 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-malformed-json-is-error ()
  "Malformed structured response JSON is a parse error."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread-llm--parse-structured-response
        request "Before {\"diagnostics\":[} after" 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-rejects-non-json-payload ()
  "Structured responses reject non-JSON Lisp payloads."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (payload '( :diagnostics nil)))
      (should-error
       (proofread-llm--parse-structured-response
        request payload 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-uses-absolute-buffer-range
    ()
  "Structured response diagnostics use absolute buffer ranges."
  (with-temp-buffer
    (insert "青晨六点，小城。")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-llm-test--response-for-range 5 7 "小城"))
           (diagnostic
            (car
             (plist-get
              (proofread-llm--parse-structured-response
               request content 'llm)
              :diagnostics))))
      (should (equal (proofread--diagnostic-range diagnostic)
                     '( 6 . 8))))))

(ert-deftest
    proofread-llm-test-structured-response-uses-shared-constructor ()
  "Normalize LLM candidates before shared diagnostic construction."
  (let ((request '( :beg 10 :end 14 :text "helo"
                    :target-kind text))
        calls)
    (cl-letf
        (((symbol-function
           'proofread--diagnostic-from-request-relative-range)
          (lambda (actual-request range properties)
            (push (list actual-request range properties) calls)
            'sentinel)))
      (let ((batch
             (proofread-llm-test--structured-batch
              request
              (list (proofread-llm-test--response-diagnostic
                     0 4 "helo" '( "hello" "hullo"))))))
        (should (equal (plist-get batch :diagnostics) '( sentinel)))
        (should-not (plist-get batch :issues))
        (should-not (plist-get batch :repairs))))
    (should
     (equal calls
            (list
             (list request '( 0 . 4)
                   '( :kind spelling
                      :message "Possible misspelling"
                      :suggestions ("hello" "hullo")
                      :source llm)))))))

(ert-deftest
    proofread-llm-test-structured-response-preserves-multiple-diagnostics
    ()
  "Structured response keeps multiple diagnostics from one request."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-llm-test--response-content
             (list
              (proofread-llm-test--response-diagnostic 0 4 "helo"
                                                       '( "hello"))
              (proofread-llm-test--response-diagnostic 5 9 "wrld"
                                                       '( "world")))))
           (diagnostics
            (plist-get
             (proofread-llm--parse-structured-response
              request content 'llm)
             :diagnostics)))
      (should (= (length diagnostics) 2))
      (should (equal (mapcar (lambda (diagnostic)
                               (plist-get diagnostic :text))
                             diagnostics)
                     '( "helo" "wrld")))
      (should (equal (mapcar (lambda (diagnostic)
                               (cons (plist-get diagnostic :beg)
                                     (plist-get diagnostic :end)))
                             diagnostics)
                     '((1 . 5) (6 . 10)))))))

(ert-deftest
    proofread-llm-test-structured-response-unmatched-text-is-isolated
    ()
  "A diagnostic whose text is outside the request becomes one issue."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (_ (setq request
                    (plist-put request :context-before "world")))
           (batch
            (proofread-llm-test--structured-batch
             request
             (list
              (proofread-llm-test--response-diagnostic
               0 99 "world")))))
      (should-not (plist-get batch :diagnostics))
      (should-not (plist-get batch :repairs))
      (should (equal (mapcar (lambda (issue)
                               (plist-get issue :reason))
                             (plist-get batch :issues))
                     '( unmatched-text))))))

(ert-deftest
    proofread-llm-test-structured-response-repairs-unique-exact-text
    ()
  "Repair a wrong range when its text has one unique request match."
  (with-temp-buffer
    (insert "青晨六点半，小城的街到刚刚醒来。")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-llm-test--structured-batch
             request
             (list
              (proofread-llm-test--response-diagnostic 0 2 "青晨"
                                                       '( "清晨"))
              (proofread-llm-test--response-diagnostic 7 9 "街到"
                                                       '( "街道")))))
           (diagnostics (plist-get batch :diagnostics))
           (repair (car (plist-get batch :repairs))))
      (should-not (plist-get batch :issues))
      (should (= (length diagnostics) 2))
      (should (equal (mapcar #'proofread--diagnostic-range
                             diagnostics)
                     '((1 . 3) (10 . 12))))
      (should (equal (plist-get repair :reported-range) '( 7 . 9)))
      (should (equal (plist-get repair :range) '( 9 . 11))))))

(ert-deftest
    proofread-llm-test-structured-response-ambiguous-text-is-isolated
    ()
  "A wrong range is not guessed when its text occurs more than once."
  (with-temp-buffer
    (insert "helo x helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-llm-test--structured-batch
             request
             (list (proofread-llm-test--response-diagnostic 6 10
                                                            "helo"))))
           (issue (car (plist-get batch :issues))))
      (should-not (plist-get batch :diagnostics))
      (should-not (plist-get batch :repairs))
      (should (eq (plist-get issue :reason) 'ambiguous-text))
      (should (equal (plist-get issue :occurrences)
                     '((0 . 4) (7 . 11)))))))

(ert-deftest
    proofread-llm-test-structured-response-exact-repeated-text-is-accepted
    ()
  "Accept exact reported ranges even when their text repeats."
  (with-temp-buffer
    (insert "helo x helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-llm-test--structured-batch
             request
             (list
              (proofread-llm-test--response-diagnostic
               7 11 "helo")))))
      (should (= (length (plist-get batch :diagnostics)) 1))
      (should-not (plist-get batch :issues))
      (should-not (plist-get batch :repairs)))))

(ert-deftest
    proofread-llm-test-structured-response-invalid-empty-range-is-isolated
    ()
  "An empty insertion text is not used to repair a nonempty range."
  (let* ((request '( :beg 1 :end 5 :text "helo"))
         (batch
          (proofread-llm-test--structured-batch
           request
           (list (proofread-llm-test--response-diagnostic
                  0 1 "" '( "H")))))
         (issue (car (plist-get batch :issues))))
    (should-not (plist-get batch :diagnostics))
    (should (eq (plist-get issue :reason) 'range-text-mismatch))))

(ert-deftest
    proofread-llm-test-structured-response-isolates-invalid-candidates
    ()
  "Keep valid diagnostics when a response has invalid candidates."
  (with-temp-buffer
    (insert "helo wrld")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (batch
            (proofread-llm-test--structured-batch
             request
             (list
              (proofread-llm-test--response-diagnostic 0 99 "hola")
              (proofread-llm-test--response-diagnostic-with-fields
               0 4 "helo" '(("kind" . "typo")))
              42
              (proofread-llm-test--response-diagnostic
               5 9 "wrld" '( "world"))))))
      (should (equal (mapcar (lambda (diagnostic)
                               (plist-get diagnostic :text))
                             (plist-get batch :diagnostics))
                     '( "wrld")))
      (should (equal (mapcar (lambda (issue)
                               (plist-get issue :reason))
                             (plist-get batch :issues))
                     '( unmatched-text invalid-shape invalid-shape)))
      (should-not (plist-get batch :repairs)))))

(ert-deftest
    proofread-llm-test-structured-response-invalid-suggestions-are-isolated
    ()
  "A non-string suggestion invalidates only its candidate."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (candidate
            '(("kind" . "spelling")
              ("message" . "Possible misspelling")
              ("text" . "helo")
              ("range" . (("beg" . 0)
                          ("end" . 4)))
              ("suggestions" . ["hello" 42 "hullo"])))
           (batch
            (proofread-llm-test--structured-batch
             request (list candidate))))
      (should-not (plist-get batch :diagnostics))
      (should (eq (plist-get (car (plist-get batch :issues)) :reason)
                  'invalid-shape)))))

(ert-deftest
    proofread-llm-test-structured-response-null-arrays-are-isolated ()
  "Treat a null root as fatal but isolate null suggestions."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm)))
      (should-error
       (proofread-llm--parse-structured-response
        request "{\"diagnostics\":null}" 'llm))
      (let ((batch
             (proofread-llm--parse-structured-response
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
    proofread-llm-test-structured-response-unknown-fields-are-scoped
    ()
  "Reject root fields while isolating candidate and range fields."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (candidate
            (proofread-llm-test--response-diagnostic 0 4 "helo"))
           (candidate-extra
            (append candidate '(("extra" . true))))
           (range-extra
            (proofread-llm-test--response-diagnostic-with-fields
             0 4 "helo"
             '(("range" . (("beg" . 0)
                           ("end" . 4)
                           ("extra" . true)))))))
      (should-error
       (proofread-llm--parse-structured-response
        request "{\"diagnostics\":[],\"extra\":true}" 'llm))
      (dolist (candidate (list candidate-extra range-extra))
        (let ((batch
               (proofread-llm-test--structured-batch
                request (list candidate))))
          (should-not (plist-get batch :diagnostics))
          (should (eq (plist-get (car (plist-get batch :issues))
                                 :reason)
                      'invalid-candidate-json))))
      (let ((batch
             (proofread-llm-test--structured-batch
              request (list candidate-extra candidate))))
        (should (equal (mapcar (lambda (diagnostic)
                                 (plist-get diagnostic :text))
                               (plist-get batch :diagnostics))
                       '( "helo")))
        (should (equal (mapcar (lambda (issue)
                                 (plist-get issue :reason))
                               (plist-get batch :issues))
                       '( invalid-candidate-json)))))))

(ert-deftest
    proofread-llm-test-structured-response-duplicate-fields-are-scoped
    ()
  "Reject duplicate root fields but isolate candidate duplicates."
  (let ((request '( :beg 1 :end 5 :text "helo")))
    (should-error
     (proofread-llm--parse-structured-response
      request "{\"diagnostics\":false,\"diagnostics\":[]}" 'llm))
    (dolist
        (content
         '( "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"kind\":\"style\",\"message\":\"issue\",\
\"text\":\"helo\",\"range\":{\"beg\":0,\"end\":4},\
\"suggestions\":[]}]}"
            "{\"diagnostics\":[{\"kind\":\"spelling\",\
\"message\":\"issue\",\"text\":\"helo\",\
\"range\":{\"beg\":0,\"beg\":1,\"end\":4},\
\"suggestions\":[]}]}"))
      (let ((batch
             (proofread-llm--parse-structured-response
              request content 'llm)))
        (should-not (plist-get batch :diagnostics))
        (should (eq (plist-get (car (plist-get batch :issues))
                               :reason)
                    'invalid-candidate-json))))))

(ert-deftest
    proofread-llm-test-structured-response-trailing-commas-are-error
    ()
  "Trailing commas at every array and object level are parse errors."
  (let ((request '( :beg 1 :end 5 :text "helo")))
    (dolist
        (content
         '( "{\"diagnostics\":[],}"
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
       (proofread-llm--parse-structured-response
        request content 'llm)))))

(ert-deftest
    proofread-llm-test-structured-response-does-not-intern-unknown-keys ()
  "Rejected JSON object keys do not enter the global symbol table."
  (let ((key "proofread-llm-test-unknown-key-7dc65efef5634c08")
        (request '( :beg 1 :end 5 :text "helo")))
    (should-not (intern-soft key))
    (should-error
     (proofread-llm--parse-structured-response
      request (format "{\"diagnostics\":[],\"%s\":true}" key) 'llm))
    (should-not (intern-soft key))))

(ert-deftest
    proofread-llm-test-structured-response-rejects-source-delimiters
    ()
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
            (proofread-llm-test--response-for-range
             insertion-position insertion-position "" '( "."))))
      (should
       (eq (proofread-llm-test--structured-issue-reason
            request
            (proofread-llm-test--response-diagnostic 0 2 ";;"))
           'outside-target))
      (let ((diagnostic
             (car
              (plist-get
               (proofread-llm--parse-structured-response
                request insertion 'llm)
               :diagnostics))))
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
       (eq (proofread-llm-test--structured-issue-reason
            request
            (proofread-llm-test--response-diagnostic 6 7 "*" '( "")))
           'outside-target))
      (should
       (eq (proofread-llm-test--structured-issue-reason
            request
            (proofread-llm-test--response-diagnostic 2 4 "/*" '( "")))
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
      (dolist (candidate '( (8 9 "-") (9 10 "-") (10 11 ">")))
        (should
         (eq (proofread-llm-test--structured-issue-reason
              request
              (proofread-llm-test--response-diagnostic
               (nth 0 candidate) (nth 1 candidate) (nth 2 candidate)
               '( "")))
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
       (eq (proofread-llm-test--structured-issue-reason
            request
            (proofread-llm-test--response-diagnostic 0 1 "\""))
           'outside-target)))))

(ert-deftest
    proofread-llm-test-structured-response-allows-safe-target-interiors ()
  "Allow prose punctuation and incomplete source containers."
  (dolist (spec '( (c-mode "/*helo!*/" comment 6 7 "!")
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
              (proofread-llm-test--response-for-range
               (nth 3 spec) (nth 4 spec) (nth 5 spec)
               '( "fixed"))))
        (goto-char (point-max))
        (push-mark (point-min) t t)
        (let ((before-point (point))
              (before-mark (mark t))
              (before-mark-active mark-active))
          (should
           (plist-get
            (proofread-llm--parse-structured-response
             request content 'llm)
            :diagnostics))
          (should (= (point) before-point))
          (should (= (mark t) before-mark))
          (should (eq mark-active before-mark-active)))))))

(ert-deftest
    proofread-llm-test-structured-response-rejects-string-escapes ()
  "Forbid docstring edits to escapes or quoted characters."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\"Say \\\"helo\\\".\"")
    (let ((request (list :buffer (current-buffer)
                         :beg (point-min)
                         :end (point-max)
                         :text (buffer-string)
                         :target-kind 'docstring)))
      (dolist (candidate '( (5 6 "\\") (6 7 "\"")))
        (should
         (eq (proofread-llm-test--structured-issue-reason
              request
              (proofread-llm-test--response-diagnostic
               (nth 0 candidate) (nth 1 candidate) (nth 2 candidate)
               '( "")))
             'outside-target))))))

(ert-deftest
    proofread-llm-test-structured-response-cross-boundary-range
    ()
  "Accept diagnostic ranges across word-like boundaries."
  (let* ((request '( :beg 1
                     :end 15
                     :text "小城的街到刚刚醒来。"))
         (content
          (proofread-llm-test--response-for-range
           3 5 "街到" '( "街道")))
         (diagnostic
          (car
           (plist-get
            (proofread-llm--parse-structured-response
             request content 'llm)
            :diagnostics))))
    (should diagnostic)
    (should (= (plist-get diagnostic :beg) 4))
    (should (= (plist-get diagnostic :end) 6))))

(ert-deftest
    proofread-llm-test-structured-response-without-range-and-text-is-rejected
    ()
  "Diagnostics without authoritative range and text are rejected."
  (let* ((request '( :beg 1 :end 5 :text "青晨六点"))
         (content
          (proofread-llm-test--response-content
           (list '(("kind" . "spelling")
                   ("message" . "Possible misspelling")
                   ("suggestions" . ["清晨"]))))))
    (let ((batch
           (proofread-llm--parse-structured-response
            request content 'llm)))
      (should-not (plist-get batch :diagnostics))
      (should (eq (plist-get (car (plist-get batch :issues)) :reason)
                  'invalid-shape)))))

(ert-deftest
    proofread-llm-test-structured-response-parsed-results-still-stale-check
    ()
  "Apply stale validation to parsed structured diagnostics."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-llm-test--response-for-range 0 4 "helo"))
           (diagnostics
            (plist-get
             (proofread-llm--parse-structured-response
              request content 'llm)
             :diagnostics)))
      (goto-char (point-max))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request diagnostics))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays)
      (should (equal (buffer-string) "helo!")))))

;;;; Cache, callbacks, and logging

(ert-deftest
    proofread-llm-test-structured-response-strategy-cache-miss ()
  "Miss cached responses when the LLM response strategy changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((proofread-llm-provider proofread-llm-test--provider)
                                             (proofread-llm-provider-identity "provider")
                                             (proofread-llm-response-strategy 'provider-json)
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range 1 5 "helo")))
                                        (proofread-llm-test--with-capabilities
                                         (let ((request
                                                (proofread-llm-test--make-profile-request chunk)))
                                           (proofread--cache-write-request request (list diagnostic))
                                           (should (proofread--cache-read-request
                                                    (proofread-llm-test--make-profile-request chunk)))
                                           (let ((proofread-llm-response-strategy 'prompt-json))
                                             (should-not
                                              (proofread--cache-read-request
                                               (proofread-llm-test--make-profile-request
                                                chunk))))))))))

(ert-deftest proofread-llm-test-diagnostic-passes-cache-miss ()
  "Cache entries miss when LLM diagnostic pass count changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (proofread-llm-test--with-profile nil
                                      (let* ((proofread-llm-provider proofread-llm-test--provider)
                                             (proofread-llm-provider-identity "provider")
                                             (proofread-llm-max-diagnostic-passes 1)
                                             (chunk (proofread-llm-test--whole-buffer-chunk))
                                             (request
                                              (proofread-llm-test--make-profile-request chunk))
                                             (diagnostic
                                              (proofread-llm-test--diagnostic-for-range 1 5 "helo")))
                                        (proofread--cache-write-request request (list diagnostic))
                                        (should (proofread--cache-read-request
                                                 (proofread-llm-test--make-profile-request chunk)))
                                        (let ((proofread-llm-max-diagnostic-passes 2))
                                          (should-not (proofread--cache-read-request
                                                       (proofread-llm-test--make-profile-request
                                                        chunk))))))))

(ert-deftest
    proofread-llm-test-checker-instructions-identity-cache-miss ()
  "Checker-local instruction identity participates in cache keys."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider proofread-llm-test--provider)
           (proofread-llm-provider-identity "global-provider")
           (profile '( :name multi :language "en-US"))
           (base-checker
            '( :profile multi
               :name local
               :backend llm
               :options ( :provider proofread-llm-test-provider
                          :provider-identity "checker-provider"
                          :instructions-function ignore
                          :instructions-identity "instructions-a")))
           (changed-function-checker
            '( :profile multi
               :name local
               :backend llm
               :options ( :provider proofread-llm-test-provider
                          :provider-identity "checker-provider"
                          :instructions-function identity
                          :instructions-identity "instructions-a")))
           (changed-identity-checker
            '( :profile multi
               :name local
               :backend llm
               :options ( :provider proofread-llm-test-provider
                          :provider-identity "checker-provider"
                          :instructions-function ignore
                          :instructions-identity "instructions-b")))
           (chunk (proofread-llm-test--whole-buffer-chunk))
           (request
            (proofread--make-backend-request
             chunk 'llm base-checker profile))
           (diagnostic
            (proofread-llm-test--diagnostic-for-range 1 5 "helo")))
      (proofread--cache-write-request request (list diagnostic))
      (should
       (proofread--cache-read-request
        (proofread--make-backend-request
         chunk 'llm changed-function-checker profile)))
      (should-not
       (proofread--cache-read-request
        (proofread--make-backend-request
         chunk 'llm changed-identity-checker profile)))
      (should-not
       (string-match-p
        (regexp-quote "instructions-function")
        (prin1-to-string (plist-get request :cache-key)))))))

(ert-deftest
    proofread-llm-test-instructions-function-requires-identity ()
  "Reject extra instructions without a stable cache identity."
  (let ((proofread-llm-instructions-function #'ignore)
        (proofread-llm-instructions-identity nil))
    (should-error (proofread-llm--provider-identity)
                  :type 'user-error)))

(ert-deftest
    proofread-llm-test-structured-response-stale-result-is-dropped ()
  "Structured successful results still require stale validation."
  (with-temp-buffer
    (insert "青晨")
    (proofread-mode 1)
    (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
           (request (proofread--make-backend-request chunk 'llm))
           (content
            (proofread-llm-test--response-for-range 0 2 "青晨"))
           (diagnostics
            (plist-get
             (proofread-llm--parse-structured-response
              request content 'llm)
             :diagnostics)))
      (goto-char (point-max))
      (insert "!")
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request diagnostics))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-llm-test-backend-success-is-asynchronous ()
  "LLM backend success callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-llm-test--with-success
     (proofread-llm-test--response-content nil)
     (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
            (request (proofread--make-backend-request chunk))
            result)
       (should (proofread--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm))
       (should-not result)
       (should (proofread-llm-test--wait-for (lambda () result)))
       (should (eq (plist-get result :status) 'ok))
       (should (eq (plist-get result :request) request))
       (should (listp (plist-get result :diagnostics)))))))

(ert-deftest proofread-llm-test-backend-error-is-asynchronous ()
  "LLM backend error callbacks happen after dispatch returns."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-llm-test--with-error
     'llm-failure "LLM failure"
     (let* ((chunk (proofread-llm-test--whole-buffer-chunk))
            (request (proofread--make-backend-request chunk))
            result)
       (should (proofread--backend-check
                request
                (lambda (backend-result)
                  (setq result backend-result))
                'llm))
       (should-not result)
       (should (proofread-llm-test--wait-for (lambda () result)))
       (should (eq (plist-get result :status) 'error))
       (should (eq (plist-get result :request) request))
       (should (eq (plist-get result :error) 'llm-failure))
       (should (equal (plist-get result :message) "LLM failure"))))))

(ert-deftest proofread-llm-test-request-log-hook-observes-lifecycle ()
  "Expose LLM request stages and final status in request events."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((proofread-llm-provider 'proofread-llm-test-provider)
           (proofread-llm-max-diagnostic-passes 1)
           (content
            (proofread-llm-test--response-content
             (list
              (proofread-llm-test--response-diagnostic 1 5 "helo")
              (proofread-llm-test--response-diagnostic 0 4 "hola"))))
           request
           events
           status)
      (cl-letf (((symbol-function 'llm-chat-async)
                 (lambda (_provider _prompt success _error
                                    &optional _multi-output)
                   (run-at-time 0 nil (lambda () (funcall success
                                                          content)))
                   'proofread-llm-test-handle))
                ((symbol-function 'llm-capabilities)
                 #'proofread-llm-test--capabilities))
        (setq request
              (proofread--make-backend-request
               (proofread-llm-test--whole-buffer-chunk)
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
          (should (proofread-llm-test--wait-for (lambda () status)))
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
            (should
             (stringp (plist-get backend-request :schema)))
            (should
             (> (length (plist-get backend-request :schema)) 0))
            (should-not (plist-member backend-request :prompt))
            (should (string-match-p
                     "helo"
                     (plist-get backend-request :prompt-text)))
            (should (equal (plist-get backend-response :response)
                           content))
            (let ((logged-result
                   (plist-get backend-result :result)))
              (should (eq (plist-get logged-result :status) 'ok))
              (should (plist-get logged-result :partial))
              (should (plist-get logged-result :diagnostics))
              (should-not
               (plist-member logged-result :candidate-issues))
              (should-not (plist-member logged-result :repairs)))
            (should (eq (plist-get final-result :status)
                        'applied))))))))

(provide 'proofread-llm-tests)
;;; proofread-llm-tests.el ends here
