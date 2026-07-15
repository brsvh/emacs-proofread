;;; proofread-popup.el --- Popup UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Assisted-by: Codex:gpt-5.5
;; Assisted-by: Codex:gpt-5.6-sol
;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1") (proofread "0.1.0") (posframe "1.5.2"))
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

;; This optional package displays the Proofread diagnostic at point
;; in a child frame.  Loading it integrates `proofread-popup-mode'
;; with `proofread-mode' in each buffer.  The core Proofread package
;; does not require this package or Posframe.

;;; Code:

(require 'posframe)
(require 'proofread)
(require 'subr-x)

(defgroup proofread-popup nil
  "Child-frame diagnostic messages for Proofread."
  :group 'proofread
  :prefix "proofread-popup-")

(defcustom proofread-popup-enabled t
  "Whether to show a child-frame message at point."
  :type 'boolean
  :group 'proofread-popup)

(defcustom proofread-popup-max-width 80
  "Maximum width of the Proofread child-frame message."
  :type 'natnum
  :set #'proofread--set-positive-integer-option
  :group 'proofread-popup)

(defface proofread-popup-face
  '((t :inherit default))
  "Face for Proofread child-frame messages."
  :group 'proofread-popup)

(defface proofread-popup-border-face
  '((((background dark)) :background "white")
    (((background light)) :background "black"))
  "Face for Proofread child-frame borders."
  :group 'proofread-popup)

(defconst proofread-popup--buffer-prefix " *Proofread Popup*"
  "Prefix for hidden buffers used by Proofread child frames.")

(defvar proofread-popup-mode)

(defvar-local proofread-popup--buffer-name nil
  "Hidden Posframe buffer name for the current Proofread buffer.")

(defvar-local proofread-popup--diagnostic nil
  "Diagnostic currently displayed in the Proofread child frame.")

(defvar-local proofread-popup--position nil
  "Buffer position currently used for the Proofread child frame.")

(defvar-local proofread-popup--window nil
  "Window where the Proofread child frame was last positioned.")

(defvar-local proofread-popup--visible-p nil
  "Non-nil when the current Proofread child frame should be visible.")

(defvar-local proofread-popup--render-state nil
  "Window and appearance state used for the current child frame.")

(defvar-local proofread-popup--user-disabled-p nil
  "Non-nil when the user disabled popup integration in this buffer.")

(defun proofread-popup--reset-state ()
  "Forget the child frame currently associated with this buffer."
  (setq proofread-popup--diagnostic nil)
  (setq proofread-popup--position nil)
  (setq proofread-popup--window nil)
  (setq proofread-popup--visible-p nil)
  (setq proofread-popup--render-state nil))

(defun proofread-popup--ensure-buffer-name ()
  "Return the hidden buffer name used for the current child frame."
  (or proofread-popup--buffer-name
      (setq proofread-popup--buffer-name
            (generate-new-buffer-name
             proofread-popup--buffer-prefix))))

(defun proofread-popup--available-p ()
  "Return non-nil when a Proofread child frame can be shown."
  (and proofread-popup-enabled
       (posframe-workable-p)))

(defun proofread-popup--selected-buffer-p ()
  "Return non-nil when the selected window displays this buffer."
  (eq (window-buffer (selected-window))
      (current-buffer)))

(defun proofread-popup--format-field (value)
  "Return VALUE formatted for a child-frame message."
  (cond
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%S" value))))

(defun proofread-popup--message (diagnostic)
  "Return the child-frame message for DIAGNOSTIC."
  (let* ((raw-message (proofread-diagnostic-message diagnostic))
         (message (and (stringp raw-message)
                       (string-trim raw-message))))
    (cond
     ((and message (not (string-empty-p message))) message)
     ((and raw-message (not (stringp raw-message)))
      (proofread-popup--format-field raw-message))
     ((proofread-diagnostic-text diagnostic)
      (format "Proofread: %s"
              (proofread-popup--format-field
               (proofread-diagnostic-text diagnostic))))
     (t "Proofread diagnostic"))))

(defun proofread-popup--face-color (face attribute)
  "Return FACE color ATTRIBUTE, or nil if unspecified."
  (let ((value (face-attribute face attribute nil t)))
    (unless (eq value 'unspecified)
      value)))

(defun proofread-popup--current-render-state ()
  "Return state that affects child-frame placement and appearance."
  (list (window-start)
        (window-hscroll)
        (window-body-width)
        (window-body-height)
        (window-edges)
        (bound-and-true-p text-scale-mode-amount)
        proofread-popup-max-width
        (proofread-popup--face-color
         'proofread-popup-face :foreground)
        (proofread-popup--face-color
         'proofread-popup-face :background)
        (proofread-popup--face-color
         'proofread-popup-border-face :background)))

(defun proofread-popup--needs-refresh-p (diagnostic position)
  "Return non-nil when the child frame needs DIAGNOSTIC at POSITION."
  (not (and (eq diagnostic proofread-popup--diagnostic)
            (equal position proofread-popup--position)
            (eq (selected-window) proofread-popup--window)
            (equal (proofread-popup--current-render-state)
                   proofread-popup--render-state))))

(defun proofread-popup--hide ()
  "Hide the current Proofread child frame."
  (when (and proofread-popup--buffer-name
             proofread-popup--visible-p)
    (posframe-hide proofread-popup--buffer-name))
  (proofread-popup--reset-state))

(defun proofread-popup--delete ()
  "Delete the current Proofread child frame and hidden buffer."
  (when proofread-popup--buffer-name
    (condition-case err
        (progn
          (posframe-delete proofread-popup--buffer-name)
          (setq proofread-popup--buffer-name nil))
      (error
       (proofread--report-warning-without-window
        (format "Proofread popup delete error: %s"
                (error-message-string err))
        "popup cleanup failed; see *Warnings*"))))
  (proofread-popup--reset-state))

(defun proofread-popup--hidehandler (info)
  "Handle automatic child-frame hiding described by Posframe INFO."
  (when (posframe-hidehandler-when-buffer-switch info)
    (when-let* ((parent-info (plist-get info :posframe-parent-buffer))
                (parent-buffer (cdr-safe parent-info))
                ((buffer-live-p parent-buffer)))
      (with-current-buffer parent-buffer
        (proofread-popup--reset-state)))
    t))

(defun proofread-popup--anchor-position (diagnostic)
  "Return a visible, accessible anchor position for DIAGNOSTIC."
  (when-let* ((range (proofread-diagnostic-range diagnostic)))
    (if (and (<= (point-min) (car range))
             (<= (car range) (point-max))
             (pos-visible-in-window-p (car range)))
        (car range)
      (point))))

(defun proofread-popup--show (diagnostic)
  "Show DIAGNOSTIC's message in a child frame."
  (let ((position (proofread-popup--anchor-position diagnostic)))
    (if (and position
             (proofread-popup--selected-buffer-p)
             (proofread-popup--available-p))
        (let ((message (proofread-popup--message diagnostic)))
          (posframe-show
           (proofread-popup--ensure-buffer-name)
           :string (propertize message 'face 'proofread-popup-face)
           :position position
           :poshandler
           #'posframe-poshandler-point-bottom-left-corner-upward
           :foreground-color
           (proofread-popup--face-color
            'proofread-popup-face :foreground)
           :background-color
           (proofread-popup--face-color
            'proofread-popup-face :background)
           :max-width (max 1 proofread-popup-max-width)
           :min-width 1
           :internal-border-width 1
           :internal-border-color
           (proofread-popup--face-color
            'proofread-popup-border-face :background)
           :left-fringe 3
           :right-fringe 3
           :accept-focus nil
           :override-parameters
           '((no-accept-focus . t)
             (no-focus-on-map . t)
             (cursor-type . nil)
             (no-special-glyphs . t)
             (desktop-dont-save . t))
           :hidehandler #'proofread-popup--hidehandler)
          (setq proofread-popup--diagnostic diagnostic)
          (setq proofread-popup--position position)
          (setq proofread-popup--window (selected-window))
          (setq proofread-popup--render-state
                (proofread-popup--current-render-state))
          (setq proofread-popup--visible-p t))
      (proofread-popup--hide))))

(defun proofread-popup--update ()
  "Update the child frame for the Proofread diagnostic at point."
  (if (and proofread-popup-mode
           proofread-mode
           proofread-popup-enabled
           (proofread-popup--selected-buffer-p))
      (let* ((diagnostic (proofread-diagnostic-at-point))
             (position
              (and diagnostic
                   (proofread-popup--anchor-position diagnostic))))
        (if (and diagnostic position)
            (when (proofread-popup--needs-refresh-p
                   diagnostic position)
              (proofread-popup--show diagnostic))
          (proofread-popup--hide)))
    (proofread-popup--hide)))

(defun proofread-popup--enable ()
  "Install the buffer-local hooks used by `proofread-popup-mode'."
  (add-hook 'post-command-hook #'proofread-popup--update nil t)
  (add-hook 'proofread-diagnostics-changed-hook
            #'proofread-popup--update nil t)
  (add-hook 'kill-buffer-hook #'proofread-popup--delete nil t)
  (add-hook 'change-major-mode-hook
            #'proofread-popup--change-major-mode nil t)
  (proofread-popup--update))

(defun proofread-popup--disable ()
  "Remove local popup hooks and delete the current child frame."
  (remove-hook 'post-command-hook #'proofread-popup--update t)
  (remove-hook 'proofread-diagnostics-changed-hook
               #'proofread-popup--update t)
  (remove-hook 'kill-buffer-hook #'proofread-popup--delete t)
  (remove-hook 'change-major-mode-hook
               #'proofread-popup--change-major-mode t)
  (proofread-popup--delete))

;;;###autoload
(define-minor-mode proofread-popup-mode
  "Toggle child-frame messages for Proofread diagnostics here.

This mode is enabled and disabled automatically with
`proofread-mode' after the optional `proofread-popup' library has
been loaded.  To opt one buffer out of popup messages, disable this
mode locally."
  :lighter nil
  :group 'proofread-popup
  (when (called-interactively-p 'interactive)
    (setq proofread-popup--user-disabled-p
          (not proofread-popup-mode)))
  (if proofread-popup-mode
      (proofread-popup--enable)
    (proofread-popup--disable)))

(defun proofread-popup--change-major-mode ()
  "Disable popup messages before changing the current major mode."
  (proofread-popup-mode -1))

(defun proofread-popup--sync-with-proofread-mode ()
  "Enable or disable popup messages to follow `proofread-mode'."
  (proofread-popup-mode
   (if (and proofread-mode
            (not proofread-popup--user-disabled-p))
       1
     -1)))

(defun proofread-popup--enable-in-existing-buffer ()
  "Enable popup messages in the current Proofread buffer."
  (when (and (bound-and-true-p proofread-mode)
             (not proofread-popup--user-disabled-p))
    (proofread-popup-mode 1)))

(add-hook 'proofread-mode-hook
          #'proofread-popup--sync-with-proofread-mode)

(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (proofread-popup--enable-in-existing-buffer)))

(defun proofread-popup-unload-function ()
  "Remove Proofread popup integration before unloading this library."
  (remove-hook 'proofread-mode-hook
               #'proofread-popup--sync-with-proofread-mode)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p proofread-popup-mode)
        (proofread-popup-mode -1))))
  nil)

(provide 'proofread-popup)

;;; proofread-popup.el ends here
