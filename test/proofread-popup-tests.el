;;; proofread-popup-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the optional Proofread child-frame frontend.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'package)
(require 'proofread)
(require 'proofread-popup)

;; Popup timer tests should not count Flymake's independent idle timer.
(setq flymake-no-changes-timeout nil)

;;;; Test support

(defun proofread-popup-test--diagnostic
    (beg end text &optional suggestions message source)
  "Return a sample diagnostic for BEG, END, and TEXT.
SUGGESTIONS, MESSAGE, and SOURCE supply the optional field values."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message (or message "Possible misspelling")
   :suggestions suggestions
   :source (or source 'test)))

(defun proofread-popup-test--install-diagnostics (diagnostics)
  "Install DIAGNOSTICS and return their proofread overlays."
  (setq proofread--diagnostics diagnostics)
  (mapcar #'proofread--create-overlay diagnostics))

(defun proofread-popup-test--diagnostic-with-checker
    (diagnostic checker)
  "Return DIAGNOSTIC annotated as owned by CHECKER."
  (let ((diagnostic (copy-sequence diagnostic)))
    (setq diagnostic (plist-put diagnostic :profile 'multi))
    (setq diagnostic (plist-put diagnostic :checker-name checker))
    (plist-put diagnostic :checker-owner
               (list :profile 'multi :checker-name checker))))

(defmacro proofread-popup-test--with-posframe-recorder (&rest body)
  "Record Posframe invocations while running BODY with immediate rendering."
  (declare (indent 0) (debug (body)))
  `(let ((proofread-popup-delay 0)
         (proofread-auto-check nil)
         (proofread-popup--owners nil)
         proofread-popup-test--shows
         proofread-popup-test--hides
         proofread-popup-test--deletes
         proofread-popup-test--events)
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
                  (push (list 'show buffer-or-name)
                        proofread-popup-test--events)
                  'proofread-popup-test-posframe))
               ((symbol-function 'posframe-hide)
                (lambda (buffer-or-name)
                  (push buffer-or-name proofread-popup-test--hides)
                  (push (list 'hide buffer-or-name)
                        proofread-popup-test--events)))
               ((symbol-function 'posframe-delete)
                (lambda (buffer-or-name)
                  (push buffer-or-name
                        proofread-popup-test--deletes)
                  (push (list 'delete buffer-or-name)
                        proofread-popup-test--events))))
       ,@body)))

(defmacro proofread-popup-test--with-idle-timer-recorder (&rest body)
  "Run BODY and record idle timer creation and cancellation."
  (declare (indent 0) (debug (body)))
  `(let (proofread-popup-test--idle-timer-calls
         proofread-popup-test--canceled-timers)
     (cl-letf (((symbol-function 'run-with-idle-timer)
                (lambda (seconds repeat function &rest arguments)
                  (let* ((timer (timer-create))
                         (call
                          (list :timer timer
                                :seconds seconds
                                :repeat repeat
                                :function function
                                :arguments arguments)))
                    (push call
                          proofread-popup-test--idle-timer-calls)
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer)
                  (push timer
                        proofread-popup-test--canceled-timers))))
       ,@body)))

(defun proofread-popup-test--popup-idle-timer-calls (records)
  "Filter RECORDS to popup idle timer entries in creation order."
  (nreverse
   (cl-remove-if-not
    (lambda (call)
      (eq (plist-get call :function)
          #'proofread-popup--idle-timer-run))
    records)))

(defun proofread-popup-test--fire-idle-timer (call)
  "Invoke recorded idle timer CALL."
  (apply (plist-get call :function)
         (plist-get call :arguments)))

(defvar proofread-popup-test--events nil)

(defvar proofread-popup-test--switch-target nil)

(defun proofread-popup-test--switch-buffer-command ()
  "Switch to `proofread-popup-test--switch-target' as a test command."
  (interactive)
  (push '(command) proofread-popup-test--events)
  (switch-to-buffer proofread-popup-test--switch-target))

(defun proofread-popup-test--noop-command ()
  "Do nothing as an interactive test command."
  (interactive))

;;;; Configuration and messages

(ert-deftest proofread-popup-test-package-metadata ()
  "Package metadata requires proofread 0.2.0 for popup 0.1.1."
  (let ((source (locate-file "proofread-popup.el" load-path)))
    (should source)
    (with-temp-buffer
      (insert-file-contents source)
      (let ((description (package-buffer-info)))
        (should (equal (package-desc-version description)
                       '(0 1 1)))
        (should (equal (cadr (assq 'proofread
                                   (package-desc-reqs description)))
                       '(0 2 0)))))))

(ert-deftest proofread-popup-test-faces-have-package-defaults ()
  "Proofread popup faces use the package defaults."
  (should (equal (face-default-spec 'proofread-popup-face)
                 '((t :inherit font-lock-comment-face))))
  (should (equal (face-default-spec 'proofread-popup-source-face)
                 '((t :inherit font-lock-keyword-face))))
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

(ert-deftest proofread-popup-test-delay-is-nonnegative ()
  "The popup delay defaults to 0.5 and rejects negative values."
  (should (= (default-value 'proofread-popup-delay) 0.5))
  (should
   (eq (get 'proofread-popup-delay 'custom-set)
       #'proofread-popup--set-nonnegative-number-option))
  (let ((symbol (make-symbol "proofread-popup-test-delay")))
    (proofread-popup--set-nonnegative-number-option symbol 0)
    (should (zerop (default-value symbol)))
    (should-error
     (proofread-popup--set-nonnegative-number-option symbol -0.1)
     :type 'user-error)
    (should-error
     (proofread-popup--set-nonnegative-number-option symbol "0.5")
     :type 'user-error)))

(ert-deftest proofread-popup-test-blank-message-falls-back-to-text ()
  "A blank diagnostic message falls back to the diagnostic text."
  (dolist (message '(nil "" " \t\n"))
    (let ((diagnostic
           (proofread-popup-test--diagnostic 1 5 "helo")))
      (setf (plist-get diagnostic :message) message)
      (should (equal (proofread-popup--message diagnostic)
                     "test: Proofread: helo")))))

(ert-deftest proofread-popup-test-blank-source-shows-bare-message ()
  "A missing or blank diagnostic source leaves the message unprefixed."
  (dolist (source '(nil "" " \t\n"))
    (let ((diagnostic
           (proofread-popup-test--diagnostic 1 5 "helo")))
      (setf (plist-get diagnostic :source) source)
      (let ((message (proofread-popup--message diagnostic)))
        (should (equal message "Possible misspelling"))
        (should (eq (get-text-property 0 'face message)
                    'proofread-popup-face))))))

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
    (setf (plist-get message-diagnostic :source) nil)
    (setf (plist-get text-diagnostic :source) nil)
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

(ert-deftest proofread-popup-test-message-aggregates-checkers ()
  "Popup messages preserve each aggregate member's source."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-popup-delay 0)
    (proofread-mode 1)
    (let ((first
           (proofread-popup-test--diagnostic-with-checker
            (proofread-popup-test--diagnostic
             1 5 "helo" '( "hello") "First message" "gpt-5.4")
            'first))
          (second
           (proofread-popup-test--diagnostic-with-checker
            (proofread-popup-test--diagnostic
             1 5 "helo" '( "hello") "Second message" 'languagetool)
            'second)))
      (proofread-popup-test--install-diagnostics
       (list first second))
      (goto-char 2)
      (let ((message
             (proofread-popup--message
              (proofread-diagnostic-at-point))))
        (should
         (equal message
                (concat "gpt-5.4: First message\n"
                        "languagetool: Second message")))
        (should (eq (get-text-property 0 'face message)
                    'proofread-popup-source-face))
        (should (eq (get-text-property 7 'face message)
                    'proofread-popup-source-face))
        (should-not (get-text-property 8 'face message))
        (should (eq (get-text-property 9 'face message)
                    'proofread-popup-face))
        (let ((second-source
               (string-match-p "languagetool" message)))
          (should second-source)
          (should
           (eq (get-text-property second-source 'face message)
               'proofread-popup-source-face))
          (should
           (eq (get-text-property (+ second-source 12) 'face message)
               'proofread-popup-source-face))
          (should-not
           (get-text-property (+ second-source 13) 'face message))
          (should
           (eq (get-text-property (+ second-source 14) 'face message)
               'proofread-popup-face)))))))

;;;; Core integration

(ert-deftest proofread-popup-test-mode-follows-proofread-mode ()
  "The popup frontend follows the core minor mode automatically."
  (with-temp-buffer
    (setq-local proofread-popup-delay 0)
    (should-not proofread-mode)
    (should-not proofread-popup-mode)
    (proofread-mode 1)
    (should proofread-popup-mode)
    (should (memq #'proofread-popup--pre-command-cleanup
                  pre-command-hook))
    (should (memq #'proofread-popup--update post-command-hook))
    (should (memq #'proofread-popup--update
                  proofread-diagnostics-changed-hook))
    (proofread-mode -1)
    (should-not proofread-popup-mode)
    (should-not (memq #'proofread-popup--pre-command-cleanup
                      pre-command-hook))
    (should-not (memq #'proofread-popup--update post-command-hook))
    (should-not (memq #'proofread-popup--update
                      proofread-diagnostics-changed-hook))))

(ert-deftest proofread-popup-test-ownership-hooks-are-default ()
  "Window and frame ownership hooks are installed globally once."
  (dolist (entry
           '((window-buffer-change-functions
              proofread-popup--validate-owners)
             (window-selection-change-functions
              proofread-popup--validate-owners)
             (delete-frame-functions
              proofread-popup--delete-frame-owner)))
    (should
     (= (cl-count (cadr entry) (default-value (car entry))) 1))))

(ert-deftest
    proofread-popup-test-diagnostics-change-shows-automatically ()
  "A notification schedules a delayed popup without another command."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(goto-char 2)
	(let ((diagnostic
               (proofread-popup-test--diagnostic 1 5 "helo"))
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-mode 1)
            (let ((startup-call
                   (car
                    (proofread-popup-test--popup-idle-timer-calls
                     proofread-popup-test--idle-timer-calls))))
              (proofread-popup-test--fire-idle-timer startup-call))
            (should-not proofread-popup-test--shows)
            (proofread--apply-backend-diagnostics (list diagnostic))
            (let ((calls
                   (proofread-popup-test--popup-idle-timer-calls
                    proofread-popup-test--idle-timer-calls)))
              (should (= (length calls) 2))
              (should-not proofread-popup-test--shows)
              (proofread-popup-test--fire-idle-timer (cadr calls)))
            (should (= (length proofread-popup-test--shows) 1))
            (should proofread-popup--render-signature)
            (should (equal diagnostic (car proofread--diagnostics)))))))))

;;;; Delayed scheduling

(ert-deftest proofread-popup-test-waits-for-idle-callback ()
  "Mode startup and diagnostics coalesce before the idle callback."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(goto-char 2)
	(let ((proofread-auto-check nil)
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-mode 1)
            (proofread--apply-backend-diagnostics
             (list (proofread-popup-test--diagnostic 1 5 "helo")))
            (let ((calls
                   (proofread-popup-test--popup-idle-timer-calls
                    proofread-popup-test--idle-timer-calls)))
              (should (= (length calls) 1))
              (should (= (plist-get (car calls) :seconds) 0.5))
              (should-not (plist-get (car calls) :repeat))
              (should-not proofread-popup-test--shows)
              (should proofread-popup--idle-timer)
              (with-temp-buffer
		(proofread-popup-test--fire-idle-timer (car calls)))
              (should (= (length proofread-popup-test--shows) 1))
              (should-not proofread-popup--idle-timer)
              (should-not proofread-popup--update-generation))))))))

(ert-deftest proofread-popup-test-coalesces-and-rereads-final-state ()
  "One delayed update reads the final point, window, and diagnostic."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "one xx two")
	(proofread-mode 1)
	(let* ((first
		(proofread-popup-test--diagnostic
                 1 4 "one" nil "First message"))
               (second
		(proofread-popup-test--diagnostic
                 8 11 "two" nil "Second message"))
               (first-window (selected-window))
               (second-window
		(split-window first-window nil 'below))
               (proofread-popup-max-width 80)
               (proofread-popup-delay 0.5))
          (proofread-popup-test--install-diagnostics
           (list first second))
          (goto-char 2)
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (goto-char 3)
            (proofread-popup--update)
            (setf (plist-get second :message) "Final message")
            (setq proofread-popup-max-width 43)
            (set-window-point second-window 9)
            (select-window second-window)
            (proofread-popup--update)
            (let ((calls
                   (proofread-popup-test--popup-idle-timer-calls
                    proofread-popup-test--idle-timer-calls)))
              (should (= (length calls) 2))
              (should-not proofread-popup-test--shows)
              (should
               (memq (plist-get (car calls) :timer)
                     proofread-popup-test--canceled-timers))
              (proofread-popup-test--fire-idle-timer (car calls))
              (should-not proofread-popup-test--shows)
              (proofread-popup-test--fire-idle-timer (cadr calls)))
            (should (= (length proofread-popup-test--shows) 1))
            (should (eq proofread-popup--window second-window))
            (should (= proofread-popup--position 8))
            (should
             (= (plist-get (cdar proofread-popup-test--shows)
                           :max-width)
		43))
            (should
             (= (plist-get proofread-popup--render-state :max-width)
		43))
            (should
             (equal
              (substring-no-properties
               (plist-get (cdar proofread-popup-test--shows) :string))
              "test: Final message"))))))))

(ert-deftest proofread-popup-test-delayed-update-ignores-stale-diagnostic ()
  "A delayed update renders a replacement diagnostic, not stale data."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic
		1 5 "helo" nil "Old message")))
	(goto-char 2)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (proofread-clear)
            (proofread-popup-test--install-diagnostics
             (list (proofread-popup-test--diagnostic
                    1 5 "helo" nil "Replacement message")))
            (let ((calls
                   (proofread-popup-test--popup-idle-timer-calls
                    proofread-popup-test--idle-timer-calls)))
              (should (= (length calls) 1))
              (proofread-popup-test--fire-idle-timer (car calls)))
            (should
             (equal
              (substring-no-properties
               (plist-get (cdar proofread-popup-test--shows) :string))
              "test: Replacement message"))))))))

(ert-deftest proofread-popup-test-stale-generation-preserves-new-timer ()
  "A canceled callback neither renders nor clears a newer timer."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((old-call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (old-timer (plist-get old-call :timer)))
              (proofread-popup--cancel-pending-update)
              (proofread-popup--update)
              (let* ((calls
                      (proofread-popup-test--popup-idle-timer-calls
                       proofread-popup-test--idle-timer-calls))
                     (new-call (cadr calls))
                     (new-timer (plist-get new-call :timer)))
		(should (= (length calls) 2))
		(should (memq old-timer
                              proofread-popup-test--canceled-timers))
		(should (eq proofread-popup--idle-timer new-timer))
		(proofread-popup-test--fire-idle-timer old-call)
		(should-not proofread-popup-test--shows)
		(should (eq proofread-popup--idle-timer new-timer))
		(proofread-popup-test--fire-idle-timer new-call)
		(should (= (length proofread-popup-test--shows) 1))
		(should-not proofread-popup--idle-timer)
		(should-not proofread-popup--update-generation)
		(proofread-popup-test--fire-idle-timer new-call)
		(should
		 (= (length proofread-popup-test--shows) 1))))))))))

(ert-deftest
    proofread-popup-test-generation-survives-major-mode-local-reset ()
  "A stale callback cannot match a new timer after local variables reset."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(goto-char 2)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((old-call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (old-timer (plist-get old-call :timer)))
              (text-mode)
              (proofread-mode 1)
              (proofread-popup-test--install-diagnostics
               (list (proofread-popup-test--diagnostic 1 5 "helo")))
              (let* ((calls
                      (proofread-popup-test--popup-idle-timer-calls
                       proofread-popup-test--idle-timer-calls))
                     (new-call (cadr calls))
                     (new-timer (plist-get new-call :timer)))
		(should (= (length calls) 2))
		(should (memq old-timer
                              proofread-popup-test--canceled-timers))
		(should (eq proofread-popup--idle-timer new-timer))
		(proofread-popup-test--fire-idle-timer old-call)
		(should-not proofread-popup-test--shows)
		(should (eq proofread-popup--idle-timer new-timer))
		(proofread-popup-test--fire-idle-timer new-call)
		(should (= (length proofread-popup-test--shows) 1))))))))))

(ert-deftest proofread-popup-test-zero-delay-cancels-pending-update ()
  "Switching to zero delay cancels pending work and renders immediately."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer)))
              (let ((proofread-popup-delay 0))
		(proofread-popup--update))
              (should (memq timer
                            proofread-popup-test--canceled-timers))
              (should (= (length proofread-popup-test--shows) 1))
              (should-not proofread-popup--idle-timer)
              (should-not proofread-popup--update-generation)
              (let ((signature proofread-popup--render-signature))
		(proofread-popup-test--fire-idle-timer call)
		(should (= (length proofread-popup-test--shows) 1))
		(should
		 (equal-including-properties
                  proofread-popup--render-signature signature))))))))))

(ert-deftest proofread-popup-test-pending-updates-are-buffer-local ()
  "Each Proofread buffer owns an independent delayed update."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((first (generate-new-buffer " *proofread-popup-first*"))
            (second (generate-new-buffer " *proofread-popup-second*")))
	(unwind-protect
            (let* ((first-window (selected-window))
                   (second-window
                    (split-window first-window nil 'below)))
              (set-window-buffer first-window first)
              (set-window-buffer second-window second)
              (dolist (buffer (list first second))
		(with-current-buffer buffer
                  (insert "helo")
                  (proofread-mode 1)))
              (let ((proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (select-window first-window)
                  (with-current-buffer first
                    (proofread-popup--update))
                  (select-window second-window)
                  (with-current-buffer second
                    (proofread-popup--update))
                  (let* ((calls
                          (proofread-popup-test--popup-idle-timer-calls
                           proofread-popup-test--idle-timer-calls))
			 (first-call (car calls))
			 (second-call (cadr calls))
			 (first-timer (plist-get first-call :timer))
			 (second-timer (plist-get second-call :timer)))
                    (should (= (length calls) 2))
                    (should-not (eq first-timer second-timer))
                    (should
                     (eq (with-current-buffer first
                           proofread-popup--idle-timer)
			 first-timer))
                    (should
                     (eq (with-current-buffer second
                           proofread-popup--idle-timer)
			 second-timer))
                    (with-current-buffer first
                      (proofread-popup--cancel-pending-update))
                    (should
                     (eq (with-current-buffer second
                           proofread-popup--idle-timer)
			 second-timer))
                    (proofread-popup-test--fire-idle-timer first-call)
                    (should
                     (eq (with-current-buffer second
                           proofread-popup--idle-timer)
			 second-timer))
                    (proofread-popup-test--fire-idle-timer second-call)
                    (should-not
                     (with-current-buffer second
                       proofread-popup--idle-timer))))))
          (dolist (buffer (list first second))
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))))))

(ert-deftest proofread-popup-test-owner-registry-tracks-active-state ()
  "The registry contains exactly pending or visible popup owners."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(goto-char 2)
	(proofread-mode 1)
	(let ((source (current-buffer))
              (window (selected-window))
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let ((call
                   (car
                    (proofread-popup-test--popup-idle-timer-calls
                     proofread-popup-test--idle-timer-calls))))
              (should proofread-popup--idle-timer)
              (should proofread-popup--update-generation)
              (should-not proofread-popup--visible-p)
              (should-not proofread-popup--render-signature)
              (should (equal proofread-popup--owners (list source)))
              (should (eq proofread-popup--owner-window window))
              (should (eq proofread-popup--owner-frame
                          (window-frame window)))
              (proofread-popup-test--fire-idle-timer call)
              (should-not proofread-popup--idle-timer)
              (should-not proofread-popup--update-generation)
              (should-not proofread-popup--owners)
              (should-not proofread-popup--owner-window)
              (should-not proofread-popup--owner-frame)))
          (proofread-popup-test--install-diagnostics
           (list (proofread-popup-test--diagnostic 1 5 "helo")))
          (let ((proofread-popup-delay 0))
            (proofread-popup--update))
          (let ((popup-buffer-name proofread-popup--buffer-name))
            (should proofread-popup--visible-p)
            (should (equal proofread-popup--owners (list source)))
            (setq proofread-popup--render-signature nil)
            (proofread-popup--hide)
            (should (equal proofread-popup-test--hides
                           (list popup-buffer-name)))
            (should-not proofread-popup--visible-p)
            (should-not proofread-popup--owners)
            (should-not proofread-popup--owner-window)
            (should-not proofread-popup--owner-frame)))))))

(ert-deftest proofread-popup-test-pending-update-survives-typing ()
  "Pending-only updates remain coalesced across interactive commands."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer))
                   (map (make-sparse-keymap)))
              (define-key map "x" #'proofread-popup-test--noop-command)
              (let ((overriding-local-map map))
		(execute-kbd-macro "xx"))
              (let ((calls
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
		(should (= (length calls) 1)))
              (should (eq proofread-popup--idle-timer timer))
              (should-not proofread-popup-test--canceled-timers)
              (should (memq (current-buffer) proofread-popup--owners)))))))))

;;;; Rendering

(ert-deftest
    proofread-popup-test-update-captures-render-inputs-once ()
  "Scheduling captures ownership; the callback captures render inputs once."
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
               (render-data-function
		(symbol-function
                 'proofread-popup--diagnostic-render-data))
               (available-function
		(symbol-function 'proofread-popup--available-p))
               (proofread-popup-delay 0.5)
               (selection-calls 0)
               (diagnostic-calls 0)
               (anchor-calls 0)
               (snapshot-calls 0)
               (render-data-calls 0)
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
                    ((symbol-function
                      'proofread-popup--diagnostic-render-data)
                     (lambda (value)
                       (setq render-data-calls
                             (1+ render-data-calls))
                       (funcall render-data-function value)))
                    ((symbol-function 'proofread-popup--available-p)
                     (lambda ()
                       (setq available-calls (1+ available-calls))
                       (funcall available-function))))
            (proofread-popup-test--with-idle-timer-recorder
              (proofread-popup--update)
              (should-not proofread-popup-test--shows)
              (should (= selection-calls 1))
              (dolist (calls
                       (list diagnostic-calls anchor-calls snapshot-calls
                             render-data-calls available-calls))
		(should (zerop calls)))
              (let ((calls
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
		(should (= (length calls) 1))
		(proofread-popup-test--fire-idle-timer (car calls)))))
          (should (= (length proofread-popup-test--shows) 1))
          (should (= selection-calls 2))
          (should (= diagnostic-calls 1))
          (should (= anchor-calls 1))
          (should (= snapshot-calls 1))
          (should (= render-data-calls 1))
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
	(let* ((raw-message
		(propertize "Possible misspelling"
                            'face 'error
                            'font-lock-face 'warning))
               (diagnostic
		(proofread-popup-test--diagnostic
                 4 8 "helo" '( "hello") raw-message)))
          (proofread-popup-test--install-diagnostics (list diagnostic))
          (goto-char 5)
          (proofread-popup--update)
          (should (= (length proofread-popup-test--shows) 1))
          (let* ((call (car proofread-popup-test--shows))
                 (args (cdr call))
                 (string (plist-get args :string))
                 (signature-message
                  (plist-get proofread-popup--render-signature
                             :message)))
            (should (string-prefix-p proofread-popup--buffer-prefix
                                     (car call)))
            (should (equal (substring-no-properties string)
                           "test: Possible misspelling"))
            (should
             (eq (get-text-property 0 'face string)
                 'proofread-popup-source-face))
            (should
             (eq (get-text-property 4 'face string)
                 'proofread-popup-source-face))
            (should-not (get-text-property 5 'face string))
            (should (eq (get-text-property 6 'face string)
			'proofread-popup-face))
            (should-not (get-text-property 6 'font-lock-face string))
            (should (eq (get-text-property 0 'face raw-message)
			'error))
            (should
             (eq (get-text-property 0 'font-lock-face raw-message)
                 'warning))
            (should
             (eq (get-text-property 0 'face signature-message)
                 'proofread-popup-source-face))
            (should
             (eq (get-text-property 4 'face signature-message)
                 'proofread-popup-source-face))
            (should-not
             (get-text-property 5 'face signature-message))
            (should
             (eq (get-text-property 6 'face signature-message)
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
    proofread-popup-test-equal-aggregate-does-not-refresh ()
  "Equivalent freshly allocated aggregates render only once."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((first
               (proofread-popup-test--diagnostic-with-checker
		(proofread-popup-test--diagnostic
                 1 5 "helo" '( "hello") "First message" "gpt-5.4")
		'first))
              (second
               (proofread-popup-test--diagnostic-with-checker
		(proofread-popup-test--diagnostic
                 1 5 "helo" '( "hello") "Second message"
                 'languagetool)
		'second)))
          (proofread-popup-test--install-diagnostics
           (list first second))
          (goto-char 2)
          (let ((first-value (proofread-diagnostic-at-point))
		(second-value (proofread-diagnostic-at-point)))
            (should-not (eq first-value second-value))
            (should
             (equal (proofread-diagnostic-range first-value)
                    (proofread-diagnostic-range second-value)))
            (should
             (equal (proofread-diagnostic-message first-value)
                    (proofread-diagnostic-message second-value)))
            (should
             (equal (proofread-diagnostic-text first-value)
                    (proofread-diagnostic-text second-value))))
          (proofread-popup--update)
          (proofread-popup--update)
          (should (= (length proofread-popup-test--shows) 1)))))))

(ert-deftest
    proofread-popup-test-rendered-message-change-refreshes ()
  "Changing rendered diagnostic content redraws the child frame."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((diagnostic
               (proofread-popup-test--diagnostic
		1 5 "helo" nil "First message")))
          (proofread-popup-test--install-diagnostics (list diagnostic))
          (goto-char 2)
          (proofread-popup--update)
          (setf (plist-get diagnostic :message) "Changed message")
          (proofread-popup--update)
          (should (= (length proofread-popup-test--shows) 2))
          (should
           (equal
            (substring-no-properties
             (plist-get (cdar proofread-popup-test--shows) :string))
            "test: Changed message")))))))

(ert-deftest proofread-popup-test-source-change-refreshes ()
  "Changing only a diagnostic source redraws the child frame."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((diagnostic
               (proofread-popup-test--diagnostic
		1 5 "helo" nil "First message" 'llm)))
          (setf (plist-get diagnostic :source-label) "gpt-5.4")
          (proofread-popup-test--install-diagnostics (list diagnostic))
          (goto-char 2)
          (proofread-popup--update)
          (setf (plist-get diagnostic :source-label) "languagetool")
          (proofread-popup--update)
          (should (= (length proofread-popup-test--shows) 2))
          (should
           (equal
            (substring-no-properties
             (plist-get (cdar proofread-popup-test--shows) :string))
            "languagetool: First message")))))))

(ert-deftest proofread-popup-test-anchor-change-refreshes ()
  "Changing the public diagnostic range redraws at its new anchor."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "aa helo zz")
	(proofread-mode 1)
	(let* ((diagnostic
		(proofread-popup-test--diagnostic 4 8 "helo"))
               (overlay
		(car
                 (proofread-popup-test--install-diagnostics
                  (list diagnostic)))))
          (goto-char 6)
          (proofread-popup--update)
          (move-overlay overlay 5 9)
          (proofread-popup--update)
          (should (= (length proofread-popup-test--shows) 2))
          (should
           (= (plist-get (cdar proofread-popup-test--shows) :position)
              5)))))))

(ert-deftest proofread-popup-test-selected-window-change-refreshes ()
  "Changing the selected display window redraws the child frame."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let* ((diagnostic
		(proofread-popup-test--diagnostic 1 5 "helo"))
               (first-window (selected-window))
               (second-window (split-window first-window nil 'below))
               (snapshot '( :max-width 80)))
          (proofread-popup-test--install-diagnostics (list diagnostic))
          (goto-char 2)
          (cl-letf
              (((symbol-function 'proofread-popup--render-snapshot)
		(lambda (_window) snapshot)))
            (proofread-popup--update)
            (set-window-point second-window 2)
            (select-window second-window)
            (proofread-popup--update))
          (should (= (length proofread-popup-test--shows) 2))
          (should (eq proofread-popup--window second-window)))))))

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
  "With zero delay, the child frame hides when point leaves diagnostics."
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
          (should-not proofread-popup--render-signature))))))

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
            (should proofread-popup--render-signature)
            (should (= proofread-popup--position 1))
            (should (eq proofread-popup--window (selected-window)))
            (should proofread-popup--render-state)
            (proofread-popup--hide)
            (should (equal proofread-popup-test--hides
                           (list popup-buffer-name)))
            (should (equal proofread-popup--buffer-name
                           popup-buffer-name))
            (should-not proofread-popup--render-signature)
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
            (should-not proofread-popup--render-signature)
            (should-not proofread-popup--position)
            (should-not proofread-popup--window)
            (should-not proofread-popup--render-state)
            (proofread-popup--delete)
            (should (= (length proofread-popup-test--deletes) 1))))))))

(ert-deftest proofread-popup-test-command-switch-hides-before-command ()
  "A command-style buffer switch hides its source popup immediately."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((source (generate-new-buffer " *proofread-popup-source*"))
            (other (generate-new-buffer " *proofread-popup-other*")))
	(unwind-protect
            (progn
              (switch-to-buffer source)
              (insert "helo")
              (proofread-mode 1)
              (proofread-popup-test--install-diagnostics
               (list (proofread-popup-test--diagnostic 1 5 "helo")))
              (goto-char 2)
              (proofread-popup--update)
              (let ((popup-buffer-name proofread-popup--buffer-name)
                    (proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (proofread-popup--update)
                  (let* ((call
                          (car
                           (proofread-popup-test--popup-idle-timer-calls
                            proofread-popup-test--idle-timer-calls)))
			 (timer (plist-get call :timer))
			 (map (make-sparse-keymap)))
                    (setq proofread-popup-test--events nil)
                    (define-key
                     map "x"
                     #'proofread-popup-test--switch-buffer-command)
                    (let ((proofread-popup-test--switch-target other)
                          (overriding-local-map map))
                      (execute-kbd-macro "x"))
                    (should (eq (current-buffer) other))
                    (should
                     (equal (nreverse proofread-popup-test--events)
                            (list (list 'hide popup-buffer-name)
                                  '(command))))
                    (should (equal proofread-popup-test--hides
                                   (list popup-buffer-name)))
                    (should-not proofread-popup-test--deletes)
                    (should (memq timer
                                  proofread-popup-test--canceled-timers))
                    (with-current-buffer source
                      (should (equal proofread-popup--buffer-name
                                     popup-buffer-name))
                      (should-not proofread-popup--visible-p)
                      (should-not proofread-popup--idle-timer)
                      (should-not proofread-popup--update-generation)
                      (should-not proofread-popup--render-signature)
                      (should-not (memq source proofread-popup--owners)))
                    (proofread-popup-test--fire-idle-timer call)
                    (should (= (length proofread-popup-test--shows) 1))
                    (switch-to-buffer source)
                    (let ((proofread-popup-delay 0))
                      (proofread-popup--update))
                    (should (= (length proofread-popup-test--shows) 2))
                    (should (equal (caar proofread-popup-test--shows)
                                   popup-buffer-name))))))
          (when (buffer-live-p source)
            (kill-buffer source))
          (when (buffer-live-p other)
            (kill-buffer other)))))))

(ert-deftest proofread-popup-test-hide-handler-remains-fallback ()
  "Posframe's hide handler invalidates ownership as a fallback."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((source (generate-new-buffer " *proofread-popup-source*"))
            (other (generate-new-buffer " *proofread-popup-other*")))
	(unwind-protect
            (progn
              (switch-to-buffer source)
              (insert "helo")
              (proofread-mode 1)
              (proofread-popup-test--install-diagnostics
               (list (proofread-popup-test--diagnostic 1 5 "helo")))
              (goto-char 2)
              (proofread-popup--update)
              (let* ((args (cdar proofread-popup-test--shows))
                     (hide-handler (plist-get args :hidehandler))
                     (popup-buffer-name proofread-popup--buffer-name)
                     (proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (proofread-popup--update)
                  (let* ((call
                          (car
                           (proofread-popup-test--popup-idle-timer-calls
                            proofread-popup-test--idle-timer-calls)))
			 (timer (plist-get call :timer))
			 (info
                          (list :posframe-parent-buffer
				(cons nil source))))
                    (switch-to-buffer other)
                    (should (funcall hide-handler info))
                    (should (funcall hide-handler info))
                    (should (memq timer
                                  proofread-popup-test--canceled-timers))
                    (should (= (length
				proofread-popup-test--canceled-timers)
                               1))
                    (should-not proofread-popup-test--hides)
                    (should-not proofread-popup-test--deletes)
                    (with-current-buffer source
                      (should (equal proofread-popup--buffer-name
                                     popup-buffer-name))
                      (should-not proofread-popup--visible-p)
                      (should-not proofread-popup--render-signature)
                      (should-not proofread-popup--idle-timer)
                      (should-not proofread-popup--update-generation)
                      (should-not (memq source proofread-popup--owners)))
                    (proofread-popup-test--fire-idle-timer call)
                    (should (= (length proofread-popup-test--shows) 1))))))
          (when (buffer-live-p source)
            (kill-buffer source))
          (when (buffer-live-p other)
            (kill-buffer other)))))))

(ert-deftest proofread-popup-test-set-window-buffer-hides-owner ()
  "Changing an owner window's buffer hides and invalidates its popup."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((source (generate-new-buffer " *proofread-popup-source*"))
            (other (generate-new-buffer " *proofread-popup-other*")))
	(unwind-protect
            (progn
              (switch-to-buffer source)
              (insert "helo")
              (proofread-mode 1)
              (proofread-popup-test--install-diagnostics
               (list (proofread-popup-test--diagnostic 1 5 "helo")))
              (goto-char 2)
              (proofread-popup--update)
              (let ((window (selected-window))
                    (frame (selected-frame))
                    (popup-buffer-name proofread-popup--buffer-name)
                    (proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (proofread-popup--update)
                  (let* ((call
                          (car
                           (proofread-popup-test--popup-idle-timer-calls
                            proofread-popup-test--idle-timer-calls)))
			 (timer (plist-get call :timer)))
                    (set-window-buffer window other)
                    (proofread-popup--validate-owners frame)
                    (proofread-popup--validate-owners frame)
                    (with-current-buffer source
                      (proofread-popup--pre-command-cleanup)
                      (should (equal proofread-popup--buffer-name
                                     popup-buffer-name))
                      (should-not proofread-popup--visible-p)
                      (should-not proofread-popup--idle-timer)
                      (should-not proofread-popup--update-generation)
                      (should-not (memq source proofread-popup--owners)))
                    (should (equal proofread-popup-test--hides
                                   (list popup-buffer-name)))
                    (should-not proofread-popup-test--deletes)
                    (should (equal proofread-popup-test--canceled-timers
                                   (list timer)))
                    (proofread-popup-test--fire-idle-timer call)
                    (should (= (length proofread-popup-test--shows) 1))))))
          (when (buffer-live-p source)
            (kill-buffer source))
          (when (buffer-live-p other)
            (kill-buffer other)))))))

(ert-deftest proofread-popup-test-selection-change-hides-owner ()
  "Selecting another window hides the popup even for the same buffer."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(let* ((first-window (selected-window))
               (second-window (split-window first-window nil 'below)))
          (proofread-popup--update)
          (let ((popup-buffer-name proofread-popup--buffer-name)
		(proofread-popup-delay 0.5))
            (proofread-popup-test--with-idle-timer-recorder
              (proofread-popup--update)
              (let* ((call
                      (car
                       (proofread-popup-test--popup-idle-timer-calls
			proofread-popup-test--idle-timer-calls)))
                     (timer (plist-get call :timer)))
		(select-window second-window)
		(proofread-popup--validate-owners (selected-frame))
		(proofread-popup--validate-owners (selected-frame))
		(should (equal proofread-popup-test--hides
                               (list popup-buffer-name)))
		(should-not proofread-popup-test--deletes)
		(should (equal proofread-popup-test--canceled-timers
                               (list timer)))
		(should-not proofread-popup--visible-p)
		(should-not proofread-popup--idle-timer)
		(should-not proofread-popup--owners)
		(proofread-popup-test--fire-idle-timer call)
		(should (= (length proofread-popup-test--shows) 1))
		(let ((proofread-popup-delay 0))
                  (proofread-popup--update))
		(should (= (length proofread-popup-test--shows) 2))
		(should (eq proofread-popup--owner-window
                            second-window))))))))))

(ert-deftest proofread-popup-test-dead-owner-window-hides-popup ()
  "Deleting the source window hides its popup without deleting Posframe."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((source (generate-new-buffer " *proofread-popup-source*"))
            (other (generate-new-buffer " *proofread-popup-other*")))
	(unwind-protect
            (let* ((source-window (selected-window))
                   (other-window
                    (split-window source-window nil 'below)))
              (set-window-buffer source-window source)
              (set-window-buffer other-window other)
              (select-window source-window)
              (with-current-buffer source
		(insert "helo")
		(proofread-mode 1)
		(proofread-popup-test--install-diagnostics
                 (list (proofread-popup-test--diagnostic 1 5 "helo")))
		(goto-char 2)
		(proofread-popup--update)
		(let ((popup-buffer-name proofread-popup--buffer-name)
                      (proofread-popup-delay 0.5))
                  (proofread-popup-test--with-idle-timer-recorder
                    (proofread-popup--update)
                    (let* ((call
                            (car
                             (proofread-popup-test--popup-idle-timer-calls
                              proofread-popup-test--idle-timer-calls)))
                           (timer (plist-get call :timer)))
                      (select-window other-window)
                      (delete-window source-window)
                      (proofread-popup--validate-owners (selected-frame))
                      (should-not (window-live-p source-window))
                      (should (equal proofread-popup-test--hides
                                     (list popup-buffer-name)))
                      (should-not proofread-popup-test--deletes)
                      (should (equal
                               proofread-popup-test--canceled-timers
                               (list timer)))
                      (should-not proofread-popup--owners)
                      (proofread-popup-test--fire-idle-timer call)
                      (should (= (length
                                  proofread-popup-test--shows)
				 1)))))))
          (when (buffer-live-p source)
            (kill-buffer source))
          (when (buffer-live-p other)
            (kill-buffer other)))))))

(ert-deftest proofread-popup-test-parent-frame-selection-hides-owner ()
  "Losing the selected parent frame hides and invalidates its popup."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(proofread-popup--update)
	(let ((popup-buffer-name proofread-popup--buffer-name)
              (other-frame (make-symbol "proofread-popup-other-frame"))
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer)))
              (cl-letf (((symbol-function 'selected-frame)
			 (lambda () other-frame)))
		(proofread-popup--validate-owners other-frame))
              (should (equal proofread-popup-test--hides
                             (list popup-buffer-name)))
              (should-not proofread-popup-test--deletes)
              (should (equal proofread-popup-test--canceled-timers
                             (list timer)))
              (should-not proofread-popup--owners)
              (proofread-popup-test--fire-idle-timer call)
              (should (= (length proofread-popup-test--shows) 1)))))))))

(ert-deftest proofread-popup-test-unrelated-window-preserves-owner ()
  "An unrelated window or frame change preserves a valid popup owner."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((source (generate-new-buffer " *proofread-popup-source*"))
            (other (generate-new-buffer " *proofread-popup-other*"))
            (replacement
             (generate-new-buffer " *proofread-popup-replacement*")))
	(unwind-protect
            (let* ((source-window (selected-window))
                   (other-window
                    (split-window source-window nil 'below)))
              (set-window-buffer source-window source)
              (set-window-buffer other-window other)
              (select-window source-window)
              (with-current-buffer source
		(insert "helo")
		(proofread-mode 1)
		(proofread-popup-test--install-diagnostics
                 (list (proofread-popup-test--diagnostic 1 5 "helo")))
		(goto-char 2)
		(proofread-popup--update)
		(let ((proofread-popup-delay 0.5))
                  (proofread-popup-test--with-idle-timer-recorder
                    (proofread-popup--update)
                    (let* ((call
                            (car
                             (proofread-popup-test--popup-idle-timer-calls
                              proofread-popup-test--idle-timer-calls)))
                           (timer (plist-get call :timer)))
                      (set-window-buffer other-window replacement)
                      (proofread-popup--validate-owners (selected-frame))
                      (proofread-popup--delete-frame-owner
                       (make-symbol "proofread-popup-unrelated-frame"))
                      (should-not proofread-popup-test--hides)
                      (should-not proofread-popup-test--deletes)
                      (should-not proofread-popup-test--canceled-timers)
                      (should (eq proofread-popup--idle-timer timer))
                      (should (equal proofread-popup--owners
                                     (list source)))
                      (proofread-popup-test--fire-idle-timer call)
                      (should-not proofread-popup--idle-timer)
                      (should proofread-popup--visible-p)
                      (should (equal proofread-popup--owners
                                     (list source))))))))
          (dolist (buffer (list source other replacement))
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))))))

(ert-deftest proofread-popup-test-parent-frame-delete-is-final ()
  "Deleting the parent frame deletes rather than hides its popup."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(proofread-popup--update)
	(let ((frame proofread-popup--owner-frame)
              (popup-buffer-name proofread-popup--buffer-name)
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer)))
              (proofread-popup--delete-frame-owner frame)
              (proofread-popup--delete-frame-owner frame)
              (should-not proofread-popup-test--hides)
              (should (equal proofread-popup-test--deletes
                             (list popup-buffer-name)))
              (should (equal proofread-popup-test--canceled-timers
                             (list timer)))
              (should-not proofread-popup--buffer-name)
              (should-not proofread-popup--visible-p)
              (should-not proofread-popup--idle-timer)
              (should-not proofread-popup--update-generation)
              (should-not proofread-popup--owners)
              (proofread-popup-test--fire-idle-timer call)
              (should (= (length proofread-popup-test--shows) 1)))))))))

(ert-deftest proofread-popup-test-delete-is-reentrant-safe ()
  "Recursive final cleanup deletes a Posframe only once."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(proofread-popup--update)
	(let ((deletes 0))
          (cl-letf (((symbol-function 'posframe-delete)
                     (lambda (_buffer-or-name)
                       (setq deletes (1+ deletes))
                       (proofread-popup--delete))))
            (proofread-popup--delete))
          (should (= deletes 1))
          (should-not proofread-popup--buffer-name)
          (should-not proofread-popup--owners))))))

(ert-deftest proofread-popup-test-cleanup-errors-remain-isolated ()
  "Timer and warning failures cannot interrupt ordinary popup hiding."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(proofread-popup-test--install-diagnostics
         (list (proofread-popup-test--diagnostic 1 5 "helo")))
	(goto-char 2)
	(proofread-popup--update)
	(let ((popup-buffer-name proofread-popup--buffer-name)
              (proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (cl-letf
		(((symbol-function 'cancel-timer)
                  (lambda (_timer)
                    (error "timer cancellation failed")))
		 ((symbol-function
                   'proofread-report-warning-without-window)
                  (lambda (&rest _args)
                    (error "warning reporter failed"))))
              (should-not
               (condition-case err
                   (progn
                     (proofread-popup--hide)
                     nil)
		 (error err))))
            (should (equal proofread-popup-test--hides
                           (list popup-buffer-name)))
            (should-not proofread-popup--visible-p)
            (should-not proofread-popup--idle-timer)
            (should-not proofread-popup--update-generation)
            (should-not proofread-popup--owners)))))))

(ert-deftest proofread-popup-test-dead-owner-buffer-is-pruned ()
  "Ownership validation safely removes a dead source buffer."
  (proofread-popup-test--with-posframe-recorder
    (let ((buffer (generate-new-buffer " *proofread-popup-dead*")))
      (setq proofread-popup--owners (list buffer))
      (kill-buffer buffer)
      (proofread-popup--validate-owners (selected-frame))
      (should-not proofread-popup--owners)
      (should-not proofread-popup-test--hides)
      (should-not proofread-popup-test--deletes))))

;;;; Availability and lifecycle

(ert-deftest proofread-popup-test-mode-disable-cancels-idle-timer ()
  "Disabling popup mode cancels its pending idle timer."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer)))
              (proofread-popup-mode -1)
              (should (memq timer
                            proofread-popup-test--canceled-timers))
              (should-not proofread-popup--idle-timer))))))))

(ert-deftest proofread-popup-test-major-mode-change-cancels-idle-timer ()
  "Changing major mode cancels the pending popup idle timer."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (with-temp-buffer
	(switch-to-buffer (current-buffer))
	(insert "helo")
	(proofread-mode 1)
	(let ((proofread-popup-delay 0.5))
          (proofread-popup-test--with-idle-timer-recorder
            (proofread-popup--update)
            (let* ((call
                    (car
                     (proofread-popup-test--popup-idle-timer-calls
                      proofread-popup-test--idle-timer-calls)))
                   (timer (plist-get call :timer)))
              (text-mode)
              (should (memq timer
                            proofread-popup-test--canceled-timers))
              (should-not (bound-and-true-p
                           proofread-popup--idle-timer)))))))))

(ert-deftest proofread-popup-test-kill-buffer-cancels-idle-timer ()
  "Killing the source buffer cancels the pending popup idle timer."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((buffer
             (generate-new-buffer " *proofread-popup-timer-kill*")))
	(unwind-protect
            (progn
              (switch-to-buffer buffer)
              (insert "helo")
              (proofread-mode 1)
              (let ((proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (proofread-popup--update)
                  (let* ((call
                          (car
                           (proofread-popup-test--popup-idle-timer-calls
                            proofread-popup-test--idle-timer-calls)))
			 (timer (plist-get call :timer)))
                    (kill-buffer buffer)
                    (should (memq
                             timer
                             proofread-popup-test--canceled-timers))
                    (should-not
                     (proofread-popup-test--fire-idle-timer call))
                    (should-not proofread-popup-test--shows)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest proofread-popup-test-unload-cancels-idle-timer ()
  "Unloading the package cancels pending popup idle timers."
  (proofread-popup-test--with-posframe-recorder
    (save-window-excursion
      (let ((buffer
             (generate-new-buffer " *proofread-popup-timer-unload*")))
	(unwind-protect
            (progn
              (switch-to-buffer buffer)
              (insert "helo")
              (proofread-mode 1)
              (let ((proofread-popup-delay 0.5))
		(proofread-popup-test--with-idle-timer-recorder
                  (proofread-popup--update)
                  (let* ((call
                          (car
                           (proofread-popup-test--popup-idle-timer-calls
                            proofread-popup-test--idle-timer-calls)))
			 (timer (plist-get call :timer)))
                    (unload-feature 'proofread-popup t)
                    (should (memq
                             timer
                             proofread-popup-test--canceled-timers))
                    (should-not
                     (with-current-buffer buffer
                       (bound-and-true-p proofread-popup-mode)))))))
          (require 'proofread-popup)
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

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
          (should-not proofread-popup--render-signature)
          (should-not proofread-popup--position)
          (should-not proofread-popup--window)
          (should-not proofread-popup--render-state))))))

(ert-deftest proofread-popup-test-manual-opt-out-persists ()
  "A manual popup opt-out survives core mode disable and re-enable."
  (with-temp-buffer
    (setq-local proofread-popup-delay 0)
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
          (should-not proofread-popup--render-signature))))))

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
  "With zero delay, correction immediately hides its diagnostic frame."
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
          (should proofread-popup--render-signature)
          (proofread-correct-at-point)
          (should proofread-popup-test--hides)
          (should-not proofread-popup--render-signature)
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
              (let* ((popup-buffer
                      (get-buffer-create proofread-popup--buffer-name))
                     (delete-function
                      (symbol-function 'posframe-delete)))
		(bury-buffer popup-buffer)
		(cl-letf (((symbol-function 'posframe-delete)
                           (lambda (buffer-or-name)
                             (funcall delete-function buffer-or-name)
                             (when-let* ((popup-buffer
                                          (get-buffer buffer-or-name)))
                               (kill-buffer popup-buffer)))))
                  (unload-feature 'proofread-popup t))
		(should-not (buffer-live-p popup-buffer)))
              (should proofread-popup-test--deletes)
              (should-not
               (memq #'proofread-popup--sync-with-proofread-mode
                     proofread-mode-hook))
              (dolist (entry
                       '((window-buffer-change-functions
                          proofread-popup--validate-owners)
                         (window-selection-change-functions
                          proofread-popup--validate-owners)
                         (delete-frame-functions
                          proofread-popup--delete-frame-owner)))
		(should-not
                 (memq (cadr entry) (default-value (car entry)))))
              (with-current-buffer buffer
		(should-not (bound-and-true-p proofread-popup-mode))
		(should-not
                 (memq 'proofread-popup--pre-command-cleanup
                       pre-command-hook))))
          (progn
            (require 'proofread-popup)
            (dolist (entry
                     '((window-buffer-change-functions
			proofread-popup--validate-owners)
                       (window-selection-change-functions
			proofread-popup--validate-owners)
                       (delete-frame-functions
			proofread-popup--delete-frame-owner)))
              (should
               (= (cl-count (cadr entry)
                            (default-value (car entry)))
                  1))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(provide 'proofread-popup-tests)
;;; proofread-popup-tests.el ends here
