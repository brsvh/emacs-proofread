;;; proofread.el --- Context-aware proofreading  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Assisted-by: Codex:gpt-5.5
;; Assisted-by: Codex:gpt-5.6-sol
;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1") (llm "0.31.1"))
;; Version: 0.3.0

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

;; Proofread provides asynchronous, context-aware proofreading for
;; Emacs buffers.  It selects prose from ordinary text, comments, or
;; docstrings; sends bounded chunks to a configured backend; and
;; displays diagnostics that can be reviewed, ignored, or corrected in
;; place.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'eldoc)
(require 'lisp-mode)
(require 'pp)
(require 'pulse)
(require 'subr-x)
(require 'tabulated-list)
(require 'url-parse)
(require 'warnings)

(declare-function next-error-this-buffer-no-select "simple"
                  (&optional n))
(declare-function previous-error-this-buffer-no-select "simple"
                  (&optional n))
(declare-function org-element-at-point "org-element"
                  (&optional epom cached-only))
(declare-function org-element-lineage "org-element-ast"
                  (datum &optional types with-self))
(declare-function org-element-property "org-element-ast"
                  (property node &optional dflt force-undefer))
(declare-function org-element-type "org-element-ast"
                  (node &optional anonymous))

;;;; Customization

(defgroup proofread nil
  "Context-aware proofreading for Emacs buffers."
  :group 'convenience
  :prefix "proofread-")

(defun proofread-set-positive-integer-option (symbol value)
  "Set SYMBOL to positive integer VALUE as a Customize option."
  (unless (and (integerp value) (> value 0))
    (error "%s must be a positive integer" symbol))
  (set-default symbol value))

;; Compatibility for proofread-popup 0.1.0.
(define-obsolete-function-alias
  'proofread--set-positive-integer-option
  'proofread-set-positive-integer-option
  "0.2.0")

(defcustom proofread-auto-check t
  "Non-nil means schedule automatic checks in `proofread-mode'.
When nil, enabling the mode, buffer changes, and window activity do
not schedule proofreading; use commands such as
`proofread-check-visible-range' to start checks manually.  This option
becomes buffer-local when set."
  :type 'boolean
  :local t
  :group 'proofread)

(defcustom proofread-targets 'auto
  "Kinds of text selected for proofreading in the current buffer.
The value `auto' selects comments and docstrings in modes derived from
`prog-mode', and all text in other modes.  The value `all' selects all
text; `comments' and `docstrings' select only the corresponding
syntactic text; and `comments-and-docstrings' selects both.

Comment and docstring delimiters remain part of the selected text so
backend offsets continue to map exactly to buffer positions.  Backends
are instructed to report only natural-language prose inside those
targets.  This option becomes buffer-local when set."
  :type '(choice
          (const :tag "Automatic" auto)
          (const :tag "All text" all)
          (const :tag "Comments only" comments)
          (const :tag "Docstrings only" docstrings)
          (const :tag "Comments and docstrings" comments-and-docstrings))
  :local t
  :group 'proofread)

(defcustom proofread-docstring-predicate-functions nil
  "Functions used to recognize syntactic strings as docstrings.
Each function is called with the beginning and end positions of a
complete syntactic string and should return non-nil when that string
is a docstring.  The generic `font-lock-doc-face' detector is always
used as a fallback.  This option becomes buffer-local when set."
  :type '(repeat function)
  :local t
  :group 'proofread)

(defcustom proofread-idle-delay 1.0
  "Seconds of idle time before scheduled proofreading work may run."
  :type 'number
  :group 'proofread)

(defcustom proofread-inhibit-progress-messages t
  "Suppress routine progress messages when non-nil.
This affects background check and request-dispatch progress messages.
It does not suppress errors or explicit command feedback."
  :type 'boolean
  :group 'proofread)

(defcustom proofread-echo-area-messages t
  "Show the Proofread diagnostic at point in the echo area.
When non-nil, `proofread-mode' uses ElDoc to show diagnostic messages
at point.  This option becomes buffer-local when set."
  :type 'boolean
  :local t
  :group 'proofread)

(defcustom proofread-max-chunk-size 2000
  "Maximum number of characters in a proofreading chunk."
  :type 'natnum
  :set #'proofread-set-positive-integer-option
  :group 'proofread)

(defcustom proofread-context-size 300
  "Maximum context characters sent with a chunk."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-context-sentences-before 1
  "Maximum number of logical sentences sent before a chunk.
A value of 0 disables before-context."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-context-sentences-after 1
  "Maximum number of logical sentences sent after a chunk.
A value of 0 disables after-context."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-max-concurrent-requests 8
  "Maximum number of proofreading backend requests active at once.
The limit is per buffer.  A value of 0 keeps cache hits active but
prevents new backend requests from being sent."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-profiles nil
  "Named proofreading profiles.
Each element maps a stable profile name to a profile property list.
A profile may contain:

`:language'
     Backend language hint for checks using this profile.

`:display-language'
     Human-readable language name for backends that build natural
     language prompts.

`:checkers'
     Ordered backend checkers.  Each checker is a property list with
     required `:name' and `:backend' properties, and an optional
     `:options' property.  Checker names are stable identifiers, not
     display labels, and must be unique inside one profile.  Checker
     options are backend-local data interpreted by the selected
     backend.  Before dispatch, the backend validates and snapshots
     these options through its registered `:snapshot-options'
     operation."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'proofread)

(defcustom proofread-profile nil
  "Selected proofreading profile.
The value nil disables backend dispatch.  A non-nil symbol selects the
matching entry from `proofread-profiles'.

This option may be set buffer-locally, for example with
`setq-local' or file/directory-local variables, when different
buffers should use different profiles."
  :type '(choice
          (const :tag "Disable backend dispatch" nil)
          symbol)
  :package-version '(proofread . "0.3.0")
  :group 'proofread)

;; Keep compiler-facing tombstones for configuration removed in 0.3.0.
(make-obsolete-variable
 'proofread-backend
 "configure `proofread-profiles' and select one with `proofread-profile'"
 "0.2.0")

(make-obsolete-variable
 'proofread-language
 "use the selected profile's `:language' property"
 "0.2.0")

(defcustom proofread-cache-max-entries 128
  "Maximum diagnostic cache entries retained in each buffer.
A value of 0 disables diagnostic caching."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-request-log-max-records 100
  "Maximum request records retained for each monitored buffer."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-ignored-faces nil
  "Faces whose text should be skipped before proofreading requests.
The `face' text property is inspected directly.  When its value is a
symbol or a list containing any face in this option, that text is not
included in request-ready chunks."
  :type '(repeat symbol)
  :group 'proofread)

(defcustom proofread-ignored-properties nil
  "Text properties whose non-nil values should be skipped.
Each property is inspected with `get-text-property'.  Text where any
configured property has a non-nil value is not included in
request-ready chunks."
  :type '(repeat symbol)
  :group 'proofread)

;;;; Faces

(defface proofread-face
  '((t :inherit font-lock-warning-face :underline ( :style wave)))
  "Face for proofreading diagnostics."
  :group 'proofread)

(defface proofread-current-face
  '((t :inherit proofread-face))
  "Face for the current proofreading diagnostic."
  :group 'proofread)

(defface proofread-echo-area-source-face
  '((t :inherit font-lock-keyword-face))
  "Face for Proofread diagnostic sources in the echo area."
  :group 'proofread)

(defface proofread-echo-area-message-face
  '((t :inherit font-lock-comment-face))
  "Face for Proofread diagnostic messages in the echo area."
  :group 'proofread)

;;;; Internal constants

(defconst proofread--backend-features
  '((llm . proofread-llm)
    (languagetool . proofread-languagetool))
  "Alist mapping built-in backend names to their library features.")

(defconst proofread--ad-hoc-profile-name 'ad-hoc
  "Profile name used for explicit low-level backend requests.")

(defconst proofread--ad-hoc-checker-name 'ad-hoc
  "Checker name used for explicit low-level backend requests.")

(defconst proofread--profile-keys
  '( :language :display-language :checkers)
  "Property keys accepted in proofread profile definitions.")

(defconst proofread--profile-checker-keys
  '( :name :backend :options)
  "Property keys accepted in proofread profile checker definitions.")

(defconst proofread--backend-descriptor-keys
  '( :check :identity :snapshot-options
     :checker-identity :source-label :cancel)
  "Property keys accepted in proofread backend descriptors.")

(defconst proofread--diagnostic-keys
  '( :beg :end :text :kind :message :suggestions :source :target-kind)
  "Required keys for proofread diagnostic plists.")

(defconst proofread--diagnostic-provenance-keys
  '( :language :display-language
     :profile :checker-name :checker-ordinal :checker-owner
     :source-label)
  "Request properties added to live proofread diagnostics.")

(defconst proofread--contract-version 5
  "Version of the internal diagnostic cache-key contract.")

(defconst proofread--backend-request-keys
  '( :id :generation :buffer
     :beg :end :text
     :context-before :context-after
     :language :display-language
     :profile :checker-name :checker-ordinal :checker-owner
     :checker-options :checker-identity :source-label
     :major-mode
     :target-policy :target-kind
     :domain-beg :domain-end :accessible-beg :accessible-end
     :backend :backend-identity)
  "Required keys for proofread backend request plists.")

(defconst proofread--request-log-schema
  '( :property-sanitizers
     ((:beg . proofread--request-log-safe-position-value)
      (:end . proofread--request-log-safe-position-value)
      (:domain-beg . proofread--request-log-safe-position-value)
      (:domain-end . proofread--request-log-safe-position-value)
      (:accessible-beg . proofread--request-log-safe-position-value)
      (:accessible-end . proofread--request-log-safe-position-value)
      (:text . proofread--request-log-safe-string-value)
      (:context-before . proofread--request-log-safe-string-value)
      (:context-after . proofread--request-log-safe-string-value)
      (:language . proofread--request-log-safe-string-value)
      (:display-language . proofread--request-log-safe-string-value)
      (:message . proofread--request-log-safe-string-value)
      (:method . proofread--request-log-safe-string-value)
      (:source-label . proofread--request-log-safe-string-value)
      (:type . proofread--request-log-safe-symbol-value)
      (:status . proofread--request-log-safe-symbol-value)
      (:final-status . proofread--request-log-safe-symbol-value)
      (:profile . proofread--request-log-safe-symbol-value)
      (:checker-name . proofread--request-log-safe-symbol-value)
      (:backend . proofread--request-log-safe-symbol-value)
      (:major-mode . proofread--request-log-safe-symbol-value)
      (:target-kind . proofread--request-log-safe-symbol-value)
      (:kind . proofread--request-log-safe-symbol-value)
      (:strategy . proofread--request-log-safe-symbol-value)
      (:reason . proofread--request-log-safe-symbol-value)
      (:phase . proofread--request-log-safe-symbol-value)
      (:ad-hoc . proofread--request-log-safe-symbol-value)
      (:partial . proofread--request-log-safe-symbol-value)
      (:source . proofread--request-log-safe-source-value)
      (:key . proofread--request-log-safe-integer-value)
      (:log-id . proofread--request-log-safe-integer-value)
      (:id . proofread--request-log-safe-integer-value)
      (:request-id . proofread--request-log-safe-integer-value)
      (:generation . proofread--request-log-safe-integer-value)
      (:checker-ordinal . proofread--request-log-safe-integer-value)
      (:pass . proofread--request-log-safe-integer-value)
      (:max-passes . proofread--request-log-safe-integer-value)
      (:http-status . proofread--request-log-safe-integer-value)
      (:contract-version . proofread--request-log-safe-integer-value)
      (:buffer . proofread--request-log-safe-buffer-value)
      (:source-buffer . proofread--request-log-safe-buffer-value)
      (:time . proofread--request-log-safe-time-value)
      (:created-at . proofread--request-log-safe-time-value)
      (:updated-at . proofread--request-log-safe-time-value)
      (:checker-owner . proofread--request-log-safe-checker-owner-value))
     :objects
     ((checker-owner
       (:profile proofread--request-log-safe-object-property)
       (:checker-name proofread--request-log-safe-object-property)
       (:ad-hoc proofread--request-log-safe-object-property))
      (backend-identity
       (:backend proofread--request-log-safe-object-property)
       (:contract-version proofread--request-log-safe-object-property)
       (:fingerprint
        proofread--request-log-safe-object-identity-fingerprint))
      (checker-identity
       (:profile proofread--request-log-safe-object-property)
       (:checker-name proofread--request-log-safe-object-property)
       (:backend proofread--request-log-safe-object-property)
       (:ad-hoc proofread--request-log-safe-object-property)
       (:backend-identity
        proofread--request-log-safe-object-backend-identity)
       (:fingerprint
        proofread--request-log-safe-object-summary-fingerprint))
      (request
       (:id proofread--request-log-safe-object-property)
       (:generation proofread--request-log-safe-object-property)
       (:buffer proofread--request-log-safe-object-property)
       (:beg proofread--request-log-safe-object-property)
       (:end proofread--request-log-safe-object-property)
       (:text proofread--request-log-safe-object-property)
       (:context-before proofread--request-log-safe-object-property)
       (:context-after proofread--request-log-safe-object-property)
       (:language proofread--request-log-safe-object-property)
       (:display-language proofread--request-log-safe-object-property)
       (:profile proofread--request-log-safe-object-property)
       (:checker-name proofread--request-log-safe-object-property)
       (:checker-ordinal proofread--request-log-safe-object-property)
       (:checker-owner proofread--request-log-safe-object-property)
       (:source-label proofread--request-log-safe-object-property)
       (:major-mode proofread--request-log-safe-object-property)
       (:target-kind proofread--request-log-safe-object-property)
       (:domain-beg proofread--request-log-safe-object-property)
       (:domain-end proofread--request-log-safe-object-property)
       (:accessible-beg proofread--request-log-safe-object-property)
       (:accessible-end proofread--request-log-safe-object-property)
       (:backend proofread--request-log-safe-object-property)
       (:backend-identity
        proofread--request-log-safe-object-backend-identity)
       (:checker-identity
        proofread--request-log-safe-object-checker-identity))
      (chunk
       (:beg proofread--request-log-safe-object-property)
       (:end proofread--request-log-safe-object-property)
       (:text proofread--request-log-safe-object-property)
       (:context-before proofread--request-log-safe-object-property)
       (:context-after proofread--request-log-safe-object-property)
       (:language proofread--request-log-safe-object-property)
       (:major-mode proofread--request-log-safe-object-property)
       (:target-kind proofread--request-log-safe-object-property)
       (:domain-beg proofread--request-log-safe-object-property)
       (:domain-end proofread--request-log-safe-object-property)
       (:accessible-beg proofread--request-log-safe-object-property)
       (:accessible-end proofread--request-log-safe-object-property))
      (diagnostic
       (:beg proofread--request-log-safe-object-property)
       (:end proofread--request-log-safe-object-property)
       (:text proofread--request-log-safe-object-property)
       (:kind proofread--request-log-safe-object-property)
       (:message proofread--request-log-safe-object-property)
       (:target-kind proofread--request-log-safe-object-property)
       (:language proofread--request-log-safe-object-property)
       (:display-language proofread--request-log-safe-object-property)
       (:profile proofread--request-log-safe-object-property)
       (:checker-name proofread--request-log-safe-object-property)
       (:checker-ordinal proofread--request-log-safe-object-property)
       (:checker-owner proofread--request-log-safe-object-property)
       (:source-label proofread--request-log-safe-object-property)
       (:source proofread--request-log-safe-object-diagnostic-source)
       (:suggestions
        proofread--request-log-safe-object-diagnostic-suggestions))
      (result
       (:status proofread--request-log-safe-object-property)
       (:source proofread--request-log-safe-object-property)
       (:partial proofread--request-log-safe-object-property)
       (:phase proofread--request-log-safe-object-property)
       (:request proofread--request-log-safe-object-request)
       (:diagnostics proofread--request-log-safe-object-diagnostics)
       (:error proofread--request-log-safe-object-condition)
       (:message proofread--request-log-safe-object-backend-message))
      (cache-entry
       (:text proofread--request-log-safe-object-property)
       (:diagnostics proofread--request-log-safe-object-diagnostics)))
     :events
     ((t
       (:type proofread--request-log-safe-event-property)
       (:time proofread--request-log-safe-event-property)
       (:log-id proofread--request-log-safe-event-property)
       (:request-id proofread--request-log-safe-event-property)
       (:buffer proofread--request-log-safe-event-property)
       (:beg proofread--request-log-safe-event-property)
       (:end proofread--request-log-safe-event-property)
       (:status proofread--request-log-safe-event-property)
       (:request proofread--request-log-safe-event-request))
      (chunk-request
       (:chunk proofread--request-log-safe-event-chunk))
      (queued-request
       (:backend proofread--request-log-safe-event-property))
      (active-request
       (:backend proofread--request-log-safe-event-property))
      (backend-dispatched
       (:backend proofread--request-log-safe-event-property))
      (backend-request
       (:backend proofread--request-log-safe-event-property)
       (:method proofread--request-log-safe-event-property)
       (:pass proofread--request-log-safe-event-property)
       (:max-passes proofread--request-log-safe-event-property)
       (:strategy proofread--request-log-safe-event-property)
       (:url proofread--request-log-safe-event-url)
       (:parameters proofread--request-log-safe-event-text)
       (:schema proofread--request-log-safe-event-text)
       (:prompt-text proofread--request-log-safe-event-text)
       (:reported-diagnostics
        proofread--request-log-safe-event-diagnostics))
      (backend-response
       (:backend proofread--request-log-safe-event-property)
       (:http-status proofread--request-log-safe-event-property)
       (:pass proofread--request-log-safe-event-property)
       (:url proofread--request-log-safe-event-url)
       (:response proofread--request-log-safe-event-text)
       (:error proofread--request-log-safe-event-condition)
       (:message proofread--request-log-safe-event-backend-message))
      (backend-result
       (:backend proofread--request-log-safe-event-property)
       (:pass proofread--request-log-safe-event-property)
       (:source proofread--request-log-safe-event-property)
       (:entry proofread--request-log-safe-event-cache-entry)
       (:result proofread--request-log-safe-event-result))
      (cache-hit
       (:entry proofread--request-log-safe-event-required-cache-entry))
      (cancelled
       (:reason proofread--request-log-safe-event-property))
      (final-result
       (:result proofread--request-log-safe-event-result))
      (checker-dispatch-failed
       (:profile proofread--request-log-safe-event-property)
       (:checker-name proofread--request-log-safe-event-property)
       (:backend proofread--request-log-safe-event-property)
       (:phase proofread--request-log-safe-event-property)
       (:error proofread--request-log-safe-event-required-condition)
       (:message proofread--request-log-safe-event-checker-message))))
  "Declarative safety schema for request-log objects and events.
The t event entry lists fields shared by every event.  Every field
specification has the form (PROPERTY SANITIZER).  Object sanitizers
also receive the safe fields collected so far; every sanitizer returns
`(t . SAFE-VALUE)' or nil.")

(defconst proofread--request-log-history-properties
  '( :events :backend-requests :backend-responses :backend-results)
  "Record properties stored internally in newest-first order.")

(defconst proofread--overlay-category 'proofread-overlay
  "Overlay category used for proofread-owned overlays.")

(defconst proofread--description-buffer-name "*Proofread Diagnostic*"
  "Buffer name used to display proofread diagnostic descriptions.")

(defconst proofread--stale-dispatch-result
  (make-symbol "proofread-stale-dispatch")
  "Internal result for a request that became stale before dispatch.")

(defconst proofread--docstring-font-lock-sample-size 256
  "Maximum opening characters fontified to classify a docstring.")

(defconst proofread--sentence-closing-characters
  "\"'”’»）]}】》」』"
  "Characters included after sentence-ending punctuation.")

(defconst proofread--url-regexp
  "\\_<https?://[^[:space:]<>(){}\"']+"
  "Regexp matching ignored URL text.")

(defconst proofread--email-regexp
  (concat "\\_<[[:alnum:]._%+-]+@[[:alnum:].-]+\\."
          "[[:alpha:]][[:alnum:].-]*\\_>")
  "Regexp matching ignored email text.")

(defconst proofread--request-log-list-format
  `[("Id" 6 nil :right-align t)
    ("Status" 10 t)
    ("Time" 8 t)
    ("Line" 4 ,(lambda (a b)
                 (< (plist-get (car a) :line)
                    (plist-get (car b) :line)))
     :right-align t)
    ("Col" 4 nil :right-align t)
    ("Range" 15 t)
    ("Backend" 10 t)
    ("Text" 0 t)]
  "Tabulated list format for proofread request buffers.")

(defconst proofread--diagnostics-list-format
  `[("Line" 4 ,(lambda (a b)
                 (< (plist-get (car a) :line)
                    (plist-get (car b) :line)))
     :right-align t)
    ("Col" 3 nil :right-align t)
    ("Kind" 8 ,(lambda (a b)
                 (< (plist-get (car a) :kind-rank)
                    (plist-get (car b) :kind-rank))))
    ("Source" 8 t)
    ("Text" 12 t)
    ("Message" 0 t)]
  "Tabulated list format for proofread diagnostics buffers.")

;;;; Internal state

(defvar proofread--backend-registry (make-hash-table :test #'eq)
  "Registry of loaded proofreading backend descriptors.")

(defvar proofread--ignored-diagnostics (make-hash-table :test #'equal)
  "Session-local table of ignored proofread diagnostic keys.")

(defvar-local proofread--diagnostics nil
  "Proofread diagnostics for the current buffer.")

(defvar-local proofread--overlays nil
  "Proofread-owned overlays for the current buffer.")

(defvar-local proofread--diagnostic-overlays nil
  "Map diagnostics to their proofread-owned overlays.")

(defvar-local proofread--next-diagnostic-insertion-ordinal 0
  "Next insertion ordinal for a proofread diagnostic overlay.")

(defvar-local proofread--diagnostic-request-ranges nil
  "Map diagnostics to their originating request marker ranges.")

(defvar-local proofread--current-diagnostic nil
  "Currently selected proofread diagnostic in the current buffer.")

(defvar-local proofread--eldoc-mode-owned-p nil
  "Non-nil when Proofread enabled ElDoc in the current buffer.")

(defvar-local proofread--echo-area-refresh-pending-p nil
  "Non-nil when a guarded Proofread echo-area refresh is pending.")

(defvar-local proofread--diagnostics-current-line 0
  "Current line in a proofread diagnostics listing buffer.")

(defvar-local proofread--diagnostics-buffer-source nil
  "Source buffer for a proofread diagnostics listing buffer.")

(defvar-local proofread--diagnostics-list-buffers nil
  "Live diagnostic list buffers for the current source buffer.")

(defvar-local proofread--active-requests nil
  "Active proofread requests for the current buffer.")

(defvar-local proofread--queue-state nil
  "Linked request queue state for the current buffer.")

(defvar-local proofread--claimed-requests nil
  "Requests moving atomically from queued to active or complete.")

(defvar-local proofread--queue-dispatch-active-p nil
  "Non-nil while the current buffer is draining its request queue.")

(defvar-local proofread--queue-dispatch-requested-p nil
  "Non-nil when queue dispatch was requested during dispatch.")

(defvar-local proofread--queue-dispatch-timer nil
  "Timer scheduled to resume queued work after an edit.")

(defvar proofread--inhibit-queue-dispatch nil
  "Buffer whose request lifecycle state is being changed atomically.")

(defvar proofread--profile-dispatch-transactions nil
  "Dynamically shared profile publication transactions.
Each entry is a `proofread--profile-dispatch-transaction'.  Nested
dispatches share one transaction only while they still own the same
buffer generation and request queue.")

(defvar proofread--queue-dispatch-transaction nil
  "Token for the dynamically active request queue dispatch transaction.")

(defvar proofread--queue-dispatch-pruned-active-p nil
  "Non-nil after the current dispatch pruned stale active requests.")

(defvar proofread--clearing-scheduled-work nil
  "Buffer whose queued and scheduled work is being cleared.")

(defvar proofread--recording-clear-rejection-p nil
  "Non-nil while reporting work rejected during cleanup.")

(defvar-local proofread--pending-request-keys nil
  "Map active and queued work keys to scheduled work records.")

(defvar-local proofread--next-request-id 0
  "Next proofread backend request id for the current buffer.")

(defvar-local proofread--generation 0
  "Generation of proofread state in the current buffer.")

(defvar proofread--generation-sequence 0
  "Sequence used to distinguish successive proofread buffer states.")

(defvar-local proofread--pending-invalidated-overlays nil
  "Proofread overlays captured before the current buffer change.")

(defvar-local proofread--pending-invalidated-diagnostics nil
  "Proofread diagnostics captured before the current buffer change.")

(defvar-local proofread--cache nil
  "Proofread cache for the current buffer.")

(defvar-local proofread--cache-order nil
  "Cache keys in most-recently-used order for the current buffer.")

(defvar-local proofread--pending-work nil
  "Non-nil when visible proofreading is scheduled for this buffer.")

(defvar-local proofread--idle-timer nil
  "Idle timer for pending proofreading work in this buffer.")

(defvar proofread-mode)

(defvar proofread--active-target-kind nil
  "Target kind dynamically bound while constructing request chunks.")

(defvar proofread-request-log-hook nil
  "Abnormal hook run with proofread request lifecycle events.
Each function receives its own detached, safe plist argument.  Raw
checker options, provider objects, backend handles, and other opaque
backend-local values are omitted.  Mutating an event cannot affect
other consumers or recorded state.  Consumers must not signal errors
that interrupt proofreading.")

(defvar-local proofread-diagnostics-changed-hook nil
  "Hook run after displayed diagnostics change in the current buffer.
Functions are called without arguments.  Errors are reported without
interrupting proofreading.")

(defvar proofread--mode-buffers nil
  "Live buffers where `proofread-mode' has installed local hooks.")

(defvar proofread--inhibit-overlay-invalidation nil
  "Buffer whose correction edits must preserve proofread overlays.")

(defvar proofread--deferred-correction-overlays nil
  "Overlays invalidated while applying an atomic correction.")

(defvar proofread--deferred-correction-diagnostics nil
  "Diagnostics invalidated while applying an atomic correction.")

(defvar proofread--request-log-sequence 0
  "Session-local sequence for request log identifiers.")

(defvar proofread--request-log-owner-ids
  (make-hash-table :test #'eq :weakness 'key)
  "Weak map from backend request payloads to scheduler log ids.")

(defvar proofread--request-batch-sequence 0
  "Session-local sequence for request batch identifiers.")

(defvar proofread--request-log-sources nil
  "Live source buffers currently recording proofread request events.")

(defvar-local proofread--request-log-enabled nil
  "Non-nil when the current buffer records proofread request events.")

(defvar-local proofread--request-log-records nil
  "Hash table of proofread request records for the current buffer.")

(defvar-local proofread--request-log-order nil
  "Request record keys in oldest-to-newest order.")

(defvar-local proofread--request-log-list-buffers nil
  "Live request list buffers for the current source buffer.")

(defvar-local proofread--request-log-refresh-timer nil
  "Timer that coalesces request list refreshes for the source.")

(defvar-local proofread--request-log-list-source nil
  "Source buffer monitored by the current proofread requests buffer.")

(defvar-keymap proofread-requests-buffer-mode-map
  :doc "Keymap for `proofread-requests-buffer-mode'."
  "RET" #'proofread-show-request
  "C-m" #'proofread-show-request)

(defvar-keymap proofread-diagnostics-buffer-mode-map
  :doc "Keymap for `proofread-diagnostics-buffer-mode'."
  "RET" #'proofread-goto-diagnostic
  "C-m" #'proofread-goto-diagnostic
  "SPC" #'proofread-show-diagnostic
  "C-o" #'proofread-show-diagnostic
  "n" #'next-error-this-buffer-no-select
  "p" #'previous-error-this-buffer-no-select)

;;;; Backend registry

(cl-defstruct
    (proofread--request-handle
     (:constructor proofread--make-request-handle (value cancel)))
  "Core-owned cancellation state for an opaque backend handle."
  value
  cancel
  cancelled)

(cl-defstruct
    (proofread--scheduled-work
     (:constructor
      proofread--make-scheduled-work (request cache-key log-id)))
  "Core-owned mutable state for one immutable backend REQUEST.
CACHE-KEY and LOG-ID belong to the scheduler and are never exposed to
the backend.  The remaining fields track lifecycle state after the
work is published."
  request
  cache-key
  log-id
  superseded
  invalidated
  cancelled
  batch
  batch-settled
  handle)

(cl-defstruct
    (proofread--queue-entry
     (:constructor
      proofread--make-queue-entry (work sequence)))
  "One scheduled WORK linked into a request queue.
SEQUENCE is the immutable FIFO position assigned when the entry is
created."
  work
  sequence
  previous
  next
  owner)

(cl-defstruct
    (proofread--queue-state
     (:constructor proofread--make-queue-state ()))
  "All mutable structural state for one request queue."
  head
  tail
  (index (make-hash-table :test #'equal))
  (woken (make-hash-table :test #'eq))
  (next-sequence 0))

(cl-defstruct
    (proofread--profile-dispatch-transaction
     (:constructor
      proofread--make-profile-dispatch-transaction
      (buffer generation queue-state)))
  "Publication ownership for one profile dispatch state.
BUFFER, GENERATION, and QUEUE-STATE identify the exact lifecycle state
that may share preparation and one eventual queue drain."
  buffer
  generation
  queue-state
  published)

(cl-defstruct
    (proofread--checker-preparation
     (:constructor
      proofread--make-checker-preparation
      (descriptor checker backend-identity checker-identity
                  source-label)))
  "Immutable-by-convention snapshot of one checker adapter.
DESCRIPTOR is local to preparation and is never added to requests or
scheduler state.  CHECKER contains the exact backend-owned options
snapshot.  The remaining fields are the metadata snapshots shared by
every request prepared for that checker."
  descriptor
  checker
  backend-identity
  checker-identity
  source-label)

(defun proofread--scheduled-work-backend (work)
  "Return the backend frozen in WORK's immutable request."
  (plist-get (proofread--scheduled-work-request work) :backend))

(defun proofread--validate-backend-descriptor (backend descriptor)
  "Return BACKEND DESCRIPTOR after validating its public contract."
  (let ((context (format "Proofread backend %S descriptor" backend))
        seen)
    (dolist (key (proofread--plist-keys descriptor context))
      (unless (memq key proofread--backend-descriptor-keys)
        (error "%s contains unknown property %S" context key))
      (when (memq key seen)
        (error "%s contains duplicate property %S" context key))
      (push key seen)))
  (dolist (key '( :check :identity :snapshot-options))
    (unless (functionp (plist-get descriptor key))
      (error "Proofread backend %S has invalid %S function"
             backend key)))
  (dolist (key '( :checker-identity :source-label :cancel))
    (when (and (plist-member descriptor key)
               (not (functionp (plist-get descriptor key))))
      (error "Proofread backend %S has invalid %S function"
             backend key)))
  descriptor)

(defun proofread-register-backend (backend &rest descriptor)
  "Register BACKEND using operations in DESCRIPTOR.
DESCRIPTOR must contain callable `:check', `:identity', and
`:snapshot-options' entries.  The snapshot operation receives raw
checker options and must return a detached property-list snapshot.
The identity operation takes no arguments and must return a property
list containing `:backend' and `:contract-version'.  The check
operation receives a read-only request and a callback, submits without
blocking, and returns an opaque handle.

An optional callable `:checker-identity' entry returns the effective
complete identity for one normalized profile checker instead of the
backend-wide identity.  An optional callable `:source-label' entry
returns nil or a nonempty display string for one normalized profile
checker.  An optional callable `:cancel' entry receives unchanged the
opaque handle returned by `:check'.

Signal an error for malformed, duplicate, or unknown descriptor
properties.  Return BACKEND after registering a shallow copy of the
descriptor."
  (unless (symbolp backend)
    (error "Proofread backend name must be a symbol: %S" backend))
  (proofread--validate-backend-descriptor backend descriptor)
  (puthash backend (copy-sequence descriptor)
           proofread--backend-registry)
  backend)

(defun proofread-unregister-backend (backend)
  "Remove BACKEND from the loaded backend registry.
Return non-nil when BACKEND had a registered descriptor."
  (let ((registered (and (gethash backend
                                  proofread--backend-registry)
                         t)))
    (remhash backend proofread--backend-registry)
    registered))

(defun proofread--backend-descriptor (backend)
  "Return BACKEND's loaded descriptor, loading its feature if known."
  (or (gethash backend proofread--backend-registry)
      (when-let* ((feature (alist-get backend
                                      proofread--backend-features)))
        (require feature nil t)
        (gethash backend proofread--backend-registry))))

;;;; Profiles

(defun proofread--plist-keys (value context)
  "Return property keys from VALUE, or signal an error for CONTEXT."
  (unless (listp value)
    (error "%s must be a property list" context))
  (let ((value-length (proper-list-p value))
        (tail value)
        keys)
    (unless (integerp value-length)
      (error "%s must be a proper property list" context))
    (unless (zerop (% value-length 2))
      (error "%s must contain values for every property" context))
    (while tail
      (let ((key (pop tail)))
        (unless (keywordp key)
          (error "%s contains non-keyword property %S" context key))
        (push key keys))
      (pop tail))
    (nreverse keys)))

(defun proofread--validate-plist (value context)
  "Return VALUE after validating it as a property list for CONTEXT."
  (proofread--plist-keys value context)
  value)

(defun proofread--validate-known-plist
    (value context allowed-keys)
  "Return VALUE after validating known properties for CONTEXT.
ALLOWED-KEYS is the list of accepted keyword properties."
  (dolist (key (proofread--plist-keys value context))
    (unless (memq key allowed-keys)
      (error "%s contains unknown property %S" context key)))
  value)

(defun proofread--validate-language-option (value context)
  "Return VALUE after validating a language option for CONTEXT."
  (unless (or (null value) (stringp value))
    (error "%s must be nil or a string" context))
  value)

(defun proofread--profile-definition (name)
  "Return the raw profile definition named NAME.
Signal an error when `proofread-profiles' has malformed entries or
duplicate names."
  (unless (symbolp name)
    (error "Proofread profile name must be a symbol: %S" name))
  (unless (listp proofread-profiles)
    (error "Proofread profiles must be a list"))
  (let (definition found)
    (dolist (entry proofread-profiles)
      (unless (and (consp entry) (symbolp (car entry)))
        (error "Invalid proofread profile entry: %S" entry))
      (when (eq (car entry) name)
        (when found
          (error "Duplicate proofread profile: %S" name))
        (setq found t)
        (setq definition (cdr entry))))
    (unless found
      (user-error "Unknown proofread profile: %S" name))
    definition))

(defun proofread--normalize-profile-checker
    (profile-name checker ordinal seen-names)
  "Return normalized CHECKER for PROFILE-NAME.
ORDINAL is CHECKER's position in the profile.  SEEN-NAMES is an eq
hash table used to reject duplicate checker names inside the profile."
  (let ((context (format "Proofread profile %S checker" profile-name)))
    (proofread--validate-known-plist
     checker context proofread--profile-checker-keys)
    (let ((name (plist-get checker :name))
          (backend (plist-get checker :backend))
          (options (plist-get checker :options)))
      (unless (and name (symbolp name))
        (error "%s must have a non-nil symbol :name" context))
      (when (gethash name seen-names)
        (error "Duplicate proofread checker %S in profile %S"
               name profile-name))
      (puthash name t seen-names)
      (unless (and backend (symbolp backend))
        (error "%s must have a non-nil symbol :backend" context))
      (when (plist-member checker :options)
        (proofread--validate-plist
         options
         (format "%s %S :options" context name)))
      (list :profile profile-name
            :name name
            :checker-ordinal ordinal
            :backend backend
            :options options))))

(defun proofread--normalize-profile-checkers
    (profile-name checkers)
  "Return normalized profile CHECKERS for PROFILE-NAME."
  (unless (listp checkers)
    (error "Proofread profile %S :checkers must be a list"
           profile-name))
  (let ((seen-names (make-hash-table :test #'eq))
        normalized)
    (cl-loop for checker in checkers
             for ordinal from 0
             do
             (push
              (proofread--normalize-profile-checker
               profile-name checker ordinal seen-names)
              normalized))
    (nreverse normalized)))

(defun proofread--normalize-profile (name definition)
  "Return normalized profile NAME from raw DEFINITION."
  (let ((context (format "Proofread profile %S" name)))
    (proofread--validate-known-plist
     definition context proofread--profile-keys)
    (let ((language (plist-get definition :language))
          (display-language (plist-get definition :display-language))
          (checkers (plist-get definition :checkers)))
      (proofread--validate-language-option
       language (format "%s :language" context))
      (proofread--validate-language-option
       display-language (format "%s :display-language" context))
      (list :name name
            :language (proofread--snapshot-value language)
            :display-language
            (proofread--snapshot-value display-language)
            :checkers
            (proofread--normalize-profile-checkers
             name checkers)))))

(defun proofread--ad-hoc-checker (backend)
  "Return an internal checker for an explicit low-level BACKEND.
Ad-hoc checkers are independent of profile selection and cannot alias
explicit profile checkers."
  (when backend
    (unless (symbolp backend)
      (error "Proofread backend must be nil or a symbol"))
    (list :profile proofread--ad-hoc-profile-name
          :name proofread--ad-hoc-checker-name
          :backend backend
          :options nil
          :ad-hoc t)))

(defun proofread--checker-with-options-snapshot
    (checker &optional descriptor)
  "Return CHECKER with its backend-owned options snapshot.
The registered backend receives CHECKER's raw `:options' value.  The
core validates only the returned property-list envelope and retains
the returned object unchanged.  When DESCRIPTOR is non-nil, use that
previously captured backend descriptor without querying the registry."
  (let* ((backend (plist-get checker :backend))
         (descriptor (or descriptor
                         (proofread--backend-descriptor backend))))
    (unless descriptor
      (error "Unsupported proofread backend %S" backend))
    (let* ((function (plist-get descriptor :snapshot-options))
           (options (funcall function
                             (plist-get checker :options))))
      (proofread--validate-plist
       options
       (format "Proofread backend %S checker options snapshot"
               backend))
      (let ((snapshot (copy-sequence checker)))
        (plist-put snapshot :options options)))))

(defun proofread--current-profile ()
  "Return the normalized selected proofreading profile."
  (if proofread-profile
      (proofread--normalize-profile
       proofread-profile
       (proofread--profile-definition proofread-profile))
    (proofread--normalize-profile nil nil)))

(defun proofread--current-profile-language ()
  "Return the selected proofreading profile's language hint."
  (plist-get (proofread--current-profile) :language))

(defun proofread--checker-discriminator (checker)
  "Return internal provenance properties for CHECKER."
  (when (plist-get checker :ad-hoc)
    '( :ad-hoc t)))

(defun proofread--checker-owner (checker)
  "Return the stable owner identity for CHECKER.
Internal checker kinds include their provenance discriminator."
  (append
   (list :profile (plist-get checker :profile)
         :checker-name (plist-get checker :name))
   (proofread--checker-discriminator checker)))

(defun proofread--report-checker-source-label-warning
    (checker reason)
  "Report a bounded source-label warning for CHECKER and REASON.
Do not let reporting errors interrupt checker dispatch."
  (condition-case nil
      (proofread-report-warning-without-window
       (format
        (concat "Proofread profile %S checker %S using backend %S "
                "could not provide a source label (%S); continuing "
                "without one")
        (plist-get checker :profile)
        (plist-get checker :name)
        (plist-get checker :backend)
        reason)
       "checker source label unavailable; see *Warnings*")
    (error nil)))

(defun proofread--backend-checker-source-label
    (checker &optional descriptor)
  "Return a safe display source label for normalized CHECKER.
Dispatch callers snapshot the backend's optional `:source-label'
operation once per checker.  Return nil after warning when the
operation signals an error or returns an invalid non-nil value.  When
DESCRIPTOR is non-nil, use that previously captured descriptor."
  (let* ((backend (plist-get checker :backend))
         (descriptor (or descriptor
                         (proofread--backend-descriptor backend)))
         (function (plist-get descriptor :source-label)))
    (when function
      (condition-case err
          (let ((source-checker (copy-sequence checker)))
            ;; Checker order controls presentation but not its source.
            (cl-remf source-checker :checker-ordinal)
            (let ((label (funcall function source-checker)))
              (cond
               ((null label) nil)
               ((stringp label)
                (let ((normalized
                       (string-clean-whitespace label)))
                  (if (string-empty-p normalized)
                      (progn
                        (proofread--report-checker-source-label-warning
                         checker 'invalid-value)
                        nil)
                    (substring-no-properties normalized))))
               (t
                (proofread--report-checker-source-label-warning
                 checker 'invalid-value)
                nil))))
        (error
         (proofread--report-checker-source-label-warning
          checker (proofread--condition-kind err))
         nil)))))

(defun proofread--backend-checker-identity
    (checker &optional descriptor)
  "Return one detached backend identity for normalized CHECKER.
When DESCRIPTOR is non-nil, use that previously captured descriptor."
  (let* ((backend (plist-get checker :backend))
         (descriptor (or descriptor
                         (proofread--backend-descriptor backend)))
         (identity-function
          (plist-get descriptor :checker-identity))
         (value
          (cond
           (identity-function
            (let ((identity-checker (copy-sequence checker)))
              ;; Checker order is presentation metadata.  Keep it out
              ;; of backend-owned cache identities even when a backend
              ;; snapshots its complete input.
              (cl-remf identity-checker :checker-ordinal)
              (funcall identity-function identity-checker)))
           (descriptor
            (funcall (plist-get descriptor :identity)))
           (t nil))))
    (cond
     ((null value)
      (when descriptor
        (error "Invalid checker identity for proofread backend %S"
               backend))
      nil)
     ((and (proofread--backend-identity-p value)
           (eq (plist-get value :backend) backend))
      (proofread--snapshot-value value))
     (t
      (error "Invalid checker identity for proofread backend %S"
             backend)))))

(defun proofread--checker-identity-from-snapshots
    (checker descriptor backend-identity)
  "Return CHECKER identity using DESCRIPTOR and BACKEND-IDENTITY.
BACKEND-IDENTITY is already detached and is retained unchanged."
  (append
   (list :profile (plist-get checker :profile)
         :checker-name (plist-get checker :name)
         :backend (plist-get checker :backend)
         :backend-identity backend-identity
         :options (unless (plist-get descriptor :checker-identity)
                    (plist-get checker :options)))
   (proofread--checker-discriminator checker)))

(defun proofread--finish-checker-preparation
    (checker descriptor &optional omit-source-label source-buffer)
  "Finish preparation of snapshotted CHECKER using DESCRIPTOR.
When OMIT-SOURCE-LABEL is non-nil, avoid the presentation-only
source-label operation.  When SOURCE-BUFFER is non-nil, run each
backend adapter operation there and stop if it dies between calls."
  (let ((backend-identity
         (if source-buffer
             (with-current-buffer source-buffer
               (proofread--backend-checker-identity
                checker descriptor))
           (proofread--backend-checker-identity checker descriptor))))
    (when (and source-buffer
               (not (buffer-live-p source-buffer)))
      (error "Proofread source buffer died during checker preparation"))
    (let ((checker-identity
           (proofread--checker-identity-from-snapshots
            checker descriptor backend-identity))
          (source-label
           (unless omit-source-label
             (if source-buffer
                 (with-current-buffer source-buffer
                   (proofread--backend-checker-source-label
                    checker descriptor))
               (proofread--backend-checker-source-label
                checker descriptor)))))
      (proofread--make-checker-preparation
       descriptor checker backend-identity checker-identity
       source-label))))

(defun proofread--prepare-checker
    (checker descriptor &optional omit-source-label)
  "Return a checker preparation using captured DESCRIPTOR.
Snapshot CHECKER options before computing identities.  When
OMIT-SOURCE-LABEL is non-nil, skip the presentation-only operation."
  (proofread--finish-checker-preparation
   (proofread--checker-with-options-snapshot checker descriptor)
   descriptor omit-source-label))

(defun proofread--request-current-checker-p (request)
  "Return non-nil when REQUEST's checker is still current."
  (condition-case nil
      (and
       (cl-every (lambda (key)
                   (plist-member request key))
                 '( :checker-name :checker-owner
                    :checker-options :checker-identity))
       (let* ((owner (plist-get request :checker-owner))
              (profile-name (plist-get request :profile))
              (checker-name (plist-get request :checker-name)))
         (cond
          ((plist-get owner :ad-hoc)
           (when-let* ((raw-checker
                        (proofread--ad-hoc-checker
                         (plist-get request :backend)))
                       (descriptor
                        (proofread--backend-descriptor
                         (plist-get raw-checker :backend)))
                       (preparation
                        (proofread--prepare-checker
                         raw-checker descriptor t))
                       (checker
                        (proofread--checker-preparation-checker
                         preparation)))
             (and (equal owner (proofread--checker-owner checker))
                  (equal (plist-get request :checker-identity)
                         (proofread--checker-preparation-checker-identity
                          preparation)))))
          ((null owner)
           (null (plist-get request :checker-identity)))
          (t
           (let* ((profile (proofread--current-profile))
                  (checker
                   (cl-find checker-name
                            (plist-get profile :checkers)
                            :key (lambda (candidate)
                                   (plist-get candidate :name))))
                  (descriptor
                   (and checker
                        (proofread--backend-descriptor
                         (plist-get checker :backend))))
                  (preparation
                   (and descriptor
                        (proofread--prepare-checker
                         checker descriptor t)))
                  (checker
                   (and preparation
                        (proofread--checker-preparation-checker
                         preparation))))
             (and (eq profile-name (plist-get profile :name))
                  (equal (plist-get request :language)
                         (plist-get profile :language))
                  (equal (plist-get request :display-language)
                         (plist-get profile :display-language))
                  checker
                  (equal owner
                         (proofread--checker-owner checker))
                  (equal (plist-get request :checker-identity)
                         (proofread--checker-preparation-checker-identity
                          preparation))))))))
    (error nil)))

;;;; State predicates

(defun proofread--queue-dispatch-inhibited-p ()
  "Return non-nil if this buffer owns queue-dispatch inhibition."
  (eq proofread--inhibit-queue-dispatch (current-buffer)))

(defun proofread--clearing-scheduled-work-p ()
  "Return non-nil when the current buffer is clearing scheduled work."
  (eq proofread--clearing-scheduled-work (current-buffer)))

(defun proofread--overlay-invalidation-inhibited-p ()
  "Return non-nil if this buffer owns correction-time inhibition."
  (eq proofread--inhibit-overlay-invalidation (current-buffer)))

;;;; Request batches and reporting

(defun proofread--condition-kind (condition)
  "Return the condition symbol represented by CONDITION."
  (cond
   ((symbolp condition) condition)
   ((and (consp condition) (symbolp (car condition)))
    (car condition))
   (t 'error)))

(defun proofread--make-request-batch (works)
  "Return shared lifecycle state for WORKS dispatched together."
  (list :id (cl-incf proofread--request-batch-sequence)
        :pending (length works)
        :errors nil
        :buffer (current-buffer)
        :reported nil))

(defun proofread--attach-request-batch (works)
  "Attach one shared request batch to WORKS and return it."
  (when works
    (let ((batch (proofread--make-request-batch works)))
      (dolist (work works)
        (setf (proofread--scheduled-work-batch work) batch))
      batch)))

(defun proofread--backend-error-message (result)
  "Return caller-readable non-secret backend error text from RESULT."
  (format "Proofreading backend error (%S)"
          (proofread--condition-kind (plist-get result :error))))

(defun proofread--message-without-resizing (format-string &rest args)
  "Display FORMAT-STRING with ARGS as a bounded single-line message."
  (let* ((message-truncate-lines t)
         (message
          (string-clean-whitespace
           (apply #'format format-string args))))
    (message "%s"
             (truncate-string-to-width message 120 nil nil "..."))))

(defun proofread-report-warning-without-window (message summary)
  "Log warning MESSAGE without a window and echo short SUMMARY."
  (let ((warning-minimum-level :error))
    (display-warning 'proofread message :warning))
  (proofread--message-without-resizing "proofread: %s" summary))

;; Compatibility for proofread-popup 0.1.0.
(define-obsolete-function-alias
  'proofread--report-warning-without-window
  'proofread-report-warning-without-window
  "0.2.0")

(defun proofread--request-batch-error-counts (errors)
  "Return an alist counting backend error message strings in ERRORS."
  (let (counts)
    (dolist (message errors)
      (setf (alist-get message counts nil nil #'equal)
            (1+ (or (alist-get message counts nil nil #'equal) 0))))
    (nreverse counts)))

(defun proofread--report-request-batch-errors (batch)
  "Report accumulated backend errors for completed BATCH once."
  (let ((errors (plist-get batch :errors))
        (buffer (plist-get batch :buffer)))
    (when (and errors
               (not (plist-get batch :reported))
               (buffer-live-p buffer))
      (setf (plist-get batch :reported) t)
      (let* ((counts (proofread--request-batch-error-counts errors))
             (shown (cl-subseq counts 0 (min 3 (length counts))))
             (remaining (- (length counts) (length shown)))
             (details
              (mapconcat
               (lambda (entry)
                 (format "%s (x%d)"
                         (truncate-string-to-width
                          (car entry) 160 nil nil "...")
                         (cdr entry)))
               shown ", ")))
        (proofread-report-warning-without-window
         (format
          (concat "Proofreading failed for %d request%s in one "
                  "check (%s%s).  Run M-x "
                  "proofread-show-buffer-requests before retrying "
                  "for details")
          (length errors)
          (if (= (length errors) 1) "" "s")
          details
          (if (> remaining 0)
              (format ", and %d more error kind%s"
                      remaining (if (= remaining 1) "" "s"))
            ""))
         (format "%d request%s failed; see *Warnings*"
                 (length errors)
                 (if (= (length errors) 1) "" "s")))))))

(defun proofread--settle-request-batch
    (work &optional result status)
  "Settle WORK in its shared batch using RESULT and final STATUS."
  (when-let* ((batch (proofread--scheduled-work-batch work)))
    (unless (proofread--scheduled-work-batch-settled work)
      (setf (proofread--scheduled-work-batch-settled work) t)
      (when (eq status 'error)
        (push (proofread--backend-error-message result)
              (plist-get batch :errors)))
      (setf (plist-get batch :pending)
            (max 0 (1- (plist-get batch :pending))))
      (when (zerop (plist-get batch :pending))
        (proofread--report-request-batch-errors batch)))))

(defun proofread--request-log-schema-object-fields (object)
  "Return request-log field specifications for OBJECT."
  (cdr (assq object (plist-get proofread--request-log-schema :objects))))

(defun proofread--request-log-safe-position-value (value)
  "Return a detached safe representation of position VALUE."
  (cons t (proofread--position-integer value)))

(defun proofread--request-log-safe-string-value (value)
  "Return a detached safe representation of string VALUE."
  (when (stringp value)
    (cons t (substring-no-properties value))))

(defun proofread--request-log-safe-symbol-value (value)
  "Return a safe representation of symbol VALUE."
  (when (symbolp value)
    (cons t value)))

(defun proofread--request-log-safe-source-value (value)
  "Return a detached safe representation of source VALUE."
  (cond
   ((symbolp value) (cons t value))
   ((stringp value)
    (cons t (substring-no-properties value)))))

(defun proofread--request-log-safe-integer-value (value)
  "Return a safe representation of integer VALUE."
  (when (integerp value)
    (cons t value)))

(defun proofread--request-log-safe-buffer-value (value)
  "Return a safe representation of buffer VALUE."
  (when (bufferp value)
    (cons t value)))

(defun proofread--request-log-safe-time-value (value)
  "Return a detached safe representation of time VALUE."
  (when (and (proper-list-p value)
             (cl-every #'integerp value))
    (cons t (copy-sequence value))))

(defun proofread--request-log-safe-property-value (property value)
  "Return `(t . COPY)' when PROPERTY and VALUE are safe to log."
  (if (null value)
      (cons t nil)
    (when-let* ((sanitizer
                 (alist-get
                  property
                  (plist-get proofread--request-log-schema
                             :property-sanitizers))))
      (funcall sanitizer value))))

(defun proofread--request-log-identity-fingerprint (identity)
  "Return a detached fingerprint for IDENTITY, or nil."
  (when identity
    (let ((existing (and (proper-list-p identity)
                         (plist-get identity :fingerprint))))
      (if (and (stringp existing)
               (string-match-p
                "\\`[[:xdigit:]]\\{64\\}\\'" existing))
          (substring-no-properties existing)
        (condition-case nil
            (let ((print-circle t)
                  (print-length nil)
                  (print-level nil))
              (secure-hash 'sha256 (prin1-to-string identity)))
          (error nil))))))

(defun proofread--request-log-safe-object-property
    (object property _safe)
  "Return OBJECT's safe scalar PROPERTY."
  (when (plist-member object property)
    (proofread--request-log-safe-property-value
     property (plist-get object property))))

(defun proofread--request-log-safe-object-identity-fingerprint
    (object _property _safe)
  "Return a safe fingerprint of identity OBJECT."
  (when-let* ((fingerprint
               (proofread--request-log-identity-fingerprint object)))
    (cons t fingerprint)))

(defun proofread--request-log-safe-object-summary-fingerprint
    (_object _property safe)
  "Return a fingerprint of the fields already in SAFE."
  (when-let* ((fingerprint
               (proofread--request-log-identity-fingerprint safe)))
    (cons t fingerprint)))

(defun proofread--request-log-safe-object-backend-identity
    (object property _safe)
  "Return OBJECT's safe backend identity PROPERTY."
  (when (plist-member object property)
    (cons t
          (proofread--request-log-safe-backend-identity
           (plist-get object property)))))

(defun proofread--request-log-safe-object-checker-identity
    (object property _safe)
  "Return OBJECT's safe checker identity PROPERTY."
  (when (plist-member object property)
    (cons t
          (proofread--request-log-safe-checker-identity
           (plist-get object property)))))

(defun proofread--request-log-safe-object-request
    (object property _safe)
  "Return OBJECT's safe nested request PROPERTY."
  (when (plist-member object property)
    (cons t
          (proofread--request-log-safe-request
           (plist-get object property)))))

(defun proofread--request-log-safe-object-diagnostics
    (object property _safe)
  "Return OBJECT's safe nested diagnostics PROPERTY."
  (when (plist-member object property)
    (cons t
          (proofread--request-log-safe-diagnostics
           (plist-get object property)))))

(defun proofread--request-log-safe-object-diagnostic-source
    (object property _safe)
  "Return OBJECT's safe diagnostic source PROPERTY."
  (when-let* ((source (plist-get object property))
              ((or (symbolp source) (stringp source))))
    (cons t (if (stringp source)
                (substring-no-properties source)
              source))))

(defun proofread--request-log-safe-object-diagnostic-suggestions
    (object property _safe)
  "Return OBJECT's safe diagnostic suggestions PROPERTY."
  (when (plist-member object property)
    (let ((suggestions (plist-get object property)))
      (when (and (proper-list-p suggestions)
                 (cl-every #'stringp suggestions))
        (cons t
              (mapcar #'substring-no-properties suggestions))))))

(defun proofread--request-log-safe-object-condition
    (object property _safe)
  "Return the condition kind in OBJECT's PROPERTY."
  (when (plist-member object property)
    (cons t (proofread--condition-kind (plist-get object property)))))

(defun proofread--request-log-safe-object-backend-message
    (object _property _safe)
  "Return OBJECT's bounded backend failure message."
  (when (or (eq (plist-get object :status) 'error)
            (plist-member object :message))
    (cons t "Backend request failed")))

(defun proofread--request-log-safe-object (kind object)
  "Return a safe KIND representation of request-log OBJECT."
  (when (proper-list-p object)
    (let (safe)
      (dolist (field (proofread--request-log-schema-object-fields kind))
        (let ((property (car field))
              (sanitizer (cadr field)))
          (when-let* ((safe-value
                       (condition-case nil
                           (funcall sanitizer object property safe)
                         (error nil))))
            (setq safe
                  (plist-put safe property (cdr safe-value))))))
      safe)))

(defun proofread--request-log-safe-checker-owner (owner)
  "Return a detached safe representation of checker OWNER."
  (proofread--request-log-safe-object 'checker-owner owner))

(defun proofread--request-log-safe-checker-owner-value (value)
  "Return a safe checker owner representation of VALUE."
  (when-let* ((owner
               (proofread--request-log-safe-checker-owner value)))
    (cons t owner)))

(defun proofread--request-log-safe-backend-identity (identity)
  "Return a safe summary of backend IDENTITY."
  (proofread--request-log-safe-object 'backend-identity identity))

(defun proofread--request-log-safe-checker-identity (identity)
  "Return a safe summary of checker IDENTITY without raw options."
  (proofread--request-log-safe-object 'checker-identity identity))

(defun proofread--request-log-safe-request (request)
  "Return a detached request-log representation of REQUEST."
  (proofread--request-log-safe-object 'request request))

(defun proofread--request-log-safe-chunk (chunk)
  "Return a detached request-log representation of CHUNK."
  (proofread--request-log-safe-object 'chunk chunk))

(defun proofread--request-log-safe-diagnostic (diagnostic)
  "Return a detached request-log representation of DIAGNOSTIC."
  (proofread--request-log-safe-object 'diagnostic diagnostic))

(defun proofread--request-log-safe-diagnostics (diagnostics)
  "Return detached request-log representations of DIAGNOSTICS."
  (when (proper-list-p diagnostics)
    (mapcar #'proofread--request-log-safe-diagnostic diagnostics)))

(defun proofread--request-log-safe-result (result)
  "Return a detached request-log representation of RESULT."
  (proofread--request-log-safe-object 'result result))

(defun proofread--request-log-safe-cache-entry (entry)
  "Return a detached request-log representation of cache ENTRY."
  (proofread--request-log-safe-object 'cache-entry entry))

(defun proofread--request-log-safe-http-parameters (parameters)
  "Return detached HTTP PARAMETERS text, or nil."
  (when (stringp parameters)
    (substring-no-properties parameters)))

(defun proofread--request-log-safe-url (url)
  "Return the origin of absolute URL, or nil."
  (when (stringp url)
    (condition-case nil
        (let* ((parsed
                (url-generic-parse-url
                 (substring-no-properties url)))
               (type (url-type parsed))
               (host (url-host parsed))
               (port (url-portspec parsed)))
          (when (and (stringp type) (stringp host)
                     (not (string-empty-p type))
                     (not (string-empty-p host)))
            (format "%s://%s%s"
                    type
                    (if (and (string-match-p ":" host)
                             (not (string-prefix-p "[" host)))
                        (format "[%s]" host)
                      host)
                    (if port (format ":%s" port) ""))))
      (error nil))))

(defun proofread--request-log-safe-event-property (event property)
  "Return EVENT's safe scalar PROPERTY, or nil when it is absent."
  (when (plist-member event property)
    (proofread--request-log-safe-property-value
     property (plist-get event property))))

(defun proofread--request-log-safe-event-request (event _property)
  "Return EVENT's detached request field, including result fallback."
  (when-let* ((request
               (or (plist-get event :request)
                   (let ((result (plist-get event :result)))
                     (and (proper-list-p result)
                          (plist-get result :request))))))
    (cons t (proofread--request-log-safe-request request))))

(defun proofread--request-log-safe-event-nested
    (event property sanitizer)
  "Sanitize nested EVENT PROPERTY with SANITIZER."
  (when (plist-member event property)
    (cons t (funcall sanitizer (plist-get event property)))))

(defun proofread--request-log-safe-event-chunk (event property)
  "Return EVENT's safe nested chunk PROPERTY."
  (cons t (proofread--request-log-safe-chunk
           (plist-get event property))))

(defun proofread--request-log-safe-event-diagnostics (event property)
  "Return EVENT's safe nested diagnostics PROPERTY."
  (proofread--request-log-safe-event-nested
   event property #'proofread--request-log-safe-diagnostics))

(defun proofread--request-log-safe-event-result (event property)
  "Return EVENT's safe nested result PROPERTY."
  (cons t (proofread--request-log-safe-result
           (plist-get event property))))

(defun proofread--request-log-safe-event-cache-entry (event property)
  "Return EVENT's safe nested cache entry PROPERTY."
  (proofread--request-log-safe-event-nested
   event property #'proofread--request-log-safe-cache-entry))

(defun proofread--request-log-safe-event-required-cache-entry
    (event property)
  "Return EVENT's safe nested cache entry PROPERTY, even if absent."
  (cons t (proofread--request-log-safe-cache-entry
           (plist-get event property))))

(defun proofread--request-log-safe-event-url (event property)
  "Return EVENT's safe URL origin PROPERTY."
  (when (plist-member event property)
    (when-let* ((url
                 (proofread--request-log-safe-url
                  (plist-get event property))))
      (cons t url))))

(defun proofread--request-log-safe-event-text (event property)
  "Return EVENT's detached string PROPERTY."
  (when (plist-member event property)
    (when-let* ((text
                 (proofread--request-log-safe-http-parameters
                  (plist-get event property))))
      (cons t text))))

(defun proofread--request-log-safe-event-condition (event property)
  "Return the condition kind in EVENT's PROPERTY."
  (when (plist-member event property)
    (cons t (proofread--condition-kind (plist-get event property)))))

(defun proofread--request-log-safe-event-required-condition
    (event property)
  "Return the condition kind in EVENT's PROPERTY, even if absent."
  (cons t (proofread--condition-kind (plist-get event property))))

(defun proofread--request-log-safe-event-backend-message
    (event _property)
  "Return EVENT's bounded backend failure message."
  (when (or (plist-member event :error)
            (plist-member event :message))
    (cons t "Backend request failed")))

(defun proofread--request-log-safe-event-checker-message
    (event _property)
  "Return EVENT's checker failure message from safe scalar fields."
  (let ((checker
         (proofread--request-log-safe-property-value
          :checker-name (plist-get event :checker-name)))
        (phase
         (proofread--request-log-safe-property-value
          :phase (plist-get event :phase))))
    (cons
     t
     (format "Checker %S failed during %s"
             (cdr checker)
             (proofread--checker-dispatch-phase-label
              (cdr phase))))))

(defun proofread--request-log-event-schema-fields (type)
  "Return request-log field specifications for event TYPE."
  (let ((events (plist-get proofread--request-log-schema :events)))
    (append (cdr (assq t events))
            (unless (eq type t)
              (cdr (assq type events))))))

(defun proofread--request-log-safe-event (event)
  "Return a detached safe representation of lifecycle EVENT."
  (when (proper-list-p event)
    (let ((type (plist-get event :type))
          safe)
      (dolist (field (proofread--request-log-event-schema-fields type))
        (let ((property (car field))
              (sanitizer (cadr field)))
          (when-let* ((safe-value
                       (condition-case nil
                           (funcall sanitizer event property)
                         (error nil))))
            (setq safe
                  (plist-put safe property (cdr safe-value))))))
      safe)))

(defun proofread--request-log-copy-safe-value (value)
  "Return a recursive detached copy of safe request-log VALUE."
  (cond
   ((stringp value) (substring-no-properties value))
   ((consp value)
    (cons (proofread--request-log-copy-safe-value (car value))
          (proofread--request-log-copy-safe-value (cdr value))))
   ((bufferp value) value)
   ((vectorp value)
    (apply #'vector
           (mapcar #'proofread--request-log-copy-safe-value value)))
   (t value)))

(defun proofread--run-request-log-hook (event)
  "Run request-log hooks with copies of canonical safe EVENT."
  (when proofread-request-log-hook
    (run-hook-wrapped
     'proofread-request-log-hook
     (lambda (function event)
       (condition-case err
           (funcall function
                    (proofread--request-log-copy-safe-value event))
         (error
          (proofread-report-warning-without-window
           (format "Proofread request log hook error (%S)"
                   (proofread--condition-kind err))
           "request log hook failed; see *Warnings*")))
       nil)
     event))
  event)

(defun proofread--publish-request-log-event (raw-event)
  "Record and publish one safe projection of RAW-EVENT."
  (let ((event (proofread--request-log-safe-event raw-event)))
    (condition-case err
        (proofread--request-log-record-canonical-event event)
      (error
       (proofread-report-warning-without-window
        (format "Proofread request log recorder error (%S)"
                (proofread--condition-kind err))
        "request log recorder failed; see *Warnings*")))
    (proofread--run-request-log-hook event)
    (proofread--request-log-copy-safe-value event)))

(defun proofread--checker-dispatch-phase-label (phase)
  "Return a caller-readable label for checker dispatch PHASE."
  (pcase phase
    ('backend-loading "backend loading")
    ('checker-options "checker options snapshot")
    ('checker-identity "checker identity calculation")
    ('request-construction "request construction")
    (_ (format "%s" phase))))

(defun proofread--make-checker-dispatch-failure
    (profile checker phase err)
  "Return a dispatch failure for CHECKER in PROFILE.
PHASE identifies the failed preparation phase and ERR is the
original error value."
  (let* ((profile-name (plist-get profile :name))
         (checker-name (plist-get checker :name))
         (backend (plist-get checker :backend))
         (error-kind
          (proofread--condition-kind err))
         (message
          (format
           (concat "Proofread profile %S checker %S using backend %S "
                   "failed during %s (%S)")
           profile-name checker-name backend
           (proofread--checker-dispatch-phase-label phase)
           error-kind)))
    (list :profile profile-name
          :checker-name checker-name
          :backend backend
          :phase phase
          :error error-kind
          :message message)))

(defun proofread--report-checker-dispatch-failure (failure)
  "Record and report one bounded checker dispatch FAILURE."
  (let* ((message
          (truncate-string-to-width
           (string-clean-whitespace
            (plist-get failure :message))
           320 nil nil "..."))
         (event
          (proofread--publish-request-log-event
           (append
            (list :type 'checker-dispatch-failed
                  :time (current-time)
                  :log-id (cl-incf proofread--request-log-sequence)
                  :buffer (current-buffer)
                  :status 'error)
            failure))))
    (proofread-report-warning-without-window
     message
     (format "checker %S failed; see *Warnings*"
             (plist-get failure :checker-name)))
    event))

(defun proofread--report-checker-dispatch-failure-safely (failure)
  "Report checker dispatch FAILURE without interrupting other work."
  (condition-case nil
      (proofread--report-checker-dispatch-failure failure)
    (error nil)))

(defun proofread--progress-message (format-string &rest args)
  "Display a routine progress message using FORMAT-STRING and ARGS."
  (unless proofread-inhibit-progress-messages
    (apply #'message format-string args)))

(defun proofread--run-diagnostics-changed-hook ()
  "Run diagnostics hooks without disrupting proofreading."
  (when proofread-diagnostics-changed-hook
    (run-hook-wrapped
     'proofread-diagnostics-changed-hook
     (lambda (function)
       (condition-case err
           (funcall function)
         (error
          (proofread-report-warning-without-window
           (format "Proofread diagnostics hook error: %s"
                   (error-message-string err))
           "diagnostics hook failed; see *Warnings*")))
       nil))))

;;;; Diagnostic and range data

(defun proofread--record-request-event (source type &rest properties)
  "Record a request event of TYPE for SOURCE with PROPERTIES.
SOURCE is normally a `proofread--scheduled-work' record.  Backends may
record their own events with the immutable request payload they were
given; its weak log-owner index supplies the scheduler-owned log id."
  (let* ((work (and (proofread--scheduled-work-p source) source))
         (request (if work
                      (proofread--scheduled-work-request work)
                    source))
         (log-id
          (if work
              (proofread--scheduled-work-log-id work)
            (and (hash-table-p proofread--request-log-owner-ids)
                 (gethash request
                          proofread--request-log-owner-ids))))
         (raw-event
          (append
           (list :type type
                 :time (current-time)
                 :log-id log-id
                 :request-id (plist-get request :id)
                 :buffer (plist-get request :buffer)
                 :beg (plist-get request :beg)
                 :end (plist-get request :end)
                 :request request)
           properties))
         event)
    (unwind-protect
        (progn
          (setq event
                (proofread--publish-request-log-event raw-event)))
      (pcase type
        ('final-result
         (when work
           (proofread--settle-request-batch
            work (plist-get raw-event :result)
            (plist-get raw-event :status))))
        ('cancelled
         (when work
           (proofread--settle-request-batch work)))))
    event))

(defun proofread--make-diagnostic (&rest properties)
  "Return a proofread diagnostic plist from PROPERTIES.
The returned plist contains the keys in `proofread--diagnostic-keys'."
  (mapcan (lambda (key)
            (list key (plist-get properties key)))
          proofread--diagnostic-keys))

(defun proofread--diagnostic-with-request-provenance
    (request diagnostic)
  "Return DIAGNOSTIC annotated with provenance from REQUEST."
  (let ((diagnostic (copy-sequence diagnostic)))
    (dolist (key proofread--diagnostic-provenance-keys)
      (setq diagnostic
            (plist-put
             diagnostic key
             (proofread--snapshot-value (plist-get request key)))))
    diagnostic))

(defun proofread--diagnostics-with-request-provenance
    (request diagnostics)
  "Return DIAGNOSTICS annotated with provenance from REQUEST."
  (mapcar (lambda (diagnostic)
            (proofread--diagnostic-with-request-provenance
             request diagnostic))
          diagnostics))

(defun proofread--position-integer (position)
  "Return integer POSITION, or nil for a non-buffer position."
  (cond
   ((integerp position) position)
   ((markerp position) (marker-position position))))

(defun proofread--current-buffer-position-p (position)
  "Return non-nil if POSITION belongs to the current buffer."
  (or (integerp position)
      (and (markerp position)
           (eq (marker-buffer position) (current-buffer)))))

;;;; Range algebra

;; Proofread represents buffer ranges as half-open (BEG . END) pairs.
;; Most operations accept zero-width ranges, but selectable check ranges
;; are always nonempty.  Relations below state their zero-width and
;; adjacency behavior explicitly so callers do not invent local variants.

(defun proofread--range-valid-p (range)
  "Return non-nil when RANGE is a valid integer buffer range.
The half-open RANGE may be zero-width."
  (and (consp range)
       (integerp (car range))
       (integerp (cdr range))
       (<= (car range) (cdr range))))

(defun proofread--range-less-p (left right)
  "Return non-nil if range LEFT should sort before range RIGHT.
Compare beginnings first and ends second.  LEFT and RIGHT must be
valid integer ranges."
  (or (< (car left) (car right))
      (and (= (car left) (car right))
           (< (cdr left) (cdr right)))))

(defun proofread--range-overlaps-p (left right)
  "Return non-nil when half-open ranges LEFT and RIGHT overlap.
Adjacent ranges do not overlap.  A zero-width range never overlaps
another range, including a zero-width range at the same position.
LEFT and RIGHT must be valid integer ranges."
  (and (< (car left) (cdr left))
       (< (car right) (cdr right))
       (< (car left) (cdr right))
       (< (car right) (cdr left))))

(defun proofread--range-conflicts-p (left right)
  "Return non-nil when ranges LEFT and RIGHT conflict.
Strictly overlapping half-open ranges conflict, but adjacent nonempty
ranges do not.  A zero-width range conflicts when its position lies on
either closed boundary of the other range; equal zero-width ranges
therefore conflict.  LEFT and RIGHT must be valid integer ranges."
  (or (proofread--range-overlaps-p left right)
      (and (= (car left) (cdr left))
           (<= (car right) (car left))
           (<= (car left) (cdr right)))
      (and (= (car right) (cdr right))
           (<= (car left) (car right))
           (<= (car right) (cdr left)))))

(defun proofread--range-contains-p (outer inner)
  "Return non-nil if range INNER is contained in range OUTER.
Containment compares both boundaries inclusively.  Thus a zero-width
INNER at either boundary of OUTER is contained, including at OUTER's
half-open end.  A zero-width OUTER contains only the equal zero-width
range.  OUTER and INNER must be valid integer ranges."
  (and (<= (car outer) (car inner))
       (<= (cdr inner) (cdr outer))))

(defun proofread--range-covers-position-p (range position)
  "Return non-nil when half-open RANGE covers POSITION.
A nonempty range covers its beginning but not its end.  A zero-width
range covers only its own position.  RANGE must be a valid integer
range; POSITION may be an integer or live marker."
  (let ((position (proofread--position-integer position)))
    (and position
         (<= (car range) position)
         (or (< position (cdr range))
             (and (= (car range) (cdr range))
                  (= position (car range)))))))

(defun proofread--range-strictly-contains-position-p (range position)
  "Return non-nil when POSITION is strictly inside RANGE.
Neither boundary is contained, and a zero-width range contains no
position.  RANGE must be a valid integer range; POSITION may be an
integer or live marker."
  (let ((position (proofread--position-integer position)))
    (and position
         (< (car range) position)
         (< position (cdr range)))))

(defun proofread--range-intersection (left right)
  "Return the nonempty intersection of ranges LEFT and RIGHT.
Return nil for adjacent ranges and whenever either range is
zero-width.  LEFT and RIGHT must be valid integer ranges."
  (when (proofread--range-overlaps-p left right)
    (cons (max (car left) (car right))
          (min (cdr left) (cdr right)))))

(defun proofread--range-affected-by-edit-p (range edit)
  "Return non-nil when EDIT affects RANGE.
For a zero-width EDIT (an insertion), a nonempty RANGE is affected only
when the insertion is strictly inside it; insertion at either boundary
does not affect it.  A zero-width RANGE is affected by insertion at its
exact position.  A nonempty EDIT uses `proofread--range-conflicts-p',
so adjacent nonempty ranges remain unaffected while zero-width ranges
at either edit boundary are affected.  RANGE and EDIT must be valid
integer ranges."
  (if (= (car edit) (cdr edit))
      (if (= (car range) (cdr range))
          (= (car edit) (car range))
        (proofread--range-strictly-contains-position-p
         range (car edit)))
    (proofread--range-conflicts-p edit range)))

(defun proofread--range-conflicts-any-p (range ranges)
  "Return non-nil when RANGE conflicts with one of RANGES."
  (cl-some
   (lambda (candidate)
     (proofread--range-conflicts-p range candidate))
   ranges))

(defun proofread--range-precedes-without-conflict-p (left right)
  "Return non-nil if LEFT precedes RIGHT without a conflict."
  (and (<= (cdr left) (car right))
       (not (proofread--range-conflicts-p left right))))

(defun proofread--range-conflicting-entries (ranges entries)
  "Return ENTRIES whose ranges conflict with one of RANGES.
Each element of ENTRIES must have the form \=(OBJECT . RANGE).  RANGE
and every element of RANGES must be valid integer ranges of the form
\=(BEG . END).  Inputs may be unsorted and are not modified.  Return
entries ordered by range while retaining original entries, duplicate
occurrences, and object identity."
  (let* ((remaining-ranges
          (sort (copy-sequence ranges) #'proofread--range-less-p))
         (sorted-entries
          (sort (copy-sequence entries)
                (lambda (left right)
                  (proofread--range-less-p (cdr left) (cdr right)))))
         conflicts)
    (dolist (entry sorted-entries)
      (let ((range (cdr entry)))
        (while (and remaining-ranges
                    (proofread--range-precedes-without-conflict-p
                     (car remaining-ranges) range))
          (setq remaining-ranges (cdr remaining-ranges)))
        (when (and remaining-ranges
                   (proofread--range-conflicts-p
                    range (car remaining-ranges)))
          (push entry conflicts))))
    (nreverse conflicts)))

(defun proofread--range-contained-in-any-p (range ranges)
  "Return non-nil if RANGE is completely contained in RANGES."
  (cl-some
   (lambda (outer)
     (proofread--range-contains-p outer range))
   ranges))

(defun proofread--merge-ranges (ranges merge-adjacent-p)
  "Return sorted copies of nonempty RANGES with overlaps merged.
RANGES must contain valid, nonempty integer ranges.  When
MERGE-ADJACENT-P is non-nil, merge adjacent ranges too.  Zero-width
ranges are outside this helper's contract."
  (let (merged)
    (dolist (range
             (sort
              (mapcar (lambda (range)
                        (cons (car range) (cdr range)))
                      ranges)
              #'proofread--range-less-p))
      (if (and merged
               (if merge-adjacent-p
                   (<= (car range) (cdar merged))
                 (proofread--range-overlaps-p
                  (car merged) range)))
          (setcdr (car merged)
                  (max (cdar merged) (cdr range)))
        (push range merged)))
    (nreverse merged)))

(defun proofread--normalize-region-range (beg end)
  "Return an ordered range for BEG and END in `current-buffer'.
Signal a `user-error' when either position is missing, is neither an
integer nor a marker in the current buffer, or makes the range empty.
Do not clip the range to the accessible portion of the buffer."
  (unless (and beg end)
    (user-error "No active region"))
  (unless (and (proofread--current-buffer-position-p beg)
               (proofread--current-buffer-position-p end))
    (user-error "Region boundaries are not in the current buffer"))
  (let ((beg (proofread--position-integer beg))
        (end (proofread--position-integer end)))
    (when (= beg end)
      (user-error "The region is empty"))
    (cons (min beg end) (max beg end))))

(defun proofread--normalize-ranges (ranges)
  "Return sorted, deduplicated RANGES.
Each range is a cons cell of the form (BEG . END).  Convert markers to
integers and discard reversed, malformed, and zero-width ranges.  Merge
both strictly overlapping and adjacent ranges."
  (proofread--merge-ranges
   (delq nil
         (mapcar
          (lambda (range)
            (when (consp range)
              (let ((beg (proofread--position-integer (car range)))
                    (end (proofread--position-integer (cdr range))))
                (when (and beg end (< beg end))
                  (cons beg end)))))
          ranges))
   t))

(defun proofread--normalize-accessible-ranges (ranges)
  "Return normalized RANGES clipped to the accessible buffer portion."
  (let ((minimum (point-min))
        (maximum (point-max))
        clipped)
    (dolist (range ranges)
      (when (consp range)
        (let ((beg (proofread--position-integer (car range)))
              (end (proofread--position-integer (cdr range))))
          (when (and beg end)
            (let ((lower (min beg end))
                  (upper (max beg end)))
              (push (cons (min maximum (max minimum lower))
                          (min maximum (max minimum upper)))
                    clipped))))))
    (proofread--normalize-ranges clipped)))

;;;; Target discovery

(cl-defstruct
    (proofread--selection-plan
     (:constructor proofread--make-selection-plan
                   (ranges domains islands)))
  "One immutable-by-convention target selection snapshot.
RANGES are normalized accessible half-open ranges.  DOMAINS are the
complete target domains returned by discovery, and ISLANDS are their
intersections with RANGES."
  ranges
  domains
  islands)

(defun proofread--effective-target-policy ()
  "Return the effective proofreading target policy for this buffer."
  (pcase proofread-targets
    ('auto
     (if (derived-mode-p 'prog-mode)
         'comments-and-docstrings
       'all))
    ((or 'all 'comments 'docstrings 'comments-and-docstrings)
     proofread-targets)
    (_
     (error "Invalid proofread target policy: %S"
            proofread-targets))))

(defun proofread--target-policy-includes-p (policy kind)
  "Return non-nil when target POLICY includes KIND."
  (pcase kind
    ('comment (memq policy '( comments comments-and-docstrings)))
    ('docstring (memq policy '( docstrings comments-and-docstrings)))
    ('text (eq policy 'all))))

(defun proofread--syntax-container-state-p (state kind)
  "Return non-nil if STATE is inside syntax container KIND."
  (pcase kind
    ('comment (nth 4 state))
    ('string (nth 3 state))
    (_ (error "Unsupported syntax container kind: %S" kind))))

(defmacro proofread--with-widened-syntax (&rest body)
  "Evaluate BODY against syntax state for the full current buffer."
  (declare (indent 0) (debug t))
  (let ((was-narrowed (make-symbol "was-narrowed")))
    `(let ((,was-narrowed (buffer-narrowed-p)))
       (save-excursion
         (save-restriction
           (widen)
           (when ,was-narrowed
             (syntax-ppss-flush-cache (point-min)))
           (when syntax-propertize-function
             (syntax-propertize (point-max)))
           (when ,was-narrowed
             (syntax-ppss-flush-cache (point-min)))
           (with-syntax-table (or syntax-ppss-table (syntax-table))
             ,@body))))))

(defun proofread--normalize-overlapping-ranges (ranges)
  "Return sorted nonempty RANGES with strict overlaps merged.
RANGES must contain valid, nonempty integer ranges.  Unlike
`proofread--normalize-ranges', keep adjacent ranges separate.
Zero-width ranges are outside this function's contract."
  (proofread--merge-ranges ranges nil))

(defun proofread--advance-to-syntax-container-end
    (position state buffer-end kind)
  "Advance POSITION and parse STATE to the end of container KIND.
BUFFER-END is the end of the widened buffer.  Return a cons containing
the new position and parse state."
  (while (and (< position buffer-end)
              (proofread--syntax-container-state-p state kind))
    (goto-char position)
    (let ((old-position position))
      (setq state
            (parse-partial-sexp
             position buffer-end nil nil state 'syntax-table)
            position (point))
      (when (= position old-position)
        (error "Syntax parser made no progress at %d" position))))
  (cons position state))

(defun proofread--syntax-containers-for-range (range buffer-end kind)
  "Return full syntactic containers of KIND overlapping RANGE.
BUFFER-END is the end of the widened buffer."
  (let* ((beg (car range))
         (end (cdr range))
         ;; Include enough lookahead for a delimiter that crosses END.
         (scan-end (min buffer-end (+ end 2)))
         (position beg)
         (state (syntax-ppss beg))
         containers)
    (when (proofread--syntax-container-state-p state kind)
      (let* ((container-beg (nth 8 state))
             (advanced
              (proofread--advance-to-syntax-container-end
               position state buffer-end kind))
             (container (cons container-beg (car advanced))))
        (when (proofread--range-overlaps-p container range)
          (push container containers))
        (setq position (car advanced)
              state (cdr advanced))))
    (while (< position scan-end)
      (goto-char position)
      (let ((old-position position))
        (setq state
              (parse-partial-sexp
               position scan-end nil nil state 'syntax-table)
              position (point))
        (when (= position old-position)
          (error "Syntax parser made no progress at %d" position)))
      (when (proofread--syntax-container-state-p state kind)
        (let* ((container-beg (nth 8 state))
               (advanced
                (proofread--advance-to-syntax-container-end
                 position state buffer-end kind))
               (container (cons container-beg (car advanced))))
          (when (proofread--range-overlaps-p container range)
            (push container containers))
          (setq position (car advanced)
                state (cdr advanced)))))
    (nreverse containers)))

(defun proofread--syntax-containers-in-normalized-ranges
    (ranges kind)
  "Return full syntactic containers of KIND overlapping RANGES.
RANGES must be normalized inside the current restriction.  KIND is
either `comment' or `string'.  Returned containers may extend beyond
the restriction."
  (let (containers)
    (proofread--with-widened-syntax
      (dolist (range ranges)
        (setq containers
              (nconc
               (proofread--syntax-containers-for-range
                range (point-max) kind)
               containers))))
    (proofread--normalize-overlapping-ranges containers)))

(defun proofread--syntax-containers-for-ranges (ranges kind)
  "Return full syntactic containers of KIND overlapping RANGES.
Accept raw RANGES and normalize them within the current restriction.
KIND is either `comment' or `string'.  Returned containers may extend
beyond the restriction."
  (proofread--syntax-containers-in-normalized-ranges
   (proofread--normalize-accessible-ranges ranges) kind))

(defun proofread--ranges-separated-by-horizontal-space-p (left right)
  "Return non-nil if only horizontal space separates LEFT and RIGHT."
  (save-excursion
    (goto-char (cdr left))
    (skip-chars-forward " \t" (car right))
    (= (point) (car right))))

(defun proofread--merge-adjacent-comment-ranges (ranges)
  "Merge sorted comment RANGES separated only by indentation."
  (let (merged)
    (dolist (range ranges)
      (if (and merged
               (proofread--ranges-separated-by-horizontal-space-p
                (car merged) range))
          (setcdr (car merged) (cdr range))
        (push (copy-tree range) merged)))
    (nreverse merged)))

(defun proofread--comment-domain-expansion-size ()
  "Return the radius used to extend selected comment domains."
  (+ (* 2 (max 1 proofread-max-chunk-size))
     (max 0 proofread-context-size)))

(defun proofread--expand-adjacent-comment-domain
    (range minimum maximum)
  "Expand comment RANGE over adjacent comments.
MINIMUM and MAXIMUM bound the expansion."
  (let ((beg (car range))
        (end (cdr range))
        expanded)
    (while (not expanded)
      (goto-char end)
      (skip-chars-forward " \t")
      (let ((next-beg (point)))
        (if (and (< next-beg maximum)
                 (not (memq (char-after next-beg) '( ?\n ?\r)))
                 (forward-comment 1))
            (setq end (point))
          (setq expanded t))))
    (setq expanded nil)
    (while (not expanded)
      (goto-char beg)
      (skip-chars-backward " \t")
      (let ((previous-end (point)))
        (if (and (> previous-end minimum)
                 (nth 4 (syntax-ppss (1- previous-end)))
                 (progn
                   (goto-char beg)
                   (forward-comment -1)))
            (setq beg (point))
          (setq expanded t))))
    (cons beg end)))

(defun proofread--comment-domains-in-normalized-ranges (ranges)
  "Return logical comment domains overlapping normalized RANGES.
Consecutive line comments separated only by indentation are treated as
one domain so sentence context can cross their source lines."
  (let ((comments
         (proofread--syntax-containers-in-normalized-ranges
          ranges 'comment))
        (expansion-size (proofread--comment-domain-expansion-size))
        domains)
    (when comments
      (save-excursion
        (save-restriction
          (widen)
          (with-syntax-table (or syntax-ppss-table (syntax-table))
            (dolist (comment
                     (proofread--merge-adjacent-comment-ranges
                      comments))
              (push (proofread--expand-adjacent-comment-domain
                     comment
                     (max (point-min)
                          (- (car comment) expansion-size))
                     (min (point-max)
                          (+ (cdr comment) expansion-size)))
                    domains))))))
    (proofread--normalize-overlapping-ranges domains)))

(defun proofread--comment-domains-for-ranges (ranges)
  "Return logical comment domains overlapping raw RANGES.
Consecutive line comments separated only by indentation form one
domain so sentence context can cross their source lines."
  (proofread--comment-domains-in-normalized-ranges
   (proofread--normalize-accessible-ranges ranges)))

(defun proofread--face-value-contains-p (value face)
  "Return non-nil if FACE is present recursively in face VALUE."
  (cond
   ((eq value face) t)
   ((consp value)
    (or (proofread--face-value-contains-p (car value) face)
        (proofread--face-value-contains-p (cdr value) face)))
   ((vectorp value)
    (cl-some
     (lambda (item)
       (proofread--face-value-contains-p item face))
     value))))

(defun proofread--doc-face-at-p (position)
  "Return non-nil if POSITION is font-locked as doc text."
  (or (proofread--face-value-contains-p
       (get-text-property position 'face) 'font-lock-doc-face)
      (proofread--face-value-contains-p
       (get-text-property position 'font-lock-face)
       'font-lock-doc-face)))

(defun proofread--next-face-property-change (position limit)
  "Return the next face property change up to LIMIT.
Search after POSITION."
  (min (or (next-single-property-change position 'face nil limit)
           limit)
       (or (next-single-property-change
            position 'font-lock-face nil limit)
           limit)))

(defun proofread--previous-face-property-change (position limit)
  "Return the previous face property change down to LIMIT.
Search before POSITION."
  (max (or (previous-single-property-change position 'face nil limit)
           limit)
       (or (previous-single-property-change
            position 'font-lock-face nil limit)
           limit)))

(defun proofread--range-has-doc-face-p (beg end)
  "Return non-nil when some character from BEG to END has doc face."
  (let ((position beg)
        found)
    (while (and (< position end) (not found))
      (setq found (proofread--doc-face-at-p position))
      (unless found
        (setq position
              (proofread--next-face-property-change position end))))
    found))

(defun proofread--docstring-predicate-matches-p (beg end)
  "Return non-nil if a predicate accepts BEG through END."
  (cl-some
   (lambda (predicate)
     (and (functionp predicate)
          (condition-case nil
              (and (funcall predicate beg end) t)
            (error nil))))
   proofread-docstring-predicate-functions))

(defun proofread--expand-range-over-doc-face (range)
  "Expand RANGE over adjacent text marked with a doc face."
  (let ((beg (car range))
        (end (cdr range)))
    (while (and (> beg (point-min))
                (proofread--doc-face-at-p (1- beg)))
      (setq beg
            (proofread--previous-face-property-change
             beg (point-min))))
    (while (and (< end (point-max))
                (proofread--doc-face-at-p end))
      (setq end
            (proofread--next-face-property-change
             end (point-max))))
    (cons beg end)))

(defun proofread--font-lock-docstring-domain (string-range)
  "Return the font-lock docstring domain for STRING-RANGE, or nil."
  (let ((beg (car string-range))
        (end (cdr string-range))
        face-match)
    (setq face-match
          (condition-case nil
              (save-match-data
                ;; Fontifying the opening sample is enough for
                ;; conventional docstring rules and avoids traversing
                ;; a huge literal.
                (font-lock-ensure
                 beg
                 (min
                  end
                  (+ beg proofread--docstring-font-lock-sample-size)))
                (proofread--range-has-doc-face-p beg end))
            (error nil)))
    (when face-match
      (proofread--expand-range-over-doc-face string-range))))

(defun proofread--docstring-domains-in-normalized-ranges (ranges)
  "Return full docstring domains overlapping normalized RANGES."
  (let ((strings
         (proofread--syntax-containers-in-normalized-ranges
          ranges 'string))
        face-domains
        unmatched-strings
        domains)
    (save-excursion
      (save-restriction
        (widen)
        (dolist (string strings)
          (if-let* ((domain
                     (proofread--font-lock-docstring-domain string)))
              (push domain face-domains)
            (push string unmatched-strings)))
        ;; Python triple-quoted strings can appear as several
        ;; syntactic strings.  Normalize face-expanded domains before
        ;; calling custom predicates so predicates see the complete
        ;; source literal once.
        (setq face-domains (proofread--normalize-ranges face-domains))
        ;; A doc face is sufficient evidence by itself.  Predicates
        ;; are the fallback for strings that font lock did not
        ;; classify.
        (dolist (domain face-domains)
          (push domain domains))
        (dolist (domain
                 (proofread--normalize-ranges unmatched-strings))
          (unless (cl-some
                   (lambda (face-domain)
                     (proofread--range-contains-p
                      face-domain domain))
                   face-domains)
            (when (proofread--docstring-predicate-matches-p
                   (car domain) (cdr domain))
              (push domain domains))))))
    (proofread--normalize-ranges domains)))

(defun proofread--docstring-domains-for-ranges (ranges)
  "Return full docstring domains overlapping raw RANGES."
  (proofread--docstring-domains-in-normalized-ranges
   (proofread--normalize-accessible-ranges ranges)))

(defun proofread--make-target-domain
    (range kind policy minimum maximum)
  "Return a target domain plist for RANGE and KIND under POLICY.
MINIMUM and MAXIMUM are the accessible buffer bounds."
  (let ((beg (max minimum (car range)))
        (end (min maximum (cdr range))))
    (when (< beg end)
      (list :kind kind
            :target-policy policy
            :domain-beg beg
            :domain-end end))))

(defun proofread--target-domains-for-kind-in-normalized-ranges
    (ranges kind policy minimum maximum)
  "Return target domains of KIND in normalized RANGES under POLICY.
MINIMUM and MAXIMUM are the snapshotted accessible buffer bounds."
  (let ((target-ranges
         (pcase kind
           ('text (and ranges (list (cons minimum maximum))))
           ('comment
            (proofread--comment-domains-in-normalized-ranges ranges))
           ('docstring
            (proofread--docstring-domains-in-normalized-ranges ranges))
           (_ (error "Unsupported proofread target kind: %S" kind))))
        domains)
    (dolist (range target-ranges)
      (when-let* ((domain
                   (proofread--make-target-domain
                    range kind policy minimum maximum)))
        (push domain domains)))
    (nreverse domains)))

(defun proofread--target-domains-for-kind
    (ranges kind policy minimum maximum)
  "Return target domains of KIND overlapping raw RANGES under POLICY.
MINIMUM and MAXIMUM are the accessible buffer bounds."
  (proofread--target-domains-for-kind-in-normalized-ranges
   (proofread--normalize-accessible-ranges ranges)
   kind policy minimum maximum))

(defun proofread--target-domains-in-normalized-ranges
    (ranges policy minimum maximum)
  "Return target domains discovered from normalized RANGES.
POLICY and accessible bounds MINIMUM and MAXIMUM belong to the same
selection snapshot as RANGES."
  (let (domains)
    (dolist (kind '( text comment docstring))
      (when (proofread--target-policy-includes-p policy kind)
        (setq domains
              (nconc domains
                     (proofread--target-domains-for-kind-in-normalized-ranges
                      ranges kind policy minimum maximum)))))
    (sort domains
          (lambda (left right)
            (< (plist-get left :domain-beg)
               (plist-get right :domain-beg))))))

(defun proofread--target-islands-in-normalized-ranges
    (ranges domains)
  "Return intersections of normalized RANGES and complete DOMAINS."
  (let (islands)
    (dolist (domain domains)
      (let ((domain-range
             (cons (plist-get domain :domain-beg)
                   (plist-get domain :domain-end))))
        (dolist (range ranges)
          (when-let* ((intersection
                       (proofread--range-intersection
                        range domain-range)))
            (push (append (list :beg (car intersection)
                                :end (cdr intersection))
                          domain)
                  islands)))))
    (sort islands
          (lambda (left right)
            (< (plist-get left :beg)
               (plist-get right :beg))))))

(defun proofread--selection-plan-for-ranges (ranges)
  "Return a target selection plan for raw RANGES.
Normalize and clip RANGES exactly once, snapshot the target policy and
accessible bounds, retain complete discovery domains, and derive
selected islands from those values."
  (let* ((minimum (point-min))
         (maximum (point-max))
         (ranges (proofread--normalize-accessible-ranges ranges))
         (policy (proofread--effective-target-policy))
         (domains
          (proofread--target-domains-in-normalized-ranges
           ranges policy minimum maximum)))
    (proofread--make-selection-plan
     ranges domains
     (proofread--target-islands-in-normalized-ranges
      ranges domains))))

(defun proofread--target-domains-for-ranges (ranges)
  "Return complete proofreading target domains overlapping RANGES."
  (proofread--selection-plan-domains
   (proofread--selection-plan-for-ranges ranges)))

(defun proofread--target-islands-for-ranges (ranges)
  "Return selected target islands for accessible RANGES.
Each island records its selected bounds and its complete target
domain."
  (proofread--selection-plan-islands
   (proofread--selection-plan-for-ranges ranges)))

(defun proofread--visible-window-ranges ()
  "Return raw visible ranges for windows showing this buffer."
  (let ((buffer (current-buffer))
        ranges)
    (dolist (window (get-buffer-window-list buffer nil t))
      (when (and (window-live-p window)
                 (eq (window-buffer window) buffer))
        (let ((beg (window-start window))
              (end (window-end window t)))
          (when end
            (push (cons beg end) ranges)))))
    ranges))

(defun proofread--visible-ranges ()
  "Return normalized visible ranges for the current buffer."
  (proofread--normalize-ranges (proofread--visible-window-ranges)))

;;;; Chunk construction

(defun proofread--range-nonblank-p (beg end)
  "Return non-nil if non-whitespace text is present from BEG to END."
  (save-excursion
    (goto-char beg)
    (re-search-forward "\\S-" end t)))

(defun proofread--range-has-alphanumeric-p (beg end)
  "Return non-nil if an alphanumeric is present from BEG to END."
  (save-excursion
    (goto-char beg)
    (re-search-forward "[[:alnum:]]" end t)))

(defun proofread--paragraph-spans-in-range (beg end)
  "Return nonblank paragraph spans between BEG and END.
Paragraphs are nonblank runs of lines separated by blank or structural
lines."
  (let ((beg (max (point-min) beg))
        (end (min (point-max) end))
        paragraph-beg
        paragraph-end
        spans)
    (when (< beg end)
      (save-excursion
        (goto-char beg)
        (while (< (point) end)
          (let ((line-beg (point))
                (line-end (min (line-end-position) end)))
            (if (proofread--context-stop-line-at-point-p)
                (progn
                  (when paragraph-beg
                    (push (cons paragraph-beg paragraph-end) spans)
                    (setq paragraph-beg nil)
                    (setq paragraph-end nil))
                  (when (proofread--range-nonblank-p
                         line-beg line-end)
                    (push (cons line-beg line-end) spans)))
              (if (proofread--range-nonblank-p line-beg line-end)
                  (progn
                    (unless paragraph-beg
                      (setq paragraph-beg line-beg))
                    (setq paragraph-end line-end))
                (when paragraph-beg
                  (push (cons paragraph-beg paragraph-end) spans)
                  (setq paragraph-beg nil)
                  (setq paragraph-end nil))))
            (forward-line 1)
            (when (> (point) end)
              (goto-char end))))
        (when paragraph-beg
          (push (cons paragraph-beg paragraph-end) spans))))
    (nreverse spans)))

(defun proofread--paragraph-spans-for-ranges (ranges)
  "Return nonblank paragraph spans for normalized RANGES."
  (let (spans)
    (dolist (range (proofread--normalize-ranges ranges))
      (dolist (span (proofread--paragraph-spans-in-range
                     (car range) (cdr range)))
        (push span spans)))
    (nreverse spans)))

(defun proofread--sentence-ending-character-p (character)
  "Return non-nil when CHARACTER is sentence-ending punctuation."
  (memq character
        '( ?。 ?！ ?？ ?! ?? ?. ?； ?\; ?…)))

(defun proofread--sentence-closing-character-p (character)
  "Return non-nil when CHARACTER closes a sentence after punctuation."
  (and character
       (string-search (char-to-string character)
                      proofread--sentence-closing-characters)))

(defun proofread--ascii-alnum-character-p (character)
  "Return non-nil when CHARACTER is an ASCII letter or digit."
  (and character
       (or (<= ?0 character ?9)
           (<= ?A character ?Z)
           (<= ?a character ?z))))

(defun proofread--period-between-ascii-alnum-p (position)
  "Return non-nil if POSITION's period is within a word-like token."
  (and (eq (char-after position) ?.)
       (proofread--ascii-alnum-character-p (char-before position))
       (proofread--ascii-alnum-character-p
        (char-after (1+ position)))))

(defun proofread--english-abbreviation-period-p (position)
  "Return non-nil if POSITION follows a common abbreviation."
  (and (eq (char-after position) ?.)
       (let ((case-fold-search t)
             (text (buffer-substring-no-properties
                    (line-beginning-position)
                    (1+ position))))
         (string-match-p
          (concat
           "\\(?:\\b\\(?:Mr\\|Mrs\\|Ms\\|Dr\\|Prof\\|Sr\\|Jr\\|"
           "St\\|vs\\|etc\\)\\|\\be\\.g\\|\\bi\\.e\\|\\ba\\.m\\|"
           "\\bp\\.m\\)\\.$")
          text))))

(defun proofread--comment-start-delimiter-position-p (position)
  "Return non-nil when POSITION is inside a comment start delimiter.
Recognize the delimiter from the current mode's `comment-start-skip'
and confirm it against the buffer's syntax state."
  (when (and (eq proofread--active-target-kind 'comment)
             comment-start-skip)
    (save-match-data
      (save-excursion
        (goto-char position)
        (let ((limit (line-end-position))
              found)
          (goto-char (line-beginning-position))
          (while (and (not found)
                      (re-search-forward comment-start-skip limit t)
                      (<= (match-beginning 0) position))
            (let ((delimiter-beg (match-beginning 0))
                  (delimiter-end (match-end 0)))
              (when (and (< position delimiter-end)
                         (let ((state (syntax-ppss delimiter-end)))
                           (and (nth 4 state)
                                (= (nth 8 state) delimiter-beg))))
                (setq found t))))
          found)))))

(defun proofread--sentence-boundary-at-point-p ()
  "Return non-nil when point is at an internal sentence boundary."
  (let ((character (char-after)))
    (and (proofread--sentence-ending-character-p character)
         (not (proofread--comment-start-delimiter-position-p (point)))
         (not (proofread--period-between-ascii-alnum-p (point)))
         (not (proofread--english-abbreviation-period-p (point))))))

(defun proofread--sentence-boundary-end (limit)
  "Return the boundary end at point without passing LIMIT."
  (save-excursion
    (while (and (< (point) limit)
                (proofread--sentence-ending-character-p (char-after)))
      (forward-char 1))
    (while (and (< (point) limit)
                (proofread--sentence-closing-character-p
                 (char-after)))
      (forward-char 1))
    (point)))

(defun proofread--sentence-spans-in-paragraph (span)
  "Return sentence spans inside paragraph SPAN.
The splitter is intentionally local and punctuation-based for Chinese
and English prose.  Single hard-wrap newlines are not sentence
boundaries unless the preceding text ends with sentence punctuation."
  (let ((beg (car span))
        (end (cdr span))
        spans)
    (save-mark-and-excursion
      (save-restriction
        (narrow-to-region beg end)
        (let ((span-beg beg))
          (goto-char beg)
          (while (< (point) end)
            (if (proofread--sentence-boundary-at-point-p)
                (let
                    ((span-end
                      (proofread--sentence-boundary-end end)))
                  (when (proofread--range-nonblank-p
                         span-beg span-end)
                    (push (cons span-beg span-end) spans))
                  (goto-char span-end)
                  (skip-chars-forward " \t\n\r" end)
                  (setq span-beg (point)))
              (forward-char 1)))
          (when (proofread--range-nonblank-p span-beg end)
            (push (cons span-beg end) spans)))))
    (nreverse spans)))

(defun proofread--sentence-spans-for-ranges (ranges)
  "Return sentence-aware spans for visible RANGES."
  (let (spans)
    (dolist (span (proofread--paragraph-spans-for-ranges ranges))
      (dolist
          (sentence-span
           (proofread--sentence-spans-in-paragraph span))
        (push sentence-span spans)))
    (nreverse spans)))

(defun proofread--split-span-by-chunk-size (span)
  "Split SPAN into ranges no larger than `proofread-max-chunk-size'."
  (let ((beg (car span))
        (end (cdr span))
        (size proofread-max-chunk-size)
        ranges)
    (unless (and (integerp size) (> size 0))
      (user-error "Proofread chunk size must be positive"))
    (while (< beg end)
      (let ((next (min end (+ beg size))))
        (when (< next end)
          (save-excursion
            (goto-char next)
            (when (re-search-backward "[[:space:][:punct:]]" beg t)
              (let ((boundary (match-end 0)))
                (when (> boundary beg)
                  (setq next boundary))))))
        (push (cons beg next) ranges)
        (setq beg next)))
    (nreverse ranges)))

(defun proofread--chunk-spans-for-ranges (ranges)
  "Return sentence-aware bounded chunk spans for visible RANGES."
  (let (spans)
    (dolist (span (proofread--sentence-spans-for-ranges ranges))
      (dolist (chunk-span (proofread--split-span-by-chunk-size span))
        (push chunk-span spans)))
    (nreverse spans)))

;;;; Filtering and context

(defun proofread--regexp-ranges-in-region (regexp beg end)
  "Return ranges matching REGEXP between BEG and END."
  (let (ranges)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward regexp end t)
        (push (cons (match-beginning 0) (match-end 0)) ranges)))
    (nreverse ranges)))

(defun proofread--face-ignored-p (face)
  "Return non-nil when FACE matches `proofread-ignored-faces'."
  (cond
   ((symbolp face)
    (memq face proofread-ignored-faces))
   ((consp face)
    (catch 'ignored
      (dolist (item face)
        (when (and (symbolp item)
                   (memq item proofread-ignored-faces))
          (throw 'ignored t)))))))

(defun proofread--property-ranges-in-region
    (property predicate beg end)
  "Return PROPERTY ranges matching PREDICATE between BEG and END."
  (let ((pos beg)
        ranges)
    (while (< pos end)
      (let* ((value (get-text-property pos property))
             (next (or (next-single-property-change
                        pos property nil end)
                       end)))
        (when (funcall predicate value)
          (push (cons pos next) ranges))
        (setq pos next)))
    (nreverse ranges)))

(defun proofread--ignored-face-ranges (beg end)
  "Return configured ignored face ranges between BEG and END."
  (when proofread-ignored-faces
    (proofread--property-ranges-in-region
     'face #'proofread--face-ignored-p beg end)))

(defun proofread--ignored-property-ranges (beg end)
  "Return ignored property ranges between BEG and END."
  (let (ranges)
    (dolist (property proofread-ignored-properties)
      (dolist (range (proofread--property-ranges-in-region
                      property #'identity beg end))
        (push range ranges)))
    (nreverse ranges)))

(defun proofread--invisible-ranges (beg end)
  "Return actually invisible text ranges between BEG and END."
  (let ((position beg)
        ranges)
    (while (< position end)
      (let ((next (next-char-property-change position end)))
        (when (invisible-p position)
          (push (cons position next) ranges))
        (setq position next)))
    (nreverse ranges)))

(defun proofread--ignored-ranges-in-region (beg end)
  "Return normalized ignored ranges between BEG and END."
  (proofread--normalize-ranges
   (append
    (proofread--regexp-ranges-in-region proofread--url-regexp beg end)
    (proofread--regexp-ranges-in-region
     proofread--email-regexp beg end)
    (proofread--ignored-face-ranges beg end)
    (proofread--ignored-property-ranges beg end)
    (proofread--invisible-ranges beg end))))

(defun proofread--retained-ranges (beg end ignored-ranges)
  "Subtract IGNORED-RANGES from the range BEG through END."
  (let ((pos beg)
        ranges)
    (dolist (ignored (proofread--normalize-ranges ignored-ranges))
      (let ((ignored-beg (max beg (car ignored)))
            (ignored-end (min end (cdr ignored))))
        (when (< ignored-beg ignored-end)
          (when (< pos ignored-beg)
            (push (cons pos ignored-beg) ranges))
          (setq pos (max pos ignored-end)))))
    (when (< pos end)
      (push (cons pos end) ranges))
    (nreverse ranges)))

(defun proofread--substring-excluding-ranges (beg end ignored-ranges)
  "Return text between BEG and END excluding IGNORED-RANGES."
  (mapconcat
   (lambda (range)
     (buffer-substring-no-properties (car range) (cdr range)))
   (proofread--retained-ranges beg end ignored-ranges)
   " "))

(defun proofread--bounded-request-ready-context-before (beg)
  "Return bounded filtered character context before BEG."
  (let* ((size (max 0 proofread-context-size))
         (context-beg (max (point-min) (- beg size)))
         (text (proofread--substring-excluding-ranges
                context-beg beg
                (proofread--ignored-ranges-in-region
                 context-beg beg))))
    (if (> (length text) size)
        (substring text (- (length text) size))
      text)))

(defun proofread--bounded-request-ready-context-after (end)
  "Return bounded filtered character context after END."
  (let* ((size (max 0 proofread-context-size))
         (context-end (min (point-max) (+ end size)))
         (text (proofread--substring-excluding-ranges
                end context-end
                (proofread--ignored-ranges-in-region
                 end context-end))))
    (if (> (length text) size)
        (substring text 0 size)
      text)))

(defun proofread--org-structural-line-p ()
  "Return non-nil when point is on an Org structural boundary.
Ordinary paragraph lines are not boundaries unless they are affiliated
keywords or belong to an Org block or drawer."
  (when (derived-mode-p 'org-mode)
    (require 'org-element)
    (save-match-data
      (let* ((element (org-element-at-point))
             (type (org-element-type element))
             (post-affiliated
              (org-element-property :post-affiliated element)))
        (or (not (memq type '( org-data paragraph section)))
            (and (eq type 'paragraph)
                 (integerp post-affiliated)
                 (< (line-beginning-position) post-affiliated))
            (org-element-lineage
             element
             '( center-block drawer dynamic-block footnote-definition
                property-drawer quote-block special-block)
             t))))))

(defun proofread--context-stop-line-at-point-p ()
  "Return non-nil when the current line stops context search."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (or (string-blank-p line)
        (proofread--org-structural-line-p))))

(defun proofread--context-search-beg (beg)
  "Return the nearest structural context boundary before BEG."
  (save-excursion
    (let ((boundary nil)
          (limit
           (max (point-min)
                (- beg (max 0 proofread-context-size)))))
      (goto-char (max (point-min) (min beg (point-max))))
      (beginning-of-line)
      (if (proofread--context-stop-line-at-point-p)
          (setq boundary (point))
        (while (and (not boundary) (> (point) limit))
          (forward-line -1)
          (when (proofread--context-stop-line-at-point-p)
            (setq boundary
                  (min (point-max)
                       (1+ (line-end-position)))))))
      (max limit (min beg (or boundary limit))))))

(defun proofread--context-search-end (end)
  "Return the nearest structural context boundary after END."
  (save-excursion
    (let ((boundary nil)
          (limit
           (min (point-max)
                (+ end (max 0 proofread-context-size)))))
      (goto-char (max (point-min) (min end (point-max))))
      (beginning-of-line)
      (if (proofread--context-stop-line-at-point-p)
          (setq boundary end)
        (while (and (not boundary) (< (line-end-position) limit))
          (forward-line 1)
          (when (proofread--context-stop-line-at-point-p)
            (setq boundary (line-beginning-position)))))
      (min limit (max end (or boundary limit))))))

(defun proofread--context-sentence-spans (beg end)
  "Return logical context sentence spans between BEG and END."
  (when (and (< beg end)
             (proofread--range-nonblank-p beg end))
    (let ((spans
           (proofread--sentence-spans-in-paragraph (cons beg end))))
      (if (memq proofread--active-target-kind '( comment docstring))
          (cl-remove-if-not
           (lambda (span)
             (proofread--range-has-alphanumeric-p
              (car span) (cdr span)))
           spans)
        spans))))

(defun proofread--context-selected-spans (spans direction count)
  "Return selected SPANS for DIRECTION using COUNT sentences."
  (if (eq direction 'before)
      (last spans count)
    (take count spans)))

(defun proofread--context-spans-text (spans)
  "Return filtered context text for SPANS."
  (when spans
    (let ((beg (caar spans))
          (end (cdar (last spans))))
      (proofread--substring-excluding-ranges
       beg end
       (proofread--ignored-ranges-in-region beg end)))))

(defun proofread--sentence-window-context
    (region-beg region-end direction count fallback)
  "Return sentence-window context in REGION-BEG to REGION-END.
DIRECTION is either `before' or `after'.  COUNT is the desired
sentence count.  FALLBACK is the bounded character-window context used
when sentence context is too large for `proofread-context-size'."
  (let ((count (max 0 count))
        (size (max 0 proofread-context-size)))
    (cond
     ((zerop count) "")
     ((zerop size) "")
     (t
      (let ((spans
             (proofread--context-sentence-spans
              region-beg region-end)))
        (cond
         ((null spans) "")
         (t
          (let ((sentence-count (min count (length spans)))
                text)
            (catch 'context
              (while (> sentence-count 0)
                (setq text
                      (proofread--context-spans-text
                       (proofread--context-selected-spans
                        spans direction sentence-count)))
                (if (<= (length text) size)
                    (throw 'context text)
                  (if (= sentence-count 1)
                      (throw 'context fallback)
                    (setq sentence-count (1- sentence-count)))))
              "")))))))))

(defun proofread--request-ready-context-before (beg)
  "Return sentence-window context before BEG without text properties."
  (proofread--sentence-window-context
   (proofread--context-search-beg beg)
   beg
   'before
   proofread-context-sentences-before
   (proofread--bounded-request-ready-context-before beg)))

(defun proofread--request-ready-context-after (end)
  "Return sentence-window context after END without text properties."
  (proofread--sentence-window-context
   end
   (proofread--context-search-end end)
   'after
   proofread-context-sentences-after
   (proofread--bounded-request-ready-context-after end)))

(defun proofread--make-request-ready-chunk (beg end &optional language)
  "Return a request chunk for text between BEG and END.
LANGUAGE is the language hint snapshotted for the check."
  (let ((text (buffer-substring-no-properties beg end)))
    (list :beg beg
          :end end
          :text text
          :major-mode major-mode
          :language language
          :context-before
          (proofread--request-ready-context-before beg)
          :context-after
          (proofread--request-ready-context-after end))))

(defun proofread--retained-request-spans (spans)
  "Return nonblank portions of SPANS after ignored text is removed."
  (let (request-spans)
    (dolist (span spans)
      (let ((beg (car span))
            (end (cdr span)))
        (dolist (range
                 (proofread--retained-ranges
                  beg end
                  (proofread--ignored-ranges-in-region beg end)))
          (when (proofread--range-nonblank-p (car range) (cdr range))
            (push range request-spans)))))
    (nreverse request-spans)))

(defun proofread--chunk-with-target-metadata (chunk island)
  "Return CHUNK annotated with target metadata from ISLAND."
  (append chunk
          (list :target-policy (plist-get island :target-policy)
                :target-kind (plist-get island :kind)
                :domain-beg (plist-get island :domain-beg)
                :domain-end (plist-get island :domain-end))))

(defun proofread--request-span-has-target-prose-p (span island)
  "Return non-nil when SPAN has useful prose for target ISLAND."
  (or (eq (plist-get island :kind) 'text)
      (proofread--range-has-alphanumeric-p
       (car span) (cdr span))))

(defun proofread--request-spans-for-islands (islands)
  "Return filtered request span records for target ISLANDS."
  (let ((accessible-beg (and (buffer-narrowed-p) (point-min)))
        (accessible-end (and (buffer-narrowed-p) (point-max)))
        request-spans)
    (save-mark-and-excursion
      (dolist (island islands)
        (let
            ((proofread--active-target-kind
              (plist-get island :kind)))
          (save-restriction
            (narrow-to-region (plist-get island :domain-beg)
                              (plist-get island :domain-end))
            (dolist
                (span
                 (proofread--retained-request-spans
                  (proofread--chunk-spans-for-ranges
                   (list (cons (plist-get island :beg)
                               (plist-get island :end))))))
              (when (proofread--request-span-has-target-prose-p
                     span island)
                (let ((request-span (copy-sequence island)))
                  (setq request-span
                        (plist-put request-span :beg (car span)))
                  (setq request-span
                        (plist-put request-span :end (cdr span)))
                  (setq request-span
                        (plist-put request-span
                                   :accessible-beg accessible-beg))
                  (setq request-span
                        (plist-put request-span
                                   :accessible-end accessible-end))
                  (push request-span request-spans))))))))
    (nreverse request-spans)))

(defun proofread--request-ready-chunks-for-request-spans
    (request-spans &optional language)
  "Materialize REQUEST-SPANS using snapshotted LANGUAGE."
  (let (request-chunks)
    (save-mark-and-excursion
      (dolist (span request-spans)
        (let
            ((proofread--active-target-kind
              (plist-get span :kind)))
          (save-restriction
            (narrow-to-region (plist-get span :domain-beg)
                              (plist-get span :domain-end))
            (let ((chunk
                   (proofread--make-request-ready-chunk
                    (plist-get span :beg)
                    (plist-get span :end)
                    language)))
              (setq chunk
                    (proofread--chunk-with-target-metadata
                     chunk span))
              (setq chunk
                    (plist-put
                     chunk :accessible-beg
                     (plist-get span :accessible-beg)))
              (setq chunk
                    (plist-put
                     chunk :accessible-end
                     (plist-get span :accessible-end)))
              (push chunk request-chunks))))))
    (nreverse request-chunks)))

(defun proofread--request-ready-chunks-for-islands
    (islands &optional language)
  "Return request-ready chunks for target ISLANDS.
LANGUAGE is the language hint snapshotted for the check."
  (proofread--request-ready-chunks-for-request-spans
   (proofread--request-spans-for-islands islands) language))

;;;; Backend requests

(defun proofread--next-request-id ()
  "Return a fresh backend request id for the current buffer."
  (setq proofread--next-request-id (1+ proofread--next-request-id)))

(defun proofread--request-checker-preparation (checker)
  "Return a complete adapter preparation for CHECKER.
Query CHECKER's backend descriptor once.  Unknown backends retain the
core checker envelope but have no backend identity or source label."
  (when checker
    (let ((descriptor
           (proofread--backend-descriptor
            (plist-get checker :backend))))
      (if descriptor
          (proofread--prepare-checker checker descriptor)
        (proofread--make-checker-preparation
         nil checker nil
         (proofread--checker-identity-from-snapshots
          checker nil nil)
         nil)))))

(defun proofread--make-backend-request
    (chunk &optional backend checker profile preparation)
  "Return a backend request plist for request-ready CHUNK.
When BACKEND is non-nil, store its canonical identity in the request.
CHECKER and PROFILE, when non-nil, identify the profile checker that
owns the request.  Without CHECKER, create an ad-hoc low-level owner
that is independent of profile selection.  PREPARATION, when non-nil,
contains the checker and metadata snapshots to share across requests."
  (let* ((checker (or checker (proofread--ad-hoc-checker backend)))
         (backend-name (or (plist-get checker :backend)
                           backend))
         (preparation
          (or preparation
              (proofread--request-checker-preparation checker)))
         (checker
          (if preparation
              (proofread--checker-preparation-checker preparation)
            checker))
         (backend-identity
          (if preparation
              (proofread--checker-preparation-backend-identity
               preparation)
            (proofread--backend-identity backend-name)))
         (checker-owner (and checker
                             (proofread--checker-owner checker)))
         (checker-identity
          (and preparation
               (proofread--checker-preparation-checker-identity
                preparation)))
         (source-label
          (and preparation
               (proofread--checker-preparation-source-label
                preparation)))
         (profile-language
          (if profile
              (plist-get profile :language)
            (plist-get chunk :language)))
         (profile-display-language
          (if profile
              (plist-get profile :display-language)
            (plist-get chunk :display-language)))
         (request
          (mapcan
           (lambda (key)
             (list key
                   (pcase key
                     ( :id (proofread--next-request-id))
                     ( :generation proofread--generation)
                     ( :buffer (current-buffer))
                     ( :backend
                       (proofread--snapshot-value backend-name))
                     ( :backend-identity backend-identity)
                     ( :profile
                       (proofread--snapshot-value
                        (plist-get checker :profile)))
                     ( :checker-name
                       (proofread--snapshot-value
                        (plist-get checker :name)))
                     ( :checker-ordinal
                       (proofread--snapshot-value
                        (plist-get checker :checker-ordinal)))
                     ( :checker-owner checker-owner)
                     ( :checker-options
                       (plist-get checker :options))
                     ( :checker-identity checker-identity)
                     ( :source-label source-label)
                     ( :language
                       (proofread--snapshot-value
                        profile-language))
                     ( :display-language
                       (proofread--snapshot-value
                        profile-display-language))
                     (_ (proofread--snapshot-value
                         (plist-get chunk key))))))
           proofread--backend-request-keys)))
    request))

(defun proofread--make-request-work (request)
  "Return fresh scheduled work owning backend REQUEST."
  (let ((work
         (proofread--make-scheduled-work
          request
          (proofread--cache-key request)
          (cl-incf proofread--request-log-sequence))))
    (puthash request
             (proofread--scheduled-work-log-id work)
             proofread--request-log-owner-ids)
    work))

(defun proofread--backend-success-result (request diagnostics)
  "Return a successful backend result for REQUEST and DIAGNOSTICS."
  (list :status 'ok
        :request request
        :diagnostics diagnostics))

(defun proofread--backend-partial-success-result (request diagnostics)
  "Return a partial backend success for REQUEST and DIAGNOSTICS."
  (plist-put
   (proofread--backend-success-result request diagnostics)
   :partial t))

(defun proofread--backend-error-result
    (request error &optional message)
  "Return an error backend result for REQUEST and ERROR.
When MESSAGE is non-nil, include it as caller-readable error text."
  (let ((result (list :status 'error
                      :request request
                      :error error)))
    (if message
        (append result (list :message message))
      result)))

(defun proofread--scheduled-work-for-request (request)
  "Return scheduled work owning backend REQUEST, or nil."
  (when-let* ((buffer (plist-get request :buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (or (cl-find request proofread--active-requests
                   :key #'proofread--scheduled-work-request
                   :test #'eq)
          (cl-find request proofread--claimed-requests
                   :key #'proofread--scheduled-work-request
                   :test #'eq)
          (cl-find request (proofread--request-queue-entries)
                   :key (lambda (entry)
                          (proofread--scheduled-work-request
                           (proofread--queue-entry-work entry)))
                   :test #'eq)))))

(defun proofread--active-request-p (work)
  "Return non-nil if WORK is active in the current buffer."
  (memq work proofread--active-requests))

(defun proofread--active-request-limit ()
  "Return the current buffer's backend request concurrency limit."
  (max 0 proofread-max-concurrent-requests))

(defun proofread--active-request-slots ()
  "Return the number of currently available backend request slots."
  (max 0 (- (proofread--active-request-limit)
            (length proofread--active-requests))))

(defun proofread--request-slot-available-p ()
  "Return non-nil when another backend request may be sent."
  (> (proofread--active-request-slots) 0))

(defun proofread--register-active-request (work)
  "Register WORK as active in the current buffer."
  (setq proofread--claimed-requests
        (delq work proofread--claimed-requests))
  (push work proofread--active-requests)
  (puthash (proofread--request-work-key work)
           work
           proofread--pending-request-keys)
  work)

(defun proofread--record-active-request-handle (work request-handle)
  "Record REQUEST-HANDLE on active WORK without replacing it."
  (when (memq work proofread--active-requests)
    (setf (proofread--scheduled-work-handle work) request-handle))
  request-handle)

(defun proofread--remove-active-request (work)
  "Remove WORK from active request state in the current buffer."
  (setq proofread--active-requests
        (delq work proofread--active-requests))
  (proofread--forget-request-work work))

(defun proofread--defer-backend-callback (callback result)
  "Invoke CALLBACK with RESULT after the current call stack unwinds."
  (run-at-time 0 nil callback result))

(defun proofread--supported-backend-p (&optional backend)
  "Return non-nil if non-nil BACKEND is a supported backend."
  (and backend
       (proofread--backend-descriptor backend)
       t))

(defun proofread--request-relative-range-valid-p (request beg end)
  "Return non-nil if relative BEG and END are valid for REQUEST."
  (let ((text (plist-get request :text))
        (range (cons beg end)))
    (and (stringp text)
         (proofread--range-valid-p range)
         (proofread--range-contains-p
          (cons 0 (length text)) range))))

(defun proofread--syntax-state-in-container-p
    (state container-beg kind)
  "Return non-nil if STATE is inside KIND at CONTAINER-BEG."
  (and (equal (nth 8 state) container-beg)
       (pcase kind
         ('comment (nth 4 state))
         ('docstring (nth 3 state)))))

(defun proofread--syntax-container-range (state kind)
  "Return STATE's complete or open syntax container for KIND."
  (when-let* ((beg (nth 8 state)))
    (let ((end
           (condition-case nil
               (pcase kind
                 ('comment
                  (save-excursion
                    (goto-char beg)
                    (with-syntax-table
                        (or syntax-ppss-table (syntax-table))
                      (and (forward-comment 1) (point)))))
                 ('docstring (scan-sexps beg 1)))
             (error nil))))
      (unless end
        (let ((end-state (syntax-ppss (point-max))))
          (when (proofread--syntax-state-in-container-p
                 end-state beg kind)
            (setq end (point-max)))))
      (and end (< beg end) (cons beg end)))))

(defun proofread--syntax-container-interior (range kind)
  "Return container RANGE's delimiter-free interior for KIND."
  (let* ((container-beg (car range))
         (container-end (cdr range))
         (beg container-beg)
         end
         delimiter-beg)
    (when (and (eq kind 'comment)
               comment-start-skip)
      (save-excursion
        (goto-char container-beg)
        (when (looking-at comment-start-skip)
          (setq beg (min container-end (match-end 0))))))
    (while (and (< beg container-end)
                (not (proofread--syntax-state-in-container-p
                      (syntax-ppss beg) container-beg kind)))
      (setq beg (1+ beg)))
    (if (proofread--syntax-state-in-container-p
         (syntax-ppss container-end) container-beg kind)
        (setq end container-end)
      (setq end container-end)
      (while (and (> end beg)
                  (not (proofread--syntax-state-in-container-p
                        (syntax-ppss end) container-beg kind)))
        (setq end (1- end)))
      (when (eq kind 'comment)
        (while (and (> end beg) (nth 10 (syntax-ppss end)))
          (setq end (1- end)))))
    ;; Syntax state element 10 identifies two-character delimiters,
    ;; but modes such as HTML use longer syntax-propertized comment
    ;; endings.  The mode's own anchored end regexp is authoritative
    ;; for those suffixes.
    (when (and (eq kind 'comment) comment-end-skip)
      (save-excursion
        (goto-char container-end)
        (when (and (re-search-backward comment-end-skip beg t)
                   (= (match-end 0) container-end))
          (setq delimiter-beg (match-beginning 0)))))
    (when delimiter-beg
      (setq end (min end delimiter-beg)))
    (and (<= beg end) (cons beg end))))

(defun proofread--range-touches-syntax-escape-p (beg end)
  "Return non-nil when BEG to END touches a quoted source character."
  (let ((position beg)
        found)
    (while (and (not found) (< position end))
      (setq found
            (or (nth 5 (syntax-ppss position))
                (and (< position (point-max))
                     (nth 5 (syntax-ppss (1+ position))))))
      (setq position (1+ position)))
    (when (= beg end)
      (setq found
            (or (nth 5 (syntax-ppss beg))
                (and (< beg (point-max))
                     (nth 5 (syntax-ppss (1+ beg)))))))
    found))

(defun proofread--request-relative-range-in-target-p (request range)
  "Return non-nil when RANGE stays inside REQUEST's prose target.
RANGE contains request-relative positions.  For comments and
docstrings, reject source delimiters and ranges crossing distinct
syntactic containers."
  (let ((kind (plist-get request :target-kind)))
    (if (not (memq kind '( comment docstring)))
        t
      (let ((buffer (plist-get request :buffer))
            (request-beg
             (proofread--position-integer (plist-get request :beg)))
            (relative-beg (car-safe range))
            (relative-end (cdr-safe range)))
        (and (buffer-live-p buffer)
             request-beg
             (integerp relative-beg)
             (integerp relative-end)
             (with-current-buffer buffer
               (save-mark-and-excursion
                 (save-restriction
                   (widen)
                   (let* ((beg (+ request-beg relative-beg))
                          (end (+ request-beg relative-end))
                          (beg-state (and (<= (point-min) beg)
                                          (<= beg (point-max))
                                          (syntax-ppss beg)))
                          (end-state (and (<= (point-min) end)
                                          (<= end (point-max))
                                          (syntax-ppss end)))
                          (container
                           (and beg-state
                                (proofread--syntax-container-range
                                 beg-state kind)))
                          (interior
                           (and container
                                (proofread--syntax-container-interior
                                 container kind))))
                     (and beg-state
                          end-state
                          interior
                          (equal (nth 8 beg-state) (nth 8 end-state))
                          (proofread--range-contains-p
                           interior (cons beg end))
                          (not
                           (proofread--range-touches-syntax-escape-p
                            beg end))
                          (pcase kind
                            ('comment
                             (and (nth 4 beg-state)
                                  (nth 4 end-state)))
                            ('docstring
                             (and (nth 3 beg-state)
                                  (nth 3 end-state))))))))))))))

(defun proofread--diagnostic-from-request-relative-range
    (request range properties)
  "Return a validated diagnostic for REQUEST, RANGE, and PROPERTIES.
RANGE is a cons cell of request-relative positions.  PROPERTIES must
contain the normalized `:kind', `:message', `:suggestions', and
`:source' fields.  Derive the diagnostic text and absolute positions
from REQUEST.  Return nil when RANGE does not stay inside REQUEST's
prose target, and signal an error when REQUEST or RANGE has invalid
bounds."
  (let* ((request-beg
          (proofread--position-integer (plist-get request :beg)))
         (request-text (plist-get request :text))
         (relative-beg (car-safe range))
         (relative-end (cdr-safe range)))
    (unless (and request-beg
                 (proofread--request-relative-range-valid-p
                  request relative-beg relative-end))
      (error "Diagnostic range is outside the request text"))
    (when (proofread--request-relative-range-in-target-p
           request range)
      (proofread--make-diagnostic
       :beg (+ request-beg relative-beg)
       :end (+ request-beg relative-end)
       :text (substring request-text relative-beg relative-end)
       :kind (plist-get properties :kind)
       :message (plist-get properties :message)
       :suggestions (plist-get properties :suggestions)
       :source (plist-get properties :source)
       :target-kind (plist-get request :target-kind)))))

(defun proofread--same-diagnostic-p (left right)
  "Return non-nil when LEFT and RIGHT describe the same diagnostic."
  (and (equal (plist-get left :beg) (plist-get right :beg))
       (equal (plist-get left :end) (plist-get right :end))
       (equal (plist-get left :text) (plist-get right :text))
       (equal (plist-get left :kind) (plist-get right :kind))
       (equal (plist-get left :message) (plist-get right :message))
       (equal (plist-get left :checker-owner)
              (plist-get right :checker-owner))))

(defun proofread--diagnostic-member-p (diagnostic diagnostics)
  "Return non-nil when DIAGNOSTIC is already in DIAGNOSTICS."
  (cl-some
   (lambda (candidate)
     (proofread--same-diagnostic-p diagnostic candidate))
   diagnostics))

(defun proofread--new-diagnostics (diagnostics existing)
  "Return unique DIAGNOSTICS that are not represented in EXISTING.
Preserve the first occurrence of each diagnostic and its input order."
  (let (new)
    (dolist (diagnostic diagnostics)
      (unless (or (proofread--diagnostic-member-p diagnostic existing)
                  (proofread--diagnostic-member-p diagnostic new))
        (push diagnostic new)))
    (nreverse new)))

(defun proofread--append-new-diagnostics (diagnostics new-diagnostics)
  "Return DIAGNOSTICS followed by non-duplicate NEW-DIAGNOSTICS."
  (append diagnostics
          (proofread--new-diagnostics new-diagnostics diagnostics)))

(defun proofread--unsupported-backend-check (backend request callback)
  "Report unsupported BACKEND for REQUEST through CALLBACK.
The report is delivered asynchronously."
  (proofread--defer-backend-callback
   callback
   (proofread--backend-error-result
    request
    'unsupported-backend
    (format "Unsupported proofread backend: %S" backend))))

(defun proofread--backend-submission-error-result
    (request error detail)
  "Return a checker-aware submission error for REQUEST.
ERROR identifies the failure and DETAIL describes it."
  (let ((result
         (proofread--backend-error-result
          request error
          (format
           (concat "Proofread profile %S checker %S using backend %S "
                   "failed during submission: %s")
           (plist-get request :profile)
           (plist-get request :checker-name)
           (plist-get request :backend)
           detail))))
    (plist-put result :phase 'submission)))

(defun proofread--dispatch-backend-request (work callback)
  "Register and submit WORK, then invoke CALLBACK."
  (let* ((request (proofread--scheduled-work-request work))
         (backend (proofread--scheduled-work-backend work))
         (buffer (plist-get request :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (proofread--register-active-request work))
      (proofread--record-request-event
       work 'active-request
       :backend backend)
      (if (not (proofread--request-ready-to-submit-p work))
          (progn
            (proofread--retire-active-request work)
            proofread--stale-dispatch-result)
        (let* ((settlement-state 'pending)
               (settle
                (lambda (result)
                  (when (eq settlement-state 'pending)
                    (setq settlement-state 'running)
                    (unwind-protect
                        (prog1
                            (progn
                              (when (buffer-live-p buffer)
                                (with-current-buffer buffer
                                  (proofread--remove-active-request
                                   work)))
                              (unwind-protect
                                  (when callback
                                    (funcall callback result))
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (when proofread-mode
                                      (proofread--dispatch-queued-requests))))))
                          (setq settlement-state 'completed))
                      (when (eq settlement-state 'running)
                        (setq settlement-state 'failed))))))
               (submission
                (condition-case err
                    (let* (;; Capture one descriptor snapshot before
                           ;; submission.  Later registry changes must
                           ;; not redirect cleanup for its handle.
                           (descriptor
                            (proofread--backend-descriptor backend))
                           (check (plist-get descriptor :check))
                           (cancel
                            (if descriptor
                                (plist-get descriptor :cancel)
                              ;; This fallback timer is core-owned.
                              #'cancel-timer))
                           (handle
                            (if check
                                (funcall check request settle)
                              (proofread--unsupported-backend-check
                               backend request settle))))
                      (list :handle handle :cancel cancel))
                  (error
                   (pcase settlement-state
                     ('pending
                      (funcall
                       settle
                       (proofread--backend-submission-error-result
                        request err (error-message-string err)))
                      nil)
                     ('completed
                      ;; The request already settled at most once.  A
                      ;; backend error after a synchronous callback
                      ;; must not abort later profile checkers.
                      nil)
                     (_
                      ;; Do not misclassify an error from the core
                      ;; callback/result path as a backend failure.
                      (signal (car err) (cdr err)))))))
               (handle (plist-get submission :handle))
               (cancel (plist-get submission :cancel))
               (request-handle
                (and handle
                     (proofread--make-request-handle
                      handle cancel))))
          (when (and (null handle) (eq settlement-state 'pending))
            (funcall
             settle
             (proofread--backend-submission-error-result
              request 'backend-returned-no-handle
              "backend returned no handle without delivering a result")))
          (let* ((active
                  (and (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (proofread--active-request-p work))))
                 (stale
                  (or (not (buffer-live-p buffer))
                      (and active
                           (not
                            (proofread--request-ready-to-submit-p
                             work)))
                      (and (not active)
                           (proofread--request-state-flag-p
                            work :cancelled)))))
            (cond
             (stale
              (proofread--retire-active-request
               work request-handle)
              proofread--stale-dispatch-result)
             (t
              (when handle
                (when active
                  (with-current-buffer buffer
                    (proofread--record-active-request-handle
                     work request-handle)))
                (proofread--record-request-event
                 work 'backend-dispatched
                 :backend backend
                 :handle handle))
              handle))))))))

;;;; Request scheduling

(defun proofread--request-lifecycle-current-p (work)
  "Return non-nil when WORK may still change lifecycle state."
  (let* ((request (proofread--scheduled-work-request work))
         (buffer (plist-get request :buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (and proofread-mode
                (equal proofread--generation
                       (plist-get request :generation))
                (proofread--latest-request-p work)
                (not (proofread--request-state-flag-p
                      work :cancelled))
                (not (proofread--request-invalidated-p work)))))))

(defun proofread--request-ready-to-submit-p (work)
  "Return non-nil if WORK is fresh and lifecycle-current."
  (and (proofread--request-lifecycle-current-p work)
       (condition-case nil
           (proofread--fresh-request-p work)
         (error nil))
       ;; Freshness can invoke user predicates that mutate request
       ;; state.
       (proofread--request-lifecycle-current-p work)))

(defun proofread--retire-active-request
    (work &optional request-handle reason)
  "Remove active WORK and cancel optional core REQUEST-HANDLE.
Record REASON as the cancellation reason, defaulting to `stale'."
  (let* ((request (proofread--scheduled-work-request work))
         (buffer (plist-get request :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (proofread--invalidate-request work)
        (proofread--remove-active-request work)))
    (let ((proofread--inhibit-queue-dispatch buffer))
      (proofread--record-request-cancellation
       work (or reason 'stale))
      (proofread--cancel-request-handle request-handle))))

(defun proofread--prune-stale-active-requests ()
  "Cancel active requests that no longer match this buffer."
  (let ((candidates proofread--active-requests)
        stale)
    (dolist (work candidates)
      (unless (proofread--request-ready-to-submit-p work)
        (push work stale)))
    ;; Freshness predicates can reenter request dispatch.  Remove only
    ;; candidates that are still active after all predicates return.
    (setq stale
          (cl-delete-if-not
           (lambda (work)
             (memq work proofread--active-requests))
           stale))
    (when stale
      (let ((table (make-hash-table :test #'eq)))
        (dolist (work stale)
          (puthash work t table)
          (proofread--invalidate-request work))
        (setq proofread--active-requests
              (cl-delete-if (lambda (work) (gethash work table))
                            proofread--active-requests)))
      (let ((proofread--inhibit-queue-dispatch (current-buffer)))
        (dolist (work stale)
          (proofread--record-request-cancellation work 'stale)
          (proofread--cancel-request-handle
           (proofread--scheduled-work-handle work)))))
    (nreverse stale)))

(defun proofread--request-cache-status (work)
  "Apply WORK's current cache entry and return its queue status.
Return `cached' when an entry settles WORK, and nil when there is no
applicable entry.  A stale cache result has already recorded its final
event, so it is also terminally `cached' from the queue's perspective."
  (when-let* ((entry (proofread--cache-read-request work)))
    (when (proofread--apply-cache-entry work entry)
      'cached)))

(defun proofread--submit-request (work)
  "Submit WORK when cache and concurrency permit.
Return one of the symbols `sent', `cached', `full', `stale', or
`error'."
  (catch 'status
    (unless (proofread--request-ready-to-submit-p work)
      (throw 'status 'stale))
    (when-let* ((status (proofread--request-cache-status work)))
      (throw 'status status))
    ;; Cache lifecycle hooks can enqueue a newer conflicting request.
    (unless (proofread--request-lifecycle-current-p work)
      (throw 'status 'stale))
    (unless (proofread--request-slot-available-p)
      (if proofread--queue-dispatch-transaction
          (unless proofread--queue-dispatch-pruned-active-p
            (setq proofread--queue-dispatch-pruned-active-p t)
            (proofread--prune-stale-active-requests))
        (proofread--prune-stale-active-requests))
      (unless (proofread--request-lifecycle-current-p work)
        (throw 'status 'stale))
      ;; Pruning can run freshness, cancellation, and logging hooks while
      ;; this request is claimed and therefore absent from the queue index.
      ;; Consume a same-key cache write from those hooks before either
      ;; submitting the backend request or restoring the queue entry.
      (when-let* ((status (proofread--request-cache-status work)))
        (throw 'status status))
      (unless (proofread--request-lifecycle-current-p work)
        (throw 'status 'stale))
      (unless (proofread--request-slot-available-p)
        (throw 'status 'full)))
    (let ((result
           (proofread--dispatch-backend-request
            work
            (lambda (backend-result)
              (proofread--handle-backend-result
               work backend-result)))))
      (cond
       ((eq result proofread--stale-dispatch-result) 'stale)
       (result 'sent)
       (t 'error)))))

(defun proofread--request-queue-entries (&optional state)
  "Return queued entries in FIFO order from STATE.
STATE defaults to the current buffer's queue state.  The returned list
is a snapshot; queue links remain owned by the state record."
  (let ((entry (when-let* ((queue (or state proofread--queue-state)))
                 (proofread--queue-state-head queue)))
        entries)
    (while entry
      (push entry entries)
      (setq entry (proofread--queue-entry-next entry)))
    (nreverse entries)))

(defun proofread--request-queue-head ()
  "Return the first queued entry in the current buffer, or nil."
  (and proofread--queue-state
       (proofread--queue-state-head proofread--queue-state)))

(defun proofread--request-queue-empty-p ()
  "Return non-nil when the current buffer has no queued requests."
  (null (proofread--request-queue-head)))

(defun proofread--request-queue-length ()
  "Return the number of queued requests in the current buffer."
  (length (proofread--request-queue-entries)))

(defun proofread--request-queue-works ()
  "Return queued scheduled work in FIFO order."
  (mapcar #'proofread--queue-entry-work
          (proofread--request-queue-entries)))

(defun proofread--request-queue-entry-cache-key (entry)
  "Return the frozen cache key for queued request ENTRY."
  (proofread--scheduled-work-cache-key
   (proofread--queue-entry-work entry)))

(defun proofread--index-request-queue-entry
    (state entry &optional suppress-cache-wakeup)
  "Add ENTRY to STATE's cache indexes.
When SUPPRESS-CACHE-WAKEUP is non-nil, do not wake ENTRY for a cache
value which the current claim already considered."
  (let* ((key (proofread--request-queue-entry-cache-key entry))
         (index (proofread--queue-state-index state))
         (bucket (gethash key index)))
    (unless bucket
      (setq bucket (make-hash-table :test #'eq))
      (puthash key bucket index))
    (puthash entry t bucket)
    (when (and (not suppress-cache-wakeup)
               (proofread--cache-key-present-p key))
      (puthash entry t (proofread--queue-state-woken state)))))

(defun proofread--unindex-request-queue-entry (state entry)
  "Remove ENTRY from STATE's cache indexes."
  (let* ((key (proofread--request-queue-entry-cache-key entry))
         (index (proofread--queue-state-index state))
         (bucket (gethash key index)))
    (when bucket
      (remhash entry bucket)
      (when (= (hash-table-count bucket) 0)
        (remhash key index))))
  (remhash entry (proofread--queue-state-woken state)))

(defun proofread--link-request-queue-entry
    (state entry previous next &optional suppress-cache-wakeup)
  "Link ENTRY into STATE between PREVIOUS and NEXT.
When SUPPRESS-CACHE-WAKEUP is non-nil, do not wake ENTRY for the cache
value which the current claim already considered."
  (when (proofread--queue-entry-owner entry)
    (error "Queue entry is already linked"))
  (unless (and (eq (if previous
                       (proofread--queue-entry-next previous)
                     (proofread--queue-state-head state))
                   next)
               (eq (if next
                       (proofread--queue-entry-previous next)
                     (proofread--queue-state-tail state))
                   previous)
               (or (null previous)
                   (eq (proofread--queue-entry-owner previous)
                       state))
               (or (null next)
                   (eq (proofread--queue-entry-owner next) state)))
    (error "Queue insertion point is inconsistent"))
  (setf (proofread--queue-entry-previous entry) previous)
  (setf (proofread--queue-entry-next entry) next)
  (setf (proofread--queue-entry-owner entry) state)
  (if previous
      (setf (proofread--queue-entry-next previous) entry)
    (setf (proofread--queue-state-head state) entry))
  (if next
      (setf (proofread--queue-entry-previous next) entry)
    (setf (proofread--queue-state-tail state) entry))
  (proofread--index-request-queue-entry
   state entry suppress-cache-wakeup)
  entry)

(defun proofread--clear-request-queue (state)
  "Detach and return every queued entry in STATE."
  (let ((entry (proofread--queue-state-head state))
        entries)
    (setf (proofread--queue-state-head state) nil)
    (setf (proofread--queue-state-tail state) nil)
    (clrhash (proofread--queue-state-index state))
    (clrhash (proofread--queue-state-woken state))
    (while entry
      (let ((next (proofread--queue-entry-next entry)))
        (push entry entries)
        (setf (proofread--queue-entry-previous entry) nil)
        (setf (proofread--queue-entry-next entry) nil)
        (setf (proofread--queue-entry-owner entry) nil)
        (setq entry next)))
    (nreverse entries)))

(defun proofread--new-request-queue-entry (state work)
  "Return a fresh queue entry for WORK in STATE."
  (proofread--make-queue-entry
   work
   (cl-incf (proofread--queue-state-next-sequence state))))

(defun proofread--append-request-queue-entry
    (state entry &optional suppress-cache-wakeup)
  "Append ENTRY to STATE in constant time.
When SUPPRESS-CACHE-WAKEUP is non-nil, forward it to the cache index."
  (proofread--link-request-queue-entry
   state entry (proofread--queue-state-tail state) nil
   suppress-cache-wakeup))

(defun proofread--enqueue-requests (works)
  "Append WORKS without running lifecycle hooks."
  (when (and works (not (proofread--clearing-scheduled-work-p)))
    (let ((state proofread--queue-state))
      (unless (proofread--queue-state-p state)
        (error "Proofread request queue is not initialized"))
      (dolist (work works)
        (proofread--append-request-queue-entry
         state
         (proofread--new-request-queue-entry state work))
        (puthash (proofread--request-work-key work)
                 work
                 proofread--pending-request-keys)))
    (when proofread--queue-dispatch-active-p
      (setq proofread--queue-dispatch-requested-p t))
    works))

(defun proofread--reject-request-during-clear (work)
  "Retire WORK while this buffer clears scheduled work."
  (proofread--invalidate-request work)
  (unless (proofread--request-state-flag-p work :cancelled)
    (proofread--set-request-state-flag work :cancelled)
    ;; Prevent an adversarial cancellation hook from recursively
    ;; generating an unbounded chain of cancellation events.  Nested
    ;; work is still marked terminal, but only the outer rejection is
    ;; reported.
    (if proofread--recording-clear-rejection-p
        (proofread--settle-request-batch work)
      (let ((proofread--recording-clear-rejection-p t))
        (proofread--record-request-event
         work 'cancelled :reason 'cleared))))
  nil)

(defun proofread--request-work-key (work)
  "Return the identity of scheduled WORK."
  (let ((request (proofread--scheduled-work-request work)))
    (list (plist-get request :generation)
          (plist-get request :checker-owner)
          (proofread--position-integer (plist-get request :beg))
          (proofread--position-integer (plist-get request :end))
          (plist-get request :accessible-beg)
          (plist-get request :accessible-end)
          (proofread--scheduled-work-cache-key work)
          (plist-get request :source-label))))

(defun proofread--forget-request-work (work)
  "Remove WORK's key from pending state."
  (when (hash-table-p proofread--pending-request-keys)
    (let ((key (proofread--request-work-key work)))
      (when (eq (gethash key proofread--pending-request-keys)
                work)
        (remhash key proofread--pending-request-keys)))))

(defun proofread--request-work-pending-p (work)
  "Return non-nil when WORK's identity is already active or queued."
  (and (hash-table-p proofread--pending-request-keys)
       (gethash (proofread--request-work-key work)
                proofread--pending-request-keys)))

(defun proofread--request-state-flag-p (work property)
  "Return non-nil when WORK lifecycle PROPERTY is set."
  (pcase property
    ( :superseded (proofread--scheduled-work-superseded work))
    ( :invalidated (proofread--scheduled-work-invalidated work))
    ( :cancelled (proofread--scheduled-work-cancelled work))
    (_ (error "Unknown scheduled work state property %S" property))))

(defun proofread--set-request-state-flag (work property)
  "Set WORK lifecycle PROPERTY."
  (pcase property
    ( :superseded
      (setf (proofread--scheduled-work-superseded work) t))
    ( :invalidated
      (setf (proofread--scheduled-work-invalidated work) t))
    ( :cancelled
      (setf (proofread--scheduled-work-cancelled work) t))
    (_ (error "Unknown scheduled work state property %S" property))))

(defun proofread--record-request-cancellation
    (work &optional reason)
  "Record one cancellation event for WORK, optionally with REASON."
  (unless (proofread--request-state-flag-p work :cancelled)
    (proofread--set-request-state-flag work :cancelled)
    (if reason
        (proofread--record-request-event
         work 'cancelled :reason reason)
      (proofread--record-request-event work 'cancelled))))

(defun proofread--request-range (request)
  "Return REQUEST's current integer range, or nil."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (when-let* ((range (cons beg end))
                ((proofread--range-valid-p range)))
      range)))

(defun proofread--conflicting-request-table (requests candidates)
  "Return an eq table of CANDIDATES conflicting with REQUESTS.
Group valid ranges by checker owner and run at most one interval
conflict sweep for each owner represented in REQUESTS."
  ;; Each bucket is (RANGES . CANDIDATE-ENTRIES).
  (let ((buckets (make-hash-table :test #'equal))
        (table (make-hash-table :test #'eq)))
    (dolist (work requests)
      (let* ((request (proofread--scheduled-work-request work))
             (range (proofread--request-range request)))
        (when range
          (let* ((owner (plist-get request :checker-owner))
                 (bucket (gethash owner buckets)))
            (unless bucket
              (setq bucket (cons nil nil))
              (puthash owner bucket buckets))
            (push range (car bucket))))))
    (unless (zerop (hash-table-count buckets))
      (dolist (candidate candidates)
        (let* ((request
                (proofread--scheduled-work-request candidate))
               (owner (plist-get request :checker-owner))
               (bucket (gethash owner buckets)))
          (when bucket
            (when-let* ((range (proofread--request-range request)))
              (push (cons candidate range) (cdr bucket)))))))
    (maphash
     (lambda (_owner bucket)
       (when (cdr bucket)
         (dolist (entry
                  (proofread--range-conflicting-entries
                   (car bucket) (cdr bucket)))
           (puthash (car entry) t table))))
     buckets)
    table))

(defun proofread--partition-pending-requests (predicate)
  "Remove pending work matching PREDICATE and group it by state.
Call PREDICATE with each active, claimed, then queued work record.  It
must not mutate work lifecycle state or invoke user callbacks.
Publish all retained state after every predicate call finishes while
preserving work order and queued entry identity.  Return selected work
in a plist with the keys :active, :claimed, and :queued.

This function does not change request flags or pending-work identity,
run lifecycle hooks, cancel handles, or schedule work."
  (let (selected-active
        selected-claimed
        selected-queued-entries
        retained-active
        retained-claimed)
    (dolist (work proofread--active-requests)
      (if (funcall predicate work)
          (push work selected-active)
        (push work retained-active)))
    (dolist (work proofread--claimed-requests)
      (if (funcall predicate work)
          (push work selected-claimed)
        (push work retained-claimed)))
    (dolist (entry (proofread--request-queue-entries))
      (when (funcall predicate (proofread--queue-entry-work entry))
        (push entry selected-queued-entries)))
    (setq selected-active (nreverse selected-active))
    (setq selected-claimed (nreverse selected-claimed))
    (setq selected-queued-entries
          (nreverse selected-queued-entries))
    (setq proofread--active-requests (nreverse retained-active))
    (setq proofread--claimed-requests (nreverse retained-claimed))
    (dolist (entry selected-queued-entries)
      (proofread--unlink-request-queue-entry entry))
    (list :active selected-active
          :claimed selected-claimed
          :queued (mapcar #'proofread--queue-entry-work
                          selected-queued-entries))))

(defun proofread--supersede-conflicting-requests (works)
  "Remove older work that conflicts with WORKS.
Return removed work grouped by its previous lifecycle state.
This function changes only internal state; it does not run lifecycle
hooks or call backend cancellation functions."
  (let* ((queued-works (proofread--request-queue-works))
         (conflicts
          (proofread--conflicting-request-table
           works
           (append proofread--active-requests
                   proofread--claimed-requests
                   queued-works)))
         (superseded
          (proofread--partition-pending-requests
           (lambda (candidate)
             (gethash candidate conflicts)))))
    (dolist (work
             (append (plist-get superseded :active)
                     (plist-get superseded :claimed)
                     (plist-get superseded :queued)))
      (proofread--set-request-state-flag work :superseded)
      (proofread--forget-request-work work))
    superseded))

(defun proofread--finish-superseded-requests (superseded)
  "Finish lifecycle handling for requests in SUPERSEDED."
  (let ((proofread--inhibit-queue-dispatch (current-buffer))
        (active (plist-get superseded :active)))
    (dolist (work
             (append active
                     (plist-get superseded :claimed)
                     (plist-get superseded :queued)))
      (proofread--record-request-cancellation work 'superseded))
    (dolist (work active)
      (proofread--cancel-request-handle
       (proofread--scheduled-work-handle work))))
  superseded)

(defun proofread--latest-request-p (work)
  "Return non-nil when no newer request supersedes WORK."
  (not (proofread--request-state-flag-p work :superseded)))

(defun proofread--invalidate-request (work)
  "Mark WORK stale because an edit may have shifted its positions."
  (proofread--set-request-state-flag work :invalidated)
  (proofread--forget-request-work work))

(defun proofread--request-invalidated-p (work)
  "Return non-nil when an edit made WORK's positions unsafe."
  (proofread--request-state-flag-p work :invalidated))

(defun proofread--invalidate-position-shifted-requests (change-beg)
  "Invalidate pending requests that an edit at CHANGE-BEG may shift."
  (let* ((invalid
          (proofread--partition-pending-requests
           (lambda (work)
             (let ((request
                    (proofread--scheduled-work-request work)))
               (when-let* ((request-end
                            (proofread--position-integer
                             (plist-get request :end))))
                 (< change-beg request-end))))))
         (invalid-active (plist-get invalid :active))
         (invalid-requests
          (append invalid-active
                  (plist-get invalid :claimed)
                  (plist-get invalid :queued))))
    (dolist (work invalid-requests)
      (proofread--invalidate-request work))
    (let ((proofread--inhibit-queue-dispatch (current-buffer)))
      (dolist (work invalid-requests)
        (proofread--record-request-cancellation work 'stale))
      (dolist (work invalid-active)
        (proofread--cancel-request-handle
         (proofread--scheduled-work-handle work))))
    (when (and invalid-active
               (not (proofread--request-queue-empty-p)))
      (proofread--schedule-queue-dispatch))))

(defun proofread--unlink-request-queue-entry (entry)
  "Remove queued ENTRY in constant time and return it.
Return nil when ENTRY is no longer queued."
  (when-let* ((state proofread--queue-state)
              ((eq (proofread--queue-entry-owner entry) state)))
    (let ((previous (proofread--queue-entry-previous entry))
          (next (proofread--queue-entry-next entry)))
      (if previous
          (setf (proofread--queue-entry-next previous) next)
        (setf (proofread--queue-state-head state) next))
      (if next
          (setf (proofread--queue-entry-previous next) previous)
        (setf (proofread--queue-state-tail state) previous))
      (proofread--unindex-request-queue-entry state entry)
      (setf (proofread--queue-entry-previous entry) nil)
      (setf (proofread--queue-entry-next entry) nil)
      (setf (proofread--queue-entry-owner entry) nil)
      entry)))

(defun proofread--claim-request-queue-entry (entry)
  "Move queued ENTRY into claimed state and return it."
  (when (proofread--unlink-request-queue-entry entry)
    (push (proofread--queue-entry-work entry)
          proofread--claimed-requests)
    entry))

(defun proofread--claim-request-queue-head ()
  "Move and return the first queue entry into claimed state."
  (when-let* ((entry (proofread--request-queue-head)))
    (proofread--claim-request-queue-entry entry)))

(defun proofread--release-claimed-request
    (work &optional forget-work)
  "Remove WORK from claimed state.
When FORGET-WORK is non-nil, also release its pending-work identity."
  (setq proofread--claimed-requests
        (delq work proofread--claimed-requests))
  (when forget-work
    (proofread--forget-request-work work)))

(defun proofread--prepend-request-queue-entry
    (entry &optional suppress-cache-wakeup)
  "Put ENTRY at the head of the request queue.
When SUPPRESS-CACHE-WAKEUP is non-nil, do not retry the cache entry
that was already considered while ENTRY was claimed."
  (let ((state proofread--queue-state))
    (proofread--link-request-queue-entry
     state entry nil (proofread--queue-state-head state)
     suppress-cache-wakeup)))

(defun proofread--insert-request-queue-entry
    (entry &optional suppress-cache-wakeup)
  "Restore ENTRY to its FIFO position in the request queue.
When SUPPRESS-CACHE-WAKEUP is non-nil, do not retry a cache entry that
was already considered while ENTRY was claimed."
  (let* ((state proofread--queue-state)
         (sequence (proofread--queue-entry-sequence entry))
         (next (proofread--queue-state-head state)))
    (while (and next
                (< (proofread--queue-entry-sequence next) sequence))
      (setq next (proofread--queue-entry-next next)))
    (if next
        (proofread--link-request-queue-entry
         state entry (proofread--queue-entry-previous next) next
         suppress-cache-wakeup)
      (proofread--append-request-queue-entry
       state entry suppress-cache-wakeup))))

(defun proofread--cache-wakeup-pending-p ()
  "Return non-nil when exact queued cache hits await dispatch."
  (and proofread--queue-state
       (> (hash-table-count
           (proofread--queue-state-woken proofread--queue-state))
          0)))

(defun proofread--queue-dispatch-transaction-current-p ()
  "Return non-nil when the dynamic dispatch still owns buffer state."
  (or (null proofread--queue-dispatch-transaction)
      (eq proofread--queue-dispatch-active-p
          proofread--queue-dispatch-transaction)))

(defun proofread--claimed-request-stale-reason (work)
  "Return the terminal stale reason for claimed WORK."
  (if (proofread--request-state-flag-p work :superseded)
      'superseded
    'stale))

(defun proofread--transition-claimed-request
    (work reason &optional restore)
  "Release claimed WORK, recording REASON or calling RESTORE.
RESTORE is a no-argument function that relinks WORK's queue entry.  It
is called only while this dispatch transaction and WORK's lifecycle
are still current.  A successful restore preserves the pending key;
otherwise this function forgets it and records one cancellation with
REASON.  A nil REASON means that an earlier final-result event already
settled WORK."
  (when (memq work proofread--claimed-requests)
    (if (and restore
             (proofread--queue-dispatch-transaction-current-p)
             (proofread--request-lifecycle-current-p work)
             (eq (proofread--request-work-pending-p work) work))
        (progn
          (funcall restore)
          (proofread--release-claimed-request work))
      (proofread--release-claimed-request work t)
      (when reason
        (proofread--record-request-cancellation work reason)))))

(defun proofread--cache-woken-entry< (left right)
  "Return non-nil when queue entry LEFT precedes RIGHT."
  (< (proofread--queue-entry-sequence left)
     (proofread--queue-entry-sequence right)))

(defun proofread--cache-woken-request-status (work)
  "Apply WORK's exact cache entry and return its queue status.
Return one of `cached', `miss', or `stale'.  This function never sends
WORK to a backend."
  (catch 'status
    (unless (proofread--request-ready-to-submit-p work)
      (throw 'status 'stale))
    (when-let* ((status (proofread--request-cache-status work)))
      (throw 'status status))
    'miss))

(defun proofread--claim-current-cache-woken-entry (entry)
  "Claim woken ENTRY only while its exact cache entry remains available."
  (when-let* ((state proofread--queue-state)
              ((proofread--queue-dispatch-transaction-current-p))
              (woken (proofread--queue-state-woken state))
              ((gethash entry woken)))
    (if (proofread--cache-key-present-p
         (proofread--request-queue-entry-cache-key entry))
        (let ((claimed
               (proofread--claim-request-queue-entry entry)))
          (unless claimed
            (remhash entry woken))
          claimed)
      (remhash entry woken)
      nil)))

(defun proofread--drain-cache-woken-requests ()
  "Apply exact queued cache hits and return the number claimed.
Do not scan unrelated requests."
  (let (entries
        (claimed-count 0))
    (when (and proofread--queue-state
               (proofread--queue-dispatch-transaction-current-p))
      (maphash (lambda (entry _value)
                 (push entry entries))
               (proofread--queue-state-woken
                proofread--queue-state)))
    (setq entries (sort entries #'proofread--cache-woken-entry<))
    (dolist (entry entries)
      ;; Lifecycle hooks from an earlier hit may already have removed
      ;; this exact entry or invalidated its cache wakeup.
      (when-let* ((claimed
                   (proofread--claim-current-cache-woken-entry entry))
                  (work (proofread--queue-entry-work claimed)))
        (setq claimed-count (1+ claimed-count))
        (unwind-protect
            (pcase (proofread--cache-woken-request-status work)
              ('cached
               (proofread--transition-claimed-request
                work nil))
              ('stale
               (proofread--transition-claimed-request
                work
                (proofread--claimed-request-stale-reason work)))
              ('miss
               ;; Cache eviction or a defensive text mismatch must not
               ;; promote this request ahead of unrelated FIFO work.
               (proofread--transition-claimed-request
                work
                (proofread--claimed-request-stale-reason work)
                (lambda ()
                  (proofread--insert-request-queue-entry
                   entry t)))))
          (proofread--transition-claimed-request
           work 'error))))
    claimed-count))

(defun proofread--drain-request-queue ()
  "Drain FIFO-ready queued requests and return those sent to backends."
  (let (requests
        full)
    (while (and (not full)
                (proofread--queue-dispatch-transaction-current-p)
                (not (proofread--request-queue-empty-p)))
      (let* ((entry (proofread--claim-request-queue-head))
             (work (proofread--queue-entry-work entry)))
        (unwind-protect
            (pcase (proofread--submit-request work)
              ('sent
               (proofread--release-claimed-request work)
               (push (proofread--scheduled-work-request work)
                     requests))
              ('full
               ;; The current cache state was already considered by
               ;; submission.  Keep unrelated work in strict FIFO order.
               (proofread--transition-claimed-request
                work
                (proofread--claimed-request-stale-reason work)
                (lambda ()
                  (proofread--prepend-request-queue-entry
                   entry t)))
               (setq full t))
              ((or 'cached 'error)
               (proofread--transition-claimed-request
                work nil))
              ('stale
               (proofread--transition-claimed-request
                work
                (proofread--claimed-request-stale-reason work))))
          ;; A malformed setting or unexpected predicate failure must
          ;; not strand a request between queue and active state.
          (proofread--transition-claimed-request
           work 'error))))
    (nreverse requests)))

(defun proofread--dispatch-queued-requests ()
  "Dispatch queued work and return requests sent to backends."
  (cond
   ((proofread--queue-dispatch-inhibited-p)
    ;; The dynamic inhibition may belong to another source buffer.
    ;; Ensure this buffer resumes after that lifecycle transaction
    ;; unwinds.
    (proofread--schedule-queue-dispatch))
   (proofread--queue-dispatch-active-p
    (setq proofread--queue-dispatch-requested-p t))
   (t
    (let ((transaction (make-symbol "proofread-queue-dispatch")))
      (setq proofread--queue-dispatch-active-p transaction)
      (unwind-protect
          (let ((proofread--queue-dispatch-transaction transaction)
                (proofread--queue-dispatch-pruned-active-p nil)
                (continue t)
                dispatched)
            (while (and continue
                        (eq proofread--queue-dispatch-active-p
                            transaction))
              (setq proofread--queue-dispatch-requested-p nil)
              (setq dispatched
                    (nconc dispatched
                           (proofread--drain-request-queue)))
              (let ((cache-claims
                     (proofread--drain-cache-woken-requests)))
                (setq continue
                      (or proofread--queue-dispatch-requested-p
                          (proofread--cache-wakeup-pending-p)
                          (> cache-claims 0)))))
            dispatched)
        ;; Mode teardown and reinitialization replace transaction state.
        ;; An old unwind must not clear a newer generation's dispatcher.
        (when (eq proofread--queue-dispatch-active-p transaction)
          (setq proofread--queue-dispatch-active-p nil)
          (setq proofread--queue-dispatch-requested-p nil)))))))

(defun proofread--request-range-valid-p (request)
  "Return non-nil if REQUEST range is valid in the current buffer."
  (when-let* ((range (proofread--request-range request)))
    (proofread--range-contains-p
     (cons (point-min) (point-max)) range)))

(defun proofread--request-text-matches-p (request)
  "Return non-nil if REQUEST text still matches the current buffer."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (and beg end
         (equal (buffer-substring-no-properties beg end)
                (plist-get request :text)))))

(defun proofread--request-currently-included-p (request)
  "Return non-nil when current ignore settings still include REQUEST."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (and beg end
         (null (proofread--ignored-ranges-in-region beg end)))))

(defun proofread--request-current-target-domain (request)
  "Return the current target domain containing REQUEST, or nil."
  (let ((kind (plist-get request :target-kind))
        (policy (plist-get request :target-policy))
        (request-range
         (proofread--request-range request)))
    (when request-range
      (cl-find-if
       (lambda (domain)
         (and
          (eq kind (plist-get domain :kind))
          (proofread--range-contains-p
           (cons (plist-get domain :domain-beg)
                 (plist-get domain :domain-end))
           request-range)))
       (proofread--target-domains-for-kind
        (list request-range)
        kind policy (point-min) (point-max))))))

(defun proofread--request-target-fresh-p (request domain)
  "Return non-nil when REQUEST still belongs to target DOMAIN."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end)))
        (domain-beg
         (proofread--position-integer
          (plist-get request :domain-beg)))
        (domain-end
         (proofread--position-integer
          (plist-get request :domain-end)))
        (kind (plist-get request :target-kind))
        (policy (plist-get request :target-policy)))
    (and beg end domain-beg domain-end kind policy
         domain
         (eq major-mode (plist-get request :major-mode))
         (eq policy (proofread--effective-target-policy))
         (proofread--range-contains-p
          (cons domain-beg domain-end) (cons beg end))
         (proofread--request-currently-included-p request))))

(defun proofread--request-context-matches-p (request domain)
  "Return non-nil when REQUEST still has the same context in DOMAIN."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end)))
        (domain-beg (plist-get domain :domain-beg))
        (domain-end (plist-get domain :domain-end)))
    (and beg end domain-beg domain-end
         (save-mark-and-excursion
           (save-restriction
             (narrow-to-region domain-beg domain-end)
             (let ((proofread--active-target-kind
                    (plist-get request :target-kind)))
               (and (equal (plist-get request :context-before)
                           (proofread--request-ready-context-before
                            beg))
                    (equal (plist-get request :context-after)
                           (proofread--request-ready-context-after
                            end)))))))))

(defun proofread--request-current-backend-identity-p (request)
  "Return non-nil when REQUEST's backend identity is still current."
  (or (plist-get request :checker-identity)
      (equal (plist-get request :backend-identity)
             (proofread--backend-identity
              (plist-get request :backend)))))

(defun proofread--fresh-request-p (work)
  "Return non-nil if WORK still matches its originating buffer."
  (let* ((request (proofread--scheduled-work-request work))
         (buffer (plist-get request :buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (and proofread-mode
                (equal proofread--generation
                       (plist-get request :generation))
                (not (proofread--request-invalidated-p work))
                (let ((accessible-beg
                       (plist-get request :accessible-beg))
                      (accessible-end
                       (plist-get request :accessible-end)))
                  (if accessible-beg
                      (and (buffer-narrowed-p)
                           (= (point-min) accessible-beg)
                           (= (point-max) accessible-end))
                    (not (buffer-narrowed-p))))
                (proofread--request-current-backend-identity-p
                 request)
                (proofread--request-current-checker-p request)
                (proofread--request-range-valid-p request)
                (proofread--request-text-matches-p request)
                (let ((domain
                       (proofread--request-current-target-domain
                        request)))
                  (and (proofread--request-target-fresh-p
                        request domain)
                       (proofread--request-context-matches-p
                        request domain))))))))

(defun proofread--request-continuable-p (source)
  "Return non-nil if SOURCE may submit another backend pass.
SOURCE may be scheduled work or its backend-facing request payload."
  (when-let* ((work
               (if (proofread--scheduled-work-p source)
                   source
                 (proofread--scheduled-work-for-request source)))
              (request (proofread--scheduled-work-request work))
              (buffer (plist-get request :buffer))
              ((buffer-live-p buffer)))
    ;; Freshness predicates may reenter dispatch and supersede WORK.
    (and (proofread--fresh-request-p work)
         (with-current-buffer buffer
           (proofread--latest-request-p work)))))

;;;; Diagnostic cache

(defun proofread--backend-identity-p (value)
  "Return non-nil if VALUE is a structured backend identity."
  (and (listp value)
       (plist-member value :backend)
       (plist-member value :contract-version)))

(defun proofread--snapshot-value (value)
  "Return a detached snapshot of core-owned mutable data in VALUE.
Backend-local checker options cross their backend's registered
`:snapshot-options' boundary instead."
  (cond
   ((consp value)
    (cons (proofread--snapshot-value (car value))
          (proofread--snapshot-value (cdr value))))
   ((stringp value) (copy-sequence value))
   ((bool-vector-p value) (copy-sequence value))
   ((vectorp value)
    (let ((copy (copy-sequence value)))
      (dotimes (index (length copy))
        (aset copy index
              (proofread--snapshot-value (aref copy index))))
      copy))
   ((hash-table-p value)
    (let ((copy
           (make-hash-table
            :test (hash-table-test value)
            :size (max 1 (hash-table-count value)))))
      (maphash
       (lambda (key item)
         (puthash (proofread--snapshot-value key)
                  (proofread--snapshot-value item)
                  copy))
       value)
      copy))
   (t value)))

(defun proofread--backend-identity (&optional backend)
  "Return canonical identity for BACKEND, or nil when it is nil."
  (proofread--snapshot-value
   (cond
    ((proofread--backend-identity-p backend) backend)
    ((null backend) nil)
    (t
     (when-let* ((descriptor
                  (proofread--backend-descriptor backend))
                 (identity (plist-get descriptor :identity)))
       (let ((value (funcall identity)))
         (unless (and (proofread--backend-identity-p value)
                      (eq (plist-get value :backend) backend))
           (error "Invalid identity for proofread backend %S"
                  backend))
         value))))))

(defun proofread--chunk-text-hash (text)
  "Return a deterministic cache hash for chunk TEXT."
  (secure-hash 'sha256 (or text "")))

(defun proofread--context-cache-identity (chunk)
  "Return stable context identity for cache key CHUNK."
  (list :strategy 'sentence-window
        :before-sentences proofread-context-sentences-before
        :after-sentences proofread-context-sentences-after
        :size proofread-context-size
        :before-hash
        (proofread--chunk-text-hash (plist-get chunk :context-before))
        :after-hash
        (proofread--chunk-text-hash
         (plist-get chunk :context-after))))

(defun proofread--cache-identity-snapshots (chunk &optional backend)
  "Return backend and checker identities for cache key CHUNK.
Resolve BACKEND's descriptor at most once when CHUNK does not already
contain both snapshots."
  (let* ((checker-identity-present
          (plist-member chunk :checker-identity))
         (checker-identity (plist-get chunk :checker-identity))
         (backend-identity-present
          (or (plist-member chunk :backend-identity)
              (and checker-identity-present
                   (plist-member checker-identity
                                 :backend-identity))))
         (backend-identity
          (if (plist-member chunk :backend-identity)
              (plist-get chunk :backend-identity)
            (and checker-identity-present
                 (plist-get checker-identity :backend-identity)))))
    (if (and backend-identity-present checker-identity-present)
        (cons backend-identity checker-identity)
      (when-let* ((backend-name (or backend
                                    (plist-get chunk :backend)))
                  (raw-checker
                   (proofread--ad-hoc-checker backend-name)))
        (let* ((descriptor
                (proofread--backend-descriptor backend-name))
               (checker
                (if descriptor
                    (proofread--checker-with-options-snapshot
                     raw-checker descriptor)
                  raw-checker))
               (backend-identity
                (if backend-identity-present
                    backend-identity
                  (and descriptor
                       (proofread--backend-checker-identity
                        checker descriptor))))
               (checker-identity
                (if checker-identity-present
                    checker-identity
                  (proofread--checker-identity-from-snapshots
                   checker descriptor backend-identity))))
          (cons backend-identity checker-identity))))))

(defun proofread--cache-key (chunk &optional backend)
  "Return diagnostic cache key for CHUNK and BACKEND."
  (let ((identities
         (proofread--cache-identity-snapshots chunk backend)))
    (list :text-hash
          (proofread--chunk-text-hash (plist-get chunk :text))
          :language (proofread--snapshot-value
                     (plist-get chunk :language))
          :display-language
          (proofread--snapshot-value
           (plist-get chunk :display-language))
          :major-mode (plist-get chunk :major-mode)
          :target-policy (plist-get chunk :target-policy)
          :target-kind (plist-get chunk :target-kind)
          :backend (car identities)
          :checker (cdr identities)
          :contract-version proofread--contract-version
          :context (proofread--context-cache-identity chunk))))

(defun proofread--ensure-cache ()
  "Return this buffer's cache table when Proofread is active."
  (when proofread-mode
    (unless (hash-table-p proofread--cache)
      (setq proofread--cache (make-hash-table :test #'equal)))
    proofread--cache))

(defun proofread--cache-key-present-p (key)
  "Return non-nil when the enabled cache has KEY."
  (and (> proofread-cache-max-entries 0)
       (hash-table-p proofread--cache)
       (let ((missing (make-symbol "missing")))
         (not (eq (gethash key proofread--cache missing)
                  missing)))))

(defun proofread--wake-queued-cache-key (key)
  "Wake only queued entries that can consume cache KEY."
  (when-let* ((state proofread--queue-state)
              (bucket (gethash key
                               (proofread--queue-state-index state))))
    (maphash
     (lambda (entry _value)
       (puthash entry t (proofread--queue-state-woken state)))
     bucket)
    (when proofread--queue-dispatch-active-p
      (setq proofread--queue-dispatch-requested-p t))))

(defun proofread--forget-queued-cache-key (key)
  "Forget pending cache wakeups for queued entries using KEY."
  (when-let* ((state proofread--queue-state)
              (bucket (gethash key
                               (proofread--queue-state-index state))))
    (maphash
     (lambda (entry _value)
       (remhash entry (proofread--queue-state-woken state)))
     bucket)))

(defun proofread--clear-queued-cache-wakeups ()
  "Clear every pending exact cache-to-queue wakeup."
  (when proofread--queue-state
    (clrhash (proofread--queue-state-woken proofread--queue-state))))

(defun proofread--cache-read (key)
  "Return diagnostic cache entry for KEY in the current buffer."
  (let ((cache (proofread--ensure-cache)))
    (when-let* ((value (and cache
                            (> proofread-cache-max-entries 0)
                            (gethash key cache))))
      (setq proofread--cache-order
            (cons key (delete key proofread--cache-order)))
      value)))

(defun proofread--cache-write (key value)
  "Store VALUE under KEY in the current buffer diagnostic cache."
  (let ((cache (proofread--ensure-cache)))
    (when (and cache (> proofread-cache-max-entries 0))
      (puthash key value cache)
      (setq proofread--cache-order
            (cons key (delete key proofread--cache-order)))
      (while (> (length proofread--cache-order)
                proofread-cache-max-entries)
        (let ((oldest (car (last proofread--cache-order))))
          (setq proofread--cache-order
                (butlast proofread--cache-order))
          (remhash oldest cache)
          (proofread--forget-queued-cache-key oldest)))
      (proofread--wake-queued-cache-key key)
      value)))

(defun proofread--diagnostic-to-relative (diagnostic request)
  "Return DIAGNOSTIC with ranges relative to REQUEST start."
  (let* ((base (plist-get request :beg))
         (beg (plist-get diagnostic :beg))
         (end (plist-get diagnostic :end))
         (relative (copy-sequence diagnostic)))
    (setq relative (plist-put relative :beg (- beg base)))
    (setq relative (plist-put relative :end (- end base)))
    relative))

(defun proofread--diagnostic-to-absolute (diagnostic request)
  "Return cached DIAGNOSTIC with ranges absolute to REQUEST start."
  (let* ((base (plist-get request :beg))
         (beg (plist-get diagnostic :beg))
         (end (plist-get diagnostic :end))
         (absolute (copy-sequence diagnostic)))
    (setq absolute (plist-put absolute :beg (+ base beg)))
    (setq absolute (plist-put absolute :end (+ base end)))
    absolute))

(defun proofread--diagnostics-to-cache-payload (diagnostics request)
  "Return provider-neutral relative DIAGNOSTICS for REQUEST."
  (mapcar (lambda (diagnostic)
            (let ((payload
                   (proofread--diagnostic-to-relative
                    diagnostic request)))
              (dolist (key proofread--diagnostic-provenance-keys)
                (cl-remf payload key))
              payload))
          diagnostics))

(defun proofread--diagnostics-to-absolute (diagnostics request)
  "Return cached DIAGNOSTICS as absolute ranges for REQUEST."
  (mapcar (lambda (diagnostic)
            (proofread--diagnostic-to-absolute diagnostic request))
          diagnostics))

(defun proofread--make-cache-entry (request diagnostics)
  "Return a provider-neutral cache entry for REQUEST and DIAGNOSTICS."
  (list :text (plist-get request :text)
        :diagnostics
        (proofread--diagnostics-to-cache-payload diagnostics request)))

(defun proofread--cache-read-request (work)
  "Return cache entry matching WORK in the current buffer."
  (proofread--cache-read
   (proofread--scheduled-work-cache-key work)))

(defun proofread--cache-write-request (work diagnostics)
  "Write DIAGNOSTICS for WORK to the current buffer cache."
  (let ((request (proofread--scheduled-work-request work)))
    (proofread--cache-write
     (proofread--scheduled-work-cache-key work)
     (proofread--make-cache-entry request diagnostics))))

(defun proofread--apply-cache-entry (work entry)
  "Apply cached diagnostics from ENTRY for WORK when still valid."
  (let ((request (proofread--scheduled-work-request work)))
    (when (equal (plist-get entry :text)
                 (plist-get request :text))
      (proofread--record-request-event
       work 'cache-hit
       :entry entry)
      (let ((result
             (list :status 'ok
                   :source 'cache
                   :request request
                   :diagnostics
                   (proofread--diagnostics-to-absolute
                    (plist-get entry :diagnostics)
                    request))))
        (proofread--record-request-event
         work 'backend-result
         :backend (plist-get request :backend)
         :source 'cache
         :entry entry
         :result result)
        (proofread--handle-backend-result work result)))))

;;;; Backend results

(defun proofread--ensure-diagnostic-request-ranges ()
  "Return the current buffer's diagnostic request range table."
  (unless (hash-table-p proofread--diagnostic-request-ranges)
    (setq proofread--diagnostic-request-ranges
          (make-hash-table :test #'eq)))
  proofread--diagnostic-request-ranges)

(defun proofread--diagnostic-request-range (diagnostic)
  "Return the current request range that produced DIAGNOSTIC, or nil."
  (when (hash-table-p proofread--diagnostic-request-ranges)
    (when-let* ((range
                 (gethash
                  diagnostic
                  proofread--diagnostic-request-ranges))
                (beg (proofread--position-integer (car range)))
                (end (proofread--position-integer (cdr range))))
      (cons beg end))))

(defun proofread--diagnostic-replaced-by-request-p
    (diagnostic request request-range)
  "Return non-nil if DIAGNOSTIC is replaced by REQUEST.
REQUEST-RANGE is the checked buffer range as a (BEG . END) pair."
  (let
      ((diagnostic-range
        (proofread--diagnostic-live-range diagnostic))
       (owner-range
        (proofread--diagnostic-request-range diagnostic)))
    (and (proofread--diagnostic-owned-by-request-p diagnostic request)
         (or (equal owner-range request-range)
             (and diagnostic-range
                  (if (= (car diagnostic-range) (cdr diagnostic-range))
                      (proofread--range-strictly-contains-position-p
                       request-range (car diagnostic-range))
                    (proofread--range-overlaps-p
                     request-range diagnostic-range)))))))

(defun proofread--diagnostic-owned-by-request-p (diagnostic request)
  "Return non-nil when REQUEST may replace DIAGNOSTIC.
Diagnostics without checker provenance can be replaced by ad-hoc
requests or by requests that also have no checker owner."
  (let ((owner (plist-get request :checker-owner))
        (diagnostic-owner (plist-get diagnostic :checker-owner)))
    (or (equal diagnostic-owner owner)
        (and (null diagnostic-owner)
             (or (null owner)
                 (plist-get owner :ad-hoc))))))

(defun proofread--diagnostics-replaced-by-request
    (request request-range)
  "Return diagnostics replaced by REQUEST over REQUEST-RANGE."
  (cl-remove-if-not
   (lambda (diagnostic)
     (proofread--diagnostic-replaced-by-request-p
      diagnostic request request-range))
   proofread--diagnostics))

(defun proofread--record-diagnostic-request-ranges
    (diagnostics request-range)
  "Record REQUEST-RANGE as the owner of DIAGNOSTICS."
  (let ((range (cons (copy-marker (car request-range) t)
                     (copy-marker (cdr request-range) nil)))
        (table (proofread--ensure-diagnostic-request-ranges)))
    (dolist (diagnostic diagnostics)
      (puthash diagnostic range table))))

(defun proofread--apply-backend-diagnostics
    (diagnostics &optional request-range)
  "Record DIAGNOSTICS and create overlays for them.
When REQUEST-RANGE is non-nil, record it as their owning request
range."
  (let ((diagnostics
         (mapcar #'copy-sequence
                 (proofread--filter-ignored-diagnostics
                  diagnostics))))
    (when request-range
      (proofread--record-diagnostic-request-ranges
       diagnostics request-range))
    (setq proofread--diagnostics
          (nconc proofread--diagnostics diagnostics))
    (dolist (diagnostic diagnostics)
      (proofread--create-overlay diagnostic))
    (proofread--run-diagnostics-changed-hook)))

(defun proofread--replace-backend-diagnostics (request diagnostics)
  "Replace current diagnostics for REQUEST with DIAGNOSTICS."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (when (and beg end)
      (let* ((request-range (cons beg end))
             (replaced
              (proofread--diagnostics-replaced-by-request
               request request-range)))
        (proofread--invalidate-affected-diagnostics
         (delq nil
               (mapcar #'proofread--overlay-for-diagnostic replaced))
         replaced t)
        (proofread--apply-backend-diagnostics
         diagnostics request-range)))))

(defun proofread--merge-backend-diagnostics (request diagnostics)
  "Merge partial REQUEST's new DIAGNOSTICS into existing ones."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end)))
        (new-diagnostics
         (proofread--new-diagnostics
          diagnostics proofread--diagnostics)))
    (when (and beg end new-diagnostics)
      (proofread--apply-backend-diagnostics
       new-diagnostics (cons beg end)))))

(defun proofread--report-backend-error (result)
  "Report the backend error described by RESULT."
  (proofread-report-warning-without-window
   (proofread--backend-error-message result)
   "backend request failed; see *Warnings*"))

(defun proofread--handle-backend-result (work result)
  "Handle backend RESULT for WORK and return an internal status."
  (let* ((request (proofread--scheduled-work-request work))
         (buffer (plist-get request :buffer))
         (result-status (plist-get result :status))
         (continuable-p
          (and (memq result-status '( ok error))
               (proofread--request-continuable-p work)))
         (status
          (pcase result-status
            ('ok
             (if continuable-p
                 (with-current-buffer buffer
                   (let* ((backend-diagnostics
                           (plist-get result :diagnostics))
                          (cacheable-p
                           (not
                            (or (eq (plist-get result :source)
                                    'cache)
                                (plist-get result :partial))))
                          (cache-diagnostics
                           (and cacheable-p
                                (mapcar #'copy-sequence
                                        backend-diagnostics)))
                          (diagnostics
                           (proofread--diagnostics-with-request-provenance
                            request backend-diagnostics)))
                     (if (plist-get result :partial)
                         (proofread--merge-backend-diagnostics
                          request diagnostics)
                       (proofread--replace-backend-diagnostics
                        request diagnostics))
                     (when cacheable-p
                       (proofread--cache-write-request
                        work cache-diagnostics)))
                   'applied)
               'stale))
            ('error
             (if continuable-p
                 (progn
                   (unless (proofread--scheduled-work-batch work)
                     (proofread--report-backend-error result))
                   'error)
               'stale))
            (_ 'error))))
    (proofread--record-request-event
     work 'final-result
     :result result
     :status status)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (proofread--forget-request-work work)))
    status))

(defun proofread--prepare-checker-request-work
    (chunks profile preparation)
  "Prepare unpublished request work from PREPARATION.
CHUNKS and PROFILE describe the work.  Return `(WORK . CHUNK)' pairs
after removing duplicate pending work."
  (let* ((checker
          (proofread--checker-preparation-checker preparation))
         (backend (plist-get checker :backend))
         (new-work-keys (make-hash-table :test #'equal))
         prepared)
    (dolist (chunk chunks)
      (let* ((request
              (proofread--make-backend-request
               chunk backend checker profile preparation))
             (work (proofread--make-request-work request))
             (work-key (proofread--request-work-key work)))
        (unless (or (proofread--request-work-pending-p work)
                    (gethash work-key new-work-keys))
          (puthash work-key t new-work-keys)
          (push (cons work chunk) prepared))))
    (nreverse prepared)))

(defun proofread--record-prepared-work-publication (prepared)
  "Record publication events for PREPARED request work."
  (dolist (item prepared)
    (let ((work (car item)))
      (proofread--record-request-event
       work 'chunk-request
       :chunk (cdr item))
      (proofread--record-request-event
       work 'queued-request
       :backend (proofread--scheduled-work-backend work)))))

(defun proofread--prepare-profile-checker-dispatch
    (chunks profile checker)
  "Prepare CHUNKS for CHECKER in PROFILE and return isolated state.
The returned plist has `:status' set to `prepared', `unsupported', or
`failed'.  Return `aborted' when the source buffer dies during an
adapter call.  Prepared state includes unpublished `:work'; failed
state includes one checker-level `:failure'."
  (let ((buffer (current-buffer))
        (backend (plist-get checker :backend))
        descriptor)
    (catch 'result
      (condition-case err
          (setq descriptor
                (with-current-buffer buffer
                  (proofread--backend-descriptor backend)))
        (error
         (throw
          'result
          (if (buffer-live-p buffer)
              (list
               :status 'failed
               :failure
               (proofread--make-checker-dispatch-failure
                profile checker 'backend-loading err))
            '( :status aborted)))))
      (unless (buffer-live-p buffer)
        (throw 'result '( :status aborted)))
      (unless descriptor
        (throw 'result '( :status unsupported)))
      (unless chunks
        (throw 'result
               '( :status prepared :supported t :work nil)))
      (let (prepared-checker preparation)
        (condition-case err
            (setq prepared-checker
                  (with-current-buffer buffer
                    (proofread--checker-with-options-snapshot
                     checker descriptor)))
          (error
           (throw
            'result
            (if (buffer-live-p buffer)
                (list
                 :status 'failed
                 :supported t
                 :failure
                 (proofread--make-checker-dispatch-failure
                  profile checker 'checker-options err))
              '( :status aborted)))))
        (unless (buffer-live-p buffer)
          (throw 'result '( :status aborted)))
        (condition-case err
            (setq preparation
                  (with-current-buffer buffer
                    (proofread--finish-checker-preparation
                     prepared-checker descriptor nil buffer)))
          (error
           (throw
            'result
            (if (buffer-live-p buffer)
                (list
                 :status 'failed
                 :supported t
                 :failure
                 (proofread--make-checker-dispatch-failure
                  profile checker 'checker-identity err))
              '( :status aborted)))))
        (unless (buffer-live-p buffer)
          (throw 'result '( :status aborted)))
        (condition-case err
            (with-current-buffer buffer
              (list
               :status 'prepared
               :supported t
               :work
               (proofread--prepare-checker-request-work
                chunks profile preparation)))
          (error
           (if (buffer-live-p buffer)
               (list
                :status 'failed
                :supported t
                :failure
                (proofread--make-checker-dispatch-failure
                 profile checker 'request-construction err))
             '( :status aborted))))))))

(defun proofread--publish-profile-checker-dispatches
    (preparations transaction)
  "Publish work in ordered PREPARATIONS as one transaction.
Return the enqueued work, or nil when there is none.  All prepared
checker work is visible and has its checker-local batch before any
lifecycle or failure hook runs.  TRANSACTION owns the eventual queue
drain."
  (let (groups)
    (dolist (preparation preparations)
      (when (eq (plist-get preparation :status) 'prepared)
        (push (plist-get preparation :work) groups)))
    (setq groups (nreverse groups))
    (let* ((prepared (apply #'append groups))
           (works (mapcar #'car prepared))
           superseded
           enqueued)
      (let ((proofread--inhibit-queue-dispatch (current-buffer)))
        (when works
          ;; Batch construction cannot strand published work: finish
          ;; it before mutating the shared request queue.
          (dolist (group groups)
            (proofread--attach-request-batch
             (mapcar #'car group)))
          (setq superseded
                (proofread--supersede-conflicting-requests works))
          (setq enqueued (proofread--enqueue-requests works))
          (when enqueued
            (setf
             (proofread--profile-dispatch-transaction-published
              transaction)
             t)))
        (proofread--finish-superseded-requests superseded)
        (dolist (preparation preparations)
          (pcase (plist-get preparation :status)
            ('prepared
             (let ((group (plist-get preparation :work)))
               (if enqueued
                   (proofread--record-prepared-work-publication group)
                 (dolist (item group)
                   (proofread--reject-request-during-clear
                    (car item))))))
            ('failed
             (proofread--report-checker-dispatch-failure-safely
              (plist-get preparation :failure))))))
      enqueued)))

(defun proofread--profile-dispatch-state-current-p
    (buffer generation queue-state)
  "Return non-nil when BUFFER still owns the captured dispatch state.
GENERATION and QUEUE-STATE identify the state captured before profile
preparation began."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and proofread-mode
              (equal proofread--generation generation)
              (eq proofread--queue-state queue-state)))))

(defun proofread--find-profile-dispatch-transaction
    (buffer generation queue-state)
  "Return the active profile transaction for BUFFER's captured state.
GENERATION and QUEUE-STATE distinguish a reinitialized buffer from an
older dispatch still on the stack."
  (cl-find-if
   (lambda (transaction)
     (and
      (eq buffer
          (proofread--profile-dispatch-transaction-buffer
           transaction))
      (equal generation
             (proofread--profile-dispatch-transaction-generation
              transaction))
      (eq queue-state
          (proofread--profile-dispatch-transaction-queue-state
           transaction))))
   proofread--profile-dispatch-transactions))

(defun proofread--profile-publication-state-current-p
    (buffer generation queue-state chars-tick)
  "Return non-nil when BUFFER still admits the prepared profile work.
GENERATION, QUEUE-STATE, and CHARS-TICK were captured before checker
preparation."
  (and (proofread--profile-dispatch-state-current-p
        buffer generation queue-state)
       (with-current-buffer buffer
         (= (buffer-chars-modified-tick) chars-tick))))

(defun proofread--dispatch-profile-request-ready-chunks-result
    (chunks profile)
  "Dispatch CHUNKS for PROFILE and return checker dispatch state.
The result contains `:requests', `:supported-count', and `:failures'."
  (let* ((buffer (current-buffer))
         (generation proofread--generation)
         (queue-state proofread--queue-state)
         (chars-tick (buffer-chars-modified-tick))
         (parent-inhibited-p
          (proofread--queue-dispatch-inhibited-p))
         (parent-profile-transaction
          (proofread--find-profile-dispatch-transaction
           buffer generation queue-state))
         (profile-transaction
          (or parent-profile-transaction
              (proofread--make-profile-dispatch-transaction
               buffer generation queue-state)))
         (root-profile-dispatch-p
          (null parent-profile-transaction))
         (profile-transactions
          (if parent-profile-transaction
              proofread--profile-dispatch-transactions
            (cons profile-transaction
                  proofread--profile-dispatch-transactions)))
         preparations
         supported-count
         failures
         requests
         completed-p)
    (unwind-protect
        (progn
          (let ((proofread--inhibit-queue-dispatch buffer)
                (proofread--profile-dispatch-transactions
                 profile-transactions))
            (setq preparations
                  (catch 'aborted
                    (let (states)
                      (dolist
                          (checker (plist-get profile :checkers))
                        (unless (buffer-live-p buffer)
                          (throw 'aborted (nreverse states)))
                        (let ((state
                               (with-current-buffer buffer
                                 (proofread--prepare-profile-checker-dispatch
                                  chunks profile checker))))
                          (push state states)
                          (when (eq (plist-get state :status)
                                    'aborted)
                            (throw 'aborted
                                   (nreverse states)))))
                      (nreverse states))))
            (setq supported-count
                  (cl-count-if
                   (lambda (preparation)
                     (plist-get preparation :supported))
                   preparations))
            (setq failures
                  (cl-loop
                   for preparation in preparations
                   when (eq (plist-get preparation :status)
                            'failed)
                   collect (plist-get preparation :failure)))
            (if (proofread--profile-publication-state-current-p
                 buffer generation queue-state chars-tick)
                (with-current-buffer buffer
                  (proofread--publish-profile-checker-dispatches
                   preparations profile-transaction))
              ;; Do not let work prepared before an edit or mode reset
              ;; supersede newer work.  Preparation failures remain
              ;; visible.
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (dolist (failure failures)
                    (proofread--report-checker-dispatch-failure-safely
                     failure))))))
          (when (and root-profile-dispatch-p
                     (proofread--profile-dispatch-transaction-published
                      profile-transaction)
                     (proofread--profile-dispatch-state-current-p
                      buffer generation queue-state))
            (with-current-buffer buffer
              (if parent-inhibited-p
                  (proofread--schedule-queue-dispatch)
                ;; Reentrant lifecycle hooks may have requested a
                ;; timer while publication was inhibited.  This direct
                ;; dispatch supersedes it.
                (proofread--cancel-queue-dispatch-timer)
                (let ((dispatched
                       (proofread--dispatch-queued-requests)))
                  ;; Reentry into an active queue transaction returns
                  ;; its request flag rather than a request list.
                  (when (listp dispatched)
                    (setq requests dispatched))))))
          (setq completed-p t)
          (list :requests requests
                :supported-count supported-count
                :failures failures))
      (when (and root-profile-dispatch-p
                 (not completed-p)
                 (proofread--profile-dispatch-transaction-published
                  profile-transaction)
                 (proofread--profile-dispatch-state-current-p
                  buffer generation queue-state))
        (with-current-buffer buffer
          (proofread--schedule-queue-dispatch))))))

;;;; Cancellation and automatic checks

(defun proofread--cancel-request-handle (request-handle)
  "Cancel REQUEST-HANDLE once through its captured operation.
The backend handle value is opaque and is passed unchanged.  Errors
from one cancel operation are reported without escaping, so cleanup
of later requests can continue."
  (when (and (proofread--request-handle-p request-handle)
             (not
              (proofread--request-handle-cancelled request-handle)))
    ;; Mark first so reentrant and repeated cleanup stays idempotent.
    (setf (proofread--request-handle-cancelled request-handle) t)
    (when-let* ((cancel
                 (proofread--request-handle-cancel request-handle)))
      (condition-case err
          (funcall
           cancel
           (proofread--request-handle-value request-handle))
        (error
         (condition-case nil
             (proofread-report-warning-without-window
              (format "Proofread backend cancellation failed (%S)"
                      (proofread--condition-kind err))
              "backend cancellation failed; see *Warnings*")
           (error nil)))))
    t))

(defun proofread--cancel-active-requests ()
  "Cancel cancellable active backend requests for the current buffer."
  (let ((works proofread--active-requests)
        (proofread--inhibit-queue-dispatch (current-buffer)))
    (setq proofread--active-requests nil)
    (dolist (work works)
      (proofread--forget-request-work work))
    (dolist (work works)
      (proofread--record-request-cancellation work)
      (proofread--cancel-request-handle
       (proofread--scheduled-work-handle work)))))

(defun proofread--cancel-idle-timer ()
  "Cancel the current buffer's scheduled idle timer."
  (when (timerp proofread--idle-timer)
    (cancel-timer proofread--idle-timer))
  (setq proofread--idle-timer nil))

(defun proofread--cancel-queue-dispatch-timer ()
  "Cancel the current buffer's scheduled queue-dispatch timer."
  (when (timerp proofread--queue-dispatch-timer)
    (cancel-timer proofread--queue-dispatch-timer))
  (setq proofread--queue-dispatch-timer nil))

(defun proofread--queue-dispatch-timer-run (buffer)
  "Resume queued work for BUFFER after its current edit finishes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq proofread--queue-dispatch-timer nil)
      (when proofread-mode
        (proofread--dispatch-queued-requests)))))

(defun proofread--schedule-queue-dispatch ()
  "Schedule queued work to resume after the current edit."
  (when (and proofread-mode
             (not (proofread--request-queue-empty-p))
             (not (timerp proofread--queue-dispatch-timer)))
    (setq proofread--queue-dispatch-timer
          (run-at-time
           0 nil #'proofread--queue-dispatch-timer-run
           (current-buffer)))))

(defun proofread--clear-scheduled-work ()
  "Clear pending scheduled proofreading work in the current buffer."
  (let ((works (append proofread--claimed-requests
                       (proofread--request-queue-works)))
        (proofread--inhibit-queue-dispatch (current-buffer))
        (proofread--clearing-scheduled-work (current-buffer)))
    (setq proofread--pending-work nil)
    (setq proofread--claimed-requests nil)
    (when proofread--queue-state
      (proofread--clear-request-queue proofread--queue-state))
    (dolist (work works)
      (proofread--forget-request-work work)
      (proofread--record-request-cancellation work)))
  (when (hash-table-p proofread--pending-request-keys)
    (clrhash proofread--pending-request-keys))
  (proofread--cancel-idle-timer)
  (proofread--cancel-queue-dispatch-timer))

(defun proofread--clear-request-work ()
  "Atomically clear this buffer's scheduled and active requests."
  (let ((proofread--clearing-scheduled-work (current-buffer)))
    (proofread--clear-scheduled-work)
    (proofread--cancel-active-requests)))

(defun proofread--idle-timer-run (buffer)
  "Run pending visible proofreading work for BUFFER when still valid."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when proofread-mode
        (let ((run-p (and proofread-auto-check
                          proofread--pending-work)))
          (setq proofread--pending-work nil)
          (setq proofread--idle-timer nil)
          (when run-p
            (proofread-check-visible-range)
            'ran))))))

(defun proofread--schedule-idle-timer ()
  "Schedule an idle timer for pending proofreading work if needed."
  (unless proofread--idle-timer
    (setq proofread--idle-timer
          (run-with-idle-timer
           (max 0 proofread-idle-delay)
           nil
           #'proofread--idle-timer-run
           (current-buffer)))))

(defun proofread--mark-pending-work ()
  "Mark the current buffer as needing scheduled visible proofreading."
  (when (and proofread-mode proofread-auto-check)
    (setq proofread--pending-work t)
    (proofread--schedule-idle-timer)))

(defun proofread--edit-affected-state (beg end)
  "Return state affected by editing from BEG through END.
The car of the result contains overlays in tracked order.  The cdr
contains diagnostics in diagnostic order.  Preserve the identity of
every collected object."
  (let ((edit (cons beg end)))
    (cons
     (cl-remove-if-not
      (lambda (overlay)
        (let ((range (cons (overlay-start overlay)
                           (overlay-end overlay))))
          (proofread--range-affected-by-edit-p range edit)))
      proofread--overlays)
     (cl-remove-if-not
      (lambda (diagnostic)
        (when-let* ((range
                     (proofread--diagnostic-live-range diagnostic)))
          (proofread--range-affected-by-edit-p range edit)))
      proofread--diagnostics))))

(defun proofread--defer-correction-invalidation (beg end)
  "Remember diagnostics affected by a correction-time change.
BEG and END delimit the changed text."
  (proofread--prune-overlays)
  (let ((affected-state (proofread--edit-affected-state beg end)))
    (dolist (overlay (car affected-state))
      (cl-pushnew overlay proofread--deferred-correction-overlays
                  :test #'eq))
    (dolist (diagnostic (cdr affected-state))
      (cl-pushnew diagnostic
                  proofread--deferred-correction-diagnostics
                  :test #'eq))))

(defun proofread--before-change (beg end)
  "Capture diagnostics affected by a change from BEG to END."
  (proofread--invalidate-position-shifted-requests beg)
  (if (proofread--overlay-invalidation-inhibited-p)
      (proofread--defer-correction-invalidation beg end)
    (proofread--prune-overlays)
    (let ((affected-state (proofread--edit-affected-state beg end)))
      (setq proofread--pending-invalidated-overlays
            (car affected-state))
      (setq proofread--pending-invalidated-diagnostics
            (cdr affected-state)))))

(defun proofread--after-change (_beg _end _length)
  "Invalidate changed diagnostics and schedule proofreading."
  (unless (proofread--overlay-invalidation-inhibited-p)
    (let ((changed (or proofread--pending-invalidated-overlays
                       proofread--pending-invalidated-diagnostics)))
      (proofread--invalidate-affected-diagnostics
       proofread--pending-invalidated-overlays
       proofread--pending-invalidated-diagnostics
       t)
      (setq proofread--pending-invalidated-overlays nil)
      (setq proofread--pending-invalidated-diagnostics nil)
      (proofread--synchronize-live-diagnostic-ranges)
      (when changed
        (proofread--run-diagnostics-changed-hook))))
  (proofread--mark-pending-work)
  ;; An edit outside an active target can still stale its saved
  ;; context.  Revisit queued work so such an active request cannot
  ;; hold a slot forever.
  (unless (proofread--request-queue-empty-p)
    (proofread--schedule-queue-dispatch)))

(defun proofread--window-scroll (_window _display-start)
  "Mark the current buffer pending after scroll activity."
  (proofread--mark-pending-work))

(defun proofread--live-mode-buffer-p (buffer)
  "Return non-nil if BUFFER is live and has `proofread-mode' enabled."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         proofread-mode)))

(defun proofread--prune-mode-buffers ()
  "Remove dead or inactive buffers from `proofread--mode-buffers'."
  (let (buffers)
    (dolist (buffer proofread--mode-buffers)
      (when (proofread--live-mode-buffer-p buffer)
        (push buffer buffers)))
    (setq proofread--mode-buffers (nreverse buffers))))

(defun proofread--register-mode-buffer ()
  "Register the current buffer as using `proofread-mode' hooks."
  (setq proofread--mode-buffers
        (delq (current-buffer) proofread--mode-buffers))
  (push (current-buffer) proofread--mode-buffers))

(defun proofread--unregister-mode-buffer ()
  "Unregister the current buffer from `proofread-mode' hooks."
  (setq proofread--mode-buffers
        (delq (current-buffer) proofread--mode-buffers))
  (proofread--prune-mode-buffers))

(defun proofread--kill-buffer ()
  "Clean up Proofread state before killing this buffer."
  (proofread--disable-echo-area)
  (proofread--close-source-list-buffers (current-buffer))
  (proofread--clear-request-work)
  (proofread--unregister-mode-buffer))

;;;; Diagnostics and navigation

(defun proofread--overlay-p (overlay)
  "Return non-nil if OVERLAY is a live proofread-owned overlay."
  (and (overlayp overlay)
       (overlay-buffer overlay)
       (eq (overlay-get overlay 'category)
           proofread--overlay-category)))

(defun proofread--current-buffer-overlay-p (overlay)
  "Return non-nil if this buffer owns proofread OVERLAY."
  (and (proofread--overlay-p overlay)
       (eq (overlay-buffer overlay) (current-buffer))))

(defun proofread--current-buffer-overlays ()
  "Return all live proofread-owned overlays in the current buffer."
  (let ((seen (make-hash-table :test #'eq))
        overlays)
    (save-restriction
      (widen)
      (dolist (overlay (append proofread--overlays
                               (overlays-in (point-min) (point-max))))
        (when (and (proofread--current-buffer-overlay-p overlay)
                   (not (gethash overlay seen)))
          (puthash overlay t seen)
          (push overlay overlays))))
    (nreverse overlays)))

(defun proofread--prune-overlays ()
  "Remove dead or foreign entries from `proofread--overlays'."
  (let (retained)
    (dolist (overlay proofread--overlays)
      (if (proofread--current-buffer-overlay-p overlay)
          (push overlay retained)
        (when (and (overlayp overlay)
                   (hash-table-p proofread--diagnostic-overlays))
          (let ((diagnostic
                 (overlay-get overlay 'proofread-diagnostic)))
            (when (eq (gethash
                       diagnostic proofread--diagnostic-overlays)
                      overlay)
              (remhash diagnostic proofread--diagnostic-overlays))))))
    (setq proofread--overlays (nreverse retained))))

(defun proofread--delete-overlay (overlay)
  "Delete proofread-owned OVERLAY when it is live."
  (when (proofread--overlay-p overlay)
    (when (hash-table-p proofread--diagnostic-overlays)
      (let ((diagnostic (overlay-get overlay 'proofread-diagnostic)))
        (when (eq (gethash diagnostic proofread--diagnostic-overlays)
                  overlay)
          (remhash diagnostic proofread--diagnostic-overlays))))
    (delete-overlay overlay)))

(defun proofread--diagnostic-range (diagnostic)
  "Return DIAGNOSTIC's valid range as a cons cell, or nil."
  (let ((beg (proofread--position-integer
              (plist-get diagnostic :beg)))
        (end (proofread--position-integer
              (plist-get diagnostic :end))))
    (when-let* ((range (cons beg end))
                ((proofread--range-valid-p range)))
      range)))

(defun proofread-diagnostic-range (diagnostic)
  "Return DIAGNOSTIC's current well-formed range, or nil.
Prefer the range tracked by a live proofread overlay in the current
buffer; otherwise return the diagnostic's stored range."
  (or (proofread--diagnostic-live-range diagnostic)
      (proofread--diagnostic-range diagnostic)))

(defun proofread-diagnostic-message (diagnostic)
  "Return DIAGNOSTIC's explanatory message."
  (plist-get diagnostic :message))

(defun proofread-diagnostic-text (diagnostic)
  "Return the text identified by DIAGNOSTIC."
  (plist-get diagnostic :text))

(defun proofread--aggregate-diagnostic-p (diagnostic)
  "Return non-nil when DIAGNOSTIC is a UI aggregate."
  (and (plist-get diagnostic :proofread-aggregate) t))

(defun proofread--diagnostic-members (diagnostic)
  "Return the raw diagnostics represented by DIAGNOSTIC."
  (if (proofread--aggregate-diagnostic-p diagnostic)
      (plist-get diagnostic :diagnostics)
    (list diagnostic)))

(defun proofread-diagnostic-message-entries (diagnostic)
  "Return detached message and backend-source entries for DIAGNOSTIC.
The result contains one property list for every raw diagnostic
represented by DIAGNOSTIC, in presentation order.  Each property list
has `:source' and `:message' keys.  The source is a display string or
nil; prefer the checker-local source label and otherwise use the raw
backend source.  The message retains its original value and may be
nil.  Callers may safely modify the returned records and values."
  (mapcar
   (lambda (member)
     (let ((source (or (plist-get member :source-label)
                       (plist-get member :source))))
       (list :source
             (and source
                  (substring-no-properties
                   (proofread-format-diagnostic-field source)))
             :message
             (proofread--snapshot-value
              (plist-get member :message)))))
   (proofread--diagnostic-members diagnostic)))

(defun proofread--diagnostic-source-label (diagnostic)
  "Return a display label for DIAGNOSTIC's checker or source."
  (let ((checker-name (plist-get diagnostic :checker-name))
        (source (plist-get diagnostic :source)))
    (cond
     (checker-name (proofread-format-diagnostic-field checker-name))
     (source (proofread-format-diagnostic-field source)))))

(defun proofread--diagnostic-source-labels (diagnostic)
  "Return unique source labels for DIAGNOSTIC in display order."
  (delete-dups
   (delq nil
         (mapcar #'proofread--diagnostic-source-label
                 (proofread--diagnostic-members diagnostic)))))

(defun proofread--diagnostic-source-summary (diagnostic)
  "Return a source summary string for DIAGNOSTIC, or nil."
  (when-let* ((labels (proofread--diagnostic-source-labels diagnostic)))
    (string-join labels ", ")))

(defun proofread--diagnostic-message-entries (diagnostic)
  "Return provenance-preserving message entries for DIAGNOSTIC."
  (let (entries)
    (dolist (member (proofread--diagnostic-members diagnostic))
      (when-let* ((message (plist-get member :message)))
        (push (list :source
                    (proofread--diagnostic-source-label member)
                    :message message
                    :diagnostic member)
              entries)))
    (nreverse entries)))

(defun proofread--diagnostic-message-summary (diagnostic)
  "Return a one-line message summary for DIAGNOSTIC."
  (if (proofread--aggregate-diagnostic-p diagnostic)
      (let (messages)
        (dolist (entry (proofread--diagnostic-message-entries
                        diagnostic))
          (let ((source (plist-get entry :source))
                (message
                 (proofread-format-diagnostic-field
                  (plist-get entry :message))))
            (push (if source
                      (format "%s: %s" source message)
                    message)
                  messages)))
        (when messages
          (string-join (nreverse messages) "; ")))
    (plist-get diagnostic :message)))

(defun proofread--diagnostic-suggestion-records (diagnostic)
  "Return deduplicated suggestion records for DIAGNOSTIC.
Each record has the keys `:text', `:sources', and `:diagnostics'."
  (let (records)
    (dolist (member (proofread--diagnostic-members diagnostic))
      (let ((source (proofread--diagnostic-source-label member)))
        (dolist (suggestion (proofread--diagnostic-suggestions member))
          (let ((record
                 (cl-find suggestion records
                          :key (lambda (entry)
                                 (plist-get entry :text))
                          :test #'equal)))
            (if record
                (progn
                  (when (and source
                             (not (member source
                                          (plist-get record :sources))))
                    (setf (plist-get record :sources)
                          (append (plist-get record :sources)
                                  (list source))))
                  (setf (plist-get record :diagnostics)
                        (append (plist-get record :diagnostics)
                                (list member))))
              (push (list :text suggestion
                          :sources (and source (list source))
                          :diagnostics (list member))
                    records))))))
    (nreverse records)))

(defun proofread--diagnostic-aggregate-key (diagnostic beg end)
  "Return the UI aggregate key for DIAGNOSTIC at BEG and END."
  (list beg end (plist-get diagnostic :text)))

(defun proofread--make-aggregate-diagnostic
    (diagnostics beg end)
  "Return a UI aggregate for DIAGNOSTICS covering BEG to END.
DIAGNOSTICS must be in navigation order."
  (let* ((first (car diagnostics))
         (aggregate
          (list :proofread-aggregate t
                :diagnostics diagnostics
                :beg beg
                :end end
                :text (plist-get first :text)
                :kind (plist-get first :kind)
                :target-kind (plist-get first :target-kind))))
    (setq aggregate
          (plist-put
           aggregate :message
           (proofread--diagnostic-message-summary aggregate)))
    (setq aggregate
          (plist-put
           aggregate :suggestions
           (mapcar (lambda (record)
                     (plist-get record :text))
                   (proofread--diagnostic-suggestion-records
                    aggregate))))
    (plist-put aggregate :source
               (proofread--diagnostic-source-labels aggregate))))

(defun proofread--diagnostic-ui-equivalent-p (left right)
  "Return non-nil when LEFT and RIGHT represent the same UI diagnostic."
  (or (eq left right)
      (memq left (proofread--diagnostic-members right))
      (memq right (proofread--diagnostic-members left))))

(defun proofread-format-diagnostic-field (value)
  "Return VALUE formatted as a Proofread diagnostic field.
Return strings unchanged and symbols by name.  Format other values
using their printed representation."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun proofread--format-diagnostic-message-field (value single-line)
  "Return VALUE as a clean diagnostic display field, or nil.
When SINGLE-LINE is non-nil, collapse whitespace to single spaces."
  (when value
    (let* ((field
            (substring-no-properties
             (if (stringp value)
                 value
               (proofread-format-diagnostic-field value))))
           (field (if single-line
                      (string-clean-whitespace field)
                    (string-trim field))))
      (unless (string-empty-p field)
        field))))

(defun proofread--format-diagnostic-message-fallback
    (diagnostic single-line)
  "Return DIAGNOSTIC's fallback message.
When SINGLE-LINE is non-nil, collapse whitespace to single spaces."
  (if-let* ((text
             (proofread--format-diagnostic-message-field
              (proofread-diagnostic-text diagnostic) single-line)))
      (concat "Proofread: " text)
    "Proofread diagnostic"))

(defun proofread--format-diagnostic-message-entry
    (entry fallback-function source-face message-face single-line)
  "Format diagnostic message ENTRY using FALLBACK-FUNCTION.
Apply SOURCE-FACE to the source and MESSAGE-FACE to the message.  When
SINGLE-LINE is non-nil, collapse field whitespace to single spaces."
  (let* ((source
          (proofread--format-diagnostic-message-field
           (plist-get entry :source) single-line))
         (message
          (or (proofread--format-diagnostic-message-field
               (plist-get entry :message) single-line)
              (funcall fallback-function)))
         (source-prefix
          (and source
               (if source-face
                   (propertize (concat source ":")
                               'face source-face)
                 (concat source ":")))))
    (concat source-prefix
            (and source-prefix " ")
            (if message-face
                (propertize message 'face message-face)
              message))))

(cl-defun proofread-format-diagnostic-message
    (diagnostic &key (separator "\n") source-face message-face single-line)
  "Return a source-aware display message for DIAGNOSTIC.
Format each represented diagnostic as `SOURCE: MESSAGE' in
presentation order, joining entries with SEPARATOR.  SOURCE-FACE is
applied to the source and colon; MESSAGE-FACE is applied only to the
message.  The intervening space and SEPARATOR remain unpropertized.

Blank or missing messages fall back to DIAGNOSTIC's text, or to a
generic diagnostic label when no text is available.  Input text
properties are not retained.  When SINGLE-LINE is non-nil, collapse
whitespace inside each field to single spaces."
  (let ((separator (substring-no-properties separator))
        (entries (proofread-diagnostic-message-entries diagnostic))
        fallback)
    (cl-labels
        ((fallback
           ()
           (or fallback
               (setq fallback
                     (proofread--format-diagnostic-message-fallback
                      diagnostic single-line)))))
      (if entries
          (mapconcat
           (lambda (entry)
             (proofread--format-diagnostic-message-entry
              entry #'fallback source-face message-face single-line))
           entries separator)
        (if message-face
            (propertize (fallback) 'face message-face)
          (fallback))))))

(defun proofread--navigation-entry< (a b)
  "Return non-nil when navigation entry A should sort before B."
  (let ((a-beg (nth 1 a))
        (b-beg (nth 1 b))
        (a-end (nth 2 a))
        (b-end (nth 2 b))
        (a-index (nth 3 a))
        (b-index (nth 3 b))
        (a-ordinal
         (plist-get (car a) :checker-ordinal))
        (b-ordinal
         (plist-get (car b) :checker-ordinal)))
    (cond
     ((< a-beg b-beg) t)
     ((> a-beg b-beg) nil)
     ((< a-end b-end) t)
     ((> a-end b-end) nil)
     ((and (natnump a-ordinal) (natnump b-ordinal)
           (< a-ordinal b-ordinal))
      t)
     ((and (natnump a-ordinal) (natnump b-ordinal)
           (> a-ordinal b-ordinal))
      nil)
     ((and (natnump a-ordinal) (not (natnump b-ordinal))) t)
     ((and (natnump b-ordinal) (not (natnump a-ordinal))) nil)
     (t (< a-index b-index)))))

(defun proofread--raw-navigation-entries (&optional accessible-only)
  "Return sorted entries for live raw diagnostics in the current buffer.
When ACCESSIBLE-ONLY is non-nil, omit ranges outside the current
restriction."
  (let ((index 0)
        entries)
    (dolist (diagnostic proofread--diagnostics)
      (let ((range (proofread--diagnostic-live-range diagnostic)))
        (when (and range
                   (or (not accessible-only)
                       (and (<= (point-min) (car range))
                            (<= (cdr range) (point-max)))))
          (push (list diagnostic (car range) (cdr range) index)
                entries)))
      (setq index (1+ index)))
    (sort entries #'proofread--navigation-entry<)))

(defun proofread--aggregate-navigation-entries (entries)
  "Return UI-aggregated navigation ENTRIES."
  (let ((groups (make-hash-table :test #'equal))
        ordered-groups)
    (dolist (entry entries)
      (let* ((diagnostic (car entry))
             (beg (nth 1 entry))
             (end (nth 2 entry))
             (index (nth 3 entry))
             (key (proofread--diagnostic-aggregate-key
                   diagnostic beg end))
             (group (gethash key groups)))
        (unless group
          (setq group (list :beg beg
                            :end end
                            :index index
                            :diagnostics nil))
          (puthash key group groups)
          (setq ordered-groups (append ordered-groups
                                       (list group))))
        (setf (plist-get group :diagnostics)
              (append (plist-get group :diagnostics)
                      (list diagnostic)))))
    (mapcar
     (lambda (group)
       (let* ((diagnostics (plist-get group :diagnostics))
              (diagnostic
               (if (cdr diagnostics)
                   (proofread--make-aggregate-diagnostic
                    diagnostics
                    (plist-get group :beg)
                    (plist-get group :end))
                 (car diagnostics))))
         (list diagnostic
               (plist-get group :beg)
               (plist-get group :end)
               (plist-get group :index))))
     ordered-groups)))

(defun proofread--navigation-entries (&optional accessible-only)
  "Return sorted UI diagnostics for navigation.
When ACCESSIBLE-ONLY is non-nil, omit ranges outside the current
restriction.  Diagnostics with the same live range and text are
returned as one aggregate entry."
  (proofread--aggregate-navigation-entries
   (proofread--raw-navigation-entries accessible-only)))

(defun proofread--navigation-diagnostics (&optional accessible-only)
  "Return live diagnostics sorted for navigation.
When ACCESSIBLE-ONLY is non-nil, omit ranges outside the current
restriction."
  (mapcar #'car (proofread--navigation-entries accessible-only)))

(defun proofread--navigation-entry-for-diagnostic
    (diagnostic entries)
  "Return DIAGNOSTIC's UI-equivalent entry from ENTRIES."
  (cl-find-if
   (lambda (entry)
     (proofread--diagnostic-ui-equivalent-p
      (car entry) diagnostic))
   entries))

(defun proofread--diagnostic-ignore-key (diagnostic)
  "Return the session ignore key for DIAGNOSTIC."
  (list :language
        (proofread--snapshot-value
         (if (plist-member diagnostic :language)
             (plist-get diagnostic :language)
           (proofread--current-profile-language)))
        :text (plist-get diagnostic :text)
        :kind (plist-get diagnostic :kind)
        :message (plist-get diagnostic :message)
        :source (plist-get diagnostic :source)))

(defun proofread--ensure-ignored-diagnostics ()
  "Return the session ignore table for proofread diagnostics."
  (unless (hash-table-p proofread--ignored-diagnostics)
    (setq proofread--ignored-diagnostics
          (make-hash-table :test #'equal)))
  proofread--ignored-diagnostics)

(defun proofread--ignore-key-p (key)
  "Return non-nil when KEY is recorded as ignored this session."
  (gethash key (proofread--ensure-ignored-diagnostics)))

(defun proofread--diagnostic-ignored-p (diagnostic)
  "Return non-nil when DIAGNOSTIC is ignored this session."
  (proofread--ignore-key-p
   (proofread--diagnostic-ignore-key diagnostic)))

(defun proofread--record-ignored-diagnostic (diagnostic)
  "Record DIAGNOSTIC as ignored for the current Emacs session."
  (let ((key (proofread--diagnostic-ignore-key diagnostic)))
    (puthash key t (proofread--ensure-ignored-diagnostics))
    key))

(defun proofread--filter-ignored-diagnostics (diagnostics)
  "Return DIAGNOSTICS without session-ignored entries."
  (delq nil
        (mapcar (lambda (diagnostic)
                  (unless (proofread--diagnostic-ignored-p diagnostic)
                    diagnostic))
                diagnostics)))

(defun proofread--diagnostic-matches-ignore-key-p (diagnostic key)
  "Return non-nil when DIAGNOSTIC matches ignore KEY."
  (equal (proofread--diagnostic-ignore-key diagnostic) key))

(defun proofread--diagnostics-matching-ignore-key (key)
  "Return current buffer diagnostics matching ignore KEY."
  (let (diagnostics)
    (dolist (diagnostic proofread--diagnostics)
      (when (proofread--diagnostic-matches-ignore-key-p
             diagnostic key)
        (push diagnostic diagnostics)))
    (nreverse diagnostics)))

(defun proofread--delete-overlays-matching-ignore-key (key)
  "Delete proofread-owned overlays matching ignore KEY."
  (proofread--prune-overlays)
  (dolist (overlay proofread--overlays)
    (let ((diagnostic (overlay-get overlay 'proofread-diagnostic)))
      (when (and diagnostic
                 (proofread--diagnostic-matches-ignore-key-p
                  diagnostic key))
        (proofread--delete-overlay overlay))))
  (proofread--prune-overlays))

(defun proofread--remove-local-diagnostics-matching-ignore-key (key)
  "Remove this buffer's diagnostics and overlays matching KEY."
  (let ((diagnostics
         (proofread--diagnostics-matching-ignore-key key)))
    (proofread--delete-overlays-matching-ignore-key key)
    (proofread--remove-diagnostics diagnostics)
    (when (and proofread--current-diagnostic
               (cl-some
                (lambda (diagnostic)
                  (proofread--diagnostic-matches-ignore-key-p
                   diagnostic key))
                (proofread--diagnostic-members
                 proofread--current-diagnostic)))
      (setq proofread--current-diagnostic nil))
    (when diagnostics
      (proofread--run-diagnostics-changed-hook))
    diagnostics))

(defun proofread--remove-diagnostics-matching-ignore-key (key)
  "Remove diagnostics matching ignore KEY from all Proofread buffers."
  (let (removed)
    (proofread--prune-mode-buffers)
    (dolist (buffer proofread--mode-buffers)
      (with-current-buffer buffer
        (setq
         removed
         (nconc
          removed
          (proofread--remove-local-diagnostics-matching-ignore-key
           key)))))
    removed))

(defun proofread--next-diagnostic-after (position)
  "Return the nearest diagnostic strictly after POSITION."
  (let* ((entries (proofread--navigation-entries t))
         (point-position (proofread--position-integer position))
         (candidate
          (and proofread--current-diagnostic
               (proofread--navigation-entry-for-diagnostic
                proofread--current-diagnostic entries)))
         (current (and candidate point-position
                       (proofread--range-covers-position-p
                        (cons (nth 1 candidate) (nth 2 candidate))
                        point-position)
                       candidate)))
    (if current
        (car (cadr (memq current entries)))
      (when point-position
        (car (cl-find-if (lambda (entry)
                           (> (nth 1 entry) point-position))
                         entries))))))

(defun proofread--previous-diagnostic-before (position)
  "Return the nearest diagnostic strictly before POSITION."
  (let* ((entries (proofread--navigation-entries t))
         (point-position (proofread--position-integer position))
         (candidate
          (and proofread--current-diagnostic
               (proofread--navigation-entry-for-diagnostic
                proofread--current-diagnostic entries)))
         (current (and candidate point-position
                       (proofread--range-covers-position-p
                        (cons (nth 1 candidate) (nth 2 candidate))
                        point-position)
                       candidate))
         previous)
    (if current
        (catch 'current
          (dolist (entry entries)
            (when (eq entry current)
              (throw 'current previous))
            (setq previous (car entry)))
          previous)
      (when point-position
        (dolist (entry entries)
          (when (< (nth 1 entry) point-position)
            (setq previous (car entry))))
        previous))))

(defun proofread--clear-current-diagnostic ()
  "Clear the current diagnostic and its highlight face."
  (when proofread--current-diagnostic
    (dolist (overlay
             (proofread--overlays-for-diagnostic
              proofread--current-diagnostic))
      (overlay-put overlay 'face 'proofread-face)))
  (setq proofread--current-diagnostic nil))

(defun proofread--overlay-for-diagnostic (diagnostic)
  "Return this buffer's proofread overlay for DIAGNOSTIC."
  (let ((overlay
         (and (hash-table-p proofread--diagnostic-overlays)
              (gethash diagnostic proofread--diagnostic-overlays))))
    (if (and (proofread--current-buffer-overlay-p overlay)
             (eq (overlay-get overlay 'proofread-diagnostic)
                 diagnostic))
        overlay
      (when (and overlay
                 (hash-table-p proofread--diagnostic-overlays))
        (remhash diagnostic proofread--diagnostic-overlays))
      nil)))

(defun proofread--overlays-for-diagnostic (diagnostic)
  "Return this buffer's proofread overlays for DIAGNOSTIC."
  (delq nil
        (mapcar #'proofread--overlay-for-diagnostic
                (proofread--diagnostic-members diagnostic))))

(defun proofread--local-navigation-entry (overlay position)
  "Return OVERLAY's navigation entry when it covers POSITION.
Return nil unless OVERLAY is the canonical live overlay for its raw
diagnostic in the current buffer."
  (when (proofread--current-buffer-overlay-p overlay)
    (let ((diagnostic
           (overlay-get overlay 'proofread-diagnostic))
          (beg (overlay-start overlay))
          (end (overlay-end overlay))
          (insertion-ordinal
           (overlay-get
            overlay 'proofread-diagnostic-insertion-ordinal)))
      (when (and (hash-table-p proofread--diagnostic-overlays)
                 (eq (gethash diagnostic
                              proofread--diagnostic-overlays)
                     overlay)
                 beg end
                 (natnump insertion-ordinal)
                 (proofread--range-covers-position-p
                  (cons beg end) position))
        (list diagnostic beg end insertion-ordinal)))))

(defun proofread--local-navigation-entries-at (position)
  "Return sorted live navigation entries covering POSITION."
  (let ((seen (make-hash-table :test #'eq))
        entries)
    ;; `overlays-at' includes ordinary overlays at their front
    ;; boundary; an empty `overlays-in' query additionally finds
    ;; zero-width ones.  Ordinary overlays may occur in both results.
    (dolist (overlay
             (append (overlays-at position)
                     (overlays-in position position)))
      (unless (gethash overlay seen)
        (puthash overlay t seen)
        (when-let* ((entry
                     (proofread--local-navigation-entry
                      overlay position)))
          (push entry entries))))
    (sort entries #'proofread--navigation-entry<)))

(defun proofread--aggregate-local-navigation-entry (entry entries)
  "Return the UI diagnostic for winning local ENTRY among ENTRIES."
  (let* ((diagnostic (car entry))
         (beg (nth 1 entry))
         (end (nth 2 entry))
         (key (proofread--diagnostic-aggregate-key
               diagnostic beg end))
         diagnostics)
    (dolist (candidate-entry entries)
      (let ((candidate (car candidate-entry)))
        (when (equal
               key
               (proofread--diagnostic-aggregate-key
                candidate
                (nth 1 candidate-entry)
                (nth 2 candidate-entry)))
          (push candidate diagnostics))))
    (setq diagnostics (nreverse diagnostics))
    (if (cdr diagnostics)
        (proofread--make-aggregate-diagnostic diagnostics beg end)
      diagnostic)))

(defun proofread-diagnostic-at-point (&optional position)
  "Return the live proofreading diagnostic at POSITION or point.
A diagnostic is live only while its proofread-owned overlay exists in
the current buffer.  An aggregate may be freshly allocated on every
call, so callers must not rely on `eq' identity across calls.  Compare
values from `proofread-diagnostic-range',
`proofread-diagnostic-message', `proofread-diagnostic-message-entries',
and `proofread-diagnostic-text' instead."
  (when-let* ((point-position
               (proofread--position-integer (or position (point)))))
    (save-restriction
      (widen)
      (when (and (<= (point-min) point-position)
                 (<= point-position (point-max)))
        (when-let* ((entries
                     (proofread--local-navigation-entries-at
                      point-position)))
          (proofread--aggregate-local-navigation-entry
           (car entries) entries))))))

(defun proofread--echo-area-message (diagnostic)
  "Return the echo-area message for DIAGNOSTIC."
  (let ((message
         (proofread-format-diagnostic-message
          diagnostic
          :separator "; "
          :source-face 'proofread-echo-area-source-face
          :message-face 'proofread-echo-area-message-face
          :single-line t)))
    (add-text-properties
     0 (length message)
     (list 'proofread--echo-area-message (current-buffer))
     message)
    message))

(defun proofread--eldoc-function (callback &rest _ignored)
  "Report the Proofread diagnostic at point through CALLBACK."
  (when (and proofread-mode proofread-echo-area-messages)
    (when-let* ((diagnostic (proofread-diagnostic-at-point))
                (message (proofread--echo-area-message diagnostic)))
      (funcall callback message :echo message))))

(defun proofread--echo-area-owned-message-p (message)
  "Return non-nil when this buffer owns Proofread MESSAGE."
  (and (stringp message)
       (> (length message) 0)
       (text-property-any
        0 (length message)
        'proofread--echo-area-message (current-buffer) message)))

(defun proofread--echo-area-refresh-permitted-p (&optional after-command)
  "Return non-nil when Proofread may refresh the echo area now.
When AFTER-COMMAND is non-nil, do not treat `this-command' as an
in-progress command."
  (and eldoc-mode
       (or after-command (null this-command))
       (eq (window-buffer (selected-window)) (current-buffer))
       (not (active-minibuffer-window))
       (eldoc-display-message-no-interference-p)
       (let ((current (current-message)))
         (or (null current)
             (proofread--echo-area-owned-message-p current)))))

(defun proofread--echo-area-clear-current-message ()
  "Forget ElDoc state owned by Proofread in the current buffer."
  (when (proofread--echo-area-owned-message-p (current-message))
    (eldoc-display-in-echo-area nil t))
  (when (proofread--echo-area-owned-message-p eldoc-last-message)
    (setq eldoc-last-message nil)))

(defun proofread--configure-echo-area (enabled)
  "Configure Proofread's echo-area integration for ENABLED."
  (if enabled
      (unless eldoc-mode
        (eldoc-mode 1)
        (setq proofread--eldoc-mode-owned-p (and eldoc-mode t)))
    (proofread--cancel-echo-area-refresh)
    (proofread--echo-area-clear-current-message)
    (when proofread--eldoc-mode-owned-p
      (setq proofread--eldoc-mode-owned-p nil)
      (when eldoc-mode
        (eldoc-mode -1)))))

(defun proofread--display-echo-area-message (message)
  "Display Proofread MESSAGE through ElDoc's echo-area frontend."
  (eldoc-display-in-echo-area
   (list
    (list message
          :origin #'proofread--eldoc-function
          :echo message))
   t))

(defun proofread--refresh-echo-area-now (&optional after-command)
  "Refresh Proofread's echo-area message when permitted.
When AFTER-COMMAND is non-nil, the command has finished and may no
longer be treated as in progress.  Return non-nil when the refresh
gate permitted an update."
  (when (proofread--echo-area-refresh-permitted-p after-command)
    (if-let* ((diagnostic
               (and proofread-mode
                    proofread-echo-area-messages
                    (proofread-diagnostic-at-point)))
              (message (proofread--echo-area-message diagnostic)))
        (proofread--display-echo-area-message message)
      (proofread--echo-area-clear-current-message))
    t))

(defun proofread--cancel-echo-area-refresh ()
  "Cancel a pending Proofread echo-area refresh."
  (setq proofread--echo-area-refresh-pending-p nil)
  (remove-hook 'post-command-hook
               #'proofread--retry-echo-area-refresh t))

(defun proofread--retry-echo-area-refresh ()
  "Retry a guarded Proofread echo-area refresh after a command."
  (cond
   ((not (and proofread-mode
              proofread-echo-area-messages
              eldoc-mode))
    (proofread--cancel-echo-area-refresh))
   ((proofread--refresh-echo-area-now t)
    (proofread--cancel-echo-area-refresh))))

(defun proofread--queue-echo-area-refresh ()
  "Retry Proofread's echo-area refresh after the next safe command."
  (setq proofread--echo-area-refresh-pending-p t)
  (add-hook 'post-command-hook
            #'proofread--retry-echo-area-refresh nil t))

(defun proofread--refresh-echo-area ()
  "Refresh Proofread's ElDoc message after diagnostics change."
  (cond
   ((not (and proofread-mode
              proofread-echo-area-messages
              eldoc-mode))
    (proofread--cancel-echo-area-refresh))
   ((proofread--refresh-echo-area-now)
    (proofread--cancel-echo-area-refresh))
   (t
    (proofread--queue-echo-area-refresh))))

(defun proofread--enable-echo-area ()
  "Enable Proofread's echo-area integration in the current buffer."
  (add-hook 'eldoc-documentation-functions
            #'proofread--eldoc-function nil t)
  (add-hook 'proofread-diagnostics-changed-hook
            #'proofread--refresh-echo-area nil t)
  (proofread--configure-echo-area proofread-echo-area-messages))

(defun proofread--disable-echo-area ()
  "Disable Proofread's echo-area integration in the current buffer."
  (proofread--cancel-echo-area-refresh)
  (remove-hook 'proofread-diagnostics-changed-hook
               #'proofread--refresh-echo-area t)
  (remove-hook 'eldoc-documentation-functions
               #'proofread--eldoc-function t)
  (proofread--echo-area-clear-current-message)
  (when proofread--eldoc-mode-owned-p
    (setq proofread--eldoc-mode-owned-p nil)
    (when eldoc-mode
      (eldoc-mode -1))))

(defun proofread--configure-echo-area-in-buffer (buffer enabled)
  "Configure Proofread echo display in BUFFER for ENABLED."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when proofread-mode
        (proofread--configure-echo-area enabled)))))

(defun proofread--configure-default-echo-area (symbol enabled)
  "Configure non-local SYMBOL users for default value ENABLED."
  (dolist (buffer (copy-sequence proofread--mode-buffers))
    (when (and (buffer-live-p buffer)
               (not (local-variable-p symbol buffer)))
      (proofread--configure-echo-area-in-buffer buffer enabled))))

(defun proofread--echo-area-option-watcher
    (symbol value operation where)
  "Synchronize echo display when SYMBOL receives VALUE.
OPERATION describes the variable change, and WHERE is its buffer or
nil for a change to the default."
  (pcase operation
    ((or 'set 'let 'unlet)
     (if (and (buffer-live-p where)
              (or (eq operation 'set)
                  (local-variable-p symbol where)))
         (proofread--configure-echo-area-in-buffer where value)
       ;; A dynamic binding of the default may report the buffer that
       ;; initiated it even though that buffer has no local value.
       (unless (equal value (default-value symbol))
         (proofread--configure-default-echo-area symbol value))))
    ('makunbound
     (when (buffer-live-p where)
       ;; `kill-local-variable' reports nil as VALUE before exposing
       ;; the default value, so synchronize to that default directly.
       (proofread--configure-echo-area-in-buffer
        where (default-value symbol))))))

(defun proofread--mark-current-diagnostic (diagnostic)
  "Mark DIAGNOSTIC current and update its overlay face."
  (proofread--clear-current-diagnostic)
  (setq proofread--current-diagnostic diagnostic)
  (dolist (overlay (proofread--overlays-for-diagnostic diagnostic))
    (overlay-put overlay 'face 'proofread-current-face))
  diagnostic)

;;;; Request listings

(defun proofread--request-log-ensure-records ()
  "Return the current buffer's proofread request record table."
  (unless (hash-table-p proofread--request-log-records)
    (setq proofread--request-log-records
          (make-hash-table :test #'equal)))
  proofread--request-log-records)

(defun proofread--request-log-event-request (event)
  "Return the proofread request stored in EVENT."
  (or (plist-get event :request)
      (plist-get (plist-get event :result) :request)))

(defun proofread--request-log-event-key (event)
  "Return the request record key for EVENT."
  (let ((request (proofread--request-log-event-request event)))
    (or (plist-get event :log-id)
        (plist-get event :request-id)
        (plist-get request :id))))

(defun proofread--request-log-plist-push (plist property value)
  "Return PLIST with VALUE prepended to list PROPERTY."
  (plist-put plist property
             (cons value (plist-get plist property))))

(defun proofread--request-log-record-status (type event)
  "Return the request status implied by event TYPE and EVENT."
  (pcase type
    ('chunk-request 'ready)
    ('queued-request 'queued)
    ('active-request 'waiting)
    ('backend-dispatched 'waiting)
    ('backend-request 'waiting)
    ('backend-response 'returned)
    ('backend-result
     (if (eq (plist-get (plist-get event :result) :status) 'error)
         'error
       'parsed))
    ('cache-hit 'cache)
    ('cancelled 'cancelled)
    ('final-result (plist-get event :status))
    ('checker-dispatch-failed 'error)
    (_ nil)))

(defun proofread--request-log-record-request-fields
    (record request event)
  "Update RECORD with REQUEST and range data from EVENT."
  (let ((request (or request (plist-get record :request))))
    (when request
      (setq record (plist-put record :request request)))
    (dolist (property '( :log-id :request-id :buffer :beg :end))
      (when (plist-member event property)
        (setq record
              (plist-put record property
                         (plist-get event property)))))
    record))

(defun proofread--request-log-apply-event (record event)
  "Return RECORD updated with canonical request lifecycle EVENT."
  (let* ((type (plist-get event :type))
         (time (plist-get event :time))
         (request (proofread--request-log-event-request event))
         (status (proofread--request-log-record-status type event)))
    (setq record (proofread--request-log-record-request-fields
                  record request event))
    (unless (plist-get record :created-at)
      (setq record (plist-put record :created-at time)))
    (setq record (plist-put record :updated-at time))
    (setq record
          (proofread--request-log-plist-push
           record :events event))
    (when status
      (setq record (plist-put record :status status)))
    (pcase type
      ('chunk-request
       (setq record
             (plist-put record :chunk
                        (plist-get event :chunk))))
      ('backend-request
       (setq record
             (proofread--request-log-plist-push
              record :backend-requests event)))
      ('backend-response
       (setq record
             (proofread--request-log-plist-push
              record :backend-responses event)))
      ('backend-result
       (setq record
             (proofread--request-log-plist-push
              record :backend-results (plist-get event :result))))
      ('cache-hit
       (setq record (plist-put record :cache-entry
                               (plist-get event :entry))))
      ('final-result
       (setq record (plist-put record :final-status
                               (plist-get event :status)))
       (setq record (plist-put record :final-result
                               (plist-get event :result))))
      ('checker-dispatch-failed
       (dolist (property
                '( :profile :checker-name :backend :phase
                   :error :message))
         (setq record
               (plist-put record property
                          (plist-get event property))))))
    record))

(defun proofread--request-log-copy-record (record)
  "Return a detached public copy of canonical request RECORD."
  (when (proper-list-p record)
    (let ((copy (proofread--request-log-copy-safe-value record)))
      (dolist (property proofread--request-log-history-properties)
        (when (plist-member copy property)
          (setq copy
                (plist-put copy property
                           (nreverse (plist-get copy property))))))
      copy)))

(defun proofread--request-log-source-enabled-p (source)
  "Return non-nil when SOURCE records proofread request events."
  (and (buffer-live-p source)
       (with-current-buffer source
         proofread--request-log-enabled)))

(defun proofread--request-log-record-canonical-event (event)
  "Record canonical EVENT when its source buffer is monitored."
  (let ((source (plist-get event :buffer))
        (key (proofread--request-log-event-key event)))
    (when (and key (proofread--request-log-source-enabled-p source))
      (with-current-buffer source
        (let* ((records (proofread--request-log-ensure-records))
               (record (or (gethash key records)
                           (list :key key
                                 :source-buffer source))))
          (setq record
                (proofread--request-log-apply-event record event))
          (puthash key record records)
          (unless (member key proofread--request-log-order)
            (setq proofread--request-log-order
                  (append proofread--request-log-order (list key))))
          (let ((limit (max 0 proofread-request-log-max-records)))
            (while (> (length proofread--request-log-order) limit)
              (remhash (pop proofread--request-log-order) records))))
        (proofread--schedule-request-log-refresh)))))

(defun proofread--request-log-record-event (raw-event)
  "Safely record RAW-EVENT when its source buffer is monitored."
  (let ((event (proofread--request-log-safe-event raw-event)))
    (proofread--request-log-record-canonical-event event)
    (proofread--request-log-copy-safe-value event)))

(defun proofread--request-log-record-list (&optional source)
  "Return proofread request records for SOURCE or the current buffer."
  (with-current-buffer (or source (current-buffer))
    (mapcar
     #'proofread--request-log-copy-record
     (sort
      (hash-table-values (proofread--request-log-ensure-records))
      (lambda (a b)
        (< (or (plist-get a :log-id)
               (plist-get a :request-id)
               0)
           (or (plist-get b :log-id)
               (plist-get b :request-id)
               0)))))))

(defun proofread--request-log-lookup-record (source key)
  "Return request record KEY from SOURCE."
  (when (buffer-live-p source)
    (with-current-buffer source
      (and (hash-table-p proofread--request-log-records)
           (proofread--request-log-copy-record
            (gethash key proofread--request-log-records))))))

(defun proofread--request-log-source-range-valid-p (source beg end)
  "Return non-nil when BEG to END is valid in SOURCE."
  (and (buffer-live-p source)
       (with-current-buffer source
         (save-restriction
           (widen)
           (let ((range (cons beg end)))
             (and (proofread--range-valid-p range)
                  (proofread--range-contains-p
                   (cons (point-min) (point-max)) range)))))))

(defun proofread--request-log-record-range (record)
  "Return RECORD's source range as a cons cell, or nil."
  (let ((beg (proofread--position-integer (plist-get record :beg)))
        (end (proofread--position-integer (plist-get record :end))))
    (when (and beg end)
      (cons beg end))))

(defun proofread--request-log-record-line-column (record)
  "Return RECORD's source line and zero-based display column."
  (let* ((source (plist-get record :source-buffer))
         (range (proofread--request-log-record-range record))
         (beg (car-safe range))
         (end (cdr-safe range)))
    (when (proofread--request-log-source-range-valid-p source beg end)
      (with-current-buffer source
        (save-restriction
          (widen)
          (save-excursion
            (goto-char beg)
            (cons (line-number-at-pos)
                  (current-column))))))))

(defun proofread--request-log-record-current-text (record)
  "Return RECORD's current source text, or nil when stale."
  (let* ((source (plist-get record :source-buffer))
         (range (proofread--request-log-record-range record))
         (beg (car-safe range))
         (end (cdr-safe range)))
    (when (proofread--request-log-source-range-valid-p source beg end)
      (with-current-buffer source
        (save-restriction
          (widen)
          (buffer-substring-no-properties beg end))))))

(defun proofread--request-log-format-time (time)
  "Return TIME formatted for request lists."
  (if time
      (format-time-string "%T" time)
    "-"))

(defun proofread--format-list-field (value &optional width)
  "Return VALUE as a one-line string, optionally limited to WIDTH."
  (let* ((text (cond
                ((null value) "-")
                ((stringp value) value)
                ((symbolp value) (symbol-name value))
                (t (format "%S" value))))
         (single-line (string-clean-whitespace text)))
    (if (and width (> (string-width single-line) width))
        (truncate-string-to-width single-line width nil nil "...")
      single-line)))

(defun proofread--request-log-backend-label (record)
  "Return a short backend label for RECORD."
  (let* ((request (plist-get record :request))
         (backend (or (plist-get request :backend)
                      (plist-get record :backend))))
    (if backend
        (proofread--format-list-field backend 10)
      "-")))

(defun proofread--request-log-record-entry (record)
  "Return a tabulated list entry for request RECORD."
  (let* ((line-column
          (proofread--request-log-record-line-column record))
         (raw-line (car-safe line-column))
         (raw-column (cdr-safe line-column))
         (line (or raw-line 0))
         (column (or raw-column 0))
         (range (proofread--request-log-record-range record))
         (entry-id (list :source-buffer
                         (plist-get record :source-buffer)
                         :key (plist-get record :key)
                         :line line
                         :column column)))
    (list
     entry-id
     (vector
      (proofread--format-list-field
       (or (plist-get record :request-id)
           (plist-get record :log-id)))
      (proofread--format-list-field (plist-get record :status))
      (proofread--request-log-format-time
       (plist-get record :updated-at))
      (if raw-line (number-to-string raw-line) "-")
      (if raw-column (number-to-string raw-column) "-")
      (if range
          (format "%d-%d" (car range) (cdr range))
        "-")
      (proofread--request-log-backend-label record)
      (proofread--format-list-field
       (or (plist-get (plist-get record :request) :text)
           (proofread--request-log-record-current-text record))
       90)))))

(defun proofread--request-log-list-refresh ()
  "Refresh the current proofread requests buffer."
  (setq tabulated-list-format proofread--request-log-list-format)
  (setq tabulated-list-entries
        (and (buffer-live-p proofread--request-log-list-source)
             (mapcar #'proofread--request-log-record-entry
                     (proofread--request-log-record-list
                      proofread--request-log-list-source))))
  (tabulated-list-init-header)
  (tabulated-list-print t))

(defun proofread--request-log-list-setup ()
  "Set up the current proofread requests buffer."
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (proofread--request-log-list-refresh)))
  (add-hook 'kill-buffer-hook
            #'proofread--request-log-list-cleanup nil t)
  (add-hook 'change-major-mode-hook
            #'proofread--request-log-list-cleanup nil t)
  (setq tabulated-list-sort-key (cons "Id" nil)))

(define-derived-mode proofread-requests-buffer-mode
  tabulated-list-mode
  "Proofread requests"
  "A mode for listing Proofread backend requests."
  :interactive nil
  (proofread--request-log-list-setup))

(defun proofread--request-log-list-buffer-name (source)
  "Return the request list buffer name for SOURCE."
  (format "*Proofread requests for `%s'*" (buffer-name source)))

(defun proofread--request-log-request-buffer-name (record)
  "Return the request detail buffer name for RECORD."
  (let ((source (plist-get record :source-buffer)))
    (format "*Proofread request %s for `%s'*"
            (or (plist-get record :request-id)
                (plist-get record :log-id)
                "?")
            (if (buffer-live-p source)
                (buffer-name source)
              "dead buffer"))))

(defun proofread--fit-list-window (window)
  "Fit proofread list WINDOW to its buffer."
  (fit-window-to-buffer window 15 8))

(defun proofread--request-log-seed-active-requests (source)
  "Record active requests already present in SOURCE."
  (with-current-buffer source
    (dolist (work proofread--active-requests)
      (let ((request (proofread--scheduled-work-request work)))
        (proofread--request-log-record-event
         (list :type 'active-request
               :time (current-time)
               :log-id (proofread--scheduled-work-log-id work)
               :request-id (plist-get request :id)
               :buffer source
               :beg (plist-get request :beg)
               :end (plist-get request :end)
               :request request))))))

(defun proofread--request-log-seed-queued-requests (source)
  "Record queued requests already present in SOURCE."
  (with-current-buffer source
    (dolist (entry (proofread--request-queue-entries))
      (let* ((work (proofread--queue-entry-work entry))
             (request (proofread--scheduled-work-request work)))
        (proofread--request-log-record-event
         (list :type 'queued-request
               :time (current-time)
               :log-id (proofread--scheduled-work-log-id work)
               :request-id (plist-get request :id)
               :buffer source
               :beg (plist-get request :beg)
               :end (plist-get request :end)
               :request request
               :backend (proofread--scheduled-work-backend work)))))))

(defun proofread--install-source-list-cleanup ()
  "Install lifecycle cleanup for lists owned by the current source."
  (add-hook 'kill-buffer-hook #'proofread--source-list-cleanup nil t)
  (add-hook 'change-major-mode-hook
            #'proofread--source-list-cleanup nil t))

(defun proofread--uninstall-source-list-cleanup-if-unused ()
  "Remove source cleanup when the current buffer owns no live lists."
  (unless (or proofread--request-log-list-buffers
              proofread--diagnostics-list-buffers)
    (remove-hook 'kill-buffer-hook #'proofread--source-list-cleanup t)
    (remove-hook 'change-major-mode-hook
                 #'proofread--source-list-cleanup t)))

(defun proofread--source-list-cleanup ()
  "Close auxiliary lists before their source loses local state."
  (proofread--close-source-list-buffers (current-buffer)))

(defun proofread--request-log-enable-source (source)
  "Enable proofread request recording for SOURCE."
  (let (newly-enabled)
    (with-current-buffer source
      (setq newly-enabled (not proofread--request-log-enabled))
      (setq proofread--request-log-enabled t)
      (proofread--request-log-ensure-records)
      (proofread--install-source-list-cleanup))
    (cl-pushnew source proofread--request-log-sources)
    (when newly-enabled
      (proofread--request-log-seed-active-requests source)
      (proofread--request-log-seed-queued-requests source))))

(defun proofread--prune-request-log-sources ()
  "Remove sources that no longer record request events."
  (setq proofread--request-log-sources
        (cl-remove-if-not #'proofread--request-log-source-enabled-p
                          proofread--request-log-sources)))

(defun proofread--request-log-disable-source (source)
  "Stop recording proofread request events for SOURCE."
  (when (buffer-live-p source)
    (with-current-buffer source
      (setq proofread--request-log-enabled nil)
      (proofread--cancel-request-log-refresh-timer)
      (proofread--uninstall-source-list-cleanup-if-unused)))
  (setq proofread--request-log-sources
        (delq source proofread--request-log-sources))
  (proofread--prune-request-log-sources))

(defun proofread--request-log-list-buffer-p (buffer source)
  "Return non-nil when BUFFER is a live request list for SOURCE."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (eq major-mode 'proofread-requests-buffer-mode)
              (eq proofread--request-log-list-source source)))))

(defun proofread--prune-request-log-list-buffers ()
  "Remove stale request lists owned by the current source buffer."
  (let ((source (current-buffer)))
    (setq proofread--request-log-list-buffers
          (cl-remove-if-not
           (lambda (buffer)
             (proofread--request-log-list-buffer-p buffer source))
           proofread--request-log-list-buffers))))

(defun proofread--request-log-list-cleanup ()
  "Stop source monitoring when its last request list closes."
  (let ((list-buffer (current-buffer))
        (source proofread--request-log-list-source))
    (if (buffer-live-p source)
        (with-current-buffer source
          (setq proofread--request-log-list-buffers
                (delq
                 list-buffer proofread--request-log-list-buffers))
          (proofread--prune-request-log-list-buffers)
          (unless proofread--request-log-list-buffers
            (proofread--request-log-disable-source source)))
      (proofread--request-log-disable-source source))))

(defun proofread--close-source-list-buffers (source)
  "Close auxiliary list buffers associated with SOURCE."
  (let (buffers)
    (when (buffer-live-p source)
      (with-current-buffer source
        (setq buffers
              (delete-dups
               (append proofread--request-log-list-buffers
                       proofread--diagnostics-list-buffers nil)))
        (setq proofread--request-log-list-buffers nil)
        (setq proofread--diagnostics-list-buffers nil)
        (proofread--request-log-disable-source source)))
    (dolist (buffer buffers)
      (when (and (not (eq buffer source))
                 (buffer-live-p buffer))
        (kill-buffer buffer)))
    buffers))

(defun proofread--cancel-request-log-refresh-timer ()
  "Cancel the current source's scheduled request list refresh."
  (when (timerp proofread--request-log-refresh-timer)
    (cancel-timer proofread--request-log-refresh-timer))
  (setq proofread--request-log-refresh-timer nil))

(defun proofread--refresh-request-log-list-buffers ()
  "Refresh request lists owned by the current source buffer."
  (proofread--prune-request-log-list-buffers)
  (dolist (buffer proofread--request-log-list-buffers)
    (with-current-buffer buffer
      (proofread--request-log-list-refresh))))

(defun proofread--request-log-refresh-timer-run (source)
  "Refresh request list buffers scheduled for SOURCE."
  (when (buffer-live-p source)
    (with-current-buffer source
      (setq proofread--request-log-refresh-timer nil)
      (condition-case err
          (proofread--refresh-request-log-list-buffers)
        (error
         (proofread-report-warning-without-window
          (format "Proofread request list refresh error (%S)"
                  (proofread--condition-kind err))
          "request list refresh failed; see *Warnings*"))))))

(defun proofread--schedule-request-log-refresh ()
  "Schedule one request list refresh for the current source buffer."
  (proofread--prune-request-log-list-buffers)
  (when (and proofread--request-log-list-buffers
             (null proofread--request-log-refresh-timer))
    (setq proofread--request-log-refresh-timer
          (run-at-time
           0 nil #'proofread--request-log-refresh-timer-run
           (current-buffer)))))

(defun proofread--request-log-backend-request-details (event)
  "Return printable backend request details from canonical EVENT."
  (list :backend (plist-get event :backend)
        :method (plist-get event :method)
        :url (plist-get event :url)
        :parameters (plist-get event :parameters)
        :pass (plist-get event :pass)
        :max-passes (plist-get event :max-passes)
        :strategy (plist-get event :strategy)
        :schema (plist-get event :schema)
        :prompt-text (plist-get event :prompt-text)
        :reported-diagnostics
        (plist-get event :reported-diagnostics)))

(defun proofread--request-log-backend-response-details (event)
  "Return printable backend response details from canonical EVENT."
  (list :backend (plist-get event :backend)
        :url (plist-get event :url)
        :http-status (plist-get event :http-status)
        :pass (plist-get event :pass)
        :response (plist-get event :response)
        :error (plist-get event :error)
        :message (plist-get event :message)))

(defun proofread--request-log-record-summary (record)
  "Return a summary plist for RECORD."
  (let* ((request (plist-get record :request))
         (line-column
          (proofread--request-log-record-line-column record)))
    (list :log-id (plist-get record :log-id)
          :request-id (plist-get record :request-id)
          :status (plist-get record :status)
          :profile (or (plist-get record :profile)
                       (plist-get request :profile))
          :checker-name (or (plist-get record :checker-name)
                            (plist-get request :checker-name))
          :backend (or (plist-get record :backend)
                       (plist-get request :backend))
          :language (plist-get request :language)
          :display-language (plist-get request :display-language)
          :checker-identity (plist-get request :checker-identity)
          :backend-identity (plist-get request :backend-identity)
          :phase (plist-get record :phase)
          :source-buffer (plist-get record :source-buffer)
          :beg (plist-get record :beg)
          :end (plist-get record :end)
          :line (car-safe line-column)
          :column (cdr-safe line-column)
          :created-at (plist-get record :created-at)
          :updated-at (plist-get record :updated-at)
          :current-source-text
          (proofread--request-log-record-current-text record))))

(defun proofread--request-log-insert-section (title value)
  "Insert a Lisp data section titled TITLE with VALUE."
  (insert ";;; " title "\n")
  (pp value (current-buffer))
  (insert "\n"))

(defun proofread--request-log-show-record (record)
  "Display detailed proofread request information for RECORD."
  (let ((buffer
         (get-buffer-create
          (proofread--request-log-request-buffer-name record))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (setq buffer-read-only nil)
        (erase-buffer)
        (lisp-data-mode)
        (proofread--request-log-insert-section
         "Summary"
         (proofread--request-log-record-summary record))
        (proofread--request-log-insert-section
         "Chunk request"
         (list :chunk (plist-get record :chunk)
               :request (plist-get record :request)))
        (proofread--request-log-insert-section
         "Lifecycle events"
         (plist-get record :events))
        (proofread--request-log-insert-section
         "Backend requests"
         (mapcar #'proofread--request-log-backend-request-details
                 (plist-get record :backend-requests)))
        (proofread--request-log-insert-section
         "Backend responses"
         (mapcar #'proofread--request-log-backend-response-details
                 (plist-get record :backend-responses)))
        (proofread--request-log-insert-section
         "Parsed backend results"
         (plist-get record :backend-results))
        (proofread--request-log-insert-section
         "Final result"
         (list :status (plist-get record :final-status)
               :result (plist-get record :final-result)
               :cache-entry (plist-get record :cache-entry)))
        (setq buffer-read-only t)
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun proofread-show-buffer-requests (buffer)
  "Show proofread backend requests recorded for BUFFER.
This command starts recording BUFFER's future proofread request
events."
  (interactive
   (list
    (read-buffer "Monitor proofread buffer: "
                 (or (and (buffer-live-p
                           proofread--request-log-list-source)
                          proofread--request-log-list-source)
                     (current-buffer))
                 t)))
  (let ((source (get-buffer buffer)))
    (unless (buffer-live-p source)
      (user-error "No such live buffer: %S" buffer))
    (unless (with-current-buffer source proofread-mode)
      (user-error "Proofread mode is not enabled in %s" source))
    (proofread--request-log-enable-source source)
    (let* ((name (proofread--request-log-list-buffer-name source))
           (target (or (get-buffer name)
                       (with-current-buffer (get-buffer-create name)
                         (proofread-requests-buffer-mode)
                         (current-buffer))))
           window)
      (with-current-buffer target
        (setq proofread--request-log-list-source source)
        (with-current-buffer source
          (cl-pushnew target proofread--request-log-list-buffers))
        (revert-buffer)
        (setq window
              (display-buffer
               (current-buffer)
               `((display-buffer-reuse-window
                  display-buffer-below-selected)
                 (window-height . proofread--fit-list-window)))))
      (when window
        (set-window-point
         window
         (with-current-buffer target (point-min))))
      target)))

;;;###autoload
(defun proofread-show-request (&optional pos)
  "Show detailed proofread request data for the row at POS."
  (interactive "d")
  (let* ((id (or (tabulated-list-get-id pos)
                 (tabulated-list-get-id)
                 (user-error "No proofread request at point")))
         (source (plist-get id :source-buffer))
         (key (plist-get id :key))
         (record (or (proofread--request-log-lookup-record source key)
                     id)))
    (proofread--request-log-show-record record)))

;;;; Diagnostic listings

(defun proofread--diagnostic-kind-rank (kind)
  "Return a stable sort rank for diagnostic KIND."
  (pcase kind
    ('spelling 0)
    ('grammar 1)
    ('style 2)
    (_ 3)))

(defun proofread--diagnostic-live-range (diagnostic)
  "Return DIAGNOSTIC's current live range, or nil."
  (if (proofread--aggregate-diagnostic-p diagnostic)
      (let (range)
        (dolist (member (proofread--diagnostic-members diagnostic))
          (unless range
            (setq range
                  (proofread--diagnostic-live-range member))))
        range)
    (let ((overlay (proofread--overlay-for-diagnostic diagnostic)))
      (when (and overlay
                 (overlay-start overlay)
                 (overlay-end overlay))
        (cons (overlay-start overlay)
              (overlay-end overlay))))))

(defun proofread--diagnostic-line-column (diagnostic)
  "Return DIAGNOSTIC's current line and zero-based display column."
  (let ((range (proofread--diagnostic-live-range diagnostic)))
    (when range
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (car range))
          (cons (line-number-at-pos)
                (current-column)))))))

(defun proofread--diagnostics-in-range (beg end)
  "Return proofread diagnostics conflicting with BEG to END.
This includes zero-width diagnostics on either boundary."
  (let ((selected-range (cons beg end))
        diagnostics)
    (dolist (diagnostic (proofread--navigation-diagnostics))
      (let ((range (proofread--diagnostic-live-range diagnostic)))
        (when (and range
                   (proofread--range-conflicts-p
                    selected-range range))
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--diagnostics-list-entry (diagnostic)
  "Return a tabulated list entry for live DIAGNOSTIC, or nil."
  (when-let*
      ((line-column
        (proofread--diagnostic-line-column diagnostic)))
    (let* ((line (car line-column))
           (column (cdr line-column))
           (kind (plist-get diagnostic :kind))
           (source (proofread--diagnostic-source-summary
                    diagnostic))
           (text (plist-get diagnostic :text))
           (message (proofread--diagnostic-message-summary
                     diagnostic))
           (id (list :diagnostic diagnostic
                     :buffer (current-buffer)
                     :line line
                     :kind-rank
                     (proofread--diagnostic-kind-rank kind))))
      (list
       id
       (vector
        (number-to-string line)
        (number-to-string column)
        (proofread--format-list-field kind)
        (proofread--format-list-field source)
        (proofread--format-list-field text)
        (list (if message
                  (proofread--format-list-field message)
                "-")
              'mouse-face 'highlight
              'help-echo "mouse-2: visit this diagnostic"
              'face nil
              'action #'proofread-goto-diagnostic
              'mouse-action #'proofread-goto-diagnostic))))))

(defun proofread--diagnostics-list-entries ()
  "Return tabulated list entries for the current buffer diagnostics."
  (delq nil
        (mapcar #'proofread--diagnostics-list-entry
                (proofread--navigation-diagnostics))))

(defun proofread--diagnostics-buffer-refresh ()
  "Refresh entries in the current proofread diagnostics buffer."
  (setq tabulated-list-format proofread--diagnostics-list-format)
  (setq tabulated-list-entries
        (and (buffer-live-p proofread--diagnostics-buffer-source)
             (with-current-buffer proofread--diagnostics-buffer-source
               (and proofread-mode
                    (proofread--diagnostics-list-entries)))))
  (tabulated-list-init-header)
  (tabulated-list-print t))

(defun proofread--diagnostics-buffer-setup ()
  "Set up refresh and navigation for proofread diagnostics buffers."
  (setq-local next-error-function #'proofread--diagnostics-next-error)
  (setq-local revert-buffer-function
              (lambda (&rest _)
                (proofread--diagnostics-buffer-refresh)))
  (add-hook 'kill-buffer-hook
            #'proofread--diagnostics-list-cleanup nil t)
  (add-hook 'change-major-mode-hook
            #'proofread--diagnostics-list-cleanup nil t))

(defun proofread--refresh-diagnostics-list-buffers ()
  "Refresh diagnostic lists for the current source buffer."
  (setq proofread--diagnostics-list-buffers
        (cl-remove-if-not #'buffer-live-p
                          proofread--diagnostics-list-buffers))
  (dolist (buffer proofread--diagnostics-list-buffers)
    (with-current-buffer buffer
      (proofread--diagnostics-buffer-refresh))))

(defun proofread--diagnostics-list-cleanup ()
  "Unregister the current diagnostic list from its source buffer."
  (let ((list-buffer (current-buffer))
        (source proofread--diagnostics-buffer-source))
    (when (buffer-live-p source)
      (with-current-buffer source
        (setq proofread--diagnostics-list-buffers
              (delq list-buffer proofread--diagnostics-list-buffers))
        (unless proofread--diagnostics-list-buffers
          (remove-hook
           'proofread-diagnostics-changed-hook
           #'proofread--refresh-diagnostics-list-buffers t))
        (proofread--uninstall-source-list-cleanup-if-unused)))))

(defun proofread-show-diagnostic (pos &optional other-window)
  "From a diagnostics buffer, show the source diagnostic at POS.
When OTHER-WINDOW is non-nil, prefer displaying the source in another
window."
  (interactive (list (point) t))
  (let* ((diagnostics-buffer (current-buffer))
         (id (or (tabulated-list-get-id pos)
                 (user-error "Nothing at point")))
         (diagnostic (plist-get id :diagnostic))
         (source (plist-get id :buffer))
         (range (and diagnostic
                     (buffer-live-p source)
                     (with-current-buffer source
                       (proofread--diagnostic-live-range
                        diagnostic)))))
    (unless (and (buffer-live-p source) range)
      (user-error "Proofread diagnostic is stale"))
    (setq proofread--diagnostics-current-line
          (line-number-at-pos pos))
    (with-current-buffer source
      (let ((window (display-buffer (current-buffer) other-window)))
        (unless (window-live-p window)
          (user-error "Unable to display proofread source buffer"))
        (with-selected-window window
          (goto-char (car range))
          (proofread--mark-current-diagnostic diagnostic)
          (pulse-momentary-highlight-region
           (car range) (cdr range))))
      (setq next-error-last-buffer diagnostics-buffer)
      (current-buffer))))

(defun proofread-goto-diagnostic (pos)
  "Visit diagnostic at POS from a Proofread diagnostics buffer."
  (interactive "d")
  (pop-to-buffer
   (proofread-show-diagnostic
    (if (button-type pos)
        (button-start pos)
      pos))))

(defun proofread--diagnostics-next-error (n &optional reset)
  "Move N diagnostics in a proofread diagnostics buffer.
When RESET is non-nil, move from the beginning of the buffer."
  (let* ((line (if reset 0 proofread--diagnostics-current-line))
         (target (+ line n))
         (total-lines (count-lines (point-min) (point-max))))
    (unless (<= 1 target total-lines)
      (user-error "No %s proofread diagnostic"
                  (if (< n 0) "previous" "next")))
    (goto-char (point-min))
    (forward-line (1- target))
    (when-let* ((window (get-buffer-window nil t)))
      (set-window-point window (point)))
    (proofread-goto-diagnostic (point))))

(define-derived-mode proofread-diagnostics-buffer-mode
  tabulated-list-mode
  "Proofread diagnostics"
  "A mode for listing Proofread diagnostics."
  :interactive nil
  (proofread--diagnostics-buffer-setup))

(defun proofread--diagnostics-buffer-name ()
  "Return the diagnostics buffer name for the current buffer."
  (format "*Proofread diagnostics for `%s'*" (current-buffer)))

(defun proofread--diagnostic-suggestions (diagnostic)
  "Return DIAGNOSTIC suggestions as strings in stored order."
  (if (proofread--aggregate-diagnostic-p diagnostic)
      (mapcar (lambda (record)
                (plist-get record :text))
              (proofread--diagnostic-suggestion-records
               diagnostic))
    (let ((suggestions (plist-get diagnostic :suggestions)))
      (cond
       ((null suggestions) nil)
       ((listp suggestions)
        (mapcar #'proofread-format-diagnostic-field suggestions))
       (t (list (proofread-format-diagnostic-field suggestions)))))))

;;;; Corrections

(defun proofread--select-diagnostic-suggestion (diagnostic)
  "Return the selected suggestion string for DIAGNOSTIC."
  (let ((suggestions (proofread--diagnostic-suggestions diagnostic)))
    (cond
     ((null suggestions)
      (user-error "No proofread suggestion available"))
     ((null (cdr suggestions))
      (car suggestions))
     (t
      (completing-read "Apply suggestion: " suggestions nil t)))))

(defun proofread--validate-suggestion-application (diagnostic)
  "Validate DIAGNOSTIC for application and return its range."
  (let* ((range (proofread--diagnostic-live-range diagnostic))
         (beg (car range))
         (end (cdr range))
         (text (plist-get diagnostic :text)))
    (unless range
      (user-error "Proofread diagnostic is stale"))
    (unless (and (proofread--range-valid-p range)
                 (proofread--range-contains-p
                  (cons (point-min) (point-max)) range))
      (user-error "Invalid proofread diagnostic range"))
    (unless (stringp text)
      (user-error "Invalid proofread diagnostic text"))
    (unless (equal (buffer-substring-no-properties beg end) text)
      (user-error "Proofread diagnostic text no longer matches"))
    range))

(defun proofread--diagnostic-correction-container (diagnostic range)
  "Return syntax-container metadata for DIAGNOSTIC at RANGE.
Return nil for diagnostics in ordinary text."
  (let ((kind (plist-get diagnostic :target-kind)))
    (when (memq kind '( comment docstring))
      (proofread--with-widened-syntax
        (let* ((beg (car range))
               (end (cdr range))
               (beg-state (syntax-ppss beg))
               (end-state (syntax-ppss end))
               (container
                (proofread--syntax-container-range beg-state kind)))
          (unless (and container
                       (proofread--syntax-state-in-container-p
                        beg-state (car container) kind)
                       (proofread--syntax-state-in-container-p
                        end-state (car container) kind))
            (user-error
             "Proofread diagnostic left its source container"))
          (list :kind kind
                :range container
                :open
                (and (proofread--syntax-state-in-container-p
                      (syntax-ppss (cdr container))
                      (car container) kind)
                     t)))))))

(defun proofread--validate-correction-container
    (container beg replacement-end delta)
  "Validate a source CONTAINER after replacing text at BEG.
REPLACEMENT-END is the end of the inserted text and DELTA is its
length change."
  (when container
    (proofread--with-widened-syntax
      (let* ((kind (plist-get container :kind))
             (old-range (plist-get container :range))
             (expected-range
              (cons (car old-range) (+ (cdr old-range) delta)))
             (beg-state (syntax-ppss beg))
             (end-state (syntax-ppss replacement-end))
             (new-range
              (proofread--syntax-container-range beg-state kind))
             (new-open
              (and new-range
                   (proofread--syntax-state-in-container-p
                    (syntax-ppss (cdr new-range))
                    (car new-range) kind)
                   t)))
        (unless (and (equal new-range expected-range)
                     (eq new-open (plist-get container :open))
                     (proofread--syntax-state-in-container-p
                      beg-state (car expected-range) kind)
                     (proofread--syntax-state-in-container-p
                      end-state (car expected-range) kind))
          (user-error
           "Proofread suggestion would alter a source delimiter"))))))

(defun proofread--remove-diagnostics (diagnostics)
  "Remove DIAGNOSTICS from current buffer proofread state."
  (let ((removed (make-hash-table :test #'eq)))
    (dolist (diagnostic diagnostics)
      (puthash diagnostic t removed)
      (when (hash-table-p proofread--diagnostic-overlays)
        (remhash diagnostic proofread--diagnostic-overlays))
      (when (hash-table-p proofread--diagnostic-request-ranges)
        (remhash diagnostic proofread--diagnostic-request-ranges)))
    (setq proofread--diagnostics
          (cl-delete-if (lambda (diagnostic)
                          (gethash diagnostic removed))
                        proofread--diagnostics))))

(defun proofread--invalidate-affected-diagnostics
    (overlays diagnostics &optional inhibit-notification)
  "Invalidate OVERLAYS and DIAGNOSTICS after a text change.
When INHIBIT-NOTIFICATION is non-nil, defer the diagnostics change
hook."
  (dolist (overlay overlays)
    (proofread--delete-overlay overlay))
  (proofread--remove-diagnostics diagnostics)
  (when (and proofread--current-diagnostic
             (cl-some (lambda (diagnostic)
                        (memq diagnostic diagnostics))
                      (proofread--diagnostic-members
                       proofread--current-diagnostic)))
    (setq proofread--current-diagnostic nil))
  (proofread--prune-overlays)
  (unless inhibit-notification
    (proofread--run-diagnostics-changed-hook)))

(defun proofread--synchronize-live-diagnostic-ranges ()
  "Synchronize stored diagnostic ranges with their live overlays."
  (let (overlays)
    (dolist (overlay proofread--overlays)
      (when (proofread--current-buffer-overlay-p overlay)
        (push overlay overlays)
        (let ((diagnostic (overlay-get overlay 'proofread-diagnostic))
              (beg (overlay-start overlay))
              (end (overlay-end overlay)))
          (when (and (eq overlay
                         (and
                          (hash-table-p
                           proofread--diagnostic-overlays)
                          (gethash
                           diagnostic
                           proofread--diagnostic-overlays)))
                     beg end)
            (setf (plist-get diagnostic :beg) beg)
            (setf (plist-get diagnostic :end) end)))))
    (setq proofread--overlays (nreverse overlays))))

(defun proofread--mode-buffer-character-ticks ()
  "Return modification ticks for live Proofread buffers."
  (proofread--prune-mode-buffers)
  (mapcar (lambda (buffer)
            (cons buffer
                  (with-current-buffer buffer
                    (buffer-chars-modified-tick))))
          proofread--mode-buffers))

(defun proofread--diagnostic-text-current-p (diagnostic)
  "Return non-nil when DIAGNOSTIC still identifies its recorded text."
  (when-let* ((range (or (proofread--diagnostic-live-range diagnostic)
                         (proofread--diagnostic-range diagnostic)))
              (beg (car range))
              (end (cdr range)))
    (and (proofread--range-valid-p range)
         (proofread--range-contains-p
          (cons (point-min) (point-max)) range)
         (equal (buffer-substring-no-properties beg end)
                (plist-get diagnostic :text)))))

(defun proofread--repair-correction-time-buffer-changes
    (ticks source &optional repair-source)
  "Repair proofread state changed since TICKS while correcting SOURCE.
Modification hooks suppress recursively triggered hooks, even in
another buffer.  Revalidate every proofread buffer whose character
tick changed.  When REPAIR-SOURCE is nil, preserve SOURCE state after
an atomic rollback."
  (dolist (entry ticks)
    (let ((buffer (car entry))
          (tick (cdr entry)))
      (when (and (or repair-source (not (eq buffer source)))
                 (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (and proofread-mode
                        (/= tick (buffer-chars-modified-tick)))))
        (with-current-buffer buffer
          ;; A suppressed nested edit may have shifted any pending
          ;; request.
          (proofread--clear-request-work)
          (save-restriction
            (widen)
            (let ((stale
                   (cl-delete-if
                    #'proofread--diagnostic-text-current-p
                    (copy-sequence proofread--diagnostics))))
              (when stale
                (proofread--invalidate-affected-diagnostics
                 (delq nil
                       (mapcar
                        #'proofread--overlay-for-diagnostic
                        stale))
                 stale t)
                (proofread--synchronize-live-diagnostic-ranges)
                (unless (eq buffer source)
                  (proofread--run-diagnostics-changed-hook)))))
          (proofread--mark-pending-work))))))

(defun proofread--prepare-diagnostic-corrections (diagnostics)
  "Return selected nonconflicting corrections for DIAGNOSTICS.
Each returned element is a cons cell of the form (DIAGNOSTIC
. SUGGESTION).  DIAGNOSTICS must be in navigation order.  An earlier
diagnostic takes precedence over any later diagnostic whose range
conflicts with it, including equal or boundary-conflicting zero-width
ranges."
  (let (corrections previous-range)
    (dolist (diagnostic diagnostics)
      (let ((range
             (proofread--validate-suggestion-application
              diagnostic)))
        (unless (and previous-range
                     (proofread--range-conflicts-p
                      range previous-range))
          (let ((suggestion
                 (proofread--select-diagnostic-suggestion
                  diagnostic)))
            (setq previous-range range)
            (push (cons diagnostic suggestion) corrections)))))
    (nreverse corrections)))

(defun proofread--corrections-affected-state
    (corrections &optional correction-ranges)
  "Return overlays and diagnostics affected by CORRECTIONS.
The return value is a cons cell whose car contains overlays and whose
cdr contains diagnostics.  When CORRECTION-RANGES is non-nil, use
the validated live ranges instead of the diagnostics' stored ranges."
  (let* ((ranges
          (or correction-ranges
              (mapcar
               (lambda (correction)
                 (proofread--diagnostic-range (car correction)))
               corrections)))
         (entries
          (delq nil
                (mapcar
                 (lambda (diagnostic)
                   (when-let* ((range
                                (proofread--diagnostic-range
                                 diagnostic)))
                     (cons diagnostic range)))
                 proofread--diagnostics)))
         (affected (make-hash-table :test #'eq))
         overlays
         diagnostics)
    (dolist (entry
             (proofread--range-conflicting-entries ranges entries))
      (puthash (car entry) t affected)
      (push (car entry) diagnostics))
    (proofread--prune-overlays)
    (dolist (overlay proofread--overlays)
      (when (gethash
             (overlay-get overlay 'proofread-diagnostic)
             affected)
        (push overlay overlays)))
    (cons overlays diagnostics)))

(defun proofread--run-correction-transaction
    (corrections &optional preserve-excursion)
  "Apply CORRECTIONS in one atomic correction transaction.
Each element of CORRECTIONS has the form (DIAGNOSTIC . SUGGESTION).
Validate every diagnostic before editing, then apply the corrections
from end to beginning.  When PRESERVE-EXCURSION is non-nil, restore
point, mark, and mark activation before notifying diagnostics hooks."
  (let* ((validated-corrections
          (mapcar
           (lambda (correction)
             (let* ((diagnostic (car correction))
                    (range
                     (proofread--validate-suggestion-application
                      diagnostic)))
               (list
                correction
                range
                ;; A single correction validates its container before
                ;; opening an undo transaction.  A batch must instead
                ;; snapshot each updated container immediately before
                ;; its reverse-order edit.
                (unless preserve-excursion
                  (cons
                   t
                   (proofread--diagnostic-correction-container
                    diagnostic range))))))
           corrections))
         (affected-state
          (proofread--corrections-affected-state
           corrections
           (mapcar (lambda (validated-correction)
                     (nth 1 validated-correction))
                   validated-corrections)))
         (affected-overlays (car affected-state))
         (affected-diagnostics (cdr affected-state))
         (buffer-ticks (proofread--mode-buffer-character-ticks))
         (source (current-buffer)))
    (cl-labels
        ((run-transaction
           ()
           (undo-boundary)
           (let ((proofread--inhibit-overlay-invalidation
                  (current-buffer))
                 (proofread--deferred-correction-overlays nil)
                 (proofread--deferred-correction-diagnostics nil)
                 correction-committed)
             (unwind-protect
                 (progn
                   (atomic-change-group
                     (dolist (validated-correction
                              (reverse validated-corrections))
                       (let* ((correction
                               (car validated-correction))
                              (diagnostic (car correction))
                              (suggestion (cdr correction))
                              (range (nth 1 validated-correction))
                              (beg (car range))
                              (end (cdr range))
                              (container-state
                               (nth 2 validated-correction))
                              (container
                               (if container-state
                                   (cdr container-state)
                                 (proofread--diagnostic-correction-container
                                  diagnostic
                                  range))))
                         (if preserve-excursion
                             (progn
                               (goto-char beg)
                               (delete-region beg end))
                           (delete-region beg end)
                           (goto-char beg))
                         (insert suggestion)
                         (proofread--validate-correction-container
                          container beg (point)
                          (- (length suggestion) (- end beg))))))
                   (setq correction-committed t)
                   (proofread--invalidate-affected-diagnostics
                    (cl-delete-duplicates
                     (append proofread--deferred-correction-overlays
                             affected-overlays)
                     :test #'eq)
                    (cl-delete-duplicates
                     (append
                      proofread--deferred-correction-diagnostics
                      affected-diagnostics)
                     :test #'eq)
                    t)
                   (proofread--synchronize-live-diagnostic-ranges))
               (proofread--repair-correction-time-buffer-changes
                buffer-ticks source correction-committed)))
           (unless preserve-excursion
             (proofread--run-diagnostics-changed-hook))
           (undo-boundary)))
      (if preserve-excursion
          (save-mark-and-excursion
            (run-transaction))
        (run-transaction)))
    (when preserve-excursion
      (proofread--run-diagnostics-changed-hook))))

(defun proofread--apply-suggestion-to-diagnostic
    (diagnostic suggestion)
  "Replace DIAGNOSTIC with SUGGESTION and invalidate stale state."
  (proofread--run-correction-transaction
   (list (cons diagnostic suggestion)))
  (message "proofread: applied suggestion")
  'applied)

(defun proofread--apply-diagnostic-corrections (corrections)
  "Apply prepared CORRECTIONS atomically from end to beginning."
  (proofread--run-correction-transaction corrections t))

(defun proofread--correct-diagnostics (diagnostics)
  "Apply selected suggestions to DIAGNOSTICS as one command.
DIAGNOSTICS must be in navigation order.  Return `applied'."
  (let (actionable)
    (dolist (diagnostic diagnostics)
      (when (proofread--diagnostic-suggestions diagnostic)
        (push diagnostic actionable)))
    (setq actionable (nreverse actionable))
    (unless actionable
      (user-error "No proofread suggestions available"))
    (let* ((corrections
            (proofread--prepare-diagnostic-corrections actionable))
           (count (length corrections))
           (skipped (- (length diagnostics) count)))
      (proofread--apply-diagnostic-corrections corrections)
      (message "proofread: applied %d suggestion%s%s"
               count
               (if (= count 1) "" "s")
               (if (zerop skipped)
                   ""
                 (format "; skipped %d diagnostic%s"
                         skipped
                         (if (= skipped 1) "" "s"))))
      'applied)))

(defun proofread--format-diagnostic-description (diagnostic)
  "Return a stable plain-text description for DIAGNOSTIC."
  (let ((aggregate (proofread--aggregate-diagnostic-p diagnostic))
        (kind (plist-get diagnostic :kind))
        (text (plist-get diagnostic :text))
        (suggestions (proofread--diagnostic-suggestions diagnostic))
        (lines '( "Proofread diagnostic")))
    (when kind
      (setq lines
            (append lines
                    (list ""
                          (format "Kind: %s"
                                  (proofread-format-diagnostic-field
                                   kind))))))
    (if aggregate
        (when-let* ((entries
                     (proofread--diagnostic-message-entries
                      diagnostic)))
          (setq lines (append lines (list "" "Messages:")))
          (dolist (entry entries)
            (let ((source (plist-get entry :source))
                  (message
                   (proofread-format-diagnostic-field
                    (plist-get entry :message))))
              (setq lines
                    (append
                     lines
                     (list (if source
                               (format "%s: %s" source message)
                             message)))))))
      (when-let* ((message (plist-get diagnostic :message)))
        (setq lines
              (append lines
                      (list (format "Message: %s"
                                    (proofread-format-diagnostic-field
                                     message)))))))
    (when text
      (setq lines
            (append lines
                    (list ""
                          "Original text:"
                          (proofread-format-diagnostic-field
                           text)))))
    (when suggestions
      (setq lines (append lines (list "" "Suggestions:")))
      (let ((index 1))
        (if aggregate
            (dolist (record
                     (proofread--diagnostic-suggestion-records
                      diagnostic))
              (let ((sources (plist-get record :sources)))
                (setq lines
                      (append
                       lines
                       (list
                        (format
                         "%d. %s%s"
                         index
                         (proofread-format-diagnostic-field
                          (plist-get record :text))
                         (if sources
                             (format " (from %s)"
                                     (string-join sources ", "))
                           ""))))))
              (setq index (1+ index)))
          (dolist (suggestion suggestions)
            (setq lines
                  (append
                   lines
                   (list
                    (format
                     "%d. %s"
                     index
                     (proofread-format-diagnostic-field
                      suggestion)))))
            (setq index (1+ index))))))
    (when-let* ((source
                 (proofread--diagnostic-source-summary diagnostic)))
      (setq lines
            (append lines
                    (list (format "%s: %s"
                                  (if aggregate "Sources" "Source")
                                  source)))))
    (mapconcat #'identity lines "\n")))

(defun proofread--display-diagnostic-description (diagnostic)
  "Display formatted details for DIAGNOSTIC in a help buffer."
  (with-help-window proofread--description-buffer-name
    (princ (proofread--format-diagnostic-description diagnostic))))

(defun proofread--create-overlay (diagnostic)
  "Create and return a proofread overlay for DIAGNOSTIC."
  (let ((beg (plist-get diagnostic :beg))
        (end (plist-get diagnostic :end)))
    (unless (and (integer-or-marker-p beg)
                 (integer-or-marker-p end)
                 (<= beg end))
      (error "Invalid proofread diagnostic range: %S" diagnostic))
    (proofread--prune-overlays)
    (let ((overlay (make-overlay beg end nil t nil)))
      (overlay-put overlay 'category proofread--overlay-category)
      (overlay-put overlay 'face 'proofread-face)
      (overlay-put overlay 'proofread-diagnostic diagnostic)
      (overlay-put
       overlay 'proofread-diagnostic-insertion-ordinal
       proofread--next-diagnostic-insertion-ordinal)
      (setq proofread--next-diagnostic-insertion-ordinal
            (1+ proofread--next-diagnostic-insertion-ordinal))
      (unless (hash-table-p proofread--diagnostic-overlays)
        (setq proofread--diagnostic-overlays
              (make-hash-table :test #'eq)))
      (puthash diagnostic overlay proofread--diagnostic-overlays)
      (push overlay proofread--overlays)
      overlay)))

(defun proofread--clear-diagnostics ()
  "Clear this buffer's proofread diagnostics and overlays."
  (dolist (overlay (proofread--current-buffer-overlays))
    (delete-overlay overlay))
  (setq proofread--overlays nil)
  (setq proofread--diagnostics nil)
  (when (hash-table-p proofread--diagnostic-overlays)
    (clrhash proofread--diagnostic-overlays))
  (when (hash-table-p proofread--diagnostic-request-ranges)
    (clrhash proofread--diagnostic-request-ranges))
  (setq proofread--current-diagnostic nil)
  (force-window-update (current-buffer))
  (proofread--run-diagnostics-changed-hook))

;;;; Mode lifecycle

(defun proofread--initialize-buffer-state ()
  "Initialize proofread-owned state for the current buffer."
  (setq proofread--generation
        (cl-incf proofread--generation-sequence))
  (setq-local proofread--diagnostics nil)
  (setq-local proofread--overlays nil)
  (setq-local proofread--diagnostic-overlays
              (make-hash-table :test #'eq))
  (setq-local proofread--next-diagnostic-insertion-ordinal 0)
  (setq-local proofread--diagnostic-request-ranges
              (make-hash-table :test #'eq))
  (setq-local proofread--current-diagnostic nil)
  (setq-local proofread--eldoc-mode-owned-p nil)
  (setq-local proofread--echo-area-refresh-pending-p nil)
  (setq-local proofread--active-requests nil)
  (setq-local proofread--queue-state
              (proofread--make-queue-state))
  (setq-local proofread--claimed-requests nil)
  (setq-local proofread--queue-dispatch-active-p nil)
  (setq-local proofread--queue-dispatch-requested-p nil)
  (setq-local proofread--queue-dispatch-timer nil)
  (setq-local proofread--pending-request-keys
              (make-hash-table :test #'equal))
  (setq-local proofread--next-request-id 0)
  (setq-local proofread--cache (make-hash-table :test #'equal))
  (setq-local proofread--cache-order nil)
  (setq-local proofread--pending-work nil)
  (setq-local proofread--idle-timer nil)
  (setq-local proofread--pending-invalidated-overlays nil)
  (setq-local proofread--pending-invalidated-diagnostics nil))

(defun proofread--clear-buffer-state ()
  "Clear proofread-owned state for the current buffer."
  (proofread--clear-request-work)
  (proofread--clear-diagnostics)
  (setq proofread--queue-state nil)
  (setq proofread--claimed-requests nil)
  (setq proofread--queue-dispatch-active-p nil)
  (setq proofread--queue-dispatch-requested-p nil)
  (setq proofread--queue-dispatch-timer nil)
  (setq proofread--pending-request-keys nil)
  (setq proofread--next-request-id 0)
  (setq proofread--cache nil)
  (setq proofread--cache-order nil)
  (setq proofread--diagnostic-overlays nil)
  (setq proofread--next-diagnostic-insertion-ordinal nil)
  (setq proofread--diagnostic-request-ranges nil)
  (setq proofread--eldoc-mode-owned-p nil)
  (setq proofread--echo-area-refresh-pending-p nil)
  (setq proofread--pending-invalidated-overlays nil)
  (setq proofread--pending-invalidated-diagnostics nil))

(defun proofread--enable-buffer ()
  "Enable this buffer's local Proofread hooks and state."
  (when (memq (current-buffer) proofread--mode-buffers)
    (proofread--disable-buffer)
    ;; Teardown hooks can schedule work while the mode variable still
    ;; remains non-nil during an explicit re-enable.
    (proofread--clear-scheduled-work))
  (proofread--initialize-buffer-state)
  (add-hook 'before-change-functions #'proofread--before-change nil t)
  (add-hook 'after-change-functions #'proofread--after-change nil t)
  (add-hook 'kill-buffer-hook #'proofread--kill-buffer nil t)
  (add-hook 'change-major-mode-hook
            #'proofread--change-major-mode nil t)
  (add-hook 'window-scroll-functions #'proofread--window-scroll nil t)
  (add-hook 'window-configuration-change-hook
            #'proofread--mark-pending-work nil t)
  (proofread--enable-echo-area)
  (proofread--register-mode-buffer)
  (proofread--mark-pending-work))

(defun proofread--disable-buffer ()
  "Disable this buffer's local Proofread hooks and state."
  (remove-hook 'before-change-functions #'proofread--before-change t)
  (remove-hook 'after-change-functions #'proofread--after-change t)
  (remove-hook 'kill-buffer-hook #'proofread--kill-buffer t)
  (remove-hook 'change-major-mode-hook
               #'proofread--change-major-mode t)
  (remove-hook 'window-scroll-functions #'proofread--window-scroll t)
  (remove-hook 'window-configuration-change-hook
               #'proofread--mark-pending-work t)
  (proofread--disable-echo-area)
  (proofread--clear-buffer-state)
  (proofread--unregister-mode-buffer))

(defun proofread--change-major-mode ()
  "Disable `proofread-mode' before changing the current major mode."
  (proofread-mode -1))

(defun proofread--require-mode ()
  "Require `proofread-mode' in the current buffer."
  (unless proofread-mode
    (user-error
     "Proofread mode is not enabled in the current buffer")))

(defun proofread--sorted-target-domains (domains)
  "Return a copy of DOMAINS sorted by beginning position."
  (sort (copy-sequence domains)
        (lambda (left right)
          (< (plist-get left :domain-beg)
             (plist-get right :domain-beg)))))

(defun proofread--range-in-sorted-domains-p (range domains)
  "Return non-nil when RANGE is contained in one of sorted DOMAINS."
  (let ((beg (car range)))
    (catch 'contained
      (dolist (domain domains)
        (let ((domain-beg (plist-get domain :domain-beg))
              (domain-end (plist-get domain :domain-end)))
          (when (> domain-beg beg)
            (throw 'contained nil))
          (when (proofread--range-contains-p
                 (cons domain-beg domain-end) range)
            (throw 'contained t))))
      nil)))

(defun proofread--checked-diagnostic-entries (ranges)
  "Return diagnostics conflicting with RANGES, sorted by position."
  (let (entries)
    (dolist (diagnostic proofread--diagnostics)
      (when-let* ((range (proofread--diagnostic-range diagnostic)))
        (when (proofread--range-conflicts-any-p range ranges)
          (push (cons diagnostic range) entries))))
    (sort entries
          (lambda (left right)
            (< (cadr left) (cadr right))))))

(defun proofread--prune-invalid-checked-diagnostics (plan profile)
  "Remove checked diagnostics invalid under PLAN or PROFILE.
A diagnostic selected by PLAN must remain wholly within one target
domain, avoid ignored text, and, when profile-owned, belong to a
checker in PROFILE.  Unowned and ad-hoc diagnostics are exempt only
from the profile-owner requirement."
  (let ((ranges (proofread--selection-plan-ranges plan))
        (remaining-domains
         (proofread--sorted-target-domains
          (proofread--selection-plan-domains plan)))
        (owners
         (mapcar #'proofread--checker-owner
                 (plist-get profile :checkers)))
        diagnostics)
    (dolist (entry (proofread--checked-diagnostic-entries ranges))
      (let* ((diagnostic (car entry))
             (range (cdr entry))
             (beg (car range))
             (end (cdr range))
             (owner (plist-get diagnostic :checker-owner)))
        (while (and remaining-domains
                    (< (plist-get (car remaining-domains) :domain-end)
                       beg))
          (setq remaining-domains (cdr remaining-domains)))
        (unless
            (and
             (proofread--range-in-sorted-domains-p
              range remaining-domains)
             (null (proofread--ignored-ranges-in-region beg end))
             (or (null owner)
                 (plist-get owner :ad-hoc)
                 (member owner owners)))
          (push diagnostic diagnostics))))
    (when diagnostics
      (proofread--invalidate-affected-diagnostics
       (delq nil
             (mapcar #'proofread--overlay-for-diagnostic diagnostics))
       diagnostics))))

(defun proofread--prepare-forced-check (force-feedback)
  "Retire pending automatic work when FORCE-FEEDBACK is non-nil."
  (when force-feedback
    (setq proofread--pending-work nil)
    (proofread--cancel-idle-timer)))

(defun proofread--check-selection-plan
    (plan profile scope &optional force-feedback request-spans)
  "Check PLAN with PROFILE and describe it as SCOPE.
When FORCE-FEEDBACK is non-nil, use `message' for feedback.  Optional
REQUEST-SPANS are already selected and filtered request span records."
  (let* ((progress-message
          (if force-feedback
              #'message
            #'proofread--progress-message))
         (normalized-ranges
          (proofread--selection-plan-ranges plan))
         (islands (proofread--selection-plan-islands plan)))
    (proofread--prune-invalid-checked-diagnostics plan profile)
    (let* ((dispatch-result
            (when (plist-get profile :checkers)
              (proofread--dispatch-profile-request-ready-chunks-result
               (if request-spans
                   (proofread--request-ready-chunks-for-request-spans
                    request-spans (plist-get profile :language))
                 (proofread--request-ready-chunks-for-islands
                  islands (plist-get profile :language)))
               profile)))
           (supported-count
            (or (plist-get dispatch-result :supported-count) 0)))
      (if (> supported-count 0)
          (let ((requests (plist-get dispatch-result :requests))
                (queued (proofread--request-queue-length)))
            (funcall
             progress-message
             "proofread: dispatched %d request%s%s from %d %s range%s"
             (length requests)
             (if (= (length requests) 1) "" "s")
             (if (> queued 0)
                 (format "; queued %d" queued)
               "")
             (length normalized-ranges)
             scope
             (if (= (length normalized-ranges) 1) "" "s")))
        (funcall
         progress-message
         "proofread: collected %d %s range%s; no available backend"
         (length normalized-ranges)
         scope
         (if (= (length normalized-ranges) 1) "" "s"))))))

(defun proofread--check-ranges (ranges scope &optional force-feedback)
  "Check RANGES and describe them as SCOPE in progress feedback.
When FORCE-FEEDBACK is non-nil, report feedback even when routine
progress messages are inhibited."
  (proofread--require-mode)
  (proofread--prepare-forced-check force-feedback)
  (let ((profile (proofread--current-profile)))
    (proofread--check-selection-plan
     (proofread--selection-plan-for-ranges ranges)
     profile scope force-feedback)))

(defun proofread--span-at-position (spans position)
  "Return the most useful member of sorted SPANS for POSITION.
SPANS are nonempty half-open ranges.  At the end of the accessible
buffer or the first sentence-ending separator whitespace, return the
preceding span only when it ends exactly at POSITION."
  (or (cl-find-if (lambda (span)
                    (proofread--range-covers-position-p
                     span position))
                  spans)
      (when (or (= position (point-max))
                (and (< position (point-max))
                     (memq (char-after position) '( ?\s ?\t ?\n ?\r))
                     (not (proofread--ignored-ranges-in-region
                           position (1+ position)))))
        (cl-find-if (lambda (span)
                      (= (cdr span) position))
                    spans))))

(defun proofread--point-probe-ranges ()
  "Return nonempty character ranges immediately around point."
  (let ((position (point))
        ranges)
    (when (< position (point-max))
      (push (cons position (1+ position)) ranges))
    (when (> position (point-min))
      (push (cons (1- position) position) ranges))
    (nreverse ranges)))

(defun proofread--point-island-for-domain (domain position)
  "Return a bounded island in target DOMAIN around POSITION."
  (let* ((domain-beg (plist-get domain :domain-beg))
         (domain-end (plist-get domain :domain-end))
         (size (max 1 proofread-max-chunk-size))
         (index (/ (max 0 (- position domain-beg)) size))
         (beg (if (<= (- domain-end domain-beg) (* 4 size))
                  domain-beg
                (+ domain-beg (* (max 0 (1- index)) size))))
         (end (if (= beg domain-beg)
                  (min domain-end (+ beg (* 4 size)))
                (min domain-end (+ beg (* 3 size))))))
    (append (list :beg beg :end end :owner-domain domain)
            domain)))

(defun proofread--point-target-domains (plan)
  "Return the preferred point target domains from PLAN.
Comments take precedence over docstrings when discovery reports both."
  (let ((domains (proofread--selection-plan-domains plan)))
    (or (cl-remove-if-not
         (lambda (domain)
           (eq (plist-get domain :kind) 'comment))
         domains)
        (cl-remove-if-not
         (lambda (domain)
           (eq (plist-get domain :kind) 'docstring))
         domains)
        (cl-remove-if-not
         (lambda (domain)
           (eq (plist-get domain :kind) 'text))
         domains))))

(defun proofread--request-span-at-position
    (request-spans position)
  "Return the member of REQUEST-SPANS selected by POSITION."
  (let* ((ranges
          (mapcar
           (lambda (span)
             (cons (plist-get span :beg)
                   (plist-get span :end)))
           request-spans))
         (range (proofread--span-at-position ranges position)))
    (or (and range
             (cl-find-if
              (lambda (span)
                (and (= (plist-get span :beg) (car range))
                     (= (plist-get span :end) (cdr range))))
              request-spans))
        ;; A comment delimiter can form a punctuation-only span that
        ;; is intentionally filtered.  Select the following prose in
        ;; that same target domain when point is on the delimiter.
        (when (cl-some
               (lambda (span)
                 (memq (plist-get span :kind)
                       '( comment docstring)))
               request-spans)
          (when-let* ((span
                       (cl-find-if
                        (lambda (candidate)
                          (let ((domain
                                 (plist-get candidate
                                            :owner-domain)))
                            (and domain
                                 (proofread--range-covers-position-p
                                  (cons
                                   (plist-get domain :domain-beg)
                                   (plist-get domain :domain-end))
                                  position)
                                 (<= position
                                     (plist-get candidate :beg)))))
                        request-spans)))
            (when (and
                   (not
                    (proofread--range-has-alphanumeric-p
                     position (plist-get span :beg)))
                   (null
                    (proofread--ignored-ranges-in-region
                     position (plist-get span :beg))))
              span))))))

(defun proofread--point-check-selection ()
  "Return the point check selection, or nil when point has no prose.
The return value is a cons whose car is the final selection plan and
whose cdr contains its one filtered request span record."
  (let* ((position (point))
         (probe-plan
          (proofread--selection-plan-for-ranges
           (proofread--point-probe-ranges)))
         (domains (proofread--point-target-domains probe-plan))
         (islands
          (mapcar
           (lambda (domain)
             (proofread--point-island-for-domain domain position))
           domains))
         (request-spans
          (proofread--request-spans-for-islands islands)))
    (when-let* ((span
                 (proofread--request-span-at-position
                  request-spans position))
                (domain (plist-get span :owner-domain)))
      (let* ((range
              (cons (plist-get span :beg)
                    (plist-get span :end)))
             (island
              (append (list :beg (car range) :end (cdr range))
                      domain)))
        (cons (proofread--make-selection-plan
               (list range) (list domain) (list island))
              (list span))))))

(defun proofread--request-ready-range-at-point ()
  "Return the request-ready chunk range selected by point, or nil."
  (when-let* ((selection (proofread--point-check-selection)))
    (car (proofread--selection-plan-ranges (car selection)))))

;;;; Minor mode

;;;###autoload
(define-minor-mode proofread-mode
  "Toggle context-aware proofreading in the current buffer.

When enabled and `proofread-auto-check' is non-nil, proofread
schedules an initial visible-buffer check when enabled, and further
checks after editing or window activity.  It then dispatches
request-ready visible chunks through the configured backend.  The
option `proofread-targets' controls which kinds of text are selected.
When point is on a diagnostic and `proofread-echo-area-messages' is
non-nil, its source and message are also shown through ElDoc in the
echo area.
When automatic checking is disabled, use
`proofread-check-at-point', `proofread-check-region',
`proofread-check-buffer', or `proofread-check-visible-range' manually.
Apply available suggestions with `proofread-correct-at-point',
`proofread-correct-region', `proofread-correct-buffer', or
`proofread-correct-visible-range'."
  :lighter " Proofread"
  :group 'proofread
  (if proofread-mode
      (proofread--enable-buffer)
    (proofread--disable-buffer)))

;;;; User commands

;;;###autoload
(defun proofread-check-visible-range (&optional force-feedback)
  "Check visible ranges for proofreading diagnostics.
Visible ranges come from all live windows displaying the current
buffer.  When FORCE-FEEDBACK is non-nil, report command feedback even
when routine progress messages are inhibited."
  (interactive (list t))
  (proofread--check-ranges
   (proofread--visible-ranges) "visible" force-feedback))

;;;###autoload
(defun proofread-check-buffer (&optional force-feedback)
  "Check accessible text for proofreading diagnostics.
When FORCE-FEEDBACK is non-nil, report command feedback even when
routine progress messages are inhibited."
  (interactive (list t))
  (proofread--check-ranges
   (list (cons (point-min) (point-max))) "buffer" force-feedback))

;;;###autoload
(defun proofread-check-region (beg end &optional force-feedback)
  "Check text between BEG and END for proofreading diagnostics.
Interactively, check the active region.  BEG and END may be supplied
in either order.  When FORCE-FEEDBACK is non-nil, report command
feedback even when routine progress messages are inhibited."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end) t)
     (list nil nil t)))
  (proofread--check-ranges
   (list (proofread--normalize-region-range beg end))
   "selected"
   force-feedback))

;;;###autoload
(defun proofread-check-at-point (&optional force-feedback)
  "Check the request-ready proofreading chunk at point.
When FORCE-FEEDBACK is non-nil, report command feedback even when
routine progress messages are inhibited."
  (interactive (list t))
  (proofread--require-mode)
  (let ((selection (proofread--point-check-selection)))
    (unless selection
      (user-error "No text to proofread at point"))
    (proofread--prepare-forced-check force-feedback)
    (let ((profile (proofread--current-profile)))
      (proofread--check-selection-plan
       (car selection) profile "point" force-feedback
       (cdr selection)))))

;;;###autoload
(defun proofread-show-buffer-diagnostics (&optional diagnostic)
  "Show a listing of Proofread diagnostics for the current buffer.
With optional DIAGNOSTIC, find and highlight this diagnostic in the
listing.

Interactively, use the diagnostic at point.  For mouse events in
margins and fringes, use the first diagnostic in the corresponding
line, otherwise look in the click position.

This function does not move point in the source buffer."
  (interactive
   (if (mouse-event-p last-command-event)
       (with-selected-window
           (posn-window (event-end last-command-event))
         (with-current-buffer (window-buffer)
           (let* ((event-point
                   (posn-point (event-end last-command-event)))
                  (diagnostics
                   (when event-point
                     (or (when-let* ((diagnostic
                                      (proofread-diagnostic-at-point
                                       event-point)))
                           (list diagnostic))
                         (save-excursion
                           (goto-char event-point)
                           (proofread--diagnostics-in-range
                            (line-beginning-position)
                            (line-end-position)))))))
             (unless diagnostics
               (user-error "No diagnostics here"))
             (list (car diagnostics)))))
     (list (proofread-diagnostic-at-point))))
  (unless proofread-mode
    (user-error
     "Proofread mode is not enabled in the current buffer"))
  (let* ((name (proofread--diagnostics-buffer-name))
         (source (current-buffer))
         (target (or (get-buffer name)
                     (with-current-buffer (get-buffer-create name)
                       (proofread-diagnostics-buffer-mode)
                       (current-buffer))))
         window)
    (with-current-buffer target
      (setq proofread--diagnostics-buffer-source source)
      (setq next-error-last-buffer (current-buffer))
      (revert-buffer)
      (setq window
            (display-buffer
             (current-buffer)
             `((display-buffer-reuse-window
                display-buffer-below-selected)
               (window-height . proofread--fit-list-window))))
      (when (and window diagnostic)
        (with-selected-window window
          (cl-loop initially (goto-char (point-min))
                   until (eobp)
                   until
                   (proofread--diagnostic-ui-equivalent-p
                    (plist-get (tabulated-list-get-id) :diagnostic)
                    diagnostic)
                   do (forward-line)
                   finally
                   (recenter)
                   (pulse-momentary-highlight-one-line
                    (point) 'highlight)))))
    (with-current-buffer source
      (cl-pushnew target proofread--diagnostics-list-buffers)
      (proofread--install-source-list-cleanup)
      (add-hook 'proofread-diagnostics-changed-hook
                #'proofread--refresh-diagnostics-list-buffers nil t))
    target))

;;;###autoload
(defun proofread-next ()
  "Move point to the next proofreading diagnostic."
  (interactive)
  (let ((diagnostic (proofread--next-diagnostic-after (point))))
    (cond
     (diagnostic
      (goto-char (car (proofread--diagnostic-live-range diagnostic)))
      (proofread--mark-current-diagnostic diagnostic)
      (message "proofread: moved to next diagnostic"))
     ((proofread--navigation-diagnostics)
      (user-error "No next proofread diagnostic"))
     (t
      (user-error "No proofread diagnostics")))))

;;;###autoload
(defun proofread-previous ()
  "Move point to the previous proofreading diagnostic."
  (interactive)
  (let ((diagnostic (proofread--previous-diagnostic-before (point))))
    (cond
     (diagnostic
      (goto-char (car (proofread--diagnostic-live-range diagnostic)))
      (proofread--mark-current-diagnostic diagnostic)
      (message "proofread: moved to previous diagnostic"))
     ((proofread--navigation-diagnostics)
      (user-error "No previous proofread diagnostic"))
     (t
      (user-error "No proofread diagnostics")))))

;;;###autoload
(defun proofread-describe ()
  "Describe the proofreading diagnostic at point."
  (interactive)
  (let ((diagnostic (proofread-diagnostic-at-point)))
    (if diagnostic
        (proofread--display-diagnostic-description diagnostic)
      (user-error "No proofread diagnostic at point"))))

;;;###autoload
(defun proofread-correct-at-point ()
  "Correct the proofreading diagnostic at point.
When the diagnostic has multiple suggestions, choose one using
`completing-read'.  Completion UIs such as Vertico and Consult can
provide the selection interface."
  (interactive)
  (proofread--require-mode)
  (proofread--synchronize-live-diagnostic-ranges)
  (let ((diagnostic (proofread-diagnostic-at-point)))
    (unless diagnostic
      (user-error "No proofread diagnostic at point"))
    (proofread--apply-suggestion-to-diagnostic
     diagnostic
     (proofread--select-diagnostic-suggestion diagnostic))))

(defun proofread--diagnostics-in-ranges (ranges)
  "Return accessible RANGES' diagnostics in navigation order."
  (let ((ranges (proofread--normalize-accessible-ranges ranges))
        diagnostics)
    (dolist (entry (proofread--raw-navigation-entries t))
      (let ((diagnostic (car entry))
            (range (cons (nth 1 entry) (nth 2 entry))))
        (when (proofread--range-contained-in-any-p range ranges)
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--correct-ranges (ranges scope)
  "Correct diagnostics contained in RANGES described by SCOPE."
  (proofread--require-mode)
  (proofread--synchronize-live-diagnostic-ranges)
  (let ((diagnostics (proofread--diagnostics-in-ranges ranges)))
    (unless diagnostics
      (user-error "No proofread diagnostics in %s" scope))
    (proofread--correct-diagnostics diagnostics)))

;;;###autoload
(defun proofread-correct-region (beg end)
  "Correct proofreading diagnostics contained between BEG and END.
Interactively, correct the active region.  BEG and END may be supplied
in either order."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list nil nil)))
  (proofread--correct-ranges
   (list (proofread--normalize-region-range beg end))
   "the selected region"))

;;;###autoload
(defun proofread-correct-buffer ()
  "Correct proofreading diagnostics in the accessible current buffer."
  (interactive)
  (proofread--correct-ranges
   (list (cons (point-min) (point-max))) "the accessible buffer"))

;;;###autoload
(defun proofread-correct-visible-range ()
  "Correct diagnostics in visible ranges of the current buffer.
Visible ranges come from all live windows displaying the current
buffer."
  (interactive)
  (proofread--correct-ranges
   (proofread--visible-ranges) "the visible range"))

;;;###autoload
(defun proofread-ignore ()
  "Ignore the proofreading diagnostic at point."
  (interactive)
  (let ((diagnostic (proofread-diagnostic-at-point)))
    (unless diagnostic
      (user-error "No proofread diagnostic at point"))
    (dolist (member (proofread--diagnostic-members diagnostic))
      (proofread--remove-diagnostics-matching-ignore-key
       (proofread--record-ignored-diagnostic member)))
    (message "proofread: ignored diagnostic")
    'ignored))

;;;###autoload
(defun proofread-clear ()
  "Clear proofreading diagnostics from the current buffer."
  (interactive)
  (proofread--clear-diagnostics))

;;;###autoload
(defun proofread-clear-cache ()
  "Clear cached proofreading results for the current buffer."
  (interactive)
  (proofread--require-mode)
  (when (hash-table-p proofread--cache)
    (clrhash proofread--cache))
  (setq proofread--cache-order nil)
  (proofread--clear-queued-cache-wakeups)
  (message "proofread: cleared diagnostic cache"))

;;;; Unloading

(defun proofread-unload-function ()
  "Remove Proofread state and hooks before unloading this library."
  (let ((registered-buffers
         (copy-sequence proofread--mode-buffers))
        auxiliary-buffers)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (cond
         ((bound-and-true-p proofread-mode)
          (proofread-mode -1))
         ((memq buffer registered-buffers)
          (proofread--disable-buffer)))
        (when (memq major-mode
                    '( proofread-requests-buffer-mode
                       proofread-diagnostics-buffer-mode))
          (push buffer auxiliary-buffers))))
    (dolist (buffer auxiliary-buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer))))
  (dolist (source (copy-sequence proofread--request-log-sources))
    (proofread--request-log-disable-source source))
  (clrhash proofread--request-log-owner-ids)
  (setq proofread--request-log-sources nil)
  (setq proofread--mode-buffers nil)
  (remove-variable-watcher
   'proofread-echo-area-messages
   #'proofread--echo-area-option-watcher)
  nil)

(add-variable-watcher
 'proofread-echo-area-messages
 #'proofread--echo-area-option-watcher)

(provide 'proofread)
;;; proofread.el ends here
