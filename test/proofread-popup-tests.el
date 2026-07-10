;;; proofread-popup-tests.el --- Tests for proofread-popup  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the optional Proofread child-frame frontend.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)
(require 'proofread-popup)

(defun proofread-popup-test--diagnostic
    (beg end text &optional suggestions message)
  "Return a sample diagnostic for BEG, END, TEXT, SUGGESTIONS, and MESSAGE."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message (or message "Possible misspelling")
   :suggestions suggestions
   :source 'test))

(defun proofread-popup-test--install-diagnostics (diagnostics)
  "Install DIAGNOSTICS and return their proofread overlays."
  (setq proofread--diagnostics diagnostics)
  (mapcar #'proofread--create-overlay diagnostics))

(defmacro proofread-popup-test--with-posframe-recorder (&rest body)
  "Run BODY while recording calls to the Posframe frontend."
  (declare (indent 0) (debug (body)))
  `(let (proofread-popup-test--shows
         proofread-popup-test--hides
         proofread-popup-test--deletes)
     (cl-letf (((symbol-function 'posframe-workable-p)
                (lambda ()
                  t))
               ((symbol-function 'pos-visible-in-window-p)
                (lambda (&rest _args)
                  t))
               ((symbol-function 'posframe-show)
                (lambda (buffer-or-name &rest args)
                  (push (cons buffer-or-name args)
                        proofread-popup-test--shows)
                  'proofread-popup-test-posframe))
               ((symbol-function 'posframe-hide)
                (lambda (buffer-or-name)
                  (push buffer-or-name proofread-popup-test--hides)))
               ((symbol-function 'posframe-delete)
                (lambda (buffer-or-name)
                  (push buffer-or-name proofread-popup-test--deletes))))
       ,@body)))

(ert-deftest proofread-popup-test-faces-have-package-defaults ()
  "Proofread popup faces use the package defaults."
  (should (equal (face-default-spec 'proofread-popup-face)
                 '((t :inherit default))))
  (should (equal (face-default-spec 'proofread-popup-border-face)
                 '((((background dark)) :background "white")
                   (((background light)) :background "black")))))

(ert-deftest proofread-popup-test-max-width-rejects-zero-in-customize ()
  "Customize rejects a nonpositive popup width."
  (should (eq (get 'proofread-popup-max-width 'custom-set)
              #'proofread--set-positive-integer-option))
  (should-error
   (funcall (get 'proofread-popup-max-width 'custom-set)
            'proofread-popup-max-width 0)))

(ert-deftest proofread-popup-test-blank-message-falls-back-to-text ()
  "A blank diagnostic message falls back to the diagnostic text."
  (dolist (message '("" " \t\n"))
    (let ((diagnostic
           (proofread-popup-test--diagnostic 1 5 "helo" nil message)))
      (should (equal (proofread-popup--message diagnostic)
                     "Proofread: helo")))))

(ert-deftest proofread-popup-test-mode-follows-proofread-mode ()
  "The popup frontend follows the core minor mode automatically."
  (with-temp-buffer
    (should-not proofread-mode)
    (should-not proofread-popup-mode)
    (proofread-mode 1)
    (should proofread-popup-mode)
    (should (memq #'proofread-popup--update post-command-hook))
    (should (memq #'proofread-popup--update
                  proofread-diagnostics-changed-hook))
    (proofread-mode -1)
    (should-not proofread-popup-mode)
    (should-not (memq #'proofread-popup--update post-command-hook))
    (should-not (memq #'proofread-popup--update
                      proofread-diagnostics-changed-hook))))

(ert-deftest proofread-popup-test-diagnostics-change-shows-automatically ()
  "A diagnostics notification shows the popup without another command."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (goto-char 2)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo")))
         (proofread--apply-backend-diagnostics (list diagnostic))
         (should (= (length proofread-popup-test--shows) 1))
         (should (equal proofread-popup--diagnostic diagnostic))
         (should (eq proofread-popup--diagnostic
                     (car proofread--diagnostics))))))))

(ert-deftest proofread-popup-test-shows-message-above-diagnostic-start ()
  "The child frame uses the diagnostic message and range start."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic
               4 8 "helo" '("hello"))))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread-popup--update)
         (should (= (length proofread-popup-test--shows) 1))
         (let* ((call (car proofread-popup-test--shows))
                (args (cdr call))
                (string (plist-get args :string)))
           (should (string-prefix-p proofread-popup--buffer-prefix
                                    (car call)))
           (should (equal (substring-no-properties string)
                          "Possible misspelling"))
           (should (eq (get-text-property 0 'face string)
                       'proofread-popup-face))
           (should (= (plist-get args :position) 4))
           (should
            (eq (plist-get args :poshandler)
                #'posframe-poshandler-point-bottom-left-corner-upward))
           (should (= (plist-get args :internal-border-width) 1))
           (should (= (plist-get args :left-fringe) 3))
           (should (= (plist-get args :right-fringe) 3))
           (should (eq (plist-get args :accept-focus) nil))
           (should (member '(no-accept-focus . t)
                           (plist-get args :override-parameters)))
           (should (member '(no-focus-on-map . t)
                           (plist-get args :override-parameters)))))))))

(ert-deftest proofread-popup-test-uses-themed-face-colors ()
  "The child frame forwards colors from the active face."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (cl-letf (((symbol-function 'face-attribute)
                    (lambda (face attribute &rest _args)
                      (pcase (list face attribute)
                        (`(proofread-popup-face :foreground)
                         "theme-foreground")
                        (`(proofread-popup-face :background)
                         "theme-background")
                        (`(proofread-popup-border-face :background)
                         "theme-border")))))
           (proofread-popup--update))
         (let* ((call (car proofread-popup-test--shows))
                (args (cdr call)))
           (should (equal (plist-get args :foreground-color)
                          "theme-foreground"))
           (should (equal (plist-get args :background-color)
                          "theme-background"))
           (should (equal (plist-get args :internal-border-color)
                          "theme-border"))))))))

(ert-deftest proofread-popup-test-does-not-refresh-same-diagnostic ()
  "Moving inside one diagnostic does not repeatedly redraw the child frame."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 4 8 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread-popup--update)
         (goto-char 7)
         (proofread-popup--update)
         (should (= (length proofread-popup-test--shows) 1)))))))

(ert-deftest proofread-popup-test-refreshes-after-window-state-change ()
  "A window layout state change redraws the current diagnostic."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 4 8 "helo"))
             (window-start-position 1))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (cl-letf (((symbol-function 'window-start)
                    (lambda (&optional _window)
                      window-start-position)))
           (proofread-popup--update)
           (proofread-popup--update)
           (should (= (length proofread-popup-test--shows) 1))
           (setq window-start-position 2)
           (proofread-popup--update)
           (should (= (length proofread-popup-test--shows) 2))))))))

(ert-deftest proofread-popup-test-inaccessible-start-anchors-at-point ()
  "A diagnostic starting outside narrowing is anchored at point."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 8 "aa helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (narrow-to-region 4 (point-max))
         (goto-char 5)
         (proofread-popup--update)
         (should (= (length proofread-popup-test--shows) 1))
         (should (= (plist-get (cdar proofread-popup-test--shows) :position)
                    (point))))))))

(ert-deftest proofread-popup-test-hides-away-from-diagnostic ()
  "The child frame hides when point leaves diagnostics."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 4 8 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread-popup--update)
         (goto-char 10)
         (proofread-popup--update)
         (should proofread-popup-test--hides)
         (should-not proofread-popup--diagnostic))))))

(ert-deftest proofread-popup-test-hidehandler-allows-reshow-after-switch ()
  "Returning after the Posframe hide handler ran shows the popup again."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (let ((source (generate-new-buffer " *proofread-popup-source*"))
           (other (generate-new-buffer " *proofread-popup-other*")))
       (unwind-protect
           (progn
             (switch-to-buffer source)
             (insert "helo")
             (proofread-mode 1)
             (let ((diagnostic
                    (proofread-popup-test--diagnostic 1 5 "helo")))
               (proofread-popup-test--install-diagnostics
                (list diagnostic))
               (goto-char 2)
               (proofread-popup--update)
               (let* ((args (cdar proofread-popup-test--shows))
                      (hidehandler (plist-get args :hidehandler)))
                 (switch-to-buffer other)
                 (should
                  (funcall
                   hidehandler
                   (list :posframe-parent-buffer
                         (cons nil source))))
                 (switch-to-buffer source)
                 (proofread-popup--update)
                 (should (= (length proofread-popup-test--shows) 2)))))
         (when (buffer-live-p source)
           (kill-buffer source))
         (when (buffer-live-p other)
           (kill-buffer other)))))))

(ert-deftest proofread-popup-test-disabled-does-not-show ()
  "Disabling popup display prevents child frame creation."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((proofread-popup-enabled nil)
             (diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (proofread-popup--update)
         (should-not proofread-popup-test--shows))))))

(ert-deftest proofread-popup-test-manual-opt-out-persists ()
  "A manual popup opt-out survives core mode disable and re-enable."
  (with-temp-buffer
    (proofread-mode 1)
    (should proofread-popup-mode)
    (cl-letf (((symbol-function 'called-interactively-p)
               (lambda (&optional _kind)
                 t)))
      (proofread-popup-mode -1))
    (should-not proofread-popup-mode)
    (should proofread-popup--user-disabled-p)
    (proofread-mode -1)
    (proofread-mode 1)
    (should-not proofread-popup-mode)
    (should proofread-popup--user-disabled-p)
    (cl-letf (((symbol-function 'called-interactively-p)
               (lambda (&optional _kind)
                 t)))
      (proofread-popup-mode 1))
    (should proofread-popup-mode)
    (should-not proofread-popup--user-disabled-p)))

(ert-deftest proofread-popup-test-disable-core-mode-cleans-up ()
  "Disabling `proofread-mode' disables and cleans up the popup frontend."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (proofread-popup--update)
         (proofread-mode -1)
         (should-not proofread-popup-mode)
         (should proofread-popup-test--hides)
         (should proofread-popup-test--deletes)
         (should-not (memq #'proofread-popup--update post-command-hook))
         (should-not (memq #'proofread-popup--update
                           proofread-diagnostics-changed-hook))
         (should-not proofread-popup--diagnostic))))))

(ert-deftest proofread-popup-test-major-mode-change-cleans-up ()
  "Changing major mode deletes the popup and removes local hooks."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo")))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (proofread-popup--update)
         (text-mode)
         (should-not proofread-mode)
         (should-not proofread-popup-mode)
         (should proofread-popup-test--deletes)
         (should-not (memq #'proofread-popup--update post-command-hook))
         (should-not (memq #'proofread-popup--update
                           proofread-diagnostics-changed-hook)))))))

(ert-deftest proofread-popup-test-kill-buffer-deletes-frame ()
  "Killing a Proofread buffer deletes its popup child frame."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (let ((buffer (generate-new-buffer " *proofread-popup-kill*")))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (insert "helo")
             (proofread-mode 1)
             (let ((diagnostic
                    (proofread-popup-test--diagnostic 1 5 "helo")))
               (proofread-popup-test--install-diagnostics
                (list diagnostic))
               (goto-char 2)
               (proofread-popup--update)
               (kill-buffer buffer)
               (should-not (buffer-live-p buffer))
               (should proofread-popup-test--deletes)))
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(ert-deftest proofread-popup-test-correct-at-point-hides-frame ()
  "Point correction immediately hides the corrected diagnostic's frame."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic
               4 8 "helo" '("hello"))))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread-popup--update)
         (should proofread-popup--diagnostic)
         (proofread-correct-at-point)
         (should proofread-popup-test--hides)
         (should-not proofread-popup--diagnostic)
         (should (equal (buffer-string) "aa hello zz")))))))

(ert-deftest proofread-popup-test-unload-cleans-existing-buffers ()
  "Unloading the frontend deletes popups and removes global integration."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (let ((buffer (generate-new-buffer " *proofread-popup-unload*")))
       (unwind-protect
           (progn
             (switch-to-buffer buffer)
             (insert "helo")
             (proofread-mode 1)
             (let ((diagnostic
                    (proofread-popup-test--diagnostic 1 5 "helo")))
               (proofread-popup-test--install-diagnostics
                (list diagnostic))
               (goto-char 2)
               (proofread-popup--update))
             (unload-feature 'proofread-popup t)
             (should proofread-popup-test--deletes)
             (should-not
              (memq #'proofread-popup--sync-with-proofread-mode
                    proofread-mode-hook))
             (with-current-buffer buffer
               (should-not (bound-and-true-p proofread-popup-mode))))
         (require 'proofread-popup)
         (when (buffer-live-p buffer)
           (kill-buffer buffer)))))))

(provide 'proofread-popup-tests)

;;; proofread-popup-tests.el ends here
