;;; proofread-popup-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the optional Proofread child-frame frontend.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)
(require 'proofread-popup)

;;;; Test support

(defun proofread-popup-test--diagnostic
    (beg end text &optional suggestions message)
  "Return a sample diagnostic for BEG, END, and TEXT.
SUGGESTIONS and MESSAGE supply the optional field values."
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

(defun proofread-popup-test--diagnostic-with-binding
    (diagnostic binding)
  "Return DIAGNOSTIC annotated as owned by BINDING."
  (let ((diagnostic (copy-sequence diagnostic)))
    (setq diagnostic (plist-put diagnostic :profile 'multi))
    (setq diagnostic (plist-put diagnostic :binding-name binding))
    (plist-put diagnostic :binding-owner
               (list :profile 'multi :binding-name binding))))

(defmacro proofread-popup-test--with-posframe-recorder (&rest body)
  "Run BODY and record invocations of the Posframe frontend."
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
                  (push buffer-or-name
                        proofread-popup-test--deletes))))
       ,@body)))

;;;; Configuration and messages

(ert-deftest proofread-popup-test-faces-have-package-defaults ()
  "Proofread popup faces use the package defaults."
  (should (equal (face-default-spec 'proofread-popup-face)
                 '((t :inherit default))))
  (should (equal (face-default-spec 'proofread-popup-border-face)
                 '((((background dark)) :background "white")
                   (((background light)) :background "black")))))

(ert-deftest
    proofread-popup-test-max-width-rejects-zero-in-customize ()
  "Customize rejects a nonpositive popup width."
  (should (eq (get 'proofread-popup-max-width 'custom-set)
              #'proofread-set-positive-integer-option))
  (should-error
   (funcall (get 'proofread-popup-max-width 'custom-set)
            'proofread-popup-max-width 0)))

(ert-deftest proofread-popup-test-blank-message-falls-back-to-text ()
  "A blank diagnostic message falls back to the diagnostic text."
  (dolist (message '( "" " \t\n"))
    (let ((diagnostic
           (proofread-popup-test--diagnostic 1 5 "helo" nil message)))
      (should (equal (proofread-popup--message diagnostic)
                     "Proofread: helo")))))

(ert-deftest
    proofread-popup-test-uses-shared-diagnostic-field-formatter ()
  "Popup messages delegate non-string fields to the core formatter."
  (let ((message-diagnostic
         (proofread-popup-test--diagnostic
          1 5 "helo" nil 'misspelling))
        (text-diagnostic
         (proofread-popup-test--diagnostic
          1 5 '( bad "text") nil ""))
        fields)
    (cl-letf (((symbol-function 'proofread-format-diagnostic-field)
               (lambda (value)
                 (push value fields)
                 "<formatted>")))
      (should (equal (proofread-popup--message message-diagnostic)
                     "<formatted>"))
      (should (equal (proofread-popup--message text-diagnostic)
                     "Proofread: <formatted>")))
    (should (equal (nreverse fields)
                   '( misspelling ( bad "text"))))))

(ert-deftest proofread-popup-test-message-aggregates-bindings ()
  "Popup messages use aggregate binding summaries."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((first
           (proofread-popup-test--diagnostic-with-binding
            (proofread-popup-test--diagnostic
             1 5 "helo" '( "hello") "First message")
            'first))
          (second
           (proofread-popup-test--diagnostic-with-binding
            (proofread-popup-test--diagnostic
             1 5 "helo" '( "hello") "Second message")
            'second)))
      (proofread-popup-test--install-diagnostics
       (list first second))
      (goto-char 2)
      (should
       (equal
        (proofread-popup--message
         (proofread-diagnostic-at-point))
        "first: First message; second: Second message")))))

;;;; Core integration

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

(ert-deftest
    proofread-popup-test-diagnostics-change-shows-automatically ()
  "A notification shows the popup without another command."
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

;;;; Rendering

(ert-deftest
    proofread-popup-test-update-captures-render-inputs-once ()
  "One popup update captures each render input exactly once."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let* ((diagnostic
               (proofread-popup-test--diagnostic 1 5 "helo"))
              (selected-window-function
               (symbol-function 'selected-window))
              (diagnostic-function
               (symbol-function 'proofread-diagnostic-at-point))
              (anchor-function
               (symbol-function 'proofread-popup--anchor-position))
              (snapshot-function
               (symbol-function 'proofread-popup--render-snapshot))
              (available-function
               (symbol-function 'proofread-popup--available-p))
              (selection-calls 0)
              (diagnostic-calls 0)
              (anchor-calls 0)
              (snapshot-calls 0)
              (available-calls 0)
              selected-window-value
              anchor-window
              snapshot-window
              snapshot)
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (cl-letf (((symbol-function 'selected-window)
                    (lambda ()
                      (setq selection-calls (1+ selection-calls))
                      (setq selected-window-value
                            (funcall selected-window-function))))
                   ((symbol-function 'proofread-diagnostic-at-point)
                    (lambda (&rest args)
                      (setq diagnostic-calls (1+ diagnostic-calls))
                      (apply diagnostic-function args)))
                   ((symbol-function
                     'proofread-popup--anchor-position)
                    (lambda (value window)
                      (setq anchor-calls (1+ anchor-calls))
                      (setq anchor-window window)
                      (funcall anchor-function value window)))
                   ((symbol-function
                     'proofread-popup--render-snapshot)
                    (lambda (window)
                      (setq snapshot-calls (1+ snapshot-calls))
                      (setq snapshot-window window)
                      (setq snapshot
                            (funcall snapshot-function window))))
                   ((symbol-function 'proofread-popup--available-p)
                    (lambda ()
                      (setq available-calls (1+ available-calls))
                      (funcall available-function))))
           (proofread-popup--update))
         (should (= (length proofread-popup-test--shows) 1))
         (should (= selection-calls 1))
         (should (= diagnostic-calls 1))
         (should (= anchor-calls 1))
         (should (= snapshot-calls 1))
         (should (= available-calls 1))
         (should (eq anchor-window selected-window-value))
         (should (eq snapshot-window selected-window-value))
         (should (eq proofread-popup--window selected-window-value))
         (should (eq proofread-popup--render-state snapshot)))))))

(ert-deftest
    proofread-popup-test-shows-message-above-diagnostic-start ()
  "The child frame uses the diagnostic message and range start."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic
               4 8 "helo" '( "hello"))))
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
            (eq
             (plist-get args :poshandler)
             #'posframe-poshandler-point-bottom-left-corner-upward))
           (should (= (plist-get args :internal-border-width) 1))
           (should (= (plist-get args :left-fringe) 3))
           (should (= (plist-get args :right-fringe) 3))
           (should (eq (plist-get args :accept-focus) nil))
           (should (member '( no-accept-focus . t)
                           (plist-get args :override-parameters)))
           (should (member '( no-focus-on-map . t)
                           (plist-get
                            args :override-parameters)))))))))

(ert-deftest proofread-popup-test-uses-themed-face-colors ()
  "The child frame forwards colors from the active face."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "helo")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic 1 5 "helo"))
             face-attributes)
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 2)
         (cl-letf (((symbol-function 'face-attribute)
                    (lambda (face attribute &rest _args)
                      (push (list face attribute) face-attributes)
                      (pcase (list face attribute)
                        (`( proofread-popup-face :foreground)
                         "theme-foreground")
                        (`( proofread-popup-face :background)
                         "theme-background")
                        (`( proofread-popup-border-face :background)
                         "theme-border")))))
           (proofread-popup--update))
         (let* ((call (car proofread-popup-test--shows))
                (args (cdr call)))
           (should (equal (plist-get args :foreground-color)
                          "theme-foreground"))
           (should (equal (plist-get args :background-color)
                          "theme-background"))
           (should (equal (plist-get args :internal-border-color)
                          "theme-border"))
           (should (= (length face-attributes) 3))
           (dolist (field
                    '( (proofread-popup-face :foreground)
                       (proofread-popup-face :background)
                       (proofread-popup-border-face :background)))
             (should (= (cl-count field face-attributes :test #'equal)
                        1)))))))))

(ert-deftest proofread-popup-test-does-not-refresh-same-diagnostic ()
  "Movement within one diagnostic does not redraw the child frame."
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

(ert-deftest
    proofread-popup-test-refreshes-after-window-state-change ()
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

(ert-deftest
    proofread-popup-test-inaccessible-start-anchors-at-point ()
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
         (should
          (= (plist-get
              (cdar proofread-popup-test--shows) :position)
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

(ert-deftest
    proofread-popup-test-hide-and-delete-reset-display-state ()
  "Hide and delete reset display state without duplicate cleanup."
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
         (let ((popup-buffer-name proofread-popup--buffer-name))
           (should popup-buffer-name)
           (should (eq proofread-popup--diagnostic diagnostic))
           (should (= proofread-popup--position 1))
           (should (eq proofread-popup--window (selected-window)))
           (should proofread-popup--render-state)
           (proofread-popup--hide)
           (should (equal proofread-popup-test--hides
                          (list popup-buffer-name)))
           (should (equal proofread-popup--buffer-name
                          popup-buffer-name))
           (should-not proofread-popup--diagnostic)
           (should-not proofread-popup--position)
           (should-not proofread-popup--window)
           (should-not proofread-popup--render-state)
           (proofread-popup--hide)
           (should (= (length proofread-popup-test--hides) 1))
           (proofread-popup--update)
           (should (= (length proofread-popup-test--shows) 2))
           (should (equal (caar proofread-popup-test--shows)
                          popup-buffer-name))
           (proofread-popup--delete)
           (should (equal proofread-popup-test--deletes
                          (list popup-buffer-name)))
           (should-not proofread-popup--buffer-name)
           (should-not proofread-popup--diagnostic)
           (should-not proofread-popup--position)
           (should-not proofread-popup--window)
           (should-not proofread-popup--render-state)
           (proofread-popup--delete)
           (should (= (length proofread-popup-test--deletes) 1))))))))

(ert-deftest
    proofread-popup-test-hide-handler-allows-reshow-after-switch ()
  "The popup returns after Posframe's hide handler runs."
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
                      (hide-handler (plist-get args :hidehandler))
                      (popup-buffer-name
                       proofread-popup--buffer-name))
                 (switch-to-buffer other)
                 (should
                  (funcall
                   hide-handler
                   (list :posframe-parent-buffer
                         (cons nil source))))
                 (with-current-buffer source
                   (should (equal proofread-popup--buffer-name
                                  popup-buffer-name))
                   (should-not proofread-popup--diagnostic)
                   (should-not proofread-popup--position)
                   (should-not proofread-popup--window)
                   (should-not proofread-popup--render-state))
                 (switch-to-buffer source)
                 (proofread-popup--update)
                 (should
                  (= (length proofread-popup-test--shows) 2)))))
         (when (buffer-live-p source)
           (kill-buffer source))
         (when (buffer-live-p other)
           (kill-buffer other)))))))

;;;; Availability and lifecycle

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

(ert-deftest proofread-popup-test-unavailable-refresh-hides-frame ()
  "An unavailable Posframe hides a popup that needs refreshing."
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
         (let ((proofread-popup-max-width
                (1+ proofread-popup-max-width)))
           (cl-letf (((symbol-function 'posframe-workable-p)
                      (lambda ()
                        nil)))
             (proofread-popup--update)))
         (should (= (length proofread-popup-test--shows) 1))
         (should (= (length proofread-popup-test--hides) 1))
         (should-not proofread-popup--diagnostic)
         (should-not proofread-popup--position)
         (should-not proofread-popup--window)
         (should-not proofread-popup--render-state))))))

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
  "Disabling core mode cleans up the popup frontend."
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
         (should-not
          (memq #'proofread-popup--update post-command-hook))
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
         (should-not
          (memq #'proofread-popup--update post-command-hook))
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
  "Correction at point immediately hides its diagnostic frame."
  (proofread-popup-test--with-posframe-recorder
   (save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (insert "aa helo zz")
       (proofread-mode 1)
       (let ((diagnostic
              (proofread-popup-test--diagnostic
               4 8 "helo" '( "hello"))))
         (proofread-popup-test--install-diagnostics (list diagnostic))
         (goto-char 5)
         (proofread-popup--update)
         (should proofread-popup--diagnostic)
         (proofread-correct-at-point)
         (should proofread-popup-test--hides)
         (should-not proofread-popup--diagnostic)
         (should (equal (buffer-string) "aa hello zz")))))))

(ert-deftest proofread-popup-test-unload-cleans-existing-buffers ()
  "Unloading the frontend removes all popup integration."
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
