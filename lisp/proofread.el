;;; proofread.el --- Context-aware LLM proofreading -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1") (jieba-rs "0.1.0") (llm "0.31.1"))
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
(require 'json)
(require 'llm)
(require 'subr-x)

(declare-function jieba-rs-forward-sentence "jieba-rs" (&optional arg))
(declare-function jieba-rs-module-segment "jieba-rs" (text hmm))

(defvar jieba-rs-hmm)
(defvar jieba-rs-segment-function)
(defvar jieba-rs-user-dict)

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

(defcustom proofread-max-concurrent-requests 2
  "Maximum number of proofreading backend requests active at once."
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
`llm' package, such as `make-llm-ollama'."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-llm-provider-identity nil
  "Stable cache identity for `proofread-llm-provider'.
When nil, proofread uses `llm-name' as a conservative fallback.  Set this to a
stable, non-secret value when provider configuration changes should invalidate
old diagnostic cache entries."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-prompt-version "2"
  "Prompt contract version used to invalidate diagnostic cache entries."
  :type 'string
  :group 'proofread)

(defcustom proofread-cache-configuration-version 1
  "Configuration version data used to invalidate diagnostic cache entries."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-token-map-enabled t
  "Non-nil means build Chinese token maps for LLM diagnostics.
Token maps are included in prompts as auxiliary locator hints.  They never
replace chunk-relative range and exact text validation."
  :type 'boolean
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

(defface proofread-face
  '((t :underline (:style wave)))
  "Face for proofreading diagnostics."
  :group 'proofread)

(defface proofread-current-face
  '((t :inherit proofread-face :weight bold))
  "Face for the current proofreading diagnostic."
  :group 'proofread)

(defconst proofread--diagnostic-keys
  '(:beg :end :text :kind :message :suggestions :confidence :source)
  "Required keys for proofread diagnostic plists.")

(defconst proofread--backend-request-keys
  '( :id :buffer :beg :end :text :context-before :context-after
     :language :major-mode :modified-tick :backend :tokens :tokenization)
  "Required keys for proofread backend request plists.")

(defconst proofread--json-diagnostic-prompt-contract
  (concat
   "Return only one JSON object.  Do not include Markdown, comments, "
   "prose, or reasoning outside the JSON object.\n"
   "The JSON object must have this shape:\n"
   "{\"diagnostics\":[{\"kind\":\"spelling|grammar|style|other\","
   "\"message\":\"short explanation\","
   "\"text\":\"exact original text\","
   "\"range\":{\"beg\":0,\"end\":0},"
   "\"token_index\":0,"
   "\"token_range\":{\"beg\":0,\"end\":1},"
   "\"suggestions\":[\"replacement\"],"
   "\"confidence\":0.0,"
   "\"source\":\"optional source\"}]}\n"
   "Use zero-based chunk-relative offsets; range end is exclusive.\n"
   "The text field must exactly equal the substring selected by range.\n"
   "Token fields are optional locator hints only when a token list is "
   "provided; range and text remain required.\n"
   "Use {\"diagnostics\":[]} when there are no diagnostics.\n")
  "Prompt contract for JSON diagnostics.")

(defconst proofread--json-diagnostic-response-format
  '(:type
    "object"
    :properties
    (:diagnostics
     (:type
      "array"
      :items
      (:type
       "object"
       :properties
       (:kind (:type "string")
              :message (:type "string")
              :text (:type "string")
              :range
              (:type
               "object"
               :properties (:beg (:type "integer") :end (:type "integer"))
               :required ["beg" "end"])
              :token_index (:type "integer")
              :token_range
              (:type
               "object"
               :properties (:beg (:type "integer") :end (:type "integer"))
               :required ["beg" "end"])
              :suggestions (:type "array" :items (:type "string"))
              :confidence (:type "number")
              :source (:type "string"))
       :required ["kind" "message" "text" "range" "suggestions"])))
    :required ["diagnostics"])
  "JSON response format requested from generic LLM providers.")

(defconst proofread--overlay-category 'proofread-overlay
  "Overlay category used for proofread-owned overlays.")

(defconst proofread--description-buffer-name "*Proofread Diagnostic*"
  "Buffer name used to display proofread diagnostic descriptions.")

(defvar proofread--ignored-diagnostics (make-hash-table :test #'equal)
  "Session-local table of ignored proofread diagnostic keys.")

(defvar-local proofread--diagnostics nil
  "Proofread diagnostics for the current buffer.")

(defvar-local proofread--overlays nil
  "Proofread-owned overlays for the current buffer.")

(defvar-local proofread--current-diagnostic nil
  "Currently selected proofread diagnostic in the current buffer.")

(defvar-local proofread--pending-ranges nil
  "Pending proofread ranges for the current buffer.")

(defvar-local proofread--requests nil
  "Active proofread requests for the current buffer.")

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

(defvar proofread--mode-buffers nil
  "Live buffers where `proofread-mode' has installed local hooks.")

(defvar proofread--window-hooks-installed nil
  "Non-nil when proofread global window activity hooks are installed.")

(defun proofread--make-diagnostic (&rest properties)
  "Return a proofread diagnostic plist from PROPERTIES.
The returned plist contains the keys in `proofread--diagnostic-keys'."
  (mapcan (lambda (key)
            (list key (plist-get properties key)))
          proofread--diagnostic-keys))

(defun proofread--diagnostic-get (diagnostic property)
  "Return PROPERTY from DIAGNOSTIC."
  (plist-get diagnostic property))

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
Paragraphs are nonblank runs of lines separated by one or more blank lines."
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
            (if (proofread--range-nonblank-p line-beg line-end)
                (progn
                  (unless paragraph-beg
                    (setq paragraph-beg line-beg))
                  (setq paragraph-end line-end))
              (when paragraph-beg
                (push (cons paragraph-beg paragraph-end) spans)
                (setq paragraph-beg nil)
                (setq paragraph-end nil)))
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

(defun proofread--sentence-boundary-available-p ()
  "Return non-nil when Chinese sentence boundary movement is available."
  (or (fboundp 'jieba-rs-forward-sentence)
      (and (require 'jieba-rs nil t)
           (fboundp 'jieba-rs-forward-sentence))))

(defun proofread--forward-sentence-boundary (limit)
  "Move to the next sentence boundary before LIMIT and return point.
Return nil when sentence boundary movement is unavailable, fails, does not move
point, or moves outside LIMIT."
  (when (proofread--sentence-boundary-available-p)
    (let ((origin (point)))
      (condition-case nil
          (progn
            (jieba-rs-forward-sentence 1)
            (if (and (> (point) origin)
                     (<= (point) limit))
                (point)
              (goto-char origin)
              nil))
        (error
         (goto-char origin)
         nil)))))

(defun proofread--sentence-spans-in-paragraph (span)
  "Return sentence spans inside paragraph SPAN, or nil if unavailable."
  (let ((beg (car span))
        (end (cdr span))
        spans
        moved)
    (save-mark-and-excursion
      (save-restriction
        (narrow-to-region beg end)
        (goto-char beg)
        (while (< (point) end)
          (let ((span-beg (point))
                (span-end (proofread--forward-sentence-boundary end)))
            (if span-end
                (progn
                  (when (proofread--range-nonblank-p span-beg span-end)
                    (push (cons span-beg span-end) spans))
                  (setq moved t)
                  (goto-char span-end))
              (goto-char end)
              (when (proofread--range-nonblank-p span-beg end)
                (push (cons span-beg end) spans)))))))
    (when (and moved spans)
      (nreverse spans))))

(defun proofread--sentence-or-paragraph-spans (span)
  "Return sentence spans for SPAN, falling back to paragraph SPAN."
  (or (proofread--sentence-spans-in-paragraph span)
      (list span)))

(defun proofread--sentence-spans-for-ranges (ranges)
  "Return sentence-aware spans for visible RANGES."
  (let (spans)
    (dolist (span (proofread--paragraph-spans-for-ranges ranges))
      (dolist (sentence-span (proofread--sentence-or-paragraph-spans span))
        (push sentence-span spans)))
    (nreverse spans)))

(defun proofread--chinese-character-p (character)
  "Return non-nil when CHARACTER is in a common CJK range."
  (or (<= #x4e00 character #x9fff)
      (<= #x3400 character #x4dbf)
      (<= #x20000 character #x2a6df)))

(defun proofread--chinese-text-p (text)
  "Return non-nil when TEXT contains Chinese characters."
  (and (stringp text)
       (catch 'found
         (cl-loop for character across text
                  when (proofread--chinese-character-p character)
                  do (throw 'found t))
         nil)))

(defun proofread--chinese-language-p (language)
  "Return non-nil when LANGUAGE identifies Chinese text."
  (and (stringp language)
       (string-match-p "\\`zh\\(?:\\'\\|[-_]\\)" language)))

(defun proofread--tokenization-target-p (text &optional language)
  "Return non-nil when TEXT and LANGUAGE should receive token metadata."
  (and proofread-token-map-enabled
       (stringp text)
       (not (string-empty-p text))
       (or (proofread--chinese-language-p language)
           (proofread--chinese-text-p text))))

(defun proofread--jieba-tokenization-available-p ()
  "Return non-nil when `jieba-rs' word tokenization is available."
  (and proofread-token-map-enabled
       (or (fboundp 'jieba-rs-module-segment)
           (and (require 'jieba-rs nil t)
                (fboundp 'jieba-rs-module-segment)))))

(defun proofread--jieba-hmm ()
  "Return the current `jieba-rs' HMM setting."
  (if (boundp 'jieba-rs-hmm)
      (symbol-value 'jieba-rs-hmm)
    t))

(defun proofread--jieba-segment-function ()
  "Return the configured `jieba-rs' segmentation function."
  (let ((configured (and (boundp 'jieba-rs-segment-function)
                         (symbol-value 'jieba-rs-segment-function))))
    (cond
     ((and (symbolp configured)
           (fboundp configured))
      configured)
     ((fboundp 'jieba-rs-module-segment)
      #'jieba-rs-module-segment))))

(defun proofread--jieba-token-output (text)
  "Return raw `jieba-rs' token output for TEXT, or nil."
  (when (proofread--jieba-tokenization-available-p)
    (let ((function (proofread--jieba-segment-function)))
      (when function
        (condition-case nil
            (condition-case nil
                (funcall function text (proofread--jieba-hmm))
              (wrong-number-of-arguments
               (funcall function text)))
          (error nil))))))

(defun proofread--sequence-list (value)
  "Return VALUE as a list when VALUE is a list or vector."
  (cond
   ((listp value) value)
   ((vectorp value) (append value nil))))

(defun proofread--token-item-word (item)
  "Return token word text from segmentation ITEM."
  (cond
   ((stringp item) item)
   ((and (listp item)
         (plist-member item :word)
         (stringp (plist-get item :word)))
    (plist-get item :word))))

(defun proofread--token-item-category (item)
  "Return token category from segmentation ITEM, or nil."
  (when (and (listp item)
             (plist-member item :category))
    (plist-get item :category)))

(defun proofread--blank-token-p (text)
  "Return non-nil when TEXT contains only whitespace."
  (string-match-p "\\`[[:space:]\n\r\t]*\\'" text))

(defun proofread--tokens-from-items (text items)
  "Return token plists for TEXT from segmentation ITEMS.
Return nil when ITEMS cannot be mapped exactly onto TEXT."
  (let ((position 0)
        (index 0)
        tokens)
    (catch 'invalid
      (dolist (item items)
        (let* ((word (proofread--token-item-word item))
               (category (proofread--token-item-category item)))
          (unless (stringp word)
            (throw 'invalid nil))
          (let* ((end (+ position (length word)))
                 (token-text (and (<= end (length text))
                                  (substring text position end))))
            (unless (equal word token-text)
              (throw 'invalid nil))
            (unless (or (string-empty-p word)
                        (proofread--blank-token-p word))
              (let ((token (list :index index
                                 :beg position
                                 :end end
                                 :text word)))
                (when category
                  (setq token (plist-put token :category category)))
                (push token tokens)
                (setq index (1+ index))))
            (setq position end))))
      (when (= position (length text))
        (nreverse tokens)))))

(defun proofread--tokens-for-text (text &optional language)
  "Return chunk-relative tokens for TEXT and LANGUAGE, or nil."
  (when (proofread--tokenization-target-p text language)
    (let ((items (proofread--sequence-list
                  (proofread--jieba-token-output text))))
      (when items
        (proofread--tokens-from-items text items)))))

(defun proofread--user-dict-identity ()
  "Return deterministic identity for `jieba-rs-user-dict', or nil."
  (let ((file (and (boundp 'jieba-rs-user-dict)
                   (symbol-value 'jieba-rs-user-dict))))
    (when (and (stringp file)
               (file-exists-p file))
      (let ((attributes (file-attributes file)))
        (list :file (file-truename file)
              :mtime (file-attribute-modification-time attributes)
              :size (file-attribute-size attributes))))))

(defun proofread--tokenization-identity ()
  "Return stable identity for tokenization-affecting configuration."
  (when proofread-token-map-enabled
    (list :enabled t
          :function (proofread--jieba-segment-function)
          :hmm (proofread--jieba-hmm)
          :prompt-version proofread-prompt-version
          :user-dict (proofread--user-dict-identity))))

(defun proofread--split-span-by-token-boundaries (span)
  "Split SPAN by token boundaries when possible.
Return nil when token-boundary splitting is unavailable or cannot keep all
chunks within `proofread-max-chunk-size'."
  (let* ((beg (car span))
         (end (cdr span))
         (text (buffer-substring-no-properties beg end))
         (tokens (proofread--tokens-for-text text))
         (size (max 1 proofread-max-chunk-size))
         ranges
         (relative-beg 0))
    (when tokens
      (catch 'fallback
        (while (< relative-beg (length text))
          (let* ((limit (min (length text) (+ relative-beg size)))
                 boundary)
            (dolist (token tokens)
              (let ((token-end (plist-get token :end)))
                (when (and (< relative-beg token-end)
                           (<= token-end limit))
                  (setq boundary token-end))))
            (unless boundary
              (throw 'fallback nil))
            (push (cons (+ beg relative-beg)
                        (+ beg boundary))
                  ranges)
            (setq relative-beg boundary)))
        (nreverse ranges)))))

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
      (dolist (chunk-span (or (proofread--split-span-by-token-boundaries span)
                              (proofread--split-span-by-chunk-size span)))
        (push chunk-span spans)))
    (nreverse spans)))

(defun proofread--chunks-for-ranges (ranges)
  "Return proofread chunks for visible RANGES in the current buffer."
  (let (chunks)
    (dolist (span (proofread--chunk-spans-for-ranges ranges))
      (push (proofread--make-chunk (car span) (cdr span)) chunks))
    (nreverse chunks)))

(defun proofread--visible-chunks ()
  "Return paragraph chunks for `proofread--pending-ranges'."
  (proofread--chunks-for-ranges proofread--pending-ranges))

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

(defun proofread--sentence-ending-character-p (character)
  "Return non-nil when CHARACTER is sentence-ending punctuation."
  (memq character
        '(?。 ?！ ?？ ?! ?? ?. ?； ?\; ?…)))

(defun proofread--hard-wrap-sentence-boundary-p (left _right)
  "Return non-nil when LEFT and _RIGHT meet at a hard-wrap newline."
  (let ((end (cdr left)))
    (and (> end (car left))
         (eq (char-before end) ?\n)
         (> (1- end) (car left))
         (not (proofread--sentence-ending-character-p
               (char-before (1- end)))))))

(defun proofread--merge-hard-wrapped-sentence-spans (spans)
  "Return SPANS with hard-wrap newline sentence boundaries merged."
  (let (merged)
    (dolist (span spans)
      (if (and merged
               (proofread--hard-wrap-sentence-boundary-p
                (car merged) span))
          (setcdr (car merged) (cdr span))
        (push (cons (car span) (cdr span)) merged)))
    (nreverse merged)))

(defun proofread--context-sentence-spans (beg end)
  "Return logical context sentence spans between BEG and END.
Return the symbol `fallback' when sentence spans cannot be computed for
nonblank text."
  (cond
   ((not (< beg end)) nil)
   ((not (proofread--range-nonblank-p beg end)) nil)
   ((not (proofread--sentence-boundary-available-p)) 'fallback)
   (t
    (let ((spans (proofread--sentence-spans-in-paragraph (cons beg end))))
      (if spans
          (proofread--merge-hard-wrapped-sentence-spans spans)
        'fallback)))))

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
unavailable or a single context sentence is too large."
  (let ((count (max 0 count))
        (size (max 0 proofread-context-size)))
    (cond
     ((zerop count) "")
     ((zerop size) "")
     (t
      (let ((spans (proofread--context-sentence-spans region-beg region-end)))
        (cond
         ((eq spans 'fallback) fallback)
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
  (let* ((text (buffer-substring-no-properties beg end))
         (tokens (proofread--tokens-for-text text proofread-language))
         (chunk (list :beg beg
                      :end end
                      :text text
                      :major-mode major-mode
                      :language proofread-language
                      :context-before (proofread--request-ready-context-before
                                       beg)
                      :context-after (proofread--request-ready-context-after
                                      end)
                      :modified-tick (buffer-chars-modified-tick))))
    (if tokens
        (append chunk
                (list :tokens tokens
                      :tokenization (proofread--tokenization-identity)))
      chunk)))

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
  (mapcan
   (lambda (key)
     (list key
           (pcase key
             (:id (proofread--next-request-id))
             (:buffer (current-buffer))
             (:backend (proofread--backend-identity backend))
             (_ (plist-get chunk key)))))
   proofread--backend-request-keys))

(defun proofread--backend-requests-from-chunks (chunks)
  "Return backend request plists for request-ready CHUNKS."
  (mapcar #'proofread--make-backend-request chunks))

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
    (let ((buffer (plist-get request :buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (proofread--remove-active-request request))))
    (proofread--invoke-backend-callback callback result)))

(defun proofread--llm-provider-available-p ()
  "Return non-nil when `proofread-llm-provider' is configured."
  (not (null proofread-llm-provider)))

(defun proofread-backend-available-p (&optional backend)
  "Return non-nil if BACKEND can accept proofreading requests.
When BACKEND is nil, check the selected `proofread-backend'."
  (pcase (or backend proofread-backend)
    ('llm (proofread--llm-provider-available-p))
    (_ nil)))

(defun proofread--diagnostic-token-contract (request)
  "Return token locator prompt text for REQUEST, or an empty string."
  (when (plist-get request :tokens)
    (concat
     "Token locators are optional hints.  When you can localize a "
     "diagnostic to the token list below, include token_index for one token "
     "or token_range with token indexes where end is exclusive.  The "
     "diagnostic range and text fields are still required and authoritative.\n")))

(defun proofread--format-token-for-prompt (token)
  "Return one prompt line for TOKEN."
  (format "%d [%d,%d] %S"
          (plist-get token :index)
          (plist-get token :beg)
          (plist-get token :end)
          (plist-get token :text)))

(defun proofread--diagnostic-token-list (request)
  "Return formatted token list text for REQUEST, or an empty string."
  (let ((tokens (plist-get request :tokens)))
    (if tokens
        (concat
         "\nTokens:\n"
         (mapconcat #'proofread--format-token-for-prompt tokens "\n")
         "\n")
      "")))

(defun proofread--diagnostic-prompt (request)
  "Return the provider-independent proofreading prompt for REQUEST."
  (format
   (concat "Proofread the following text.\n\n"
           "%s\n"
           "%s"
           "Language: %S\n"
           "Major mode: %S\n\n"
           "Context before:\n%s\n\n"
           "Text:\n%s\n\n"
           "Context after:\n%s\n"
           "%s")
   proofread--json-diagnostic-prompt-contract
   (or (proofread--diagnostic-token-contract request) "")
   (plist-get request :language)
   (plist-get request :major-mode)
   (or (plist-get request :context-before) "")
   (or (plist-get request :text) "")
   (or (plist-get request :context-after) "")
   (proofread--diagnostic-token-list request)))

(defun proofread--json-encode (value)
  "Return JSON encoding for VALUE."
  (json-encode value))

(defun proofread--json-read-string (string)
  "Read STRING as JSON and return plist/list data."
  (let ((json-object-type 'plist)
        (json-array-type 'list)
        (json-key-type 'keyword)
        (json-false nil))
    (json-read-from-string string)))

(defun proofread--json-diagnostic-object-substrings (string)
  "Return top-level JSON object substrings found in STRING."
  (let ((index 0)
        (length (length string))
        (depth 0)
        start
        in-string
        escape
        objects)
    (while (< index length)
      (let ((char (aref string index)))
        (cond
         ((and (> depth 0) escape)
          (setq escape nil))
         ((and (> depth 0) in-string (eq char ?\\))
          (setq escape t))
         ((and (> depth 0) (eq char ?\"))
          (setq in-string (not in-string)))
         (in-string nil)
         ((eq char ?{)
          (when (= depth 0)
            (setq start index))
          (setq depth (1+ depth)))
         ((and (> depth 0) (eq char ?}))
          (setq depth (1- depth))
          (when (= depth 0)
            (push (substring string start (1+ index)) objects)
            (setq start nil)))))
      (setq index (1+ index)))
    (nreverse objects)))

(defun proofread--json-diagnostic-parse-json (content)
  "Parse one JSON diagnostic object from CONTENT."
  (let ((objects (proofread--json-diagnostic-object-substrings content)))
    (unless (= (length objects) 1)
      (error "Expected exactly one diagnostic JSON object"))
    (proofread--json-read-string (car objects))))

(defun proofread--json-diagnostic-payload (content)
  "Return parsed diagnostic payload from CONTENT."
  (cond
   ((stringp content)
    (proofread--json-diagnostic-parse-json content))
   ((listp content) content)
   (t (error "Invalid diagnostic response content"))))

(defun proofread--json-diagnostic-candidates (payload)
  "Return diagnostic candidates from parsed PAYLOAD."
  (unless (plist-member payload :diagnostics)
    (error "Missing diagnostics payload"))
  (let ((diagnostics (plist-get payload :diagnostics)))
    (unless (listp diagnostics)
      (error "Invalid diagnostics payload"))
    diagnostics))

(defun proofread--json-diagnostic-range (candidate)
  "Return CANDIDATE's chunk-relative range as a cons cell."
  (let ((range (plist-get candidate :range)))
    (when (and (listp range)
               (plist-member range :beg)
               (plist-member range :end))
      (cons (plist-get range :beg)
            (plist-get range :end)))))

(defun proofread--json-diagnostic-range-valid-p (request beg end)
  "Return non-nil if relative BEG and END are valid for REQUEST."
  (let ((text (plist-get request :text)))
    (and (integerp beg)
         (integerp end)
         (stringp text)
         (<= 0 beg)
         (<= beg end)
         (<= end (length text)))))

(defun proofread--json-diagnostic-suggestions (value)
  "Return string suggestions from VALUE in original order."
  (when (listp value)
    (let (strings)
      (dolist (suggestion value)
        (when (stringp suggestion)
          (push suggestion strings)))
      (nreverse strings))))

(defun proofread--json-diagnostic-kind (value)
  "Return normalized diagnostic kind for VALUE."
  (cond
   ((and (symbolp value)
         (not (keywordp value)))
    value)
   ((and (stringp value)
         (string-match-p "\\`[[:alnum:]_-]+\\'" value))
    (intern value))))

(defun proofread--json-diagnostic-confidence (value)
  "Return normalized diagnostic confidence for VALUE, or nil."
  (when (and (numberp value)
             (<= 0 value)
             (<= value 1))
    value))

(defun proofread--json-diagnostic-source (candidate &optional default-source)
  "Return normalized diagnostic source from CANDIDATE.
When CANDIDATE has no valid source, use DEFAULT-SOURCE or `llm'."
  (let ((value (plist-get candidate :source)))
    (cond
     ((and (plist-member candidate :source)
           (symbolp value)
           (not (keywordp value)))
      value)
     ((and (plist-member candidate :source)
           (stringp value)
           (not (string= value "")))
      value)
     (t (or default-source 'llm)))))

(defun proofread--token-by-index (tokens index)
  "Return token with INDEX from TOKENS, or nil."
  (catch 'found
    (dolist (token tokens)
      (when (equal index (plist-get token :index))
        (throw 'found token)))
    nil))

(defun proofread--json-diagnostic-token-index-range (request index)
  "Return chunk-relative text range for token INDEX in REQUEST."
  (when (integerp index)
    (let ((token (proofread--token-by-index
                  (plist-get request :tokens)
                  index)))
      (when token
        (cons (plist-get token :beg)
              (plist-get token :end))))))

(defun proofread--json-diagnostic-token-range-field (candidate)
  "Return CANDIDATE's token index range as a cons cell, or nil."
  (let ((range (plist-get candidate :token_range)))
    (when (and (listp range)
               (plist-member range :beg)
               (plist-member range :end))
      (cons (plist-get range :beg)
            (plist-get range :end)))))

(defun proofread--json-diagnostic-token-indexes-range
    (request beg end)
  "Return chunk-relative text range for token indexes BEG through END.
END is exclusive.  Return nil when the token indexes cannot be mapped."
  (let* ((tokens (plist-get request :tokens))
         (first (and (integerp beg)
                     (proofread--token-by-index tokens beg)))
         (last (and (integerp end)
                    (< beg end)
                    (proofread--token-by-index tokens (1- end)))))
    (when (and first last)
      (cons (plist-get first :beg)
            (plist-get last :end)))))

(defun proofread--json-diagnostic-token-locator-ranges
    (request candidate)
  "Return interpretable token locator ranges for CANDIDATE.
Malformed token locators are ignored."
  (let (ranges)
    (let ((index (plist-get candidate :token_index)))
      (when (integerp index)
        (let ((range
               (proofread--json-diagnostic-token-index-range
                request index)))
          (when range
            (push range ranges)))))
    (let ((token-range
           (proofread--json-diagnostic-token-range-field candidate)))
      (when token-range
        (let ((range
               (proofread--json-diagnostic-token-indexes-range
                request (car token-range) (cdr token-range))))
          (when range
            (push range ranges)))))
    (nreverse ranges)))

(defun proofread--json-diagnostic-token-locator-consistent-p
    (request candidate relative-beg relative-end text)
  "Return non-nil when CANDIDATE token locators do not contradict range.
REQUEST, RELATIVE-BEG, RELATIVE-END, and TEXT describe the already-validated
authoritative diagnostic location."
  (let ((ranges (proofread--json-diagnostic-token-locator-ranges
                 request candidate))
        (expected (cons relative-beg relative-end))
        (request-text (plist-get request :text))
        inconsistent)
    (dolist (range ranges)
      (unless (and (equal range expected)
                   (equal text (substring request-text
                                          (car range)
                                          (cdr range))))
        (setq inconsistent t)))
    (not inconsistent)))

(defun proofread--json-diagnostic-from-candidate
    (request candidate &optional default-source)
  "Return proofread diagnostic for REQUEST and CANDIDATE, or nil."
  (let* ((range (proofread--json-diagnostic-range candidate))
         (relative-beg (car-safe range))
         (relative-end (cdr-safe range))
         (request-beg (plist-get request :beg))
         (request-text (plist-get request :text))
         (text (plist-get candidate :text))
         (kind (proofread--json-diagnostic-kind
                (plist-get candidate :kind)))
         (message (plist-get candidate :message)))
    (when (and (proofread--json-diagnostic-range-valid-p
                request relative-beg relative-end)
               (integerp request-beg)
               (stringp text)
               kind
               (stringp message)
               (equal text
                      (substring request-text relative-beg relative-end))
               (proofread--json-diagnostic-token-locator-consistent-p
                request candidate relative-beg relative-end text))
      (proofread--make-diagnostic
       :beg (+ request-beg relative-beg)
       :end (+ request-beg relative-end)
       :text text
       :kind kind
       :message message
       :suggestions (proofread--json-diagnostic-suggestions
                     (plist-get candidate :suggestions))
       :confidence (proofread--json-diagnostic-confidence
                    (plist-get candidate :confidence))
       :source (proofread--json-diagnostic-source
                candidate default-source)))))

(defun proofread--json-diagnostics-from-payload
    (request payload &optional default-source)
  "Return proofread diagnostics for REQUEST from parsed PAYLOAD.
DEFAULT-SOURCE is used for diagnostics without an explicit source."
  (let (diagnostics)
    (dolist (candidate (proofread--json-diagnostic-candidates payload))
      (let ((diagnostic
             (and (listp candidate)
                  (proofread--json-diagnostic-from-candidate
                   request candidate default-source))))
        (when diagnostic
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--diagnostic-payload (content)
  "Return parsed diagnostic payload from generated CONTENT."
  (proofread--json-diagnostic-payload content))

(defun proofread--diagnostics-from-payload
    (request payload &optional default-source)
  "Return proofread diagnostics for REQUEST from parsed PAYLOAD."
  (proofread--json-diagnostics-from-payload
   request payload default-source))

(defun proofread--diagnostics-from-content
    (request content &optional default-source)
  "Return proofread diagnostics for REQUEST from generated CONTENT."
  (proofread--diagnostics-from-payload
   request (proofread--diagnostic-payload content) default-source))

(defun proofread--llm-prompt (request)
  "Return an `llm-chat-prompt' for backend REQUEST."
  (llm-make-chat-prompt
   (proofread--diagnostic-prompt request)
   :response-format proofread--json-diagnostic-response-format))

(defun proofread--llm-response-text (response)
  "Return generated text from an LLM RESPONSE."
  (cond
   ((stringp response) response)
   ((and (listp response)
         (plist-member response :text)
         (stringp (plist-get response :text)))
    (plist-get response :text))
   (t (error "Invalid llm response text"))))

(defun proofread--llm-success-result (request response)
  "Return backend success or parse error result for LLM RESPONSE."
  (condition-case err
      (proofread--backend-success-result
       request
       (proofread--diagnostics-from-content
        request (proofread--llm-response-text response) 'llm))
    (error
     (proofread--backend-error-result
      request 'llm-invalid-response (error-message-string err)))))

(defun proofread--llm-error-result (request error &optional message)
  "Return backend error result for LLM ERROR and MESSAGE."
  (proofread--backend-error-result
   request
   (or error 'llm-error)
   (if message
       (format "%s" message)
     (format "%S" error))))

(defun proofread--llm-defer-callback (callback result)
  "Invoke CALLBACK with RESULT after the current call stack unwinds."
  (run-at-time 0 nil #'proofread--invoke-backend-callback callback result))

(defun proofread--llm-backend-check (request callback)
  "Submit REQUEST to `proofread-llm-provider' asynchronously."
  (if (not proofread-llm-provider)
      (let ((timer
             (proofread--llm-defer-callback
              callback
              (proofread--backend-error-result
               request 'llm-provider-unavailable
               "No proofread llm provider is configured"))))
        (list :backend 'llm
              :request nil
              :timer timer))
    (let* ((provider proofread-llm-provider)
           (prompt (proofread--llm-prompt request))
           (handle
            (condition-case err
                (llm-chat-async
                 provider prompt
                 (lambda (response)
                   (proofread--llm-defer-callback
                    callback
                    (proofread--llm-success-result request response)))
                 (lambda (error &optional message &rest _)
                   (proofread--llm-defer-callback
                    callback
                    (proofread--llm-error-result
                     request error message))))
              (error
               (proofread--llm-defer-callback
                callback
                (proofread--backend-error-result
                 request 'llm-submit-error (error-message-string err)))
               nil))))
      (list :backend 'llm
            :request handle))))

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
              (proofread--record-active-request-handle request handle)))
          handle)))))

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

(defun proofread--cache-backend-identity (&optional backend)
  "Return BACKEND identity for cache keys.
When BACKEND is nil, use the currently selected `proofread-backend'."
  (proofread--backend-identity backend))

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
                   :backend (proofread--cache-backend-identity
                             (or (plist-get chunk :backend) backend))
                   :prompt-version proofread-prompt-version
                   :context (proofread--context-cache-identity chunk)
                   :configuration-version
                   proofread-cache-configuration-version)))
    (if (plist-get chunk :tokenization)
        (append key (list :tokenization (plist-get chunk :tokenization)))
      key)))

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
         (beg (proofread--diagnostic-get diagnostic :beg))
         (end (proofread--diagnostic-get diagnostic :end))
         (relative (copy-sequence diagnostic)))
    (setq relative (plist-put relative :beg (- beg base)))
    (setq relative (plist-put relative :end (- end base)))
    relative))

(defun proofread--diagnostic-to-absolute (diagnostic request)
  "Return cached DIAGNOSTIC with ranges absolute to REQUEST start."
  (let* ((base (plist-get request :beg))
         (beg (proofread--diagnostic-get diagnostic :beg))
         (end (proofread--diagnostic-get diagnostic :end))
         (absolute (copy-sequence diagnostic)))
    (setq absolute (plist-put absolute :beg (+ base beg)))
    (setq absolute (plist-put absolute :end (+ base end)))
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
    (proofread--handle-backend-result
     (list :status 'ok
           :source 'cache
           :request request
           :diagnostics
           (proofread--diagnostics-to-absolute
            (plist-get entry :diagnostics)
            request)))))

(defun proofread--apply-backend-diagnostics (diagnostics)
  "Record DIAGNOSTICS and create proofread-owned overlays for them."
  (let ((diagnostics (proofread--filter-ignored-diagnostics diagnostics)))
    (setq proofread--diagnostics
          (append proofread--diagnostics diagnostics))
    (dolist (diagnostic diagnostics)
      (proofread--create-overlay diagnostic))))

(defun proofread--handle-backend-result (result)
  "Handle backend RESULT and return an internal status symbol."
  (let* ((request (plist-get result :request))
         (buffer (plist-get request :buffer)))
    (pcase (plist-get result :status)
      ('ok
       (if (proofread--fresh-request-p request)
           (with-current-buffer buffer
             (let ((diagnostics (plist-get result :diagnostics)))
               (proofread--apply-backend-diagnostics diagnostics)
               (unless (eq (plist-get result :source) 'cache)
                 (proofread--cache-write-request request diagnostics)))
             'applied)
         'stale))
      ('error 'error)
      (_ 'error))))

(defun proofread--dispatch-request-ready-chunks (chunks &optional backend)
  "Dispatch request-ready CHUNKS through BACKEND.
When BACKEND is nil, use `proofread-backend'.  Return dispatched requests."
  (when (proofread-backend-available-p backend)
    (let ((backend-identity (proofread--cache-backend-identity backend))
          requests)
      (dolist (chunk chunks)
        (let ((request (proofread--make-backend-request chunk backend)))
          (setq request (plist-put request :backend backend-identity))
          (let ((entry (proofread--cache-read-request request)))
            (if entry
                (proofread--apply-cache-entry request entry)
              (when (proofread--dispatch-backend-request
                     request #'proofread--handle-backend-result backend)
                (push request requests))))))
      (nreverse requests))))

(defun proofread--cancel-request-handle (handle)
  "Cancel backend HANDLE when the backend supports cancellation."
  (when (and (listp handle)
             (eq (plist-get handle :backend) 'llm)
             (plist-get handle :request))
    (let ((warning-minimum-level :error)
          (warning-minimum-log-level :error))
      (ignore-errors
        (llm-cancel-request (plist-get handle :request))))))

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

(defun proofread--prune-overlays ()
  "Remove stale or foreign overlay references from `proofread--overlays'."
  (let (overlays)
    (dolist (overlay proofread--overlays)
      (when (proofread--current-buffer-overlay-p overlay)
        (push overlay overlays)))
    (setq proofread--overlays (nreverse overlays))))

(defun proofread--delete-overlay (overlay)
  "Delete proofread-owned OVERLAY when it is live."
  (when (proofread--overlay-p overlay)
    (delete-overlay overlay)))

(defun proofread--overlay-modified (overlay after _beg _end &optional _length)
  "Delete proofread-owned OVERLAY when its text is modified.
AFTER is non-nil for the after-change notification."
  (unless after
    (proofread--delete-overlay overlay)))

(defun proofread--diagnostic-range (diagnostic)
  "Return DIAGNOSTIC's valid range as a cons cell, or nil."
  (let ((beg (proofread--position-integer
              (proofread--diagnostic-get diagnostic :beg)))
        (end (proofread--position-integer
              (proofread--diagnostic-get diagnostic :end))))
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
  (list :text (proofread--diagnostic-get diagnostic :text)
        :kind (proofread--diagnostic-get diagnostic :kind)))

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

(defun proofread--format-diagnostic-field (value)
  "Return VALUE formatted for a diagnostic description."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun proofread--diagnostic-suggestions (diagnostic)
  "Return DIAGNOSTIC suggestions as strings in stored order."
  (let ((suggestions (proofread--diagnostic-get diagnostic :suggestions)))
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
         (text (proofread--diagnostic-get diagnostic :text)))
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
  (let ((kind (proofread--diagnostic-get diagnostic :kind))
        (message (proofread--diagnostic-get diagnostic :message))
        (text (proofread--diagnostic-get diagnostic :text))
        (suggestions (proofread--diagnostic-suggestions diagnostic))
        (confidence (proofread--diagnostic-get diagnostic :confidence))
        (source (proofread--diagnostic-get diagnostic :source))
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
  (let ((beg (proofread--diagnostic-get diagnostic :beg))
        (end (proofread--diagnostic-get diagnostic :end)))
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
  (dolist (overlay proofread--overlays)
    (when (proofread--current-buffer-overlay-p overlay)
      (delete-overlay overlay)))
  (setq proofread--overlays nil)
  (setq proofread--current-diagnostic nil))

(defun proofread--initialize-buffer-state ()
  "Initialize proofread-owned state for the current buffer."
  (setq-local proofread--diagnostics nil)
  (setq-local proofread--overlays nil)
  (setq-local proofread--current-diagnostic nil)
  (setq-local proofread--pending-ranges nil)
  (setq-local proofread--requests nil)
  (setq-local proofread--next-request-id 0)
  (setq-local proofread--cache (make-hash-table :test #'equal))
  (setq-local proofread--pending-work nil)
  (setq-local proofread--idle-timer nil))

(defun proofread--clear-buffer-state ()
  "Clear proofread-owned state for the current buffer."
  (proofread--clear-scheduled-work)
  (proofread--cancel-active-requests)
  (proofread--clear-overlays)
  (setq proofread--diagnostics nil)
  (setq proofread--current-diagnostic nil)
  (setq proofread--pending-ranges nil)
  (setq proofread--next-request-id 0)
  (setq proofread--cache nil))

(defun proofread--enable-buffer ()
  "Enable proofread buffer-local hooks and state in the current buffer."
  (proofread--initialize-buffer-state)
  (add-hook 'after-change-functions #'proofread--after-change nil t)
  (add-hook 'kill-buffer-hook #'proofread--kill-buffer nil t)
  (proofread--register-mode-buffer))

(defun proofread--disable-buffer ()
  "Disable proofread buffer-local hooks and state in the current buffer."
  (remove-hook 'after-change-functions #'proofread--after-change t)
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
             (requests (proofread--dispatch-request-ready-chunks chunks)))
        (message "proofread: dispatched %d request%s from %d visible range%s"
                 (length requests)
                 (if (= (length requests) 1) "" "s")
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

;;;###autoload
(defun proofread-apply-suggestion ()
  "Apply a proofreading suggestion at point."
  (interactive)
  (let ((diagnostic (proofread--diagnostic-at-point)))
    (unless diagnostic
      (user-error "No proofread diagnostic at point"))
    (proofread--apply-suggestion-to-diagnostic
     diagnostic
     (proofread--select-diagnostic-suggestion diagnostic))))

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
