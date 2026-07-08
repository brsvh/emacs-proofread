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
  "Backend used to produce proofreading diagnostics.
The backend protocol is defined in later implementation steps."
  :type '(choice (const :tag "None" nil)
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

(defvar-local proofread--cache nil
  "Proofread cache for the current buffer.")

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
  (setq-local proofread--cache (make-hash-table :test #'equal)))

(defun proofread--clear-buffer-state ()
  "Clear proofread-owned state for the current buffer."
  (proofread--clear-overlays)
  (setq proofread--diagnostics nil)
  (setq proofread--pending-ranges nil)
  (setq proofread--requests nil)
  (setq proofread--cache nil))

(defun proofread--command-placeholder (command)
  "Report that COMMAND has not been implemented yet."
  (message "proofread: `%s' is not implemented yet" command))

;;;###autoload
(define-minor-mode proofread-mode
  "Toggle context-aware proofreading in the current buffer.

This initial skeleton only installs the mode entry point.  It deliberately does
not create overlays, timers, requests, or other background state."
  :lighter " Proofread"
  :group 'proofread
  (if proofread-mode
      (proofread--initialize-buffer-state)
    (proofread--clear-buffer-state)))

;;;###autoload
(defun proofread-check-visible ()
  "Check visible text in the current buffer for proofreading diagnostics."
  (interactive)
  (setq proofread--pending-ranges (proofread--visible-ranges))
  (message "proofread: collected %d visible range%s"
           (length proofread--pending-ranges)
           (if (= (length proofread--pending-ranges) 1) "" "s")))

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
