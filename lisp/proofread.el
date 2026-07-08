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
                 symbol)
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
     :language :major-mode :modified-tick)
  "Required keys for proofread backend request plists.")

(defconst proofread--overlay-category 'proofread-overlay
  "Overlay category used for proofread-owned overlays.")

(defvar-local proofread--diagnostics nil
  "Proofread diagnostics for the current buffer.")

(defvar-local proofread--overlays nil
  "Proofread-owned overlays for the current buffer.")

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

(defun proofread--make-backend-request (chunk)
  "Return a backend request plist for request-ready CHUNK."
  (mapcan
   (lambda (key)
     (list key
           (pcase key
             (:id (proofread--next-request-id))
             (:buffer (current-buffer))
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

(defun proofread-backend-available-p (&optional backend)
  "Return non-nil if BACKEND can accept proofreading requests.
When BACKEND is nil, check the selected `proofread-backend'."
  (pcase (or backend proofread-backend)
    ('mock t)
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

(defun proofread--apply-backend-diagnostics (diagnostics)
  "Record DIAGNOSTICS and create proofread-owned overlays for them."
  (setq proofread--diagnostics
        (append proofread--diagnostics diagnostics))
  (dolist (diagnostic diagnostics)
    (proofread--create-overlay diagnostic)))

(defun proofread--handle-backend-result (result)
  "Handle backend RESULT and return an internal status symbol."
  (let* ((request (plist-get result :request))
         (buffer (plist-get request :buffer)))
    (pcase (plist-get result :status)
      ('ok
       (if (proofread--fresh-request-p request)
           (with-current-buffer buffer
             (proofread--apply-backend-diagnostics
              (plist-get result :diagnostics))
             'applied)
         'stale))
      ('error 'error)
      (_ 'error))))

(defun proofread--dispatch-request-ready-chunks (chunks &optional backend)
  "Dispatch request-ready CHUNKS through BACKEND.
When BACKEND is nil, use `proofread-backend'.  Return dispatched requests."
  (when (proofread-backend-available-p backend)
    (let (requests)
      (dolist (chunk chunks)
        (let ((request (proofread--make-backend-request chunk)))
          (when (proofread--dispatch-backend-request
                 request #'proofread--handle-backend-result backend)
            (push request requests))))
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
  (setq proofread--overlays nil))

(defun proofread--initialize-buffer-state ()
  "Initialize proofread-owned state for the current buffer."
  (setq-local proofread--diagnostics nil)
  (setq-local proofread--overlays nil)
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
  (proofread--command-placeholder 'proofread-next))

;;;###autoload
(defun proofread-previous ()
  "Move point to the previous proofreading diagnostic."
  (interactive)
  (proofread--command-placeholder 'proofread-previous))

;;;###autoload
(defun proofread-describe ()
  "Describe the proofreading diagnostic at point."
  (interactive)
  (proofread--command-placeholder 'proofread-describe))

;;;###autoload
(defun proofread-apply-suggestion ()
  "Apply a proofreading suggestion at point."
  (interactive)
  (proofread--command-placeholder 'proofread-apply-suggestion))

;;;###autoload
(defun proofread-ignore ()
  "Ignore the proofreading diagnostic at point."
  (interactive)
  (proofread--command-placeholder 'proofread-ignore))

;;;###autoload
(defun proofread-clear ()
  "Clear proofreading overlays from the current buffer."
  (interactive)
  (proofread--clear-overlays))

(provide 'proofread)

;;; proofread.el ends here
