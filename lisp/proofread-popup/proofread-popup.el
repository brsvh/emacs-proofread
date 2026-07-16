;;; proofread-popup.el --- Popup UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Assisted-by: Codex:gpt-5.5
;; Assisted-by: Codex:gpt-5.6-sol
;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp
;; Package-Requires: ((emacs "30.1") (proofread "0.2.0") (posframe "1.5.2"))
;; Version: 0.1.1

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

;;;; Options

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
  :set #'proofread-set-positive-integer-option
  :group 'proofread-popup)

;;;; Faces

(defface proofread-popup-face
  '((t :inherit default))
  "Face for Proofread child-frame messages."
  :group 'proofread-popup)

(defface proofread-popup-border-face
  '((((background dark)) :background "white")
    (((background light)) :background "black"))
  "Face for Proofread child-frame borders."
  :group 'proofread-popup)

;;;; Internal state

(defconst proofread-popup--buffer-prefix " *Proofread Popup*"
  "Prefix for hidden buffers used by Proofread child frames.")

(defvar proofread-popup-mode)

(defvar-local proofread-popup--buffer-name nil
  "Hidden Posframe buffer name for the current Proofread buffer.")

(defvar-local proofread-popup--render-signature nil
  "Popup-owned signature of the diagnostic currently displayed.")

(defvar-local proofread-popup--position nil
  "Buffer position currently used for the Proofread child frame.")

(defvar-local proofread-popup--window nil
  "Window where the Proofread child frame was last positioned.")

(defvar-local proofread-popup--render-state nil
  "Render snapshot used for the current Proofread child frame.")

(defvar-local proofread-popup--user-disabled-p nil
  "Non-nil when the user disabled popup integration in this buffer.")

;;;; Child-frame rendering

(defun proofread-popup--reset-state ()
  "Forget the child frame currently associated with this buffer."
  (setq proofread-popup--render-signature nil)
  (setq proofread-popup--position nil)
  (setq proofread-popup--window nil)
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

(defun proofread-popup--selected-buffer-p (window)
  "Return non-nil when WINDOW displays the current buffer."
  (eq (window-buffer window)
      (current-buffer)))

(defun proofread-popup--message-for-fields (raw-message text)
  "Return the child-frame message for RAW-MESSAGE and TEXT."
  (let ((message (and (stringp raw-message)
                      (string-trim raw-message))))
    (cond
     ((and message (not (string-empty-p message))) message)
     ((and raw-message (not (stringp raw-message)))
      (proofread-format-diagnostic-field raw-message))
     (text
      (format "Proofread: %s"
              (proofread-format-diagnostic-field text)))
     (t "Proofread diagnostic"))))

(defun proofread-popup--message (diagnostic)
  "Return the child-frame message for DIAGNOSTIC."
  (proofread-popup--message-for-fields
   (proofread-diagnostic-message diagnostic)
   (proofread-diagnostic-text diagnostic)))

(defun proofread-popup--diagnostic-render-data (diagnostic)
  "Return popup-owned render data for DIAGNOSTIC.
The result contains the final display message and an immutable
signature built only from public diagnostic values."
  (let* ((range (proofread-diagnostic-range diagnostic))
         (raw-message (proofread-diagnostic-message diagnostic))
         (text (proofread-diagnostic-text diagnostic))
         (message
          (copy-sequence
           (proofread-popup--message-for-fields raw-message text))))
    (list :message message
          :signature
          (list :range (and range (cons (car range) (cdr range)))
                :message (copy-sequence message)))))

(defun proofread-popup--face-color (face attribute)
  "Return FACE color ATTRIBUTE, or nil if unspecified."
  (let ((value (face-attribute face attribute nil t)))
    (unless (eq value 'unspecified)
      value)))

(defun proofread-popup--render-snapshot (window)
  "Return the child-frame render snapshot for WINDOW."
  (list :window-start (window-start window)
        :window-hscroll (window-hscroll window)
        :window-body-width (window-body-width window)
        :window-body-height (window-body-height window)
        :window-edges (window-edges window)
        :text-scale (bound-and-true-p text-scale-mode-amount)
        :max-width (max 1 proofread-popup-max-width)
        :foreground-color
        (proofread-popup--face-color
         'proofread-popup-face :foreground)
        :background-color
        (proofread-popup--face-color
         'proofread-popup-face :background)
        :border-color
        (proofread-popup--face-color
         'proofread-popup-border-face :background)))

(defun proofread-popup--needs-refresh-p
    (signature position window snapshot)
  "Return non-nil when SIGNATURE needs rendering at POSITION.
WINDOW and SNAPSHOT describe the selected display target."
  (not (and (equal-including-properties
             signature proofread-popup--render-signature)
            (equal position proofread-popup--position)
            (eq window proofread-popup--window)
            (equal snapshot proofread-popup--render-state))))

(defun proofread-popup--hide ()
  "Hide the current Proofread child frame."
  (when (and proofread-popup--buffer-name
             proofread-popup--render-signature)
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
       (proofread-report-warning-without-window
        (format "Proofread popup delete error: %s"
                (error-message-string err))
        "popup cleanup failed; see *Warnings*"))))
  (proofread-popup--reset-state))

(defun proofread-popup--hide-handler (info)
  "Handle automatic child-frame hiding described by Posframe INFO."
  (when (posframe-hidehandler-when-buffer-switch info)
    (when-let* ((parent-info (plist-get info :posframe-parent-buffer))
                (parent-buffer (cdr-safe parent-info))
                ((buffer-live-p parent-buffer)))
      (with-current-buffer parent-buffer
        (proofread-popup--reset-state)))
    t))

(defun proofread-popup--anchor-position (diagnostic window)
  "Return DIAGNOSTIC's visible, accessible anchor in WINDOW."
  (when-let* ((range (proofread-diagnostic-range diagnostic)))
    (if (and (<= (point-min) (car range))
             (<= (car range) (point-max))
             (pos-visible-in-window-p (car range) window))
        (car range)
      (point))))

(defun proofread-popup--show
    (message signature position window snapshot)
  "Show MESSAGE with SIGNATURE at POSITION in WINDOW using SNAPSHOT."
  (posframe-show
   (proofread-popup--ensure-buffer-name)
   :string (propertize message 'face 'proofread-popup-face)
   :position position
   :poshandler
   #'posframe-poshandler-point-bottom-left-corner-upward
   :foreground-color (plist-get snapshot :foreground-color)
   :background-color (plist-get snapshot :background-color)
   :max-width (plist-get snapshot :max-width)
   :min-width 1
   :internal-border-width 1
   :internal-border-color (plist-get snapshot :border-color)
   :left-fringe 3
   :right-fringe 3
   :accept-focus nil
   :override-parameters
   '((no-accept-focus . t)
     (no-focus-on-map . t)
     (cursor-type . nil)
     (no-special-glyphs . t)
     (desktop-dont-save . t))
   :hidehandler #'proofread-popup--hide-handler)
  (setq proofread-popup--render-signature signature)
  (setq proofread-popup--position position)
  (setq proofread-popup--window window)
  (setq proofread-popup--render-state snapshot))

(defun proofread-popup--update ()
  "Update the child frame for the Proofread diagnostic at point."
  (if (and proofread-popup-mode
           proofread-mode
           proofread-popup-enabled)
      (let ((window (selected-window)))
        (if (proofread-popup--selected-buffer-p window)
            (let* ((diagnostic (proofread-diagnostic-at-point))
                   (position
                    (and diagnostic
                         (proofread-popup--anchor-position
                          diagnostic window))))
              (if (and diagnostic position)
                  (let* ((snapshot
                          (proofread-popup--render-snapshot window))
                         (render-data
                          (proofread-popup--diagnostic-render-data
                           diagnostic))
                         (message (plist-get render-data :message))
                         (signature
                          (plist-get render-data :signature)))
                    (when (proofread-popup--needs-refresh-p
                           signature position window snapshot)
                      (if (proofread-popup--available-p)
                          (proofread-popup--show
                           message signature position window snapshot)
                        (proofread-popup--hide))))
                (proofread-popup--hide)))
          (proofread-popup--hide)))
    (proofread-popup--hide)))

;;;; Mode lifecycle

(defun proofread-popup--disable-before-major-mode-change ()
  "Disable popup messages before changing the current major mode."
  (proofread-popup-mode -1))

(defun proofread-popup--enable ()
  "Install the buffer-local hooks used by `proofread-popup-mode'."
  (add-hook 'post-command-hook #'proofread-popup--update nil t)
  (add-hook 'proofread-diagnostics-changed-hook
            #'proofread-popup--update nil t)
  (add-hook 'kill-buffer-hook #'proofread-popup--delete nil t)
  (add-hook
   'change-major-mode-hook
   #'proofread-popup--disable-before-major-mode-change nil t)
  (proofread-popup--update))

(defun proofread-popup--disable ()
  "Remove local popup hooks and delete the current child frame."
  (remove-hook 'post-command-hook #'proofread-popup--update t)
  (remove-hook 'proofread-diagnostics-changed-hook
               #'proofread-popup--update t)
  (remove-hook 'kill-buffer-hook #'proofread-popup--delete t)
  (remove-hook
   'change-major-mode-hook
   #'proofread-popup--disable-before-major-mode-change t)
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

(defun proofread-popup-unload-function ()
  "Remove Proofread popup integration before unloading this library."
  (remove-hook 'proofread-mode-hook
               #'proofread-popup--sync-with-proofread-mode)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p proofread-popup-mode)
        (proofread-popup-mode -1))))
  nil)

;;;; Runtime setup

(progn
  (add-hook 'proofread-mode-hook
            #'proofread-popup--sync-with-proofread-mode)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (proofread-popup--enable-in-existing-buffer))))

(provide 'proofread-popup)
;;; proofread-popup.el ends here
