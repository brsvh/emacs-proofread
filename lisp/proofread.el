;;; proofread.el --- Context-aware LLM proofreading -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1") (llm "0.31.1") (posframe "1.5.2"))
;; Version: 0.1.0

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

;; Proofread mode is intended to provide asynchronous, context-aware
;; proofreading for visible text in Emacs buffers.  This file currently
;; contains the package skeleton and public command entry points.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'json)
(require 'lisp-mode)
(require 'llm)
(require 'posframe)
(require 'pp)
(require 'pulse)
(require 'subr-x)
(require 'tabulated-list)

(declare-function llm-chat-prompt-interactions "llm" (prompt))
(declare-function llm-chat-prompt-interaction-content "llm" (interaction))

(declare-function previous-error-this-buffer-no-select "simple"
                  (&optional n reset))

(defgroup proofread nil
  "Context-aware proofreading for Emacs buffers."
  :group 'convenience
  :prefix "proofread-")

(defcustom proofread-language nil
  "Language hint used by proofread backends.
When nil, backends may infer the language from buffer contents or other
configuration."
  :type '(choice (const :tag "Infer" nil)
                 string)
  :group 'proofread)

(defcustom proofread-idle-delay 1.0
  "Seconds of idle time before scheduled proofreading work may run."
  :type 'number
  :group 'proofread)

(defcustom proofread-max-chunk-size 2000
  "Maximum number of characters in a proofreading chunk."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-context-size 300
  "Maximum number of surrounding context characters sent with a chunk."
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
The limit is per buffer.  A value of 0 keeps cache hits active but prevents
new backend requests from being sent."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-backend nil
  "Selected backend used to produce proofreading diagnostics.
The symbol `llm' uses `proofread-llm-provider'.  A nil value disables backend
dispatch."
  :type '(choice (const :tag "None" nil)
                 (const :tag "Generic llm backend" llm))
  :group 'proofread)

(defcustom proofread-llm-provider nil
  "Provider object used when `proofread-backend' is `llm'.
Users should configure this with a provider constructor from the GNU ELPA
`llm' package."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-response-strategy 'auto
  "How the LLM backend requests structured diagnostics.
The value `auto' uses provider-enforced JSON schema output when the provider
advertises `json-response', and otherwise falls back to prompt-only JSON.  The
value `provider-json' requires `json-response'.  The value `prompt-json' always
uses ordinary chat output and asks the model to return only JSON."
  :type '(choice (const :tag "Auto" auto)
                 (const :tag "Provider JSON schema" provider-json)
                 (const :tag "Prompt-only JSON" prompt-json))
  :group 'proofread)

(defcustom proofread-llm-provider-identity nil
  "Stable cache identity for `proofread-llm-provider'.
When nil, proofread uses `llm-name' as a conservative fallback.  Set this to a
stable, non-secret value when provider configuration changes should invalidate
old diagnostic cache entries."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-max-diagnostic-passes 3
  "Maximum number of LLM passes used to find diagnostics for one request.
Additional passes ask only for problems not already reported.  A value of 1
uses a single LLM call."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-prompt-version "8"
  "Prompt contract version used to invalidate diagnostic cache entries."
  :type 'string
  :group 'proofread)

(defcustom proofread-cache-configuration-version 1
  "Configuration version data used to invalidate diagnostic cache entries."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-ignored-faces nil
  "Faces whose text should be skipped before proofreading requests.
The `face' text property is inspected directly.  When its value is a symbol or
a list containing any face in this option, that text is not included in
request-ready chunks."
  :type '(repeat symbol)
  :group 'proofread)

(defcustom proofread-ignored-properties nil
  "Text properties whose non-nil values should be skipped.
Each property is inspected with `get-text-property'.  Text where any configured
property has a non-nil value is not included in request-ready chunks."
  :type '(repeat symbol)
  :group 'proofread)

(defcustom proofread-popup-enabled t
  "Non-nil means show a child frame message for the diagnostic at point."
  :type 'boolean
  :group 'proofread)

(defcustom proofread-popup-max-width 80
  "Maximum width of the proofread child frame message."
  :type 'natnum
  :group 'proofread)

(defface proofread-face
  '((t :underline (:style wave)))
  "Face for proofreading diagnostics."
  :group 'proofread)

(defface proofread-current-face
  '((t :inherit proofread-face :weight bold))
  "Face for the current proofreading diagnostic."
  :group 'proofread)

(defface proofread-popup-face
  '((t :inherit default))
  "Face for proofreading child frame messages."
  :group 'proofread)

(defface proofread-popup-border-face
  '((((background dark)) :background "white")
    (((background light)) :background "black"))
  "Face for proofreading child frame borders."
  :group 'proofread)

(defconst proofread--diagnostic-keys
  '(:beg :end :text :kind :message :suggestions :confidence :source :locator)
  "Required keys for proofread diagnostic plists.")

(defconst proofread--diagnostic-kinds
  '(spelling grammar style other)
  "Diagnostic kind symbols accepted from structured responses.")

(defconst proofread--diagnostic-kind-names
  (vconcat (mapcar #'symbol-name proofread--diagnostic-kinds))
  "Diagnostic kind names accepted by the structured response schema.")

(defconst proofread--backend-request-keys
  '( :id :buffer :beg :end :text :context-before :context-after
     :language :major-mode :modified-tick :backend)
  "Required keys for proofread backend request plists.")

(defconst proofread--structured-response-instructions
  (concat
   "Return proofreading diagnostics that match the requested response "
   "schema.  Do not include Markdown, comments, prose, or reasoning outside "
   "the structured response.\n"
   "The top-level response has a diagnostics array.  Each diagnostic has "
   "kind, message, text, range, suggestions, and confidence fields.\n"
   "Report every independent problem in Text.  Do not stop after the first "
   "problem in a sentence; when one sentence has multiple misspellings, grammar "
   "issues, or style issues, return one diagnostic per issue.\n"
   "Prefer the smallest exact text range that identifies each issue, and keep "
   "diagnostics separate unless one correction requires a single combined "
   "range.\n"
   "For Chinese text, also check adjacent characters that may form one "
   "misspelled word; a diagnostic may cover multiple adjacent characters.\n"
   "Report diagnostics only for the Text section.  Use context before and "
   "context after only to understand the Text; never return ranges or text "
   "from context.\n"
   "Use zero-based chunk-relative offsets; range end is exclusive.\n"
   "The text field must exactly equal the substring selected by range.\n"
   "Use kind values spelling, grammar, style, or other.\n"
   "For suggestions, return practical replacement text in best-first order.  "
   "Include multiple suggestions when several distinct corrections are useful; "
   "one suggestion or an empty suggestions array is acceptable when there is no "
   "real alternative.\n"
   "Set confidence to null when unknown.\n"
   "Use an empty diagnostics array when there are no diagnostics.\n")
  "Provider-independent instructions for structured responses.")

(defconst proofread--structured-response-schema
  `(:type "object"
          :properties
          (:diagnostics
           (:type "array"
                  :items
                  (:type "object"
                         :properties
                         (:kind
                          (:type "string"
                                 :enum ,proofread--diagnostic-kind-names)
                          :message (:type "string")
                          :text (:type "string")
                          :range
                          (:type "object"
                                 :properties (:beg (:type "integer") :end (:type "integer"))
                                 :required ["beg" "end"]
                                 :additionalProperties ,json-false)
                          :suggestions (:type "array" :items (:type "string"))
                          :confidence (:type ["number" "null"]))
                         :required ["kind" "message" "text" "range"
                                    "suggestions" "confidence"]
                         :additionalProperties ,json-false)))
          :required ["diagnostics"]
          :additionalProperties ,json-false)
  "JSON schema requested from LLM providers for structured responses.")

(defconst proofread--overlay-category 'proofread-overlay
  "Overlay category used for proofread-owned overlays.")

(defconst proofread--description-buffer-name "*Proofread Diagnostic*"
  "Buffer name used to display proofread diagnostic descriptions.")

(defconst proofread--popup-buffer-prefix " *Proofread Popup*"
  "Prefix for hidden buffers used by proofread child frames.")

(defvar proofread--ignored-diagnostics (make-hash-table :test #'equal)
  "Session-local table of ignored proofread diagnostic keys.")

(defvar-local proofread--diagnostics nil
  "Proofread diagnostics for the current buffer.")

(defvar-local proofread--overlays nil
  "Proofread-owned overlays for the current buffer.")

(defvar-local proofread--current-diagnostic nil
  "Currently selected proofread diagnostic in the current buffer.")

(defvar-local proofread-current-diagnostic-line 0
  "Current line in a proofread diagnostics listing buffer.")

(defvar-local proofread--diagnostics-buffer-source nil
  "Source buffer for a proofread diagnostics listing buffer.")

(defvar-local proofread--popup-buffer-name nil
  "Hidden posframe buffer name for the current proofread buffer.")

(defvar-local proofread--popup-diagnostic nil
  "Diagnostic currently displayed in the proofread child frame.")

(defvar-local proofread--popup-position nil
  "Buffer position currently used for the proofread child frame.")

(defvar-local proofread--popup-window nil
  "Window where the proofread child frame was last positioned.")

(defvar-local proofread--popup-window-start nil
  "Window start used for the current proofread child frame position.")

(defvar-local proofread--popup-visible-p nil
  "Non-nil when the current proofread child frame should be visible.")

(defvar-local proofread--pending-ranges nil
  "Pending proofread ranges for the current buffer.")

(defvar-local proofread--requests nil
  "Active proofread requests for the current buffer.")

(defvar-local proofread--request-queue nil
  "Proofread requests waiting for an available backend request slot.")

(defvar-local proofread--next-request-id 0
  "Next proofread backend request id for the current buffer.")

(defvar-local proofread--cache nil
  "Proofread cache for the current buffer.")

(defvar-local proofread--pending-work nil
  "Non-nil when visible proofreading work is scheduled for this buffer.")

(defvar-local proofread--idle-timer nil
  "Idle timer scheduled for pending proofreading work in this buffer.")

(defvar proofread-mode)

(defvar warning-minimum-level)
(defvar warning-minimum-log-level)

(defvar proofread-request-log-hook nil
  "Abnormal hook run with proofread request lifecycle events.
Each function receives one plist argument.  Consumers should treat the event as
read-only and must not signal errors that interrupt proofreading.")

(defvar proofread--mode-buffers nil
  "Live buffers where `proofread-mode' has installed local hooks.")

(defvar proofread--window-hooks-installed nil
  "Non-nil when proofread global window activity hooks are installed.")

(defvar proofread--request-log-sequence 0
  "Session-local sequence for request log identifiers.")

(defun proofread--run-request-log-hook (event)
  "Run `proofread-request-log-hook' for EVENT without breaking proofreading."
  (when proofread-request-log-hook
    (run-hook-wrapped
     'proofread-request-log-hook
     (lambda (function event)
       (condition-case err
           (funcall function event)
         (error
          (message "proofread request log hook error: %s"
                   (error-message-string err))))
       nil)
     event)))

(defun proofread--record-request-event (request type &rest properties)
  "Record a lifecycle event of TYPE for REQUEST with PROPERTIES."
  (let ((event (append
                (list :type type
                      :time (current-time)
                      :log-id (plist-get request :log-id)
                      :request-id (plist-get request :id)
                      :buffer (plist-get request :buffer)
                      :beg (plist-get request :beg)
                      :end (plist-get request :end)
                      :request request)
                properties)))
    (proofread--run-request-log-hook event)
    event))

(defun proofread--make-diagnostic (&rest properties)
  "Return a proofread diagnostic plist from PROPERTIES.
The returned plist contains the keys in `proofread--diagnostic-keys'."
  (mapcan (lambda (key)
            (list key (plist-get properties key)))
          proofread--diagnostic-keys))

(defun proofread--position-integer (position)
  "Return POSITION as an integer, or nil if it is not a buffer position."
  (cond
   ((integerp position) position)
   ((markerp position) (marker-position position))))

(defun proofread--normalize-ranges (ranges)
  "Return sorted, deduplicated RANGES.
Each range is a cons cell of the form (BEG . END).  Empty or invalid ranges
are discarded.  Overlapping or adjacent ranges are merged."
  (let (normalized)
    (dolist (range
             (sort
              (delq nil
                    (mapcar
                     (lambda (range)
                       (when (consp range)
                         (let ((beg (proofread--position-integer (car range)))
                               (end (proofread--position-integer (cdr range))))
                           (when (and beg end (< beg end))
                             (cons beg end)))))
                     ranges))
              (lambda (a b)
                (< (car a) (car b)))))
      (if (and normalized (<= (car range) (cdar normalized)))
          (setcdr (car normalized) (max (cdar normalized) (cdr range)))
        (push range normalized)))
    (nreverse normalized)))

(defun proofread--visible-window-ranges ()
  "Return raw visible ranges for live windows showing the current buffer."
  (let ((buffer (current-buffer))
        ranges)
    (dolist (window (get-buffer-window-list buffer nil t))
      (when (and (window-live-p window)
                 (eq (window-buffer window) buffer))
        (let ((beg (window-start window))
              (end (window-end window t)))
          (when end
            (push (cons beg end) ranges)))))
    (nreverse ranges)))

(defun proofread--visible-ranges ()
  "Return normalized visible ranges for the current buffer."
  (proofread--normalize-ranges (proofread--visible-window-ranges)))

(defun proofread--range-nonblank-p (beg end)
  "Return non-nil if text between BEG and END contains non-whitespace."
  (save-excursion
    (goto-char beg)
    (re-search-forward "\\S-" end t)))

(defun proofread--chunk-context-before (beg)
  "Return bounded context before BEG without text properties."
  (let* ((size (max 0 proofread-context-size))
         (context-beg (max (point-min) (- beg size))))
    (buffer-substring-no-properties context-beg beg)))

(defun proofread--chunk-context-after (end)
  "Return bounded context after END without text properties."
  (let* ((size (max 0 proofread-context-size))
         (context-end (min (point-max) (+ end size))))
    (buffer-substring-no-properties end context-end)))

(defun proofread--make-chunk (beg end)
  "Return a proofread chunk plist for text between BEG and END."
  (list :beg beg
        :end end
        :text (buffer-substring-no-properties beg end)
        :major-mode major-mode
        :language proofread-language
        :context-before (proofread--chunk-context-before beg)
        :context-after (proofread--chunk-context-after end)
        :modified-tick (buffer-chars-modified-tick)))

(defun proofread--paragraph-spans-in-range (beg end)
  "Return nonblank paragraph spans between BEG and END.
Paragraphs are nonblank runs of lines separated by blank or structural lines."
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
                  (when (proofread--range-nonblank-p line-beg line-end)
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

(defconst proofread--sentence-closing-characters
  "\"'”’»）]}】》」』"
  "Characters included after sentence-ending punctuation.")

(defun proofread--sentence-ending-character-p (character)
  "Return non-nil when CHARACTER is sentence-ending punctuation."
  (memq character
        '(?。 ?！ ?？ ?! ?? ?. ?； ?\; ?…)))

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
  "Return non-nil when the period at POSITION is inside a word-like token."
  (and (eq (char-after position) ?.)
       (proofread--ascii-alnum-character-p (char-before position))
       (proofread--ascii-alnum-character-p (char-after (1+ position)))))

(defun proofread--english-abbreviation-period-p (position)
  "Return non-nil when the period at POSITION follows a common abbreviation."
  (and (eq (char-after position) ?.)
       (let ((case-fold-search t)
             (text (buffer-substring-no-properties
                    (line-beginning-position)
                    (1+ position))))
         (string-match-p
          "\\(?:\\b\\(?:Mr\\|Mrs\\|Ms\\|Dr\\|Prof\\|Sr\\|Jr\\|St\\|vs\\|etc\\)\\|\\be\\.g\\|\\bi\\.e\\|\\ba\\.m\\|\\bp\\.m\\)\\.$"
          text))))

(defun proofread--sentence-boundary-at-point-p ()
  "Return non-nil when point is at an internal sentence boundary."
  (let ((character (char-after)))
    (and (proofread--sentence-ending-character-p character)
         (not (proofread--period-between-ascii-alnum-p (point)))
         (not (proofread--english-abbreviation-period-p (point))))))

(defun proofread--sentence-boundary-end (limit)
  "Return the end of the sentence boundary at point, not beyond LIMIT."
  (save-excursion
    (while (and (< (point) limit)
                (proofread--sentence-ending-character-p (char-after)))
      (forward-char 1))
    (while (and (< (point) limit)
                (proofread--sentence-closing-character-p (char-after)))
      (forward-char 1))
    (point)))

(defun proofread--skip-sentence-separator-whitespace (limit)
  "Move point past whitespace between sentences, not beyond LIMIT."
  (while (and (< (point) limit)
              (memq (char-after) '(?\s ?\t ?\n ?\r)))
    (forward-char 1)))

(defun proofread--sentence-spans-in-paragraph (span)
  "Return sentence spans inside paragraph SPAN.
The splitter is intentionally local and punctuation-based for Chinese and
English prose.  Single hard-wrap newlines are not sentence boundaries unless
the preceding text ends with sentence punctuation."
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
                (let ((span-end (proofread--sentence-boundary-end end)))
                  (when (proofread--range-nonblank-p span-beg span-end)
                    (push (cons span-beg span-end) spans))
                  (goto-char span-end)
                  (proofread--skip-sentence-separator-whitespace end)
                  (setq span-beg (point)))
              (forward-char 1)))
          (when (proofread--range-nonblank-p span-beg end)
            (push (cons span-beg end) spans)))))
    (nreverse spans)))

(defun proofread--sentence-or-paragraph-spans (span)
  "Return sentence spans for SPAN."
  (proofread--sentence-spans-in-paragraph span))

(defun proofread--sentence-spans-for-ranges (ranges)
  "Return sentence-aware spans for visible RANGES."
  (let (spans)
    (dolist (span (proofread--paragraph-spans-for-ranges ranges))
      (dolist (sentence-span (proofread--sentence-or-paragraph-spans span))
        (push sentence-span spans)))
    (nreverse spans)))

(defun proofread--split-span-by-chunk-size (span)
  "Split SPAN into ranges no larger than `proofread-max-chunk-size'."
  (let ((beg (car span))
        (end (cdr span))
        (size (max 1 proofread-max-chunk-size))
        ranges)
    (while (< beg end)
      (let ((next (min end (+ beg size))))
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

(defun proofread--chunks-for-ranges (ranges)
  "Return proofread chunks for visible RANGES in the current buffer."
  (let (chunks)
    (dolist (span (proofread--chunk-spans-for-ranges ranges))
      (push (proofread--make-chunk (car span) (cdr span)) chunks))
    (nreverse chunks)))

(defconst proofread--url-regexp
  "\\_<https?://[^[:space:]<>(){}\"']+"
  "Regular expression matching URL text ignored before backend requests.")

(defconst proofread--email-regexp
  "\\_<[[:alnum:]._%+-]+@[[:alnum:].-]+\\.[[:alpha:]][[:alnum:].-]*\\_>"
  "Regular expression matching email text ignored before backend requests.")

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

(defun proofread--property-ranges-in-region (property predicate beg end)
  "Return PROPERTY ranges matching PREDICATE between BEG and END."
  (let ((pos beg)
        ranges)
    (while (< pos end)
      (let* ((value (get-text-property pos property))
             (next (or (next-single-property-change pos property nil end)
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
  "Return configured ignored text property ranges between BEG and END."
  (let (ranges)
    (dolist (property proofread-ignored-properties)
      (dolist (range (proofread--property-ranges-in-region
                      property #'identity beg end))
        (push range ranges)))
    (nreverse ranges)))

(defun proofread--invisible-ranges (beg end)
  "Return invisible text ranges between BEG and END."
  (proofread--property-ranges-in-region 'invisible #'identity beg end))

(defun proofread--ignored-ranges-in-region (beg end)
  "Return normalized ignored ranges between BEG and END."
  (proofread--normalize-ranges
   (append
    (proofread--regexp-ranges-in-region proofread--url-regexp beg end)
    (proofread--regexp-ranges-in-region proofread--email-regexp beg end)
    (proofread--ignored-face-ranges beg end)
    (proofread--ignored-property-ranges beg end)
    (proofread--invisible-ranges beg end))))

(defun proofread--retained-ranges (beg end ignored-ranges)
  "Return ranges between BEG and END after subtracting IGNORED-RANGES."
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
   ""))

(defun proofread--bounded-request-ready-context-before (beg)
  "Return bounded filtered character context before BEG."
  (let* ((size (max 0 proofread-context-size))
         (context-beg (max (point-min) (- beg size))))
    (proofread--substring-excluding-ranges
     context-beg beg
     (proofread--ignored-ranges-in-region context-beg beg))))

(defun proofread--bounded-request-ready-context-after (end)
  "Return bounded filtered character context after END."
  (let* ((size (max 0 proofread-context-size))
         (context-end (min (point-max) (+ end size))))
    (proofread--substring-excluding-ranges
     end context-end
     (proofread--ignored-ranges-in-region end context-end))))

(defun proofread--org-block-content-line-p ()
  "Return non-nil when point is on a line inside an Org block."
  (and (derived-mode-p 'org-mode)
       (save-excursion
         (let ((line-beg (line-beginning-position)))
           (catch 'inside
             (while (re-search-backward
                     "^[ \t]*#\\+\\(?:begin\\|end\\)_" nil t)
               (if (string-match-p
                    "\\`[ \t]*#\\+end_"
                    (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position)))
                   (throw 'inside nil)
                 (throw 'inside (< (line-beginning-position) line-beg))))
             nil)))))

(defun proofread--org-structural-line-p (line)
  "Return non-nil when LINE is an Org structural boundary."
  (and (derived-mode-p 'org-mode)
       (or (string-match-p "\\`[ \t]*\\*+\\(?:[ \t]\\|\\'\\)" line)
           (string-match-p "\\`[ \t]*#\\+[[:alpha:]_]+:" line)
           (string-match-p "\\`[ \t]*:[[:alnum:]_@#%]+:" line)
           (string-match-p "\\`[ \t]*|" line)
           (string-match-p
            "\\`[ \t]*\\(?:[-+]\\|[0-9]+[.)]\\)\\(?:[ \t]\\|\\'\\)"
            line)
           (string-match-p "\\`[ \t]+\\*\\(?:[ \t]\\|\\'\\)" line))))

(defun proofread--context-stop-line-at-point-p ()
  "Return non-nil when the current line stops context search."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (or (string-blank-p line)
        (proofread--org-structural-line-p line)
        (proofread--org-block-content-line-p))))

(defun proofread--line-end-after-newline ()
  "Return the position after the current line's terminating newline."
  (min (point-max) (1+ (line-end-position))))

(defun proofread--context-search-beg (beg)
  "Return the nearest structural context boundary before BEG."
  (save-excursion
    (let ((boundary nil))
      (goto-char (max (point-min) (min beg (point-max))))
      (beginning-of-line)
      (if (proofread--context-stop-line-at-point-p)
          (setq boundary (point))
        (while (and (not boundary) (> (point) (point-min)))
          (forward-line -1)
          (when (proofread--context-stop-line-at-point-p)
            (setq boundary (proofread--line-end-after-newline)))))
      (min beg (or boundary (point-min))))))

(defun proofread--context-search-end (end)
  "Return the nearest structural context boundary after END."
  (save-excursion
    (let ((boundary nil))
      (goto-char (max (point-min) (min end (point-max))))
      (beginning-of-line)
      (if (proofread--context-stop-line-at-point-p)
          (setq boundary end)
        (while (and (not boundary) (< (line-end-position) (point-max)))
          (forward-line 1)
          (when (proofread--context-stop-line-at-point-p)
            (setq boundary (line-beginning-position)))))
      (max end (or boundary (point-max))))))

(defun proofread--context-sentence-spans (beg end)
  "Return logical context sentence spans between BEG and END."
  (when (and (< beg end)
             (proofread--range-nonblank-p beg end))
    (proofread--sentence-spans-in-paragraph (cons beg end))))

(defun proofread--take-spans (count spans)
  "Return the first COUNT items from SPANS."
  (let (taken)
    (while (and spans (> count 0))
      (push (car spans) taken)
      (setq spans (cdr spans))
      (setq count (1- count)))
    (nreverse taken)))

(defun proofread--context-selected-spans (spans direction count)
  "Return selected SPANS for DIRECTION using COUNT sentences."
  (if (eq direction 'before)
      (last spans count)
    (proofread--take-spans count spans)))

(defun proofread--context-spans-text (spans)
  "Return filtered context text for SPANS."
  (mapconcat
   (lambda (span)
     (let ((beg (car span))
           (end (cdr span)))
       (proofread--substring-excluding-ranges
        beg end
        (proofread--ignored-ranges-in-region beg end))))
   spans
   ""))

(defun proofread--sentence-window-context
    (region-beg region-end direction count fallback)
  "Return sentence-window context in REGION-BEG to REGION-END.
DIRECTION is either `before' or `after'.  COUNT is the desired sentence count.
FALLBACK is the bounded character-window context used when sentence context is
too large for `proofread-context-size'."
  (let ((count (max 0 count))
        (size (max 0 proofread-context-size)))
    (cond
     ((zerop count) "")
     ((zerop size) "")
     (t
      (let ((spans (proofread--context-sentence-spans region-beg region-end)))
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

(defun proofread--make-request-ready-chunk (beg end)
  "Return a request-ready proofread chunk for text between BEG and END."
  (let ((text (buffer-substring-no-properties beg end)))
    (list :beg beg
          :end end
          :text text
          :major-mode major-mode
          :language proofread-language
          :context-before (proofread--request-ready-context-before beg)
          :context-after (proofread--request-ready-context-after end)
          :modified-tick (buffer-chars-modified-tick))))

(defun proofread--request-ready-chunks-from-chunk (chunk)
  "Return request-ready chunks split from paragraph CHUNK."
  (let* ((beg (plist-get chunk :beg))
         (end (plist-get chunk :end))
         (ignored-ranges (proofread--ignored-ranges-in-region beg end))
         chunks)
    (dolist (range (proofread--retained-ranges beg end ignored-ranges))
      (when (proofread--range-nonblank-p (car range) (cdr range))
        (push (proofread--make-request-ready-chunk
               (car range) (cdr range))
              chunks)))
    (nreverse chunks)))

(defun proofread--request-ready-chunks-from-chunks (chunks)
  "Return request-ready chunks filtered from paragraph CHUNKS."
  (let (request-chunks)
    (dolist (chunk chunks)
      (dolist (request-chunk (proofread--request-ready-chunks-from-chunk chunk))
        (push request-chunk request-chunks)))
    (nreverse request-chunks)))

(defun proofread--request-ready-chunks-for-ranges (ranges)
  "Return request-ready chunks for visible RANGES.
This is the internal boundary future cache lookup and backend dispatch should
consume."
  (proofread--request-ready-chunks-from-chunks
   (proofread--chunks-for-ranges ranges)))

(defun proofread--request-ready-visible-chunks ()
  "Return request-ready chunks for `proofread--pending-ranges'."
  (proofread--request-ready-chunks-for-ranges proofread--pending-ranges))

(defun proofread--next-request-id ()
  "Return a fresh backend request id for the current buffer."
  (setq proofread--next-request-id (1+ proofread--next-request-id)))

(defun proofread--make-backend-request (chunk &optional backend)
  "Return a backend request plist for request-ready CHUNK.
When BACKEND is non-nil, store its canonical identity in the request."
  (plist-put
   (mapcan
    (lambda (key)
      (list key
            (pcase key
              (:id (proofread--next-request-id))
              (:buffer (current-buffer))
              (:backend (proofread--backend-identity backend))
              (_ (plist-get chunk key)))))
    proofread--backend-request-keys)
   :log-id
   (cl-incf proofread--request-log-sequence)))

(defun proofread--backend-success-result (request diagnostics)
  "Return a successful backend result for REQUEST and DIAGNOSTICS."
  (list :status 'ok
        :request request
        :diagnostics diagnostics))

(defun proofread--backend-error-result (request error &optional message)
  "Return an error backend result for REQUEST and ERROR.
When MESSAGE is non-nil, include it as caller-readable error text."
  (let ((result (list :status 'error
                      :request request
                      :error error)))
    (if message
        (append result (list :message message))
      result)))

(defun proofread--active-request-p (request)
  "Return non-nil if REQUEST is active in the current buffer."
  (let ((id (plist-get request :id))
        active)
    (dolist (candidate proofread--requests)
      (when (equal id (plist-get candidate :id))
        (setq active t)))
    active))

(defun proofread--active-request-limit ()
  "Return the current buffer's backend request concurrency limit."
  (max 0 proofread-max-concurrent-requests))

(defun proofread--active-request-slots ()
  "Return the number of currently available backend request slots."
  (max 0 (- (proofread--active-request-limit)
            (length proofread--requests))))

(defun proofread--request-slot-available-p ()
  "Return non-nil when another backend request may be sent."
  (> (proofread--active-request-slots) 0))

(defun proofread--register-active-request (request)
  "Register REQUEST as active in the current buffer."
  (push request proofread--requests)
  request)

(defun proofread--record-active-request-handle (request handle)
  "Record backend HANDLE for active REQUEST in the current buffer."
  (let ((id (plist-get request :id))
        retained)
    (dolist (candidate proofread--requests)
      (push
       (if (equal id (plist-get candidate :id))
           (plist-put (copy-sequence candidate) :handle handle)
         candidate)
       retained))
    (setq proofread--requests (nreverse retained)))
  handle)

(defun proofread--remove-active-request (request)
  "Remove REQUEST from active request state in the current buffer."
  (let ((id (plist-get request :id))
        retained)
    (dolist (candidate proofread--requests)
      (unless (equal id (plist-get candidate :id))
        (push candidate retained)))
    (setq proofread--requests (nreverse retained))))

(defun proofread--invoke-backend-callback (callback result)
  "Invoke CALLBACK with backend RESULT when CALLBACK is non-nil."
  (when callback
    (funcall callback result)))

(defun proofread--wrap-backend-callback (request callback)
  "Return a callback that cleans REQUEST state before CALLBACK."
  (lambda (result)
    (let ((buffer (plist-get request :buffer))
          callback-value)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (proofread--remove-active-request request)))
      (unwind-protect
          (setq callback-value
                (proofread--invoke-backend-callback callback result))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when proofread-mode
              (proofread--dispatch-queued-requests)))))
      callback-value)))

(defun proofread-backend-available-p (&optional backend)
  "Return non-nil if BACKEND can accept proofreading requests.
When BACKEND is nil, check the selected `proofread-backend'."
  (pcase (or backend proofread-backend)
    ('llm (and proofread-llm-provider
               (not (null (proofread--llm-response-strategy
                           proofread-llm-provider)))))
    (_ nil)))

(defun proofread--structured-response-schema-text ()
  "Return the diagnostic response schema as JSON text."
  (json-encode proofread--structured-response-schema))

(defun proofread--prompt-json-response-contract ()
  "Return extra instructions for prompt-only JSON responses."
  (concat
   "The provider is not enforcing the schema.  Return exactly one JSON "
   "object that matches this schema, with no Markdown code fence and no "
   "other text.\n"
   "JSON schema:\n"
   (proofread--structured-response-schema-text)
   "\n"))

(defun proofread--reported-diagnostic-line (request diagnostic)
  "Return a prompt line for previously reported DIAGNOSTIC in REQUEST."
  (let ((request-beg (plist-get request :beg)))
    (format "- range [%d,%d], text %S, kind %S, message %S\n"
            (- (plist-get diagnostic :beg) request-beg)
            (- (plist-get diagnostic :end) request-beg)
            (plist-get diagnostic :text)
            (plist-get diagnostic :kind)
            (plist-get diagnostic :message))))

(defun proofread--reported-diagnostics-prompt (request diagnostics)
  "Return prompt text describing already reported DIAGNOSTICS for REQUEST."
  (when diagnostics
    (concat
     "Already reported diagnostics for this same Text:\n"
     (mapconcat
      (lambda (diagnostic)
        (proofread--reported-diagnostic-line request diagnostic))
      diagnostics
      "")
     "Return only additional diagnostics not already reported above.  Do not "
     "repeat diagnostics with the same range and text.  Scan the full Text "
     "again, especially unreported words and text spans before, after, and "
     "between the listed ranges.  Use an empty diagnostics array when no "
     "additional problems remain.\n\n")))

(defun proofread--structured-response-prompt
    (request &optional prompt-json reported-diagnostics)
  "Return the provider-independent proofreading prompt for REQUEST."
  (format
   (concat "Proofread the following text.\n\n"
           "%s\n"
           "%s"
           "%s"
           "Language: %S\n"
           "Major mode: %S\n\n"
           "Context before:\n%s\n\n"
           "Text:\n%s\n\n"
           "Context after:\n%s\n")
   proofread--structured-response-instructions
   (or (proofread--reported-diagnostics-prompt
        request reported-diagnostics)
       "")
   (if prompt-json
       (proofread--prompt-json-response-contract)
     "")
   (plist-get request :language)
   (plist-get request :major-mode)
   (or (plist-get request :context-before) "")
   (or (plist-get request :text) "")
   (or (plist-get request :context-after) "")))

(defun proofread--json-read-string (string)
  "Read STRING as JSON and return plist/list data."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((json-object-type 'plist)
          (json-array-type 'list)
          (json-key-type 'keyword)
          (json-false nil)
          value)
      (skip-chars-forward " \t\r\n")
      (setq value (json-read))
      (skip-chars-forward " \t\r\n")
      (unless (eobp)
        (error "Trailing content after JSON structured response"))
      value)))

(defun proofread--structured-response-payload (content)
  "Return structured response payload from CONTENT."
  (cond
   ((stringp content)
    (proofread--json-read-string content))
   ((listp content) content)
   (t (error "Invalid structured response content"))))

(defun proofread--diagnostic-candidates (payload)
  "Return diagnostic candidates from structured PAYLOAD."
  (unless (plist-member payload :diagnostics)
    (error "Missing diagnostics payload"))
  (let ((diagnostics (plist-get payload :diagnostics)))
    (unless (or (listp diagnostics)
                (vectorp diagnostics))
      (error "Invalid diagnostics payload"))
    (append diagnostics nil)))

(defun proofread--diagnostic-candidate-range (candidate)
  "Return CANDIDATE's chunk-relative range as a cons cell."
  (let ((range (plist-get candidate :range)))
    (when (and (listp range)
               (plist-member range :beg)
               (plist-member range :end))
      (cons (plist-get range :beg)
            (plist-get range :end)))))

(defun proofread--diagnostic-candidate-range-valid-p (request beg end)
  "Return non-nil if relative BEG and END are valid for REQUEST."
  (let ((text (plist-get request :text)))
    (and (integerp beg)
         (integerp end)
         (stringp text)
         (<= 0 beg)
         (<= beg end)
         (<= end (length text)))))

(defun proofread--string-occurrences (needle haystack)
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

(defun proofread--nearest-unique-range (target ranges)
  "Return the unique range in RANGES nearest to TARGET, or nil."
  (when (and (integerp target) ranges)
    (let ((best nil)
          (best-distance nil)
          tied)
      (dolist (range ranges)
        (let ((distance (abs (- (car range) target))))
          (cond
           ((or (not best-distance)
                (< distance best-distance))
            (setq best range)
            (setq best-distance distance)
            (setq tied nil))
           ((= distance best-distance)
            (setq tied t)))))
      (unless tied best))))

(defun proofread--diagnostic-candidate-matching-range
    (request candidate relative-beg relative-end)
  "Return CANDIDATE's corrected chunk-relative range for REQUEST.
Prefer the reported RELATIVE-BEG and RELATIVE-END when they select the reported
text exactly.  If the reported range is wrong, fall back to an exact search for
the reported text inside the request text only."
  (let* ((request-text (plist-get request :text))
         (text (plist-get candidate :text))
         (reported-range (cons relative-beg relative-end)))
    (cond
     ((and (proofread--diagnostic-candidate-range-valid-p
            request relative-beg relative-end)
           (stringp text)
           (equal text
                  (substring request-text relative-beg relative-end)))
      reported-range)
     ((and (integerp relative-beg)
           (integerp relative-end)
           (stringp text)
           (not (string-empty-p text)))
      (let ((ranges (proofread--string-occurrences text request-text)))
        (or (proofread--nearest-unique-range relative-beg ranges)
            (and (= (length ranges) 1)
                 (car ranges))))))))

(defun proofread--diagnostic-candidate-suggestions (value)
  "Return string suggestions from VALUE in original order."
  (when (or (listp value)
            (vectorp value))
    (let (strings)
      (dolist (suggestion (append value nil))
        (when (stringp suggestion)
          (push suggestion strings)))
      (nreverse strings))))

(defun proofread--diagnostic-candidate-kind (value)
  "Return normalized diagnostic kind for VALUE."
  (let ((kind
         (cond
          ((and (symbolp value)
                (not (keywordp value)))
           value)
          ((and (stringp value)
                (string-match-p "\\`[[:alnum:]_-]+\\'" value))
           (intern value)))))
    (when (memq kind proofread--diagnostic-kinds)
      kind)))

(defun proofread--diagnostic-candidate-confidence (value)
  "Return normalized diagnostic confidence for VALUE, or nil."
  (when (and (numberp value)
             (<= 0 value)
             (<= value 1))
    value))

(defun proofread--diagnostic-source (&optional default-source)
  "Return the internal source for diagnostics from a backend result."
  (or default-source 'llm))

(defun proofread--char-range-locator (beg end)
  "Return a diagnostic locator for character positions BEG through END."
  (list :kind 'char-range
        :beg beg
        :end end))

(defun proofread--shift-locator (locator offset)
  "Return LOCATOR shifted by OFFSET when it is a character range."
  (if (and (listp locator)
           (eq (plist-get locator :kind) 'char-range)
           (integerp (plist-get locator :beg))
           (integerp (plist-get locator :end)))
      (plist-put
       (plist-put (copy-sequence locator)
                  :beg (+ (plist-get locator :beg) offset))
       :end (+ (plist-get locator :end) offset))
    locator))

(defun proofread--diagnostic-from-candidate
    (request candidate &optional default-source)
  "Return proofread diagnostic for REQUEST and CANDIDATE, or nil."
  (let* ((range (proofread--diagnostic-candidate-range candidate))
         (relative-beg (car-safe range))
         (relative-end (cdr-safe range))
         (matching-range
          (proofread--diagnostic-candidate-matching-range
           request candidate relative-beg relative-end))
         (request-beg (plist-get request :beg))
         (request-text (plist-get request :text))
         (text (plist-get candidate :text))
         (kind (proofread--diagnostic-candidate-kind
                (plist-get candidate :kind)))
         (message (plist-get candidate :message))
         (absolute-beg (and (integerp request-beg)
                            (integerp (car-safe matching-range))
                            (+ request-beg (car matching-range))))
         (absolute-end (and (integerp request-beg)
                            (integerp (cdr-safe matching-range))
                            (+ request-beg (cdr matching-range)))))
    (when (and matching-range
               (stringp request-text)
               (integerp request-beg)
               (stringp text)
               kind
               (stringp message))
      (proofread--make-diagnostic
       :beg absolute-beg
       :end absolute-end
       :text text
       :kind kind
       :message message
       :suggestions (proofread--diagnostic-candidate-suggestions
                     (plist-get candidate :suggestions))
       :confidence (proofread--diagnostic-candidate-confidence
                    (plist-get candidate :confidence))
       :source (proofread--diagnostic-source default-source)
       :locator (proofread--char-range-locator absolute-beg absolute-end)))))

(defun proofread--diagnostics-from-structured-payload
    (request payload &optional default-source)
  "Return proofread diagnostics for REQUEST from parsed PAYLOAD.
DEFAULT-SOURCE is stored as each diagnostic's internal source."
  (let (diagnostics)
    (dolist (candidate (proofread--diagnostic-candidates payload))
      (let ((diagnostic
             (and (listp candidate)
                  (proofread--diagnostic-from-candidate
                   request candidate default-source))))
        (when diagnostic
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--diagnostics-from-structured-response
    (request content &optional default-source)
  "Return proofread diagnostics for REQUEST from structured response CONTENT."
  (proofread--diagnostics-from-structured-payload
   request (proofread--structured-response-payload content) default-source))

(defun proofread--llm-prompt (request strategy &optional reported-diagnostics)
  "Return an `llm-chat-prompt' for REQUEST, STRATEGY, and diagnostics."
  (pcase strategy
    ('provider-json
     (llm-make-chat-prompt
      (proofread--structured-response-prompt
       request nil reported-diagnostics)
      :response-format proofread--structured-response-schema))
    ('prompt-json
     (llm-make-chat-prompt
      (proofread--structured-response-prompt
       request t reported-diagnostics)))
    (_ (error "Unsupported llm response strategy: %S" strategy))))

(defun proofread--llm-response-content (response)
  "Return structured response content from LLM RESPONSE."
  (cond
   ((stringp response) response)
   ((and (listp response)
         (plist-member response :diagnostics))
    response)
   ((and (listp response)
         (plist-member response :text)
         (stringp (plist-get response :text)))
    (plist-get response :text))
   (t (error "Invalid llm structured response"))))

(defun proofread--llm-success-result (request response &optional pass)
  "Return backend success or parse error result for LLM RESPONSE."
  (proofread--record-request-event
   request 'backend-response
   :backend 'llm
   :pass pass
   :response response)
  (let ((result
         (condition-case err
             (proofread--backend-success-result
              request
              (proofread--diagnostics-from-structured-response
               request (proofread--llm-response-content response) 'llm))
           (error
            (proofread--backend-error-result
             request 'llm-invalid-response (error-message-string err))))))
    (proofread--record-request-event
     request 'backend-result
     :backend 'llm
     :pass pass
     :result result)
    result))

(defun proofread--llm-error-result (request error &optional message pass)
  "Return backend error result for LLM ERROR and MESSAGE."
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

(defun proofread--llm-provider-json-response-p (provider)
  "Return non-nil when PROVIDER advertises JSON response support."
  (condition-case nil
      (memq 'json-response (llm-capabilities provider))
    (error nil)))

(defun proofread--llm-response-strategy (&optional provider)
  "Return the actual LLM response strategy for PROVIDER, or nil.
When PROVIDER is nil, use `proofread-llm-provider'."
  (let ((provider (or provider proofread-llm-provider)))
    (when provider
      (pcase proofread-llm-response-strategy
        ('auto
         (if (proofread--llm-provider-json-response-p provider)
             'provider-json
           'prompt-json))
        ('provider-json
         (and (proofread--llm-provider-json-response-p provider)
              'provider-json))
        ('prompt-json 'prompt-json)
        (_ nil)))))

(defun proofread--llm-defer-callback (callback result)
  "Invoke CALLBACK with RESULT after the current call stack unwinds."
  (run-at-time 0 nil #'proofread--invoke-backend-callback callback result))

(defun proofread--llm-diagnostic-passes ()
  "Return the configured number of diagnostic LLM passes."
  (max 1 proofread-llm-max-diagnostic-passes))

(defun proofread--same-diagnostic-p (left right)
  "Return non-nil when LEFT and RIGHT describe the same diagnostic."
  (and (equal (plist-get left :beg) (plist-get right :beg))
       (equal (plist-get left :end) (plist-get right :end))
       (equal (plist-get left :text) (plist-get right :text))))

(defun proofread--diagnostic-member-p (diagnostic diagnostics)
  "Return non-nil when DIAGNOSTIC is already in DIAGNOSTICS."
  (catch 'found
    (dolist (candidate diagnostics)
      (when (proofread--same-diagnostic-p diagnostic candidate)
        (throw 'found t)))
    nil))

(defun proofread--append-new-diagnostics (diagnostics new-diagnostics)
  "Return DIAGNOSTICS followed by non-duplicate NEW-DIAGNOSTICS."
  (let ((merged (copy-sequence diagnostics)))
    (dolist (diagnostic new-diagnostics)
      (unless (proofread--diagnostic-member-p diagnostic merged)
        (setq merged (append merged (list diagnostic)))))
    merged))

(defun proofread--llm-finish-or-continue
    (request callback submit max-passes pass diagnostics result)
  "Handle one LLM RESULT for REQUEST and maybe call SUBMIT again.
MAX-PASSES is the request-local diagnostic pass limit."
  (pcase (plist-get result :status)
    ('ok
     (let* ((new-diagnostics (plist-get result :diagnostics))
            (merged (proofread--append-new-diagnostics
                     diagnostics new-diagnostics)))
       (if (and new-diagnostics
                (> (length merged) (length diagnostics))
                (< pass max-passes))
           (funcall submit (1+ pass) merged)
         (proofread--llm-defer-callback
          callback
          (proofread--backend-success-result request merged)))))
    (_
     (proofread--llm-defer-callback
      callback
      (if diagnostics
          (proofread--backend-success-result request diagnostics)
        result)))))

(defun proofread--llm-submit-passes (provider strategy request callback handle)
  "Submit REQUEST to PROVIDER using STRATEGY and record requests in HANDLE."
  (let ((max-passes (proofread--llm-diagnostic-passes)))
    (cl-labels
        ((submit
           (pass diagnostics)
           (let ((prompt (proofread--llm-prompt request strategy diagnostics)))
             (condition-case err
                 (progn
                   (proofread--record-request-event
                    request 'backend-request
                    :backend 'llm
                    :pass pass
                    :max-passes max-passes
                    :strategy strategy
                    :prompt prompt
                    :schema (llm-chat-prompt-response-format prompt)
                    :reported-diagnostics diagnostics)
                   (let ((request-handle
                          (llm-chat-async
                           provider prompt
                           (lambda (response)
                             (proofread--llm-finish-or-continue
                              request callback #'submit max-passes pass diagnostics
                              (proofread--llm-success-result
                               request response pass)))
                           (lambda (error &optional message &rest _)
                             (proofread--llm-finish-or-continue
                              request callback #'submit max-passes pass diagnostics
                              (proofread--llm-error-result
                               request error message pass))))))
                     (plist-put handle
                                :requests
                                (cons request-handle
                                      (plist-get handle :requests)))))
               (error
                (let ((result
                       (if diagnostics
                           (proofread--backend-success-result
                            request diagnostics)
                         (proofread--backend-error-result
                          request 'llm-submit-error
                          (error-message-string err)))))
                  (proofread--record-request-event
                   request 'backend-result
                   :backend 'llm
                   :pass pass
                   :result result)
                  (proofread--llm-defer-callback callback result)))))))
      (submit 1 nil)))
  handle)

(defun proofread--llm-backend-check (request callback)
  "Submit REQUEST to `proofread-llm-provider' asynchronously."
  (cond
   ((not proofread-llm-provider)
    (let ((timer
           (proofread--llm-defer-callback
            callback
            (proofread--backend-error-result
             request 'llm-provider-unavailable
             "No proofread llm provider is configured"))))
      (list :backend 'llm
            :request nil
            :timer timer)))
   ((not (proofread--llm-response-strategy proofread-llm-provider))
    (let ((timer
           (proofread--llm-defer-callback
            callback
            (proofread--backend-error-result
             request 'llm-structured-output-unavailable
             "The configured llm response strategy is unavailable"))))
      (list :backend 'llm
            :request nil
            :timer timer)))
   (t
    (let* ((provider proofread-llm-provider)
           (strategy (proofread--llm-response-strategy provider))
           (handle (list :backend 'llm
                         :requests nil)))
      (proofread--llm-submit-passes
       provider strategy request callback handle)))))

(defun proofread--unsupported-backend-check (backend request callback)
  "Report unsupported BACKEND for REQUEST through CALLBACK asynchronously."
  (run-at-time
   0 nil
   #'proofread--invoke-backend-callback
   callback
   (proofread--backend-error-result
    request
    'unsupported-backend
    (format "Unsupported proofread backend: %S" backend))))

(defun proofread-backend-check (request callback &optional backend)
  "Submit REQUEST to BACKEND and invoke CALLBACK asynchronously.
When BACKEND is nil, use `proofread-backend'.  The return value is a backend
handle."
  (let ((backend (or backend proofread-backend)))
    (pcase backend
      ('llm (proofread--llm-backend-check request callback))
      (_ (proofread--unsupported-backend-check backend request callback)))))

(defun proofread--dispatch-backend-request (request callback &optional backend)
  "Register REQUEST, submit it to BACKEND, and invoke CALLBACK on completion."
  (let ((buffer (plist-get request :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (proofread--register-active-request request))
      (proofread--record-request-event
       request 'active-request
       :backend (or backend proofread-backend))
      (let ((wrapped-callback
             (proofread--wrap-backend-callback request callback)))
        (let ((handle
               (condition-case err
                   (proofread-backend-check request wrapped-callback backend)
                 (error
                  (proofread--invoke-backend-callback
                   wrapped-callback
                   (proofread--backend-error-result
                    request err (error-message-string err)))
                  nil))))
          (when handle
            (with-current-buffer buffer
              (proofread--record-active-request-handle request handle))
            (proofread--record-request-event
             request 'backend-dispatched
             :backend (or backend proofread-backend)
             :handle handle))
          handle)))))

(defun proofread--submit-request (request backend)
  "Submit REQUEST through BACKEND when cache and concurrency permit.
Return one of the symbols `sent', `cached', `full', `stale', or `error'."
  (cond
   ((not (proofread--fresh-request-p request))
    'stale)
   ((let ((entry (proofread--cache-read-request request)))
      (when entry
        (proofread--apply-cache-entry request entry)
        t))
    'cached)
   ((not (proofread--request-slot-available-p))
    'full)
   ((proofread--dispatch-backend-request
     request #'proofread--handle-backend-result backend)
    'sent)
   (t 'error)))

(defun proofread--queue-request (request backend)
  "Queue REQUEST for BACKEND until a concurrency slot is available."
  (setq proofread--request-queue
        (nconc proofread--request-queue
               (list (list :request request
                           :backend backend))))
  (proofread--record-request-event
   request 'queued-request
   :backend backend)
  request)

(defun proofread--dispatch-queued-requests ()
  "Dispatch queued proofread requests while backend slots are available.
Return requests that were sent to the backend."
  (let ((continue t)
        requests)
    (while (and continue
                proofread--request-queue
                (proofread--request-slot-available-p))
      (let* ((entry (pop proofread--request-queue))
             (request (plist-get entry :request))
             (backend (plist-get entry :backend)))
        (pcase (proofread--submit-request request backend)
          ('sent (push request requests))
          ('full
           (setq proofread--request-queue
                 (cons entry proofread--request-queue))
           (setq continue nil)))))
    (nreverse requests)))

(defun proofread--request-range-valid-p (request)
  "Return non-nil if REQUEST range is valid in the current buffer."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (and beg end
         (<= (point-min) beg)
         (<= beg end)
         (<= end (point-max)))))

(defun proofread--request-text-matches-p (request)
  "Return non-nil if REQUEST text still matches the current buffer."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (and beg end
         (equal (buffer-substring-no-properties beg end)
                (plist-get request :text)))))

(defun proofread--fresh-request-p (request)
  "Return non-nil if REQUEST still matches its originating buffer."
  (let ((buffer (plist-get request :buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (and proofread-mode
                (equal (buffer-chars-modified-tick)
                       (plist-get request :modified-tick))
                (proofread--request-range-valid-p request)
                (proofread--request-text-matches-p request))))))

(defun proofread--backend-identity-p (value)
  "Return non-nil when VALUE is a structured proofread backend identity."
  (and (listp value)
       (plist-member value :backend)
       (plist-member value :prompt-version)))

(defvar proofread--llm-provider-identity-sequence 0
  "Sequence used for non-secret session-local LLM provider identities.")

(defvar proofread--llm-provider-session-identities (make-hash-table :test #'eq)
  "Session-local identities for LLM provider objects.")

(defun proofread--llm-provider-session-identity (provider)
  "Return a non-secret session-local identity for PROVIDER."
  (or (gethash provider proofread--llm-provider-session-identities)
      (puthash provider
               (cl-incf proofread--llm-provider-identity-sequence)
               proofread--llm-provider-session-identities)))

(defun proofread--llm-provider-name ()
  "Return a stable display name for `proofread-llm-provider', or nil."
  (when proofread-llm-provider
    (condition-case nil
        (llm-name proofread-llm-provider)
      (error nil))))

(defun proofread--llm-provider-identity ()
  "Return stable cache identity for the configured LLM provider."
  (list :backend 'llm
        :provider (if proofread-llm-provider
                      (or proofread-llm-provider-identity
                          (list :name (or (proofread--llm-provider-name)
                                          'unknown)
                                :session
                                (proofread--llm-provider-session-identity
                                 proofread-llm-provider)))
                    'unconfigured)
        :response-strategy
        (proofread--llm-response-strategy proofread-llm-provider)
        :diagnostic-passes (proofread--llm-diagnostic-passes)
        :prompt-version proofread-prompt-version))

(defun proofread--backend-identity (&optional backend)
  "Return canonical identity for BACKEND.
When BACKEND is nil, use the selected `proofread-backend'."
  (let ((backend (or backend proofread-backend)))
    (cond
     ((proofread--backend-identity-p backend) backend)
     ((null backend) nil)
     ((eq backend 'llm) (proofread--llm-provider-identity))
     (t nil))))

(defun proofread--chunk-text-hash (text)
  "Return a deterministic cache hash for chunk TEXT."
  (secure-hash 'sha1 (or text "")))

(defun proofread--context-cache-identity (chunk)
  "Return stable context identity for cache key CHUNK."
  (list :strategy 'sentence-window
        :before-sentences proofread-context-sentences-before
        :after-sentences proofread-context-sentences-after
        :size proofread-context-size
        :before-hash
        (proofread--chunk-text-hash (plist-get chunk :context-before))
        :after-hash
        (proofread--chunk-text-hash (plist-get chunk :context-after))))

(defun proofread--cache-key (chunk &optional backend)
  "Return diagnostic cache key for CHUNK and BACKEND."
  (let ((key (list :text-hash
                   (proofread--chunk-text-hash (plist-get chunk :text))
                   :language (plist-get chunk :language)
                   :major-mode (plist-get chunk :major-mode)
                   :backend (proofread--backend-identity
                             (or (plist-get chunk :backend) backend))
                   :prompt-version proofread-prompt-version
                   :context (proofread--context-cache-identity chunk)
                   :configuration-version
                   proofread-cache-configuration-version)))
    key))

(defun proofread--ensure-cache ()
  "Return the current buffer's cache table when `proofread-mode' is active."
  (when proofread-mode
    (unless (hash-table-p proofread--cache)
      (setq proofread--cache (make-hash-table :test #'equal)))
    proofread--cache))

(defun proofread--cache-read (key)
  "Return diagnostic cache entry for KEY in the current buffer."
  (let ((cache (proofread--ensure-cache)))
    (when cache
      (gethash key cache))))

(defun proofread--cache-write (key value)
  "Store VALUE under KEY in the current buffer diagnostic cache."
  (let ((cache (proofread--ensure-cache)))
    (when cache
      (puthash key value cache)
      value)))

(defun proofread--diagnostic-to-relative (diagnostic request)
  "Return DIAGNOSTIC with ranges relative to REQUEST start."
  (let* ((base (plist-get request :beg))
         (beg (plist-get diagnostic :beg))
         (end (plist-get diagnostic :end))
         (relative (copy-sequence diagnostic)))
    (setq relative (plist-put relative :beg (- beg base)))
    (setq relative (plist-put relative :end (- end base)))
    (setq relative
          (plist-put relative
                     :locator
                     (proofread--shift-locator
                      (plist-get diagnostic :locator)
                      (- base))))
    relative))

(defun proofread--diagnostic-to-absolute (diagnostic request)
  "Return cached DIAGNOSTIC with ranges absolute to REQUEST start."
  (let* ((base (plist-get request :beg))
         (beg (plist-get diagnostic :beg))
         (end (plist-get diagnostic :end))
         (absolute (copy-sequence diagnostic)))
    (setq absolute (plist-put absolute :beg (+ base beg)))
    (setq absolute (plist-put absolute :end (+ base end)))
    (setq absolute
          (plist-put absolute
                     :locator
                     (proofread--shift-locator
                      (plist-get diagnostic :locator)
                      base)))
    absolute))

(defun proofread--diagnostics-to-relative (diagnostics request)
  "Return DIAGNOSTICS converted to chunk-relative ranges for REQUEST."
  (mapcar (lambda (diagnostic)
            (proofread--diagnostic-to-relative diagnostic request))
          diagnostics))

(defun proofread--diagnostics-to-absolute (diagnostics request)
  "Return cached DIAGNOSTICS converted to absolute ranges for REQUEST."
  (mapcar (lambda (diagnostic)
            (proofread--diagnostic-to-absolute diagnostic request))
          diagnostics))

(defun proofread--make-cache-entry (request diagnostics)
  "Return cache entry for REQUEST and accepted DIAGNOSTICS."
  (list :text (plist-get request :text)
        :diagnostics
        (proofread--diagnostics-to-relative diagnostics request)))

(defun proofread--cache-read-request (request)
  "Return cache entry matching REQUEST in the current buffer."
  (proofread--cache-read
   (proofread--cache-key request (plist-get request :backend))))

(defun proofread--cache-write-request (request diagnostics)
  "Write DIAGNOSTICS for REQUEST to the current buffer cache."
  (proofread--cache-write
   (proofread--cache-key request (plist-get request :backend))
   (proofread--make-cache-entry request diagnostics)))

(defun proofread--apply-cache-entry (request entry)
  "Apply cached diagnostics from ENTRY for REQUEST when still valid."
  (when (equal (plist-get entry :text)
               (plist-get request :text))
    (proofread--record-request-event
     request 'cache-hit
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
       request 'backend-result
       :backend (plist-get request :backend)
       :source 'cache
       :entry entry
       :result result)
      (proofread--handle-backend-result result))))

(defun proofread--clear-diagnostics-in-range (beg end)
  "Remove current proofread diagnostics intersecting BEG to END."
  (proofread--invalidate-affected-diagnostics
   (proofread--overlays-intersecting-range beg end)
   (proofread--diagnostics-intersecting-range beg end)))

(defun proofread--apply-backend-diagnostics (diagnostics)
  "Record DIAGNOSTICS and create proofread-owned overlays for them."
  (let ((diagnostics (proofread--filter-ignored-diagnostics diagnostics)))
    (setq proofread--diagnostics
          (append proofread--diagnostics diagnostics))
    (dolist (diagnostic diagnostics)
      (proofread--create-overlay diagnostic))
    (proofread--popup-update)))

(defun proofread--replace-backend-diagnostics (request diagnostics)
  "Replace current diagnostics for REQUEST with DIAGNOSTICS."
  (let ((beg (proofread--position-integer (plist-get request :beg)))
        (end (proofread--position-integer (plist-get request :end))))
    (when (and beg end)
      (proofread--clear-diagnostics-in-range beg end)))
  (proofread--apply-backend-diagnostics diagnostics))

(defun proofread--handle-backend-result (result)
  "Handle backend RESULT and return an internal status symbol."
  (let* ((request (plist-get result :request))
         (buffer (plist-get request :buffer))
         (status
          (pcase (plist-get result :status)
            ('ok
             (if (proofread--fresh-request-p request)
                 (with-current-buffer buffer
                   (let ((diagnostics (plist-get result :diagnostics)))
                     (proofread--replace-backend-diagnostics
                      request diagnostics)
                     (unless (eq (plist-get result :source) 'cache)
                       (proofread--cache-write-request request diagnostics)))
                   'applied)
               'stale))
            ('error 'error)
            (_ 'error))))
    (proofread--record-request-event
     request 'final-result
     :result result
     :status status)
    status))

(defun proofread--dispatch-request-ready-chunks (chunks &optional backend)
  "Dispatch request-ready CHUNKS through BACKEND.
When BACKEND is nil, use `proofread-backend'.  Return dispatched requests."
  (when (proofread-backend-available-p backend)
    (let ((backend-identity (proofread--backend-identity backend))
          requests)
      (setq proofread--request-queue nil)
      (dolist (chunk chunks)
        (let ((request (proofread--make-backend-request chunk backend)))
          (setq request (plist-put request :backend backend-identity))
          (proofread--record-request-event
           request 'chunk-request
           :chunk chunk)
          (pcase (proofread--submit-request request backend)
            ('sent (push request requests))
            ('full (proofread--queue-request request backend)))))
      (nreverse requests))))

(defun proofread--cancel-request-handle (handle)
  "Cancel backend HANDLE when the backend supports cancellation."
  (when (and (listp handle)
             (eq (plist-get handle :backend) 'llm))
    (let ((warning-minimum-level :error)
          (warning-minimum-log-level :error))
      (dolist (request-handle
               (or (plist-get handle :requests)
                   (and (plist-get handle :request)
                        (list (plist-get handle :request)))))
        (ignore-errors
          (llm-cancel-request request-handle))))))

(defun proofread--cancel-active-requests ()
  "Cancel cancellable active backend requests for the current buffer."
  (dolist (request proofread--requests)
    (proofread--cancel-request-handle (plist-get request :handle)))
  (setq proofread--requests nil))

(defun proofread--cancel-idle-timer ()
  "Cancel the current buffer's scheduled idle timer."
  (when (timerp proofread--idle-timer)
    (cancel-timer proofread--idle-timer))
  (setq proofread--idle-timer nil))

(defun proofread--clear-scheduled-work ()
  "Clear pending scheduled proofreading work in the current buffer."
  (setq proofread--pending-work nil)
  (setq proofread--request-queue nil)
  (proofread--cancel-idle-timer))

(defun proofread--idle-timer-run (buffer)
  "Run pending visible proofreading work for BUFFER when still valid."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when proofread-mode
        (if proofread--pending-work
            (progn
              (setq proofread--pending-work nil)
              (setq proofread--idle-timer nil)
              (proofread-check-visible)
              'ran)
          (setq proofread--idle-timer nil)
          nil)))))

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
  (when proofread-mode
    (setq proofread--request-queue nil)
    (setq proofread--pending-work t)
    (proofread--schedule-idle-timer)))

(defun proofread--after-change (_beg _end _length)
  "Mark proofreading work pending after a buffer change."
  (proofread--mark-pending-work))

(defun proofread--mark-window-buffer-pending (window)
  "Mark WINDOW's buffer pending when it has active `proofread-mode'."
  (when (and (window-live-p window)
             (not (window-minibuffer-p window)))
    (let ((buffer (window-buffer window)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (proofread--mark-pending-work))))))

(defun proofread--window-scroll (window _display-start)
  "Mark WINDOW's buffer pending after scroll activity."
  (proofread--mark-window-buffer-pending window))

(defun proofread--window-configuration-change ()
  "Mark proofread buffers pending after window configuration changes."
  (dolist (window (window-list nil nil))
    (proofread--mark-window-buffer-pending window)))

(defun proofread--install-window-hooks ()
  "Install global window activity hooks used by `proofread-mode'."
  (unless proofread--window-hooks-installed
    (add-hook 'window-scroll-functions #'proofread--window-scroll)
    (add-hook 'window-configuration-change-hook
              #'proofread--window-configuration-change)
    (setq proofread--window-hooks-installed t)))

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

(defun proofread--uninstall-window-hooks-if-unused ()
  "Uninstall global window hooks when no proofread buffers remain."
  (proofread--prune-mode-buffers)
  (unless proofread--mode-buffers
    (remove-hook 'window-scroll-functions #'proofread--window-scroll)
    (remove-hook 'window-configuration-change-hook
                 #'proofread--window-configuration-change)
    (setq proofread--window-hooks-installed nil)))

(defun proofread--register-mode-buffer ()
  "Register the current buffer as using `proofread-mode' hooks."
  (setq proofread--mode-buffers
        (delq (current-buffer) proofread--mode-buffers))
  (push (current-buffer) proofread--mode-buffers)
  (proofread--install-window-hooks))

(defun proofread--unregister-mode-buffer ()
  "Unregister the current buffer from `proofread-mode' hooks."
  (setq proofread--mode-buffers
        (delq (current-buffer) proofread--mode-buffers))
  (proofread--uninstall-window-hooks-if-unused))

(defun proofread--kill-buffer ()
  "Clean up proofread scheduling state before killing the current buffer."
  (proofread--popup-delete)
  (proofread--clear-scheduled-work)
  (proofread--cancel-active-requests)
  (proofread--unregister-mode-buffer))

(defun proofread--overlay-p (overlay)
  "Return non-nil if OVERLAY is a live proofread-owned overlay."
  (and (overlayp overlay)
       (overlay-buffer overlay)
       (eq (overlay-get overlay 'category) proofread--overlay-category)))

(defun proofread--current-buffer-overlay-p (overlay)
  "Return non-nil if OVERLAY is proofread-owned in the current buffer."
  (and (proofread--overlay-p overlay)
       (eq (overlay-buffer overlay) (current-buffer))))

(defun proofread--current-buffer-overlays ()
  "Return all live proofread-owned overlays in the current buffer."
  (let (overlays)
    (save-restriction
      (widen)
      (dolist (overlay (append proofread--overlays
                               (overlays-in (point-min) (point-max))))
        (when (and (proofread--current-buffer-overlay-p overlay)
                   (not (memq overlay overlays)))
          (push overlay overlays))))
    (nreverse overlays)))

(defun proofread--prune-overlays ()
  "Synchronize `proofread--overlays' with live current-buffer overlays."
  (setq proofread--overlays (proofread--current-buffer-overlays)))

(defun proofread--delete-overlay (overlay)
  "Delete proofread-owned OVERLAY when it is live."
  (when (proofread--overlay-p overlay)
    (when (equal (overlay-get overlay 'proofread-diagnostic)
                 proofread--popup-diagnostic)
      (proofread--popup-hide))
    (delete-overlay overlay)))

(defun proofread--overlay-modified (overlay after _beg _end &optional _length)
  "Delete proofread-owned OVERLAY when its text is modified.
AFTER is non-nil for the after-change notification."
  (unless after
    (proofread--delete-overlay overlay)))

(defun proofread--diagnostic-range (diagnostic)
  "Return DIAGNOSTIC's valid range as a cons cell, or nil."
  (let ((beg (proofread--position-integer
              (plist-get diagnostic :beg)))
        (end (proofread--position-integer
              (plist-get diagnostic :end))))
    (when (and beg end (<= beg end))
      (cons beg end))))

(defun proofread--navigation-entry< (a b)
  "Return non-nil when navigation entry A should sort before B."
  (let ((a-beg (nth 1 a))
        (b-beg (nth 1 b))
        (a-end (nth 2 a))
        (b-end (nth 2 b))
        (a-index (nth 3 a))
        (b-index (nth 3 b)))
    (cond
     ((< a-beg b-beg) t)
     ((> a-beg b-beg) nil)
     ((< a-end b-end) t)
     ((> a-end b-end) nil)
     (t (< a-index b-index)))))

(defun proofread--navigation-entries ()
  "Return sorted navigation entries for current buffer diagnostics."
  (let ((index 0)
        entries)
    (dolist (diagnostic proofread--diagnostics)
      (let ((range (proofread--diagnostic-range diagnostic)))
        (when range
          (push (list diagnostic (car range) (cdr range) index)
                entries)))
      (setq index (1+ index)))
    (sort (nreverse entries)
          #'proofread--navigation-entry<)))

(defun proofread--navigation-diagnostics ()
  "Return valid proofread diagnostics sorted for navigation."
  (mapcar #'car (proofread--navigation-entries)))

(defun proofread--diagnostic-covers-position-p (diagnostic position)
  "Return non-nil when DIAGNOSTIC covers POSITION."
  (let ((range (proofread--diagnostic-range diagnostic))
        (point-position (proofread--position-integer position)))
    (and range
         point-position
         (<= (car range) point-position)
         (< point-position (cdr range)))))

(defun proofread--diagnostic-at-point (&optional position)
  "Return the proofread diagnostic covering POSITION or point.
When multiple diagnostics cover the position, return the first one in
navigation order."
  (let ((point-position (or position (point))))
    (catch 'found
      (dolist (diagnostic (proofread--navigation-diagnostics))
        (when (proofread--diagnostic-covers-position-p
               diagnostic point-position)
          (throw 'found diagnostic))))))

(defun proofread--diagnostic-ignore-key (diagnostic)
  "Return the session ignore key for DIAGNOSTIC."
  (list :text (plist-get diagnostic :text)
        :kind (plist-get diagnostic :kind)))

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
      (when (proofread--diagnostic-matches-ignore-key-p diagnostic key)
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

(defun proofread--remove-diagnostics-matching-ignore-key (key)
  "Remove current buffer diagnostics and overlays matching ignore KEY."
  (let ((diagnostics (proofread--diagnostics-matching-ignore-key key)))
    (proofread--delete-overlays-matching-ignore-key key)
    (proofread--remove-diagnostics diagnostics)
    (when (and proofread--current-diagnostic
               (proofread--diagnostic-matches-ignore-key-p
                proofread--current-diagnostic key))
      (setq proofread--current-diagnostic nil))
    diagnostics))

(defun proofread--next-diagnostic-after (position)
  "Return the nearest diagnostic strictly after POSITION."
  (catch 'found
    (let ((point-position (proofread--position-integer position)))
      (when point-position
        (dolist (entry (proofread--navigation-entries))
          (when (> (nth 1 entry) point-position)
            (throw 'found (car entry))))))))

(defun proofread--previous-diagnostic-before (position)
  "Return the nearest diagnostic strictly before POSITION."
  (let ((point-position (proofread--position-integer position))
        previous)
    (when point-position
      (dolist (entry (proofread--navigation-entries))
        (when (< (nth 1 entry) point-position)
          (setq previous (car entry))))
      previous)))

(defun proofread--clear-current-diagnostic ()
  "Clear current diagnostic state and proofread-owned highlight faces."
  (proofread--prune-overlays)
  (dolist (overlay proofread--overlays)
    (overlay-put overlay 'face 'proofread-face))
  (setq proofread--current-diagnostic nil))

(defun proofread--overlay-for-diagnostic (diagnostic)
  "Return the proofread-owned overlay for DIAGNOSTIC in the current buffer."
  (let (found)
    (proofread--prune-overlays)
    (dolist (overlay proofread--overlays)
      (when (and (not found)
                 (equal (overlay-get overlay 'proofread-diagnostic)
                        diagnostic))
        (setq found overlay)))
    found))

(defun proofread--mark-current-diagnostic (diagnostic)
  "Mark DIAGNOSTIC as current and update proofread-owned overlay faces."
  (proofread--clear-current-diagnostic)
  (setq proofread--current-diagnostic diagnostic)
  (let ((overlay (proofread--overlay-for-diagnostic diagnostic)))
    (when overlay
      (overlay-put overlay 'face 'proofread-current-face)))
  diagnostic)

;;; Per-buffer request listings

(defvar-local proofread--request-log-enabled nil
  "Non-nil when the current buffer records proofread request events.")

(defvar-local proofread--request-log-records nil
  "Hash table of proofread request records for the current buffer.")

(defvar-local proofread--request-log-list-source nil
  "Source buffer monitored by the current proofread requests buffer.")

(defvar proofread-requests-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'proofread-show-request)
    (define-key map (kbd "C-m") #'proofread-show-request)
    map)
  "Keymap for `proofread-requests-buffer-mode'.")

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

(defun proofread--request-log-ensure-records ()
  "Return the current buffer's proofread request record table."
  (unless (hash-table-p proofread--request-log-records)
    (setq proofread--request-log-records (make-hash-table :test #'equal)))
  proofread--request-log-records)

(defun proofread--request-log-hash-values (hash-table)
  "Return values from HASH-TABLE."
  (let (values)
    (maphash (lambda (_key value)
               (push value values))
             hash-table)
    (nreverse values)))

(defun proofread--request-log-event-request (event)
  "Return the proofread request stored in EVENT."
  (or (plist-get event :request)
      (plist-get (plist-get event :result) :request)))

(defun proofread--request-log-event-key (event)
  "Return the request record key for EVENT."
  (let ((request (proofread--request-log-event-request event)))
    (or (plist-get event :log-id)
        (plist-get request :log-id)
        (plist-get event :request-id)
        (plist-get request :id))))

(defun proofread--request-log-plist-append (plist property value)
  "Return PLIST with VALUE appended to list PROPERTY."
  (plist-put plist property
             (append (plist-get plist property) (list value))))

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
    ('final-result (plist-get event :status))
    (_ nil)))

(defun proofread--request-log-record-request-fields (record request event)
  "Update RECORD with REQUEST and range data from EVENT."
  (let ((request (or request (plist-get record :request))))
    (when request
      (setq record (plist-put record :request request)))
    (dolist (property '(:log-id :request-id :buffer :beg :end))
      (when (plist-member event property)
        (setq record
              (plist-put record property (plist-get event property)))))
    record))

(defun proofread--request-log-apply-event (record event)
  "Return RECORD updated with request lifecycle EVENT."
  (let* ((type (plist-get event :type))
         (time (plist-get event :time))
         (request (proofread--request-log-event-request event))
         (status (proofread--request-log-record-status type event)))
    (setq record (proofread--request-log-record-request-fields
                  record request event))
    (unless (plist-get record :created-at)
      (setq record (plist-put record :created-at time)))
    (setq record (plist-put record :updated-at time))
    (setq record (proofread--request-log-plist-append record :events event))
    (when status
      (setq record (plist-put record :status status)))
    (pcase type
      ('chunk-request
       (setq record (plist-put record :chunk (plist-get event :chunk))))
      ('backend-dispatched
       (setq record (plist-put record :handle (plist-get event :handle))))
      ('backend-request
       (setq record
             (proofread--request-log-plist-append
              record :backend-requests event)))
      ('backend-response
       (setq record
             (proofread--request-log-plist-append
              record :backend-responses event)))
      ('backend-result
       (setq record
             (proofread--request-log-plist-append
              record :backend-results (plist-get event :result))))
      ('cache-hit
       (setq record (plist-put record :cache-entry
                               (plist-get event :entry))))
      ('final-result
       (setq record (plist-put record :final-status
                               (plist-get event :status)))
       (setq record (plist-put record :final-result
                               (plist-get event :result)))))
    record))

(defun proofread--request-log-source-enabled-p (source)
  "Return non-nil when SOURCE records proofread request events."
  (and (buffer-live-p source)
       (with-current-buffer source
         proofread--request-log-enabled)))

(defun proofread--request-log-record-event (event)
  "Record a proofread request EVENT when its buffer is monitored."
  (let ((source (plist-get event :buffer))
        (key (proofread--request-log-event-key event)))
    (when (and key (proofread--request-log-source-enabled-p source))
      (with-current-buffer source
        (let* ((records (proofread--request-log-ensure-records))
               (record (or (gethash key records)
                           (list :key key
                                 :source-buffer source))))
          (setq record (proofread--request-log-apply-event record event))
          (puthash key record records)))
      (proofread--request-log-refresh-open-buffers source))))

(defun proofread--request-log-record-list (&optional source)
  "Return proofread request records for SOURCE or the current buffer."
  (with-current-buffer (or source (current-buffer))
    (sort
     (proofread--request-log-hash-values (proofread--request-log-ensure-records))
     (lambda (a b)
       (< (or (plist-get a :log-id)
              (plist-get a :request-id)
              0)
          (or (plist-get b :log-id)
              (plist-get b :request-id)
              0))))))

(defun proofread--request-log-lookup-record (source key)
  "Return request record KEY from SOURCE."
  (when (buffer-live-p source)
    (with-current-buffer source
      (and (hash-table-p proofread--request-log-records)
           (gethash key proofread--request-log-records)))))

(defun proofread--request-log-position (position)
  "Return POSITION as an integer buffer position, or nil."
  (cond
   ((integerp position) position)
   ((markerp position) (marker-position position))))

(defun proofread--request-log-source-range-valid-p (source beg end)
  "Return non-nil when BEG to END is valid in SOURCE."
  (and (buffer-live-p source)
       (with-current-buffer source
         (and (integerp beg)
              (integerp end)
              (<= (point-min) beg)
              (<= beg end)
              (<= end (point-max))))))

(defun proofread--request-log-record-range (record)
  "Return RECORD's source range as a cons cell, or nil."
  (let ((beg (proofread--request-log-position (plist-get record :beg)))
        (end (proofread--request-log-position (plist-get record :end))))
    (when (and beg end)
      (cons beg end))))

(defun proofread--request-log-record-line-column (record)
  "Return RECORD's source line and column as a cons cell."
  (let* ((source (plist-get record :source-buffer))
         (range (proofread--request-log-record-range record))
         (beg (car-safe range))
         (end (cdr-safe range)))
    (when (proofread--request-log-source-range-valid-p source beg end)
      (with-current-buffer source
        (save-excursion
          (goto-char beg)
          (cons (line-number-at-pos)
                (- (point) (line-beginning-position))))))))

(defun proofread--request-log-record-current-text (record)
  "Return RECORD's current source text, or nil when stale."
  (let* ((source (plist-get record :source-buffer))
         (range (proofread--request-log-record-range record))
         (beg (car-safe range))
         (end (cdr-safe range)))
    (when (proofread--request-log-source-range-valid-p source beg end)
      (with-current-buffer source
        (buffer-substring-no-properties beg end)))))

(defun proofread--request-log-format-time (time)
  "Return TIME formatted for request lists."
  (if time
      (format-time-string "%T" time)
    "-"))

(defun proofread--request-log-format-field (value &optional width)
  "Return VALUE as a one-line string, optionally limited to WIDTH."
  (let* ((text (cond
                ((null value) "-")
                ((stringp value) value)
                ((symbolp value) (symbol-name value))
                (t (format "%S" value))))
         (single-line (string-trim
                       (replace-regexp-in-string "[[:space:]\n\r]+"
                                                 " "
                                                 text))))
    (if (and width (> (string-width single-line) width))
        (truncate-string-to-width single-line width nil nil "...")
      single-line)))

(defun proofread--request-log-backend-label (record)
  "Return a short backend label for RECORD."
  (let* ((request (plist-get record :request))
         (backend (plist-get request :backend)))
    (cond
     ((and (listp backend) (plist-get backend :backend))
      (proofread--request-log-format-field (plist-get backend :backend)))
     (backend
      (proofread--request-log-format-field backend 10))
     (t "-"))))

(defun proofread--request-log-record-entry (record)
  "Return a tabulated list entry for request RECORD."
  (let* ((line-column (proofread--request-log-record-line-column record))
         (raw-line (car-safe line-column))
         (raw-column (cdr-safe line-column))
         (line (or raw-line 0))
         (column (or raw-column 0))
         (range (proofread--request-log-record-range record))
         (entry-id (copy-sequence record)))
    (setq entry-id (plist-put entry-id :line line))
    (setq entry-id (plist-put entry-id :column column))
    (list
     entry-id
     (vector
      (proofread--request-log-format-field
       (or (plist-get record :request-id)
           (plist-get record :log-id)))
      (proofread--request-log-format-field (plist-get record :status))
      (proofread--request-log-format-time (plist-get record :updated-at))
      (if raw-line (number-to-string raw-line) "-")
      (if raw-column (number-to-string raw-column) "-")
      (if range
          (format "%d-%d" (car range) (cdr range))
        "-")
      (proofread--request-log-backend-label record)
      (proofread--request-log-format-field
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
  (setq tabulated-list-sort-key (cons "Id" nil)))

(define-derived-mode proofread-requests-buffer-mode tabulated-list-mode
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

(defun proofread--request-log-fit-list-window (window)
  "Fit proofread request list WINDOW to its buffer."
  (fit-window-to-buffer window 15 8))

(defun proofread--request-log-source-buffer (buffer)
  "Return BUFFER as a live buffer, or signal `user-error'."
  (let ((source (if (bufferp buffer)
                    buffer
                  (get-buffer buffer))))
    (unless (buffer-live-p source)
      (user-error "No such live buffer: %S" buffer))
    source))

(defun proofread--request-log-ensure-hook ()
  "Install the proofread request log hook."
  (add-hook 'proofread-request-log-hook
            #'proofread--request-log-record-event))

(defun proofread--request-log-seed-active-requests (source)
  "Record active requests already present in SOURCE."
  (with-current-buffer source
    (dolist (request proofread--requests)
      (proofread--request-log-record-event
       (list :type 'active-request
             :time (current-time)
             :log-id (plist-get request :log-id)
             :request-id (plist-get request :id)
             :buffer source
             :beg (plist-get request :beg)
             :end (plist-get request :end)
             :request request)))))

(defun proofread--request-log-seed-queued-requests (source)
  "Record queued requests already present in SOURCE."
  (with-current-buffer source
    (dolist (entry proofread--request-queue)
      (let ((request (plist-get entry :request)))
        (proofread--request-log-record-event
         (list :type 'queued-request
               :time (current-time)
               :log-id (plist-get request :log-id)
               :request-id (plist-get request :id)
               :buffer source
               :beg (plist-get request :beg)
               :end (plist-get request :end)
               :request request
               :backend (plist-get entry :backend)))))))

(defun proofread--request-log-enable-source (source)
  "Enable proofread request recording for SOURCE."
  (with-current-buffer source
    (setq proofread--request-log-enabled t)
    (proofread--request-log-ensure-records))
  (proofread--request-log-ensure-hook)
  (proofread--request-log-seed-active-requests source)
  (proofread--request-log-seed-queued-requests source))

(defun proofread--request-log-refresh-open-buffers (source)
  "Refresh open proofread request list buffers for SOURCE."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq major-mode 'proofread-requests-buffer-mode)
                   (eq proofread--request-log-list-source source))
          (proofread--request-log-list-refresh))))))

(defun proofread--request-log-prompt-text (prompt)
  "Return a plain prompt text summary from PROMPT, or nil."
  (condition-case nil
      (mapconcat #'llm-chat-prompt-interaction-content
                 (llm-chat-prompt-interactions prompt)
                 "\n\n")
    (error nil)))

(defun proofread--request-log-backend-request-details (event)
  "Return printable backend request details for EVENT."
  (let ((prompt (plist-get event :prompt)))
    (list :backend (plist-get event :backend)
          :pass (plist-get event :pass)
          :max-passes (plist-get event :max-passes)
          :strategy (plist-get event :strategy)
          :schema (plist-get event :schema)
          :prompt-text (proofread--request-log-prompt-text prompt)
          :prompt prompt
          :reported-diagnostics
          (plist-get event :reported-diagnostics))))

(defun proofread--request-log-backend-response-details (event)
  "Return printable backend response details for EVENT."
  (list :backend (plist-get event :backend)
        :pass (plist-get event :pass)
        :response (plist-get event :response)
        :error (plist-get event :error)
        :message (plist-get event :message)))

(defun proofread--request-log-record-summary (record)
  "Return a summary plist for RECORD."
  (let ((line-column (proofread--request-log-record-line-column record)))
    (list :log-id (plist-get record :log-id)
          :request-id (plist-get record :request-id)
          :status (plist-get record :status)
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
  (let ((buffer (get-buffer-create
                 (proofread--request-log-request-buffer-name record))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (setq buffer-read-only nil)
        (erase-buffer)
        (if (fboundp 'lisp-data-mode)
            (lisp-data-mode)
          (emacs-lisp-mode))
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
This command starts recording BUFFER's future proofread request events."
  (interactive
   (list
    (read-buffer "Monitor proofread buffer: "
                 (or (and (boundp 'proofread--request-log-list-source)
                          (buffer-live-p proofread--request-log-list-source)
                          proofread--request-log-list-source)
                     (current-buffer))
                 t)))
  (let ((source (proofread--request-log-source-buffer buffer)))
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
        (revert-buffer)
        (setq window
              (display-buffer
               (current-buffer)
               `((display-buffer-reuse-window
                  display-buffer-below-selected)
                 (window-height . proofread--request-log-fit-list-window)))))
      (when window
        (set-window-point window (with-current-buffer target (point-min))))
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

;;; Per-buffer diagnostic listings

(defvar proofread-diagnostics-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'proofread-goto-diagnostic)
    (define-key map (kbd "C-m") #'proofread-goto-diagnostic)
    (define-key map (kbd "SPC") #'proofread-show-diagnostic)
    (define-key map (kbd "C-o") #'proofread-show-diagnostic)
    (when (fboundp 'next-error-this-buffer-no-select)
      (define-key map (kbd "n") #'next-error-this-buffer-no-select)
      (define-key map (kbd "p") #'previous-error-this-buffer-no-select))
    map)
  "Keymap for `proofread-diagnostics-buffer-mode'.")

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

(defun proofread--diagnostic-kind-rank (kind)
  "Return a stable sort rank for diagnostic KIND."
  (pcase kind
    ('spelling 0)
    ('grammar 1)
    ('style 2)
    (_ 3)))

(defun proofread--diagnostic-live-range (diagnostic)
  "Return DIAGNOSTIC's current live range, or nil."
  (let ((overlay (proofread--overlay-for-diagnostic diagnostic)))
    (cond
     ((and overlay
           (overlay-start overlay)
           (overlay-end overlay))
      (cons (overlay-start overlay)
            (overlay-end overlay)))
     (t
      (proofread--diagnostic-range diagnostic)))))

(defun proofread--diagnostic-line-column (diagnostic)
  "Return DIAGNOSTIC's current line and column as a cons cell."
  (let ((range (proofread--diagnostic-live-range diagnostic)))
    (when range
      (save-excursion
        (goto-char (car range))
        (cons (line-number-at-pos)
              (- (point) (line-beginning-position)))))))

(defun proofread--diagnostics-in-range (beg end)
  "Return proofread diagnostics intersecting BEG to END."
  (let (diagnostics)
    (dolist (diagnostic (proofread--navigation-diagnostics))
      (let ((range (proofread--diagnostic-live-range diagnostic)))
        (when (and range
                   (proofread--ranges-intersect-p
                    beg end (car range) (cdr range)))
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--diagnostics-list-entry (diagnostic)
  "Return a tabulated list entry for DIAGNOSTIC."
  (let* ((line-column (proofread--diagnostic-line-column diagnostic))
         (line (car line-column))
         (column (cdr line-column))
         (kind (plist-get diagnostic :kind))
         (source (plist-get diagnostic :source))
         (text (plist-get diagnostic :text))
         (message (plist-get diagnostic :message))
         (id (list :diagnostic diagnostic
                   :buffer (current-buffer)
                   :line line
                   :kind-rank (proofread--diagnostic-kind-rank kind))))
    (list
     id
     (vector
      (number-to-string line)
      (number-to-string column)
      (proofread--format-diagnostic-field kind)
      (if source (proofread--format-diagnostic-field source) "-")
      (if text (proofread--format-diagnostic-field text) "-")
      (list (if message
                (proofread--format-diagnostic-field message)
              "-")
            'mouse-face 'highlight
            'help-echo "mouse-2: visit this diagnostic"
            'face nil
            'action #'proofread-goto-diagnostic
            'mouse-action #'proofread-goto-diagnostic)))))

(defun proofread--diagnostics-list-entries ()
  "Return tabulated list entries for the current buffer diagnostics."
  (delq nil
        (mapcar (lambda (diagnostic)
                  (when (proofread--diagnostic-line-column diagnostic)
                    (proofread--diagnostics-list-entry diagnostic)))
                (proofread--navigation-diagnostics))))

(defun proofread--diagnostics-buffer-refresh ()
  "Refresh entries in the current proofread diagnostics buffer."
  (setq tabulated-list-format proofread--diagnostics-list-format)
  (setq tabulated-list-entries
        (and (buffer-live-p proofread--diagnostics-buffer-source)
             (with-current-buffer proofread--diagnostics-buffer-source
               (and proofread-mode
                    (proofread--diagnostics-list-entries)))))
  (tabulated-list-init-header))

(defun proofread--diagnostics-buffer-setup ()
  "Set up refresh and navigation for proofread diagnostics buffers."
  (setq-local next-error-function #'proofread--diagnostics-next-error)
  (let ((saved-revert-buffer-function revert-buffer-function))
    (setq revert-buffer-function
          (lambda (&rest args)
            (proofread--diagnostics-buffer-refresh)
            (apply saved-revert-buffer-function args)))))

(defun proofread-show-diagnostic (pos &optional other-window)
  "From a Proofread diagnostics buffer, show source of diagnostic at POS."
  (interactive (list (point) t))
  (let* ((diagnostics-buffer (current-buffer))
         (id (or (tabulated-list-get-id pos)
                 (user-error "Nothing at point")))
         (diagnostic (plist-get id :diagnostic))
         (source (plist-get id :buffer))
         (range (and diagnostic
                     (buffer-live-p source)
                     (with-current-buffer source
                       (proofread--diagnostic-live-range diagnostic)))))
    (unless (and (buffer-live-p source) range)
      (user-error "Proofread diagnostic is stale"))
    (setq proofread-current-diagnostic-line (line-number-at-pos pos))
    (with-current-buffer source
      (with-selected-window
          (display-buffer (current-buffer) other-window)
        (goto-char (car range))
        (proofread--mark-current-diagnostic diagnostic)
        (pulse-momentary-highlight-region
         (car range) (cdr range)))
      (setq next-error-last-buffer diagnostics-buffer)
      (current-buffer))))

(defun proofread-goto-diagnostic (pos)
  "From a Proofread diagnostics buffer, go to source of diagnostic at POS."
  (interactive "d")
  (pop-to-buffer
   (proofread-show-diagnostic
    (if (button-type pos)
        (button-start pos)
      pos))))

(defun proofread--diagnostics-next-error (n &optional reset)
  "Move N diagnostics in a proofread diagnostics buffer.
When RESET is non-nil, move from the beginning of the buffer."
  (let ((line (if reset 1 proofread-current-diagnostic-line))
        (total-lines (count-lines (point-min) (point-max))))
    (goto-char (point-min))
    (unless (zerop total-lines)
      (forward-line
       (1- (max 1 (min total-lines (+ line n))))))
    (when-let* ((window (get-buffer-window nil t)))
      (set-window-point window (point)))
    (proofread-goto-diagnostic (point))))

(define-derived-mode proofread-diagnostics-buffer-mode tabulated-list-mode
  "Proofread diagnostics"
  "A mode for listing Proofread diagnostics."
  :interactive nil
  (proofread--diagnostics-buffer-setup))

(defun proofread--diagnostics-buffer-name ()
  "Return the diagnostics buffer name for the current buffer."
  (format "*Proofread diagnostics for `%s'*" (current-buffer)))

(defun proofread--fit-diagnostics-window (window)
  "Fit proofread diagnostics WINDOW to its buffer."
  (fit-window-to-buffer window 15 8))

(defun proofread--popup-buffer ()
  "Return the hidden buffer name used for the current proofread child frame."
  (or proofread--popup-buffer-name
      (setq proofread--popup-buffer-name
            (generate-new-buffer-name proofread--popup-buffer-prefix))))

(defun proofread--popup-available-p ()
  "Return non-nil when proofread can show a child frame."
  (and proofread-popup-enabled
       (posframe-workable-p)))

(defun proofread--popup-selected-buffer-p ()
  "Return non-nil when the selected window displays the current buffer."
  (eq (window-buffer (selected-window))
      (current-buffer)))

(defun proofread--popup-window-start-position ()
  "Return the selected window start as an integer position."
  (proofread--position-integer
   (window-start (selected-window))))

(defun proofread--popup-message (diagnostic)
  "Return the child frame message for DIAGNOSTIC."
  (let ((message (plist-get diagnostic :message)))
    (cond
     ((and (stringp message)
           (not (string-empty-p (string-trim message))))
      (string-trim message))
     (message
      (proofread--format-diagnostic-field message))
     ((plist-get diagnostic :text)
      (format "Proofread: %s"
              (proofread--format-diagnostic-field
               (plist-get diagnostic :text))))
     (t "Proofread diagnostic"))))

(defun proofread--face-color (face attribute)
  "Return FACE color ATTRIBUTE, or nil if unspecified."
  (let ((value (face-attribute face attribute nil t)))
    (unless (eq value 'unspecified)
      value)))

(defun proofread--popup-diagnostic-at-point ()
  "Return the visible proofread diagnostic at point, or nil."
  (let ((diagnostic (proofread--diagnostic-at-point)))
    (when (and diagnostic
               (proofread--overlay-for-diagnostic diagnostic))
      diagnostic)))

(defun proofread--popup-needs-refresh-p (diagnostic position)
  "Return non-nil when the child frame needs DIAGNOSTIC at POSITION."
  (not (and (eq diagnostic proofread--popup-diagnostic)
            (equal position proofread--popup-position)
            (eq (selected-window) proofread--popup-window)
            (equal (proofread--popup-window-start-position)
                   proofread--popup-window-start))))

(defun proofread--popup-hide ()
  "Hide the current proofread child frame."
  (when (and proofread--popup-buffer-name
             proofread--popup-visible-p)
    (posframe-hide proofread--popup-buffer-name))
  (setq proofread--popup-diagnostic nil)
  (setq proofread--popup-position nil)
  (setq proofread--popup-window nil)
  (setq proofread--popup-window-start nil)
  (setq proofread--popup-visible-p nil))

(defun proofread--popup-delete ()
  "Delete the current proofread child frame and hidden buffer."
  (when proofread--popup-buffer-name
    (posframe-delete proofread--popup-buffer-name))
  (setq proofread--popup-buffer-name nil)
  (setq proofread--popup-diagnostic nil)
  (setq proofread--popup-position nil)
  (setq proofread--popup-window nil)
  (setq proofread--popup-window-start nil)
  (setq proofread--popup-visible-p nil))

(defun proofread--popup-show (diagnostic)
  "Show DIAGNOSTIC's message in a child frame."
  (let ((range (proofread--diagnostic-range diagnostic)))
    (if (and range
             (proofread--popup-selected-buffer-p)
             (proofread--popup-available-p))
        (let ((position (car range))
              (message (proofread--popup-message diagnostic)))
          (posframe-show
           (proofread--popup-buffer)
           :string (propertize message 'face 'proofread-popup-face)
           :position position
           :poshandler
           #'posframe-poshandler-point-bottom-left-corner-upward
           :foreground-color
           (proofread--face-color 'proofread-popup-face :foreground)
           :background-color
           (proofread--face-color 'proofread-popup-face :background)
           :max-width (max 1 proofread-popup-max-width)
           :min-width 1
           :internal-border-width 1
           :internal-border-color
           (proofread--face-color 'proofread-popup-border-face :background)
           :left-fringe 3
           :right-fringe 3
           :accept-focus nil
           :override-parameters
           '((no-accept-focus . t)
             (no-focus-on-map . t)
             (cursor-type . nil)
             (no-special-glyphs . t)
             (desktop-dont-save . t))
           :hidehandler #'posframe-hidehandler-when-buffer-switch)
          (setq proofread--popup-diagnostic diagnostic)
          (setq proofread--popup-position position)
          (setq proofread--popup-window (selected-window))
          (setq proofread--popup-window-start
                (proofread--popup-window-start-position))
          (setq proofread--popup-visible-p t))
      (proofread--popup-hide))))

(defun proofread--popup-update ()
  "Update the proofread child frame for the diagnostic at point."
  (if (and proofread-mode
           proofread-popup-enabled
           (proofread--popup-selected-buffer-p))
      (let* ((diagnostic (proofread--popup-diagnostic-at-point))
             (range (and diagnostic
                         (proofread--diagnostic-range diagnostic)))
             (position (car-safe range)))
        (if (and diagnostic position)
            (when (proofread--popup-needs-refresh-p diagnostic position)
              (proofread--popup-show diagnostic))
          (proofread--popup-hide)))
    (proofread--popup-hide)))

(defun proofread--format-diagnostic-field (value)
  "Return VALUE formatted for a diagnostic description."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun proofread--diagnostic-suggestions (diagnostic)
  "Return DIAGNOSTIC suggestions as strings in stored order."
  (let ((suggestions (plist-get diagnostic :suggestions)))
    (cond
     ((null suggestions) nil)
     ((listp suggestions)
      (mapcar #'proofread--format-diagnostic-field suggestions))
     (t (list (proofread--format-diagnostic-field suggestions))))))

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

(defun proofread--application-range (diagnostic)
  "Return DIAGNOSTIC's valid in-buffer application range."
  (let ((range (proofread--diagnostic-range diagnostic)))
    (unless (and range
                 (<= (point-min) (car range))
                 (<= (car range) (cdr range))
                 (<= (cdr range) (point-max)))
      (user-error "Invalid proofread diagnostic range"))
    range))

(defun proofread--validate-suggestion-application (diagnostic)
  "Validate DIAGNOSTIC for suggestion application and return its range."
  (let* ((range (proofread--application-range diagnostic))
         (beg (car range))
         (end (cdr range))
         (text (plist-get diagnostic :text)))
    (unless (proofread--overlay-for-diagnostic diagnostic)
      (user-error "Proofread diagnostic is stale"))
    (unless (stringp text)
      (user-error "Invalid proofread diagnostic text"))
    (unless (equal (buffer-substring-no-properties beg end) text)
      (user-error "Proofread diagnostic text no longer matches"))
    range))

(defun proofread--ranges-intersect-p (beg end other-beg other-end)
  "Return non-nil if BEG to END intersects OTHER-BEG to OTHER-END."
  (and (< beg other-end)
       (< other-beg end)))

(defun proofread--overlays-intersecting-range (beg end)
  "Return proofread-owned overlays intersecting BEG to END."
  (let (overlays)
    (proofread--prune-overlays)
    (dolist (overlay proofread--overlays)
      (let ((overlay-beg (overlay-start overlay))
            (overlay-end (overlay-end overlay)))
        (when (and overlay-beg
                   overlay-end
                   (proofread--ranges-intersect-p
                    beg end overlay-beg overlay-end))
          (push overlay overlays))))
    (nreverse overlays)))

(defun proofread--diagnostic-intersects-range-p (diagnostic beg end)
  "Return non-nil if DIAGNOSTIC intersects BEG to END."
  (let ((range (proofread--diagnostic-range diagnostic)))
    (and range
         (proofread--ranges-intersect-p
          beg end (car range) (cdr range)))))

(defun proofread--diagnostics-intersecting-range (beg end)
  "Return proofread diagnostics intersecting BEG to END."
  (let (diagnostics)
    (dolist (diagnostic proofread--diagnostics)
      (when (proofread--diagnostic-intersects-range-p diagnostic beg end)
        (push diagnostic diagnostics)))
    (nreverse diagnostics)))

(defun proofread--remove-diagnostics (diagnostics)
  "Remove DIAGNOSTICS from current buffer proofread state."
  (setq proofread--diagnostics
        (delq nil
              (mapcar (lambda (diagnostic)
                        (unless (member diagnostic diagnostics)
                          diagnostic))
                      proofread--diagnostics))))

(defun proofread--invalidate-affected-diagnostics (overlays diagnostics)
  "Invalidate proofread-owned OVERLAYS and DIAGNOSTICS after text changes."
  (dolist (overlay overlays)
    (proofread--delete-overlay overlay))
  (proofread--remove-diagnostics diagnostics)
  (when (and proofread--current-diagnostic
             (member proofread--current-diagnostic diagnostics))
    (setq proofread--current-diagnostic nil))
  (proofread--prune-overlays))

(defun proofread--apply-suggestion-to-diagnostic (diagnostic suggestion)
  "Replace DIAGNOSTIC's range with SUGGESTION and invalidate stale state."
  (let* ((range (proofread--validate-suggestion-application diagnostic))
         (beg (car range))
         (end (cdr range))
         (affected-overlays (proofread--overlays-intersecting-range beg end))
         (affected-diagnostics
          (proofread--diagnostics-intersecting-range beg end)))
    (undo-boundary)
    (delete-region beg end)
    (goto-char beg)
    (insert suggestion)
    (proofread--invalidate-affected-diagnostics
     affected-overlays affected-diagnostics)
    (undo-boundary)
    (message "proofread: applied suggestion")
    'applied))

(defun proofread--format-diagnostic-description (diagnostic)
  "Return a stable plain-text description for DIAGNOSTIC."
  (let ((kind (plist-get diagnostic :kind))
        (message (plist-get diagnostic :message))
        (text (plist-get diagnostic :text))
        (suggestions (proofread--diagnostic-suggestions diagnostic))
        (confidence (plist-get diagnostic :confidence))
        (source (plist-get diagnostic :source))
        (lines '("Proofread diagnostic")))
    (when kind
      (setq lines
            (append lines
                    (list ""
                          (format "Kind: %s"
                                  (proofread--format-diagnostic-field
                                   kind))))))
    (when message
      (setq lines
            (append lines
                    (list (format "Message: %s"
                                  (proofread--format-diagnostic-field
                                   message))))))
    (when text
      (setq lines
            (append lines
                    (list ""
                          "Original text:"
                          (proofread--format-diagnostic-field text)))))
    (when suggestions
      (setq lines (append lines (list "" "Suggestions:")))
      (let ((index 1))
        (dolist (suggestion suggestions)
          (setq lines
                (append lines
                        (list (format "%d. %s"
                                      index
                                      (proofread--format-diagnostic-field
                                       suggestion)))))
          (setq index (1+ index)))))
    (when confidence
      (setq lines
            (append lines
                    (list ""
                          (format "Confidence: %s"
                                  (proofread--format-diagnostic-field
                                   confidence))))))
    (when source
      (setq lines
            (append lines
                    (list (format "Source: %s"
                                  (proofread--format-diagnostic-field
                                   source))))))
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
    (let ((overlay (make-overlay beg end)))
      (overlay-put overlay 'category proofread--overlay-category)
      (overlay-put overlay 'face 'proofread-face)
      (overlay-put overlay 'proofread-diagnostic diagnostic)
      (overlay-put overlay 'modification-hooks
                   '(proofread--overlay-modified))
      (push overlay proofread--overlays)
      overlay)))

(defun proofread--clear-overlays ()
  "Delete proofread-owned overlays in the current buffer."
  (proofread--popup-hide)
  (dolist (overlay (proofread--current-buffer-overlays))
    (delete-overlay overlay))
  (setq proofread--overlays nil)
  (setq proofread--current-diagnostic nil)
  (force-window-update (current-buffer)))

(defun proofread--initialize-buffer-state ()
  "Initialize proofread-owned state for the current buffer."
  (setq-local proofread--diagnostics nil)
  (setq-local proofread--overlays nil)
  (setq-local proofread--current-diagnostic nil)
  (setq-local proofread--popup-buffer-name nil)
  (setq-local proofread--popup-diagnostic nil)
  (setq-local proofread--popup-position nil)
  (setq-local proofread--popup-window nil)
  (setq-local proofread--popup-window-start nil)
  (setq-local proofread--popup-visible-p nil)
  (setq-local proofread--pending-ranges nil)
  (setq-local proofread--requests nil)
  (setq-local proofread--request-queue nil)
  (setq-local proofread--next-request-id 0)
  (setq-local proofread--cache (make-hash-table :test #'equal))
  (setq-local proofread--pending-work nil)
  (setq-local proofread--idle-timer nil))

(defun proofread--clear-buffer-state ()
  "Clear proofread-owned state for the current buffer."
  (proofread--clear-scheduled-work)
  (proofread--cancel-active-requests)
  (proofread--clear-overlays)
  (proofread--popup-delete)
  (setq proofread--diagnostics nil)
  (setq proofread--current-diagnostic nil)
  (setq proofread--pending-ranges nil)
  (setq proofread--request-queue nil)
  (setq proofread--next-request-id 0)
  (setq proofread--cache nil))

(defun proofread--enable-buffer ()
  "Enable proofread buffer-local hooks and state in the current buffer."
  (proofread--initialize-buffer-state)
  (add-hook 'after-change-functions #'proofread--after-change nil t)
  (add-hook 'post-command-hook #'proofread--popup-update nil t)
  (add-hook 'kill-buffer-hook #'proofread--kill-buffer nil t)
  (proofread--register-mode-buffer))

(defun proofread--disable-buffer ()
  "Disable proofread buffer-local hooks and state in the current buffer."
  (remove-hook 'after-change-functions #'proofread--after-change t)
  (remove-hook 'post-command-hook #'proofread--popup-update t)
  (remove-hook 'kill-buffer-hook #'proofread--kill-buffer t)
  (proofread--clear-buffer-state)
  (proofread--unregister-mode-buffer))

(defun proofread--command-placeholder (command)
  "Report that COMMAND has not been implemented yet."
  (message "proofread: `%s' is not implemented yet" command))

;;;###autoload
(define-minor-mode proofread-mode
  "Toggle context-aware proofreading in the current buffer.

When enabled, proofread schedules visible-buffer checks after editing and
window activity, then dispatches request-ready visible chunks through the
configured backend."
  :lighter " Proofread"
  :group 'proofread
  (if proofread-mode
      (proofread--enable-buffer)
    (proofread--disable-buffer)))

;;;###autoload
(defun proofread-check-visible ()
  "Check visible text in the current buffer for proofreading diagnostics."
  (interactive)
  (setq proofread--pending-ranges (proofread--visible-ranges))
  (if (proofread-backend-available-p)
      (let* ((chunks (proofread--request-ready-visible-chunks))
             (requests (proofread--dispatch-request-ready-chunks chunks))
             (queued (length proofread--request-queue)))
        (message "proofread: dispatched %d request%s%s from %d visible range%s"
                 (length requests)
                 (if (= (length requests) 1) "" "s")
                 (if (> queued 0)
                     (format "; queued %d" queued)
                   "")
                 (length proofread--pending-ranges)
                 (if (= (length proofread--pending-ranges) 1) "" "s")))
    (message "proofread: collected %d visible range%s; no available backend"
             (length proofread--pending-ranges)
             (if (= (length proofread--pending-ranges) 1) "" "s"))))

;;;###autoload
(defun proofread-check-buffer ()
  "Check the current buffer for proofreading diagnostics."
  (interactive)
  (proofread--command-placeholder 'proofread-check-buffer))

;;;###autoload
(defun proofread-show-buffer-diagnostics (&optional diagnostic)
  "Show a listing of Proofread diagnostics for the current buffer.
With optional DIAGNOSTIC, find and highlight this diagnostic in the listing.

Interactively, use the diagnostic at point.  For mouse events in margins and
fringes, use the first diagnostic in the corresponding line, otherwise look in
the click position.

This function does not move point in the source buffer."
  (interactive
   (if (mouse-event-p last-command-event)
       (with-selected-window (posn-window (event-end last-command-event))
         (with-current-buffer (window-buffer)
           (let* ((event-point (posn-point (event-end last-command-event)))
                  (diagnostics
                   (when event-point
                     (or (when-let* ((diagnostic
                                      (proofread--diagnostic-at-point
                                       event-point)))
                           (list diagnostic))
                         (save-excursion
                           (goto-char event-point)
                           (proofread--diagnostics-in-range
                            (line-beginning-position)
                            (line-end-position)))))))
             (unless diagnostics
               (error "No diagnostics here"))
             (list (car diagnostics)))))
     (list (proofread--diagnostic-at-point))))
  (unless proofread-mode
    (user-error "Proofread mode is not enabled in the current buffer"))
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
               (window-height . proofread--fit-diagnostics-window))))
      (when (and window diagnostic)
        (with-selected-window window
          (cl-loop initially (goto-char (point-min))
                   until (eobp)
                   until (eq (plist-get (tabulated-list-get-id)
                                        :diagnostic)
                             diagnostic)
                   do (forward-line)
                   finally
                   (recenter)
                   (pulse-momentary-highlight-one-line
                    (point) 'highlight)))))))

;;;###autoload
(defun proofread-next ()
  "Move point to the next proofreading diagnostic."
  (interactive)
  (let ((diagnostic (proofread--next-diagnostic-after (point))))
    (cond
     (diagnostic
      (goto-char (car (proofread--diagnostic-range diagnostic)))
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
      (goto-char (car (proofread--diagnostic-range diagnostic)))
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
  (let ((diagnostic (proofread--diagnostic-at-point)))
    (if diagnostic
        (proofread--display-diagnostic-description diagnostic)
      (user-error "No proofread diagnostic at point"))))

(defun proofread--correct-at-point ()
  "Apply a selected proofreading suggestion at point."
  (let ((diagnostic (proofread--diagnostic-at-point)))
    (unless diagnostic
      (user-error "No proofread diagnostic at point"))
    (proofread--apply-suggestion-to-diagnostic
     diagnostic
     (proofread--select-diagnostic-suggestion diagnostic))))

;;;###autoload
(defun proofread-correct ()
  "Correct the proofreading diagnostic at point.
When the diagnostic has multiple suggestions, choose one using
`completing-read'.  Completion UIs such as Vertico and Consult can provide the
selection interface."
  (interactive)
  (proofread--correct-at-point))

;;;###autoload
(defun proofread-ignore ()
  "Ignore the proofreading diagnostic at point."
  (interactive)
  (let ((diagnostic (proofread--diagnostic-at-point))
        key)
    (unless diagnostic
      (user-error "No proofread diagnostic at point"))
    (setq key (proofread--record-ignored-diagnostic diagnostic))
    (proofread--remove-diagnostics-matching-ignore-key key)
    (message "proofread: ignored diagnostic")
    'ignored))

;;;###autoload
(defun proofread-clear ()
  "Clear proofreading overlays from the current buffer."
  (interactive)
  (proofread--clear-overlays))

(provide 'proofread)

;;; proofread.el ends here
