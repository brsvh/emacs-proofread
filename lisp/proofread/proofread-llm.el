;;; proofread-llm.el --- LLM backend  -*- lexical-binding: t; -*-

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

;;;; Options

(defun proofread-llm--validate-request-timeout (value)
  "Return request timeout VALUE, or signal an error when invalid."
  (unless (or (null value)
              (and (numberp value) (> value 0)))
    (error "Proofread LLM request timeout must be nil or a positive number"))
  value)

(defun proofread-llm--set-request-timeout-option (symbol value)
  "Set SYMBOL to request timeout VALUE as a Customize option."
  (proofread-llm--validate-request-timeout value)
  (set-default symbol value))

(defun proofread-llm--validate-source-label (value)
  "Return normalized LLM source label VALUE, or nil.
Signal an error unless a non-nil value is a nonempty string."
  (when value
    (unless (stringp value)
      (error "Proofread LLM source label must be nil or a string"))
    (let ((label
           (replace-regexp-in-string
            "[[:space:]]+" " "
            (string-trim (substring-no-properties value)))))
      (when (string-empty-p label)
        (error "Proofread LLM source label must not be empty"))
      label)))

(defun proofread-llm--set-source-label-option (symbol value)
  "Set SYMBOL to source label VALUE as a Customize option."
  (set-default symbol
               (proofread-llm--validate-source-label value)))

(defcustom proofread-llm-provider nil
  "Default provider object used by the LLM backend.
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
  :type '(choice
          (const :tag "Auto" auto)
          (const :tag "Provider JSON schema" provider-json)
          (const :tag "Prompt-only JSON" prompt-json))
  :group 'proofread)

(defcustom proofread-llm-provider-identity nil
  "Stable cache identity for `proofread-llm-provider'.
When nil, proofread combines `llm-name' with a non-secret identity
local to the current provider object and `proofread-llm' feature load.
Set this to a stable, non-secret value to reuse compatible cache
entries across equivalent provider objects and feature reloads in the
same buffer."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-source-label nil
  "Default display source label for LLM diagnostics.
When nil, use `llm-name' for the effective provider and fall back to
\"llm\" when that does not yield a usable label.  A checker-local
`:source-label' option overrides this value; an explicit nil uses the
automatic provider-name behavior for that checker.

This label is presentation metadata and does not participate in LLM
backend or checker cache identities."
  :type '(choice
          (const :tag "Automatic" nil)
          (string :tag "Source label"))
  :set #'proofread-llm--set-source-label-option
  :group 'proofread)

(defcustom proofread-llm-max-diagnostic-passes 3
  "Maximum LLM passes used to find diagnostics for one request.
Additional passes ask only for problems not already reported.  A value
of 1 uses a single LLM call."
  :type 'natnum
  :set #'proofread-set-positive-integer-option
  :group 'proofread)

(defcustom proofread-llm-request-timeout 120
  "Seconds before Proofread cancels one LLM backend request.
The timeout covers all diagnostic passes for that request.  A non-nil
value must be a positive number; set it to nil to disable the
Proofread-owned watchdog.  A checker-local `:request-timeout' option
overrides this value for that checker."
  :type '(choice
          (const :tag "Disabled" nil)
          (number :tag "Seconds"))
  :set #'proofread-llm--set-request-timeout-option
  :group 'proofread)

(defcustom proofread-llm-instructions-function nil
  "Function returning extra LLM instructions for one backend request.
When non-nil, the function is called with the backend request plist and
must return either nil or a string.  Configure
`proofread-llm-instructions-identity' with a stable, non-secret value
that changes whenever this function's effective instructions change."
  :type '(choice
          (const :tag "None" nil)
          function)
  :group 'proofread)

(defcustom proofread-llm-instructions-identity nil
  "Stable cache identity for `proofread-llm-instructions-function'.
This value is required whenever `proofread-llm-instructions-function'
is non-nil, because extra instructions can change LLM diagnostics."
  :type 'sexp
  :group 'proofread)

;;;; Provider state

(defvar proofread-llm--provider-identity-sequence 0
  "Sequence for session-local LLM provider identities.")

(defvar proofread-llm--provider-session-identities
  (make-hash-table :test #'eq :weakness 'key)
  "Session-local identities for LLM provider objects.")

(defvar proofread-llm--provider-load-discriminator
  (gensym "proofread-llm-provider-load-")
  "Non-secret discriminator for fallback identities from this load.")

(defvar proofread-llm--live-handles nil
  "LLM backend handles that have not settled or been cancelled.")

;;;; Structured response contract

(defconst proofread-llm--contract-version 3
  "Version of the LLM prompt, response, and cache identity contract.")

(defconst proofread-llm--empty-json-object
  'proofread-llm--empty-json-object
  "Sentinel preserving an empty JSON object's type.")

(defconst proofread-llm--json-false 'proofread-llm--json-false
  "Sentinel preserving a JSON false value's type.")

(defconst proofread-llm--json-null 'proofread-llm--json-null
  "Sentinel preserving a JSON null value's type.")

(defconst proofread-llm--diagnostic-kinds
  '( spelling grammar style other)
  "Diagnostic kind symbols accepted from structured responses.")

(defconst proofread-llm--diagnostic-kind-names
  (vconcat (mapcar #'symbol-name proofread-llm--diagnostic-kinds))
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
  `( :type "object"
     :properties
     ( :diagnostics
       ( :type "array"
         :items
         ( :type "object"
           :properties
           ( :kind ( :type "string"
                     :enum ,proofread-llm--diagnostic-kind-names)
             :message ( :type "string")
             :text ( :type "string")
             :range
             ( :type "object"
               :properties ( :beg ( :type "integer")
                             :end ( :type "integer"))
               :required ["beg" "end"]
               :additionalProperties ,json-false)
             :suggestions
             ( :type "array"
               :items ( :type "string")))
           :required ["kind" "message" "text" "range" "suggestions"]
           :additionalProperties ,json-false)))
     :required ["diagnostics"]
     :additionalProperties ,json-false)
  "JSON schema for structured LLM responses.")

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

(defun proofread-llm--reported-diagnostics-prompt
    (request diagnostics)
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

(defun proofread-llm--additional-instructions-prompt (request)
  "Return extra instruction prompt text for REQUEST, or nil."
  (when-let* ((function
               (proofread-llm--effective-instructions-function request)))
    (proofread-llm--validate-instructions-identity
     function
     (proofread-llm--effective-instructions-identity request))
    (let ((instructions (funcall function request)))
      (cond
       ((null instructions) nil)
       ((stringp instructions)
        (let ((instructions (string-trim instructions)))
          (unless (string-empty-p instructions)
            (format "Additional instructions:\n%s\n\n"
                    instructions))))
       (t
        (error (concat "Proofread LLM instructions function must "
                       "return nil or a string")))))))

(defun proofread-llm--request-language-prompt (request)
  "Return REQUEST's effective language prompt line, or nil."
  (when-let* ((language
               (or (plist-get request :display-language)
                   (plist-get request :language))))
    (format "Language: %S\n" language)))

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
           "%s"
           "%s"
           "Major mode: %S\n"
           "Target kind: %S\n\n"
           "Context before:\n%s\n\n"
           "Text:\n%s\n\n"
           "Context after:\n%s\n")
   proofread-llm--structured-response-instructions
   (or (proofread-llm--additional-instructions-prompt request)
       "")
   (or (proofread-llm--reported-diagnostics-prompt
        request reported-diagnostics)
       "")
   (if prompt-json
       (proofread-llm--prompt-json-response-contract)
     "")
   (or (proofread-llm--request-language-prompt request) "")
   (plist-get request :major-mode)
   (plist-get request :target-kind)
   (or (plist-get request :context-before) "")
   (or (plist-get request :text) "")
   (or (plist-get request :context-after) "")))

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

(defun proofread-llm--request-log-prompt-text (prompt)
  "Return a plain prompt text summary from PROMPT, or nil."
  (condition-case nil
      (mapconcat #'llm-chat-prompt-interaction-content
                 (llm-chat-prompt-interactions prompt)
                 "\n\n")
    (error nil)))

;;;; Structured response parsing

(defun proofread-llm--json-schema-property (schema key)
  "Return the property entry for string KEY in SCHEMA, or nil.
The entry is a cons whose car is the known keyword and whose cdr is
the child schema.  Unknown keys are not interned."
  (let ((properties (plist-get schema :properties))
        property)
    (while (and properties (not property))
      (let ((keyword (pop properties))
            (child-schema (pop properties)))
        (when (equal key (substring (symbol-name keyword) 1))
          (setq property (cons keyword child-schema)))))
    property))

(defun proofread-llm--normalize-json-value
    (value schema &optional context)
  "Return VALUE normalized according to SCHEMA.
CONTEXT names the containing object for error messages."
  (cond
   ((listp value)
    (if (null value)
        proofread-llm--empty-json-object
      (let ((seen (make-hash-table :test #'equal))
            plist)
        (dolist (field value)
          (let* ((key (car field))
                 (item (cdr field))
                 (property
                  (proofread-llm--json-schema-property schema key)))
            (unless property
              (error "Unexpected %s field: %s" context key))
            (when (gethash key seen)
              (error "Duplicate %s field: %s" context key))
            (puthash key t seen)
            (setq plist
                  (plist-put
                   plist (car property)
                   (proofread-llm--normalize-json-value
                    item (cdr property) key)))))
        (or plist proofread-llm--empty-json-object))))
   ((vectorp value)
    (let* ((child-schema (plist-get schema :items))
           (candidate-items-p
            (equal (plist-get child-schema :type) "object")))
      (vconcat
       (mapcar (lambda (item)
                 (if candidate-items-p
                     (condition-case err
                         (proofread-llm--normalize-json-value
                          item child-schema 'candidate)
                       (error
                        (list :candidate-error
                              (error-message-string err))))
                   (proofread-llm--normalize-json-value
                    item child-schema context)))
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
      (proofread-llm--normalize-json-value
       (json-read) proofread-llm--structured-response-schema 'root))))

(defun proofread-llm--structured-response-payload (content)
  "Return structured response payload from CONTENT."
  (unless (stringp content)
    (error "Structured response content is not JSON text"))
  (proofread-llm--json-read-string content))

(defun proofread-llm--diagnostic-candidates (payload)
  "Return diagnostic candidates from structured PAYLOAD."
  (unless (and (listp payload)
               (plist-member payload :diagnostics))
    (error "Missing diagnostics payload"))
  (let ((diagnostics (plist-get payload :diagnostics)))
    (unless (vectorp diagnostics)
      (error "Invalid diagnostics payload"))
    (append diagnostics nil)))

(defun proofread-llm--diagnostic-candidate-range (candidate)
  "Return CANDIDATE's chunk-relative range as a cons cell."
  (let ((range (plist-get candidate :range)))
    (when (and (listp range)
               (plist-member range :beg)
               (plist-member range :end))
      (cons (plist-get range :beg)
            (plist-get range :end)))))

(defun proofread-llm--string-occurrences (needle haystack)
  "Return zero-based ranges where NEEDLE occurs in HAYSTACK."
  (when (and (stringp needle)
             (not (string-empty-p needle))
             (stringp haystack))
    (let ((start 0)
          ranges)
      (while (setq start (string-search needle haystack start))
        (push (cons start (+ start (length needle))) ranges)
        (setq start (1+ start)))
      (nreverse ranges))))

(defun proofread-llm--diagnostic-candidate-matching-range
    (request candidate relative-beg relative-end)
  "Return CANDIDATE's safe chunk-relative range for REQUEST.
Prefer RELATIVE-BEG and RELATIVE-END when they select the candidate
text exactly.  Otherwise, repair the range only when that text occurs
exactly once in the request text."
  (let* ((request-text (plist-get request :text))
         (text (plist-get candidate :text))
         (reported-range (cons relative-beg relative-end)))
    (cond
     ((and (proofread--request-relative-range-valid-p
            request relative-beg relative-end)
           (stringp text)
           (equal text
                  (substring request-text relative-beg relative-end)))
      reported-range)
     ((and (integerp relative-beg)
           (integerp relative-end)
           (stringp text)
           (not (string-empty-p text)))
      (let ((ranges
             (proofread-llm--string-occurrences text request-text)))
        (when (= (length ranges) 1)
          (car ranges)))))))

(defun proofread-llm--diagnostic-candidate-kind (value)
  "Return normalized diagnostic kind for VALUE."
  (let ((kind
         (and (stringp value)
              (cdr (assoc value
                          '(("spelling" . spelling)
                            ("grammar" . grammar)
                            ("style" . style)
                            ("other" . other)))))))
    (when (memq kind proofread-llm--diagnostic-kinds)
      kind)))

(defun proofread-llm--diagnostic-candidate-shape-p (candidate)
  "Return non-nil when CANDIDATE has the required field shapes."
  (and (listp candidate)
       (let ((suggestions (plist-get candidate :suggestions)))
         (and
          (cl-every (lambda (key) (plist-member candidate key))
                    '( :kind :message :text :range :suggestions))
          (proofread-llm--diagnostic-candidate-kind
           (plist-get candidate :kind))
          (stringp (plist-get candidate :message))
          (stringp (plist-get candidate :text))
          (proofread-llm--diagnostic-candidate-range candidate)
          (vectorp suggestions)
          (cl-every #'stringp (append suggestions nil))))))

(defun proofread-llm--diagnostic-candidate-resolution
    (request candidate)
  "Return REQUEST's safe range resolution for CANDIDATE.
The returned plist has a `:status' of `exact', `repaired', or
`rejected'."
  (if (not (proofread-llm--diagnostic-candidate-shape-p candidate))
      (list :status 'rejected
            :reason (if (and (listp candidate)
                             (plist-member
                              candidate :candidate-error))
                        'invalid-candidate-json
                      'invalid-shape)
            :message (and (listp candidate)
                          (plist-get candidate :candidate-error)))
    (let* ((reported-range
            (proofread-llm--diagnostic-candidate-range candidate))
           (relative-beg (car reported-range))
           (relative-end (cdr reported-range))
           (text (plist-get candidate :text))
           (matching-range
            (proofread-llm--diagnostic-candidate-matching-range
             request candidate relative-beg relative-end)))
      (cond
       ((not matching-range)
        (let ((occurrences
               (proofread-llm--string-occurrences
                text (plist-get request :text))))
          (list :status 'rejected
                :reason
                (cond
                 ((or (not (integerp relative-beg))
                      (not (integerp relative-end)))
                  'invalid-range)
                 ((string-empty-p text) 'range-text-mismatch)
                 ((null occurrences) 'unmatched-text)
                 (t 'ambiguous-text))
                :reported-range reported-range
                :occurrences occurrences)))
       ((not (proofread--request-relative-range-in-target-p
              request matching-range))
        (list :status 'rejected
              :reason 'outside-target
              :reported-range reported-range
              :range matching-range))
       ((equal matching-range reported-range)
        (list :status 'exact :range matching-range))
       (t
        (list :status 'repaired
              :reported-range reported-range
              :range matching-range))))))

(defun proofread-llm--diagnostic-candidate-issue
    (index candidate resolution)
  "Return an issue for CANDIDATE at INDEX from RESOLUTION."
  (list :action 'dropped
        :candidate-index index
        :reason (plist-get resolution :reason)
        :message (plist-get resolution :message)
        :text (and (listp candidate)
                   (plist-get candidate :text))
        :reported-range
        (or
         (plist-get resolution :reported-range)
         (and
          (listp candidate)
          (proofread-llm--diagnostic-candidate-range candidate)))
        :resolved-range (plist-get resolution :range)
        :occurrences (plist-get resolution :occurrences)))

(defun proofread-llm--diagnostic-candidate-repair
    (index candidate resolution)
  "Return repair metadata for CANDIDATE at INDEX from RESOLUTION."
  (list :action 'repaired
        :candidate-index index
        :text (plist-get candidate :text)
        :reported-range (plist-get resolution :reported-range)
        :range (plist-get resolution :range)))

(defun proofread-llm--diagnostic-from-candidate
    (request candidate &optional default-source matching-range)
  "Return a diagnostic for REQUEST and CANDIDATE, or nil.
Use DEFAULT-SOURCE when it is non-nil.  MATCHING-RANGE, when non-nil,
is the already validated chunk-relative range for CANDIDATE."
  (let* ((range
          (proofread-llm--diagnostic-candidate-range candidate))
         (relative-beg (car-safe range))
         (relative-end (cdr-safe range))
         (matching-range
          (or matching-range
              (proofread-llm--diagnostic-candidate-matching-range
               request candidate relative-beg relative-end)))
         (text (plist-get candidate :text))
         (kind (proofread-llm--diagnostic-candidate-kind
                (plist-get candidate :kind)))
         (message (plist-get candidate :message)))
    (when (and matching-range
               (stringp text)
               kind
               (stringp message))
      (proofread--diagnostic-from-request-relative-range
       request matching-range
       (list :kind kind
             :message message
             :suggestions
             (append (plist-get candidate :suggestions) nil)
             :source
             (or default-source
                 (plist-get request :backend)
                 'unknown))))))

(defun proofread-llm--parse-structured-payload
    (request payload &optional default-source)
  "Return parsed diagnostic batch for REQUEST from PAYLOAD.
DEFAULT-SOURCE is stored as each diagnostic's internal source.
Candidate-level problems are returned in `:issues' instead of
invalidating the whole payload."
  (let ((index 0)
        diagnostics
        issues
        repairs)
    (dolist (candidate
             (proofread-llm--diagnostic-candidates payload))
      (let* ((resolution
              (proofread-llm--diagnostic-candidate-resolution
               request candidate))
             (status (plist-get resolution :status)))
        (pcase status
          ((or 'exact 'repaired)
           (let ((diagnostic
                  (proofread-llm--diagnostic-from-candidate
                   request candidate default-source
                   (plist-get resolution :range))))
             (if diagnostic
                 (progn
                   (push diagnostic diagnostics)
                   (when (eq status 'repaired)
                     (push
                      (proofread-llm--diagnostic-candidate-repair
                       index candidate resolution)
                      repairs)))
               (push (proofread-llm--diagnostic-candidate-issue
                      index candidate
                      (list :reason 'invalid-candidate))
                     issues))))
          ('rejected
           (push (proofread-llm--diagnostic-candidate-issue
                  index candidate resolution)
                 issues)))
        (setq index (1+ index))))
    (list :diagnostics (nreverse diagnostics)
          :issues (nreverse issues)
          :repairs (nreverse repairs))))

(defun proofread-llm--parse-structured-response
    (request content &optional default-source)
  "Return parsed diagnostic batch for REQUEST from response CONTENT.
Use DEFAULT-SOURCE when it is non-nil."
  (proofread-llm--parse-structured-payload
   request
   (proofread-llm--structured-response-payload content)
   default-source))

;;;; Backend results

(defun proofread-llm--result-with-candidate-metadata
    (result candidate-issues repairs)
  "Return RESULT with optional CANDIDATE-ISSUES and REPAIRS metadata."
  (when candidate-issues
    (setq result
          (plist-put result :candidate-issues candidate-issues)))
  (when repairs
    (setq result (plist-put result :repairs repairs)))
  result)

(defun proofread-llm--backend-invalid-diagnostics-result
    (request candidate-issues repairs)
  "Return an error for REQUEST with no usable diagnostic candidates.
CANDIDATE-ISSUES and REPAIRS describe the responses that were
rejected."
  (proofread-llm--result-with-candidate-metadata
   (proofread--backend-error-result
    request 'llm-invalid-diagnostics
    (format (concat "No usable diagnostic candidates after %d "
                    "rejected candidate%s")
            (length candidate-issues)
            (if (= (length candidate-issues) 1) "" "s")))
   candidate-issues repairs))

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
                  (proofread-llm--parse-structured-response
                   request response 'llm))
                 (diagnostics (plist-get batch :diagnostics))
                 (issues
                  (proofread-llm--diagnostic-metadata-for-pass
                   (plist-get batch :issues) pass))
                 (repairs
                  (proofread-llm--diagnostic-metadata-for-pass
                   (plist-get batch :repairs) pass)))
              (proofread-llm--result-with-candidate-metadata
               (if issues
                   (proofread--backend-partial-success-result
                    request diagnostics)
                 (proofread--backend-success-result
                  request diagnostics))
               issues repairs))
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

;;;; Provider selection and identity

(defun proofread-llm--provider-json-response-p (provider)
  "Return non-nil when PROVIDER advertises JSON response support."
  (condition-case nil
      (memq 'json-response (llm-capabilities provider))
    (error nil)))

(defun proofread-llm--source-options (source)
  "Return checker-local options from SOURCE, or nil.
SOURCE may be a backend request or a normalized profile checker."
  (or (plist-get source :checker-options)
      (plist-get source :options)))

(defun proofread-llm--option (source key fallback)
  "Return SOURCE checker option KEY, or FALLBACK when absent."
  (let ((options (proofread-llm--source-options source)))
    (if (plist-member options key)
        (plist-get options key)
      fallback)))

(defun proofread-llm--effective-provider (source)
  "Return the LLM provider effective for SOURCE."
  (proofread-llm--option
   source :provider proofread-llm-provider))

(defun proofread-llm--effective-provider-identity (source)
  "Return the stable provider identity effective for SOURCE."
  (proofread-llm--option
   source :provider-identity proofread-llm-provider-identity))

(defun proofread-llm--effective-source-label (source)
  "Return the configured display source label effective for SOURCE."
  (proofread-llm--option
   source :source-label proofread-llm-source-label))

(defun proofread-llm--effective-response-strategy (source)
  "Return the configured response strategy effective for SOURCE."
  (proofread-llm--option
   source :response-strategy proofread-llm-response-strategy))

(defun proofread-llm--effective-diagnostic-passes (source)
  "Return the diagnostic pass count effective for SOURCE."
  (proofread-llm--diagnostic-passes
   (proofread-llm--option
    source :diagnostic-passes
    proofread-llm-max-diagnostic-passes)))

(defun proofread-llm--effective-request-timeout (source)
  "Return the validated request timeout effective for SOURCE."
  (proofread-llm--validate-request-timeout
   (proofread-llm--option
    source :request-timeout proofread-llm-request-timeout)))

(defun proofread-llm--effective-instructions-function (source)
  "Return the extra-instructions function effective for SOURCE."
  (proofread-llm--option
   source :instructions-function proofread-llm-instructions-function))

(defun proofread-llm--effective-instructions-identity (source)
  "Return the extra-instructions identity effective for SOURCE."
  (proofread-llm--option
   source :instructions-identity
   proofread-llm-instructions-identity))

(defun proofread-llm--response-strategy
    (provider configured-strategy)
  "Return the actual LLM response strategy for PROVIDER, or nil.
CONFIGURED-STRATEGY is the user-selected response strategy before
capability fallback."
  (when provider
    (pcase configured-strategy
      ('auto
       (if (proofread-llm--provider-json-response-p provider)
           'provider-json
         'prompt-json))
      ('provider-json
       (and (proofread-llm--provider-json-response-p provider)
            'provider-json))
      ('prompt-json 'prompt-json)
      (_ nil))))

(defun proofread-llm--diagnostic-passes (passes)
  "Return PASSES after validating it as a positive integer."
  (unless (and (integerp passes)
               (> passes 0))
    (user-error "Proofread diagnostic pass count must be positive"))
  passes)

(defun proofread-llm--provider-session-identity (provider)
  "Return a non-secret session-local identity for PROVIDER."
  (or (gethash provider proofread-llm--provider-session-identities)
      (puthash provider
               (cl-incf proofread-llm--provider-identity-sequence)
               proofread-llm--provider-session-identities)))

(defun proofread-llm--provider-name (provider)
  "Return a stable display name for PROVIDER, or nil."
  (when provider
    (condition-case nil
        (llm-name provider)
      (error nil))))

(defun proofread-llm--safe-provider-source-label (provider)
  "Return PROVIDER's safe display source label, or nil."
  (condition-case nil
      (proofread-llm--validate-source-label
       (proofread-llm--provider-name provider))
    (error nil)))

(defun proofread-llm--checker-source-label (checker)
  "Return the display source label for normalized profile CHECKER."
  (or (proofread-llm--validate-source-label
       (proofread-llm--effective-source-label checker))
      (proofread-llm--safe-provider-source-label
       (proofread-llm--effective-provider checker))
      "llm"))

(defun proofread-llm--validate-instructions-identity
    (instructions-function instructions-identity)
  "Require INSTRUCTIONS-IDENTITY when INSTRUCTIONS-FUNCTION is non-nil."
  (when (and instructions-function (null instructions-identity))
    (user-error (concat "Proofread LLM instructions identity must be "
                        "non-nil when instructions function is "
                        "configured"))))

(defun proofread-llm--identity-for-source (source)
  "Return stable cache identity for SOURCE's effective LLM settings."
  (let* ((provider (proofread-llm--effective-provider source))
         (provider-identity
          (proofread-llm--effective-provider-identity source))
         (response-strategy
          (proofread-llm--response-strategy
           provider
           (proofread-llm--effective-response-strategy source)))
         (diagnostic-passes
          (proofread-llm--effective-diagnostic-passes source))
         (instructions-function
          (proofread-llm--effective-instructions-function source))
         (instructions-identity
          (proofread-llm--effective-instructions-identity source)))
    (proofread-llm--validate-instructions-identity
     instructions-function instructions-identity)
    (list :backend 'llm
          :provider
          (if provider
              (or provider-identity
                  (list
                   :name
                   (or (proofread-llm--provider-name provider)
                       'unknown)
                   :load proofread-llm--provider-load-discriminator
                   :session
                   (proofread-llm--provider-session-identity
                    provider)))
            'unconfigured)
          :response-strategy response-strategy
          :diagnostic-passes diagnostic-passes
          :instructions-identity
          (and instructions-function instructions-identity)
          :contract-version proofread-llm--contract-version)))

(defun proofread-llm--provider-identity ()
  "Return stable cache identity for the configured LLM provider."
  (proofread-llm--identity-for-source nil))

(defun proofread-llm--checker-identity (checker)
  "Return stable cache identity for normalized profile CHECKER."
  (proofread-llm--identity-for-source checker))

;;;; Request execution

(defun proofread-llm--new-handle
    (request callback request-timeout)
  "Return and register an LLM handle for REQUEST and CALLBACK.
REQUEST-TIMEOUT is the snapshotted Proofread watchdog duration."
  (let ((handle (list :backend 'llm
                      :request request
                      :callback callback
                      :request-timeout request-timeout
                      :requests nil
                      :timer nil
                      :watchdog-timer nil
                      :delivered nil
                      :settled nil
                      :cancelled nil)))
    (push handle proofread-llm--live-handles)
    handle))

(defun proofread-llm--cancel-watchdog (handle)
  "Cancel and clear HANDLE's watchdog timer."
  (let ((timer (plist-get handle :watchdog-timer)))
    (setf (plist-get handle :watchdog-timer) nil)
    (when (timerp timer)
      (ignore-errors
        (cancel-timer timer)))))

(defun proofread-llm--cancel-handle-work (handle)
  "Cancel and clear provider requests and timers in HANDLE."
  (let ((request-handles (plist-get handle :requests))
        (timer (plist-get handle :timer))
        (warning-minimum-level :error)
        (warning-minimum-log-level :error))
    (setf (plist-get handle :requests) nil)
    (setf (plist-get handle :timer) nil)
    (when (timerp timer)
      (ignore-errors
        (cancel-timer timer)))
    (proofread-llm--cancel-watchdog handle)
    (dolist (request-handle request-handles)
      (ignore-errors
        (llm-cancel-request request-handle)))))

(defun proofread-llm--watchdog-expired (handle)
  "Cancel and settle HANDLE after its request watchdog expires."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered)
              (plist-get handle :settled))
    ;; Claim the terminal state before provider cancellation because
    ;; cancellation may invoke provider callbacks synchronously.
    (setf (plist-get handle :cancelled) t)
    (setf (plist-get handle :delivered) t)
    (setf (plist-get handle :settled) t)
    (setq proofread-llm--live-handles
          (delq handle proofread-llm--live-handles))
    (proofread-llm--cancel-handle-work handle)
    (let* ((request (plist-get handle :request))
           (message "LLM request timed out")
           (result
            (proofread--backend-error-result
             request 'llm-request-timeout message)))
      (proofread--record-request-event
       request 'backend-response
       :backend 'llm
       :error 'llm-request-timeout
       :message message)
      (proofread--record-request-event
       request 'backend-result
       :backend 'llm
       :result result)
      (when-let* ((callback (plist-get handle :callback)))
        (funcall callback result)))))

(defun proofread-llm--arm-watchdog (handle)
  "Arm HANDLE's Proofread-owned request watchdog."
  (when-let* ((timeout (plist-get handle :request-timeout)))
    (let ((timer
           (run-at-time
            timeout nil
            (lambda ()
              ;; This closure may outlive the unloaded feature.  Do
              ;; not call a library function before the inline guard.
              (unless (or (plist-get handle :cancelled)
                          (plist-get handle :delivered)
                          (plist-get handle :settled))
                (proofread-llm--watchdog-expired handle))))))
      (if (or (plist-get handle :cancelled)
              (plist-get handle :delivered)
              (plist-get handle :settled))
          (when (timerp timer)
            (ignore-errors
              (cancel-timer timer)))
        (setf (plist-get handle :watchdog-timer) timer))))
  handle)

(defun proofread-llm--settle-handle (handle result)
  "Deliver RESULT through HANDLE at most once."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :settled))
    (setf (plist-get handle :settled) t)
    (setf (plist-get handle :timer) nil)
    (setf (plist-get handle :requests) nil)
    (proofread-llm--cancel-watchdog handle)
    (setq proofread-llm--live-handles
          (delq handle proofread-llm--live-handles))
    (when-let* ((callback (plist-get handle :callback)))
      (funcall callback result))))

(defun proofread-llm--deliver-result (handle result)
  "Schedule RESULT for delivery through HANDLE."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered)
              (plist-get handle :settled))
    (setf (plist-get handle :delivered) t)
    (proofread-llm--cancel-watchdog handle)
    (setf (plist-get handle :timer)
          (proofread--defer-backend-callback
           (lambda (deferred-result)
             ;; This inline guard must not call a library function:
             ;; the timer may run after `proofread-llm' is unloaded.
             (unless (or (plist-get handle :cancelled)
                         (plist-get handle :settled))
               (proofread-llm--settle-handle
                handle deferred-result)))
           result))))

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
   ((and handle
         (or (plist-get handle :cancelled)
             (plist-get handle :settled)))
    nil)
   ((and handle (not (proofread--request-continuable-p request)))
    (proofread-llm--deliver-result handle result))
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
                    (proofread-llm--result-with-candidate-metadata
                     (proofread--backend-partial-success-result
                      request merged)
                     merged-issues merged-repairs))
                   (t
                    (proofread-llm--result-with-candidate-metadata
                     (proofread--backend-success-result
                      request merged)
                     nil merged-repairs)))))
             (if handle
                 (proofread-llm--deliver-result
                  handle final-result)
               (proofread--defer-backend-callback
                callback final-result))))))
      (_
       (let ((final-result
              (cond
               (diagnostics
                (proofread-llm--result-with-candidate-metadata
                 (proofread--backend-partial-success-result
                  request diagnostics)
                 candidate-issues repairs))
               (candidate-issues
                (proofread-llm--result-with-candidate-metadata
                 result candidate-issues repairs))
               (t result))))
         (if handle
             (proofread-llm--deliver-result
              handle final-result)
           (proofread--defer-backend-callback
            callback final-result))))))))

(defun proofread-llm--submit-passes
    (provider strategy max-passes request callback handle)
  "Submit REQUEST to PROVIDER with STRATEGY and record HANDLE.
MAX-PASSES is the request-local diagnostic pass limit."
  (cl-labels
      ((submit (pass diagnostics candidate-issues repairs)
         (unless (or (plist-get handle :cancelled)
                     (plist-get handle :settled))
           (let (pass-finished)
             (cl-labels
                 ((finish (result)
                    (unless (or pass-finished
                                (plist-get handle :cancelled)
                                (plist-get handle :settled))
                      (setq pass-finished t)
                      (proofread-llm--finish-or-continue
                       request callback #'submit max-passes pass
                       diagnostics candidate-issues repairs
                       result handle)))
                  (start-provider (prompt)
                    (let ((request-handle
                           (llm-chat-async
                            provider prompt
                            (lambda (response)
                              ;; Provider callbacks can outlive this
                              ;; library.  Check HANDLE before calling
                              ;; any library function, and check again
                              ;; in case request logging unloads it.
                              (unless (or pass-finished
                                          (plist-get handle :cancelled)
                                          (plist-get handle :settled))
                                (let ((result
                                       (proofread-llm--success-result
                                        request response pass)))
                                  (unless (or pass-finished
                                              (plist-get handle :cancelled)
                                              (plist-get handle :settled))
                                    (finish result)))))
                            (lambda (error &optional message &rest _)
                              ;; Keep this guard inline for callbacks
                              ;; invoked after the feature is unloaded.
                              (unless (or pass-finished
                                          (plist-get handle :cancelled)
                                          (plist-get handle :settled))
                                (let ((result
                                       (proofread-llm--error-result
                                        request error message pass)))
                                  (unless (or pass-finished
                                              (plist-get handle :cancelled)
                                              (plist-get handle :settled))
                                    (finish result))))))))
                      ;; A synchronous provider callback may have settled
                      ;; HANDLE before `llm-chat-async' returns its handle.
                      (if (or (plist-get handle :cancelled)
                              (plist-get handle :settled))
                          (ignore-errors
                            (llm-cancel-request request-handle))
                        (push request-handle
                              (plist-get handle :requests))))))
               (condition-case err
                   (let ((prompt
                          (proofread-llm--prompt
                           request strategy diagnostics)))
                     (unless (or (plist-get handle :cancelled)
                                 (plist-get handle :settled))
                       (proofread--record-request-event
                        request 'backend-request
                        :backend 'llm
                        :pass pass
                        :max-passes max-passes
                        :strategy strategy
                        :prompt prompt
                        :prompt-text
                        (proofread-llm--request-log-prompt-text
                         prompt)
                        :schema
                        (when (llm-chat-prompt-response-format prompt)
                          (proofread-llm--structured-response-schema-text))
                        :reported-diagnostics diagnostics)
                       (unless (or (plist-get handle :cancelled)
                                   (plist-get handle :settled))
                         (start-provider prompt))))
                 (error
                  (unless (or pass-finished
                              (plist-get handle :cancelled)
                              (plist-get handle :settled))
                    (let ((result
                           (proofread--backend-error-result
                            request 'llm-submit-error
                            (error-message-string err))))
                      (proofread--record-request-event
                       request 'backend-result
                       :backend 'llm
                       :pass pass
                       :result result)
                      (unless (or pass-finished
                                  (plist-get handle :cancelled)
                                  (plist-get handle :settled))
                        (finish result)))))))))))
    (submit 1 nil nil nil))
  handle)

(defun proofread-llm--backend-check (request callback)
  "Submit REQUEST asynchronously and invoke CALLBACK with its result."
  (let* ((provider (proofread-llm--effective-provider request))
         (strategy
          (and provider
               (proofread-llm--response-strategy
                provider
                (proofread-llm--effective-response-strategy
                 request))))
         (max-passes
          (and provider
               strategy
               (proofread-llm--effective-diagnostic-passes
                request)))
         (request-timeout
          (proofread-llm--effective-request-timeout request))
         (handle (proofread-llm--new-handle
                  request callback request-timeout)))
    (cond
     ((not provider)
      (proofread-llm--deliver-result
       handle
       (proofread--backend-error-result
        request 'llm-provider-unavailable
        "No proofread llm provider is configured")))
     ((not strategy)
      (proofread-llm--deliver-result
       handle
       (proofread--backend-error-result
        request 'llm-structured-output-unavailable
        "The configured llm response strategy is unavailable")))
     (t
      (condition-case err
          (progn
            (proofread-llm--arm-watchdog handle)
            (unless (or (plist-get handle :cancelled)
                        (plist-get handle :settled))
              (proofread-llm--submit-passes
               provider strategy max-passes request callback handle)))
        (error
         (let ((result
                (proofread--backend-error-result
                 request 'llm-submit-error
                 (error-message-string err))))
           (proofread--record-request-event
            request 'backend-result
            :backend 'llm
            :result result)
           (proofread-llm--deliver-result handle result))))))
    handle))

(defun proofread-llm--cancel-request-handle (handle)
  "Cancel the LLM requests recorded in backend HANDLE."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :settled))
    (setf (plist-get handle :cancelled) t)
    (setf (plist-get handle :settled) t)
    (setq proofread-llm--live-handles
          (delq handle proofread-llm--live-handles))
    (proofread-llm--cancel-handle-work handle)))

(defun proofread-llm--settle-unloaded-handle (handle)
  "Cancel HANDLE and settle it with an LLM-unloaded error."
  (unless (plist-get handle :settled)
    ;; Claim settlement before cancellation because provider
    ;; cancellation is allowed to invoke its callbacks synchronously.
    (setf (plist-get handle :cancelled) t)
    (setf (plist-get handle :delivered) t)
    (setf (plist-get handle :settled) t)
    (setq proofread-llm--live-handles
          (delq handle proofread-llm--live-handles))
    (proofread-llm--cancel-handle-work handle)
    (let ((result
           (proofread--backend-error-result
            (plist-get handle :request)
            'llm-unloaded
            "LLM backend was unloaded")))
      (proofread--record-request-event
       (plist-get handle :request) 'backend-result
       :backend 'llm
       :result result)
      (when-let* ((callback (plist-get handle :callback)))
        (funcall callback result)))))

(defun proofread-llm--settle-live-handles ()
  "Settle all live handles, including handles added by callbacks."
  (while proofread-llm--live-handles
    (let ((handles (copy-sequence proofread-llm--live-handles)))
      (dolist (handle handles)
        (condition-case nil
            (proofread-llm--settle-unloaded-handle handle)
          (error nil))))))

(defun proofread-llm-unload-function ()
  "Unregister the LLM backend and settle its live requests."
  (proofread--unregister-backend 'llm)
  (proofread-llm--settle-live-handles)
  nil)

;;;; Runtime registration

(progn
  (proofread--register-backend
   'llm
   :check #'proofread-llm--backend-check
   :identity #'proofread-llm--provider-identity
   :checker-identity #'proofread-llm--checker-identity
   :source-label #'proofread-llm--checker-source-label
   :cancel #'proofread-llm--cancel-request-handle))

(provide 'proofread-llm)
;;; proofread-llm.el ends here
