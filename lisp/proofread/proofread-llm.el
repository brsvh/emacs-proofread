;;; proofread-llm.el --- LLM backend for Proofread  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Assisted-by: Codex:gpt-5.5
;; Assisted-by: Codex:gpt-5.6-sol
;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.

;; This file is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library implements the GNU ELPA llm backend for Proofread.
;; Requiring it registers the `llm' backend with the core library.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'llm)
(require 'proofread)
(require 'subr-x)
(require 'warnings)

(defcustom proofread-llm-provider nil
  "Provider object used when `proofread-backend' is `llm'.
Users should configure this with a provider constructor from the GNU
ELPA `llm' package."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-response-strategy 'auto
  "How the LLM backend requests structured diagnostics.
The value `auto' uses provider-enforced JSON schema output when the
provider advertises `json-response', and otherwise falls back to
prompt-only JSON.  The value `provider-json' requires `json-response'.
The value `prompt-json' always uses ordinary chat output and asks the
model to return only JSON."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Provider JSON schema" provider-json)
                 (const :tag "Prompt-only JSON" prompt-json))
  :group 'proofread)

(defcustom proofread-llm-provider-identity nil
  "Stable cache identity for `proofread-llm-provider'.
When nil, proofread combines `llm-name' with a session-local provider
identity.  Set this to a stable, non-secret value to share cache
entries across equivalent provider objects in the same buffer."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-max-diagnostic-passes 3
  "Maximum LLM passes used to find diagnostics for one request.
Additional passes ask only for problems not already reported.  A value
of 1 uses a single LLM call."
  :type 'natnum
  :set #'proofread--set-positive-integer-option
  :group 'proofread)

(defconst proofread-llm--contract-version 2
  "Version of the LLM prompt, response, and cache identity contract.")

(defconst proofread-llm--diagnostic-kind-names
  (vconcat (mapcar #'symbol-name proofread--diagnostic-kinds))
  "Diagnostic kind names accepted by the structured response schema.")

(defconst proofread-llm--structured-response-instructions
  (concat
   "Return proofreading diagnostics that match the requested "
   "response schema.  Do not include Markdown, comments, prose, or "
   "reasoning outside the structured response.\n"
   "The top-level response has a diagnostics array.  Each "
   "diagnostic has "
   "kind, message, text, range, and suggestions fields.\n"
   "Report every independent problem in Text.  Do not stop after "
   "the first problem in a sentence; when one sentence has multiple "
   "misspellings, grammar "
   "issues, or style issues, return one diagnostic per issue.\n"
   "Prefer the smallest exact text range that identifies each issue, "
   "and keep diagnostics separate unless one correction requires a "
   "single combined "
   "range.\n"
   "For Chinese text, also check adjacent characters that may form "
   "one misspelled word; a diagnostic may cover multiple adjacent "
   "characters.\n"
   "Report diagnostics only for the Text section.  Use context "
   "before and context after only to understand the Text; never "
   "return ranges or text "
   "from context.\n"
   "When Target kind is comment or docstring, check only "
   "natural-language prose.  Never report comment delimiters, string "
   "quotes, indentation, "
   "program code, or markup as proofreading problems.\n"
   "Use zero-based chunk-relative offsets; range end is exclusive.\n"
   "The text field must exactly equal the substring selected by "
   "range.\n"
   "Use kind values spelling, grammar, style, or other.\n"
   "For suggestions, return practical replacement text in "
   "best-first order.  Include multiple suggestions when several "
   "distinct corrections are useful; one suggestion or an empty "
   "suggestions array is acceptable when there is no "
   "real alternative.\n"
   "Use an empty diagnostics array when there are no diagnostics.\n")
  "Provider-independent instructions for structured responses.")

(defconst proofread-llm--structured-response-schema
  `(:type "object"
          :properties
          (:diagnostics
           (:type "array"
                  :items
                  (:type "object"
                         :properties
                         (:kind
                          (:type "string"
                                 :enum
                                 ,proofread-llm--diagnostic-kind-names)
                          :message (:type "string")
                          :text (:type "string")
                          :range
                          (:type "object"
                                 :properties
                                 (:beg
                                  (:type "integer")
                                  :end
                                  (:type "integer"))
                                 :required ["beg" "end"]
                                 :additionalProperties ,json-false)
                          :suggestions
                          (:type "array"
                                 :items
                                 (:type "string")))
                         :required ["kind" "message" "text" "range"
                                    "suggestions"]
                         :additionalProperties ,json-false)))
          :required ["diagnostics"])
  "JSON schema for structured LLM responses.")

(defun proofread-llm--backend-invalid-diagnostics-result
    (request candidate-issues repairs)
  "Return an error for REQUEST with no usable diagnostic candidates.
CANDIDATE-ISSUES and REPAIRS describe the responses that were
rejected."
  (proofread--backend-result-with-diagnostic-metadata
   (proofread--backend-error-result
    request 'llm-invalid-diagnostics
    (format (concat "No usable diagnostic candidates after %d "
                    "rejected candidate%s")
            (length candidate-issues)
            (if (= (length candidate-issues) 1) "" "s")))
   candidate-issues repairs))

(defun proofread-llm--structured-response-schema-text ()
  "Return the diagnostic response schema as JSON text."
  (json-encode proofread-llm--structured-response-schema))

(defun proofread-llm--prompt-json-response-contract ()
  "Return extra instructions for prompt-only JSON responses."
  (concat
   "The provider is not enforcing the schema.  Return exactly "
   "one JSON object that matches this schema, with no Markdown code "
   "fence and no "
   "other text.\n"
   "JSON schema:\n"
   (proofread-llm--structured-response-schema-text)
   "\n"))

(defun proofread-llm--reported-diagnostic-line (request diagnostic)
  "Return a prompt line for REQUEST's reported DIAGNOSTIC."
  (let ((request-beg (plist-get request :beg)))
    (format "- range [%d,%d], text %S, kind %S, message %S\n"
            (- (plist-get diagnostic :beg) request-beg)
            (- (plist-get diagnostic :end) request-beg)
            (plist-get diagnostic :text)
            (plist-get diagnostic :kind)
            (plist-get diagnostic :message))))

(defun proofread-llm--reported-diagnostics-prompt (request diagnostics)
  "Return prompt text for REQUEST's reported DIAGNOSTICS."
  (when diagnostics
    (concat
     "Already reported diagnostics for this same Text:\n"
     (mapconcat
      (lambda (diagnostic)
        (proofread-llm--reported-diagnostic-line request diagnostic))
      diagnostics
      "")
     "Return only additional diagnostics not already "
     "reported above.  "
     "Do not repeat diagnostics with the same range, text, kind, and "
     "message.  Scan "
     "the full Text "
     "again, especially unreported words and text spans before, "
     "after, "
     "and between the listed ranges.  Use an empty diagnostics array "
     "when no "
     "additional problems remain.\n\n")))

(defun proofread-llm--structured-response-prompt
    (request &optional prompt-json reported-diagnostics)
  "Return the provider-independent proofreading prompt for REQUEST.
When PROMPT-JSON is non-nil, include the prompt-only JSON contract.
Describe any REPORTED-DIAGNOSTICS so a later pass does not repeat
them."
  (format
   (concat "Proofread the following text.\n\n"
           "%s\n"
           "%s"
           "%s"
           "Language: %S\n"
           "Major mode: %S\n"
           "Target kind: %S\n\n"
           "Context before:\n%s\n\n"
           "Text:\n%s\n\n"
           "Context after:\n%s\n")
   proofread-llm--structured-response-instructions
   (or (proofread-llm--reported-diagnostics-prompt
        request reported-diagnostics)
       "")
   (if prompt-json
       (proofread-llm--prompt-json-response-contract)
     "")
   (plist-get request :language)
   (plist-get request :major-mode)
   (plist-get request :target-kind)
   (or (plist-get request :context-before) "")
   (or (plist-get request :text) "")
   (or (plist-get request :context-after) "")))

(defconst proofread-llm--json-keywords
  '(("diagnostics" . :diagnostics)
    ("kind" . :kind)
    ("message" . :message)
    ("text" . :text)
    ("range" . :range)
    ("beg" . :beg)
    ("end" . :end)
    ("suggestions" . :suggestions))
  "Known structured-response JSON keys and their Lisp keywords.")

(defconst proofread-llm--empty-json-object 'proofread-llm--empty-json-object
  "Sentinel preserving an empty JSON object's type.")

(defconst proofread-llm--json-false 'proofread-llm--json-false
  "Sentinel preserving a JSON false value's type.")

(defconst proofread-llm--json-null 'proofread-llm--json-null
  "Sentinel preserving a JSON null value's type.")

(defun proofread-llm--json-object-keys (context)
  "Return allowed JSON object keys for CONTEXT."
  (pcase context
    ('root '("diagnostics"))
    ('candidate '("kind" "message" "text" "range" "suggestions"))
    ('range '("beg" "end"))
    (_ nil)))

(defun proofread-llm--json-child-context (context key)
  "Return child JSON context below CONTEXT at KEY."
  (pcase (cons context key)
    (`(root . "diagnostics") 'diagnostics)
    (`(candidate . "range") 'range)
    (`(candidate . "suggestions") 'suggestions)))

(defun proofread-llm--normalize-json-value (value context)
  "Return VALUE converted from JSON data for CONTEXT."
  (cond
   ((listp value)
    (if (null value)
        proofread-llm--empty-json-object
      (let ((seen (make-hash-table :test #'equal))
            plist)
        (dolist (field value)
          (let ((key (car field))
                (item (cdr field)))
            (unless (member key (proofread-llm--json-object-keys context))
              (error "Unexpected %s field: %s" context key))
            (when (gethash key seen)
              (error "Duplicate %s field: %s" context key))
            (puthash key t seen)
            (setq plist
                  (plist-put
                   plist (cdr (assoc key proofread-llm--json-keywords))
                   (proofread-llm--normalize-json-value
                    item
                    (proofread-llm--json-child-context context key))))))
        (or plist proofread-llm--empty-json-object))))
   ((vectorp value)
    (let ((child-context
           (pcase context
             ('diagnostics 'candidate)
             ('suggestions 'suggestion))))
      (vconcat
       (mapcar (lambda (item)
                 (if (eq child-context 'candidate)
                     (condition-case err
                         (proofread-llm--normalize-json-value
                          item child-context)
                       (error
                        (list :candidate-error
                              (error-message-string err))))
                   (proofread-llm--normalize-json-value
                    item child-context)))
               value))))
   (t value)))

(defun proofread-llm--json-read-string (string)
  "Read STRING as normalized structured-response JSON data."
  ;; First use the native parser for strict syntax validation.  Its
  ;; alist representation interns object keys, so use a hash table
  ;; here and then read again with string keys to retain duplicates
  ;; without growing obarray.
  (ignore
   (json-parse-string
    string
    :object-type 'hash-table
    :array-type 'array
    :null-object proofread-llm--json-null
    :false-object proofread-llm--json-false))
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((json-object-type 'alist)
          (json-array-type 'vector)
          (json-key-type 'string)
          (json-null proofread-llm--json-null)
          (json-false proofread-llm--json-false))
      (proofread-llm--normalize-json-value (json-read) 'root))))

(defun proofread-llm--structured-response-payload (content)
  "Return structured response payload from CONTENT."
  (unless (stringp content)
    (error "Structured response content is not JSON text"))
  (proofread-llm--json-read-string content))

(defun proofread-llm--diagnostic-batch-from-structured-response
    (request content &optional default-source)
  "Return parsed diagnostic batch for REQUEST from response CONTENT.
Use DEFAULT-SOURCE when it is non-nil."
  (proofread--diagnostic-batch-from-structured-payload
   request
   (proofread-llm--structured-response-payload content)
   default-source))

(defun proofread-llm--diagnostics-from-structured-response
    (request content &optional default-source)
  "Return diagnostics for REQUEST from structured response CONTENT.
Use DEFAULT-SOURCE when it is non-nil."
  (proofread--diagnostics-from-structured-payload
   request
   (proofread-llm--structured-response-payload content)
   default-source))

(defun proofread-llm--prompt
    (request strategy &optional reported-diagnostics)
  "Return an `llm-chat-prompt' for REQUEST using STRATEGY.
REPORTED-DIAGNOSTICS are included to avoid duplicates across passes."
  (pcase strategy
    ('provider-json
     (llm-make-chat-prompt
      (proofread-llm--structured-response-prompt
       request nil reported-diagnostics)
      :response-format proofread-llm--structured-response-schema))
    ('prompt-json
     (llm-make-chat-prompt
      (proofread-llm--structured-response-prompt
       request t reported-diagnostics)))
    (_ (error "Unsupported llm response strategy: %S" strategy))))

(defun proofread-llm--response-content (response)
  "Return structured response content from LLM RESPONSE."
  (unless (stringp response)
    (error "Invalid llm structured response"))
  response)

(defun proofread-llm--diagnostic-metadata-for-pass (items pass)
  "Return copies of diagnostic metadata ITEMS annotated with PASS."
  (mapcar (lambda (item)
            (plist-put (copy-sequence item) :pass pass))
          items))

(defun proofread-llm--success-result (request response &optional pass)
  "Return a backend result for REQUEST from LLM RESPONSE.
PASS identifies the diagnostic pass for request logging."
  (proofread--record-request-event
   request 'backend-response
   :backend 'llm
   :pass pass
   :response response)
  (let
      ((result
        (condition-case err
            (let*
                ((batch
                  (proofread-llm--diagnostic-batch-from-structured-response
                   request
                   (proofread-llm--response-content response)
                   'llm))
                 (diagnostics (plist-get batch :diagnostics))
                 (issues
                  (proofread-llm--diagnostic-metadata-for-pass
                   (plist-get batch :issues) pass))
                 (repairs
                  (proofread-llm--diagnostic-metadata-for-pass
                   (plist-get batch :repairs) pass)))
              (if issues
                  (proofread--backend-partial-success-result
                   request diagnostics issues repairs)
                (proofread--backend-success-result
                 request diagnostics nil repairs)))
          (error
           (proofread--backend-error-result
            request
            'llm-invalid-response
            (error-message-string err))))))
    (proofread--record-request-event
     request 'backend-result
     :backend 'llm
     :pass pass
     :result result)
    result))

(defun proofread-llm--error-result
    (request error &optional message pass)
  "Return a backend result for REQUEST from LLM ERROR and MESSAGE.
PASS identifies the diagnostic pass for request logging."
  (proofread--record-request-event
   request 'backend-response
   :backend 'llm
   :pass pass
   :error error
   :message message)
  (let ((result
         (proofread--backend-error-result
          request
          (or error 'llm-error)
          (if message
              (format "%s" message)
            (format "%S" error)))))
    (proofread--record-request-event
     request 'backend-result
     :backend 'llm
     :pass pass
     :result result)
    result))

(defun proofread-llm--provider-json-response-p (provider)
  "Return non-nil when PROVIDER advertises JSON response support."
  (condition-case nil
      (memq 'json-response (llm-capabilities provider))
    (error nil)))

(defun proofread-llm--response-strategy (&optional provider)
  "Return the actual LLM response strategy for PROVIDER, or nil.
When PROVIDER is nil, use `proofread-llm-provider'."
  (let ((provider (or provider proofread-llm-provider)))
    (when provider
      (pcase proofread-llm-response-strategy
        ('auto
         (if (proofread-llm--provider-json-response-p provider)
             'provider-json
           'prompt-json))
        ('provider-json
         (and (proofread-llm--provider-json-response-p provider)
              'provider-json))
        ('prompt-json 'prompt-json)
        (_ nil)))))

(defun proofread-llm--deliver-result (handle callback result)
  "Schedule RESULT for CALLBACK and record its timer in HANDLE."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered))
    (setf (plist-get handle :delivered) t)
    (setf (plist-get handle :timer)
          (proofread--defer-backend-callback callback result))))

(defun proofread-llm--diagnostic-passes ()
  "Return the configured number of diagnostic LLM passes."
  (unless (and (integerp proofread-llm-max-diagnostic-passes)
               (> proofread-llm-max-diagnostic-passes 0))
    (user-error "Proofread diagnostic pass count must be positive"))
  proofread-llm-max-diagnostic-passes)

(defun proofread-llm--finish-or-continue
    (request callback submit max-passes pass diagnostics
             candidate-issues repairs result &optional handle)
  "Handle one LLM RESULT for REQUEST and maybe call SUBMIT again.
CALLBACK receives the final result.  MAX-PASSES is the request-local
diagnostic pass limit; PASS is the current pass and DIAGNOSTICS are
results accumulated from earlier passes.  CANDIDATE-ISSUES and REPAIRS
are accumulated response metadata.  HANDLE carries cancellation
state."
  (cond
   ((and handle (plist-get handle :cancelled)) nil)
   ((and handle (not (proofread--request-continuable-p request)))
    (proofread-llm--deliver-result handle callback result))
   (t
    (pcase (plist-get result :status)
      ('ok
       (let* ((new-diagnostics (plist-get result :diagnostics))
              (merged (proofread--append-new-diagnostics
                       diagnostics new-diagnostics))
              (new-issues (plist-get result :candidate-issues))
              (merged-issues (append candidate-issues new-issues))
              (merged-repairs
               (append repairs (plist-get result :repairs)))
              (continue
               (and (< pass max-passes)
                    (or new-issues
                        (and merged-issues (null merged))
                        (> (length merged) (length diagnostics))))))
         (if continue
             (funcall submit
                      (1+ pass) merged merged-issues merged-repairs)
           (let ((final-result
                  (cond
                   ((and merged-issues (null merged))
                    (proofread-llm--backend-invalid-diagnostics-result
                     request merged-issues merged-repairs))
                   (merged-issues
                    (proofread--backend-partial-success-result
                     request merged merged-issues merged-repairs))
                   (t
                    (proofread--backend-success-result
                     request merged nil merged-repairs)))))
             (if handle
                 (proofread-llm--deliver-result
                  handle callback final-result)
               (proofread--defer-backend-callback
                callback final-result))))))
      (_
       (let ((final-result
              (cond
               (diagnostics
                (proofread--backend-partial-success-result
                 request diagnostics candidate-issues repairs))
               (candidate-issues
                (proofread--backend-result-with-diagnostic-metadata
                 result candidate-issues repairs))
               (t result))))
         (if handle
             (proofread-llm--deliver-result
              handle callback final-result)
           (proofread--defer-backend-callback
            callback final-result))))))))

(defun proofread-llm--submit-passes
    (provider strategy request callback handle)
  "Submit REQUEST to PROVIDER with STRATEGY and record HANDLE."
  (let ((max-passes (proofread-llm--diagnostic-passes)))
    (cl-labels
        ((submit (pass diagnostics candidate-issues repairs)
           (unless (plist-get handle :cancelled)
             (let (pass-finished)
               (cl-labels
                   ((finish (result)
                      (unless pass-finished
                        (setq pass-finished t)
                        (proofread-llm--finish-or-continue
                         request callback #'submit max-passes pass
                         diagnostics candidate-issues repairs
                         result handle))))
                 (condition-case err
                     (let ((prompt
                            (proofread-llm--prompt
                             request strategy diagnostics)))
                       (proofread--record-request-event
                        request 'backend-request
                        :backend 'llm
                        :pass pass
                        :max-passes max-passes
                        :strategy strategy
                        :prompt prompt
                        :prompt-text
                        (proofread-llm--request-log-prompt-text prompt)
                        :schema
                        (llm-chat-prompt-response-format prompt)
                        :reported-diagnostics diagnostics)
                       (let ((request-handle
                              (llm-chat-async
                               provider prompt
                               (lambda (response)
                                 (finish
                                  (proofread-llm--success-result
                                   request response pass)))
                               (lambda
                                 (error &optional message &rest _)
                                 (finish
                                  (proofread-llm--error-result
                                   request error message pass))))))
                         (push request-handle
                               (plist-get handle :requests))))
                   (error
                    (let ((result
                           (proofread--backend-error-result
                            request 'llm-submit-error
                            (error-message-string err))))
                      (proofread--record-request-event
                       request 'backend-result
                       :backend 'llm
                       :pass pass
                       :result result)
                      (finish result)))))))))
      (submit 1 nil nil nil)))
  handle)

(defun proofread-llm--backend-check (request callback)
  "Submit REQUEST asynchronously and invoke CALLBACK with its result."
  (cond
   ((not proofread-llm-provider)
    (let ((timer
           (proofread--defer-backend-callback
            callback
            (proofread--backend-error-result
             request 'llm-provider-unavailable
             "No proofread llm provider is configured"))))
      (list :backend 'llm
            :request nil
            :timer timer)))
   ((not (proofread-llm--response-strategy proofread-llm-provider))
    (let ((timer
           (proofread--defer-backend-callback
            callback
            (proofread--backend-error-result
             request 'llm-structured-output-unavailable
             "The configured llm response strategy is unavailable"))))
      (list :backend 'llm
            :request nil
            :timer timer)))
   (t
    (let* ((provider proofread-llm-provider)
           (strategy (proofread-llm--response-strategy provider))
           (handle (list :backend 'llm
                         :requests nil
                         :timer nil
                         :delivered nil
                         :cancelled nil)))
      (proofread-llm--submit-passes
       provider strategy request callback handle)))))

(defvar proofread-llm--provider-identity-sequence 0
  "Sequence for session-local LLM provider identities.")

(defvar proofread-llm--provider-session-identities
  (make-hash-table :test #'eq :weakness 'key)
  "Session-local identities for LLM provider objects.")

(defun proofread-llm--provider-session-identity (provider)
  "Return a non-secret session-local identity for PROVIDER."
  (or (gethash provider proofread-llm--provider-session-identities)
      (puthash provider
               (cl-incf proofread-llm--provider-identity-sequence)
               proofread-llm--provider-session-identities)))

(defun proofread-llm--provider-name ()
  "Return a stable display name for `proofread-llm-provider', or nil."
  (when proofread-llm-provider
    (condition-case nil
        (llm-name proofread-llm-provider)
      (error nil))))

(defun proofread-llm--provider-identity ()
  "Return stable cache identity for the configured LLM provider."
  (list :backend 'llm
        :provider
        (if proofread-llm-provider
            (or proofread-llm-provider-identity
                (list
                 :name
                 (or (proofread-llm--provider-name) 'unknown)
                 :session
                 (proofread-llm--provider-session-identity
                  proofread-llm-provider)))
          'unconfigured)
        :response-strategy
        (proofread-llm--response-strategy proofread-llm-provider)
        :diagnostic-passes (proofread-llm--diagnostic-passes)
        :contract-version proofread-llm--contract-version))

(defun proofread-llm--request-log-prompt-text (prompt)
  "Return a plain prompt text summary from PROMPT, or nil."
  (condition-case nil
      (mapconcat #'llm-chat-prompt-interaction-content
                 (llm-chat-prompt-interactions prompt)
                 "\n\n")
    (error nil)))

(defun proofread-llm--cancel-request-handle (handle)
  "Cancel the LLM requests recorded in backend HANDLE."
  (let ((warning-minimum-level :error)
        (warning-minimum-log-level :error))
    (dolist (request-handle
             (or (plist-get handle :requests)
                 (and (plist-get handle :request)
                      (list (plist-get handle :request)))))
      (ignore-errors
        (llm-cancel-request request-handle)))))

(proofread--register-backend
 'llm
 :check #'proofread-llm--backend-check
 :identity #'proofread-llm--provider-identity
 :cancel #'proofread-llm--cancel-request-handle)

(defun proofread-llm-unload-function ()
  "Unregister the LLM backend before unloading this library."
  (proofread--unregister-backend 'llm)
  nil)

(provide 'proofread-llm)

;;; proofread-llm.el ends here
