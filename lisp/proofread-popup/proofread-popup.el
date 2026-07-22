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
;;
;; The frontend observes `proofread-diagnostics-changed-hook' and uses
;; only public Proofread diagnostic APIs:
;; `proofread-diagnostic-at-point', `proofread-diagnostic-range', and
;; `proofread-format-diagnostic-message'.  Other point-oriented
;; frontends can use the same interface without reading Flymake or
;; Proofread private state.
;; This popup supplements Flymake; it neither replaces Flymake's
;; annotations and ElDoc integration nor displays diagnostics owned by
;; other Flymake backends.

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
  "Whether `proofread-popup-mode' may show a child-frame message.
This controls only popup rendering; it does not disable the popup
mode, Proofread, Flymake annotations, or ElDoc."
  :type 'boolean
  :group 'proofread-popup)

(defun proofread-popup--set-nonnegative-number-option (symbol value)
  "Set SYMBOL to VALUE after requiring a nonnegative number."
  (unless (and (numberp value) (>= value 0))
    (user-error "%s must be a nonnegative number" symbol))
  (set-default symbol value))

(defcustom proofread-popup-delay 0.5
  "Seconds point must remain idle before updating the child frame.
Set this to zero to update the child frame immediately."
  :type '(number :tag "Seconds")
  :set #'proofread-popup--set-nonnegative-number-option
  :group 'proofread-popup)

(defcustom proofread-popup-max-width 80
  "Maximum width of the Proofread child-frame message."
  :type 'natnum
  :set #'proofread-set-positive-integer-option
  :group 'proofread-popup)

;;;; Faces

(defface proofread-popup-face
  '((t :inherit font-lock-comment-face))
  "Face for Proofread child-frame messages."
  :group 'proofread-popup)

(defface proofread-popup-source-face
  '((t :inherit font-lock-keyword-face))
  "Face for source labels in Proofread child-frame messages."
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

(defvar proofread-popup--owners nil
  "Source buffers with pending or visible Proofread popups.")

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

(defvar-local proofread-popup--idle-timer nil
  "One-shot idle timer for the next popup update.")

(defvar-local proofread-popup--update-generation nil
  "Identity token for the current pending popup update.")

(defvar-local proofread-popup--owner-window nil
  "Selected source window that owns this buffer's popup state.")

(defvar-local proofread-popup--owner-frame nil
  "Parent frame that owns this buffer's popup state.")

(defvar-local proofread-popup--visible-p nil
  "Non-nil when this buffer owns a visible Proofread child frame.")

(defvar-local proofread-popup--user-disabled-p nil
  "Non-nil when the user disabled popup integration in this buffer.")

;;;; Child-frame rendering

(defun proofread-popup--owner-active-p ()
  "Return non-nil when the current buffer has popup-owned work."
  (or proofread-popup--idle-timer proofread-popup--visible-p))

(defun proofread-popup--sync-owner-registry ()
  "Synchronize the current buffer with the popup owner registry."
  (if (proofread-popup--owner-active-p)
      (unless (memq (current-buffer) proofread-popup--owners)
        (push (current-buffer) proofread-popup--owners))
    (setq proofread-popup--owners
          (delq (current-buffer) proofread-popup--owners))
    (setq proofread-popup--owner-window nil)
    (setq proofread-popup--owner-frame nil)))

(defun proofread-popup--set-owner-target (window)
  "Record WINDOW and its parent frame as the current popup owner."
  (setq proofread-popup--owner-window window)
  (setq proofread-popup--owner-frame (window-frame window)))

(defun proofread-popup--selected-owner-target ()
  "Return the selected source window for the current buffer, or nil."
  (let ((window (selected-window)))
    (when (and (window-live-p window)
               (eq (window-buffer window) (current-buffer))
               (frame-live-p (window-frame window)))
      window)))

(defun proofread-popup--owner-valid-p (&optional selected-window)
  "Return non-nil when the current buffer still owns its display.
SELECTED-WINDOW, when non-nil, is the already captured selected window."
  (let ((selected-window
         (or selected-window (selected-window))))
    (and (proofread-popup--owner-active-p)
         (window-live-p proofread-popup--owner-window)
         (frame-live-p proofread-popup--owner-frame)
         (eq (window-frame proofread-popup--owner-window)
             proofread-popup--owner-frame)
         (eq (selected-frame) proofread-popup--owner-frame)
         (eq selected-window proofread-popup--owner-window)
         (eq (frame-selected-window proofread-popup--owner-frame)
             proofread-popup--owner-window)
         (eq (window-buffer proofread-popup--owner-window)
             (current-buffer)))))

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

(defun proofread-popup--message (diagnostic)
  "Return the child-frame message for DIAGNOSTIC."
  (proofread-format-diagnostic-message
   diagnostic
   :separator "\n"
   :source-face 'proofread-popup-source-face
   :message-face 'proofread-popup-face))

(defun proofread-popup--diagnostic-render-data (diagnostic)
  "Return popup-owned render data for DIAGNOSTIC.
The result contains the final display message and an immutable
signature built only from public diagnostic values."
  (let* ((range (proofread-diagnostic-range diagnostic))
         (message (copy-sequence (proofread-popup--message diagnostic))))
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

(defun proofread-popup--report-cleanup-error (message)
  "Report popup cleanup MESSAGE without allowing another error."
  (condition-case nil
      (proofread-report-warning-without-window
       message "popup cleanup failed; see *Warnings*")
    (error nil)))

(defun proofread-popup--cancel-timer (timer)
  "Cancel TIMER, isolating cleanup errors."
  (when timer
    (condition-case err
        (cancel-timer timer)
      (error
       (proofread-popup--report-cleanup-error
        (format "Proofread popup timer cancellation error: %s"
                (error-message-string err)))))))

(defun proofread-popup--cancel-pending-update ()
  "Cancel and invalidate the pending popup update, if any."
  (let ((timer proofread-popup--idle-timer))
    (setq proofread-popup--idle-timer nil)
    (setq proofread-popup--update-generation nil)
    (proofread-popup--sync-owner-registry)
    (proofread-popup--cancel-timer timer)))

(defun proofread-popup--claim-hidden-popup ()
  "Claim and return the timer for all current popup-owned state."
  (let ((timer proofread-popup--idle-timer))
    (setq proofread-popup--idle-timer nil)
    (setq proofread-popup--update-generation nil)
    (setq proofread-popup--visible-p nil)
    (proofread-popup--reset-state)
    (proofread-popup--sync-owner-registry)
    timer))

(defun proofread-popup--forget-hidden-popup ()
  "Forget popup state after Posframe has hidden the child frame."
  (proofread-popup--cancel-timer
   (proofread-popup--claim-hidden-popup)))

(defun proofread-popup--hide ()
  "Hide and invalidate the current Proofread child frame."
  (let ((buffer-name proofread-popup--buffer-name)
        (visible-p proofread-popup--visible-p))
    (proofread-popup--forget-hidden-popup)
    (when (and buffer-name visible-p)
      (condition-case err
          (posframe-hide buffer-name)
        (error
         (proofread-popup--report-cleanup-error
          (format "Proofread popup hide error: %s"
                  (error-message-string err))))))))

(defun proofread-popup--delete ()
  "Delete the current Proofread child frame and hidden buffer."
  (let ((buffer-name proofread-popup--buffer-name))
    (setq proofread-popup--buffer-name nil)
    (proofread-popup--forget-hidden-popup)
    (when buffer-name
      (condition-case err
          (posframe-delete buffer-name)
        (error
         (unless proofread-popup--buffer-name
           (setq proofread-popup--buffer-name buffer-name))
         (proofread-popup--report-cleanup-error
          (format "Proofread popup delete error: %s"
                  (error-message-string err))))))))

(defun proofread-popup--hide-handler (info)
  "Handle automatic child-frame hiding described by Posframe INFO."
  (when (posframe-hidehandler-when-buffer-switch info)
    (when-let* ((parent-info (plist-get info :posframe-parent-buffer))
                (parent-buffer (cdr-safe parent-info)))
      (if (buffer-live-p parent-buffer)
          (with-current-buffer parent-buffer
            (proofread-popup--forget-hidden-popup))
        (setq proofread-popup--owners
              (delq parent-buffer proofread-popup--owners))))
    t))

(defun proofread-popup--pre-command-cleanup ()
  "Hide popup-owned state before a command can leave this buffer."
  (when proofread-popup--visible-p
    (condition-case err
        (proofread-popup--hide)
      (error
       (proofread-popup--report-cleanup-error
        (format "Proofread popup pre-command cleanup error: %s"
                (error-message-string err)))))))

(defun proofread-popup--validate-owners (&optional _frame)
  "Hide registered popups whose display ownership is no longer valid."
  (dolist (buffer (copy-sequence proofread-popup--owners))
    (if (buffer-live-p buffer)
        (condition-case err
            (with-current-buffer buffer
              (unless (proofread-popup--owner-valid-p)
                (proofread-popup--hide)))
          (error
           (proofread-popup--report-cleanup-error
            (format "Proofread popup ownership cleanup error: %s"
                    (error-message-string err)))))
      (setq proofread-popup--owners
            (delq buffer proofread-popup--owners)))))

(defun proofread-popup--delete-frame-owner (frame)
  "Delete registered popups whose parent frame is FRAME."
  (dolist (buffer (copy-sequence proofread-popup--owners))
    (if (buffer-live-p buffer)
        (condition-case err
            (with-current-buffer buffer
              (when (eq proofread-popup--owner-frame frame)
                (proofread-popup--delete)))
          (error
           (proofread-popup--report-cleanup-error
            (format "Proofread popup frame cleanup error: %s"
                    (error-message-string err)))))
      (setq proofread-popup--owners
            (delq buffer proofread-popup--owners)))))

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
  (let ((display-message (copy-sequence message)))
    (posframe-show
     (proofread-popup--ensure-buffer-name)
     :string display-message
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
     :hidehandler #'proofread-popup--hide-handler))
  (setq proofread-popup--render-signature signature)
  (setq proofread-popup--position position)
  (setq proofread-popup--window window)
  (setq proofread-popup--render-state snapshot)
  (setq proofread-popup--visible-p t)
  (proofread-popup--set-owner-target window)
  (proofread-popup--sync-owner-registry))

(defun proofread-popup--render-now (&optional selected-window)
  "Immediately update the child frame from the current buffer state.
SELECTED-WINDOW, when non-nil, is the already captured selected window."
  (if (and proofread-popup-mode
           proofread-mode
           proofread-popup-enabled)
      (let ((window (or selected-window (selected-window))))
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

(defun proofread-popup--idle-timer-run (buffer generation)
  "Render BUFFER when GENERATION still identifies its pending update."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq generation proofread-popup--update-generation)
        (let ((window (selected-window)))
          (if (proofread-popup--owner-valid-p window)
              (progn
                (setq proofread-popup--idle-timer nil)
                (setq proofread-popup--update-generation nil)
                (proofread-popup--sync-owner-registry)
                (proofread-popup--render-now window))
            (proofread-popup--hide)))))))

(defun proofread-popup--schedule-update ()
  "Schedule one idle popup update for the current buffer."
  (let ((window (proofread-popup--selected-owner-target)))
    (cond
     ((not window)
      (proofread-popup--hide))
     ((and (proofread-popup--owner-active-p)
           (not (and (eq proofread-popup--owner-window window)
                     (eq proofread-popup--owner-frame
                         (window-frame window)))))
      (proofread-popup--hide)
      (proofread-popup--schedule-update))
     ((not proofread-popup--idle-timer)
      (let* ((generation
              (make-symbol "proofread-popup-pending-generation"))
             (timer
              (run-with-idle-timer
               proofread-popup-delay nil
               #'proofread-popup--idle-timer-run
               (current-buffer) generation)))
        (proofread-popup--set-owner-target window)
        (setq proofread-popup--update-generation generation)
        (setq proofread-popup--idle-timer timer)
        (proofread-popup--sync-owner-registry))))))

(defun proofread-popup--update ()
  "Schedule an update for the Proofread diagnostic at point."
  (if (and proofread-popup-mode
           proofread-mode
           proofread-popup-enabled)
      (if (zerop proofread-popup-delay)
          (progn
            (proofread-popup--cancel-pending-update)
            (proofread-popup--render-now))
        (proofread-popup--schedule-update))
    (proofread-popup--hide)))

;;;; Mode lifecycle

(defun proofread-popup--disable-before-major-mode-change ()
  "Disable popup messages before changing the current major mode."
  (proofread-popup-mode -1))

(defun proofread-popup--enable ()
  "Install the buffer-local hooks used by `proofread-popup-mode'."
  (add-hook 'pre-command-hook
            #'proofread-popup--pre-command-cleanup nil t)
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
  (remove-hook 'pre-command-hook
               #'proofread-popup--pre-command-cleanup t)
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
mode interactively; the opt-out persists when `proofread-mode' is
disabled and re-enabled.  Enabling this mode interactively clears the
opt-out.

The popup displays only the live Proofread diagnostic returned by the
public diagnostic API, never diagnostics from other Flymake backends.
It supplements rather than replaces Flymake annotations and ElDoc.
When the public logical range start is accessible and visible, the
child frame is anchored there; otherwise it is anchored at point.  A
visible zero-width diagnostic uses its exact logical position."
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
  (remove-hook 'window-buffer-change-functions
               #'proofread-popup--validate-owners)
  (remove-hook 'window-selection-change-functions
               #'proofread-popup--validate-owners)
  (remove-hook 'delete-frame-functions
               #'proofread-popup--delete-frame-owner)
  (remove-hook 'proofread-mode-hook
               #'proofread-popup--sync-with-proofread-mode)
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (bound-and-true-p proofread-popup-mode)
          (proofread-popup-mode -1)))))
  (setq proofread-popup--owners nil)
  nil)

;;;; Runtime setup

(progn
  (add-hook 'window-buffer-change-functions
            #'proofread-popup--validate-owners)
  (add-hook 'window-selection-change-functions
            #'proofread-popup--validate-owners)
  (add-hook 'delete-frame-functions
            #'proofread-popup--delete-frame-owner)
  (add-hook 'proofread-mode-hook
            #'proofread-popup--sync-with-proofread-mode)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (proofread-popup--enable-in-existing-buffer))))

(provide 'proofread-popup)
;;; proofread-popup.el ends here
