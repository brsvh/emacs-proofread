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

(defun proofread--command-placeholder (command)
  "Report that COMMAND has not been implemented yet."
  (message "proofread: `%s' is not implemented yet" command))

;;;###autoload
(define-minor-mode proofread-mode
  "Toggle context-aware proofreading in the current buffer.

This initial skeleton only installs the mode entry point.  It deliberately does
not create overlays, timers, requests, or other background state."
  :lighter " Proofread"
  :group 'proofread)

;;;###autoload
(defun proofread-check-visible ()
  "Check visible text in the current buffer for proofreading diagnostics."
  (interactive)
  (proofread--command-placeholder 'proofread-check-visible))

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
  "Clear proofreading diagnostics from the current buffer."
  (interactive)
  (proofread--command-placeholder 'proofread-clear))

(provide 'proofread)

;;; proofread.el ends here
