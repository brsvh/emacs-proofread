;;; proofread.el --- Context-aware LLM proofreading -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1"))
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

(require 'json)
(require 'url)

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

(defcustom proofread-max-concurrent-requests 2
  "Maximum number of proofreading backend requests active at once."
  :type 'natnum
  :group 'proofread)

(defcustom proofread-backend nil
  "Selected backend used to produce proofreading diagnostics.
The built-in mock backend is selected with the symbol `mock'.  A nil value
disables backend dispatch."
  :type '(choice (const :tag "None" nil)
                 (const :tag "Mock backend" mock)
                 (const :tag "Ollama backend" ollama)
                 symbol)
  :group 'proofread)

(defcustom proofread-backend-model nil
  "Model name used by configurable proofread backends.
This value participates in model-aware backend identity for non-mock backends.
The built-in mock backend ignores it."
  :type '(choice (const :tag "Unspecified" nil)
                 string)
  :group 'proofread)

(defcustom proofread-backend-endpoint nil
  "Endpoint used by configurable proofread backends.
This value participates in model-aware backend identity for non-mock backends.
The built-in mock backend ignores it."
  :type '(choice (const :tag "Unspecified" nil)
                 string)
  :group 'proofread)

(defcustom proofread-backend-options nil
  "Cache-relevant options used by configurable proofread backends.
Put only options that can affect returned diagnostics here.  Runtime-only
controls, such as timeouts, should use backend-specific variables and are not
part of model-aware cache identity."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-ollama-base-url "http://localhost:11434/api"
  "Base URL for the Ollama API.
The default points at the local Ollama service.  Changing this value sends
filtered visible chunks and context to the configured endpoint."
  :type 'string
  :group 'proofread)

(defcustom proofread-ollama-model nil
  "Ollama model name used by the Ollama backend."
  :type '(choice (const :tag "Unspecified" nil)
                 string)
  :group 'proofread)

(defcustom proofread-ollama-options nil
  "Ollama generation options that can affect returned diagnostics.
This value participates in the Ollama backend identity and diagnostic cache
keys."
  :type 'sexp
  :group 'proofread)

(defcustom proofread-ollama-timeout 30
  "Seconds to wait before an Ollama request fails with a timeout."
  :type 'number
  :group 'proofread)

(defcustom proofread-prompt-version "2"
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
     :language :major-mode :modified-tick :backend)
  "Required keys for proofread backend request plists.")

(defconst proofread--ollama-json-prompt-contract
  (concat
   "Return only one JSON object.  Do not include Markdown, comments, "
   "prose, or reasoning outside the JSON object.\n"
   "The JSON object must have this shape:\n"
   "{\"diagnostics\":[{\"kind\":\"spelling|grammar|style|other\","
   "\"message\":\"short explanation\","
   "\"text\":\"exact original text\","
   "\"range\":{\"beg\":0,\"end\":0},"
   "\"suggestions\":[\"replacement\"],"
   "\"confidence\":0.0,"
   "\"source\":\"optional source\"}]}\n"
   "Use zero-based chunk-relative offsets; range end is exclusive.\n"
   "The text field must exactly equal the substring selected by range.\n"
   "Use {\"diagnostics\":[]} when there are no diagnostics.\n")
  "Prompt contract for Ollama JSON diagnostics.")

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
  "Return bounded chunk spans for visible RANGES."
  (let (spans)
    (dolist (span (proofread--paragraph-spans-for-ranges ranges))
      (dolist (chunk-span (proofread--split-span-by-chunk-size span))
        (push chunk-span spans)))
    (nreverse spans)))

(defun proofread--chunks-for-ranges (ranges)
  "Return paragraph chunks for visible RANGES in the current buffer."
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

(defun proofread--request-ready-context-before (beg)
  "Return filtered context before BEG without text properties."
  (let* ((size (max 0 proofread-context-size))
         (context-beg (max (point-min) (- beg size))))
    (proofread--substring-excluding-ranges
     context-beg beg
     (proofread--ignored-ranges-in-region context-beg beg))))

(defun proofread--request-ready-context-after (end)
  "Return filtered context after END without text properties."
  (let* ((size (max 0 proofread-context-size))
         (context-end (min (point-max) (+ end size))))
    (proofread--substring-excluding-ranges
     end context-end
     (proofread--ignored-ranges-in-region end context-end))))

(defun proofread--make-request-ready-chunk (beg end)
  "Return a request-ready proofread chunk for text between BEG and END."
  (list :beg beg
        :end end
        :text (buffer-substring-no-properties beg end)
        :major-mode major-mode
        :language proofread-language
        :context-before (proofread--request-ready-context-before beg)
        :context-after (proofread--request-ready-context-after end)
        :modified-tick (buffer-chars-modified-tick)))

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

(defun proofread--nonempty-string-p (value)
  "Return non-nil when VALUE is a non-empty string."
  (and (stringp value)
       (not (string= value ""))))

(defun proofread-backend-available-p (&optional backend)
  "Return non-nil if BACKEND can accept proofreading requests.
When BACKEND is nil, check the selected `proofread-backend'."
  (pcase (or backend proofread-backend)
    ('mock t)
    ('ollama (proofread--nonempty-string-p proofread-ollama-model))
    (_ nil)))

(defun proofread--mock-backend-complete (request callback)
  "Complete mock backend REQUEST by invoking CALLBACK."
  (if (plist-get request :mock-error)
      (proofread--invoke-backend-callback
       callback
       (proofread--backend-error-result
        request
        (plist-get request :mock-error)
        (plist-get request :mock-message)))
    (proofread--invoke-backend-callback
     callback
     (proofread--backend-success-result request nil))))

(defun proofread--mock-backend-check (request callback)
  "Submit REQUEST to the asynchronous mock backend."
  (run-at-time 0 nil #'proofread--mock-backend-complete request callback))

(defun proofread--ollama-generate-url ()
  "Return the configured Ollama generate endpoint URL."
  (concat (replace-regexp-in-string "/\\'" "" proofread-ollama-base-url)
          "/generate"))

(defun proofread--ollama-prompt (request)
  "Return the Ollama prompt for backend REQUEST."
  (format
   (concat "Proofread the following text.\n\n"
           "%s\n"
           "Language: %S\n"
           "Major mode: %S\n\n"
           "Context before:\n%s\n\n"
           "Text:\n%s\n\n"
           "Context after:\n%s\n")
   proofread--ollama-json-prompt-contract
   (plist-get request :language)
   (plist-get request :major-mode)
   (or (plist-get request :context-before) "")
   (or (plist-get request :text) "")
   (or (plist-get request :context-after) "")))

(defun proofread--ollama-payload (request)
  "Return an alist payload for Ollama backend REQUEST."
  (let ((payload `(("model" . ,proofread-ollama-model)
                   ("prompt" . ,(proofread--ollama-prompt request))
                   ("stream" . :json-false))))
    (when proofread-ollama-options
      (setq payload
            (append payload
                    `(("options" . ,proofread-ollama-options)))))
    payload))

(defun proofread--json-encode (value)
  "Return JSON encoding for VALUE."
  (json-encode value))

(defun proofread--encode-http-request-data (data)
  "Return DATA encoded as UTF-8 unibyte data for `url-request-data'."
  (encode-coding-string data 'utf-8))

(defun proofread--json-read-string (string)
  "Read STRING as JSON and return plist/list data."
  (let ((json-object-type 'plist)
        (json-array-type 'list)
        (json-key-type 'keyword)
        (json-false nil))
    (json-read-from-string string)))

(defun proofread--ollama-url-retrieve-callback (status callback)
  "Invoke CALLBACK with STATUS and the current response buffer."
  (funcall callback status (current-buffer)))

(defun proofread--ollama-url-retrieve (url data callback)
  "Submit DATA to URL and invoke CALLBACK asynchronously."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         '(("Content-Type" . "application/json; charset=utf-8")))
        (url-request-data (proofread--encode-http-request-data data)))
    (url-retrieve
     url #'proofread--ollama-url-retrieve-callback
     (list callback) t t)))

(defun proofread--kill-response-buffer (buffer)
  "Kill response BUFFER without prompting about live processes."
  (when (buffer-live-p buffer)
    (let ((process (get-buffer-process buffer)))
      (when (processp process)
        (set-process-query-on-exit-flag process nil)
        (delete-process process)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(defun proofread--ollama-http-status ()
  "Return HTTP status code from the current response buffer."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
      (string-to-number (match-string 1)))))

(defun proofread--ollama-response-body ()
  "Return HTTP response body from the current response buffer."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "\r?\n\r?\n" nil t)
        (buffer-substring-no-properties (point) (point-max))
      "")))

(defun proofread--ollama-response-payload (body)
  "Return parsed Ollama JSON response payload from BODY."
  (proofread--json-read-string body))

(defun proofread--ollama-response-content (payload)
  "Return generated content from Ollama response PAYLOAD."
  (plist-get payload :response))

(defun proofread--ollama-json-object-substrings (string)
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

(defun proofread--ollama-parse-diagnostic-json (content)
  "Parse one JSON diagnostic object from CONTENT."
  (let ((objects (proofread--ollama-json-object-substrings content)))
    (unless (= (length objects) 1)
      (error "Expected exactly one Ollama diagnostic JSON object"))
    (proofread--json-read-string (car objects))))

(defun proofread--ollama-diagnostic-payload (content)
  "Return parsed diagnostic payload from Ollama CONTENT."
  (cond
   ((stringp content)
    (proofread--ollama-parse-diagnostic-json content))
   ((listp content) content)
   (t (error "Invalid Ollama response content"))))

(defun proofread--ollama-diagnostic-candidates (payload)
  "Return diagnostic candidates from parsed Ollama PAYLOAD."
  (unless (plist-member payload :diagnostics)
    (error "Missing Ollama diagnostics payload"))
  (let ((diagnostics (plist-get payload :diagnostics)))
    (unless (listp diagnostics)
      (error "Invalid Ollama diagnostics payload"))
    diagnostics))

(defun proofread--ollama-diagnostic-range (candidate)
  "Return CANDIDATE's chunk-relative range as a cons cell."
  (let ((range (plist-get candidate :range)))
    (when (and (listp range)
               (plist-member range :beg)
               (plist-member range :end))
      (cons (plist-get range :beg)
            (plist-get range :end)))))

(defun proofread--ollama-diagnostic-range-valid-p (request beg end)
  "Return non-nil if relative BEG and END are valid for REQUEST."
  (let ((text (plist-get request :text)))
    (and (integerp beg)
         (integerp end)
         (stringp text)
         (<= 0 beg)
         (<= beg end)
         (<= end (length text)))))

(defun proofread--ollama-diagnostic-suggestions (value)
  "Return string suggestions from VALUE in original order."
  (when (listp value)
    (let (strings)
      (dolist (suggestion value)
        (when (stringp suggestion)
          (push suggestion strings)))
      (nreverse strings))))

(defun proofread--ollama-diagnostic-kind (value)
  "Return normalized diagnostic kind for VALUE."
  (cond
   ((and (symbolp value)
         (not (keywordp value)))
    value)
   ((and (stringp value)
         (string-match-p "\\`[[:alnum:]_-]+\\'" value))
    (intern value))))

(defun proofread--ollama-diagnostic-confidence (value)
  "Return normalized diagnostic confidence for VALUE, or nil."
  (when (and (numberp value)
             (<= 0 value)
             (<= value 1))
    value))

(defun proofread--ollama-diagnostic-source (candidate)
  "Return normalized diagnostic source from CANDIDATE."
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
     (t 'ollama))))

(defun proofread--ollama-diagnostic-from-candidate (request candidate)
  "Return proofread diagnostic for REQUEST and CANDIDATE, or nil."
  (let* ((range (proofread--ollama-diagnostic-range candidate))
         (relative-beg (car-safe range))
         (relative-end (cdr-safe range))
         (request-beg (plist-get request :beg))
         (request-text (plist-get request :text))
         (text (plist-get candidate :text))
         (kind (proofread--ollama-diagnostic-kind
                (plist-get candidate :kind)))
         (message (plist-get candidate :message)))
    (when (and (proofread--ollama-diagnostic-range-valid-p
                request relative-beg relative-end)
               (integerp request-beg)
               (stringp text)
               kind
               (stringp message)
               (equal text
                      (substring request-text relative-beg relative-end)))
      (proofread--make-diagnostic
       :beg (+ request-beg relative-beg)
       :end (+ request-beg relative-end)
       :text text
       :kind kind
       :message message
       :suggestions (proofread--ollama-diagnostic-suggestions
                     (plist-get candidate :suggestions))
       :confidence (proofread--ollama-diagnostic-confidence
                    (plist-get candidate :confidence))
       :source (proofread--ollama-diagnostic-source candidate)))))

(defun proofread--ollama-diagnostics-from-payload (request payload)
  "Return proofread diagnostics for REQUEST from parsed PAYLOAD."
  (let (diagnostics)
    (dolist (candidate (proofread--ollama-diagnostic-candidates payload))
      (let ((diagnostic
             (and (listp candidate)
                  (proofread--ollama-diagnostic-from-candidate
                   request candidate))))
        (when diagnostic
          (push diagnostic diagnostics))))
    (nreverse diagnostics)))

(defun proofread--ollama-parse-success (request body)
  "Return diagnostics for REQUEST from successful Ollama response BODY."
  (let* ((response-payload (proofread--ollama-response-payload body))
         (content (proofread--ollama-response-content response-payload))
         (diagnostic-payload
          (proofread--ollama-diagnostic-payload content)))
    (proofread--ollama-diagnostics-from-payload request diagnostic-payload)))

(defun proofread--ollama-result-from-response (request status buffer)
  "Return backend result for REQUEST from Ollama STATUS and BUFFER."
  (let ((transport-error (plist-get status :error)))
    (cond
     (transport-error
      (proofread--backend-error-result
       request 'ollama-connection-error
       (format "%S" transport-error)))
     ((not (buffer-live-p buffer))
      (proofread--backend-error-result
       request 'ollama-response-error "Ollama response buffer is not live"))
     (t
      (with-current-buffer buffer
        (let ((http-status (proofread--ollama-http-status)))
          (cond
           ((not (and http-status
                      (<= 200 http-status)
                      (< http-status 300)))
            (proofread--backend-error-result
             request 'ollama-http-error
             (format "Ollama HTTP status: %S" http-status)))
           (t
            (condition-case err
                (proofread--backend-success-result
                 request
                 (proofread--ollama-parse-success
                  request (proofread--ollama-response-body)))
              (error
               (proofread--backend-error-result
                request 'ollama-invalid-response
                (error-message-string err))))))))))))

(defun proofread--ollama-backend-check (request callback)
  "Submit REQUEST to Ollama and invoke CALLBACK asynchronously."
  (let ((finished nil)
        (url (proofread--ollama-generate-url))
        (data (proofread--json-encode
               (proofread--ollama-payload request)))
        response-buffer
        timeout-timer
        finish)
    (setq finish
          (lambda (result &optional buffer)
            (unless finished
              (setq finished t)
              (when (timerp timeout-timer)
                (cancel-timer timeout-timer))
              (when (buffer-live-p buffer)
                (proofread--kill-response-buffer buffer))
              (proofread--invoke-backend-callback callback result))))
    (when (and (numberp proofread-ollama-timeout)
               (> proofread-ollama-timeout 0))
      (setq timeout-timer
            (run-at-time
             proofread-ollama-timeout nil
             (lambda ()
               (funcall
                finish
                (proofread--backend-error-result
                 request 'ollama-timeout
                 "Ollama request timed out")
                response-buffer)))))
    (condition-case err
        (setq response-buffer
              (proofread--ollama-url-retrieve
               url data
               (lambda (status buffer)
                 (funcall
                  finish
                  (proofread--ollama-result-from-response
                   request status buffer)
                  buffer))))
      (error
       (funcall
        finish
        (proofread--backend-error-result
         request 'ollama-submit-error (error-message-string err)))))
    (list :backend 'ollama
          :buffer response-buffer
          :timer timeout-timer)))

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
handle, such as a timer object for the built-in mock backend."
  (let ((backend (or backend proofread-backend)))
    (pcase backend
      ('mock (proofread--mock-backend-check request callback))
      ('ollama (proofread--ollama-backend-check request callback))
      (_ (proofread--unsupported-backend-check backend request callback)))))

(defun proofread--dispatch-backend-request (request callback &optional backend)
  "Register REQUEST, submit it to BACKEND, and invoke CALLBACK on completion."
  (let ((buffer (plist-get request :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (proofread--register-active-request request))
      (let ((wrapped-callback
             (proofread--wrap-backend-callback request callback)))
        (condition-case err
            (proofread-backend-check request wrapped-callback backend)
          (error
           (proofread--invoke-backend-callback
            wrapped-callback
            (proofread--backend-error-result
             request err (error-message-string err)))
           nil))))))

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

(defun proofread--backend-cache-relevant-options (&optional backend)
  "Return cache-relevant options for BACKEND.
Runtime-only options are intentionally excluded from this value."
  (copy-tree
   (pcase backend
     ('ollama proofread-ollama-options)
     (_ proofread-backend-options))))

(defun proofread--backend-model-name (&optional backend)
  "Return model name for BACKEND."
  (pcase backend
    ('ollama proofread-ollama-model)
    (_ proofread-backend-model)))

(defun proofread--backend-endpoint (&optional backend)
  "Return endpoint for BACKEND."
  (pcase backend
    ('ollama proofread-ollama-base-url)
    (_ proofread-backend-endpoint)))

(defun proofread--model-backend-identity (backend)
  "Return structured identity for configurable model BACKEND."
  (list :backend backend
        :model (proofread--backend-model-name backend)
        :endpoint (proofread--backend-endpoint backend)
        :prompt-version proofread-prompt-version
        :options (proofread--backend-cache-relevant-options backend)))

(defun proofread--backend-identity (&optional backend)
  "Return canonical identity for BACKEND.
When BACKEND is nil, use the selected `proofread-backend'.  The mock backend
keeps its symbol identity for compatibility; configurable model backends use a
structured identity that excludes volatile request state."
  (let ((backend (or backend proofread-backend)))
    (cond
     ((proofread--backend-identity-p backend) backend)
     ((null backend) nil)
     ((eq backend 'mock) 'mock)
     (t (proofread--model-backend-identity backend)))))

(defun proofread--cache-backend-identity (&optional backend)
  "Return BACKEND identity for cache keys.
When BACKEND is nil, use the currently selected `proofread-backend'."
  (proofread--backend-identity backend))

(defun proofread--chunk-text-hash (text)
  "Return a deterministic cache hash for chunk TEXT."
  (secure-hash 'sha1 (or text "")))

(defun proofread--cache-key (chunk &optional backend)
  "Return diagnostic cache key for CHUNK and BACKEND."
  (list :text-hash
        (proofread--chunk-text-hash (plist-get chunk :text))
        :language (plist-get chunk :language)
        :major-mode (plist-get chunk :major-mode)
        :backend (proofread--cache-backend-identity
                  (or (plist-get chunk :backend) backend))
        :prompt-version proofread-prompt-version
        :configuration-version proofread-cache-configuration-version))

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
  (dolist (window (window-list nil nil t))
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
  (proofread--clear-overlays)
  (setq proofread--diagnostics nil)
  (setq proofread--current-diagnostic nil)
  (setq proofread--pending-ranges nil)
  (setq proofread--requests nil)
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
