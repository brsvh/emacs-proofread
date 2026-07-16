;;; proofread-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for proofread.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)

;;;; Test state

(defconst proofread-test--backend 'proofread-test-backend
  "Backend symbol used by core Proofread tests.")

(defconst proofread-test--profile 'proofread-test-profile
  "Profile symbol used by core Proofread tests.")

(defconst proofread-test--checker 'proofread-test-checker
  "Checker symbol used by core Proofread tests.")

(defconst proofread-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the core Proofread test fixtures.")

(defvar proofread-test--backend-identity-token
  'proofread-test-identity
  "Stable identity token used by the test backend.")

(defvar proofread-test--backend-check-function nil
  "Optional implementation for the test backend check function.")

(defvar proofread-test--profile-language nil
  "Language used by the minimal test profile fixture.")

;;;; Test helpers

(defun proofread-test--tree-member-p (needle tree)
  "Return non-nil if NEEDLE appears anywhere in TREE."
  (cond
   ((eq needle tree) t)
   ((consp tree)
    (or (proofread-test--tree-member-p needle (car tree))
        (proofread-test--tree-member-p needle (cdr tree))))
   (t nil)))

(defun proofread-test--assert-secret-not-printed (secret value)
  "Assert that printing VALUE does not expose SECRET."
  (should-not
   (string-match-p (regexp-quote secret)
                   (prin1-to-string value))))

(defun proofread-test--diagnostic ()
  "Return a sample proofread diagnostic."
  (proofread--make-diagnostic
   :beg 1
   :end 6
   :text "helo"
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions '( "hello")
   :source 'test))

(defun proofread-test--diagnostic-for-range (beg end text)
  "Return a sample diagnostic for BEG, END, and TEXT."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions '( "hello")
   :source 'test))

(defun proofread-test--diagnostic-with-kind (beg end text kind)
  "Return a sample diagnostic for BEG, END, TEXT, and KIND."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind kind
   :message "Possible issue"
   :suggestions '( "fixed")
   :source 'test))

(defun proofread-test--diagnostic-with-suggestions
    (beg end text suggestions)
  "Return a diagnostic for BEG, END, TEXT, and SUGGESTIONS."
  (proofread--make-diagnostic
   :beg beg
   :end end
   :text text
   :kind 'spelling
   :message "Possible misspelling"
   :suggestions suggestions
   :source 'test))

(defun proofread-test--install-diagnostics (diagnostics)
  "Install DIAGNOSTICS and return their proofread overlays."
  (setq proofread--diagnostics diagnostics)
  (mapcar #'proofread--create-overlay diagnostics))

(defconst proofread-test--diagnostic-provenance-keys
  '( :language :display-language :profile :checker-name
     :checker-ordinal :checker-owner :source-label)
  "Diagnostic provenance keys added by the Proofread core.")

(defun proofread-test--diagnostic-without-provenance
    (diagnostic)
  "Return DIAGNOSTIC without core provenance fields."
  (let ((diagnostic (copy-sequence diagnostic)))
    (dolist (key proofread-test--diagnostic-provenance-keys)
      (cl-remf diagnostic key))
    diagnostic))

(defun proofread-test--diagnostic-with-checker
    (diagnostic checker)
  "Return DIAGNOSTIC annotated as owned by CHECKER."
  (let ((diagnostic (copy-sequence diagnostic)))
    (setq diagnostic (plist-put diagnostic :profile 'multi))
    (setq diagnostic (plist-put diagnostic :checker-name checker))
    (plist-put diagnostic :checker-owner
               (list :profile 'multi :checker-name checker))))

(defun proofread-test--diagnostics-without-provenance
    (diagnostics)
  "Return DIAGNOSTICS without core provenance fields."
  (mapcar #'proofread-test--diagnostic-without-provenance
          diagnostics))

(defun proofread-test--chunk-texts (chunks)
  "Return the text payloads from CHUNKS."
  (mapcar (lambda (chunk)
            (plist-get chunk :text))
          chunks))

(defun proofread-test--combined-chunk-text (chunks)
  "Return the text payloads from CHUNKS joined by newlines."
  (mapconcat (lambda (chunk)
               (plist-get chunk :text))
             chunks
             "\n"))

(defun proofread-test--span-texts (spans)
  "Return buffer text selected by SPANS."
  (mapcar (lambda (span)
            (buffer-substring-no-properties (car span) (cdr span)))
          spans))

(defun proofread-test--chunk-with-text (chunks text)
  "Return the first chunk from CHUNKS whose text is TEXT."
  (cl-find-if (lambda (chunk)
                (equal (plist-get chunk :text) text))
              chunks))

(defun proofread-test--request-ready-chunks-for-ranges
    (ranges &optional language)
  "Return request-ready chunks from islands selected by RANGES.
LANGUAGE is the language hint snapshotted for the chunks."
  (proofread--request-ready-chunks-for-islands
   (proofread--target-islands-for-ranges ranges) language))

(defun proofread-test--flush-request-log-refresh (source)
  "Refresh SOURCE's pending request listings immediately."
  (with-current-buffer source
    (proofread--cancel-request-log-refresh-timer)
    (proofread--refresh-request-log-list-buffers)))

(defun proofread-test--wait-for (predicate &optional timeout)
  "Wait for PREDICATE to return non-nil or TIMEOUT seconds to pass."
  (let ((deadline (+ (float-time) (or timeout 1.0)))
        result)
    (while (and (not (setq result (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(defun proofread-test--make-backend-recorder ()
  "Return a plist containing a backend recorder and accessors."
  (let (requests callbacks)
    (list :function
          (lambda (request callback &optional _backend)
            (push request requests)
            (push callback callbacks)
            'proofread-test-handle)
          :requests
          (lambda ()
            (reverse requests))
          :callbacks
          (lambda ()
            (reverse callbacks)))))

(defun proofread-test--ordered-profiles (&optional checker-order)
  "Return a profile fixture with CHECKER-ORDER.
CHECKER-ORDER defaults to first followed by second."
  (list
   (list
    'multi
    :language "en-US"
    :checkers
    (mapcar
     (lambda (name)
       (list :name name :backend proofread-test--backend))
     (or checker-order '( first second))))))

(defun proofread-test--ordered-checker-diagnostic (request)
  "Return an order-sensitive diagnostic for REQUEST's checker."
  (pcase (plist-get request :checker-name)
    ('first
     (proofread--make-diagnostic
      :beg 4
      :end 8
      :text "helo"
      :kind 'grammar
      :message "First message"
      :suggestions '( "first-fix" "shared")
      :source 'first))
    ('second
     (proofread--make-diagnostic
      :beg 4
      :end 8
      :text "helo"
      :kind 'style
      :message "Second message"
      :suggestions '( "second-fix" "shared")
      :source 'second))
    (_
     (error "Unexpected checker: %S"
            (plist-get request :checker-name)))))

(defun proofread-test--complete-recorded-checkers
    (recorder checker-order)
  "Complete RECORDER requests in CHECKER-ORDER."
  (let ((pairs
         (cl-mapcar
          #'cons
          (funcall (plist-get recorder :requests))
          (funcall (plist-get recorder :callbacks))))
        statuses)
    (dolist (checker checker-order)
      (let* ((pair
              (cl-find
               checker pairs
               :key (lambda (entry)
                      (plist-get (car entry) :checker-name))))
             (request (car pair))
             (callback (cdr pair)))
        (unless pair
          (error "No recorded request for checker: %S" checker))
        (push
         (funcall
          callback
          (proofread--backend-success-result
           request
           (list
            (proofread-test--ordered-checker-diagnostic request))))
         statuses)))
    (nreverse statuses)))

(defun proofread-test--complete-recorded-requests (recorder)
  "Complete every request in RECORDER with one diagnostic."
  (cl-mapcar
   (lambda (request callback)
     (funcall
      callback
      (proofread--backend-success-result
       request
       (list
        (proofread--make-diagnostic
         :beg (proofread--position-integer
               (plist-get request :beg))
         :end (proofread--position-integer
               (plist-get request :end))
         :text (plist-get request :text)
         :kind 'spelling
         :message
         (format "%s result" (plist-get request :checker-name))
         :suggestions nil
         :source (plist-get request :checker-name))))))
   (funcall (plist-get recorder :requests))
   (funcall (plist-get recorder :callbacks))))

(defun proofread-test--failure-checker-names (position)
  "Return checker names with a failure at POSITION."
  (pcase position
    ('first '( failed later))
    ('middle '( earlier failed later))
    (_ (error "Unexpected failure position: %S" position))))

(defun proofread-test--scheduled-checker-names ()
  "Return checker names in all current scheduler states."
  (mapcar
   (lambda (request)
     (plist-get request :checker-name))
   (append
    proofread--active-requests
    proofread--claimed-requests
    (mapcar (lambda (entry)
              (plist-get entry :request))
            proofread--request-queue))))

(defun proofread-test--assert-queue-cache-index-consistent ()
  "Assert that request queue links and cache-key indexes agree."
  (let ((queued (make-hash-table :test #'eq))
        (cell proofread--request-queue)
        previous
        (queue-count 0)
        (indexed-count 0))
    (when cell
      (should (hash-table-p proofread--request-queue-index))
      (should (hash-table-p proofread--request-queue-links))
      (should (hash-table-p proofread--cache-woken-queue-entries)))
    (while cell
      (let* ((entry (car cell))
             (link (gethash entry proofread--request-queue-links))
             (key (proofread--request-queue-entry-cache-key entry))
             (bucket (gethash key proofread--request-queue-index)))
        (should-not (gethash entry queued))
        (puthash entry t queued)
        (should link)
        (should (eq (car link) cell))
        (should (eq (cdr link) previous))
        (should (natnump
                 (proofread--request-queue-entry-sequence entry)))
        (should (hash-table-p bucket))
        (should (gethash entry bucket)))
      (setq queue-count (1+ queue-count))
      (setq previous cell)
      (setq cell (cdr cell)))
    (should (eq proofread--request-queue-tail previous))
    (when (hash-table-p proofread--request-queue-links)
      (should (= (hash-table-count proofread--request-queue-links)
                 queue-count))
      (maphash
       (lambda (entry _link)
         (should (gethash entry queued)))
       proofread--request-queue-links))
    (when (hash-table-p proofread--request-queue-index)
      (maphash
       (lambda (key bucket)
         (should (hash-table-p bucket))
         (should (> (hash-table-count bucket) 0))
         (maphash
          (lambda (entry _value)
            (setq indexed-count (1+ indexed-count))
            (should (gethash entry queued))
            (should (equal
                     key
                     (proofread--request-queue-entry-cache-key
                      entry))))
          bucket))
       proofread--request-queue-index)
      (should (= indexed-count queue-count)))
    (when (hash-table-p proofread--cache-woken-queue-entries)
      (maphash
       (lambda (entry _value)
         (should (gethash entry queued)))
       proofread--cache-woken-queue-entries))))

(defun proofread-test--assert-requests-settled (requests)
  "Assert that REQUESTS and current scheduler state are settled."
  (dolist (request requests)
    (let ((state (plist-get request :state)))
      (should (plist-get state :batch))
      (should (plist-get state :batch-settled))))
  (dolist (batch
           (delete-dups
            (mapcar (lambda (request)
                      (plist-get (plist-get request :state) :batch))
                    requests)))
    (should (zerop (plist-get batch :pending))))
  (should-not proofread--active-requests)
  (should-not proofread--claimed-requests)
  (should-not proofread--request-queue)
  (should-not proofread--request-queue-tail)
  (should-not proofread--queue-dispatch-active-p)
  (should-not proofread--queue-dispatch-requested-p)
  (proofread-test--assert-queue-cache-index-consistent)
  (should (zerop (hash-table-count proofread--pending-request-keys))))

(defun proofread-test--assert-one-checker-report (reports)
  "Require one bounded `failed' checker report in REPORTS."
  (should (= (length reports) 1))
  (let ((detail (caar reports))
        (summary (cadar reports)))
    (should (<= (string-width detail) 320))
    (should (string-match-p "multi" detail))
    (should (string-match-p "failed" detail))
    (should (string-match-p "failed" summary))))

(defun proofread-test--assert-one-batch-error-report
    (reports count condition-kind)
  "Require one report for COUNT errors of CONDITION-KIND in REPORTS."
  (should (= (length reports) 1))
  (let ((detail (caar reports))
        (summary (cadar reports)))
    (should
     (string-match-p
      (regexp-quote
       (format "Proofreading backend error (%S) (x%d)"
               condition-kind count))
      detail))
    (should
     (string-match-p
      (format "%d request%s" count (if (= count 1) "" "s"))
      detail))
    (should (string-match-p "failed" summary))))

(defun proofread-test--assert-checker-dispatch-failure-event
    (events phase)
  "Assert EVENTS contain one `failed' checker event for PHASE."
  (let ((failures
         (cl-remove-if-not
          (lambda (event)
            (eq (plist-get event :type)
                'checker-dispatch-failed))
          events)))
    (should (= (length failures) 1))
    (let ((event (car failures)))
      (should (eq (plist-get event :profile) 'multi))
      (should (eq (plist-get event :checker-name) 'failed))
      (should (eq (plist-get event :phase) phase))
      (should (eq (plist-get event :status) 'error))
      event)))

(defun proofread-test--assert-successful-checker-requests
    (requests checker-names)
  "Assert REQUESTS contain two requests for each CHECKER-NAMES member."
  (let ((names
         (mapcar (lambda (request)
                   (plist-get request :checker-name))
                 requests)))
    (should (= (length requests) (* 2 (length checker-names))))
    (dolist (name checker-names)
      (should (= (cl-count name names) 2)))
    (should-not (memq 'failed names))))

(defun proofread-test--assert-dispatch-progress
    (progress request-count)
  "Assert PROGRESS reports REQUEST-COUNT dispatched buffer requests."
  (should
   (equal
    progress
    (list
     (format "proofread: dispatched %d requests from 1 buffer range"
             request-count)))))

(defun proofread-test--assert-request-diagnostics (requests)
  "Assert current diagnostics correspond exactly to REQUESTS."
  (let ((request-names
         (mapcar (lambda (request)
                   (plist-get request :checker-name))
                 requests))
        (diagnostic-names
         (mapcar (lambda (diagnostic)
                   (plist-get diagnostic :checker-name))
                 proofread--diagnostics)))
    (should (= (length request-names) (length diagnostic-names)))
    (dolist (name (delete-dups (copy-sequence request-names)))
      (should (= (cl-count name request-names)
                 (cl-count name diagnostic-names))))
    (should-not (memq 'failed diagnostic-names))
    (should (memq 'later diagnostic-names))))

(defun proofread-test--public-diagnostic-signature (diagnostic)
  "Return DIAGNOSTIC's signature through public accessors only."
  (list (proofread-diagnostic-range diagnostic)
        (proofread-diagnostic-message diagnostic)
        (proofread-diagnostic-text diagnostic)))

(defun proofread-test--aggregate-order-signature (diagnostic)
  "Return order-sensitive presentation fields from DIAGNOSTIC."
  (list
   :members
   (mapcar (lambda (member)
             (plist-get member :checker-name))
           (proofread--diagnostic-members diagnostic))
   :kind (plist-get diagnostic :kind)
   :sources (proofread--diagnostic-source-labels diagnostic)
   :public (proofread-test--public-diagnostic-signature diagnostic)
   :suggestions (proofread--diagnostic-suggestions diagnostic)))

(defun proofread-test--ordered-raw-diagnostic-signatures ()
  "Return semantic signatures for raw diagnostics in navigation order."
  (mapcar
   (lambda (entry)
     (let ((diagnostic (car entry)))
       (list
        (plist-get diagnostic :checker-name)
        (plist-get diagnostic :checker-ordinal)
        (proofread-diagnostic-range diagnostic)
        (proofread-diagnostic-text diagnostic)
        (plist-get diagnostic :kind)
        (proofread-diagnostic-message diagnostic)
        (plist-get diagnostic :suggestions))))
   (proofread--raw-navigation-entries)))

(defun proofread-test--lifecycle-request
    (id beg end &optional handle)
  "Return a minimal lifecycle request named ID from BEG to END.
When HANDLE is non-nil, attach it as the backend handle."
  (list :id id
        :log-id id
        :buffer (current-buffer)
        :generation 1
        :beg beg
        :end end
        :accessible-beg 1
        :accessible-end 100
        :cache-key id
        :handle handle
        :state (list :superseded nil
                     :invalidated nil
                     :cancelled nil
                     :batch nil
                     :batch-settled nil)))

(defun proofread-test--pending-request-table (requests)
  "Return a pending-work table containing REQUESTS."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (request requests)
      (puthash (proofread--request-work-key request)
               (plist-get request :log-id)
               table))
    table))

(defun proofread-test--window-state (buffer window)
  "Return point and window state for BUFFER and WINDOW."
  (list :selected-window (selected-window)
        :window-list (window-list)
        :selected-window-point (window-point (selected-window))
        :selected-window-start (window-start (selected-window))
        :buffer-point (with-current-buffer buffer (point))
        :window-point (window-point window)
        :window-start (window-start window)))

(defun proofread-test--backend-identity ()
  "Return the current identity of the test backend."
  (list :backend proofread-test--backend
        :token proofread-test--backend-identity-token
        :contract-version 1))

(defun proofread-test--profiles (&optional language backend)
  "Return a minimal test profile using LANGUAGE and BACKEND.
When LANGUAGE is nil, the profile has no language hint.  When
BACKEND is nil, use the generic test backend."
  `((,proofread-test--profile
     :language ,language
     :checkers (( :name ,proofread-test--checker
                  :backend ,(or backend proofread-test--backend))))))

(defun proofread-test--current-profile-checker (&optional profile)
  "Return the first normalized checker from PROFILE.
When PROFILE is nil, use the current profile."
  (car (plist-get (or profile (proofread--current-profile))
                  :checkers)))

(defun proofread-test--make-profile-request (chunk)
  "Return a backend request for CHUNK owned by the current profile."
  (let* ((profile (proofread--current-profile))
         (checker (proofread-test--current-profile-checker profile)))
    (proofread--make-backend-request
     chunk (plist-get checker :backend) checker profile)))

(defun proofread-test--dispatch-profile-chunks (chunks)
  "Dispatch CHUNKS through the first checker in the current profile."
  (let* ((profile (proofread--current-profile))
         (checker (proofread-test--current-profile-checker profile)))
    (proofread--dispatch-request-ready-chunks
     chunks (plist-get checker :backend) checker profile)))

(defun proofread-test--defer-backend-result (callback result)
  "Return a cancellable handle that delivers RESULT to CALLBACK."
  (let ((handle (list :backend proofread-test--backend
                      :cancelled nil
                      :timer nil)))
    (setf (plist-get handle :timer)
          (run-at-time
           0 nil
           (lambda ()
             (unless (plist-get handle :cancelled)
               (proofread--invoke-backend-callback
                callback result)))))
    handle))

(defun proofread-test--backend-check (request callback)
  "Check REQUEST with the configured test backend and CALLBACK."
  (if proofread-test--backend-check-function
      (funcall proofread-test--backend-check-function
               request callback)
    (proofread-test--defer-backend-result
     callback (proofread--backend-success-result request nil))))

(defun proofread-test--backend-cancel (handle)
  "Cancel the test backend HANDLE."
  (when (listp handle)
    (setf (plist-get handle :cancelled) t)
    (let ((timer (plist-get handle :timer)))
      (when (timerp timer)
        (cancel-timer timer)))
    (setf (plist-get handle :timer) nil)))

(defun proofread-test--opaque-handle-cases ()
  "Return fresh provider-neutral backend handle fixtures."
  (list
   (list :kind 'symbol
         :handle (make-symbol "proofread-test-symbol-handle"))
   (list :kind 'vector
         :handle (vector 'proofread-test-vector-handle 'payload))
   (list :kind 'record
         :handle (record 'proofread-test-record-handle 'payload))
   (list :kind 'plist
         :handle
         (list :backend 'proofread-test-decoy-backend
               :cancelled 'backend-owned
               :timer 'backend-owned))))

(defun proofread-test--register-cancellable-backend
    (backend check cancel)
  "Register BACKEND with CHECK, CANCEL, and a minimal identity."
  (proofread--register-backend
   backend
   :check check
   :identity
   (lambda ()
     (list :backend backend :contract-version 1))
   :cancel cancel))

(defun proofread-test--assert-no-pending-request-work ()
  "Assert that the current buffer has no pending request work."
  (should-not proofread--active-requests)
  (should-not proofread--claimed-requests)
  (should-not proofread--request-queue)
  (should-not proofread--request-queue-tail)
  (proofread-test--assert-queue-cache-index-consistent)
  (should
   (zerop (hash-table-count proofread--pending-request-keys))))

(defmacro proofread-test--with-profile (&rest body)
  "Run BODY with the generic test backend selected by a profile."
  (declare (indent 0) (debug (body)))
  `(let ((proofread-profile proofread-test--profile)
         (proofread-profiles
          (proofread-test--profiles
           proofread-test--profile-language)))
     ,@body))

(defmacro proofread-test--with-profile-success
    (diagnostics &rest body)
  "Run BODY with the profile test backend returning DIAGNOSTICS."
  (declare (indent 1) (debug (form body)))
  `(let ((proofread-profile proofread-test--profile)
         (proofread-profiles
          (proofread-test--profiles
           proofread-test--profile-language))
         (proofread-test--backend-check-function
          (lambda (request callback)
            (proofread-test--defer-backend-result
             callback
             (proofread--backend-success-result
              request ,diagnostics)))))
     ,@body))

(defmacro proofread-test--with-profile-error
    (error message &rest body)
  "Run BODY with the profile test backend returning ERROR and MESSAGE."
  (declare (indent 2) (debug (form form body)))
  `(let ((proofread-profile proofread-test--profile)
         (proofread-profiles
          (proofread-test--profiles
           proofread-test--profile-language))
         (proofread-test--backend-check-function
          (lambda (request callback)
            (proofread-test--defer-backend-result
             callback
             (proofread--backend-error-result
              request ,error ,message)))))
     ,@body))

(defmacro proofread-test--with-legacy-options
    (backend language &rest body)
  "Run BODY with legacy BACKEND and LANGUAGE."
  (declare (indent 2) (debug (form form body)))
  `(with-suppressed-warnings
       ((obsolete proofread-backend proofread-language))
     (let ((proofread-backend ,backend)
           (proofread-language ,language))
       ,@body)))

;;;; Range and diagnostic tests

(ert-deftest proofread-test-normalize-ranges-merges-adjacent-ranges ()
  "Normalize visible ranges, dropping invalid or duplicate ranges."
  (should (equal (proofread--normalize-ranges
                  '((30 . 35)
                    (1 . 1)
                    (10 . 20)
                    (40 . 39)
                    (20 . 30)))
                 '((10 . 35)))))

(ert-deftest proofread-test-normalize-region-range-preserves-bounds ()
  "Normalize region order without clipping accessible bounds."
  (with-temp-buffer
    (insert "abc")
    (let ((end (copy-marker 3)))
      (should
       (equal (proofread--normalize-region-range end 0)
              '( 0 . 3))))))

(ert-deftest
    proofread-test-region-commands-preserve-boundary-errors ()
  "Preserve region argument errors before mode validation."
  (with-temp-buffer
    (insert "abc")
    (dolist (command
             '( proofread-check-region proofread-correct-region))
      (dolist (case '((nil invalid "No active region")
                      (invalid
                       2
                       "Region boundaries are not in the current buffer")
                      (20 20 "The region is empty")))
        (let ((condition
               (should-error
                (funcall command (nth 0 case) (nth 1 case))
                :type 'user-error)))
          (should (equal (error-message-string condition)
                         (nth 2 case))))))))

(ert-deftest proofread-test-new-diagnostics-preserves-input-order ()
  "Keep only first unseen diagnostics in input order."
  (let* ((existing
          (proofread-test--diagnostic-for-range 6 10 "wrld"))
         (later-range
          (proofread-test--diagnostic-for-range 11 15 "agin"))
         (earlier-range
          (proofread-test--diagnostic-for-range 1 5 "helo"))
         (diagnostics
          (list later-range
                (copy-sequence existing)
                earlier-range
                (copy-sequence later-range)
                (copy-sequence earlier-range)))
         (original-diagnostics (copy-sequence diagnostics))
         (result
          (proofread--new-diagnostics diagnostics (list existing))))
    (should (equal diagnostics original-diagnostics))
    (should (= (length result) 2))
    (should (eq (car result) later-range))
    (should (eq (cadr result) earlier-range))))

(ert-deftest
    proofread-test-range-conflicting-entries-orders-and-preserves-items
    ()
  "Scan unsorted conflicts without deduplicating or copying entries."
  (let* ((duplicate (list 'duplicate))
         (adjacent-left (cons 'adjacent-left '( 1 . 4)))
         (contains (cons 'contains '( 2 . 8)))
         (overlap (cons 'overlap '( 3 . 5)))
         (zero-left (cons 'zero-left '( 4 . 4)))
         (contained (cons 'contained '( 5 . 6)))
         (zero-right (cons 'zero-right '( 7 . 7)))
         (adjacent-right (cons 'adjacent-right '( 7 . 9)))
         (zero-query-left (cons 'zero-query-left '( 9 . 10)))
         (zero-query-right (cons 'zero-query-right '( 10 . 12)))
         (duplicate-first (cons duplicate '( 15 . 16)))
         (duplicate-second (cons duplicate '( 17 . 19)))
         (adjacent-late (cons 'adjacent-late '( 18 . 20)))
         (ranges (list '( 14 . 18) '( 10 . 10) '( 4 . 7)))
         (entries
          (list duplicate-second adjacent-left zero-right contained
                zero-query-right contains adjacent-late overlap
                duplicate-first adjacent-right zero-left
                zero-query-left))
         (original-ranges (copy-sequence ranges))
         (original-entries (copy-sequence entries))
         (expected
          (list contains overlap zero-left contained zero-right
                zero-query-left zero-query-right duplicate-first
                duplicate-second))
         (result
          (proofread--range-conflicting-entries ranges entries)))
    (should (equal ranges original-ranges))
    (should (equal entries original-entries))
    (should (equal result expected))
    (should (cl-every #'eq result expected))
    (should (= (cl-count duplicate result :key #'car :test #'eq) 2))))

(ert-deftest
    proofread-test-range-conflicting-entries-sorts-equal-starts-by-end
    ()
  "Find zero-width conflicts behind equal-start nonconflicts."
  (let* ((range-entry (cons 'range-candidate '( 1 . 2)))
         (zero-entry (cons 'zero-candidate '( 2 . 2)))
         (nonconflicting-entry
          (cons 'nonconflicting-candidate '( 2 . 4)))
         (range-result
          (proofread--range-conflicting-entries
           '((2 . 4) (2 . 2))
           (list range-entry)))
         (entry-result
          (proofread--range-conflicting-entries
           '((1 . 2))
           (list nonconflicting-entry zero-entry))))
    (should (equal range-result (list range-entry)))
    (should (eq (car range-result) range-entry))
    (should (equal entry-result (list zero-entry)))
    (should (eq (car entry-result) zero-entry))))

(ert-deftest proofread-test-conflicting-request-table-uses-eq-keys ()
  "Fold repeated conflicting candidate identities into an eq table."
  (let* ((main (list :beg 4 :end 7))
         (zero (list :beg 10 :end 10))
         (overlap (list :beg 3 :end 5))
         (contains (list :beg 2 :end 8))
         (zero-right (list :beg 7 :end 7))
         (zero-query-left (list :beg 9 :end 10))
         (contained (list :beg 5 :end 6))
         (contained-copy (copy-sequence contained))
         (adjacent-left (list :beg 1 :end 4))
         (adjacent-right (list :beg 7 :end 9))
         (table
          (proofread--conflicting-request-table
           (list zero main)
           (list adjacent-right contained overlap contained-copy
                 zero-query-left contains contained zero-right
                 adjacent-left contained))))
    (should-not (eq contained contained-copy))
    (should (equal contained contained-copy))
    (should (eq (hash-table-test table) #'eq))
    (dolist (candidate
             (list overlap contains zero-right zero-query-left
                   contained contained-copy))
      (should (gethash candidate table)))
    (should-not (gethash adjacent-left table))
    (should-not (gethash adjacent-right table))
    (should (= (hash-table-count table) 6))))

(ert-deftest
    proofread-test-partition-pending-requests-preserves-state
    ()
  "Partition all pending states without lifecycle side effects."
  (let* ((active-first
          (proofread-test--lifecycle-request 'active-first 1 2))
         (active-retained
          (proofread-test--lifecycle-request 'active-retained 2 3))
         (active-last
          (proofread-test--lifecycle-request 'active-last 3 4))
         (claimed-retained-first
          (proofread-test--lifecycle-request
           'claimed-retained-first 4 5))
         (claimed-selected
          (proofread-test--lifecycle-request 'claimed-selected 5 6))
         (claimed-retained-last
          (proofread-test--lifecycle-request
           'claimed-retained-last 6 7))
         (queued-first
          (proofread-test--lifecycle-request 'queued-first 7 8))
         (queued-retained-first
          (proofread-test--lifecycle-request
           'queued-retained-first 8 9))
         (queued-retained-last
          (proofread-test--lifecycle-request
           'queued-retained-last 9 10))
         (queued-last
          (proofread-test--lifecycle-request 'queued-last 10 11))
         (queued-first-entry
          (list :request queued-first :backend 'first-backend))
         (queued-retained-first-entry
          (list :request queued-retained-first
                :backend 'retained-first-backend))
         (queued-retained-last-entry
          (list :request queued-retained-last
                :backend 'retained-last-backend))
         (queued-last-entry
          (list :request queued-last :backend 'last-backend))
         (active-input
          (list active-first active-retained active-last))
         (claimed-input
          (list claimed-retained-first claimed-selected
                claimed-retained-last))
         (queue-input
          (list queued-first-entry queued-retained-first-entry
                queued-retained-last-entry queued-last-entry))
         (active-snapshot (copy-sequence active-input))
         (claimed-snapshot (copy-sequence claimed-input))
         (queue-snapshot (copy-sequence queue-input))
         (all-requests
          (append active-input claimed-input
                  (mapcar (lambda (entry)
                            (plist-get entry :request))
                          queue-input)))
         (request-value-snapshot (copy-tree all-requests))
         (queue-value-snapshot (copy-tree queue-input))
         (selected
          (list active-first active-last claimed-selected
                queued-first queued-last))
         (expected-visits all-requests)
         (proofread--active-requests active-input)
         (proofread--claimed-requests claimed-input)
         (proofread--request-queue queue-input)
         (original-tail (last queue-input))
         (proofread--request-queue-tail original-tail)
         (proofread--pending-request-keys
          (proofread-test--pending-request-table all-requests))
         (unpublished t)
         visits
         events
         cancelled-handles
         result)
    (should-error
     (proofread--partition-pending-requests
      (lambda (request)
        (when (eq request claimed-selected)
          (error "Simulated predicate failure"))
        (memq request selected))))
    (should (eq proofread--active-requests active-input))
    (should (eq proofread--claimed-requests claimed-input))
    (should (eq proofread--request-queue queue-input))
    (should (eq proofread--request-queue-tail original-tail))
    (let ((proofread-request-log-hook
           (list (lambda (event)
                   (push event events)))))
      (cl-letf (((symbol-function 'proofread--cancel-request-handle)
                 (lambda (handle)
                   (push handle cancelled-handles))))
        (setq result
              (proofread--partition-pending-requests
               (lambda (request)
                 (setq visits (append visits (list request)))
                 (unless (and (eq proofread--active-requests
                                  active-input)
                              (eq proofread--claimed-requests
                                  claimed-input)
                              (eq proofread--request-queue
                                  queue-input)
                              (eq proofread--request-queue-tail
                                  original-tail))
                   (setq unpublished nil))
                 (memq request selected))))))
    (should unpublished)
    (should (equal visits expected-visits))
    (should (cl-every #'eq visits expected-visits))
    (should
     (equal result
            (list :active (list active-first active-last)
                  :claimed (list claimed-selected)
                  :queued (list queued-first queued-last))))
    (should
     (cl-every #'eq (plist-get result :active)
               (list active-first active-last)))
    (should
     (cl-every #'eq (plist-get result :claimed)
               (list claimed-selected)))
    (should
     (cl-every #'eq (plist-get result :queued)
               (list queued-first queued-last)))
    (should (equal proofread--active-requests
                   (list active-retained)))
    (should (eq (car proofread--active-requests) active-retained))
    (should
     (equal proofread--claimed-requests
            (list claimed-retained-first claimed-retained-last)))
    (should
     (cl-every #'eq proofread--claimed-requests
               (list claimed-retained-first claimed-retained-last)))
    (should
     (equal proofread--request-queue
            (list queued-retained-first-entry
                  queued-retained-last-entry)))
    (should
     (cl-every #'eq proofread--request-queue
               (list queued-retained-first-entry
                     queued-retained-last-entry)))
    (should (eq proofread--request-queue-tail
                (last proofread--request-queue)))
    (should (eq (car proofread--request-queue-tail)
                queued-retained-last-entry))
    (should (equal active-input active-snapshot))
    (should (cl-every #'eq active-input active-snapshot))
    (should (equal claimed-input claimed-snapshot))
    (should (cl-every #'eq claimed-input claimed-snapshot))
    (should (equal queue-input queue-snapshot))
    (should (cl-every #'eq queue-input queue-snapshot))
    (should (equal all-requests request-value-snapshot))
    (should (equal queue-input queue-value-snapshot))
    (dolist (request all-requests)
      (should (equal (proofread--request-work-pending-p request)
                     (plist-get request :log-id)))
      (should-not
       (proofread--request-state-flag-p request :superseded))
      (should-not
       (proofread--request-state-flag-p request :invalidated))
      (should-not
       (proofread--request-state-flag-p request :cancelled)))
    (should-not events)
    (should-not cancelled-handles)))

(ert-deftest
    proofread-test-edit-affected-state-preserves-edit-boundaries ()
  "Collect edit-affected state in source order without copying it."
  (with-temp-buffer
    (insert "abcdefghijk")
    (proofread-mode 1)
    (let* ((left
            (proofread-test--diagnostic-for-range 1 3 "ab"))
           (interior
            (proofread-test--diagnostic-for-range 2 5 "bcd"))
           (interior-copy (copy-sequence interior))
           (zero
            (proofread-test--diagnostic-for-range 3 3 ""))
           (right
            (proofread-test--diagnostic-for-range 3 6 "cde"))
           (covered
            (proofread-test--diagnostic-for-range 7 8 "g"))
           (end-zero
            (proofread-test--diagnostic-for-range 9 9 ""))
           (after
            (proofread-test--diagnostic-for-range 9 11 "ij"))
           (diagnostics
            (list left interior interior-copy zero right covered
                  end-zero after))
           (overlays
            (proofread-test--install-diagnostics diagnostics))
           (interior-overlay (nth 1 overlays))
           (interior-copy-overlay (nth 2 overlays))
           (zero-overlay (nth 3 overlays))
           (covered-overlay (nth 5 overlays))
           (end-zero-overlay (nth 6 overlays)))
      (should (equal interior interior-copy))
      (should-not (eq interior interior-copy))
      (let ((affected (proofread--edit-affected-state 3 3))
            (expected-overlays
             (list zero-overlay
                   interior-copy-overlay
                   interior-overlay))
            (expected-diagnostics (list interior interior-copy zero)))
        (should (equal (car affected) expected-overlays))
        (should (cl-every #'eq (car affected) expected-overlays))
        (should (equal (cdr affected) expected-diagnostics))
        (should (cl-every #'eq (cdr affected) expected-diagnostics)))
      (let ((affected (proofread--edit-affected-state 6 9))
            (expected-overlays
             (list end-zero-overlay covered-overlay))
            (expected-diagnostics (list covered end-zero)))
        (should (equal (car affected) expected-overlays))
        (should (cl-every #'eq (car affected) expected-overlays))
        (should (equal (cdr affected) expected-diagnostics))
        (should
         (cl-every #'eq (cdr affected) expected-diagnostics))))))

;;;; Overlay and mode tests

(ert-deftest proofread-test-face-defaults-avoid-fixed-colors ()
  "Proofread faces are defined without fixed color attributes."
  (dolist (face '( proofread-face
                   proofread-current-face
                   proofread-echo-area-source-face
                   proofread-echo-area-message-face))
    (should (facep face))
    (let ((spec (face-default-spec face)))
      (should-not (proofread-test--tree-member-p :foreground spec))
      (should-not (proofread-test--tree-member-p :background spec))
      (should-not (proofread-test--tree-member-p :color spec))
      (should-not (proofread-test--tree-member-p 'flyspell-incorrect
                                                 spec))
      (should-not (proofread-test--tree-member-p 'flymake-warning
                                                 spec))
      (should-not (proofread-test--tree-member-p 'flymake-error spec))
      (should-not (proofread-test--tree-member-p 'flycheck-error
                                                 spec)))))

(ert-deftest proofread-test-echo-area-faces-have-package-defaults ()
  "Proofread echo-area faces inherit theme-aware font-lock faces."
  (should
   (equal (face-default-spec 'proofread-echo-area-source-face)
          '((t :inherit font-lock-keyword-face))))
  (should
   (equal (face-default-spec 'proofread-echo-area-message-face)
          '((t :inherit font-lock-comment-face)))))

(ert-deftest proofread-test-face-uses-font-lock-warning-face ()
  "Diagnostic text uses the theme's font-lock warning face."
  (let ((spec (face-default-spec 'proofread-face)))
    (should
     (proofread-test--tree-member-p 'font-lock-warning-face spec))
    (should (proofread-test--tree-member-p :underline spec))))

(ert-deftest proofread-test-overlay-stores-diagnostic ()
  "Store ownership and metadata on created proofread overlays."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic)))
      (setq proofread--diagnostics (list diagnostic))
      (let ((overlay (proofread--create-overlay diagnostic)))
        (should (eq (overlay-get overlay 'category)
                    'proofread-overlay))
        (should (eq (overlay-get overlay 'face) 'proofread-face))
        (should (equal (overlay-get overlay 'proofread-diagnostic)
                       diagnostic))
        (should
         (= (overlay-get
             overlay 'proofread-diagnostic-insertion-ordinal)
            0))
        (should (memq overlay proofread--overlays))
        (should (equal proofread--diagnostics (list diagnostic)))))))

(ert-deftest proofread-test-diagnostic-overlay-ordinals-are-monotonic
    ()
  "Do not reuse diagnostic overlay ordinals after deletion or clear."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (first (proofread-test--diagnostic-for-range 1 2 "a"))
          (second (proofread-test--diagnostic-for-range 3 4 "c"))
          (third (proofread-test--diagnostic-for-range 5 6 "e")))
      (proofread-mode 1)
      (let ((overlays
             (proofread-test--install-diagnostics
              (list first second))))
        (should
         (equal
          (mapcar
           (lambda (overlay)
             (overlay-get
              overlay 'proofread-diagnostic-insertion-ordinal))
           overlays)
          '( 0 1)))
        (proofread--invalidate-affected-diagnostics
         (list (car overlays)) (list first))
        (proofread-clear)
        (setq proofread--diagnostics (list third))
        (let ((overlay (proofread--create-overlay third)))
          (should
           (= (overlay-get
               overlay 'proofread-diagnostic-insertion-ordinal)
              2))
          (should (= proofread--next-diagnostic-insertion-ordinal
                     3)))))))

(ert-deftest proofread-test-clear-preserves-unrelated-overlays ()
  "Clearing diagnostics preserves unrelated overlays."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (setq proofread--diagnostics (list diagnostic))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-clear)
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--overlays)
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-edit-invalidates-proofread-overlay ()
  "Editing covered text deletes only the proofread-owned overlay."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (goto-char 3)
      (insert "x")
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-before-change-paths-select-same-state ()
  "Select the same objects for ordinary and deferred invalidation."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let* ((first
            (proofread-test--diagnostic-for-range 2 5 "bcd"))
           (same (copy-sequence first))
           (outside
            (proofread-test--diagnostic-for-range 5 7 "ef")))
      (should (equal first same))
      (should-not (eq first same))
      (proofread-test--install-diagnostics (list first same outside))
      (proofread--before-change 3 3)
      (let ((ordinary-overlays
             (copy-sequence proofread--pending-invalidated-overlays))
            (ordinary-diagnostics
             (copy-sequence
              proofread--pending-invalidated-diagnostics)))
        (setq proofread--pending-invalidated-overlays nil)
        (setq proofread--pending-invalidated-diagnostics nil)
        (let ((proofread--inhibit-overlay-invalidation
               (current-buffer))
              (proofread--deferred-correction-overlays nil)
              (proofread--deferred-correction-diagnostics nil))
          (proofread--before-change 3 3)
          (proofread--before-change 3 3)
          (should (= (length proofread--deferred-correction-overlays)
                     (length ordinary-overlays)))
          (should (= (length
                      proofread--deferred-correction-diagnostics)
                     (length ordinary-diagnostics)))
          (dolist (overlay ordinary-overlays)
            (should (memq overlay
                          proofread--deferred-correction-overlays)))
          (dolist (diagnostic ordinary-diagnostics)
            (should
             (memq diagnostic
                   proofread--deferred-correction-diagnostics))))))))

(ert-deftest proofread-test-disable-mode-clears-proofread-overlays ()
  "Disabling `proofread-mode' deletes proofread overlays only."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (proofread-overlay (proofread--create-overlay diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (setq proofread--diagnostics (list diagnostic))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-mode -1)
      (should-not (overlay-buffer proofread-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-disable-mode-clears-untracked-overlays ()
  "Disabling `proofread-mode' deletes untracked proofread overlays."
  (with-temp-buffer
    (insert "hello world again")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (tracked-overlay (proofread--create-overlay diagnostic))
           (orphan-overlay (make-overlay 8 13))
           (foreign-overlay (make-overlay 8 13)))
      (overlay-put orphan-overlay 'category
                   proofread--overlay-category)
      (overlay-put orphan-overlay 'face 'proofread-face)
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--overlays (list tracked-overlay))
      (narrow-to-region 1 6)
      (proofread-mode -1)
      (should-not (overlay-buffer tracked-overlay))
      (should-not (overlay-buffer orphan-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-check-visible-range-collects-single-window-range ()
  "Record the selected visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-single*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello visible world")
            (proofread-mode 1)
            (cl-letf (((symbol-function 'window-start)
                       (lambda (&optional _window) 3))
                      ((symbol-function 'window-end)
                       (lambda (&optional _window _update) 16)))
              (should (equal (proofread--visible-ranges) '((3 . 16))))
              (proofread-check-visible-range)
              (should-not proofread--diagnostics)
              (should-not proofread--overlays)
              (should-not proofread--active-requests)
              (should (= (hash-table-count proofread--cache) 0))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-deduplicates-multiple-windows
    ()
  "Merge overlapping visible ranges from multiple windows."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-multiple*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello visible world")
            (proofread-mode 1)
            (let* ((first-window (selected-window))
                   (second-window (split-window-right))
                   (window-ranges
                    `((,first-window . (3 . 12))
                      (,second-window . (8 . 16)))))
              (set-window-buffer second-window buffer)
              (cl-letf (((symbol-function 'window-start)
                         (lambda (&optional window)
                           (car (cdr (assq window window-ranges)))))
                        ((symbol-function 'window-end)
                         (lambda (&optional window _update)
                           (cdr (cdr (assq window window-ranges))))))
                (should (equal (proofread--visible-ranges) '((3 .
                                                                16))))
                (proofread-check-visible-range))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-no-window-produces-no-ranges ()
  "Do not use the whole buffer when no visible window exists."
  (with-temp-buffer
    (insert "hello hidden world")
    (proofread-mode 1)
    (proofread-check-visible-range)
    (should-not proofread--active-requests)))

;;;; Check command tests

(ert-deftest proofread-test-check-commands-require-mode ()
  "Proofread check commands require `proofread-mode'."
  (with-temp-buffer
    (insert "Alpha")
    (should-error (proofread-check-visible-range) :type 'user-error)
    (should-error (proofread-check-buffer) :type 'user-error)
    (should-error (proofread-check-region (point-min) (point-max))
                  :type 'user-error)
    (goto-char (point-min))
    (should-error (proofread-check-at-point) :type 'user-error)))

(ert-deftest proofread-test-check-buffer-dispatches-accessible-buffer
    ()
  "Check only accessible buffer text with the current options."
  (with-temp-buffer
    (insert "Outside. Alpha beta. Gamma. Outside.")
    (goto-char (point-min))
    (search-forward "Alpha")
    (let ((beg (match-beginning 0)))
      (search-forward "Gamma.")
      (let ((end (match-end 0)))
        (narrow-to-region beg end)
        (goto-char (+ (point-min) 2))
        (set-mark (+ (point-min) 4))
        (setq mark-active t)
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (let ((proofread-test--profile-language "en")
              (proofread-context-size 0)
              (proofread-max-chunk-size 7)
              (proofread-max-concurrent-requests 10)
              (recorder (proofread-test--make-backend-recorder))
              (source (current-buffer))
              (before-text (buffer-string))
              (before-tick (buffer-chars-modified-tick))
              (before-point (point))
              (before-mark (mark))
              (before-mark-active mark-active)
              (before-min (point-min))
              (before-max (point-max)))
          (proofread-test--with-profile
            (cl-letf (((symbol-function 'proofread--backend-check)
                       (plist-get recorder :function)))
              (proofread-check-buffer)
              (let ((requests (funcall (plist-get recorder
                                                  :requests))))
                (should (equal
                         (mapcar (lambda (request)
                                   (plist-get request :text))
                                 requests)
                         '( "Alpha " "beta." "Gamma.")))
                (dolist (request requests)
                  (should
                   (equal (plist-get request :language) "en"))))
              (should-not proofread-auto-check)
              (should (eq (current-buffer) source))
              (should (equal (buffer-string) before-text))
              (should (= (buffer-chars-modified-tick) before-tick))
              (should (= (point) before-point))
              (should (= (mark) before-mark))
              (should (eq mark-active before-mark-active))
              (should (= (point-min) before-min))
              (should (= (point-max) before-max)))))))))

(ert-deftest proofread-test-programming-checks-preserve-window-state
    ()
  "Preserve point and window position during programming checks."
  (dolist (command '( proofread-check-visible-range
                      proofread-check-buffer))
    (save-window-excursion
      (let ((buffer
             (generate-new-buffer
              (format " *proofread-programming-%s*" command))))
        (unwind-protect
            (progn
              (switch-to-buffer buffer)
              (emacs-lisp-mode)
              (insert ";; First prose sentence.\n"
                      "(setq cursor_should_stay_here 1)\n"
                      ";; Last prose sentence.\n")
              (setq-local proofread-auto-check nil)
              (setq-local proofread-targets 'comments)
              (proofread-mode 1)
              (goto-char (point-min))
              (search-forward "cursor_should")
              (let* ((proofread-context-size 0)
                     (proofread-max-concurrent-requests 10)
                     (recorder
                      (proofread-test--make-backend-recorder))
                     (window (selected-window))
                     (before (proofread-test--window-state buffer
                                                           window)))
                (proofread-test--with-profile
                  (cl-letf (((symbol-function
                              'proofread--backend-check)
                             (plist-get recorder :function)))
                    (funcall command)
                    (redisplay t)
                    (should (funcall (plist-get recorder :requests)))
                    (should (equal
                             (proofread-test--window-state buffer
                                                           window)
                             before))))))
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-check-region-normalizes-and-filters-selection ()
  "Normalize and filter regions passed to `proofread-check-region'."
  (with-temp-buffer
    (insert "Before. Alpha SECRET beta. After.")
    (goto-char (point-min))
    (search-forward "Alpha")
    (let ((beg (match-beginning 0)))
      (search-forward "SECRET")
      (add-text-properties (match-beginning 0) (match-end 0)
                           '( proofread-test-ignore t))
      (search-forward "beta.")
      (let ((end (match-end 0)))
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (let ((proofread-context-size 0)
              (proofread-ignored-properties '( proofread-test-ignore))
              (recorder (proofread-test--make-backend-recorder)))
          (proofread-test--with-profile
            (cl-letf (((symbol-function 'proofread--backend-check)
                       (plist-get recorder :function)))
              (proofread-check-region end beg)
              (should
               (equal
                (mapcar (lambda (request)
                          (plist-get request :text))
                        (funcall (plist-get recorder :requests)))
                '( "Alpha " " beta."))))))))))

(ert-deftest
    proofread-test-check-region-interactively-requires-active-region
    ()
  "`proofread-check-region' rejects an inactive region."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((transient-mark-mode t))
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active nil)
      (should-error (call-interactively #'proofread-check-region)
                    :type 'user-error)
      (should-not proofread--active-requests))))

(ert-deftest proofread-test-check-region-rejects-foreign-markers ()
  "`proofread-check-region' rejects markers from another buffer."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((other (generate-new-buffer " *proofread-region-marker*")))
      (unwind-protect
          (let ((foreign
                 (with-current-buffer other
                   (insert "Beta")
                   (copy-marker (point-min)))))
            (let ((condition
                   (should-error
                    (proofread-check-region foreign (point-max))
                    :type 'user-error)))
              (should
               (equal
                (error-message-string condition)
                "Region boundaries are not in the current buffer")))
            (should-not proofread--active-requests))
        (kill-buffer other)))))

(ert-deftest
    proofread-test-check-region-interactive-feedback-is-shown ()
  "Show region feedback even when messages are inhibited."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((transient-mark-mode t)
          messages)
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active t)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args)
                         messages))))
        (call-interactively #'proofread-check-region)
        (should
         (equal messages
                (list (concat
                       "proofread: collected 1 selected range; "
                       "no available backend"))))))))

(ert-deftest
    proofread-test-check-at-point-dispatches-containing-chunk ()
  "Check the point's chunk with its surrounding context."
  (with-temp-buffer
    (insert "First.  Second sentence. Third.")
    (goto-char (point-min))
    (search-forward "Second sentence.")
    (let ((beg (match-beginning 0)))
      (goto-char (+ beg 3))
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-test--profile-language "en")
            (proofread-context-size 100)
            (proofread-context-sentences-before 1)
            (proofread-context-sentences-after 1)
            (recorder (proofread-test--make-backend-recorder))
            (before-point (point)))
        (proofread-test--with-profile
          (cl-letf (((symbol-function 'proofread--backend-check)
                     (plist-get recorder :function)))
            (proofread-check-at-point)
            (let* ((requests (funcall (plist-get recorder :requests)))
                   (request (car requests)))
              (should (= (length requests) 1))
              (should (equal (plist-get request :text)
                             "Second sentence."))
              (should (equal (plist-get request :language) "en"))
              (should (string-match-p
                       "First" (plist-get request :context-before)))
              (should (string-match-p
                       "Third" (plist-get request :context-after))))
            (should (= (point) before-point))))))))

(ert-deftest proofread-test-request-ready-range-at-point-boundaries ()
  "Select point ranges at sentences, whitespace, and buffer edges."
  (with-temp-buffer
    (insert "First.  Second.")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "First.")
    (let ((first-beg (match-beginning 0))
          (first-end (match-end 0)))
      (search-forward "Second.")
      (let ((second-beg (match-beginning 0))
            (second-end (match-end 0)))
        (goto-char second-beg)
        (should (equal (proofread--request-ready-range-at-point)
                       (cons second-beg second-end)))
        (goto-char first-end)
        (should (equal (proofread--request-ready-range-at-point)
                       (cons first-beg first-end)))
        (goto-char (1+ first-end))
        (should-not (proofread--request-ready-range-at-point))
        (goto-char (point-max))
        (should (equal (proofread--request-ready-range-at-point)
                       (cons second-beg second-end))))))
  (with-temp-buffer
    (insert "abcdef")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((proofread-max-chunk-size 3))
      (goto-char 4)
      (should (equal (proofread--request-ready-range-at-point)
                     '( 4 . 7)))))
  (with-temp-buffer
    (insert "First.\n\n")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-max))
    (should-not (proofread--request-ready-range-at-point)))
  (with-temp-buffer
    (insert "Alpha http://example.com")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-max))
    (should-not (proofread--request-ready-range-at-point))))

(ert-deftest proofread-test-check-at-point-rejects-ignored-text ()
  "Reject point text excluded by ignored properties."
  (with-temp-buffer
    (insert "Alpha SECRET beta.")
    (goto-char (point-min))
    (search-forward "SECRET")
    (let ((beg (match-beginning 0))
          (end (match-end 0)))
      (add-text-properties beg end '( proofread-test-ignore t))
      (goto-char beg)
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-ignored-properties '( proofread-test-ignore)))
        (should-error (proofread-check-at-point) :type 'user-error)
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-progress-messages-inhibited-by-default ()
  "Routine progress messages are quiet by default."
  (let (messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args)
                       messages))))
      (should proofread-inhibit-progress-messages)
      (proofread--progress-message "proofread: %s" "checking")
      (should-not messages))))

(ert-deftest proofread-test-progress-messages-can-be-enabled ()
  "Routine progress messages can be enabled explicitly."
  (let ((proofread-inhibit-progress-messages nil)
        messages)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (push (apply #'format format-string args)
                       messages))))
      (proofread--progress-message "proofread: %s" "checking")
      (should (equal messages '( "proofread: checking"))))))

(ert-deftest
    proofread-test-check-visible-range-is-quiet-in-background ()
  "Keep noninteractive visible-range checks quiet."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-background-message*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello")
            (proofread-mode 1)
            (let (messages)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args)
                                 messages)))
                        ((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update)
                           (point-max))))
                (proofread-check-visible-range)
                (should-not messages))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-interactive-progress-is-shown
    ()
  "Report progress for interactive visible-range checks."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-interactive-message*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "hello")
            (proofread-mode 1)
            (let (messages)
              (cl-letf (((symbol-function 'message)
                         (lambda (format-string &rest args)
                           (push (apply #'format format-string args)
                                 messages)))
                        ((symbol-function 'window-start)
                         (lambda (&optional _window)
                           (point-min)))
                        ((symbol-function 'window-end)
                         (lambda (&optional _window _update)
                           (point-max))))
                (call-interactively #'proofread-check-visible-range)
                (should
                 (equal messages
                        '( "proofread: collected 1 visible \
range; no available backend"))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-auto-check-defaults-enabled-and-is-buffer-local ()
  "`proofread-auto-check' defaults to enabled and localizes when set."
  (should (custom-variable-p 'proofread-auto-check))
  (should (default-value 'proofread-auto-check))
  (should (local-variable-if-set-p 'proofread-auto-check))
  (with-temp-buffer
    (setq proofread-auto-check nil)
    (should (local-variable-p 'proofread-auto-check))
    (should-not proofread-auto-check)
    (with-temp-buffer
      (should proofread-auto-check))))

(ert-deftest
    proofread-test-echo-area-messages-default-enabled-and-local ()
  "The echo-area option defaults to enabled and localizes when set."
  (should (custom-variable-p 'proofread-echo-area-messages))
  (should (default-value 'proofread-echo-area-messages))
  (should (local-variable-if-set-p 'proofread-echo-area-messages))
  (with-temp-buffer
    (setq proofread-echo-area-messages nil)
    (should (local-variable-p 'proofread-echo-area-messages))
    (should-not proofread-echo-area-messages)
    (with-temp-buffer
      (should proofread-echo-area-messages))))

(ert-deftest
    proofread-test-mode-enable-schedules-initial-idle-work ()
  "Enabling automatic checking schedules initial idle work."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-idle-delay 7)
          scheduled
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (seconds repeat function &rest args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (setq scheduled
                         (list seconds repeat function args))
                   'proofread-test-timer))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks
                         (1+ (or visible-checks 0))))))
        (proofread-mode 1)
        (should (= timer-count 1))
        (should proofread--pending-work)
        (should (eq proofread--idle-timer
                    'proofread-test-timer))
        (should (equal scheduled
                       (list 7 nil #'proofread--idle-timer-run
                             (list (current-buffer)))))
        (proofread--mark-pending-work)
        (should (= timer-count 1))
        (should (eq (proofread--idle-timer-run
                     (current-buffer))
                    'ran))
        (should (= visible-checks 1))
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest
    proofread-test-mode-enable-respects-disabled-auto-check ()
  "Enabling with automatic checking off schedules no initial work."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (let (timer-count)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   'proofread-test-timer)))
        (proofread-mode 1)
        (should-not timer-count)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest
    proofread-test-repeated-mode-enable-replaces-initial-timer ()
  "Repeated mode enable cancels and replaces the initial timer."
  (with-temp-buffer
    (insert "Alpha")
    (let (cancelled timers)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (let ((timer
                          (intern
                           (format "proofread-test-timer-%d"
                                   (1+ (length timers))))))
                     (push timer timers)
                     timer)))
                ((symbol-function 'timerp)
                 (lambda (object)
                   (memq object timers)))
                ((symbol-function 'cancel-timer)
                 (lambda (timer)
                   (push timer cancelled))))
        (add-hook 'proofread-diagnostics-changed-hook
                  #'proofread--mark-pending-work nil t)
        (proofread-mode 1)
        (let ((first-timer proofread--idle-timer))
          (proofread-mode 1)
          (let ((second-timer proofread--idle-timer))
            (should (= (length timers) 3))
            (should (equal cancelled (cdr timers)))
            (should-not (eq second-timer first-timer))
            (should (eq second-timer (car timers)))
            (should proofread--pending-work)
            (proofread-mode -1)
            (should (equal cancelled timers))
            (should-not proofread--pending-work)
            (should-not proofread--idle-timer)))))))

(ert-deftest
    proofread-test-positive-option-rejects-zero-in-customize ()
  "Customize rejects a non-positive maximum chunk size."
  (let ((symbol 'proofread-max-chunk-size))
    (should (eq (get symbol 'custom-set)
                #'proofread-set-positive-integer-option))
    (should-error
     (funcall (get symbol 'custom-set) symbol 0))))

(ert-deftest
    proofread-test-auto-check-disabled-does-not-schedule-edit-work ()
  "Do not schedule edit work when automatic checking is off."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let ((proofread--request-queue '( manual-request))
          timer-count)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   'proofread-test-timer)))
        (insert "!")
        (should-not timer-count)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)
        (should (equal proofread--request-queue
                       '( manual-request)))))))

(ert-deftest
    proofread-test-auto-check-disabled-does-not-schedule-window-work
    ()
  "Do not schedule window work when automatic checking is off."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-auto-check-window*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let ((proofread--request-queue '( manual-request))
                  timer-count)
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (_seconds _repeat _function &rest
                                           _args)
                           (setq timer-count (1+ (or timer-count 0)))
                           'proofread-test-timer)))
                (proofread--window-scroll (selected-window)
                                          (point-min))
                (proofread--window-configuration-change)
                (should-not timer-count)
                (should-not proofread--pending-work)
                (should-not proofread--idle-timer)
                (should (equal proofread--request-queue
                               '( manual-request))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-auto-check-disabled-allows-manual-visible-check ()
  "Manual visible checking works when automatic checking is disabled."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-manual-check*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let (dispatched)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function
                            'proofread--request-ready-chunks-for-islands)
                           (lambda (_islands &optional _language)
                             '(( :text "Alpha"))))
                          ((symbol-function
                            'proofread--dispatch-profile-request-ready-chunks-result)
                           (lambda (chunks _profile)
                             (setq dispatched chunks)
                             '( :requests nil
                                :supported-count 1
                                :failures nil))))
                  (proofread-check-visible-range)
                  (should (equal dispatched '(( :text "Alpha"))))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-disabled-auto-check-stale-timer-does-not-check ()
  "A stale timer does not check after automatic checking is disabled."
  (with-temp-buffer
    (insert "Alpha")
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (proofread-mode 1)
        (should (= timer-count 1))
        (setq proofread-auto-check nil)
        (should-not (proofread--idle-timer-run buffer))
        (should-not visible-checks)
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)
        (setq proofread-auto-check t)
        (insert "?")
        (should (= timer-count 2))
        (should proofread--pending-work)))))

;;;; Automatic check tests

(ert-deftest proofread-test-edit-schedules-idle-work ()
  "Mark work pending and schedule a timer after an edit."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((proofread-idle-delay 7)
          scheduled)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (seconds repeat function &rest args)
                   (setq scheduled (list seconds repeat function
                                         args))
                   'proofread-test-timer)))
        (insert "!")
        (should proofread--pending-work)
        (should (eq proofread--idle-timer 'proofread-test-timer))
        (should (equal scheduled
                       (list 7 nil #'proofread--idle-timer-run
                             (list (current-buffer)))))))))

(ert-deftest proofread-test-edit-does-not-call-backend-synchronously
    ()
  "Editing schedules work without calling the backend inline."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let (backend-calls)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread--backend-check)
                 (lambda (_request _callback &optional _backend)
                   (setq backend-calls (1+ (or backend-calls 0))))))
        (insert "!")
        (should proofread--pending-work)
        (should-not backend-calls)))))

(ert-deftest proofread-test-repeated-edits-coalesce-before-idle ()
  "Repeated edits before idle time reuse one timer and run one check."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (insert "?")
        (should (= timer-count 1))
        (should proofread--pending-work)
        (should (eq (proofread--idle-timer-run buffer) 'ran))
        (should (= visible-checks 1))
        (should-not proofread--pending-work)
        (should-not proofread--idle-timer)))))

(ert-deftest proofread-test-activity-after-idle-can-reschedule ()
  "Activity after an idle callback can schedule later work."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let ((buffer (current-buffer))
          timer-count
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   (intern (format "proofread-test-timer-%d"
                                   timer-count))))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (insert "!")
        (should (eq (proofread--idle-timer-run buffer) 'ran))
        (insert "?")
        (should (= timer-count 2))
        (should (= visible-checks 1))
        (should proofread--pending-work)))))

(ert-deftest
    proofread-test-programming-idle-check-preserves-window-state ()
  "Preserve user and target windows during a programming idle check."
  (save-window-excursion
    (let ((user-buffer (generate-new-buffer " *proofread-idle-user*"))
          (target-buffer (generate-new-buffer
                          " *proofread-idle-target*")))
      (unwind-protect
          (let* ((user-window (selected-window))
                 (target-window (split-window-right))
                 (recorder (proofread-test--make-backend-recorder)))
            (set-window-buffer user-window user-buffer)
            (with-current-buffer user-buffer
              (dotimes (line 100)
                (insert (format "User line %03d must stay visible.\n"
                                line)))
              (goto-char (point-min))
              (forward-line 50)
              (move-to-column 8))
            (set-window-point
             user-window (with-current-buffer user-buffer (point)))
            (set-window-start
             user-window
             (with-current-buffer user-buffer
               (save-excursion
                 (goto-char (point-min))
                 (forward-line 30)
                 (point))))
            (with-current-buffer target-buffer
              (emacs-lisp-mode)
              (insert ";; First prose sentence.\n"
                      "(setq target_cursor_stays_here 1)\n"
                      ";; Last prose sentence.\n")
              (setq-local proofread-targets 'comments)
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t)
              (goto-char (point-min))
              (search-forward "target_cursor")
              (setq proofread--pending-work t))
            (set-window-buffer target-window target-buffer)
            (set-window-point
             target-window (with-current-buffer target-buffer
                             (point)))
            (set-window-start target-window 1)
            (select-window user-window)
            (let ((proofread-context-size 0)
                  (proofread-max-concurrent-requests 10)
                  (before
                   (proofread-test--window-state
                    target-buffer target-window)))
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'proofread--backend-check)
                           (plist-get recorder :function)))
                  (should (eq (proofread--idle-timer-run
                               target-buffer) 'ran))
                  (redisplay t)
                  (let ((requests (funcall (plist-get recorder
                                                      :requests)))
                        (callbacks (funcall (plist-get recorder
                                                       :callbacks))))
                    (should requests)
                    (let ((valid-index
                           (cl-position-if
                            (lambda (request)
                              (string-search
                               "First" (plist-get request :text)))
                            requests)))
                      (should valid-index)
                      (let* ((valid-request
                              (nth valid-index requests))
                             (valid-text (plist-get valid-request
                                                    :text))
                             (relative-beg
                              (string-search "First" valid-text)))
                        (dotimes (index (length requests))
                          (funcall
                           (nth index callbacks)
                           (if (= index valid-index)
                               (proofread--backend-success-result
                                valid-request
                                (list
                                 (proofread--diagnostic-from-request-relative-range
                                  valid-request
                                  (cons relative-beg
                                        (+ relative-beg 5))
                                  (list :kind 'spelling
                                        :message "Test diagnostic"
                                        :suggestions '( "First")
                                        :source
                                        proofread-test--backend))))
                             (proofread--backend-error-result
                              (nth index requests) 'test-error
                              (concat "Simulated background failure: "
                                      (make-string 600 ?x)))))))))
                  (redisplay t)
                  (should (equal
                           (proofread-test--window-state
                            target-buffer target-window)
                           before))))))
        (kill-buffer user-buffer)
        (kill-buffer target-buffer)))))

(ert-deftest proofread-test-window-activity-marks-proofread-buffer ()
  "Mark only live `proofread-mode' buffers after window activity."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-mode*"))
          (plain-buffer
           (generate-new-buffer " *proofread-window-plain*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t))
            (with-current-buffer plain-buffer
              (insert "Beta"))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest
                                         _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format
                                  "proofread-test-window-timer-%d"
                                  timer-count)))))
              (switch-to-buffer proofread-buffer)
              (proofread--window-scroll (selected-window) (point-min))
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (switch-to-buffer plain-buffer)
              (proofread--window-scroll (selected-window) (point-min))
              (with-current-buffer plain-buffer
                (should-not proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)
        (kill-buffer plain-buffer)))))

(ert-deftest proofread-test-window-configuration-change-marks-buffer
    ()
  "Window configuration changes mark proofread buffers pending."
  (save-window-excursion
    (let ((proofread-buffer
           (generate-new-buffer " *proofread-window-config*")))
      (unwind-protect
          (let (timer-count)
            (with-current-buffer proofread-buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)
              (setq proofread-auto-check t))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_seconds _repeat _function &rest
                                         _args)
                         (setq timer-count (1+ (or timer-count 0)))
                         (intern (format
                                  "proofread-test-window-timer-%d"
                                  timer-count)))))
              (switch-to-buffer proofread-buffer)
              (proofread--window-configuration-change)
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)))))

(ert-deftest proofread-test-disable-mode-clears-scheduled-work ()
  "Disabling `proofread-mode' clears pending work and timer state."
  (with-temp-buffer
    (insert "Alpha")
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (_seconds _repeat _function &rest _args)
                 'proofread-test-timer)))
      (proofread-mode 1)
      (should proofread--pending-work)
      (should proofread--idle-timer)
      (proofread-mode -1)
      (should-not proofread--pending-work)
      (should-not proofread--idle-timer)
      (should-not (memq #'proofread--after-change
                        after-change-functions)))))

(ert-deftest
    proofread-test-disabled-mode-stale-timer-does-not-check-visible ()
  "A stale timer after mode disable does not run visible checking."
  (with-temp-buffer
    (insert "Alpha")
    (let ((buffer (current-buffer))
          visible-checks)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   'proofread-test-timer))
                ((symbol-function 'proofread-check-visible-range)
                 (lambda ()
                   (setq visible-checks (1+ (or visible-checks 0))))))
        (proofread-mode 1)
        (proofread-mode -1)
        (should-not (proofread--idle-timer-run buffer))
        (should-not visible-checks)))))

(ert-deftest proofread-test-killed-buffer-idle-timer-is-ignored ()
  "An idle timer targeting a killed buffer is ignored without error."
  (let ((buffer (generate-new-buffer " *proofread-idle-killed*")))
    (with-current-buffer buffer
      (insert "Alpha")
      (proofread-mode 1))
    (kill-buffer buffer)
    (should-not (buffer-live-p buffer))
    (should-not (proofread--idle-timer-run buffer))))

;;;; Chunk and context tests

(ert-deftest proofread-test-chunk-spans-for-ranges-ordinary-paragraph
    ()
  "Sentence chunk spans record exact buffer boundaries."
  (with-temp-buffer
    (insert "First paragraph. Second line.\n\nIgnored")
    (let* ((paragraph-end (save-excursion
                            (goto-char (point-min))
                            (search-forward "\n\n")
                            (- (point) 2)))
           (spans (proofread--chunk-spans-for-ranges
                   (list (cons (point-min) paragraph-end)))))
      (should (= (length spans) 2))
      (should (equal (proofread-test--span-texts spans)
                     '( "First paragraph." "Second line.")))
      (should (= (caar spans) (point-min)))
      (should (= (cdr (car (last spans))) paragraph-end)))))

(ert-deftest proofread-test-chunk-spans-for-ranges-skips-whitespace ()
  "Chunk spans skip empty and whitespace-only paragraphs."
  (with-temp-buffer
    (insert "  \n\t\n\n")
    (should-not (proofread--chunk-spans-for-ranges
                 (list (cons (point-min) (point-max)))))))

(ert-deftest proofread-test-chunk-spans-split-oversized-paragraph ()
  "Oversized paragraphs split into bounded contiguous chunks."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (let* ((proofread-max-chunk-size 5)
           (spans (proofread--chunk-spans-for-ranges
                   (list (cons (point-min) (point-max))))))
      (should (equal spans '((1 . 6) (6 . 11) (11 . 13))))
      (should (equal (proofread-test--span-texts spans)
                     '( "abcde" "fghij" "kl")))
      (should (cl-every (lambda (span)
                          (<= (- (cdr span) (car span))
                              proofread-max-chunk-size))
                        spans)))))

(ert-deftest proofread-test-chunking-preserves-buffer-and-state ()
  "Preserve buffer contents, properties, and proofread state."
  (with-temp-buffer
    (insert (propertize "Alpha paragraph" 'face 'bold 'proofread-test
                        t))
    (proofread-mode 1)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick)))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (= (length spans) 1))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should-not proofread--active-requests)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest
    proofread-test-sentence-chunking-splits-chinese-paragraph ()
  "Split Chinese paragraphs at sentence punctuation."
  (with-temp-buffer
    (insert "第一句。第二句！第三句？")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '( "第一句。" "第二句！" "第三句？"))))))

(ert-deftest
    proofread-test-sentence-chunking-keeps-hard-wrapped-sentence ()
  "A single hard-wrap newline does not split a logical sentence."
  (with-temp-buffer
    (insert "第一句\n第二句")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '( "第一句\n第二句")))
      (should (equal spans
                     (list (cons (point-min) (point-max))))))))

(ert-deftest
    proofread-test-sentence-chunking-splits-english-paragraph ()
  "Split English sentences while keeping common inline forms."
  (with-temp-buffer
    (insert
     (concat "Dr. Smith measured 3.14. It rained. "
             "Visit example.com/path? Done!"))
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '( "Dr. Smith measured 3.14."
                        "It rained."
                        "Visit example.com/path?"
                        "Done!"))))))

(ert-deftest proofread-test-sentence-chunking-keeps-closing-quote ()
  "Keep closing quotes and brackets with sentence punctuation."
  (with-temp-buffer
    (insert "他说“第一句。”第二句。")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '( "他说“第一句。”" "第二句。"))))))

(ert-deftest
    proofread-test-sentence-chunking-bounds-oversized-sentence ()
  "A single oversized sentence still splits into bounded chunks."
  (with-temp-buffer
    (insert "一二三四五六。")
    (let ((proofread-max-chunk-size 3))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--span-texts spans)
                       '( "一二三" "四五六" "。")))
        (should (equal spans
                       '((1 . 4) (4 . 7) (7 . 8))))
        (should (cl-every (lambda (span)
                            (<= (- (cdr span) (car span))
                                proofread-max-chunk-size))
                          spans))))))

(ert-deftest
    proofread-test-sentence-chunking-keeps-unpunctuated-paragraph ()
  "Unpunctuated paragraphs stay one logical sentence."
  (with-temp-buffer
    (insert "第一句 第二句")
    (let ((spans (proofread--chunk-spans-for-ranges
                  (list (cons (point-min) (point-max))))))
      (should (equal (proofread-test--span-texts spans)
                     '( "第一句 第二句")))
      (should (= (length spans) 1)))))

(ert-deftest proofread-test-sentence-chunking-filtering-still-applies
    ()
  "Keep ignored text filtered after splitting sentences."
  (with-temp-buffer
    (insert (concat "甲 http://example.com 乙。"
                    "丙 user@example.com 丁。"
                    "戊 HIDDEN 己。"
                    "庚 SKIP 辛。"
                    "壬 DROP 癸。"))
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (drop-beg (progn
                      (goto-char (point-min))
                      (search-forward "DROP")
                      (match-beginning 0)))
          (drop-end (match-end 0))
          (proofread-ignored-faces '( proofread-test-ignore))
          (proofread-ignored-properties '( proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties hidden-beg hidden-end '( invisible t))
      (add-text-properties skip-beg skip-end
                           '( face proofread-test-ignore))
      (add-text-properties drop-beg drop-end
                           '( proofread-test-ignore t))
      (let* ((chunks (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (text (mapconcat #'identity
                              (proofread-test--chunk-texts chunks)
                              "")))
        (dolist (chunk chunks)
          (should (equal (plist-get chunk :text)
                         (buffer-substring-no-properties
                          (plist-get chunk :beg)
                          (plist-get chunk :end)))))
        (should-not (string-match-p "http://example.com" text))
        (should-not (string-match-p "user@example.com" text))
        (should-not (string-match-p "HIDDEN" text))
        (should-not (string-match-p "SKIP" text))
        (should-not (string-match-p "DROP" text))
        (should (string-match-p "甲 " text))
        (should (string-match-p " 癸。" text))))))

(ert-deftest
    proofread-test-sentence-chunking-preserves-buffer-and-state ()
  "Sentence-aware chunking preserves buffer and proofread state."
  (with-temp-buffer
    (insert (propertize "第一句。第二句。" 'face 'bold
                        'proofread-test t))
    (proofread-mode 1)
    (goto-char 3)
    (push-mark 5 t t)
    (let ((before-text (buffer-string))
          (before-tick (buffer-chars-modified-tick))
          (before-point (point))
          (before-mark (mark t)))
      (let ((spans (proofread--chunk-spans-for-ranges
                    (list (cons (point-min) (point-max))))))
        (should (equal (proofread-test--span-texts spans)
                       '( "第一句。" "第二句。")))
        (should (equal (buffer-string) before-text))
        (should (= (buffer-chars-modified-tick) before-tick))
        (should (= (point) before-point))
        (should (= (mark t) before-mark))
        (should (eq (get-text-property (point-min) 'face) 'bold))
        (should (get-text-property (point-min) 'proofread-test))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)
        (should-not proofread--active-requests)
        (should (= (hash-table-count proofread--cache) 0))))))

(ert-deftest proofread-test-request-ready-chunks-filter-url ()
  "Exclude URLs but retain surrounding request text."
  (with-temp-buffer
    (insert "Alpha http://example.com/path Beta")
    (let* ((proofread-context-size 0)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (texts (proofread-test--chunk-texts chunks)))
      (should (equal texts '( "Alpha " " Beta")))
      (should-not (string-match-p "http://example.com/path"
                                  (mapconcat #'identity texts ""))))))

(ert-deftest proofread-test-request-ready-chunks-filter-email ()
  "Request-ready chunks exclude email addresses while retaining text."
  (with-temp-buffer
    (insert "Alpha user@example.com Beta")
    (let* ((proofread-context-size 0)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (texts (proofread-test--chunk-texts chunks)))
      (should (equal texts '( "Alpha " " Beta")))
      (should-not (string-match-p "user@example.com"
                                  (mapconcat #'identity texts ""))))))

(ert-deftest proofread-test-request-ready-chunks-filter-ignored-face
    ()
  "Request-ready chunks exclude text with ignored faces."
  (with-temp-buffer
    (insert "Alpha SKIP Beta")
    (let ((skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (proofread-ignored-faces '( proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties skip-beg skip-end
                           '( face (bold proofread-test-ignore)))
      (should (equal
               (proofread-test--chunk-texts
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '( "Alpha " " Beta"))))))

(ert-deftest
    proofread-test-request-ready-chunks-filter-ignored-property ()
  "Request-ready chunks exclude text with ignored properties."
  (with-temp-buffer
    (insert "Alpha SKIP Beta")
    (let ((skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (proofread-ignored-properties '( proofread-test-ignore))
          (proofread-context-size 0))
      (add-text-properties skip-beg skip-end
                           '( proofread-test-ignore t))
      (should (equal
               (proofread-test--chunk-texts
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '( "Alpha " " Beta"))))))

(ert-deftest proofread-test-request-ready-chunks-filter-invisible ()
  "Request-ready chunks exclude invisible text by default."
  (with-temp-buffer
    (insert "Alpha HIDDEN Beta")
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (proofread-context-size 0))
      (add-text-properties hidden-beg hidden-end '( invisible t))
      (should (equal
               (proofread-test--chunk-texts
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               '( "Alpha " " Beta"))))))

(ert-deftest
    proofread-test-request-ready-chunks-copy-explicit-language
    ()
  "Snapshot explicit language metadata in filtered chunks."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-context-size 80))
      (insert "Keep http://example.com TARGET tail")
      (let ((chunks (proofread-test--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max))) "en")))
        (should (equal (proofread-test--chunk-texts chunks)
                       '( "Keep " " TARGET tail")))
        (dolist (chunk chunks)
          (should (equal (plist-get chunk :text)
                         (buffer-substring-no-properties
                          (plist-get chunk :beg)
                          (plist-get chunk :end))))
          (should (eq (plist-get chunk :major-mode) 'text-mode))
          (should (equal (plist-get chunk :language) "en"))
          (should-not
           (string-match-p "http://example.com"
                           (plist-get chunk :text)))
          (should-not
           (string-match-p "http://example.com"
                           (plist-get chunk :context-before)))
          (should-not
           (string-match-p
            "http://example.com"
            (plist-get chunk :context-after))))))))

(ert-deftest proofread-test-request-ready-context-default-sentences ()
  "Use one complete context sentence by default."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-context-size 300)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) "前文。"))
      (should (equal (plist-get chunk :context-after) "后文。")))))

(ert-deftest proofread-test-request-ready-context-configured-counts ()
  "Configured sentence counts change request-ready context windows."
  (with-temp-buffer
    (insert "一。二。三。目标。四。五。六。")
    (let* ((proofread-context-size 300)
           (proofread-context-sentences-before 2)
           (proofread-context-sentences-after 2)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) "二。三。"))
      (should (equal (plist-get chunk :context-after) "四。五。")))))

(ert-deftest proofread-test-request-ready-context-zero-counts ()
  "Zero sentence counts disable the corresponding context direction."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-context-size 300)
           (proofread-context-sentences-before 0)
           (proofread-context-sentences-after 0)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest
    proofread-test-request-ready-context-keeps-hard-wrap-sentence ()
  "Keep hard-wrapped prose as one logical context sentence."
  (with-temp-buffer
    (insert "前半句\n后半句。目标句。")
    (let* ((proofread-context-size 300)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before)
                     "前半句\n后半句。"))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest
    proofread-test-request-ready-context-ignores-visual-wrapping ()
  "Visual wrapping does not affect request-ready sentence context."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (let* ((proofread-context-size 300)
           (range (list (cons (point-min) (point-max))))
           (plain
            (proofread-test--request-ready-chunks-for-ranges range)))
      (visual-line-mode 1)
      (let ((wrapped (proofread-test--request-ready-chunks-for-ranges
                      range)))
        (should (equal (proofread-test--chunk-texts wrapped)
                       (proofread-test--chunk-texts plain)))
        (cl-mapc
         (lambda (left right)
           (should (equal (plist-get left :context-before)
                          (plist-get right :context-before)))
           (should (equal (plist-get left :context-after)
                          (plist-get right :context-after))))
         plain wrapped)))))

(ert-deftest
    proofread-test-request-ready-context-stops-at-blank-lines ()
  "Blank lines stop request-ready sentence context search."
  (with-temp-buffer
    (insert "前文。\n\n目标句。\n\n后文。")
    (let* ((proofread-context-size 300)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks
                                                   "目标句。")))
      (should chunk)
      (should (equal (plist-get chunk :context-before) ""))
      (should (equal (plist-get chunk :context-after) "")))))

(ert-deftest
    proofread-test-request-ready-context-stops-at-org-structure ()
  "Org structural lines stop request-ready sentence context search."
  (dolist
      (text
       '( "前文。\n* 标题\n目标句。"
          "前文。\n#+TITLE: 标题\n目标句。"
          "前文。\n:PROPERTIES:\n\
:CUSTOM_ID: x\n:END:\n目标句。"
          "前文。\n- 项目\n目标句。"
          "前文。\n| 表格 |\n目标句。"
          "前文。\n#+begin_quote\n引用。\n\
#+end_quote\n目标句。"))
    (with-temp-buffer
      (org-mode)
      (insert text)
      (let* ((proofread-context-size 300)
             (chunks (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (proofread-test--chunk-with-text chunks
                                                     "目标句。")))
        (should chunk)
        (should (equal (plist-get chunk :context-before) ""))))))

(ert-deftest
    proofread-test-request-ready-context-filters-ignored-text ()
  "Exclude ignored text from sentence context.

This covers URLs, email, invisible text, faces, and properties."
  (with-temp-buffer
    (insert
     (concat "访问 http://example.com，联系 "
             "user@example.com，保留 HIDDEN SKIP DROP。目标句。"))
    (let ((hidden-beg (progn
                        (goto-char (point-min))
                        (search-forward "HIDDEN")
                        (match-beginning 0)))
          (hidden-end (match-end 0))
          (skip-beg (progn
                      (goto-char (point-min))
                      (search-forward "SKIP")
                      (match-beginning 0)))
          (skip-end (match-end 0))
          (drop-beg (progn
                      (goto-char (point-min))
                      (search-forward "DROP")
                      (match-beginning 0)))
          (drop-end (match-end 0))
          (proofread-context-size 300)
          (proofread-ignored-faces '( proofread-test-ignore))
          (proofread-ignored-properties '( proofread-test-ignore)))
      (add-text-properties hidden-beg hidden-end '( invisible t))
      (add-text-properties skip-beg skip-end
                           '( face proofread-test-ignore))
      (add-text-properties drop-beg drop-end
                           '( proofread-test-ignore t))
      (let* ((chunks (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max)))))
             (chunk (proofread-test--chunk-with-text chunks
                                                     "目标句。"))
             (context (plist-get chunk :context-before)))
        (should chunk)
        (should-not (string-match-p "http://example.com" context))
        (should-not (string-match-p "user@example.com" context))
        (should-not (string-match-p "HIDDEN" context))
        (should-not (string-match-p "SKIP" context))
        (should-not (string-match-p "DROP" context))
        (should (string-match-p "访问" context))))))

(ert-deftest proofread-test-request-ready-context-oversized-fallback
    ()
  "Oversized single-sentence context uses bounded character fallback."
  (with-temp-buffer
    (insert "很长很长的前置句子。目标句。")
    (let* ((proofread-context-size 4)
           (chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (chunk (proofread-test--chunk-with-text chunks "目标句。"))
           (beg (plist-get chunk :beg))
           (expected (buffer-substring-no-properties (- beg 4) beg)))
      (should chunk)
      (should (equal (plist-get chunk :context-before) expected))
      (should (<= (length (plist-get chunk :context-before))
                  proofread-context-size))
      (should (equal (plist-get chunk :text)
                     (buffer-substring-no-properties
                      (plist-get chunk :beg)
                      (plist-get chunk :end)))))))

(ert-deftest proofread-test-request-ready-context-fragment-fallback ()
  "Oversized unpunctuated context uses bounded character context."
  (with-temp-buffer
    (insert "abcdefTARGETuvwxyz")
    (let ((proofread-context-size 3)
          (proofread-context-sentences-before 1)
          (proofread-context-sentences-after 1))
      (let ((chunk (proofread--make-request-ready-chunk 7 13)))
        (should (equal (plist-get chunk :text) "TARGET"))
        (should (equal (plist-get chunk :context-before) "def"))
        (should (equal (plist-get chunk :context-after) "uvw"))))))

;;;; Cache tests

(ert-deftest proofread-test-cache-key-varies-by-identity ()
  "Cache keys change when text or environment identity changes."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-test--backend-identity-token "identity-a"))
      (insert "Alpha")
      (let* ((chunk
              (plist-put
               (car (proofread-test--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max)))))
               :language "en"))
             (base-key
              (proofread--cache-key
               chunk proofread-test--backend)))
        (let ((proofread-test--backend-identity-token "identity-b"))
          (should-not
           (equal base-key
                  (proofread--cache-key
                   chunk proofread-test--backend))))
        (let ((changed-language (copy-sequence chunk)))
          (setq changed-language
                (plist-put changed-language :language "fr"))
          (should-not (equal base-key
                             (proofread--cache-key
                              changed-language
                              proofread-test--backend))))
        (let ((changed-mode (copy-sequence chunk)))
          (setq changed-mode
                (plist-put changed-mode :major-mode 'org-mode))
          (should-not (equal base-key
                             (proofread--cache-key
                              changed-mode proofread-test--backend))))
        (let ((changed-text (copy-sequence chunk)))
          (setq changed-text
                (plist-put changed-text :text "Beta"))
          (should-not (equal base-key
                             (proofread--cache-key
                              changed-text
                              proofread-test--backend))))))))

(ert-deftest proofread-test-cache-key-varies-by-context ()
  "Cover context, configuration, and content in cache keys."
  (let* ((proofread-context-size 300)
         (proofread-context-sentences-before 1)
         (proofread-context-sentences-after 1)
         (chunk '( :text "目标句。"
                   :context-before "前文。"
                   :context-after "后文。"
                   :language "zh"
                   :major-mode org-mode))
         (base-key
          (proofread--cache-key chunk proofread-test--backend))
         (context (plist-get base-key :context)))
    (should (eq (plist-get context :strategy) 'sentence-window))
    (let ((proofread-context-sentences-before 2))
      (should-not
       (equal base-key
              (proofread--cache-key
               chunk proofread-test--backend))))
    (let ((proofread-context-size 40))
      (should-not
       (equal base-key
              (proofread--cache-key
               chunk proofread-test--backend))))
    (let ((changed (plist-put (copy-sequence chunk)
                              :context-before "别的前文。")))
      (should-not (equal base-key
                         (proofread--cache-key
                          changed proofread-test--backend))))))

(ert-deftest
    proofread-test-cache-key-context-excludes-volatile-values ()
  "Context-aware cache keys exclude volatile objects and raw secrets."
  (with-temp-buffer
    (let* ((chunk (list :text "目标句。"
                        :context-before "secret-token 前文。"
                        :context-after "后文。"
                        :language "zh"
                        :major-mode 'org-mode
                        :buffer (current-buffer)
                        :callback #'ignore))
           (key (proofread--cache-key
                 chunk proofread-test--backend)))
      (should-not (plist-member key :buffer))
      (should-not (plist-member key :callback))
      (should-not (proofread-test--tree-member-p (current-buffer)
                                                 key))
      (should-not (proofread-test--tree-member-p "secret-token"
                                                 key)))))

(ert-deftest proofread-test-cache-read-write-hit-and-miss ()
  "Read and write cache entries only in active proofread buffers."
  (with-temp-buffer
    (insert "Alpha")
    (should-not (proofread--cache-write 'key 'value))
    (should-not proofread--cache)
    (proofread-mode 1)
    (should (proofread--cache-write 'key 'value))
    (should (equal (proofread--cache-read 'key) 'value))
    (should-not (proofread--cache-read 'missing-key))
    (proofread-mode -1)
    (should-not proofread--cache)
    (should-not (proofread--cache-read 'key))))

(ert-deftest
    proofread-test-request-relative-diagnostic-construction ()
  "Construct canonical diagnostics from request-relative ranges."
  (let* ((request '( :beg 20 :end 28 :text "This are"
                     :target-kind text))
         (properties '( :kind grammar
                        :message "Agreement"
                        :suggestions ("is")
                        :source test))
         (diagnostic
          (proofread--diagnostic-from-request-relative-range
           request '( 5 . 8) properties)))
    (should
     (equal diagnostic
            '( :beg 25 :end 28 :text "are" :kind grammar
               :message "Agreement" :suggestions ("is")
               :source test :target-kind text)))
    (should
     (equal
      (proofread--diagnostic-from-request-relative-range
       request '( 8 . 8) properties)
      '( :beg 28 :end 28 :text "" :kind grammar
         :message "Agreement" :suggestions ("is")
         :source test :target-kind text)))))

(ert-deftest proofread-test-request-relative-diagnostic-marker-base ()
  "Convert a live request marker into integer diagnostic positions."
  (with-temp-buffer
    (insert "prefixThis are")
    (let* ((request (list :beg (copy-marker 7)
                          :end (point-max)
                          :text "This are"
                          :target-kind 'text))
           (diagnostic
            (proofread--diagnostic-from-request-relative-range
             request '( 5 . 8)
             '( :kind grammar :message "Agreement"
                :suggestions ("is") :source test))))
      (should (equal (proofread--diagnostic-range diagnostic)
                     '( 12 . 15)))
      (should (integerp (plist-get diagnostic :beg)))
      (should (integerp (plist-get diagnostic :end))))))

(ert-deftest
    proofread-test-request-relative-diagnostic-validates-bounds ()
  "Reject relative diagnostic ranges outside their request text."
  (let ((request '( :beg 20 :end 28 :text "This are"))
        (properties '( :kind grammar :message "Agreement"
                       :suggestions nil :source test)))
    (dolist (range '((-1 . 0) (0 . 9) (6 . 5)
                     (nil . 4) (0)))
      (should
       (string-match-p
        "outside the request text"
        (error-message-string
         (should-error
          (proofread--diagnostic-from-request-relative-range
           request range properties))))))
    (dolist (invalid-request '(( :beg nil :text "This are")
                               ( :beg 20 :text nil)))
      (should
       (string-match-p
        "outside the request text"
        (error-message-string
         (should-error
          (proofread--diagnostic-from-request-relative-range
           invalid-request '( 0 . 4) properties))))))))

(ert-deftest
    proofread-test-request-relative-diagnostic-validates-target ()
  "Reject source delimiters while accepting safe target interiors."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; teh")
    (syntax-propertize (point-max))
    (let* ((request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text (buffer-string)
                          :target-kind 'comment))
           (properties '( :kind spelling
                          :message "Possible misspelling"
                          :suggestions ("the")
                          :source test)))
      (should-not
       (proofread--diagnostic-from-request-relative-range
        request '( 0 . 2) properties))
      (should
       (equal
        (proofread--diagnostic-from-request-relative-range
         request '( 3 . 6) properties)
        '( :beg 4 :end 7 :text "teh" :kind spelling
           :message "Possible misspelling" :suggestions ("the")
           :source test :target-kind comment))))))

(ert-deftest proofread-test-cache-relative-diagnostic-conversion ()
  "Cached diagnostics convert ranges between coordinate systems."
  (let* ((request '( :beg 10 :end 20 :text "0123456789"
                     :backend proofread-test-backend))
         (diagnostic (proofread-test--diagnostic-for-range 12 15
                                                           "234"))
         (relative
          (proofread--diagnostic-to-relative diagnostic request))
         (absolute
          (proofread--diagnostic-to-absolute relative request)))
    (should (= (plist-get relative :beg) 2))
    (should (= (plist-get relative :end) 5))
    (should-not (= (plist-get relative :beg)
                   (plist-get diagnostic :beg)))
    (should-not (= (plist-get relative :end)
                   (plist-get diagnostic :end)))
    (should (equal absolute diagnostic))))

(ert-deftest proofread-test-cache-hit-skips-backend-dispatch ()
  "Reuse cached diagnostics for unchanged visible text."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-hit*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback
                  backend-calls)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update) 5))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq backend-calls
                                   (1+ (or backend-calls 0)))
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (should (= backend-calls 1))
                  (let ((diagnostic
                         (proofread-test--diagnostic-for-range
                          1 5 "helo")))
                    (should (eq (funcall
                                 callback
                                 (proofread--backend-success-result
                                  request (list diagnostic)))
                                'applied))
                    (should (= (hash-table-count proofread--cache) 1))
                    (proofread-check-visible-range)
                    (should (= backend-calls 1))
                    (should
                     (equal
                      (proofread-test--diagnostics-without-provenance
                       proofread--diagnostics)
                      (list diagnostic)))
                    (should (= (length proofread--overlays) 1))
                    (proofread-clear)
                    (setq proofread--diagnostics nil)
                    (proofread-check-visible-range)
                    (should (= backend-calls 1))
                    (should
                     (equal
                      (proofread-test--diagnostics-without-provenance
                       proofread--diagnostics)
                      (list diagnostic)))
                    (should (= (length proofread--overlays) 1)))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-backend-result-replaces-request-range-diagnostics
    ()
  "Replace rather than duplicate diagnostics for the same request."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should (= (length proofread--diagnostics) 1))
        (should (= (length proofread--overlays) 1))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list diagnostic)))
        (should (= (length proofread--overlays) 1))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result request nil))
                    'applied))
        (should-not proofread--diagnostics)
        (should-not proofread--overlays)))))

(ert-deftest
    proofread-test-partial-backend-result-merges-without-caching ()
  "Merge unique partial results without writing them to the cache."
  (with-temp-buffer
    (insert "helo bad wrld")
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (old (proofread-test--diagnostic-for-range 1 5 "helo"))
             (later-range
              (proofread-test--diagnostic-for-range 10 14 "wrld"))
             (earlier-range
              (proofread-test--diagnostic-for-range 6 9 "bad"))
             (partial
              (proofread--backend-partial-success-result
               request
               (list later-range (copy-sequence old) earlier-range
                     (copy-sequence later-range)
                     (copy-sequence earlier-range))))
             (original-create-overlay
              (symbol-function 'proofread--create-overlay))
             (created 0)
             (changed 0))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result request (list old)))
                    'applied))
        (proofread-clear-cache)
        (add-hook 'proofread-diagnostics-changed-hook
                  (lambda () (setq changed (1+ changed))) nil t)
        (cl-letf (((symbol-function 'proofread--create-overlay)
                   (lambda (diagnostic)
                     (setq created (1+ created))
                     (funcall original-create-overlay diagnostic))))
          (should (eq (proofread--handle-backend-result partial)
                      'applied))
          (should
           (equal (proofread-test--diagnostics-without-provenance
                   proofread--diagnostics)
                  (list old later-range earlier-range)))
          (should (= (length proofread--overlays) 3))
          (should (= created 2))
          (should (= changed 1))
          (should (= (hash-table-count proofread--cache) 0))
          (should (eq (proofread--handle-backend-result partial)
                      'applied))
          (should
           (equal (proofread-test--diagnostics-without-provenance
                   proofread--diagnostics)
                  (list old later-range earlier-range)))
          (should (= (length proofread--overlays) 3))
          (should (= created 2))
          (should (= changed 1)))))))

(ert-deftest proofread-test-cache-miss-calls-backend ()
  "A visible chunk with no cache entry is sent to the backend."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-cache-miss*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo")
            (proofread-mode 1)
            (let ((recorder (proofread-test--make-backend-recorder)))
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (plist-get recorder :function)))
                  (proofread-check-visible-range)
                  (should (= (length (funcall
                                      (plist-get recorder :requests)))
                             1))
                  (should (equal (plist-get
                                  (car (funcall
                                        (plist-get recorder
                                                   :requests)))
                                  :text)
                                 "helo"))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-filtering-precedes-cache-and-backend-dispatch ()
  "Filtered chunks are used for cache lookup and backend dispatch."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-filter-cache*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let ((proofread-context-size 0)
                  (recorder (proofread-test--make-backend-recorder)))
              (proofread-test--with-profile
                (let* ((chunks
                        (proofread-test--request-ready-chunks-for-ranges
                         (list (cons (point-min) (point-max)))))
                       (cached-request
                        (proofread-test--make-profile-request
                         (car chunks)))
                       (cached-diagnostic
                        (proofread-test--diagnostic-with-kind
                         1 6 "Alpha" 'spelling)))
                  (proofread--cache-write-request
                   cached-request (list cached-diagnostic))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max)))
                            ((symbol-function 'proofread--backend-check)
                             (plist-get recorder :function)))
                    (proofread-check-visible-range)
                    (should (equal (mapcar
                                    (lambda (request)
                                      (plist-get request :text))
                                    (funcall (plist-get recorder
                                                        :requests)))
                                   '( " Beta")))
                    (should
                     (equal (proofread-test--diagnostics-without-provenance
                             proofread--diagnostics)
                            (list cached-diagnostic)))
                    (should (= (length proofread--overlays) 1)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-cache-invalidation-misses ()
  "Backend identity and text changes miss old cache entries."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((proofread-test--backend-identity-token "identity-a")
           (chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request
                     chunk proofread-test--backend))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request request (list diagnostic))
      (let ((proofread-test--backend-identity-token "identity-b"))
        (should-not (proofread--cache-read-request
                     (proofread--make-backend-request
                      chunk proofread-test--backend))))
      (let ((changed-chunk (plist-put (copy-sequence chunk)
                                      :text "Beta")))
        (should-not
         (proofread--cache-read-request
          (proofread--make-backend-request
           changed-chunk proofread-test--backend)))))))

(ert-deftest proofread-test-stale-and-error-results-are-not-cached ()
  "Do not cache stale or failed backend results."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (insert "!")
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'stale))
        (should (= (hash-table-count proofread--cache) 0))
        (let ((fresh-request
               (proofread-test--make-profile-request
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))))
          (should (eq (proofread--handle-backend-result
                       (proofread--backend-error-result
                        fresh-request 'proofread-test-backend-failure
                        "Test backend failure"))
                      'error))
          (should (= (hash-table-count proofread--cache) 0)))))))

(ert-deftest proofread-test-cache-hit-validates-current-text ()
  "Drop cached diagnostics when their source text has changed."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (entry (proofread--make-cache-entry request (list
                                                        diagnostic))))
      (delete-region 1 5)
      (insert "hello")
      (should (eq (proofread--apply-cache-entry request entry)
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

;;;; Profile configuration tests

(ert-deftest proofread-test-popup-0.1-compatibility-aliases ()
  "Retain the two core helper aliases required by popup 0.1.0."
  (dolist (case
           '((proofread--set-positive-integer-option
              . proofread-set-positive-integer-option)
             (proofread--report-warning-without-window
              . proofread-report-warning-without-window)))
    (let ((old-name (car case))
          (replacement (cdr case)))
      (should (eq (symbol-function old-name) replacement))
      (should (equal (get old-name 'byte-obsolete-info)
                     (list replacement nil "0.2.0"))))))

(ert-deftest proofread-test-legacy-options-are-obsolete ()
  "Mark both legacy configuration options obsolete in version 0.2.0."
  (dolist (case
           '((proofread-backend
              "proofread-profiles" "proofread-profile")
             (proofread-language ":language")))
    (let* ((variable (car case))
           (required-fragments (cdr case))
           (metadata (get variable 'byte-obsolete-variable)))
      (should (= (length metadata) 3))
      (let ((replacement (car metadata))
            (access-type (cadr metadata))
            (version (caddr metadata)))
        (should (stringp replacement))
        (dolist (fragment required-fragments)
          (should (string-match-p (regexp-quote fragment)
                                  replacement)))
        (should-not access-type)
        (should (equal version "0.2.0"))))))

(ert-deftest proofread-test-legacy-profile-normalizes-backend-settings
    ()
  "Normalize legacy backend settings as one synthetic profile."
  (proofread-test--with-legacy-options
      proofread-test--backend "zh-Hans"
    (let ((proofread-profile nil))
      (should
       (equal
        (proofread--current-profile)
        `( :name legacy
           :language "zh-Hans"
           :display-language nil
           :checkers
           (( :profile legacy
              :name legacy
              :checker-ordinal 0
              :backend ,proofread-test--backend
              :options nil
              :legacy t))))))))

(ert-deftest proofread-test-legacy-profile-allows-disabled-backend
    ()
  "Normalize disabled legacy backend settings as an empty profile."
  (proofread-test--with-legacy-options nil nil
    (let ((proofread-profile nil))
      (should
       (equal
        (proofread--current-profile)
        '( :name legacy
           :language nil
           :display-language nil
           :checkers nil))))))

(ert-deftest proofread-test-legacy-dispatch-warns-once-per-session ()
  "Warn once when repeated checks dispatch through legacy options."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread--legacy-dispatch-warning-issued-p nil)
            (recorder (proofread-test--make-backend-recorder))
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-buffer)
          (let* ((requests (funcall (plist-get recorder :requests)))
                 (callbacks (funcall (plist-get recorder :callbacks))))
            (should (= (length requests) 1))
            (should
             (eq (funcall
                  (car callbacks)
                  (proofread--backend-success-result
                   (car requests) nil))
                 'applied)))
          (proofread-check-buffer)
          (let* ((requests (funcall (plist-get recorder :requests)))
                 (callbacks (funcall (plist-get recorder :callbacks))))
            (should (= (length requests) 2))
            (should
             (eq (funcall
                  (cadr callbacks)
                  (proofread--backend-success-result
                   (cadr requests) nil))
                 'applied))))
        (should proofread--legacy-dispatch-warning-issued-p)
        (should (= (length warnings) 1))
        (let ((warning (car warnings)))
          (should (eq (car warning) 'proofread))
          (should (eq (nth 2 warning) :warning))
          (dolist (fragment
                   '("proofread-backend" "proofread-language"
                     "proofread-profiles" "proofread-profile"))
            (should (string-match-p
                     (regexp-quote fragment) (nth 1 warning)))))))))

(ert-deftest proofread-test-unavailable-legacy-backend-still-warns ()
  "Warn when a check selects an unavailable legacy backend."
  (proofread-test--with-legacy-options
      'proofread-test-unavailable-backend "en-US"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread--legacy-dispatch-warning-issued-p nil)
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore))
          (proofread-check-buffer))
        (should (= (length warnings) 1))
        (should proofread--legacy-dispatch-warning-issued-p)
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-legacy-dispatch-warning-is-session-global
    ()
  "Warn only once when legacy checks run in two buffers."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (let ((first-buffer
           (generate-new-buffer " *proofread-legacy-warning-a*"))
          (second-buffer
           (generate-new-buffer " *proofread-legacy-warning-b*"))
          (proofread-profile nil)
          (proofread--legacy-dispatch-warning-issued-p nil)
          requests
          warnings)
      (unwind-protect
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest args)
                       (push args warnings)))
                    ((symbol-function 'message) #'ignore)
                    ((symbol-function 'proofread--backend-check)
                     (lambda (request _callback &optional _backend)
                       (push request requests)
                       'proofread-test-handle)))
            (dolist (entry `((,first-buffer . "Alpha")
                             (,second-buffer . "Beta")))
              (with-current-buffer (car entry)
                (insert (cdr entry))
                (setq-local proofread-auto-check nil)
                (proofread-mode 1)
                (proofread-check-buffer)))
            (should (= (length requests) 2))
            (should (= (length warnings) 1))
            (should proofread--legacy-dispatch-warning-issued-p))
        (kill-buffer first-buffer)
        (kill-buffer second-buffer)))))

(ert-deftest
    proofread-test-legacy-inspection-preserves-language-and-identity
    ()
  "Inspect legacy provenance and freshness without a runtime warning."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread-context-size 0)
            (proofread-test--backend-identity-token 'identity-a)
            (proofread--legacy-dispatch-warning-issued-p nil)
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore))
          (let* ((profile (proofread--current-profile))
                 (checker (car (plist-get profile :checkers)))
                 (chunk
                  (car
                   (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))
                    (plist-get profile :language))))
                 (request
                  (proofread--make-backend-request
                   chunk proofread-test--backend checker profile))
                 (checker-identity
                  (plist-get request :checker-identity)))
            (should (eq (plist-get request :profile) 'legacy))
            (should (eq (plist-get request :checker-name) 'legacy))
            (should (equal (plist-get request :checker-owner)
                           '( :profile legacy
                              :checker-name legacy
                              :legacy t)))
            (should (equal (plist-get request :language) "en-US"))
            (should (equal (plist-get request :backend-identity)
                           (proofread-test--backend-identity)))
            (should (equal
                     (plist-get checker-identity :backend-identity)
                     (proofread-test--backend-identity)))
            (should (plist-get checker-identity :legacy))
            (should (proofread--fresh-request-p request))
            (let ((proofread-language "fr"))
              (should-not (proofread--fresh-request-p request)))
            (let ((proofread-backend
                   'proofread-test-other-backend))
              (should-not (proofread--fresh-request-p request))
              (should-not
               (proofread--request-ready-to-submit-p request)))
            (let ((proofread-backend nil))
              (should-not (proofread--fresh-request-p request))
              (should-not
               (proofread--request-ready-to-submit-p request)))
            (let ((proofread-test--backend-identity-token 'identity-b))
              (should-not (proofread--fresh-request-p request)))
            (should (proofread--fresh-request-p request))))
        (should-not warnings)
        (should-not proofread--legacy-dispatch-warning-issued-p)))))

(ert-deftest proofread-test-profile-normalizes-checkers ()
  "Normalize an explicitly selected profile and its checkers."
  (let ((proofread-profile 'zh-hans)
        (proofread-profiles
         `((zh-hans
            :language "zh-Hans"
            :display-language "Simplified Chinese"
            :checkers
            (( :name llm-primary
               :backend ,proofread-test--backend
               :options
               ( :provider proofread-test-provider
                 :provider-identity "test-provider"
                 :instructions-function
                 proofread-test-instructions
                 :instructions-identity "instructions:v1"))
             ( :name languagetool
               :backend languagetool
               :options
               ( :language "zh-CN"
                 :level picky)))))))
    (let* ((profile (proofread--current-profile))
           (checkers (plist-get profile :checkers))
           (llm-checker (car checkers))
           (languagetool-checker (cadr checkers)))
      (should (eq (plist-get profile :name) 'zh-hans))
      (should (equal (plist-get profile :language) "zh-Hans"))
      (should (equal (plist-get profile :display-language)
                     "Simplified Chinese"))
      (should (= (length checkers) 2))
      (should (eq (plist-get llm-checker :profile) 'zh-hans))
      (should (eq (plist-get llm-checker :name) 'llm-primary))
      (should (eq (plist-get llm-checker :backend)
                  proofread-test--backend))
      (should (equal (plist-get llm-checker :options)
                     '( :provider proofread-test-provider
                        :provider-identity "test-provider"
                        :instructions-function
                        proofread-test-instructions
                        :instructions-identity "instructions:v1")))
      (should (eq (plist-get languagetool-checker :name)
                  'languagetool))
      (should (eq (plist-get languagetool-checker :backend)
                  'languagetool)))))

(ert-deftest proofread-test-profile-can-be-buffer-local ()
  "Allow buffers to explicitly select different profiles."
  (let ((proofread-profile 'english)
        (proofread-profiles
         `((english
            :language "en-US"
            :checkers (( :name primary
                         :backend ,proofread-test--backend)))
           (chinese
            :language "zh-Hans"
            :checkers (( :name primary
                         :backend ,proofread-test--backend))))))
    (with-temp-buffer
      (setq-local proofread-profile 'chinese)
      (let ((profile (proofread--current-profile)))
        (should (eq (plist-get profile :name) 'chinese))
        (should (equal (plist-get profile :language) "zh-Hans"))))
    (should (eq proofread-profile 'english))
    (with-temp-buffer
      (let ((profile (proofread--current-profile)))
        (should (eq (plist-get profile :name) 'english))
        (should (equal (plist-get profile :language) "en-US"))))))

(ert-deftest proofread-test-profile-is-not-automatically-safe-local ()
  "Require confirmation for file-local profile selection by default."
  (should-not (get 'proofread-profile 'safe-local-variable)))

(ert-deftest proofread-test-buffer-local-nil-selects-legacy-profile ()
  "Keep buffer-local nil on the compatibility profile during migration."
  (proofread-test--with-legacy-options
      proofread-test--backend "legacy-language"
    (let ((proofread-profile 'english)
          (proofread-profiles
           `((english
              :language "en-US"
              :checkers (( :name primary
                           :backend ,proofread-test--backend))))))
      (with-temp-buffer
        (setq-local proofread-profile nil)
        (let ((profile (proofread--current-profile)))
          (should (eq (plist-get profile :name) 'legacy))
          (should (equal (plist-get profile :language)
                         "legacy-language")))))))

(ert-deftest proofread-test-buffer-local-empty-profile-disables-dispatch
    ()
  "Let one buffer select an explicitly disabled profile."
  (proofread-test--with-legacy-options proofread-test--backend nil
    (let ((proofread-profile 'enabled)
          (proofread-profiles
           `((enabled
              :checkers (( :name primary
                           :backend ,proofread-test--backend)))
             (disabled
              :checkers nil)))
          (proofread--legacy-dispatch-warning-issued-p nil)
          (backend-calls 0)
          warnings)
      (with-temp-buffer
        (insert "Alpha")
        (setq-local proofread-profile 'disabled)
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread--backend-check)
                   (lambda (_request _callback &optional _backend)
                     (setq backend-calls (1+ backend-calls))
                     'proofread-test-handle)))
          (let ((profile (proofread--current-profile)))
            (should (eq (plist-get profile :name) 'disabled))
            (should-not (plist-get profile :checkers))
            (should-not
             (proofread--current-profile-supported-checkers profile)))
          (proofread-check-buffer))
        (should (= backend-calls 0))
        (should-not proofread--active-requests)
        (should-not warnings)
        (should-not proofread--legacy-dispatch-warning-issued-p)))))

(ert-deftest
    proofread-test-explicit-legacy-named-profile-precedes-old-options
    ()
  "Treat an explicitly selected profile named legacy as non-legacy."
  (proofread-test--with-legacy-options
      'proofread-test-unavailable-backend "legacy-language"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile 'legacy)
            (proofread-profiles
             `((legacy
                :language "profile-language"
                :checkers (( :name legacy
                             :backend ,proofread-test--backend)))))
            (proofread-auto-check nil)
            (proofread-context-size 0)
            (proofread--legacy-dispatch-warning-issued-p nil)
            (recorder (proofread-test--make-backend-recorder))
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-buffer))
        (let ((requests (funcall (plist-get recorder :requests))))
          (should (= (length requests) 1))
          (let ((request (car requests)))
            (should (eq (plist-get request :profile) 'legacy))
            (should (eq (plist-get request :checker-name) 'legacy))
            (should (eq (plist-get request :backend)
                        proofread-test--backend))
            (should (equal (plist-get request :language)
                           "profile-language"))
            (should-not
             (plist-get (plist-get request :checker-owner)
                        :legacy))))
        (should-not warnings)
        (should-not proofread--legacy-dispatch-warning-issued-p)))))

(ert-deftest proofread-test-explicit-legacy-names-do-not-alias-old-options
    ()
  "Keep explicit, synthetic legacy, and ad-hoc ownership distinct."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profiles
             `((legacy
                :language "en-US"
                :checkers (( :name legacy
                             :backend ,proofread-test--backend)))))
            (proofread-auto-check nil)
            (proofread-context-size 0))
        (proofread-mode 1)
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))) "en-US")))
               (explicit-profile
                (let ((proofread-profile 'legacy))
                  (proofread--current-profile)))
               (explicit-checker
                (car (plist-get explicit-profile :checkers)))
               (explicit-request
                (proofread--make-backend-request
                 chunk proofread-test--backend
                 explicit-checker explicit-profile))
               (legacy-profile
                (let ((proofread-profile nil))
                  (proofread--current-profile)))
               (legacy-checker
                (car (plist-get legacy-profile :checkers)))
               (legacy-request
                (proofread--make-backend-request
                 chunk proofread-test--backend
                 legacy-checker legacy-profile))
               (ad-hoc-request
                (proofread--make-backend-request
                 chunk proofread-test--backend)))
          (dolist (pair
                   (list (list explicit-request legacy-request)
                         (list explicit-request ad-hoc-request)
                         (list legacy-request ad-hoc-request)))
            (dolist (key
                     '( :checker-owner :checker-identity :cache-key))
              (should-not
               (equal (plist-get (car pair) key)
                      (plist-get (cadr pair) key))))
            (should
             (= (hash-table-count
                 (proofread--conflicting-request-table
                  (list (car pair)) (list (cadr pair))))
                0))
            (should
             (= (hash-table-count
                 (proofread--conflicting-request-table
                  (list (cadr pair)) (list (car pair))))
                0)))
          (let ((proofread-profile 'legacy))
            (should (proofread--fresh-request-p explicit-request))
            (should-not (proofread--fresh-request-p legacy-request))
            (should (proofread--fresh-request-p ad-hoc-request)))
          (let ((proofread-profile nil))
            (should (proofread--fresh-request-p legacy-request))
            (should-not
             (proofread--fresh-request-p explicit-request))
            (should (proofread--fresh-request-p ad-hoc-request))))))))

(ert-deftest proofread-test-invalid-profile-never-falls-back-to-legacy
    ()
  "Reject missing and malformed profiles without legacy dispatch."
  (dolist (case
           '((missing nil)
             (malformed ((malformed :checkers invalid)))
             (duplicate
              ((duplicate
                :checkers
                (( :name repeated
                   :backend proofread-test-backend)
                 ( :name repeated
                   :backend proofread-test-backend)))))))
    (proofread-test--with-legacy-options proofread-test--backend "en-US"
      (with-temp-buffer
        (insert "Alpha")
        (let ((proofread-profile (car case))
              (proofread-profiles (cadr case))
              (proofread-auto-check nil)
              (proofread--legacy-dispatch-warning-issued-p nil)
              (backend-calls 0)
              warnings)
          (proofread-mode 1)
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest args)
                       (push args warnings)))
                    ((symbol-function 'message) #'ignore)
                    ((symbol-function 'proofread--backend-check)
                     (lambda (_request _callback &optional _backend)
                       (setq backend-calls (1+ backend-calls))
                       'proofread-test-handle)))
            (should-error (proofread-check-buffer)))
          (should (= backend-calls 0))
          (should-not proofread--active-requests)
          (should-not proofread--claimed-requests)
          (should-not proofread--request-queue)
          (should
           (zerop
            (hash-table-count
             proofread--pending-request-keys)))
          (should-not warnings)
          (should-not proofread--legacy-dispatch-warning-issued-p))))))

(ert-deftest proofread-test-nil-profile-and-backend-disable-dispatch
    ()
  "Dispatch nothing and warn about nothing when both selectors are nil."
  (proofread-test--with-legacy-options nil nil
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread--legacy-dispatch-warning-issued-p nil)
            (backend-calls 0)
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread--backend-check)
                   (lambda (_request _callback &optional _backend)
                     (setq backend-calls (1+ backend-calls))
                     'proofread-test-handle)))
          (proofread-check-buffer))
        (should (= backend-calls 0))
        (should-not proofread--active-requests)
        (should-not warnings)
        (should-not proofread--legacy-dispatch-warning-issued-p)))))

(ert-deftest proofread-test-legacy-result-is-cached-with-provenance ()
  "Cache legacy results with their original language and ownership."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (with-temp-buffer
      (insert "helo")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread-context-size 0)
            (proofread--legacy-dispatch-warning-issued-p nil)
            (recorder (proofread-test--make-backend-recorder))
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-buffer)
          (let* ((requests (funcall (plist-get recorder :requests)))
                 (callbacks (funcall (plist-get recorder :callbacks)))
                 (request (car requests))
                 (diagnostic
                  (proofread-test--diagnostic-for-range 1 5 "helo")))
            (should (= (length requests) 1))
            (should (equal (plist-get request :language) "en-US"))
            (should (eq (plist-get request :profile) 'legacy))
            (should (eq (plist-get request :checker-name) 'legacy))
            (should
             (eq (funcall
                  (car callbacks)
                  (proofread--backend-success-result
                   request (list diagnostic)))
                 'applied))
            (should (= (hash-table-count proofread--cache) 1))
            (let ((live (car proofread--diagnostics)))
              (should (equal (plist-get live :language) "en-US"))
              (should (eq (plist-get live :profile) 'legacy))
              (should (eq (plist-get live :checker-name) 'legacy))
              (should (equal (plist-get live :checker-owner)
                             (plist-get request :checker-owner))))
            (proofread-check-buffer)
            (should (= (length
                        (funcall (plist-get recorder :requests)))
                       1))
            (let ((live (car proofread--diagnostics)))
              (should (equal (plist-get live :language) "en-US"))
              (let ((proofread-language "fr"))
                (should
                 (equal
                  (plist-get
                   (proofread--diagnostic-ignore-key live) :language)
                  "en-US"))))))
        (should (= (length warnings) 1))
        (should proofread--legacy-dispatch-warning-issued-p)))))

(ert-deftest proofread-test-legacy-request-is-cancelled-with-buffer ()
  "Cancel an active legacy-owned request when disabling its buffer."
  (proofread-test--with-legacy-options
      proofread-test--backend "en-US"
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile nil)
            (proofread-auto-check nil)
            (proofread-context-size 0)
            (proofread--legacy-dispatch-warning-issued-p nil)
            request
            handle
            cancelled
            warnings)
        (proofread-mode 1)
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args)
                     (push args warnings)))
                  ((symbol-function 'message) #'ignore)
                  ((symbol-function 'proofread-test--backend-cancel)
                   (lambda (backend-handle)
                     (push backend-handle cancelled)))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (backend-request _callback &optional _backend)
                     (setq request backend-request)
                     (setq handle
                           'proofread-test-legacy-handle))))
          (proofread-check-buffer)
          (should request)
          (should (eq (plist-get request :profile) 'legacy))
          (should (eq (plist-get request :checker-name) 'legacy))
          (should (proofread--active-request-p request))
          (proofread-mode -1))
        (should (= (length cancelled) 1))
        (should (eq (car cancelled) handle))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should (= (length warnings) 1))))))

(ert-deftest proofread-test-profile-rejects-unknown-selection ()
  "Reject a selected profile that is not configured."
  (let ((proofread-profile 'missing)
        (proofread-profiles nil))
    (should-error (proofread--current-profile) :type 'user-error)))

(ert-deftest proofread-test-profile-rejects-unknown-property ()
  "Reject unknown properties in a profile definition."
  (let ((proofread-profile 'invalid)
        (proofread-profiles
         `((invalid
            :checkers
            (( :name current
               :backend ,proofread-test--backend))
            :unknown-property t))))
    (let ((err (should-error (proofread--current-profile) :type 'error)))
      (should
       (string-match-p
        "unknown property :unknown-property"
        (error-message-string err))))))

(ert-deftest proofread-test-profile-rejects-duplicate-checker-names
    ()
  "Reject duplicate checker names inside one profile."
  (let ((proofread-profile 'duplicate)
        (proofread-profiles
         `((duplicate
            :checkers
            (( :name repeated
               :backend ,proofread-test--backend)
             ( :name repeated
               :backend languagetool))))))
    (should-error (proofread--current-profile) :type 'error)))

(ert-deftest proofread-test-profile-ordinals-precede-backend-filtering
    ()
  "Assign checker ordinals before filtering unsupported backends."
  (let ((proofread-profile 'multi)
        (proofread-profiles
         `((multi
            :checkers
            (( :name unavailable
               :backend proofread-test-unavailable)
             ( :name available
               :backend ,proofread-test--backend))))))
    (let* ((profile (proofread--current-profile))
           (checkers (plist-get profile :checkers))
           (supported
            (proofread--current-profile-supported-checkers profile)))
      (should
       (equal (mapcar (lambda (checker)
                        (plist-get checker :checker-ordinal))
                      checkers)
              '( 0 1)))
      (should (= (length supported) 1))
      (should (eq (plist-get (car supported) :name) 'available))
      (should (= (plist-get (car supported) :checker-ordinal) 1))))
  (proofread-test--with-legacy-options proofread-test--backend nil
    (should (= (plist-get (proofread--legacy-profile-checker)
                          :checker-ordinal)
               0)))
  (should-not
   (plist-member (proofread--ad-hoc-checker proofread-test--backend)
                 :checker-ordinal)))

(ert-deftest proofread-test-profile-dispatch-fans-out-checkers ()
  "Dispatch one request per request-ready chunk and profile checker."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name strict
                 :backend ,proofread-test--backend
                 :options ( :tone strict))
               ( :name gentle
                 :backend ,proofread-test--backend
                 :options ( :tone gentle))))))
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get recorder :function)))
        (proofread-check-region (point-min) (point-max))
        (let ((requests (funcall (plist-get recorder :requests))))
          (should (= (length requests) 2))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :profile))
                                 requests)
                         '( multi multi)))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :checker-name))
                                 requests)
                         '( strict gentle)))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request
                                              :checker-ordinal))
                                 requests)
                         '( 0 1)))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :checker-options))
                                 requests)
                         '(( :tone strict) ( :tone gentle))))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :language))
                                 requests)
                         '( "en-US" "en-US")))
          (should (= (length proofread--active-requests) 2)))))))

(ert-deftest proofread-test-profile-empty-chunks-skip-checker-identity
    ()
  "Treat no chunks as an empty dispatch for a supported checker."
  (let ((proofread-profile 'multi)
        (proofread-profiles
         (proofread-test--ordered-profiles '( only)))
        (identity-calls 0)
        reports)
    (cl-letf
        (((symbol-function 'proofread--checker-request-identities)
          (lambda (_checker)
            (setq identity-calls (1+ identity-calls))
            (error "Identity must not be requested for empty chunks")))
         ((symbol-function 'proofread-report-warning-without-window)
          (lambda (detail summary)
            (push (list detail summary) reports))))
      (should
       (equal
        (proofread--dispatch-profile-request-ready-chunks-result
         nil (proofread--current-profile))
        '( :requests nil :supported-count 1 :failures nil))))
    (should (zerop identity-calls))
    (should-not reports)))

(ert-deftest
    proofread-test-profile-source-label-is-snapshotted-once-per-checker
    ()
  "Snapshot one safe source label for every dispatched checker."
  (with-temp-buffer
    (text-mode)
    (insert "First. Second.")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 20)
           (proofread-profile 'multi)
           (proofread-profiles (proofread-test--ordered-profiles))
           (proofread--backend-registry (make-hash-table :test #'eq))
           (recorder (proofread-test--make-backend-recorder))
           calls)
      (proofread--register-backend
       proofread-test--backend
       :check (plist-get recorder :function)
       :identity #'proofread-test--backend-identity
       :source-label
       (lambda (checker)
         (push (copy-sequence checker) calls)
         (propertize
          (format " \n%s\nmodel\tname " (plist-get checker :name))
          'proofread-test-secret t)))
      (proofread-mode 1)
      (proofread-check-buffer)
      (let ((requests (funcall (plist-get recorder :requests))))
        (should (= (length requests) 4))
        (should (= (length calls) 2))
        (should (equal (sort (mapcar (lambda (checker)
                                       (plist-get checker :name))
                                     calls)
                             (lambda (left right)
                               (string< (symbol-name left)
                                        (symbol-name right))))
                       '( first second)))
        (dolist (checker calls)
          (should-not (plist-member checker :checker-ordinal)))
        (dolist (request requests)
          (let ((label (plist-get request :source-label)))
            (should
             (equal label
                    (format "%s model name"
                            (plist-get request :checker-name))))
            (should-not (text-properties-at 0 label))
            (should
             (equal
              (plist-get
               (proofread--request-log-safe-request request)
               :source-label)
              label))))
        (should
         (equal (proofread-test--complete-recorded-requests recorder)
                '( applied applied applied applied)))
        (should (= (length proofread--diagnostics) 4))
        (dolist (diagnostic proofread--diagnostics)
          (should
           (equal
            (plist-get diagnostic :source-label)
            (format "%s model name"
                    (plist-get diagnostic :checker-name)))))))))

(ert-deftest
    proofread-test-source-label-failure-warns-and-dispatches-checker
    ()
  "Degrade invalid source labels without interrupting checker work."
  (dolist (failure '( error invalid blank))
    (with-temp-buffer
      (insert "Alpha")
      (let* ((proofread-auto-check nil)
             (proofread-cache-max-entries 0)
             (proofread-context-size 0)
             (proofread-profile 'multi)
             (proofread-profiles
              (proofread-test--ordered-profiles '( only)))
             (proofread--backend-registry
              (make-hash-table :test #'eq))
             (recorder (proofread-test--make-backend-recorder))
             (calls 0)
             reports)
        (proofread--register-backend
         proofread-test--backend
         :check (plist-get recorder :function)
         :identity #'proofread-test--backend-identity
         :source-label
         (lambda (_checker)
           (setq calls (1+ calls))
           (pcase failure
             ('error (error "secret source-label failure"))
             ('invalid '( secret invalid value))
             ('blank " \n\t "))))
        (proofread-mode 1)
        (cl-letf
            (((symbol-function
               'proofread-report-warning-without-window)
              (lambda (detail summary)
                (push (list detail summary) reports))))
          (proofread-check-buffer))
        (let ((requests (funcall (plist-get recorder :requests))))
          (should (= calls 1))
          (should (= (length requests) 1))
          (should-not (plist-get (car requests) :source-label))
          (should (= (length reports) 1))
          (should (string-match-p "source label" (caar reports)))
          (proofread-test--assert-secret-not-printed
           "secret" reports)
          (should
           (equal (proofread-test--complete-recorded-requests recorder)
                  '( applied)))
          (should-not
           (plist-get (car proofread--diagnostics) :source-label)))))))

(ert-deftest
    proofread-test-source-label-change-supersedes-pending-work
    ()
  "Let a new source label supersede otherwise identical pending work."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-profile 'multi)
           (proofread-profiles
            `((multi
               :checkers
               (( :name only
                  :backend ,proofread-test--backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (recorder (proofread-test--make-backend-recorder))
           (label "old-model")
           cancelled-handles)
      (proofread--register-backend
       proofread-test--backend
       :check (plist-get recorder :function)
       :identity #'proofread-test--backend-identity
       :source-label (lambda (_checker) label)
       :cancel (lambda (handle)
                 (push handle cancelled-handles)))
      (proofread-mode 1)
      (proofread-check-buffer)
      (let ((old (car (funcall (plist-get recorder :requests)))))
        (should old)
        (should (equal (plist-get old :source-label) "old-model"))
        (setq label "new-model")
        (proofread-check-buffer)
        (let* ((requests (funcall (plist-get recorder :requests)))
               (callbacks (funcall (plist-get recorder :callbacks)))
               (new (cadr requests)))
          (should (= (length requests) 2))
          (should (equal (plist-get new :source-label) "new-model"))
          (should (equal (plist-get old :cache-key)
                         (plist-get new :cache-key)))
          (should-not (equal (proofread--request-work-key old)
                             (proofread--request-work-key new)))
          (should
           (proofread--request-state-flag-p old :superseded))
          (should (equal cancelled-handles
                         '(proofread-test-handle)))
          (should-not (proofread--active-request-p old))
          (should (proofread--active-request-p new))
          (should
           (eq
            (funcall
             (car callbacks)
             (proofread--backend-success-result
              old
              (list
               (proofread-test--diagnostic-for-range 1 5 "helo"))))
            'stale))
          (should
           (eq
            (funcall
             (cadr callbacks)
             (proofread--backend-success-result
              new
              (list
               (proofread-test--diagnostic-for-range 1 5 "helo"))))
            'applied))
          (should
           (equal (plist-get (car proofread--diagnostics)
                             :source-label)
                  "new-model")))))))

(ert-deftest proofread-test-nil-source-label-is-silent ()
  "Treat a nil backend source label as a valid absence."
  (let ((proofread--backend-registry (make-hash-table :test #'eq))
        (calls 0)
        reports)
    (proofread--register-backend
     proofread-test--backend
     :check #'ignore
     :identity #'proofread-test--backend-identity
     :source-label
     (lambda (_checker)
       (setq calls (1+ calls))
       nil))
    (cl-letf
        (((symbol-function 'proofread-report-warning-without-window)
          (lambda (&rest args)
            (push args reports))))
      (should-not
       (proofread--backend-checker-source-label
        (list :profile 'multi
              :name 'only
              :checker-ordinal 0
              :backend proofread-test--backend
              :options nil))))
    (should (= calls 1))
    (should-not reports)))

(ert-deftest
    proofread-test-profile-feature-load-error-isolates-checker ()
  "Continue later profile checkers after one feature fails to load."
  (dolist (position '( first middle))
    (with-temp-buffer
      (text-mode)
      (insert "First. Second.")
      (let* ((proofread-auto-check nil)
             (proofread-cache-max-entries 0)
             (proofread-context-size 0)
             (proofread-max-concurrent-requests 20)
             (proofread-profile 'multi)
             (checker-names
              (proofread-test--failure-checker-names position))
             (successful-names (remq 'failed checker-names))
             (failed-backend 'proofread-test-feature-load-failure)
             (failed-feature 'proofread-test-feature-load-error)
             (proofread-profiles
              (list
               (list
                'multi
                :language "en-US"
                :checkers
                (mapcar
                 (lambda (name)
                   (list :name name
                         :backend
                         (if (eq name 'failed)
                             failed-backend
                           proofread-test--backend)))
                 checker-names))))
             (proofread--backend-features
              (cons (cons failed-backend failed-feature)
                    proofread--backend-features))
             (recorder (proofread-test--make-backend-recorder))
             (original-require (symbol-function 'require))
             (require-calls 0)
             events
             progress
             reports)
        (proofread-mode 1)
        (let ((proofread-request-log-hook
               (list (lambda (event)
                       (push event events)))))
          (cl-letf
              (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature failed-feature)
                      (progn
                        (setq require-calls (1+ require-calls))
                        (error "Simulated feature load failure"))
                    (funcall original-require feature filename noerror))))
               ((symbol-function 'proofread--backend-check)
                (plist-get recorder :function))
               ((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports)))
               ((symbol-function 'proofread--progress-message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        progress))))
            (proofread-check-buffer)
            (let ((requests
                   (funcall (plist-get recorder :requests))))
              (should (= require-calls 1))
              (proofread-test--assert-checker-dispatch-failure-event
               events 'backend-loading)
              (proofread-test--assert-one-checker-report reports)
              (proofread-test--assert-successful-checker-requests
               requests successful-names)
              (proofread-test--assert-dispatch-progress
               progress (length requests))
              (should-not
               (memq 'failed
                     (proofread-test--scheduled-checker-names)))
              (should
               (equal
                (proofread-test--complete-recorded-requests recorder)
                (make-list (length requests) 'applied)))
              (proofread-test--assert-request-diagnostics requests)
              (proofread-test--assert-requests-settled requests)
              (proofread-test--assert-one-checker-report reports))))))))

(ert-deftest
    proofread-test-profile-checker-identity-error-isolates-checker ()
  "Continue later profile checkers after one identity calculation fails."
  (dolist (position '( first middle))
    (with-temp-buffer
      (text-mode)
      (insert "First. Second.")
      (let* ((proofread-auto-check nil)
             (proofread-cache-max-entries 0)
             (proofread-context-size 0)
             (proofread-max-concurrent-requests 20)
             (proofread-profile 'multi)
             (checker-names
              (proofread-test--failure-checker-names position))
             (successful-names (remq 'failed checker-names))
             (proofread-profiles
              (proofread-test--ordered-profiles checker-names))
             (proofread--backend-registry
              (make-hash-table :test #'eq))
             (recorder (proofread-test--make-backend-recorder))
             (failed-identity-calls 0)
             events
             progress
             reports)
        (proofread--register-backend
         proofread-test--backend
         :check (plist-get recorder :function)
         :identity #'proofread-test--backend-identity
         :checker-identity
         (lambda (checker)
           (if (eq (plist-get checker :name) 'failed)
               (progn
                 (setq failed-identity-calls
                       (1+ failed-identity-calls))
                 (error "Simulated checker identity failure"))
             (list :backend proofread-test--backend
                   :checker-name (plist-get checker :name)
                   :contract-version 1))))
        (proofread-mode 1)
        (let ((proofread-request-log-hook
               (list (lambda (event)
                       (push event events)))))
          (cl-letf
              (((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports)))
               ((symbol-function 'proofread--progress-message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        progress))))
            (proofread-check-buffer)
            (let ((requests
                   (funcall (plist-get recorder :requests))))
              (should (= failed-identity-calls 1))
              (proofread-test--assert-checker-dispatch-failure-event
               events 'checker-identity)
              (proofread-test--assert-one-checker-report reports)
              (proofread-test--assert-successful-checker-requests
               requests successful-names)
              (proofread-test--assert-dispatch-progress
               progress (length requests))
              (should-not
               (memq 'failed
                     (proofread-test--scheduled-checker-names)))
              (should
               (equal
                (proofread-test--complete-recorded-requests recorder)
                (make-list (length requests) 'applied)))
              (proofread-test--assert-request-diagnostics requests)
              (proofread-test--assert-requests-settled requests)
              (proofread-test--assert-one-checker-report reports))))))))

(ert-deftest
    proofread-test-profile-request-construction-error-isolates-checker
    ()
  "Continue later profile checkers after one request construction fails."
  (dolist (position '( first middle))
    (with-temp-buffer
      (text-mode)
      (insert "First. Second.")
      (let* ((proofread-auto-check nil)
             (proofread-cache-max-entries 0)
             (proofread-context-size 0)
             (proofread-max-concurrent-requests 20)
             (proofread-profile 'multi)
             (checker-names
              (proofread-test--failure-checker-names position))
             (successful-names (remq 'failed checker-names))
             (proofread-profiles
              (proofread-test--ordered-profiles checker-names))
             (recorder (proofread-test--make-backend-recorder))
             (original-make-request
              (symbol-function 'proofread--make-backend-request))
             (failed-construction-calls 0)
             events
             progress
             reports)
        (proofread-mode 1)
        (let ((proofread-request-log-hook
               (list (lambda (event)
                       (push event events)))))
          (cl-letf
              (((symbol-function 'proofread--make-backend-request)
                (lambda (chunk &optional backend checker profile
                               identities)
                  (if (eq (plist-get checker :name) 'failed)
                      (progn
                        (setq failed-construction-calls
                              (1+ failed-construction-calls))
                        (error "Simulated request construction failure"))
                    (funcall original-make-request
                             chunk backend checker profile identities))))
               ((symbol-function 'proofread--backend-check)
                (plist-get recorder :function))
               ((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports)))
               ((symbol-function 'proofread--progress-message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        progress))))
            (proofread-check-buffer)
            (let ((requests
                   (funcall (plist-get recorder :requests))))
              (should (= failed-construction-calls 1))
              (proofread-test--assert-checker-dispatch-failure-event
               events 'request-construction)
              (proofread-test--assert-one-checker-report reports)
              (proofread-test--assert-successful-checker-requests
               requests successful-names)
              (proofread-test--assert-dispatch-progress
               progress (length requests))
              (should-not
               (memq 'failed
                     (proofread-test--scheduled-checker-names)))
              (should
               (equal
                (proofread-test--complete-recorded-requests recorder)
                (make-list (length requests) 'applied)))
              (proofread-test--assert-request-diagnostics requests)
              (proofread-test--assert-requests-settled requests)
              (proofread-test--assert-one-checker-report reports))))))))

(ert-deftest
    proofread-test-profile-synchronous-submission-error-isolates-checker
    ()
  "Continue later checkers after synchronous submission failures."
  (dolist (failure-mode '( signal nil-handle))
    (dolist (position '( first middle))
      (with-temp-buffer
        (text-mode)
        (insert "First. Second.")
        (let* ((proofread-auto-check nil)
               (proofread-cache-max-entries 0)
               (proofread-context-size 0)
               (proofread-max-concurrent-requests 20)
               (proofread-profile 'multi)
               (checker-names
                (proofread-test--failure-checker-names position))
               (successful-names (remq 'failed checker-names))
               (proofread-profiles
                (proofread-test--ordered-profiles checker-names))
               (recorder (proofread-test--make-backend-recorder))
               (recorder-function (plist-get recorder :function))
               all-requests
               events
               progress
               reports)
          (proofread-mode 1)
          (let ((proofread-request-log-hook
                 (list (lambda (event)
                         (push event events)))))
            (cl-letf
                (((symbol-function 'proofread--backend-check)
                  (lambda (request callback &optional backend)
                    (push request all-requests)
                    (if (eq (plist-get request :checker-name) 'failed)
                        (pcase failure-mode
                          ('signal
                           (error "Simulated submission failure"))
                          ('nil-handle nil))
                      (funcall recorder-function
                               request callback backend))))
                 ((symbol-function
                   'proofread-report-warning-without-window)
                  (lambda (detail summary)
                    (push (list detail summary) reports)))
                 ((symbol-function 'proofread--progress-message)
                  (lambda (format-string &rest args)
                    (push (apply #'format format-string args)
                          progress))))
              (proofread-check-buffer)
              (setq all-requests (nreverse all-requests))
              (let* ((requests
                      (funcall (plist-get recorder :requests)))
                     (failed-requests
                      (cl-remove-if-not
                       (lambda (request)
                         (eq (plist-get request :checker-name)
                             'failed))
                       all-requests))
                     (failure-events
                      (cl-remove-if-not
                       (lambda (event)
                         (let ((request
                                (plist-get event :request)))
                           (and
                            (eq (plist-get event :type) 'final-result)
                            (eq (plist-get request :checker-name)
                                'failed))))
                       events)))
                (should (= (length failed-requests) 2))
                (should (= (length failure-events) 2))
                (dolist (event failure-events)
                  (let ((result (plist-get event :result)))
                    (should (eq (plist-get event :status) 'error))
                    (should (eq (plist-get result :status) 'error))
                    (should (eq (plist-get result :phase) 'submission))
                    (when (eq failure-mode 'nil-handle)
                      (should
                       (eq (plist-get result :error)
                           'backend-returned-no-handle)))))
                (should-not
                 (cl-find-if
                  (lambda (event)
                    (eq (plist-get event :type)
                        'checker-dispatch-failed))
                  events))
                (proofread-test--assert-one-batch-error-report
                 reports 2
                 (if (eq failure-mode 'signal)
                     'error
                   'backend-returned-no-handle))
                (proofread-test--assert-secret-not-printed
                 "multi" reports)
                (proofread-test--assert-secret-not-printed
                 (if (eq failure-mode 'signal)
                     "Simulated submission failure"
                   (concat
                    "backend returned no handle without "
                    "delivering a result"))
                 reports)
                (proofread-test--assert-successful-checker-requests
                 requests successful-names)
                (proofread-test--assert-dispatch-progress
                 progress (length requests))
                (should-not
                 (memq 'failed
                       (proofread-test--scheduled-checker-names)))
                (dolist (request failed-requests)
                  (should-not (plist-get request :handle))
                  (should-not
                   (proofread--request-work-pending-p request)))
                (should
                 (equal
                  (proofread-test--complete-recorded-requests recorder)
                  (make-list (length requests) 'applied)))
                (proofread-test--assert-request-diagnostics requests)
                (proofread-test--assert-requests-settled all-requests)
                (proofread-test--assert-one-batch-error-report
                 reports 2
                 (if (eq failure-mode 'signal)
                     'error
                   'backend-returned-no-handle))))))))))

(ert-deftest
    proofread-test-synchronous-callback-then-signal-settles-once ()
  "Ignore a backend error after its synchronous callback has settled."
  (with-temp-buffer
    (text-mode)
    (insert "First. Second.")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 20)
           (proofread-profile 'multi)
           (proofread-profiles
            (proofread-test--ordered-profiles '( completed later)))
           (recorder (proofread-test--make-backend-recorder))
           (recorder-function (plist-get recorder :function))
           all-requests
           events
           reports)
      (proofread-mode 1)
      (let ((proofread-request-log-hook
             (list (lambda (event)
                     (push event events)))))
        (cl-letf
            (((symbol-function 'proofread--backend-check)
              (lambda (request callback &optional backend)
                (push request all-requests)
                (if (eq (plist-get request :checker-name) 'completed)
                    (progn
                      (funcall
                       callback
                       (proofread--backend-success-result
                        request
                        (list
                         (proofread--make-diagnostic
                          :beg (proofread--position-integer
                                (plist-get request :beg))
                          :end (proofread--position-integer
                                (plist-get request :end))
                          :text (plist-get request :text)
                          :kind 'spelling
                          :message "completed result"
                          :suggestions nil
                          :source 'completed))))
                      (error "Simulated error after callback"))
                  (funcall recorder-function request callback backend))))
             ((symbol-function
               'proofread-report-warning-without-window)
              (lambda (detail summary)
                (push (list detail summary) reports))))
          (proofread-check-buffer)
          (setq all-requests (nreverse all-requests))
          (let* ((later-requests
                  (funcall (plist-get recorder :requests)))
                 (completed-events
                  (cl-remove-if-not
                   (lambda (event)
                     (let ((request (plist-get event :request)))
                       (and
                        (eq (plist-get event :type) 'final-result)
                        (eq (plist-get request :checker-name)
                            'completed))))
                   events)))
            (should (= (length completed-events) 2))
            (dolist (event completed-events)
              (should (eq (plist-get event :status) 'applied))
              (should-not
               (plist-member (plist-get event :result) :phase)))
            (should-not reports)
            (should (= (length later-requests) 2))
            (should
             (equal
              (proofread-test--complete-recorded-requests recorder)
              '( applied applied)))
            (proofread-test--assert-request-diagnostics all-requests)
            (proofread-test--assert-requests-settled all-requests)
            (should-not reports)))))))

(ert-deftest
    proofread-test-synchronous-core-callback-error-is-resignalled ()
  "Re-signal core errors raised inside a synchronous backend callback."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-profile 'multi)
           (proofread-profiles
            (proofread-test--ordered-profiles '( only)))
           request
           events
           reports)
      (proofread-mode 1)
      (let ((proofread-request-log-hook
             (list (lambda (event)
                     (push event events)))))
        (cl-letf
            (((symbol-function 'proofread--backend-check)
              (lambda (backend-request callback &optional _backend)
                (setq request backend-request)
                (funcall
                 callback
                 (proofread--backend-success-result
                  backend-request nil))
                nil))
             ((symbol-function 'proofread--cache-write-request)
              (lambda (&rest _)
                (error "Simulated core callback failure")))
             ((symbol-function
               'proofread-report-warning-without-window)
              (lambda (detail summary)
                (push (list detail summary) reports))))
          (let ((condition
                 (should-error (proofread-check-buffer) :type 'error)))
            (should
             (equal (error-message-string condition)
                    "Simulated core callback failure"))))
        (should request)
        (should-not (plist-get request :handle))
        (should-not reports)
        (should-not
         (cl-find-if
          (lambda (event)
            (and
             (eq (plist-get event :type) 'final-result)
             (eq (plist-get (plist-get event :result) :phase)
                 'submission)))
          events))
        (should-not (proofread--request-work-pending-p request))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should
         (zerop
          (hash-table-count proofread--pending-request-keys)))))))

(ert-deftest
    proofread-test-profile-pending-work-distinguishes-checkers
    ()
  "Keep same-range work from different profile checkers distinct."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max))))))
        (proofread--dispatch-profile-request-ready-chunks
         chunks profile)
        (let ((queued
               (mapcar (lambda (entry)
                         (plist-get entry :request))
                       proofread--request-queue)))
          (should (= (length queued) 2))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :checker-name))
                                 queued)
                         '( first second)))
          (should-not (equal (proofread--request-work-key
                              (car queued))
                             (proofread--request-work-key
                              (cadr queued))))
          (should (= (hash-table-count
                      proofread--pending-request-keys)
                     2)))))))

(ert-deftest
    proofread-test-profile-supersedes-only-same-checker
    ()
  "Overlapping work supersedes only requests owned by the same checker."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 8)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (lambda (request _callback &optional _backend)
                   (list :backend proofread-test--backend
                         :checker-name
                         (plist-get request :checker-name)))))
        (let* ((profile (proofread--current-profile))
               (checkers (plist-get profile :checkers))
               (first-checker (car checkers))
               (old-chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((1 . 7)))))
               (new-chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((2 . 6))))))
          (proofread--dispatch-profile-request-ready-chunks
           (list old-chunk) profile)
          (let* ((old-first
                  (cl-find
                   'first proofread--active-requests
                   :key (lambda (request)
                          (plist-get request :checker-name))))
                 (old-second
                  (cl-find
                   'second proofread--active-requests
                   :key (lambda (request)
                          (plist-get request :checker-name)))))
            (should old-first)
            (should old-second)
            (proofread--dispatch-request-ready-chunks
             (list new-chunk) proofread-test--backend
             first-checker profile)
            (let ((new-first
                   (cl-find-if
                    (lambda (request)
                      (and (eq (plist-get request :checker-name)
                               'first)
                           (equal (plist-get request :text)
                                  "bcde")))
                    proofread--active-requests)))
              (should (proofread--request-state-flag-p
                       old-first :superseded))
              (should-not (proofread--active-request-p old-first))
              (should-not (proofread--request-state-flag-p
                           old-second :superseded))
              (should (proofread--active-request-p old-second))
              (should (proofread--active-request-p new-first))
              (should (= (length proofread--active-requests)
                         2)))))))))

(ert-deftest
    proofread-test-profile-result-adds-diagnostic-provenance
    ()
  "Annotate accepted diagnostics with profile checker provenance."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name strict
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should-not (plist-member diagnostic :profile))
        (should-not (plist-member diagnostic :language))
        (let ((live (car proofread--diagnostics)))
          (should (equal (plist-get live :language) "en-US"))
          (should (equal (plist-get live :profile) 'multi))
          (should (equal (plist-get live :checker-name) 'strict))
          (should (= (plist-get live :checker-ordinal) 0))
          (should (equal (plist-get live :checker-owner)
                         (plist-get request :checker-owner))))))))

(ert-deftest
    proofread-test-profile-display-language-snapshots-provenance ()
  "Snapshot profile display language into requests and diagnostics."
  (with-temp-buffer
    (insert "helo")
    (let* ((display-language (copy-sequence "Simplified Chinese"))
           (proofread-profile 'multi)
           (proofread-profiles
            `((multi
               :language "zh-Hans"
               :display-language ,display-language
               :checkers
               (( :name strict
                  :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (profile-display-language
              (plist-get profile :display-language))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile))
             (request-display-language
              (plist-get request :display-language))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (should (equal profile-display-language
                       "Simplified Chinese"))
        (should-not (eq profile-display-language display-language))
        (should (equal request-display-language
                       "Simplified Chinese"))
        (should-not
         (eq request-display-language profile-display-language))
        (aset profile-display-language 0 ?X)
        (should (equal request-display-language
                       "Simplified Chinese"))
        (should
         (eq (proofread--handle-backend-result
              (proofread--backend-success-result
               request (list diagnostic)))
             'applied))
        (should-not (plist-member diagnostic :display-language))
        (let* ((live (car proofread--diagnostics))
               (live-display-language
                (plist-get live :display-language)))
          (should (equal live-display-language
                         "Simplified Chinese"))
          (should-not (eq live-display-language
                          request-display-language))
          (aset request-display-language 0 ?Y)
          (should (equal live-display-language
                         "Simplified Chinese")))))))

(ert-deftest
    proofread-test-profile-result-replaces-only-same-checker
    ()
  "Do not let one checker's result remove another checker's diagnostics."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checkers (plist-get profile :checkers))
             (first-checker (car checkers))
             (second-checker (cadr checkers))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (first-request
              (proofread--make-backend-request
               chunk proofread-test--backend first-checker profile))
             (second-request
              (proofread--make-backend-request
               chunk proofread-test--backend second-checker profile))
             (first-diagnostic
              (proofread-test--diagnostic-with-suggestions
               1 5 "helo" '( "hello")))
             (second-diagnostic
              (proofread-test--diagnostic-with-suggestions
               1 5 "helo" '( "hullo"))))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      second-request (list second-diagnostic)))
                    'applied))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      first-request (list first-diagnostic)))
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list second-diagnostic first-diagnostic)))
        (should
         (equal (mapcar (lambda (diagnostic)
                          (plist-get diagnostic :checker-name))
                        proofread--diagnostics)
                '( second first)))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-success-result
                      first-request nil))
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list second-diagnostic)))
        (should (equal (plist-get (car proofread--diagnostics)
                                  :checker-owner)
                       (plist-get second-request :checker-owner)))))))

(ert-deftest
    proofread-test-profile-switch-retires-only-checked-diagnostics
    ()
  "Retire the old profile only inside the newly checked range."
  (with-temp-buffer
    (insert "helo and wrld")
    (setq-local proofread-profile 'profile-a)
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          (proofread-context-size 0)
          (proofread-profiles
           `((profile-a
              :checkers (( :name checker
                           :backend ,proofread-test--backend)))
             (profile-b
              :checkers (( :name checker
                           :backend ,proofread-test--backend)))))
          (profile-a-recorder
           (proofread-test--make-backend-recorder))
          (profile-b-recorder
           (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get profile-a-recorder :function)))
        (proofread-check-buffer)
        (let ((requests
               (funcall (plist-get profile-a-recorder :requests)))
              (callbacks
               (funcall (plist-get profile-a-recorder :callbacks))))
          (should (= (length requests) 1))
          (should (= (length callbacks) 1))
          (should
           (eq
            (funcall
             (car callbacks)
             (proofread--backend-success-result
              (car requests)
              (list
               (proofread-test--diagnostic-for-range
                1 5 "helo")
               (proofread-test--diagnostic-for-range
                10 14 "wrld"))))
            'applied))))
      (let* ((inside
              (cl-find 1 proofread--diagnostics
                       :key (lambda (diagnostic)
                              (plist-get diagnostic :beg))))
             (outside
              (cl-find 10 proofread--diagnostics
                       :key (lambda (diagnostic)
                              (plist-get diagnostic :beg))))
             (inside-overlay
              (proofread--overlay-for-diagnostic inside))
             (outside-overlay
              (proofread--overlay-for-diagnostic outside)))
        (should inside)
        (should outside)
        (setq-local proofread-profile 'profile-b)
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get profile-b-recorder :function)))
          (proofread-check-region 1 5)
          (should-not (memq inside proofread--diagnostics))
          (should-not (overlay-buffer inside-overlay))
          (should (memq outside proofread--diagnostics))
          (should (overlay-buffer outside-overlay))
          (should (eq (proofread--overlay-for-diagnostic outside)
                      outside-overlay))
          (let ((requests
                 (funcall (plist-get profile-b-recorder :requests)))
                (callbacks
                 (funcall (plist-get profile-b-recorder :callbacks))))
            (should (= (length requests) 1))
            (should (= (length callbacks) 1))
            (should (eq (plist-get (car requests) :profile)
                        'profile-b))
            (should
             (eq (funcall
                  (car callbacks)
                  (proofread--backend-success-result
                   (car requests) nil))
                 'applied)))
          (should (equal proofread--diagnostics (list outside)))
          (should (eq (proofread--overlay-for-diagnostic outside)
                      outside-overlay)))))))

(ert-deftest
    proofread-test-profile-checker-removal-keeps-current-until-replaced
    ()
  "Retire a removed checker but keep current diagnostics until result."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-profile 'multi)
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          (proofread-context-size 0)
          (proofread-profiles
           `((multi
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend)))))
          (initial-recorder
           (proofread-test--make-backend-recorder))
          (replacement-recorder
           (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get initial-recorder :function)))
        (proofread-check-buffer)
        (let* ((requests
                (funcall (plist-get initial-recorder :requests)))
               (callbacks
                (funcall (plist-get initial-recorder :callbacks)))
               (pairs (cl-mapcar #'cons requests callbacks)))
          (should (= (length pairs) 2))
          (dolist (checker '( second first))
            (let* ((pair
                    (cl-find
                     checker pairs
                     :key
                     (lambda (entry)
                       (plist-get (car entry) :checker-name))))
                   (request (car pair))
                   (callback (cdr pair))
                   (suggestions
                    (if (eq checker 'first)
                        '( "hello")
                      '( "hullo"))))
              (should pair)
              (should
               (eq
                (funcall
                 callback
                 (proofread--backend-success-result
                  request
                  (list
                   (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" suggestions))))
                'applied))))))
      (let* ((first
              (cl-find 'first proofread--diagnostics
                       :key (lambda (diagnostic)
                              (plist-get diagnostic :checker-name))))
             (second
              (cl-find 'second proofread--diagnostics
                       :key (lambda (diagnostic)
                              (plist-get diagnostic :checker-name))))
             (first-overlay
              (proofread--overlay-for-diagnostic first))
             (second-overlay
              (proofread--overlay-for-diagnostic second)))
        (should first)
        (should second)
        (setq proofread-profiles
              `((multi
                 :checkers
                 (( :name second
                    :backend ,proofread-test--backend)))))
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get replacement-recorder :function)))
          (proofread-check-buffer)
          (should-not (memq first proofread--diagnostics))
          (should-not (overlay-buffer first-overlay))
          (should (memq second proofread--diagnostics))
          (should (overlay-buffer second-overlay))
          (should (eq (proofread--overlay-for-diagnostic second)
                      second-overlay))
          (let ((requests
                 (funcall (plist-get replacement-recorder :requests)))
                (callbacks
                 (funcall (plist-get replacement-recorder :callbacks))))
            (should (= (length requests) 1))
            (should (= (length callbacks) 1))
            (should (eq (plist-get (car requests) :checker-name)
                        'second))
            (should
             (eq (funcall
                  (car callbacks)
                  (proofread--backend-success-result
                   (car requests) nil))
                 'applied)))
          (should-not proofread--diagnostics)
          (should-not (overlay-buffer second-overlay)))))))

(ert-deftest
    proofread-test-empty-profile-retires-profile-diagnostics-only
    ()
  "An empty profile retires profile diagnostics but keeps ad-hoc ones."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-profile 'enabled)
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          (proofread-context-size 0)
          (proofread-profiles
           `((enabled
              :checkers (( :name profile-checker
                           :backend ,proofread-test--backend)))
             (disabled :checkers nil)))
          (profile-recorder
           (proofread-test--make-backend-recorder))
          (ad-hoc-recorder
           (proofread-test--make-backend-recorder))
          (disabled-recorder
           (proofread-test--make-backend-recorder))
          profile-diagnostic
          profile-overlay
          ad-hoc-diagnostic
          ad-hoc-overlay)
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get profile-recorder :function)))
        (proofread-check-buffer)
        (let ((requests
               (funcall (plist-get profile-recorder :requests)))
              (callbacks
               (funcall (plist-get profile-recorder :callbacks))))
          (should (= (length requests) 1))
          (should (= (length callbacks) 1))
          (should
           (eq
            (funcall
             (car callbacks)
             (proofread--backend-success-result
              (car requests)
              (list
               (proofread-test--diagnostic-with-suggestions
                1 5 "helo" '( "hello")))))
            'applied))))
      (setq profile-diagnostic (car proofread--diagnostics))
      (setq profile-overlay
            (proofread--overlay-for-diagnostic profile-diagnostic))
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get ad-hoc-recorder :function)))
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               (dispatched
                (proofread--dispatch-request-ready-chunks
                 chunks proofread-test--backend))
               (callbacks
                (funcall (plist-get ad-hoc-recorder :callbacks))))
          (should (= (length dispatched) 1))
          (should (= (length callbacks) 1))
          (should (plist-get
                   (plist-get (car dispatched) :checker-owner)
                   :ad-hoc))
          (should
           (eq
            (funcall
             (car callbacks)
             (proofread--backend-success-result
              (car dispatched)
              (list
               (proofread-test--diagnostic-with-suggestions
                1 5 "helo" '( "hullo")))))
            'applied))))
      (setq ad-hoc-diagnostic
            (cl-find-if
             (lambda (diagnostic)
               (plist-get
                (plist-get diagnostic :checker-owner) :ad-hoc))
             proofread--diagnostics))
      (setq ad-hoc-overlay
            (proofread--overlay-for-diagnostic ad-hoc-diagnostic))
      (should profile-diagnostic)
      (should ad-hoc-diagnostic)
      (setq-local proofread-profile 'disabled)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get disabled-recorder :function)))
        (proofread-check-buffer))
      (should-not
       (funcall (plist-get disabled-recorder :requests)))
      (should-not (memq profile-diagnostic proofread--diagnostics))
      (should-not (overlay-buffer profile-overlay))
      (should (equal proofread--diagnostics
                     (list ad-hoc-diagnostic)))
      (should (overlay-buffer ad-hoc-overlay))
      (should (eq (proofread--overlay-for-diagnostic
                   ad-hoc-diagnostic)
                  ad-hoc-overlay)))))

(ert-deftest
    proofread-test-profile-order-is-independent-of-callback-order
    ()
  "Present profile diagnostics in checker order after any completion order."
  (let ((expected
         '( :members (first second)
            :kind grammar
            :sources ("first" "second")
            :public ((4 . 8)
                     "first: First message; second: Second message"
                     "helo")
            :suggestions ("first-fix" "shared" "second-fix")))
        signatures
        diagnostic-signatures)
    (dolist (completion-order '(( first second) ( second first)))
      (with-temp-buffer
        (insert "aa helo zz")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 0)
              (proofread-context-size 0)
              (proofread-max-concurrent-requests 2)
              (proofread-profile 'multi)
              (proofread-profiles
               (proofread-test--ordered-profiles))
              (recorder (proofread-test--make-backend-recorder)))
          (proofread-mode 1)
          (cl-letf (((symbol-function 'proofread--backend-check)
                     (plist-get recorder :function)))
            (proofread-check-buffer)
            (let ((requests
                   (funcall (plist-get recorder :requests))))
              (should (= (length requests) 2))
              (should (= (length proofread--active-requests) 2))
              (should
               (equal
                (mapcar
                 (lambda (request)
                   (list (plist-get request :checker-name)
                         (plist-get request :checker-ordinal)))
                 requests)
                '(( first 0) ( second 1)))))
            (should
             (equal
              (proofread-test--complete-recorded-checkers
               recorder completion-order)
              '( applied applied))))
          (should-not proofread--active-requests)
          (let* ((navigation (proofread--navigation-diagnostics))
                 (aggregate (car navigation)))
            (should (= (length navigation) 1))
            (push (proofread-test--ordered-raw-diagnostic-signatures)
                  diagnostic-signatures)
            (push
             (proofread-test--aggregate-order-signature aggregate)
             signatures)
            (goto-char 5)
            (let ((first-lookup (proofread-diagnostic-at-point))
                  (second-lookup (proofread-diagnostic-at-point)))
              (should-not (eq first-lookup second-lookup))
              (should
               (equal
                (proofread-test--aggregate-order-signature
                 first-lookup)
                expected))
              (should
               (equal
                (proofread-test--public-diagnostic-signature
                 first-lookup)
                (proofread-test--public-diagnostic-signature
                 second-lookup)))
              (should
               (equal
                (proofread-test--public-diagnostic-signature
                 first-lookup)
                (plist-get expected :public))))
            (goto-char (point-min))
            (proofread-next)
            (should
             (equal
              (proofread-test--aggregate-order-signature
               proofread--current-diagnostic)
              expected))
            (goto-char 5)
            (let (collection)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt candidates &rest _args)
                           (setq collection candidates)
                           (car candidates))))
                (should (eq (proofread-correct-at-point) 'applied)))
              (should
               (equal collection
                      '( "first-fix" "shared" "second-fix")))
              (should (equal (buffer-string)
                             "aa first-fix zz")))))))
    (should
     (equal
      (nreverse diagnostic-signatures)
      (make-list
       2
       '(( first 0 (4 . 8) "helo" grammar "First message"
           ("first-fix" "shared"))
         ( second 1 (4 . 8) "helo" style "Second message"
           ("second-fix" "shared"))))))
    (should (equal (nreverse signatures)
                   (list expected expected)))))

(ert-deftest
    proofread-test-profile-order-controls-conflicting-correction
    ()
  "Prefer the first profile checker for equal-range batch corrections."
  (dolist (completion-order '(( first second) ( second first)))
    (with-temp-buffer
      (insert "aa helo zz")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread-max-concurrent-requests 2)
            (proofread-profile 'multi)
            (proofread-profiles
             (proofread-test--ordered-profiles))
            (recorder (proofread-test--make-backend-recorder)))
        (proofread-mode 1)
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-buffer)
          (proofread-test--complete-recorded-checkers
           recorder completion-order))
        (let (collection)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _args)
                       (setq collection candidates)
                       (car candidates))))
            (should (eq (proofread-correct-buffer) 'applied)))
          (should (equal collection '( "first-fix" "shared")))
          (should (equal (buffer-string) "aa first-fix zz")))))))

(ert-deftest
    proofread-test-profile-reorder-reuses-cache-and-reorders-presentation
    ()
  "Reuse checker cache entries after changing profile presentation order."
  (with-temp-buffer
    (insert "aa helo zz")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 10)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 2)
          (proofread-profile 'multi)
          (proofread-profiles
           (proofread-test--ordered-profiles))
          (warm-recorder (proofread-test--make-backend-recorder))
          (cache-recorder (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get warm-recorder :function)))
        (proofread-check-buffer)
        (should
         (equal
          (proofread-test--complete-recorded-checkers
           warm-recorder '( second first))
          '( applied applied))))
      (should (= (hash-table-count proofread--cache) 2))
      (proofread-clear)
      (setq proofread-profiles
            (proofread-test--ordered-profiles '( second first)))
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (plist-get cache-recorder :function)))
        (proofread-check-buffer))
      (should-not (funcall (plist-get cache-recorder :requests)))
      (should-not proofread--active-requests)
      (should (= (hash-table-count proofread--cache) 2))
      (should
       (equal
        (mapcar
         (lambda (diagnostic)
           (list (plist-get diagnostic :checker-name)
                 (plist-get diagnostic :checker-ordinal)))
         (proofread--diagnostic-members
          (car (proofread--navigation-diagnostics))))
        '(( second 0) ( first 1))))
      (should
       (equal
        (proofread-test--aggregate-order-signature
         (car (proofread--navigation-diagnostics)))
        '( :members (second first)
           :kind style
           :sources ("second" "first")
           :public ((4 . 8)
                    "second: Second message; first: First message"
                    "helo")
           :suggestions ("second-fix" "shared" "first-fix")))))))

(ert-deftest
    proofread-test-profile-order-is-stable-for-mixed-cache-network
    ()
  "Keep profile order when one checker hits cache and one completes later."
  (let ((expected
         '( :members (first second)
            :kind grammar
            :sources ("first" "second")
            :public ((4 . 8)
                     "first: First message; second: Second message"
                     "helo")
            :suggestions ("first-fix" "shared" "second-fix")))
        signatures)
    (dolist (cached-checker '( first second))
      (with-temp-buffer
        (insert "aa helo zz")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 10)
              (proofread-context-size 0)
              (proofread-max-concurrent-requests 2)
              (proofread-profile 'multi)
              (proofread-profiles
               (proofread-test--ordered-profiles))
              (recorder (proofread-test--make-backend-recorder)))
          (proofread-mode 1)
          (let* ((profile (proofread--current-profile))
                 (checker
                  (cl-find
                   cached-checker (plist-get profile :checkers)
                   :key (lambda (candidate)
                          (plist-get candidate :name))))
                 (chunk
                  (car
                   (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
                 (request
                  (proofread--make-backend-request
                   chunk proofread-test--backend checker profile)))
            (proofread--cache-write-request
             request
             (list
              (proofread-test--ordered-checker-diagnostic request))))
          (cl-letf (((symbol-function 'proofread--backend-check)
                     (plist-get recorder :function)))
            (proofread-check-buffer)
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (network-checker
                    (if (eq cached-checker 'first)
                        'second
                      'first)))
              (should (= (length requests) 1))
              (should (eq (plist-get (car requests) :checker-name)
                          network-checker))
              (should (= (length proofread--active-requests) 1))
              (should (= (length proofread--diagnostics) 1))
              (should
               (eq (plist-get (car proofread--diagnostics)
                              :checker-name)
                   cached-checker))
              (should
               (equal
                (proofread-test--complete-recorded-checkers
                 recorder (list network-checker))
                '( applied)))))
          (should (= (hash-table-count proofread--cache) 2))
          (push
           (proofread-test--aggregate-order-signature
            (car (proofread--navigation-diagnostics)))
           signatures))))
    (should (equal (nreverse signatures)
                   (list expected expected)))))

(ert-deftest
    proofread-test-profile-cache-hit-preserves-diagnostic-provenance
    ()
  "Keep checker provenance when diagnostics are served from cache."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :display-language "English"
              :checkers
              (( :name strict
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo")))
        (proofread--cache-write-request request (list diagnostic))
        (let* ((entry (proofread--cache-read-request request))
               (cached (car (plist-get entry :diagnostics))))
          (should (equal (plist-get cached :language) "en-US"))
          (should (equal (plist-get cached :display-language)
                         "English"))
          (should (= (plist-get cached :checker-ordinal) 0))
          (should (equal (plist-get cached :checker-owner)
                         (plist-get request :checker-owner)))
          (should (eq (proofread--apply-cache-entry request entry)
                      'applied))
          (let ((live (car proofread--diagnostics)))
            (should (equal (plist-get live :language) "en-US"))
            (should (equal (plist-get live :display-language)
                           "English"))
            (should (equal (plist-get live :profile) 'multi))
            (should (equal (plist-get live :checker-name) 'strict))
            (should (= (plist-get live :checker-ordinal) 0))
            (should (equal (plist-get live :checker-owner)
                           (plist-get request :checker-owner)))))))))

(ert-deftest
    proofread-test-cache-hit-refreshes-source-label-provenance
    ()
  "Overlay cached diagnostics with the current checker source label."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-profile 'multi)
           (proofread-profiles
            `((multi
               :language "en-US"
               :checkers
               (( :name strict
                  :backend ,proofread-test--backend)))))
           (proofread--backend-registry (make-hash-table :test #'eq))
           (label "old-model"))
      (proofread--register-backend
       proofread-test--backend
       :check #'proofread-test--backend-check
       :identity #'proofread-test--backend-identity
       :source-label (lambda (_checker) label))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (old-request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (proofread--cache-write-request old-request (list diagnostic))
        (let* ((entry (proofread--cache-read-request old-request))
               (cached (car (plist-get entry :diagnostics))))
          (should (equal (plist-get cached :source-label) "old-model"))
          (setq label "new-model")
          (let ((new-request
                 (proofread--make-backend-request
                  chunk proofread-test--backend checker profile)))
            (should
             (equal (plist-get old-request :cache-key)
                    (plist-get new-request :cache-key)))
            (should (equal (plist-get new-request :source-label)
                           "new-model"))
            (should (eq (proofread--apply-cache-entry new-request entry)
                        'applied))
            (let ((live (car proofread--diagnostics)))
              (should (equal (plist-get live :source-label)
                             "new-model"))
              (should (eq (plist-get live :source) 'test))
              (should
               (equal
                (proofread-diagnostic-message-entries live)
                '(( :source "new-model"
                    :message "Possible misspelling"))))
              (should
               (eq (plist-get
                    (proofread--diagnostic-ignore-key live) :source)
                   'test))
              (should
               (equal
                (plist-get
                 (proofread--request-log-safe-diagnostic live)
                 :source-label)
                "new-model")))))))))

(ert-deftest
    proofread-test-profile-partial-results-keep-checker-duplicates
    ()
  "Do not merge identical internal diagnostics from different checkers."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checkers (plist-get profile :checkers))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (first-request
              (proofread--make-backend-request
               chunk proofread-test--backend (car checkers)
               profile))
             (second-request
              (proofread--make-backend-request
               chunk proofread-test--backend (cadr checkers)
               profile))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-partial-success-result
                      first-request (list diagnostic)))
                    'applied))
        (should (eq (proofread--handle-backend-result
                     (proofread--backend-partial-success-result
                      second-request (list (copy-sequence diagnostic))))
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list diagnostic diagnostic)))
        (should
         (equal (mapcar (lambda (live-diagnostic)
                          (plist-get live-diagnostic :checker-name))
                        proofread--diagnostics)
                '( first second)))))))

(ert-deftest
    proofread-test-profile-cache-key-distinguishes-checker-identity
    ()
  "Include checker names and options in diagnostic cache keys."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((profile '( :name multi :language "en-US"))
           (strict
            `( :profile multi
               :name strict
               :backend ,proofread-test--backend
               :options ( :tone formal)))
           (gentle
            `( :profile multi
               :name gentle
               :backend ,proofread-test--backend
               :options ( :tone formal)))
           (strict-relaxed
            `( :profile multi
               :name strict
               :backend ,proofread-test--backend
               :options ( :tone relaxed)))
           (chunk
            (car
             (proofread-test--request-ready-chunks-for-ranges
              (list (cons (point-min) (point-max))))))
           (strict-request
            (proofread--make-backend-request
             chunk proofread-test--backend strict profile))
           (gentle-request
            (proofread--make-backend-request
             chunk proofread-test--backend gentle profile))
           (strict-relaxed-request
            (proofread--make-backend-request
             chunk proofread-test--backend strict-relaxed profile)))
      (should-not (equal (plist-get strict-request :cache-key)
                         (plist-get gentle-request :cache-key)))
      (should-not (equal (plist-get strict-request :cache-key)
                         (plist-get strict-relaxed-request
                                    :cache-key))))))

(ert-deftest
    proofread-test-profile-cache-key-uses-backend-checker-identity ()
  "Let backend checker identity own raw checker options in cache keys."
  (let ((proofread--backend-registry (make-hash-table :test #'eq))
        identity-checkers)
    (proofread--register-backend
     proofread-test--backend
     :check (lambda (_request _callback) nil)
     :identity
     (lambda ()
       '( :backend proofread-test-backend
          :contract-version 1))
     :checker-identity
     (lambda (checker)
       (push (copy-sequence checker) identity-checkers)
       (list :backend proofread-test--backend
             :tone (plist-get (plist-get checker :options)
                              :tone)
             :contract-version 1)))
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-auto-check nil))
        (proofread-mode 1))
      (let* ((profile '( :name multi :language "en-US"))
             (formal-a
              `( :profile multi
                 :name local
                 :checker-ordinal 0
                 :backend ,proofread-test--backend
                 :options ( :tone formal
                            :secret "secret-a")))
             (formal-b
              `( :profile multi
                 :name local
                 :checker-ordinal 1
                 :backend ,proofread-test--backend
                 :options ( :tone formal
                            :secret "secret-b")))
             (relaxed
              `( :profile multi
                 :name local
                 :checker-ordinal 2
                 :backend ,proofread-test--backend
                 :options ( :tone relaxed
                            :secret "secret-a")))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (formal-a-request
              (proofread--make-backend-request
               chunk proofread-test--backend formal-a profile))
             (formal-b-request
              (proofread--make-backend-request
               chunk proofread-test--backend formal-b profile))
             (relaxed-request
              (proofread--make-backend-request
               chunk proofread-test--backend relaxed profile)))
        (should (equal (plist-get formal-a-request :cache-key)
                       (plist-get formal-b-request :cache-key)))
        (should-not (equal (plist-get formal-a-request :cache-key)
                           (plist-get relaxed-request :cache-key)))
        (should
         (cl-every
          (lambda (checker)
            (not (plist-member checker :checker-ordinal)))
          identity-checkers))
        (should-not
         (string-match-p
          (regexp-quote "secret-a")
          (prin1-to-string
           (plist-get formal-a-request :cache-key))))))))

(ert-deftest proofread-test-cache-contract-v3-isolates-v0.1-namespace
    ()
  "Keep released v0.1 cache entries out of the current namespace."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
               (request
                (proofread-test--make-profile-request chunk))
               (new-key (plist-get request :cache-key))
               (v0.1-key
                (list
                 :text-hash (plist-get new-key :text-hash)
                 :language (plist-get new-key :language)
                 :major-mode (plist-get new-key :major-mode)
                 :target-policy (plist-get new-key :target-policy)
                 :target-kind (plist-get new-key :target-kind)
                 :backend (plist-get new-key :backend)
                 :contract-version 2
                 :context (plist-get new-key :context)
                 :response-schema '( :type "object"))))
          (should (= proofread--contract-version 3))
          (should (= (plist-get new-key :contract-version) 3))
          (should (plist-member new-key :checker))
          (should (plist-member new-key :display-language))
          (should-not (plist-member v0.1-key :checker))
          (should-not (plist-member v0.1-key :display-language))
          (should (plist-member v0.1-key :response-schema))
          (should (proofread--cache-write v0.1-key 'old-value))
          (should (eq (proofread--cache-read v0.1-key) 'old-value))
          (should-not (proofread--cache-read new-key)))))))

(ert-deftest proofread-test-request-requires-current-checker-provenance ()
  "Reject requests missing any current checker provenance field."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
               (request
                (proofread-test--make-profile-request chunk)))
          (should (proofread--request-current-checker-p request))
          (should (proofread--fresh-request-p request))
          (dolist (field
                   '( :checker-name :checker-owner
                      :checker-options :checker-identity))
            (let ((incomplete-request (copy-tree request)))
              (cl-remf incomplete-request field)
              (should
               (proofread--request-current-backend-identity-p
                incomplete-request))
              (should-not
               (proofread--request-current-checker-p incomplete-request))
              (should-not
               (proofread--fresh-request-p incomplete-request)))))))))

(ert-deftest
    proofread-test-profile-checker-change-makes-request-stale
    ()
  "Ignore legacy language changes but reject checker identity changes."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name strict
                 :backend ,proofread-test--backend
                 :options ( :tone formal)))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile)))
        (proofread-test--with-legacy-options nil "global-change"
          (should (proofread--fresh-request-p request)))
        (let ((proofread-profiles
               `((multi
                  :language "en-US"
                  :checkers
                  (( :name strict
                     :backend ,proofread-test--backend
                     :options ( :tone relaxed)))))))
          (should-not (proofread--fresh-request-p request)))))))

(ert-deftest
    proofread-test-profile-display-language-affects-cache-and-freshness
    ()
  "Invalidate request and cache identity after display language changes."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :display-language "English"
              :checkers
              (( :name strict
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend checker profile))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 6 "Alpha")))
        (should (equal (plist-get request :display-language)
                       "English"))
        (proofread--cache-write-request request (list diagnostic))
        (let ((proofread-profiles
               `((multi
                  :language "en-US"
                  :display-language "American English"
                  :checkers
                  (( :name strict
                     :backend ,proofread-test--backend))))))
          (should-not (proofread--fresh-request-p request))
          (let* ((changed-profile (proofread--current-profile))
                 (changed-checker
                  (car (plist-get changed-profile :checkers)))
                 (changed-request
                  (proofread--make-backend-request
                   chunk proofread-test--backend changed-checker
                   changed-profile)))
            (should (equal (plist-get changed-request :language)
                           (plist-get request :language)))
            (should (equal
                     (plist-get changed-request :display-language)
                     "American English"))
            (should-not
             (equal (plist-get changed-request :cache-key)
                    (plist-get request :cache-key)))
            (should-not
             (proofread--cache-read-request changed-request))))))))

(ert-deftest
    proofread-test-profile-checkers-share-global-concurrency-limit
    ()
  "Apply the buffer-wide request limit across profile checkers."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :language "en-US"
              :checkers
              (( :name first
                 :backend ,proofread-test--backend)
               ( :name second
                 :backend ,proofread-test--backend))))))
      (proofread-mode 1)
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (lambda (request _callback &optional _backend)
                   (list :backend proofread-test--backend
                         :request-id (plist-get request :id)))))
        (proofread-check-region (point-min) (point-max))
        (should (= (length proofread--active-requests) 1))
        (should (= (length proofread--request-queue) 1))
        (let ((owners
               (mapcar
                (lambda (request)
                  (plist-get request :checker-name))
                (append
                 proofread--active-requests
                 (mapcar (lambda (entry)
                           (plist-get entry :request))
                         proofread--request-queue)))))
          (should (equal (sort owners
                               (lambda (left right)
                                 (string< (symbol-name left)
                                          (symbol-name right))))
                         '( first second))))))))

;;;; Backend and scheduler tests

(ert-deftest proofread-test-backend-handles-are-opaque ()
  "Pass provider-neutral backend handles unchanged to their adapter."
  (dolist (case (proofread-test--opaque-handle-cases))
    (let* ((backend 'proofread-test-opaque-backend)
           (kind (plist-get case :kind))
           (handle (plist-get case :handle))
           (printed-handle (prin1-to-string handle))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           cancelled)
      (pcase kind
        ('symbol (should (symbolp handle)))
        ('vector
         (should (vectorp handle))
         (should-not (recordp handle)))
        ('record (should (recordp handle)))
        ('plist (should (listp handle))))
      (proofread-test--register-cancellable-backend
       backend
       (lambda (_request _callback)
         handle)
       (lambda (backend-handle)
         (push backend-handle cancelled)))
      (with-temp-buffer
        (text-mode)
        (insert "Alpha")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 0)
              (proofread-context-size 0)
              (proofread-profile 'opaque)
              (proofread-profiles
               (list
                (list
                 'opaque
                 :language "en-US"
                 :checkers
                 (list (list :name 'opaque :backend backend))))))
          (proofread-mode 1)
          (proofread-check-buffer)
          (should (= (length proofread--active-requests) 1))
          (let ((request (car proofread--active-requests)))
            (proofread--clear-request-work)
            (should (= (length cancelled) 1))
            (should (eq (car cancelled) handle))
            (should (equal (prin1-to-string handle)
                           printed-handle))
            (should
             (proofread--request-state-flag-p request :cancelled))
            (proofread-test--assert-no-pending-request-work)
            (proofread--clear-request-work)
            (should (= (length cancelled) 1))))))))

(ert-deftest
    proofread-test-cancellation-keeps-submission-adapter ()
  "Use the captured cancel adapter after registry replacement or removal."
  (dolist (transition '( unregister reregister))
    (let* ((backend 'proofread-test-snapshot-backend)
           (handle (make-symbol "proofread-test-snapshot-handle"))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           old-cancelled
           new-cancelled)
      (proofread-test--register-cancellable-backend
       backend
       (lambda (_request _callback)
         handle)
       (lambda (backend-handle)
         (push backend-handle old-cancelled)))
      (with-temp-buffer
        (insert "Alpha")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 0)
              (proofread-context-size 0)
              (proofread-profile 'snapshot)
              (proofread-profiles
               (list
                (list
                 'snapshot
                 :language "en-US"
                 :checkers
                 (list (list :name 'snapshot :backend backend))))))
          (proofread-mode 1)
          (proofread-check-buffer)
          (should (= (length proofread--active-requests) 1))
          (let ((request (car proofread--active-requests)))
            (pcase transition
              ('unregister
               (proofread--unregister-backend backend))
              ('reregister
               (proofread-test--register-cancellable-backend
                backend
                (lambda (&rest _)
                  (error "Replacement backend must not run"))
                (lambda (backend-handle)
                  (push backend-handle new-cancelled)))))
            (proofread--clear-request-work)
            (should (= (length old-cancelled) 1))
            (should (eq (car old-cancelled) handle))
            (should-not new-cancelled)
            (should
             (proofread--request-state-flag-p request :cancelled))
            (proofread-test--assert-no-pending-request-work)))))))

(ert-deftest
    proofread-test-cancel-error-does-not-block-or-repeat-cleanup ()
  "Continue cleanup after one cancel error and never retry it."
  (let* ((backend 'proofread-test-throwing-cancel-backend)
         (proofread--backend-registry
          (make-hash-table :test #'eq))
         submitted
         cancelled
         reports
         raised)
    (proofread-test--register-cancellable-backend
     backend
     (lambda (_request _callback)
       (let ((handle
              (make-symbol "proofread-test-throwing-handle")))
         (push handle submitted)
         handle))
     (lambda (handle)
       (push handle cancelled)
       (unless raised
         (setq raised t)
         (error "Simulated cancellation failure"))))
    (with-temp-buffer
      (text-mode)
      (insert "One. Two. Three.")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread-max-concurrent-requests 20)
            (proofread-profile 'throwing)
            (proofread-profiles
             (list
              (list
               'throwing
               :language "en-US"
               :checkers
               (list (list :name 'throwing :backend backend))))))
        (proofread-mode 1)
        (proofread-check-buffer)
        (should (= (length submitted) 3))
        (should (= (length proofread--active-requests) 3))
        (let ((requests (copy-sequence proofread--active-requests)))
          (cl-letf
              (((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports))))
            (proofread--clear-request-work)
            (should (= (length cancelled) 3))
            (should (= (length reports) 1))
            (should
             (equal (caar reports)
                    "Proofread backend cancellation failed (error)"))
            (should
             (equal (cadar reports)
                    "backend cancellation failed; see *Warnings*"))
            (proofread-test--assert-secret-not-printed
             "Simulated cancellation failure" reports)
            (dolist (handle submitted)
              (should (= (cl-count handle cancelled :test #'eq) 1)))
            (let ((cancel-count (length cancelled)))
              (proofread--clear-request-work)
              (should (= (length cancelled) cancel-count))
              (should (= (length reports) 1))))
          (should raised)
          (dolist (request requests)
            (should
             (proofread--request-state-flag-p request :cancelled)))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest
    proofread-test-terminal-event-settles-when-hook-warning-signals ()
  "Settle final and cancelled batches after hook reporting signals."
  (dolist (type '( final-result cancelled))
    (with-temp-buffer
      (let* ((request
              (proofread-test--lifecycle-request
               (if (eq type 'final-result) 501 502) 1 2))
             (batch (proofread--attach-request-batch (list request)))
             (proofread-request-log-hook
              (list
               (lambda (_event)
                 (error "Sensitive request hook failure"))))
             reports)
        (cl-letf
            (((symbol-function
               'proofread-report-warning-without-window)
              (lambda (detail summary)
                (push (list detail summary) reports)
                (error "Warning reporter failure"))))
          (should-error
           (pcase type
             ('final-result
              (proofread--record-request-event
               request type
               :result
               (proofread--backend-success-result request nil)
               :status 'applied))
             ('cancelled
              (proofread--record-request-event
               request type :reason 'cleared)))))
        (should (= (length reports) 1))
        (should
         (equal (caar reports)
                "Proofread request log hook error (error)"))
        (proofread-test--assert-secret-not-printed
         "Sensitive request hook failure" reports)
        (should (zerop (plist-get batch :pending)))
        (should
         (plist-get (plist-get request :state) :batch-settled))))))

(ert-deftest proofread-test-core-timers-stay-core-owned ()
  "Cancel core timers directly and backend timers through their adapter."
  (let* ((backend 'proofread-test-timer-backend)
         (backend-timer 'proofread-test-backend-timer)
         (core-idle-timer 'proofread-test-core-idle-timer)
         (core-queue-timer 'proofread-test-core-queue-timer)
         (proofread--backend-registry
          (make-hash-table :test #'eq))
         adapter-cancelled
         directly-cancelled)
    (proofread-test--register-cancellable-backend
     backend
     (lambda (_request _callback)
       backend-timer)
     (lambda (handle)
       (push handle adapter-cancelled)))
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread-profile 'timers)
            (proofread-profiles
             (list
              (list
               'timers
               :language "en-US"
               :checkers
               (list (list :name 'timers :backend backend))))))
        (proofread-mode 1)
        (proofread-check-buffer)
        (should (= (length proofread--active-requests) 1))
        (let ((request (car proofread--active-requests)))
          (setq proofread--idle-timer core-idle-timer)
          (setq proofread--queue-dispatch-timer core-queue-timer)
          (cl-letf (((symbol-function 'timerp)
                     (lambda (object)
                       (memq object
                             (list backend-timer
                                   core-idle-timer
                                   core-queue-timer))))
                    ((symbol-function 'cancel-timer)
                     (lambda (timer)
                       (push timer directly-cancelled))))
            (proofread--clear-request-work)
            (proofread--clear-request-work))
          (should (= (length adapter-cancelled) 1))
          (should (eq (car adapter-cancelled) backend-timer))
          (should (= (length directly-cancelled) 2))
          (should
           (= (cl-count core-idle-timer directly-cancelled
                        :test #'eq)
              1))
          (should
           (= (cl-count core-queue-timer directly-cancelled
                        :test #'eq)
              1))
          (should-not (memq backend-timer directly-cancelled))
          (should
           (proofread--request-state-flag-p request :cancelled))
          (should-not proofread--idle-timer)
          (should-not proofread--queue-dispatch-timer)
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-backend-registry-routes-adapter-functions
    ()
  "Route backend operations through a registered adapter descriptor."
  (let* ((proofread--backend-registry
          (make-hash-table :test #'eq))
         (cancel (lambda (_handle)
                   (error "Unexpected cancellation")))
         checked
         result)
    (proofread--register-backend
     proofread-test--backend
     :check
     (lambda (request callback)
       (setq checked request)
       (run-at-time
        0 nil callback
        (proofread--backend-success-result request nil))
       'proofread-test-registry-handle)
     :identity
     (lambda ()
       '( :backend proofread-test-backend :contract-version 1))
     :cancel cancel)
    (should (proofread--supported-backend-p proofread-test--backend))
    (should
     (eq
      (plist-get
       (gethash proofread-test--backend
                proofread--backend-registry)
       :cancel)
      cancel))
    (should (equal (proofread--backend-identity
                    proofread-test--backend)
                   '( :backend proofread-test-backend
                      :contract-version 1)))
    (let* ((request '( :id 1))
           (handle
            (proofread--backend-check
             request
             (lambda (backend-result)
               (setq result backend-result))
             proofread-test--backend)))
      (should (eq checked request))
      (should (eq handle 'proofread-test-registry-handle))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'ok)))
    (proofread--unregister-backend proofread-test--backend)
    (should-not
     (proofread--supported-backend-p proofread-test--backend))))

(ert-deftest proofread-test-backend-registry-validates-source-label
    ()
  "Reject a non-callable backend source-label operation."
  (let ((proofread--backend-registry (make-hash-table :test #'eq)))
    (should-error
     (proofread--register-backend
      proofread-test--backend
      :check #'ignore
      :identity #'proofread-test--backend-identity
      :source-label 'not-callable))
    (should-not
     (gethash proofread-test--backend proofread--backend-registry))))

(ert-deftest proofread-test-backend-registry-lazily-loads-feature ()
  "Load a known backend feature once before resolving its descriptor."
  (let ((proofread--backend-features
         '((proofread-test-lazy . proofread-test-lazy-feature)))
        (proofread--backend-registry (make-hash-table :test #'eq))
        loaded-feature)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (setq loaded-feature feature)
                 (proofread--register-backend
                  'proofread-test-lazy
                  :check (lambda (_request _callback) 'test-handle)
                  :identity
                  (lambda ()
                    '( :backend proofread-test-lazy
                       :contract-version 1)))
                 t)))
      (should (proofread--supported-backend-p 'proofread-test-lazy))
      (should (eq loaded-feature 'proofread-test-lazy-feature))
      (setq loaded-feature nil)
      (should (proofread--supported-backend-p 'proofread-test-lazy))
      (should-not loaded-feature))))

(ert-deftest proofread-test-supported-backend ()
  "Registered backend symbols are supported."
  (should (proofread--supported-backend-p proofread-test--backend))
  (should-not
   (proofread--supported-backend-p 'unknown-backend)))

(ert-deftest proofread-test-unknown-backend-is-unsupported ()
  "Unknown backend symbols use unsupported dispatch."
  (with-temp-buffer
    (insert "helo")
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request
            (proofread--make-backend-request
             chunk 'unknown-backend))
           result)
      (should-not (proofread--supported-backend-p 'unknown-backend))
      (should (proofread--backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'unknown-backend))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :request) request))
      (should (eq (plist-get result :error) 'unsupported-backend)))))

(ert-deftest proofread-test-cache-key-excludes-volatile-values ()
  "Cache keys exclude volatile buffer objects."
  (with-temp-buffer
    (let* ((proofread-test--backend-identity-token "identity-a")
           (chunk (list :text "青晨"
                        :language "zh"
                        :major-mode 'org-mode
                        :buffer (current-buffer)
                        :callback #'ignore))
           (key (proofread--cache-key
                 chunk proofread-test--backend)))
      (should-not (plist-member key :buffer))
      (should-not (plist-member key :callback))
      (should-not (proofread-test--tree-member-p (current-buffer)
                                                 key))
      (should-not (string-match-p (buffer-name) (prin1-to-string
                                                 key))))))

(ert-deftest proofread-test-backend-request-records-chunk-fields ()
  "Backend requests preserve request-ready chunk metadata."
  (with-temp-buffer
    (text-mode)
    (let ((proofread-test--profile-language "en")
          (proofread-context-size 3))
      (insert "abcTARGETxyz")
      (proofread-test--with-profile
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((4 . 10)))))
               (request (proofread-test--make-profile-request chunk)))
          (dolist (key proofread--backend-request-keys)
            (should (plist-member request key)))
          (should (integerp (plist-get request :id)))
          (should (eq (plist-get request :buffer) (current-buffer)))
          (should (= (plist-get request :beg) 4))
          (should (= (plist-get request :end) 10))
          (should (equal (plist-get request :text) "TARGET"))
          (should (equal (plist-get request :context-before) "abc"))
          (should (equal (plist-get request :context-after) "xyz"))
          (should (equal (plist-get request :language) "en"))
          (should (eq (plist-get request :major-mode) 'text-mode)))))))

(ert-deftest proofread-test-unsupported-backend-error-is-asynchronous
    ()
  "Unsupported backends report an asynchronous protocol error."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request chunk))
           result)
      (should (proofread--backend-check
               request
               (lambda (backend-result)
                 (setq result backend-result))
               'unknown-backend))
      (should-not result)
      (should (proofread-test--wait-for (lambda () result)))
      (should (eq (plist-get result :status) 'error))
      (should (eq (plist-get result :request) request))
      (should (eq (plist-get result :error) 'unsupported-backend)))))

(ert-deftest proofread-test-backend-success-clears-active-request ()
  "Successful backend callbacks clear active request state first."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-test--with-profile-success
        nil
      (let* ((buffer (current-buffer))
             (chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             result
             active-at-callback)
        (should (proofread--dispatch-backend-request
                 request
                 (lambda (backend-result)
                   (setq result backend-result)
                   (with-current-buffer buffer
                     (setq active-at-callback
                           proofread--active-requests)))
                 proofread-test--backend))
        (should (proofread--active-request-p request))
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'ok))
        (should-not active-at-callback)
        (should-not (proofread--active-request-p request))))))

(ert-deftest
    proofread-test-backend-error-preserves-buffer-and-clears-request
    ()
  "Preserve text and clear active state after backend errors."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (proofread-test--with-profile-error
        'proofread-test-backend-failure "Test backend failure"
      (let* ((buffer (current-buffer))
             (before-text (buffer-string))
             (chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             result
             active-at-callback)
        (should
         (proofread--dispatch-backend-request
          request
          (lambda (backend-result)
            (setq result backend-result)
            (with-current-buffer buffer
              (setq active-at-callback
                    proofread--active-requests)))
          proofread-test--backend))
        (should (proofread--active-request-p request))
        (should
         (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (equal (buffer-string) before-text))
        (should-not active-at-callback)
        (should-not
         (proofread--active-request-p request))))))

(ert-deftest
    proofread-test-check-visible-range-dispatches-ready-chunks ()
  "Dispatch filtered chunks from the visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-dispatch*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha http://example.com/path Beta")
            (proofread-mode 1)
            (let ((proofread-context-size 0)
                  requests
                  callbacks)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (request callback &optional
                                            _backend)
                             (push request requests)
                             (push callback callbacks)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (setq requests (nreverse requests))
                  (should (equal (mapcar (lambda (request)
                                           (plist-get request :text))
                                         requests)
                                 '( "Alpha " " Beta")))
                  (should (= (length callbacks) 2))
                  (should (= (length proofread--active-requests) 2))
                  (should-not proofread--diagnostics)
                  (should-not proofread--overlays)))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-check-visible-range-dispatches-sentence-chunks ()
  "Dispatch sentence-level chunks from the visible range."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-visible-sentences*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert (concat "青晨六点半，小城的街到刚刚醒来。"
                            "卖豆浆的滩主把炉子推到巷口。"
                            "几个上班的人撑着伞从桥边经过。"))
            (proofread-mode 1)
            (let ((proofread-context-size 0)
                  (proofread-max-concurrent-requests 10)
                  requests
                  callbacks)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (request callback &optional
                                            _backend)
                             (push request requests)
                             (push callback callbacks)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (setq requests (nreverse requests))
                  (should (equal
                           (mapcar (lambda (request)
                                     (plist-get request :text))
                                   requests)
                           '( "青晨六点半，小城的街到刚刚醒来。"
                              "卖豆浆的滩主把炉子推到巷口。"
                              "几个上班的人撑着伞从桥边经过。")))
                  (dolist (request requests)
                    (should (equal
                             (plist-get request :text)
                             (buffer-substring-no-properties
                              (plist-get request :beg)
                              (plist-get request :end)))))
                  (should (= (length callbacks) 3))
                  (should (= (length proofread--active-requests)
                             3))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-max-concurrent-requests-queues-extra-work
    ()
  "Limit active backend requests with the concurrency option."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-visible-queue*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert (concat "第一句。"
                            "第二句。"
                            "第三句。"))
            (proofread-mode 1)
            (let ((proofread-context-size 0)
                  (proofread-max-concurrent-requests 2)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name
                         buffer)))
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (plist-get recorder :function)))
                  (proofread-show-buffer-requests buffer)
                  (proofread-check-visible-range)
                  (should (= (length (funcall
                                      (plist-get recorder :requests)))
                             2))
                  (should (= (length proofread--active-requests) 2))
                  (should (= (length proofread--request-queue) 1))
                  (proofread-check-visible-range)
                  (should (= (length (funcall
                                      (plist-get recorder :requests)))
                             2))
                  (should (= (length proofread--active-requests) 2))
                  (should (= (length proofread--request-queue) 1))
                  (proofread-test--flush-request-log-refresh buffer)
                  (with-current-buffer name
                    (let ((statuses (mapcar (lambda (entry)
                                              (aref (cadr entry) 1))
                                            tabulated-list-entries)))
                      (should (= (length statuses) 3))
                      (should (= (cl-count "waiting" statuses
                                           :test #'equal)
                                 2))
                      (should (member "queued" statuses))))
                  (let* ((requests (funcall (plist-get recorder
                                                       :requests)))
                         (callbacks (funcall (plist-get recorder
                                                        :callbacks)))
                         (first-request (car requests))
                         (second-request (cadr requests))
                         (first-callback (car callbacks)))
                    (should (eq (funcall
                                 first-callback
                                 (proofread--backend-success-result
                                  first-request nil))
                                'applied))
                    (let* ((all-requests (funcall
                                          (plist-get recorder
                                                     :requests)))
                           (third-request (caddr all-requests))
                           (active-ids
                            (mapcar (lambda (request)
                                      (plist-get request :id))
                                    proofread--active-requests)))
                      (should (= (length all-requests) 3))
                      (should (= (length proofread--active-requests)
                                 2))
                      (should-not proofread--request-queue)
                      (proofread-test--flush-request-log-refresh
                       buffer)
                      (with-current-buffer name
                        (let ((statuses
                               (mapcar (lambda (entry)
                                         (aref (cadr entry) 1))
                                       tabulated-list-entries)))
                          (should (member "applied" statuses))
                          (should (= (cl-count "waiting" statuses
                                               :test #'equal)
                                     2))
                          (should-not (member "queued" statuses))))
                      (should-not
                       (member (plist-get first-request :id)
                               active-ids))
                      (should (member (plist-get second-request :id)
                                      active-ids))
                      (should (member (plist-get third-request :id)
                                      active-ids))))))))
        (when-let*
            ((list-buffer
              (get-buffer
               (proofread--request-log-list-buffer-name buffer))))
          (kill-buffer list-buffer))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-active-requests-remain-buffer-local ()
  "Keep profile-owned active requests isolated between buffers."
  (let ((first-buffer (generate-new-buffer " *proofread-requests-a*"))
        (second-buffer (generate-new-buffer
                        " *proofread-requests-b*"))
        (proofread-profiles
         `((first-profile
            :language "en-US"
            :checkers (( :name first-checker
                         :backend ,proofread-test--backend)))
           (second-profile
            :language "zh-Hans"
            :checkers (( :name second-checker
                         :backend ,proofread-test--backend))))))
    (unwind-protect
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (_request _callback &optional _backend)
                     'proofread-test-handle)))
          (with-current-buffer first-buffer
            (setq-local proofread-profile 'first-profile)
            (insert "Alpha")
            (proofread-mode 1)
            (proofread-test--dispatch-profile-chunks
             (proofread-test--request-ready-chunks-for-ranges
              (list (cons (point-min) (point-max))))))
          (with-current-buffer second-buffer
            (setq-local proofread-profile 'second-profile)
            (insert "Beta")
            (proofread-mode 1)
            (proofread-test--dispatch-profile-chunks
             (proofread-test--request-ready-chunks-for-ranges
              (list (cons (point-min) (point-max))))))
          (with-current-buffer first-buffer
            (should (= (length proofread--active-requests) 1))
            (let ((request (car proofread--active-requests)))
              (should (eq (plist-get request :buffer) first-buffer))
              (should (eq (plist-get request :profile)
                          'first-profile))
              (should (eq (plist-get request :checker-name)
                          'first-checker))))
          (with-current-buffer second-buffer
            (should (= (length proofread--active-requests) 1))
            (let ((request (car proofread--active-requests)))
              (should (eq (plist-get request :buffer) second-buffer))
              (should (eq (plist-get request :profile)
                          'second-profile))
              (should (eq (plist-get request :checker-name)
                          'second-checker)))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest
    proofread-test-fresh-result-records-diagnostics-and-overlays ()
  "Fresh successful results record diagnostics and create overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-fresh-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (should (proofread--active-request-p request))
                  (let ((diagnostic
                         (proofread-test--diagnostic-for-range
                          1 5 "helo")))
                    (should (eq (funcall
                                 callback
                                 (proofread--backend-success-result
                                  request (list diagnostic)))
                                'applied))
                    (should
                     (equal
                      (proofread-test--diagnostics-without-provenance
                       proofread--diagnostics)
                      (list diagnostic)))
                    (should (= (length proofread--overlays) 1))
                    (should
                     (overlay-buffer (car proofread--overlays)))
                    (should-not (proofread--active-request-p
                                 request)))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-live-range-does-not-mutate-backend-result
    ()
  "Keep backend results immutable when overlays move."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo"))
             (result
              (proofread--backend-success-result
               request (list diagnostic))))
        (should (eq (proofread--handle-backend-result result)
                    'applied))
        (let ((live (car proofread--diagnostics)))
          (should-not (eq live diagnostic))
          (goto-char (point-min))
          (insert "x")
          (should (equal (proofread--diagnostic-range live)
                         '( 2 . 6)))
          (should
           (equal (proofread--diagnostic-range diagnostic)
                  '( 1 . 5)))
          (should (eq (car (plist-get result :diagnostics))
                      diagnostic)))))))

(ert-deftest
    proofread-test-context-does-not-shift-diagnostic-overlays ()
  "Do not shift accepted overlays for sentence-window context."
  (with-temp-buffer
    (insert "前文。目标句。后文。")
    (proofread-mode 1)
    (let ((proofread-test--profile-language "zh")
          (proofread-context-size 300))
      (proofread-test--with-profile
        (let* ((chunk
                (proofread-test--chunk-with-text
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))
                 "目标句。"))
               (request (proofread-test--make-profile-request chunk))
               (diagnostic
                (proofread-test--diagnostic-for-range
                 (plist-get request :beg)
                 (+ (plist-get request :beg) 2)
                 "目标")))
          (should (equal (plist-get request :context-before) "前文。"))
          (should (equal (plist-get request :context-after) "后文。"))
          (should (eq (proofread--handle-backend-result
                       (proofread--backend-success-result
                        request (list diagnostic)))
                      'applied))
          (should (= (length proofread--overlays) 1))
          (let ((overlay (car proofread--overlays)))
            (should (= (overlay-start overlay)
                       (plist-get diagnostic :beg)))
            (should (= (overlay-end overlay)
                       (plist-get diagnostic :end)))))))))

(ert-deftest proofread-test-killed-buffer-result-is-dropped ()
  "Results for killed buffers are dropped without recreating state."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-killed-result*"))
          request
          callback)
      (switch-to-buffer buffer)
      (insert "helo world")
      (proofread-mode 1)
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'window-start)
                   (lambda (&optional _window) (point-min)))
                  ((symbol-function 'window-end)
                   (lambda (&optional _window _update) (point-max)))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (backend-request
                            backend-callback
                            &optional _backend)
                     (setq request backend-request)
                     (setq callback backend-callback)
                     'proofread-test-handle)))
          (proofread-check-visible-range)))
      (kill-buffer buffer)
      (should-not (buffer-live-p buffer))
      (should (eq (funcall
                   callback
                   (proofread--backend-success-result
                    request
                    (list
                     (proofread-test--diagnostic-for-range
                      1 5 "helo"))))
                  'stale)))))

(ert-deftest proofread-test-disabled-mode-result-is-dropped ()
  "Do not mutate proofread state after disabling the mode."
  (save-window-excursion
    (let ((buffer (generate-new-buffer
                   " *proofread-disabled-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (proofread-mode -1)
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                request
                                (list
                                 (proofread-test--diagnostic-for-range
                                  1 5 "helo"))))
                              'stale))
                  (should-not proofread--diagnostics)
                  (should-not proofread--overlays)
                  (should-not proofread--active-requests)))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-context-change-result-is-dropped ()
  "Results are stale after their surrounding context changes."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-tick-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update) 5))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (goto-char (point-max))
                  (insert "!")
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                request
                                (list
                                 (proofread-test--diagnostic-for-range
                                  1 5 "helo"))))
                              'stale))
                  (should-not proofread--diagnostics)
                  (should-not proofread--overlays)
                  (should-not (proofread--active-request-p
                               request))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-text-mismatch-result-is-dropped ()
  "Results are stale when the request range text no longer matches."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-text-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update) 5))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (delete-region 1 5)
                  (insert "hello")
                  (should (eq (funcall
                               callback
                               (proofread--backend-success-result
                                request
                                (list
                                 (proofread-test--diagnostic-for-range
                                  1 6 "hello"))))
                              'stale))
                  (should-not proofread--diagnostics)
                  (should-not proofread--overlays)
                  (should-not (proofread--active-request-p
                               request))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-backend-error-result-creates-no-overlays
    ()
  "Backend error results preserve text and create no overlays."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-error-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((before-text (buffer-string))
                  request
                  callback)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request
                                    backend-callback
                                    &optional _backend)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (should (eq (funcall
                               callback
                               (proofread--backend-error-result
                                request 'proofread-test-backend-failure
                                "Test backend failure"))
                              'error))
                  (should (equal (buffer-string) before-text))
                  (should-not proofread--diagnostics)
                  (should-not proofread--overlays)
                  (should-not (proofread--active-request-p
                               request))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-warning-report-preserves-detail-and-shortens-echo
    ()
  "Log full background warnings but echo a short summary."
  (let* ((detail (concat "Backend detail line one\n"
                         (make-string 600 ?x)))
         (summary (concat "backend request failed\n"
                          (make-string 600 ?y)))
         captured-echo
         captured-minimum-level
         captured-truncation
         captured-warning-args)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args)
                 (setq captured-minimum-level warning-minimum-level)
                 (setq captured-warning-args args)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq captured-truncation message-truncate-lines)
                 (setq captured-echo
                       (apply #'format format-string args)))))
      (proofread-report-warning-without-window detail summary))
    (should (equal captured-warning-args
                   (list 'proofread detail :warning)))
    (should (eq captured-minimum-level :error))
    (should captured-truncation)
    (should (string-prefix-p "proofread: backend request failed "
                             captured-echo))
    (should (<= (string-width captured-echo) 120))
    (should-not (string-match-p "[\n\r]" captured-echo))))

(ert-deftest
    proofread-test-backend-errors-are-aggregated-per-request-batch ()
  "Aggregate production errors and settle cancelled batch work."
  (with-temp-buffer
    (text-mode)
    (insert "onee\n\ntwoo\n\nthree\n\nfourr")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 10)
          echo-truncation
          echoes
          captured-warning-levels
          warnings)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((ranges '((1 . 5) (7 . 11) (13 . 18) (20 . 25)))
               (chunks
                (mapcar
                 (lambda (range)
                   (car
                    (proofread-test--request-ready-chunks-for-ranges
                     (list range))))
                 ranges))
               (recorder (proofread-test--make-backend-recorder)))
          (cl-letf (((symbol-function 'display-warning)
                     (lambda (&rest args)
                       (push warning-minimum-level
                             captured-warning-levels)
                       (push args warnings)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push message-truncate-lines echo-truncation)
                       (push (apply #'format format-string args)
                             echoes)))
                    ((symbol-function 'proofread--backend-check)
                     (plist-get recorder :function)))
            (should (= (length
                        (proofread-test--dispatch-profile-chunks
                         chunks))
                       4))
            (let ((requests (funcall (plist-get recorder :requests)))
                  (callbacks (funcall (plist-get recorder
                                                 :callbacks))))
              (should (= (length requests) 4))
              (should (cl-every
                       (lambda (request)
                         (plist-get
                          (plist-get request :state)
                          :batch))
                       requests))
              (dotimes (index 4)
                (funcall
                 (nth index callbacks)
                 (proofread--backend-error-result
                  (nth index requests)
                  'proofread-test-backend-invalid-diagnostics
                  (format "Failure kind %d" index)))
                (should (= (length warnings) (if (= index 3) 1 0))))
              (let ((message (nth 1 (car warnings))))
                (should (string-match-p "4 requests" message))
                (should
                 (string-match-p
                  (regexp-quote
                   (concat
                    "Proofreading backend error "
                    "(proofread-test-backend-invalid-diagnostics) "
                    "(x4)"))
                  message))
                (should-not
                 (string-match-p "Failure kind" message))
                (should-not
                 (string-match-p "more error kind" message))))
            (let ((second-recorder
                   (proofread-test--make-backend-recorder)))
              (cl-letf (((symbol-function 'proofread--backend-check)
                         (plist-get second-recorder :function)))
                (proofread-test--dispatch-profile-chunks
                 (cl-subseq chunks 0 2))
                (let ((requests
                       (funcall
                        (plist-get second-recorder :requests)))
                      (callbacks
                       (funcall (plist-get second-recorder
                                           :callbacks))))
                  (funcall
                   (car callbacks)
                   (proofread--backend-error-result
                    (car requests)
                    'proofread-test-backend-failure
                    "One failure"))
                  (should (= (length warnings) 1))
                  (proofread--retire-active-request
                   (cadr requests) nil 'test-cancelled)
                  (should (= (length warnings) 2)))))
            (let ((direct
                   (proofread-test--make-profile-request
                    (car chunks))))
              (should
               (eq (proofread--handle-backend-result
                    (proofread--backend-error-result
                     direct
                     'proofread-test-backend-failure
                     "Direct failure"))
                   'error))
              (should (= (length warnings) 3))
              (should (equal captured-warning-levels
                             '( :error :error :error)))
              (should (equal echo-truncation '( t t t)))
              (should (= (length echoes) 3))
              (dolist (raw-message
                       '( "Failure kind" "One failure"
                          "Direct failure"))
                (proofread-test--assert-secret-not-printed
                 raw-message warnings))
              (should (cl-every
                       (lambda (echo)
                         (and (< (string-width echo) 80)
                              (not (string-match-p "[\n\r]" echo))))
                       echoes)))))))))

;;;; Navigation and presentation tests

(ert-deftest
    proofread-test-public-diagnostic-message-entries-are-detached
    ()
  "Expose ordered backend sources without leaking diagnostic storage."
  (let* ((first-message (propertize "First message" 'face 'bold))
         (second-message '( structured "Second message"))
         (first
          (plist-put
           (proofread--make-diagnostic
            :beg 1 :end 5 :text "helo" :kind 'grammar
            :message first-message :suggestions nil :source 'raw-first)
           :source-label
           (propertize "model-a" 'face 'italic)))
         (second
          (proofread--make-diagnostic
           :beg 1 :end 5 :text "helo" :kind 'style
           :message second-message :suggestions nil
           :source 'languagetool))
         (third
          (proofread--make-diagnostic
           :beg 1 :end 5 :text "helo" :kind 'spelling
           :message nil :suggestions nil
           :source (propertize "fallback" 'face 'underline)))
         (aggregate
          (list :proofread-aggregate t
                :diagnostics (list first second third)))
         (entries
          (proofread-diagnostic-message-entries aggregate))
         (singleton
          (proofread-diagnostic-message-entries first)))
    (should
     (equal
      entries
      '(( :source "model-a" :message "First message")
        ( :source "languagetool"
          :message ( structured "Second message"))
        ( :source "fallback" :message nil))))
    (should (equal singleton (list (car entries))))
    (dolist (entry entries)
      (should-not
       (text-properties-at 0 (plist-get entry :source))))
    (aset (plist-get (car entries) :source) 0 ?X)
    (aset (plist-get (car entries) :message) 0 ?X)
    (setcar (plist-get (cadr entries) :message) 'changed)
    (should (equal (plist-get first :source-label) "model-a"))
    (should (equal (plist-get first :message) "First message"))
    (should (equal (plist-get second :message)
                   '( structured "Second message")))))

(ert-deftest
    proofread-test-navigation-preserves-equal-checker-ordinal-order
    ()
  "Preserve backend order for equal-range diagnostics from one checker."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-checker
            (proofread--make-diagnostic
             :beg 1 :end 5 :text "helo" :kind 'grammar
             :message "First" :suggestions nil :source 'test)
            'same))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread--make-diagnostic
             :beg 1 :end 5 :text "helo" :kind 'style
             :message "Second" :suggestions nil :source 'test)
            'same)))
      (setq first (plist-put first :checker-ordinal 0))
      (setq second (plist-put second :checker-ordinal 0))
      (proofread-test--install-diagnostics (list first second))
      (should
       (equal
        (proofread--diagnostic-members
         (car (proofread--navigation-diagnostics)))
        (list first second)))
      (goto-char 2)
      (should
       (equal
        (proofread--diagnostic-members
         (proofread-diagnostic-at-point))
        (list first second))))))

(ert-deftest proofread-test-navigation-sorts-and-filters-diagnostics
    ()
  "Sort valid navigation diagnostics by start and end."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((marker (copy-marker 2))
           (first (proofread-test--diagnostic-for-range marker 5
                                                        "bcd"))
           (same-start-short
            (proofread-test--diagnostic-for-range 4 6 "de"))
           (same-start-long
            (proofread-test--diagnostic-for-range 4 9 "defgh"))
           (last (proofread-test--diagnostic-for-range 8 10 "hi"))
           (invalid-beg
            (proofread-test--diagnostic-for-range 'not-a-position 3
                                                  ""))
           (invalid-backward
            (proofread-test--diagnostic-for-range 7 6 "")))
      (setq proofread--diagnostics
            (list same-start-long invalid-beg last invalid-backward
                  same-start-short first))
      (mapc #'proofread--create-overlay
            (list same-start-long last same-start-short first))
      (should (equal (mapcar #'proofread--diagnostic-range
                             (proofread--navigation-diagnostics))
                     '((2 . 5) (4 . 6) (4 . 9) (8 . 10)))))))

(ert-deftest proofread-test-navigation-target-selection-around-point
    ()
  "Select strict non-wrapping targets for next and previous moves."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (proofread-mode 1)
    (let* ((first (proofread-test--diagnostic-for-range 3 4 "c"))
           (second (proofread-test--diagnostic-for-range 6 7 "f"))
           (third (proofread-test--diagnostic-for-range 9 10 "i"))
           (invalid (proofread-test--diagnostic-for-range 12 11 "")))
      (setq proofread--diagnostics (list third invalid first second))
      (mapc #'proofread--create-overlay (list third first second))
      (should (eq (proofread--next-diagnostic-after 1) first))
      (should (eq (proofread--next-diagnostic-after 3) second))
      (should (eq (proofread--next-diagnostic-after 6) third))
      (should-not (proofread--next-diagnostic-after 9))
      (should-not (proofread--previous-diagnostic-before 3))
      (should (eq (proofread--previous-diagnostic-before 6) first))
      (should (eq (proofread--previous-diagnostic-before 9) second))
      (should (eq (proofread--previous-diagnostic-before 11)
                  third)))))

(ert-deftest
    proofread-test-proofread-next-moves-to-nearest-diagnostic ()
  "`proofread-next' moves point to the nearest later diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list second first))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (should (equal proofread--current-diagnostic first))
      (proofread-next)
      (should (= (point) 7))
      (should (equal proofread--current-diagnostic second)))))

(ert-deftest
    proofread-test-proofread-previous-moves-to-nearest-diagnostic ()
  "Move to the nearest earlier diagnostic with `proofread-previous'."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list second first))
      (goto-char (point-max))
      (proofread-previous)
      (should (= (point) 7))
      (should (equal proofread--current-diagnostic second))
      (proofread-previous)
      (should (= (point) 3))
      (should (equal proofread--current-diagnostic first)))))

(ert-deftest proofread-test-navigation-empty-diagnostics-keeps-point
    ()
  "Preserve point when navigation finds no diagnostics."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (goto-char 5)
    (let ((position (point))
          (text (buffer-string)))
      (should-error (proofread-next) :type 'user-error)
      (should (= (point) position))
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) position))
      (should (equal (buffer-string) text)))))

(ert-deftest proofread-test-navigation-boundaries-do-not-wrap ()
  "Navigation commands use a no-wrap boundary policy."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--install-diagnostics (list first second))
      (goto-char 7)
      (should-error (proofread-next) :type 'user-error)
      (should (= (point) 7))
      (goto-char 3)
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) 3)))))

(ert-deftest proofread-test-navigation-ignores-foreign-overlays ()
  "Navigate using proofread diagnostics, not unrelated overlays."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((foreign-overlay (make-overlay 2 3))
           (diagnostic (proofread-test--diagnostic-for-range 6 7
                                                             "f")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 6))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-navigation-marks-one-current-diagnostic ()
  "Mark exactly one owned diagnostic as current during navigation."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((first (proofread-test--diagnostic-for-range 3 4 "c"))
           (second (proofread-test--diagnostic-for-range 7 8 "g"))
           (foreign-overlay (make-overlay 1 2)))
      (overlay-put foreign-overlay 'face 'bold)
      (proofread-test--install-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                first)
                               'face)
                  'proofread-current-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                second)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get foreign-overlay 'face) 'bold))
      (proofread-next)
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                first)
                               'face)
                  'proofread-face))
      (should (eq (overlay-get (proofread--overlay-for-diagnostic
                                second)
                               'face)
                  'proofread-current-face))
      (should (= (cl-count 'proofread-current-face
                           (mapcar (lambda (overlay)
                                     (overlay-get overlay 'face))
                                   proofread--overlays))
                 1))
      (should (eq (overlay-get foreign-overlay 'face) 'bold)))))

(ert-deftest proofread-test-navigation-preserves-buffer-text ()
  "Navigation commands move point without changing buffer text."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g"))
          (text (buffer-string)))
      (proofread-test--install-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (goto-char (point-max))
      (proofread-previous)
      (should (equal (buffer-string) text)))))

(ert-deftest proofread-test-navigation-clears-current-state ()
  "Clear current diagnostic state with overlays or mode disable."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c")))
      (proofread-test--install-diagnostics (list diagnostic))
      (proofread--mark-current-diagnostic diagnostic)
      (should proofread--current-diagnostic)
      (proofread-clear)
      (should-not proofread--current-diagnostic)
      (should-not proofread--overlays)))
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (proofread--mark-current-diagnostic diagnostic)
      (proofread-mode -1)
      (should-not proofread--current-diagnostic)
      (should-not (overlay-buffer overlay)))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-lists-current-buffer ()
  "List diagnostics for the source buffer."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (proofread-mode 1)
      (let* ((source (current-buffer))
             (first
              (proofread--make-diagnostic
               :beg 4
               :end 8
               :text "helo"
               :kind 'spelling
               :message "Possible misspelling"
               :suggestions '( "hello")
               :source 'test))
             (second
              (proofread--make-diagnostic
               :beg 12
               :end 15
               :text "teh"
               :kind 'grammar
               :message "Use \"the\" here"
               :suggestions '( "the")))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list second
                                                         first))
              (goto-char 2)
              (proofread-show-buffer-diagnostics)
              (should (= (point) 2))
              (with-current-buffer name
                (should (eq major-mode
                            'proofread-diagnostics-buffer-mode))
                (should (eq proofread--diagnostics-buffer-source
                            source))
                (should (= (length tabulated-list-entries) 2))
                (let* ((entry (car tabulated-list-entries))
                       (id (car entry))
                       (columns (cadr entry)))
                  (should (eq (plist-get id :diagnostic) first))
                  (should (eq (plist-get id :buffer) source))
                  (should (equal (aref columns 0) "1"))
                  (should (equal (aref columns 1) "3"))
                  (should (equal (aref columns 2) "spelling"))
                  (should (equal (aref columns 3) "test"))
                  (should (equal (aref columns 4) "helo"))
                  (should (equal (car (aref columns 5))
                                 "Possible misspelling")))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-selects-diagnostic ()
  "Highlight the requested diagnostic in the diagnostics list."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (proofread-mode 1)
      (let* ((first (proofread-test--diagnostic-for-range 4 8 "helo"))
             (second (proofread-test--diagnostic-for-range 12 15
                                                           "teh"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list first
                                                         second))
              (cl-letf (((symbol-function
                          'pulse-momentary-highlight-one-line)
                         (lambda (&rest _args)
                           'highlighted)))
                (proofread-show-buffer-diagnostics second))
              (with-current-buffer name
                (should (eq (plist-get (tabulated-list-get-id)
                                       :diagnostic)
                            second))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-diagnostics-list-aggregates-checkers ()
  "List one row for same-range diagnostics from multiple checkers."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo")
      (proofread-mode 1)
      (let* ((first
              (proofread-test--diagnostic-with-checker
               (proofread--make-diagnostic
                :beg 4
                :end 8
                :text "helo"
                :kind 'spelling
                :message "First message"
                :suggestions '( "hello")
                :source 'test)
               'first))
             (second
              (proofread-test--diagnostic-with-checker
               (proofread--make-diagnostic
                :beg 4
                :end 8
                :text "helo"
                :kind 'spelling
                :message "Second message"
                :suggestions '( "hello" "hullo")
                :source 'test)
               'second))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics
               (list first second))
              (proofread-show-buffer-diagnostics)
              (with-current-buffer name
                (should (= (length tabulated-list-entries) 1))
                (let* ((entry (car tabulated-list-entries))
                       (id (car entry))
                       (diagnostic (plist-get id :diagnostic))
                       (columns (cadr entry)))
                  (should (proofread--aggregate-diagnostic-p
                           diagnostic))
                  (should (equal (plist-get diagnostic :diagnostics)
                                 (list first second)))
                  (should (equal (aref columns 3)
                                 "first, second"))
                  (should (equal (car (aref columns 5))
                                 (concat "first: First message; "
                                         "second: Second message"))))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-diagnostics-list-keeps-distinct-groups ()
  "Do not aggregate diagnostics whose range or text differs."
  (with-temp-buffer
    (insert "helo hallo")
    (proofread-mode 1)
    (let ((same-range-different-text
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 1 5 "helo")
            'first))
          (different-text
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 1 5 "hallo")
            'second))
          (different-range
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 6 11 "hallo")
            'third)))
      (proofread-test--install-diagnostics
       (list same-range-different-text different-text
             different-range))
      (should (= (length (proofread--navigation-diagnostics)) 3)))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-selects-aggregate-member
    ()
  "Selecting a raw diagnostic highlights its aggregate list row."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo")
      (proofread-mode 1)
      (let* ((first
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 4 8 "helo")
               'first))
             (second
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 4 8 "helo")
               'second))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics
               (list first second))
              (proofread-show-buffer-diagnostics second)
              (with-current-buffer name
                (should
                 (memq second
                       (plist-get
                        (plist-get (tabulated-list-get-id)
                                   :diagnostic)
                        :diagnostics)))))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest proofread-test-show-diagnostic-visits-source ()
  "`proofread-show-diagnostic' visits the source diagnostic location."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo zz")
      (proofread-mode 1)
      (let* ((source (current-buffer))
             (diagnostic
              (proofread-test--diagnostic-for-range 4 8 "helo"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--install-diagnostics (list diagnostic))
              (proofread-show-buffer-diagnostics)
              (with-current-buffer name
                (goto-char (point-min))
                (cl-letf (((symbol-function
                            'pulse-momentary-highlight-region)
                           (lambda (&rest _args)
                             'highlighted)))
                  (should (eq (proofread-show-diagnostic (point))
                              source))))
              (should (= (point) 4))
              (should (eq proofread--current-diagnostic diagnostic)))
          (when-let* ((buffer (get-buffer name)))
            (kill-buffer buffer)))))))

(ert-deftest proofread-test-show-buffer-diagnostics-requires-mode ()
  "`proofread-show-buffer-diagnostics' requires `proofread-mode'."
  (with-temp-buffer
    (insert "helo")
    (should-error (proofread-show-buffer-diagnostics) :type
                  'user-error)))

(ert-deftest
    proofread-test-diagnostics-list-refreshes-visible-contents ()
  "An open diagnostics list redraws when source diagnostics change."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-diagnostics-refresh*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (let* ((diagnostic
                    (proofread-test--diagnostic-for-range 1 5 "helo"))
                   (name (proofread--diagnostics-buffer-name)))
              (proofread-test--install-diagnostics (list diagnostic))
              (proofread-show-buffer-diagnostics)
              (with-current-buffer name
                (goto-char (point-min))
                (should (search-forward "helo" nil t)))
              (with-current-buffer source
                (proofread-clear))
              (with-current-buffer name
                (should-not tabulated-list-entries)
                (goto-char (point-min))
                (should-not (search-forward "helo" nil t)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-diagnostic-at-point-finds-covering-diagnostic ()
  "Diagnostic lookup returns the proofread diagnostic covering point."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 6
                                                            "cde")))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 3)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (goto-char 5)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (goto-char 6)
      (should-not (proofread-diagnostic-at-point)))))

(ert-deftest proofread-test-diagnostic-at-point-uses-overlap-order ()
  "Overlapping diagnostic lookup uses navigation ordering."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((long (proofread-test--diagnostic-for-range 2 9 "bcdefgh"))
          (short (proofread-test--diagnostic-for-range 2 6 "bcde"))
          (later (proofread-test--diagnostic-for-range 4 5 "d")))
      (proofread-test--install-diagnostics (list later long short))
      (goto-char 4)
      (should (eq (proofread-diagnostic-at-point) short)))))

(ert-deftest proofread-test-diagnostic-at-point-aggregates-checkers
    ()
  "Point lookup aggregates same-range diagnostics from checkers."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '( "hello"))
            'first))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '( "hello" "hullo"))
            'second)))
      (proofread-test--install-diagnostics (list first second))
      (goto-char 2)
      (let ((diagnostic (proofread-diagnostic-at-point))
            (repeated (proofread-diagnostic-at-point)))
        (should (proofread--aggregate-diagnostic-p diagnostic))
        (should-not (eq diagnostic repeated))
        (should
         (equal
          (proofread-test--public-diagnostic-signature diagnostic)
          (proofread-test--public-diagnostic-signature repeated)))
        (should (equal (plist-get diagnostic :diagnostics)
                       (list first second)))
        (should (equal (proofread--diagnostic-suggestions
                        diagnostic)
                       '( "hello" "hullo")))))))

(ert-deftest
    proofread-test-diagnostic-at-point-avoids-navigation-scan ()
  "Do not call buffer-wide navigation while aggregating at point."
  (with-temp-buffer
    (insert (make-string 500 ?x))
    (let ((proofread-auto-check nil)
          remote-diagnostics)
      (proofread-mode 1)
      (dotimes (index 200)
        (let ((beg (+ 10 (* index 2))))
          (push
           (proofread-test--diagnostic-for-range
            beg (1+ beg) "x")
           remote-diagnostics)))
      (let* ((first
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 1 2 "x")
               'first))
             (different-text
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range
                1 2 "different")
               'middle))
             (second
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 1 2 "x")
               'second))
             orphan-overlay)
        (setq first (plist-put first :checker-ordinal 0))
        (setq different-text
              (plist-put different-text :checker-ordinal 1))
        (setq second (plist-put second :checker-ordinal 2))
        ;; Create the local overlays in the inverse of their checker
        ;; order, with a different-text entry between aggregate members.
        (proofread-test--install-diagnostics
         (append (nreverse remote-diagnostics)
                 (list second different-text first)))
        (setq orphan-overlay (make-overlay 1 2))
        (overlay-put orphan-overlay 'category
                     proofread--overlay-category)
        (overlay-put orphan-overlay 'proofread-diagnostic first)
        (overlay-put
         orphan-overlay 'proofread-diagnostic-insertion-ordinal 999)
        (cl-letf
            (((symbol-function 'proofread--raw-navigation-entries)
              (lambda (&rest _args)
                (ert-fail
                 "Point lookup scanned all buffer diagnostics"))))
          (let ((diagnostic (proofread-diagnostic-at-point 1)))
            (should (proofread--aggregate-diagnostic-p diagnostic))
            (should
             (equal (proofread--diagnostic-members diagnostic)
                    (list first second)))))))))

(ert-deftest
    proofread-test-diagnostic-at-point-live-range-work-is-local ()
  "Bound live-range work by local rather than total diagnostics."
  (let (call-counts)
    (dolist (remote-count '( 20 200))
      (with-temp-buffer
        (insert (make-string 500 ?x))
        (let ((proofread-auto-check nil)
              remote-diagnostics)
          (proofread-mode 1)
          (dotimes (index remote-count)
            (let ((beg (+ 10 (* index 2))))
              (push
               (proofread-test--diagnostic-for-range
                beg (1+ beg) "x")
               remote-diagnostics)))
          (let* ((first
                  (proofread-test--diagnostic-with-checker
                   (proofread-test--diagnostic-for-range 1 2 "x")
                   'first))
                 (second
                  (proofread-test--diagnostic-with-checker
                   (proofread-test--diagnostic-for-range 1 2 "x")
                   'second))
                 (local-diagnostics (list first second))
                 (live-range-calls nil)
                 (original-live-range
                  (symbol-function
                   'proofread--diagnostic-live-range)))
            (proofread-test--install-diagnostics
             (append (nreverse remote-diagnostics)
                     local-diagnostics))
            (cl-letf
                (((symbol-function 'proofread--diagnostic-live-range)
                  (lambda (diagnostic)
                    (push diagnostic live-range-calls)
                    (funcall original-live-range diagnostic))))
              (should
               (proofread--aggregate-diagnostic-p
                (proofread-diagnostic-at-point 1))))
            (dolist (diagnostic live-range-calls)
              (should (memq diagnostic local-diagnostics)))
            (should (<= (length live-range-calls)
                        (* 2 (length local-diagnostics))))
            (push (length live-range-calls) call-counts)))))
    (should (= (length call-counts) 2))
    (should (apply #'= call-counts))))

(ert-deftest
    proofread-test-diagnostic-at-point-orders-zero-width-overlaps ()
  "Order zero-width and nonempty local diagnostics like navigation."
  (with-temp-buffer
    (insert "abcd")
    (let ((proofread-auto-check nil)
          (zero
           (proofread-test--diagnostic-for-range 3 3 ""))
          (same-start
           (proofread-test--diagnostic-for-range 3 5 "cd")))
      (proofread-mode 1)
      (proofread-test--install-diagnostics (list same-start zero))
      (should (eq (proofread-diagnostic-at-point 3) zero))))
  (with-temp-buffer
    (insert "abcd")
    (let ((proofread-auto-check nil)
          (zero
           (proofread-test--diagnostic-for-range 3 3 ""))
          (earlier
           (proofread-test--diagnostic-for-range 2 4 "bc")))
      (proofread-mode 1)
      (proofread-test--install-diagnostics (list zero earlier))
      (should (eq (proofread-diagnostic-at-point 3) earlier)))))

(ert-deftest proofread-test-diagnostic-at-point-uses-moved-range ()
  "Aggregate diagnostics using their moved overlay ranges."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (first
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 1 5 "helo")
            'first))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 1 5 "helo")
            'second)))
      (proofread-mode 1)
      (proofread-test--install-diagnostics (list first second))
      (goto-char (point-min))
      (insert "x")
      (should-not (proofread-diagnostic-at-point 1))
      (let ((diagnostic (proofread-diagnostic-at-point 2)))
        (should (equal (proofread-diagnostic-range diagnostic)
                       '( 2 . 6)))
        (should (equal (proofread--diagnostic-members diagnostic)
                       (list first second)))))))

(ert-deftest
    proofread-test-diagnostic-at-point-skips-removed-overlay ()
  "Ignore a live orphan overlay removed from diagnostic state."
  (with-temp-buffer
    (insert "abcdefghij")
    (let ((proofread-auto-check nil)
          (stale
           (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
          (live
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (proofread-mode 1)
      (proofread-test--install-diagnostics (list stale live))
      (let ((stale-overlay
             (proofread--overlay-for-diagnostic stale)))
        (proofread--remove-diagnostics (list stale))
        (should (overlay-buffer stale-overlay))
        (should-not (gethash stale proofread--diagnostic-overlays))
        (should (eq (proofread-diagnostic-at-point 4) live))))))

(ert-deftest proofread-test-diagnostic-at-point-follows-replacement
    ()
  "Return only the current member after backend replacement."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (request '( :beg 1 :end 5))
          (old
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'spelling))
          (new
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'grammar)))
      (proofread-mode 1)
      (proofread--apply-backend-diagnostics (list old) '( 1 . 5))
      (let* ((old-live (car proofread--diagnostics))
             (old-overlay
              (proofread--overlay-for-diagnostic old-live)))
        (should (eq (proofread-diagnostic-at-point 2) old-live))
        (proofread--replace-backend-diagnostics request (list new))
        (let ((new-live (car proofread--diagnostics)))
          (should-not (overlay-buffer old-overlay))
          (should (eq (proofread-diagnostic-at-point 2) new-live)))
        (proofread--replace-backend-diagnostics request nil)
        (should-not (proofread-diagnostic-at-point 2))))))

(ert-deftest proofread-test-diagnostic-at-point-follows-partial-merge
    ()
  "Aggregate local members added by a partial backend result."
  (with-temp-buffer
    (insert "helo xxxx")
    (let ((proofread-auto-check nil)
          (request '( :beg 1 :end 10))
          (first
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'spelling))
          (second
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'grammar))
          (remote
           (proofread-test--diagnostic-with-kind
            6 10 "xxxx" 'style)))
      (proofread-mode 1)
      (proofread--apply-backend-diagnostics (list first) '( 1 . 10))
      (let ((first-live (car proofread--diagnostics)))
        (proofread--merge-backend-diagnostics
         request (list second remote))
        (let ((second-live (nth 1 proofread--diagnostics))
              (remote-live (nth 2 proofread--diagnostics)))
          (should
           (equal
            (proofread--diagnostic-members
             (proofread-diagnostic-at-point 2))
            (list first-live second-live)))
          (should (eq (proofread-diagnostic-at-point 7)
                      remote-live)))))))

(ert-deftest proofread-test-diagnostic-at-point-follows-removal ()
  "Shrink an aggregate as its raw diagnostics are removed."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (first
           (proofread-test--diagnostic-for-range 1 5 "helo"))
          (second
           (proofread-test--diagnostic-for-range 1 5 "helo"))
          (third
           (proofread-test--diagnostic-for-range 1 5 "helo")))
      (proofread-mode 1)
      (proofread-test--install-diagnostics
       (list first second third))
      (proofread--invalidate-affected-diagnostics
       (list (proofread--overlay-for-diagnostic second))
       (list second))
      (should
       (equal
        (proofread--diagnostic-members
         (proofread-diagnostic-at-point 2))
        (list first third)))
      (proofread--invalidate-affected-diagnostics
       (list (proofread--overlay-for-diagnostic first))
       (list first))
      (should (eq (proofread-diagnostic-at-point 2) third))
      (proofread--invalidate-affected-diagnostics
       (list (proofread--overlay-for-diagnostic third))
       (list third))
      (should-not (proofread-diagnostic-at-point 2)))))

(ert-deftest
    proofread-test-diagnostic-at-point-ignores-foreign-overlays ()
  "Ignore foreign overlays and invalid ranges during lookup."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((foreign-overlay (make-overlay 3 6))
          (invalid-backward
           (proofread-test--diagnostic-for-range 7 6 ""))
          (invalid-beg
           (proofread-test--diagnostic-for-range 'not-a-position 5
                                                 "")))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (setq proofread--diagnostics (list invalid-backward
                                         invalid-beg))
      (goto-char 4)
      (should-not (proofread-diagnostic-at-point)))))

(ert-deftest proofread-test-public-diagnostic-range-validates-range ()
  "The public diagnostic range accessor returns only valid ranges."
  (should (equal
           (proofread-diagnostic-range
            (proofread-test--diagnostic-for-range 3 6 "cde"))
           '( 3 . 6)))
  (should-not (proofread-diagnostic-range '( :beg 7 :end 6)))
  (should-not (proofread-diagnostic-range '( :beg invalid :end 6))))

(ert-deftest proofread-test-public-diagnostic-field-formatting ()
  "The shared diagnostic field formatter returns display strings."
  (let ((string (copy-sequence "literal")))
    (should (eq (proofread-format-diagnostic-field string) string)))
  (should (equal (proofread-format-diagnostic-field 'spelling)
                 "spelling"))
  (should (equal (proofread-format-diagnostic-field '( bad "text"))
                 "(bad \"text\")")))

(ert-deftest proofread-test-public-diagnostic-message-formatting-faces ()
  "The shared message formatter owns exact face boundaries."
  (let* ((source
          (propertize "test" 'face 'bold 'help-echo "source"))
         (raw-message
          (propertize
           "Possible misspelling"
           'face 'error
           'font-lock-face 'warning
           'proofread-test-property t))
         (diagnostic
          (list :source source
                :message raw-message
                :text "helo"))
         (message
          (proofread-format-diagnostic-message
           diagnostic
           :source-face 'proofread-echo-area-source-face
           :message-face 'proofread-echo-area-message-face)))
    (should (equal message "test: Possible misspelling"))
    (should
     (eq (get-text-property 0 'face message)
         'proofread-echo-area-source-face))
    (should
     (eq (get-text-property 4 'face message)
         'proofread-echo-area-source-face))
    (should-not (get-text-property 5 'face message))
    (should
     (eq (get-text-property 6 'face message)
         'proofread-echo-area-message-face))
    (dolist (property '( font-lock-face
                         help-echo
                         proofread-test-property))
      (should-not (get-text-property 6 property message)))
    (should (eq (get-text-property 0 'face source) 'bold))
    (should (eq (get-text-property 0 'face raw-message) 'error))
    (should
     (eq (get-text-property 0 'font-lock-face raw-message)
         'warning))))

(ert-deftest
    proofread-test-public-diagnostic-message-formatting-aggregates ()
  "Format aggregate entries in order with caller-selected separation."
  (let* ((first
          (list :source-label " model\n a "
                :source 'raw
                :message " First\n message "))
         (second
          (list :source 'languagetool
                :message 'structured))
         (diagnostic
          (list :proofread-aggregate t
                :diagnostics (list first second)
                :text "helo"))
         (message
          (proofread-format-diagnostic-message
           diagnostic
           :separator "; "
           :source-face 'proofread-echo-area-source-face
           :message-face 'proofread-echo-area-message-face
           :single-line t))
         (separator (string-match-p "; " message))
         (second-source (string-match-p "languagetool" message)))
    (should
     (equal message
            "model a: First message; languagetool: structured"))
    (should separator)
    (should-not (get-text-property separator 'face message))
    (should-not (get-text-property (1+ separator) 'face message))
    (should second-source)
    (should
     (eq (get-text-property second-source 'face message)
         'proofread-echo-area-source-face))
    (should
     (eq (get-text-property (+ second-source 14) 'face message)
         'proofread-echo-area-message-face))))

(ert-deftest proofread-test-public-diagnostic-message-fallbacks ()
  "The shared message formatter handles blank and non-string fields."
  (dolist (raw-message '(nil "" " \t\n"))
    (let ((message
           (proofread-format-diagnostic-message
            (list :source " "
                  :message raw-message
                  :text (propertize "helo" 'face 'error))
            :message-face 'proofread-echo-area-message-face)))
      (should (equal message "Proofread: helo"))
      (should
       (eq (get-text-property 0 'face message)
           'proofread-echo-area-message-face))))
  (should
   (equal
    (proofread-format-diagnostic-message
     (list :source 'test :message nil :text nil))
    "test: Proofread diagnostic"))
  (should
   (equal
    (proofread-format-diagnostic-message
     (list :source nil :message '( bad "text") :text "helo"))
    "(bad \"text\")"))
  (should
   (equal
    (proofread-format-diagnostic-message
     (list :proofread-aggregate t :diagnostics nil :text "helo"))
    "Proofread: helo")))

(ert-deftest
    proofread-test-public-diagnostic-at-point-requires-overlay ()
  "Return only live displayed diagnostics from the public lookup."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread-test--diagnostic-for-range 3 6 "cde"))
           overlay)
      (setq proofread--diagnostics (list diagnostic))
      (should-not (proofread-diagnostic-at-point 4))
      (setq overlay (proofread--create-overlay diagnostic))
      (should (eq (proofread-diagnostic-at-point 4) diagnostic))
      (delete-overlay overlay)
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest
    proofread-test-public-diagnostic-at-point-skips-stale-overlap ()
  "The public lookup skips an earlier stale overlapping diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((stale
           (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
          (live
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (setq proofread--diagnostics (list stale live))
      (proofread--create-overlay live)
      (should (eq (proofread-diagnostic-at-point 4) live)))))

(ert-deftest proofread-test-eldoc-provider-formats-diagnostic-at-point
    ()
  "The ElDoc provider reports the local diagnostic with echo faces."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (let (called)
        (should-not
         (proofread--eldoc-function
          (lambda (&rest _arguments)
            (setq called t))))
        (should-not called))
      (proofread-test--install-diagnostics
       (list (proofread-test--diagnostic-for-range 1 5 "helo")))
      (goto-char 2)
      (let (callback-arguments)
        (should
         (proofread--eldoc-function
          (lambda (&rest arguments)
            (setq callback-arguments arguments))))
        (let ((message (car callback-arguments)))
          (should (equal message "test: Possible misspelling"))
          (should (equal (plist-get (cdr callback-arguments) :echo)
                         message))
          (should
           (eq (get-text-property 0 'face message)
               'proofread-echo-area-source-face))
          (should-not (get-text-property 5 'face message))
          (should
           (eq (get-text-property 6 'face message)
               'proofread-echo-area-message-face))
          (should
           (eq (get-text-property
                0 'proofread--echo-area-message message)
               (current-buffer)))))
      (setq-local proofread-echo-area-messages nil)
      (let (called)
        (should-not
         (proofread--eldoc-function
          (lambda (&rest _arguments)
            (setq called t))))
        (should-not called)))))

(ert-deftest proofread-test-eldoc-provider-aggregates-on-one-line ()
  "Echo diagnostics retain checker order without multiline output."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (first
           (proofread-test--diagnostic-with-checker
            (proofread--make-diagnostic
             :beg 1 :end 5 :text "helo" :kind 'grammar
             :message "First\nmessage" :suggestions nil
             :source 'first)
            'first))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread--make-diagnostic
             :beg 1 :end 5 :text "helo" :kind 'style
             :message "Second message" :suggestions nil
             :source 'second)
            'second)))
      (proofread-mode 1)
      (proofread-test--install-diagnostics (list first second))
      (goto-char 2)
      (let (message)
        (proofread--eldoc-function
         (lambda (document &rest _properties)
           (setq message document)))
        (should
         (equal message
                "first: First message; second: Second message"))
        (should-not (string-match-p "[\n\r]" message))))))

(ert-deftest proofread-test-eldoc-mode-lifecycle-restores-state ()
  "Proofread restores only ElDoc mode state that it enabled."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should eldoc-mode)
      (should proofread--eldoc-mode-owned-p)
      (should (eq (car eldoc-documentation-functions)
                  #'proofread--eldoc-function))
      (should-not (memq #'proofread--retry-echo-area-refresh
                        post-command-hook))
      (proofread-mode -1)
      (should-not eldoc-mode)
      (should-not proofread--eldoc-mode-owned-p)
      (should-not (memq #'proofread--eldoc-function
                        eldoc-documentation-functions))))
  (with-temp-buffer
    (text-mode)
    (add-hook 'eldoc-documentation-functions #'ignore nil t)
    (eldoc-mode 1)
    (should eldoc-mode)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should-not proofread--eldoc-mode-owned-p)
      (should (eq (car eldoc-documentation-functions)
                  #'proofread--eldoc-function))
      (setq-local proofread-echo-area-messages nil)
      (should eldoc-mode)
      (should-not proofread--eldoc-mode-owned-p)
      (setq-local proofread-echo-area-messages t)
      (should eldoc-mode)
      (proofread-mode -1)
      (should eldoc-mode)
      (should (memq #'ignore eldoc-documentation-functions))
      (should-not (memq #'proofread--eldoc-function
                        eldoc-documentation-functions)))
    (eldoc-mode -1)))

(ert-deftest proofread-test-echo-option-controls-owned-eldoc ()
  "The echo option dynamically owns and restores a disabled ElDoc mode."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (setq-local proofread-echo-area-messages nil)
    (let ((proofread-auto-check nil)
          (eldoc-last-message nil))
      (proofread-mode 1)
      (should-not eldoc-mode)
      (should-not proofread--eldoc-mode-owned-p)
      (should (eq (car eldoc-documentation-functions)
                  #'proofread--eldoc-function))
      (setq-local proofread-echo-area-messages t)
      (should eldoc-mode)
      (should proofread--eldoc-mode-owned-p)
      (let ((message
             (proofread--echo-area-message
              (proofread-test--diagnostic)))
            displays)
        (setq eldoc-last-message message)
        (cl-letf
            (((symbol-function 'current-message)
              (lambda () message))
             ((symbol-function 'eldoc-display-in-echo-area)
              (lambda (documents interactive)
                (push (list documents interactive) displays))))
          (setq-local proofread-echo-area-messages nil))
        (should (equal displays '((nil t))))
        (should-not eldoc-last-message))
      (should-not eldoc-mode)
      (should-not proofread--eldoc-mode-owned-p))))

(ert-deftest proofread-test-echo-option-local-let-restores-eldoc ()
  "A temporary local echo option restores Proofread-owned ElDoc."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (setq-local proofread-echo-area-messages nil)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should-not eldoc-mode)
      (let ((proofread-echo-area-messages t))
        (should eldoc-mode)
        (should proofread--eldoc-mode-owned-p))
      (should-not proofread-echo-area-messages)
      (should-not eldoc-mode)
      (should-not proofread--eldoc-mode-owned-p))))

(ert-deftest proofread-test-echo-option-default-let-restores-eldoc ()
  "A temporary default echo option restores non-local users."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should-not
       (local-variable-p 'proofread-echo-area-messages))
      (should eldoc-mode)
      (should proofread--eldoc-mode-owned-p)
      (let ((proofread-echo-area-messages nil))
        (should-not proofread-echo-area-messages)
        (should-not eldoc-mode)
        (should-not proofread--eldoc-mode-owned-p))
      (should proofread-echo-area-messages)
      (should eldoc-mode)
      (should proofread--eldoc-mode-owned-p))))

(ert-deftest proofread-test-echo-option-kill-local-uses-default ()
  "Killing a local echo option synchronizes to its default value."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (setq-local proofread-echo-area-messages nil)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should-not eldoc-mode)
      (kill-local-variable 'proofread-echo-area-messages)
      (should proofread-echo-area-messages)
      (should-not
       (local-variable-p 'proofread-echo-area-messages))
      (should eldoc-mode)
      (should proofread--eldoc-mode-owned-p))))

(ert-deftest proofread-test-echo-option-default-set-is-local-aware ()
  "A new echo default updates only buffers without a local value."
  (let ((default-buffer
         (generate-new-buffer " *proofread-echo-default*"))
        (local-buffer
         (generate-new-buffer " *proofread-echo-local*"))
        (original-default
         (default-value 'proofread-echo-area-messages)))
    (unwind-protect
        (progn
          (set-default 'proofread-echo-area-messages t)
          (dolist (buffer (list default-buffer local-buffer))
            (with-current-buffer buffer
              (text-mode)
              (setq-local eldoc-documentation-functions nil)
              (eldoc-mode -1)))
          (with-current-buffer local-buffer
            (setq-local proofread-echo-area-messages t))
          (dolist (buffer (list default-buffer local-buffer))
            (with-current-buffer buffer
              (let ((proofread-auto-check nil))
                (proofread-mode 1))
              (should eldoc-mode)
              (should proofread--eldoc-mode-owned-p)))
          (set-default 'proofread-echo-area-messages nil)
          (with-current-buffer default-buffer
            (should-not proofread-echo-area-messages)
            (should-not eldoc-mode)
            (should-not proofread--eldoc-mode-owned-p))
          (with-current-buffer local-buffer
            (should proofread-echo-area-messages)
            (should eldoc-mode)
            (should proofread--eldoc-mode-owned-p))
          (set-default 'proofread-echo-area-messages t)
          (with-current-buffer default-buffer
            (should proofread-echo-area-messages)
            (should eldoc-mode)
            (should proofread--eldoc-mode-owned-p)))
      (dolist (buffer (list default-buffer local-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (set-default 'proofread-echo-area-messages original-default))))

(ert-deftest proofread-test-echo-area-refresh-is-guarded-and-retried
    ()
  "Do not overwrite foreign messages; retry only after a safe command."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-echo-refresh*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo")
            (let ((proofread-auto-check nil)
                  (this-command nil)
                  current-message-value
                  displays)
              (proofread-mode 1)
              (proofread-test--install-diagnostics
               (list
                (proofread-test--diagnostic-for-range 1 5 "helo")))
              (goto-char 2)
              (cl-letf
                  (((symbol-function 'active-minibuffer-window)
                    (lambda () nil))
                   ((symbol-function
                     'eldoc-display-message-no-interference-p)
                    (lambda () t))
                   ((symbol-function 'current-message)
                    (lambda () current-message-value))
                   ((symbol-function 'eldoc-display-in-echo-area)
                    (lambda (documents interactive)
                      (push (list documents interactive) displays)
                      (setq current-message-value
                            (and documents (caar documents))))))
                (proofread--refresh-echo-area)
                (should (= (length displays) 1))
                (let ((message (caaaar displays)))
                  (should
                   (equal message "test: Possible misspelling")))
                (should-not proofread--echo-area-refresh-pending-p)
                (should-not
                 (memq #'proofread--retry-echo-area-refresh
                       post-command-hook))
                (setq displays nil)
                (setq current-message-value "foreign command output")
                (proofread--refresh-echo-area)
                (should-not displays)
                (should proofread--echo-area-refresh-pending-p)
                (should
                 (memq #'proofread--retry-echo-area-refresh
                       post-command-hook))
                (setq current-message-value nil)
                (let ((this-command 'next-line))
                  (proofread--retry-echo-area-refresh))
                (should (= (length displays) 1))
                (should-not proofread--echo-area-refresh-pending-p)
                (should-not
                 (memq #'proofread--retry-echo-area-refresh
                       post-command-hook)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest proofread-test-echo-area-ownership-is-buffer-specific ()
  "One Proofread buffer cannot clear another buffer's echo message."
  (let ((first (generate-new-buffer " *proofread-echo-first*"))
        (second (generate-new-buffer " *proofread-echo-second*"))
        (eldoc-last-message nil)
        displays
        message)
    (unwind-protect
        (progn
          (with-current-buffer first
            (setq message
                  (proofread--echo-area-message
                   (proofread-test--diagnostic))))
          (setq eldoc-last-message message)
          (cl-letf
              (((symbol-function 'current-message)
                (lambda () message))
               ((symbol-function 'eldoc-display-in-echo-area)
                (lambda (documents interactive)
                  (push (list documents interactive) displays))))
            (with-current-buffer second
              (proofread--echo-area-clear-current-message))
            (should-not displays)
            (should (eq eldoc-last-message message))
            (with-current-buffer first
              (proofread--echo-area-clear-current-message))
            (should (equal displays '((nil t))))
            (should-not eldoc-last-message)))
      (when (buffer-live-p first)
        (kill-buffer first))
      (when (buffer-live-p second)
        (kill-buffer second)))))

(ert-deftest proofread-test-diagnostics-changed-hook-runs-after-clear
    ()
  "Notify optional frontends after clearing displayed diagnostics."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((calls 0)
          (diagnostic
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread-test--install-diagnostics (list diagnostic))
      (proofread-clear)
      (should (= calls 1))
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest
    proofread-test-diagnostics-hook-error-does-not-break-correction ()
  "Do not let optional frontend errors interrupt corrections."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 5
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '( "hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (error "Simulated frontend failure"))
                nil t)
      (goto-char 2)
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "hello"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest proofread-test-backend-replace-notifies-diagnostics-once
    ()
  "One backend replacement emits one final diagnostics notification."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((calls 0)
          (old
           (proofread-test--diagnostic-for-range 1 5 "helo"))
          (new
           (proofread-test--diagnostic-with-kind
            1 5 "helo" 'grammar)))
      (proofread-test--install-diagnostics (list old))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread--replace-backend-diagnostics
       (list :beg 1 :end 5)
       (list new))
      (should (= calls 1))
      (should (equal proofread--diagnostics (list new))))))

(ert-deftest proofread-test-format-diagnostic-description-details ()
  "Diagnostic description includes stable package-level fields."
  (let* ((diagnostic
          (proofread--make-diagnostic
           :beg 1
           :end 5
           :text "helo"
           :kind 'spelling
           :message "Possible misspelling"
           :suggestions '( "hello")
           :source proofread-test--backend))
         (description
          (proofread--format-diagnostic-description diagnostic)))
    (should (string-match-p "Kind: spelling" description))
    (should (string-match-p "Message: Possible misspelling"
                            description))
    (should (string-match-p "Original text:\nhelo" description))
    (should (string-match-p "1\\. hello" description))
    (should (string-match-p "Source: proofread-test-backend"
                            description))))

(ert-deftest proofread-test-describe-displays-diagnostic-details ()
  "`proofread-describe' displays diagnostic details at point."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '( "hello")
              :source proofread-test--backend)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Kind: spelling" description))
            (should (string-match-p "Message: Possible misspelling"
                                    description))
            (should (string-match-p "Original text:\nhelo"
                                    description))
            (should (string-match-p "1\\. hello" description))
            (should (string-match-p
                     "Source: proofread-test-backend"
                     description))))))))

(ert-deftest proofread-test-describe-preserves-suggestion-order ()
  "`proofread-describe' displays suggestions in stored order."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '( "hello" "help" "hero"))))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let* ((description (buffer-string))
                 (first (string-match-p "1\\. hello" description))
                 (second (string-match-p "2\\. help" description))
                 (third (string-match-p "3\\. hero" description)))
            (should first)
            (should second)
            (should third)
            (should (< first second))
            (should (< second third))))))))

(ert-deftest proofread-test-describe-aggregates-checker-details ()
  "`proofread-describe' preserves aggregate messages and sources."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((first
             (proofread-test--diagnostic-with-checker
              (proofread--make-diagnostic
               :beg 1
               :end 5
               :text "helo"
               :kind 'spelling
               :message "First message"
               :suggestions '( "hello" "hullo")
               :source 'test)
              'first))
            (second
             (proofread-test--diagnostic-with-checker
              (proofread--make-diagnostic
               :beg 1
               :end 5
               :text "helo"
               :kind 'spelling
               :message "Second message"
               :suggestions '( "hello")
               :source 'test)
              'second)))
        (proofread-test--install-diagnostics (list first second))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Messages:" description))
            (should (string-match-p "first: First message"
                                    description))
            (should (string-match-p "second: Second message"
                                    description))
            (should (string-match-p
                     "1\\. hello (from first, second)"
                     description))
            (should (string-match-p
                     "2\\. hullo (from first)"
                     description))
            (should (string-match-p "Sources: first, second"
                                    description))))))))

(ert-deftest proofread-test-describe-handles-missing-optional-fields
    ()
  "Show available fields when optional diagnostic data is absent."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 1
              :end 5
              :text "helo"
              :message "Message only")))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (with-current-buffer proofread--description-buffer-name
          (let ((description (buffer-string)))
            (should (string-match-p "Message: Message only"
                                    description))
            (should (string-match-p "Original text:\nhelo"
                                    description))
            (should-not (string-match-p "Suggestions:" description))
            (should-not (string-match-p "Confidence:" description))
            (should-not (string-match-p "Source:" description))))))))

(ert-deftest proofread-test-describe-away-from-diagnostic-keeps-point
    ()
  "Report no diagnostic without moving point."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 5 "cd"))
          (text (buffer-string)))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 8)
      (let ((position (point)))
        (should-error (proofread-describe) :type 'user-error)
        (should (= (point) position))
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-describe-preserves-source-buffer-text ()
  "`proofread-describe' does not modify source buffer text."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let ((diagnostic (proofread-test--diagnostic-for-range 1 5
                                                              "helo"))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (should (equal (buffer-string) text))))))

(ert-deftest
    proofread-test-describe-preserves-diagnostics-and-overlays ()
  "Do not mutate diagnostics or overlays while describing them."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let* ((diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo"))
             (overlays (proofread-test--install-diagnostics
                        (list diagnostic)))
             (diagnostics-before (copy-sequence
                                  proofread--diagnostics))
             (overlays-before (copy-sequence proofread--overlays))
             (faces-before
              (mapcar (lambda (overlay)
                        (overlay-get overlay 'face))
                      proofread--overlays)))
        (goto-char 2)
        (proofread-describe)
        (should (equal proofread--diagnostics diagnostics-before))
        (should (equal proofread--overlays overlays-before))
        (should (equal (mapcar (lambda (overlay)
                                 (overlay-get overlay 'face))
                               proofread--overlays)
                       faces-before))
        (dolist (overlay overlays)
          (should (overlay-buffer overlay)))))))

(ert-deftest proofread-test-apply-target-overlay-lookup ()
  "Apply suggestions through owned diagnostic and overlay state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (proofread-overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic))))
           (foreign-overlay (make-overlay 1 5)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (overlay-put foreign-overlay 'proofread-diagnostic diagnostic)
      (goto-char 2)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (should (eq (proofread--overlay-for-diagnostic diagnostic)
                  proofread-overlay))
      (delete-overlay proofread-overlay)
      (should-not (proofread--overlay-for-diagnostic diagnostic))
      (should (overlay-buffer foreign-overlay)))))

(ert-deftest proofread-test-apply-suggestion-helper-returns-strings ()
  "Suggestion extraction returns strings in stored order."
  (let ((diagnostic
         (proofread--make-diagnostic
          :beg 1
          :end 5
          :text "helo"
          :suggestions '( hello "hullo" 42))))
    (should (equal (proofread--diagnostic-suggestions diagnostic)
                   '( "hello" "hullo" "42")))))

;;;; Correction tests

(ert-deftest proofread-test-correct-at-point-single-suggestion ()
  "Apply one point suggestion without prompting."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '( "hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args)
                   (error "Unexpected completion prompt"))))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal (buffer-string) "aa hello zz")))))

(ert-deftest proofread-test-correct-at-point-aggregates-suggestions
    ()
  "Correct an aggregate using deduplicated suggestion text."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-with-suggestions
             4 8 "helo" '( "hello" "hullo"))
            'first))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-with-suggestions
             4 8 "helo" '( "hello"))
            'second))
          collection-seen)
      (proofread-test--install-diagnostics (list first second))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _args)
                   (setq collection-seen collection)
                   "hello")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal collection-seen '( "hello" "hullo")))
      (should (equal (buffer-string) "aa hello zz"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-correction-entry-points-use-transaction-runner ()
  "Run single and batch corrections through one transaction runner."
  (let ((original-runner
         (symbol-function 'proofread--run-correction-transaction))
        entry-point
        calls)
    (cl-letf
        (((symbol-function 'proofread--run-correction-transaction)
          (lambda (&rest arguments)
            (push entry-point calls)
            (apply original-runner arguments))))
      (with-temp-buffer
        (insert "helo")
        (proofread-mode 1)
        (proofread-test--install-diagnostics
         (list
          (proofread-test--diagnostic-with-suggestions
           1 5 "helo" '( "hello"))))
        (goto-char 2)
        (setq entry-point 'single)
        (proofread-correct-at-point))
      (with-temp-buffer
        (insert "helo wrld")
        (proofread-mode 1)
        (proofread-test--install-diagnostics
         (list
          (proofread-test--diagnostic-with-suggestions
           1 5 "helo" '( "hello"))
          (proofread-test--diagnostic-with-suggestions
           6 10 "wrld" '( "world"))))
        (setq entry-point 'batch)
        (proofread-correct-buffer)))
    (should (equal (nreverse calls) '( single batch)))))

(ert-deftest
    proofread-test-single-correction-preserves-transaction-order ()
  "Keep single-correction point, mark, hook, and undo ordering."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (proofread-test--install-diagnostics
     (list
      (proofread-test--diagnostic-with-suggestions
       4 8 "helo" '( "hello"))))
    (goto-char 5)
    (set-mark (point-max))
    (setq mark-active t)
    (let ((original-boundary (symbol-function 'undo-boundary))
          events)
      (add-hook
       'proofread-diagnostics-changed-hook
       (lambda ()
         (push (list 'hook (point) (mark) mark-active) events))
       nil t)
      (cl-letf (((symbol-function 'undo-boundary)
                 (lambda ()
                   (push 'boundary events)
                   (funcall original-boundary))))
        (proofread-correct-at-point))
      (should (equal (nreverse events)
                     '( boundary (hook 9 12 t) boundary)))
      (should (= (point) 9))
      (should (= (mark) 12))
      (should mark-active))))

(ert-deftest
    proofread-test-single-correction-validates-container-before-undo
    ()
  "Reject a stale container before opening an undo transaction."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1 :end 5 :text "helo" :kind 'spelling
            :suggestions '( "hello") :source 'test
            :target-kind 'docstring))
          (original-boundary (symbol-function 'undo-boundary))
          (boundaries 0))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (cl-letf (((symbol-function 'undo-boundary)
                 (lambda ()
                   (setq boundaries (1+ boundaries))
                   (funcall original-boundary))))
        (should-error (proofread-correct-at-point) :type 'user-error))
      (should (= boundaries 0))
      (should (equal (buffer-string) "helo"))
      (should (equal proofread--diagnostics (list diagnostic))))))

(ert-deftest
    proofread-test-single-correction-keeps-delete-hook-point ()
  "Run the single-correction delete hook at the command's point."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (proofread-test--install-diagnostics
     (list
      (proofread-test--diagnostic-with-suggestions
       4 8 "helo" '( "hello"))))
    (goto-char 5)
    (let (change-points)
      (add-hook 'before-change-functions
                (lambda (&rest _)
                  (push (point) change-points))
                nil t)
      (proofread-correct-at-point)
      (should (equal (nreverse change-points) '( 5 4))))))

(ert-deftest
    proofread-test-batch-correction-preserves-transaction-order ()
  "Keep batch point, mark, hook, and undo ordering."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (proofread-test--install-diagnostics
     (list
      (proofread-test--diagnostic-with-suggestions
       4 8 "helo" '( "hello"))))
    (goto-char 5)
    (set-mark (point-max))
    (setq mark-active t)
    (let ((original-boundary (symbol-function 'undo-boundary))
          events)
      (add-hook
       'proofread-diagnostics-changed-hook
       (lambda ()
         (push (list 'hook (point) (mark) mark-active) events))
       nil t)
      (cl-letf (((symbol-function 'undo-boundary)
                 (lambda ()
                   (push 'boundary events)
                   (funcall original-boundary))))
        (proofread-correct-buffer))
      (should (equal (nreverse events)
                     '( boundary boundary (hook 4 12 t))))
      (should (= (point) 4))
      (should (= (mark) 12))
      (should mark-active))))

(ert-deftest proofread-test-correct-at-point-multiple-suggestions ()
  "Preserve suggestion order during point correction."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '( "hello" "hullo" "hallo")))
          candidates-seen)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt candidates &rest _args)
                   (setq candidates-seen candidates)
                   "hullo")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal candidates-seen '( "hello" "hullo" "hallo")))
      (should (equal (buffer-string) "aa hullo zz")))))

(ert-deftest proofread-test-correct-at-point-uses-native-completion ()
  "Use completion when correcting among multiple suggestions."
  (let ((description-buffer (get-buffer
                             proofread--description-buffer-name)))
    (when description-buffer
      (kill-buffer description-buffer)))
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling"
            :suggestions '( "hello" "hullo" "hallo")))
          prompt-seen
          candidates-seen
          require-match-seen)
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt candidates _predicate require-match
                                 &rest _args)
                   (setq prompt-seen prompt)
                   (setq candidates-seen candidates)
                   (setq require-match-seen require-match)
                   "hallo")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal prompt-seen "Apply suggestion: "))
      (should (equal candidates-seen '( "hello" "hullo" "hallo")))
      (should require-match-seen)
      (should (equal (buffer-string) "aa hallo zz"))
      (should-not (get-buffer proofread--description-buffer-name)))))

(ert-deftest proofread-test-correct-at-point-follows-preceding-edit ()
  "Track live diagnostics after earlier source text changes."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char (point-min))
      (insert "xx ")
      (should (equal (proofread-diagnostic-range diagnostic) '( 4 .
                                                                8)))
      (goto-char 5)
      (proofread-correct-at-point)
      (should (equal (buffer-string) "xx hello")))))

(ert-deftest
    proofread-test-correct-at-point-inserts-zero-width-suggestion ()
  "Point correction applies and removes a zero-width diagnostic."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '( "X"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (proofread-correct-at-point)
      (should (equal (buffer-string) "aXb"))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-public-command-scope-names ()
  "Check and correction commands use matching scope suffixes."
  (dolist (operation '( check correct))
    (dolist (scope '( at-point region buffer visible-range))
      (should
       (commandp
        (intern (format "proofread-%s-%s" operation scope)))))))

(ert-deftest
    proofread-test-correct-region-applies-from-end-to-beginning ()
  "Correct reversed regions despite changing text lengths."
  (with-temp-buffer
    (insert "helo and wrld; ouut.")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            10 14 "wrld" '( "world")))
          (outside
           (proofread-test--diagnostic-with-suggestions
            16 20 "ouut" '( "out"))))
      (proofread-test--install-diagnostics
       (list first second outside))
      (should (eq (proofread-correct-region 14 1) 'applied))
      (should (equal (buffer-string) "hello and world; ouut."))
      (should (equal proofread--diagnostics (list outside)))
      (should
       (equal (proofread-diagnostic-range outside)
              '( 18 . 22))))))

(ert-deftest
    proofread-test-correct-region-validates-interactive-bounds ()
  "Interactive region correction rejects inactive and foreign bounds."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((transient-mark-mode t))
      (goto-char (point-max))
      (set-mark (point-min))
      (setq mark-active nil)
      (should-error (call-interactively #'proofread-correct-region)
                    :type 'user-error))
    (let ((other (generate-new-buffer " *proofread-correct-marker*")))
      (unwind-protect
          (let ((foreign
                 (with-current-buffer other
                   (insert "wrld")
                   (copy-marker (point-min)))))
            (let ((condition
                   (should-error
                    (proofread-correct-region foreign (point-max))
                    :type 'user-error)))
              (should
               (equal
                (error-message-string condition)
                "Region boundaries are not in the current buffer"))))
        (kill-buffer other)))))

(ert-deftest proofread-test-correct-buffer-respects-narrowing ()
  "Correct only diagnostics in the accessible buffer portion."
  (with-temp-buffer
    (insert "helo middle wrld")
    (proofread-mode 1)
    (let ((outside
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (inside
           (proofread-test--diagnostic-with-suggestions
            13 17 "wrld" '( "world"))))
      (proofread-test--install-diagnostics (list outside inside))
      (narrow-to-region 13 17)
      (should (eq (proofread-correct-buffer) 'applied))
      (should (= (point-min) 13))
      (should (= (point-max) 18))
      (widen)
      (should (equal (buffer-string) "helo middle world"))
      (should (equal proofread--diagnostics (list outside)))
      (should (equal (proofread-diagnostic-range outside) '( 1 .
                                                             5))))))

(ert-deftest proofread-test-correct-visible-range-uses-all-ranges ()
  "Correct only diagnostics in visible ranges."
  (with-temp-buffer
    (insert "helo and wrld and ouut")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (hidden
           (proofread-test--diagnostic-with-suggestions
            10 14 "wrld" '( "world")))
          (last
           (proofread-test--diagnostic-with-suggestions
            19 23 "ouut" '( "out"))))
      (proofread-test--install-diagnostics (list first hidden last))
      (cl-letf (((symbol-function 'proofread--visible-ranges)
                 (lambda () '((1 . 5) (19 . 23)))))
        (should (eq (proofread-correct-visible-range) 'applied)))
      (should (equal (buffer-string) "hello and wrld and out"))
      (should (equal proofread--diagnostics (list hidden)))
      (should (equal (proofread-diagnostic-range hidden) '( 11 .
                                                            15))))))

(ert-deftest
    proofread-test-correct-buffer-skips-unavailable-suggestions ()
  "Buffer correction skips diagnostics without suggestions."
  (with-temp-buffer
    (insert "note helo")
    (proofread-mode 1)
    (let ((unavailable
           (proofread-test--diagnostic-with-suggestions
            1 5 "note" nil))
          (available
           (proofread-test--diagnostic-with-suggestions
            6 10 "helo" '( "hello"))))
      (proofread-test--install-diagnostics (list unavailable
                                                 available))
      (should (eq (proofread-correct-buffer) 'applied))
      (should (equal (buffer-string) "note hello"))
      (should (equal proofread--diagnostics (list unavailable))))))

(ert-deftest
    proofread-test-correct-buffer-keeps-adjacent-diagnostic-range ()
  "A correction preserves an adjacent diagnostic's exact range."
  (with-temp-buffer
    (insert "helowrld")
    (proofread-mode 1)
    (let ((available
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (adjacent
           (proofread-test--diagnostic-with-suggestions
            5 9 "wrld" nil)))
      (proofread-test--install-diagnostics (list available adjacent))
      (proofread-correct-buffer)
      (should (equal (buffer-string) "hellowrld"))
      (should (equal proofread--diagnostics (list adjacent)))
      (should
       (equal (proofread-diagnostic-range adjacent) '( 6 . 10)))
      (should (equal (buffer-substring-no-properties 6 10) "wrld")))))

(ert-deftest
    proofread-test-corrections-affected-state-preserves-adapter-order
    ()
  "Keep correction affected-state ordering around the shared scan."
  (with-temp-buffer
    (insert "abcdefghijkl")
    (proofread-mode 1)
    (let* ((right-adjacent
            (proofread-test--diagnostic-for-range 7 9 "gh"))
           (zero-right
            (proofread-test--diagnostic-for-range 7 7 ""))
           (contains
            (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
           (zero-correction
            (proofread-test--diagnostic-for-range 10 10 ""))
           (overlap
            (proofread-test--diagnostic-for-range 3 5 "cd"))
           (main
            (proofread-test--diagnostic-for-range 4 7 "def"))
           (left-adjacent
            (proofread-test--diagnostic-for-range 1 4 "abc"))
           (diagnostics
            (list right-adjacent zero-right contains zero-correction
                  overlap main left-adjacent))
           (installed-overlays
            (proofread-test--install-diagnostics diagnostics))
           (expected-overlays
            (list (nth 1 installed-overlays)
                  (nth 2 installed-overlays)
                  (nth 3 installed-overlays)
                  (nth 4 installed-overlays)
                  (nth 5 installed-overlays)))
           (expected-diagnostics
            (list zero-correction zero-right main overlap contains))
           (affected-state
            (proofread--corrections-affected-state
             (list (cons zero-correction "X")
                   (cons main "Y")))))
      (should (equal (car affected-state) expected-overlays))
      (should (cl-every #'eq (car affected-state)
                        expected-overlays))
      (should (equal (cdr affected-state) expected-diagnostics))
      (should (cl-every #'eq (cdr affected-state)
                        expected-diagnostics)))))

(ert-deftest proofread-test-correct-buffer-prefers-navigation-order ()
  "Skip overlapping diagnostics after the first correction."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let ((long
           (proofread-test--diagnostic-with-suggestions
            1 5 "abcd" '( "long")))
          (short
           (proofread-test--diagnostic-with-suggestions
            1 3 "ab" '( "XY"))))
      (proofread-test--install-diagnostics (list long short))
      (should (eq (proofread-correct-buffer) 'applied))
      (should (equal (buffer-string) "XYcdef"))
      (should-not proofread--diagnostics))))

(ert-deftest
    proofread-test-correct-buffer-deduplicates-zero-width-position ()
  "Apply one diagnostic at a shared insertion point."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '( "X")))
          (second
           (proofread-test--diagnostic-with-suggestions
            2 2 "" '( "Y"))))
      (proofread-test--install-diagnostics (list first second))
      (proofread-correct-buffer)
      (should (equal (buffer-string) "aXb"))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-correct-buffer-is-one-undo-step ()
  "One undo restores every replacement made by buffer correction."
  (with-temp-buffer
    (insert "helo wrld tail")
    (buffer-enable-undo)
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '( "world")))
          (survivor
           (proofread-test--diagnostic-with-suggestions
            11 15 "tail" nil)))
      (proofread-test--install-diagnostics (list first second
                                                 survivor))
      (setq buffer-undo-list nil)
      (proofread-correct-buffer)
      (should (equal (buffer-string) "hello world tail"))
      (should (equal (proofread-diagnostic-range survivor) '( 13 .
                                                              17)))
      (undo)
      (should (equal (buffer-string) "helo wrld tail"))
      (should (equal (proofread-diagnostic-range survivor) '( 11 .
                                                              15)))
      (should (equal (buffer-substring-no-properties 11 15)
                     "tail")))))

(ert-deftest proofread-test-correct-buffer-rolls-back-on-edit-error ()
  "Preserve text and diagnostics when correction raises an error."
  (with-temp-buffer
    (insert "helo wrld")
    (add-text-properties 1 5 '( read-only t))
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '( "world"))))
      (proofread-test--install-diagnostics (list first second))
      (should-error (proofread-correct-buffer))
      (should (equal (buffer-string) "helo wrld"))
      (should (equal proofread--diagnostics (list first second)))
      (should (= (length (proofread--current-buffer-overlays)) 2)))))

(ert-deftest
    proofread-test-correct-buffer-revalidates-after-selection ()
  "Never overwrite edits made during suggestion selection."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello" "hullo"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (erase-buffer)
                   (insert "user text")
                   "hello")))
        (should-error (proofread-correct-buffer) :type 'user-error))
      (should (equal (buffer-string) "user text"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-correction-uses-revalidated-range-for-state ()
  "Use the validated live range when stored state misses an edit."
  (with-temp-buffer
    (insert "ahelo")
    (proofread-mode 1)
    (let ((survivor
           (proofread-test--diagnostic-for-range 2 2 ""))
          (target
           (proofread-test--diagnostic-with-suggestions
            2 6 "helo" '( "hello" "hullo"))))
      (proofread-test--install-diagnostics (list survivor target))
      (goto-char 3)
      (cl-letf
          (((symbol-function 'completing-read)
            (lambda (&rest _)
              (let ((failing-hook
                     (lambda (&rest _)
                       (error "Stop range synchronization"))))
                (add-hook 'after-change-functions failing-hook nil t)
                (unwind-protect
                    (condition-case nil
                        (progn
                          (goto-char 2)
                          (insert "q"))
                      (error nil))
                  (remove-hook 'after-change-functions
                               failing-hook t)))
              "hello")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal (buffer-string) "aqhello"))
      (should (equal proofread--diagnostics (list survivor)))
      (should (proofread--overlay-for-diagnostic survivor)))))

(ert-deftest
    proofread-test-correction-rejects-source-delimiter-suggestions ()
  "Corrections cannot introduce comment or string delimiters."
  (dolist (spec '((c-mode "/*helo*/" comment 2 6 "helo" "*/")
                  (emacs-lisp-mode "\"helo\"" docstring 1 5 "helo"
                                   "\"")
                  (emacs-lisp-mode "\"helo\"" docstring 1 5 "helo"
                                   "\\")))
    (with-temp-buffer
      (funcall (nth 0 spec))
      (insert (nth 1 spec))
      (syntax-propertize (point-max))
      (proofread-mode 1)
      (let* ((before (buffer-string))
             (request (list :buffer (current-buffer)
                            :beg (point-min)
                            :end (point-max)
                            :text before
                            :target-kind (nth 2 spec)))
             (diagnostic
              (proofread--diagnostic-from-request-relative-range
               request
               (cons (nth 3 spec) (nth 4 spec))
               (list :kind 'spelling
                     :message "Possible misspelling"
                     :suggestions (list (nth 6 spec))
                     :source proofread-test--backend)))
             (overlay
              (car (proofread-test--install-diagnostics
                    (list diagnostic)))))
        (goto-char (plist-get diagnostic :beg))
        (should-error (proofread-correct-at-point) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal proofread--diagnostics (list diagnostic)))
        (should (overlay-buffer overlay))))))

(ert-deftest proofread-test-correction-allows-safe-comment-text ()
  "A source-aware correction still accepts ordinary comment prose."
  (with-temp-buffer
    (c-mode)
    (insert "/*helo*/")
    (syntax-propertize (point-max))
    (proofread-mode 1)
    (let* ((request (list :buffer (current-buffer)
                          :beg (point-min)
                          :end (point-max)
                          :text (buffer-string)
                          :target-kind 'comment))
           (diagnostic
            (proofread--diagnostic-from-request-relative-range
             request
             '( 2 . 6)
             (list :kind 'spelling
                   :message "Possible misspelling"
                   :suggestions '( "hello!")
                   :source proofread-test--backend))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char (plist-get diagnostic :beg))
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "/*hello!*/")))))

(ert-deftest
    proofread-test-batch-correction-validates-shared-container ()
  "Validate each batch replacement against the updated container."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\"helo wrld\"")
    (syntax-propertize (point-max))
    (proofread-mode 1)
    (let ((first
           (proofread--make-diagnostic
            :beg 2 :end 6 :text "helo" :kind 'spelling
            :suggestions '( "hello") :source 'test
            :target-kind 'docstring))
          (second
           (proofread--make-diagnostic
            :beg 7 :end 11 :text "wrld" :kind 'spelling
            :suggestions '( "world") :source 'test
            :target-kind 'docstring)))
      (proofread-test--install-diagnostics (list first second))
      (should (eq (proofread-correct-buffer) 'applied))
      (should (equal (buffer-string) "\"hello world\"")))))

(ert-deftest
    proofread-test-batch-container-error-rolls-back-transaction ()
  "Roll back batch edits when a source delimiter becomes unsafe."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "\"helo wrld\"")
    (syntax-propertize (point-max))
    (proofread-mode 1)
    (let* ((first
            (proofread--make-diagnostic
             :beg 2 :end 6 :text "helo" :kind 'spelling
             :suggestions '( "\"") :source 'test
             :target-kind 'docstring))
           (second
            (proofread--make-diagnostic
             :beg 7 :end 11 :text "wrld" :kind 'spelling
             :suggestions '( "world") :source 'test
             :target-kind 'docstring))
           (diagnostics (list first second))
           (overlays
            (proofread-test--install-diagnostics diagnostics))
           (calls 0))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (goto-char 5)
      (should-error (proofread-correct-buffer) :type 'user-error)
      (should (equal (buffer-string) "\"helo wrld\""))
      (should (equal proofread--diagnostics diagnostics))
      (should (cl-every #'overlay-buffer overlays))
      (should (= calls 0))
      (should (= (point) 5)))))

(ert-deftest
    proofread-test-narrowed-correction-uses-full-source-container ()
  "Validate source delimiters outside the narrowed restriction."
  (dolist (spec '(("hello" . applied)
                  ("hello\\" . rejected)))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "\"helo\"")
      (syntax-propertize (point-max))
      (proofread-mode 1)
      (let* ((before (buffer-string))
             (diagnostic
              (proofread--make-diagnostic
               :beg 2 :end 6 :text "helo" :kind 'spelling
               :message "Possible misspelling"
               :suggestions (list (car spec)) :source 'test
               :target-kind 'docstring)))
        (proofread-test--install-diagnostics (list diagnostic))
        (narrow-to-region 2 6)
        (goto-char (point-min))
        (if (eq (cdr spec) 'applied)
            (should (eq (proofread-correct-at-point) 'applied))
          (should-error (proofread-correct-at-point) :type
                        'user-error))
        (widen)
        (should (equal (buffer-string)
                       (if (eq (cdr spec) 'applied)
                           "\"hello\""
                         before)))))))

(ert-deftest
    proofread-test-correction-invalidates-nested-same-buffer-edit ()
  "A correction hook cannot leave a remotely edited diagnostic stale."
  (with-temp-buffer
    (insert "helo tail")
    (proofread-mode 1)
    (let ((first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "tail" '( "tall")))
          nested-edit)
      (proofread-test--install-diagnostics (list first second))
      (add-hook
       'after-change-functions
       (lambda (&rest _)
         (unless nested-edit
           (setq nested-edit t)
           (save-excursion
             (goto-char (point-min))
             (when (search-forward "tail" nil t)
               (replace-match "fail" t t)))))
       nil t)
      (goto-char (point-min))
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "hello fail"))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-correction-does-not-inhibit-other-buffer-edits ()
  "Limit correction invalidation inhibition to its source buffer."
  (let ((source (generate-new-buffer
                 " *proofread-correction-source*"))
        (other (generate-new-buffer " *proofread-correction-other*")))
    (unwind-protect
        (progn
          (with-current-buffer other
            (insert "helo")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" '( "hello")))))
          (with-current-buffer source
            (insert "wrng")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "wrng" '( "wrong"))))
            (let (nested-edit)
              (add-hook
               'after-change-functions
               (lambda (&rest _)
                 (unless nested-edit
                   (setq nested-edit t)
                   (with-current-buffer other
                     (goto-char 2)
                     (delete-char 1)
                     (insert "x"))))
               nil t)
              (goto-char (point-min))
              (should (eq (proofread-correct-at-point) 'applied))
              (should (equal (buffer-string) "wrong"))))
          (with-current-buffer other
            (should (equal (buffer-string) "hxlo"))
            (should-not proofread--diagnostics)
            (should-not proofread--overlays)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest
    proofread-test-failed-correction-repairs-other-buffer-edits ()
  "Repair edits in another buffer after rolling back a correction."
  (let ((source (generate-new-buffer " *proofread-failed-source*"))
        (other (generate-new-buffer " *proofread-failed-other*")))
    (unwind-protect
        (progn
          (with-current-buffer other
            (insert "helo")
            (proofread-mode 1)
            (proofread-test--install-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" '( "hello")))))
          (with-current-buffer source
            (emacs-lisp-mode)
            (insert "\"helo\"")
            (syntax-propertize (point-max))
            (proofread-mode 1)
            (let ((diagnostic
                   (proofread--make-diagnostic
                    :beg 2 :end 6 :text "helo" :kind 'spelling
                    :message "Possible misspelling"
                    :suggestions '( "hello\\") :source 'test
                    :target-kind 'docstring))
                  nested-edit)
              (proofread-test--install-diagnostics (list diagnostic))
              (add-hook
               'after-change-functions
               (lambda (&rest _)
                 (unless nested-edit
                   (setq nested-edit t)
                   (with-current-buffer other
                     (goto-char 2)
                     (delete-char 1)
                     (insert "x"))))
               nil t)
              (goto-char 2)
              (should-error (proofread-correct-at-point) :type
                            'user-error)
              (should (equal (buffer-string) "\"helo\""))
              (should (equal proofread--diagnostics (list
                                                     diagnostic)))
              (should (= (length proofread--overlays) 1))))
          (with-current-buffer other
            (should (equal (buffer-string) "hxlo"))
            (should-not proofread--diagnostics)
            (should-not proofread--overlays)))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest proofread-test-correct-buffer-notifies-diagnostics-once
    ()
  "Buffer correction emits one final diagnostics notification."
  (with-temp-buffer
    (insert "helo wrld")
    (proofread-mode 1)
    (let ((calls 0)
          (first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '( "world"))))
      (proofread-test--install-diagnostics (list first second))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (proofread-correct-buffer)
      (should (= calls 1)))))

(ert-deftest proofread-test-apply-no-suggestion-reports-unavailable ()
  "Report missing suggestions without editing."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 5
            :text "helo"
            :kind 'spelling
            :message "Possible misspelling")))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-invalid-range-rejected ()
  "Suggestion application rejects out-of-buffer diagnostic ranges."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 999
            :text "helo"
            :kind 'spelling
            :suggestions '( "hello"))))
      (setq proofread--diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-stale-overlay-rejected ()
  "Reject diagnostics without live owned overlays."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread--make-diagnostic
             :beg 1
             :end 5
             :text "helo"
             :kind 'spelling
             :suggestions '( "hello")))
           (overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic)))))
      (delete-overlay overlay)
      (goto-char 2)
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "helo")))))

(ert-deftest proofread-test-apply-text-mismatch-rejected ()
  "Reject changed diagnostic text before replacement."
  (with-temp-buffer
    (insert "hell")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 1
            :end 5
            :text "helo"
            :kind 'spelling
            :suggestions '( "hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 2)
      (should-error (proofread-correct-at-point) :type 'user-error)
      (should (equal (buffer-string) "hell")))))

(ert-deftest proofread-test-apply-undo-restores-original-text ()
  "Undo restores text replaced by `proofread-correct-at-point'."
  (with-temp-buffer
    (insert "aa helo zz")
    (buffer-enable-undo)
    (setq buffer-undo-list nil)
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 4
            :end 8
            :text "helo"
            :kind 'spelling
            :suggestions '( "hello"))))
      (proofread-test--install-diagnostics (list diagnostic))
      (goto-char 5)
      (proofread-correct-at-point)
      (should (equal (buffer-string) "aa hello zz"))
      (undo)
      (should (equal (buffer-string) "aa helo zz")))))

(ert-deftest proofread-test-apply-invalidates-proofread-overlays ()
  "Suggestion application removes affected proofread overlays only."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (let* ((target
            (proofread--make-diagnostic
             :beg 4
             :end 8
             :text "helo"
             :kind 'spelling
             :suggestions '( "hello")))
           (overlap
            (proofread-test--diagnostic-for-range 5 8 "elo"))
           (outside
            (proofread-test--diagnostic-for-range 9 11 "zz"))
           (overlays
            (proofread-test--install-diagnostics
             (list target overlap outside)))
           (target-overlay (nth 0 overlays))
           (overlap-overlay (nth 1 overlays))
           (outside-overlay (nth 2 overlays))
           (foreign-overlay (make-overlay 3 9)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread--mark-current-diagnostic target)
      (goto-char 5)
      (proofread-correct-at-point)
      (should-not (overlay-buffer target-overlay))
      (should-not (overlay-buffer overlap-overlay))
      (should (overlay-buffer outside-overlay))
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--current-diagnostic)
      (should (equal proofread--diagnostics (list outside))))))

(ert-deftest
    proofread-test-non-apply-commands-do-not-apply-suggestions ()
  "Navigation and description do not apply suggestions automatically."
  (save-window-excursion
    (with-temp-buffer
      (insert " helo world")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread--make-diagnostic
              :beg 2
              :end 6
              :text "helo"
              :kind 'spelling
              :message "Possible misspelling"
              :suggestions '( "hello")))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 1)
        (proofread-next)
        (should (equal (buffer-string) text))
        (proofread-describe)
        (should (equal (buffer-string) text))))))

;;;; Ignore tests

(ert-deftest proofread-test-ignore-key-uses-diagnostic-origin-language
    ()
  "Prefer diagnostic origin language in ignore keys."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal))
        (proofread-profile 'current)
        (proofread-profiles
         '((current :language "fr" :checkers nil))))
    (cl-labels
        ((with-language
           (diagnostic language)
           (plist-put diagnostic :language language)))
      (let ((diagnostic
             (with-language
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'spelling)
              "en"))
            (same
             (with-language
              (proofread-test--diagnostic-with-kind
               10 14 "helo" 'spelling)
              "en"))
            (different-language
             (with-language
              (proofread-test--diagnostic-with-kind
               10 14 "helo" 'spelling)
              "fr"))
            (different-kind
             (with-language
              (proofread-test--diagnostic-with-kind
               10 14 "helo" 'grammar)
              "en"))
            (different-text
             (with-language
              (proofread-test--diagnostic-with-kind
               10 14 "wrld" 'spelling)
              "en"))
            (different-message
             (with-language
              (proofread--make-diagnostic
               :beg 10 :end 14 :text "helo" :kind 'spelling
               :message "Different issue" :suggestions '( "hello")
               :source 'test)
              "en"))
            (without-language
             (proofread-test--diagnostic-with-kind
              20 24 "word" 'spelling)))
        (should (equal (proofread--diagnostic-ignore-key diagnostic)
                       '( :language "en" :text "helo" :kind spelling
                          :message "Possible issue" :source
                          test)))
        (should
         (equal
          (plist-get
           (proofread--diagnostic-ignore-key without-language)
           :language)
          "fr"))
        (proofread--record-ignored-diagnostic diagnostic)
        (should (proofread--diagnostic-ignored-p same))
        (should-not
         (proofread--diagnostic-ignored-p different-language))
        (should-not (proofread--diagnostic-ignored-p different-kind))
        (should-not (proofread--diagnostic-ignored-p different-text))
        (should-not (proofread--diagnostic-ignored-p
                     different-message))))))

(ert-deftest proofread-test-ignore-command-removes-matching-overlays
    ()
  "Record ignored keys and remove their proofread overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (with-temp-buffer
      (insert "helo wrld helo")
      (proofread-mode 1)
      (let* ((target
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'spelling))
             (unrelated
              (proofread-test--diagnostic-with-kind
               6 10 "wrld" 'spelling))
             (same-key
              (proofread-test--diagnostic-with-kind
               11 15 "helo" 'spelling))
             (overlays
              (proofread-test--install-diagnostics
               (list target unrelated same-key)))
             (target-overlay (nth 0 overlays))
             (unrelated-overlay (nth 1 overlays))
             (same-key-overlay (nth 2 overlays))
             (foreign-overlay (make-overlay 1 15))
             (text (buffer-string)))
        (overlay-put foreign-overlay 'category 'foreign-overlay)
        (proofread--mark-current-diagnostic target)
        (goto-char 2)
        (should (eq (proofread-ignore) 'ignored))
        (should (proofread--diagnostic-ignored-p target))
        (should-not (overlay-buffer target-overlay))
        (should-not (overlay-buffer same-key-overlay))
        (should (overlay-buffer unrelated-overlay))
        (should (overlay-buffer foreign-overlay))
        (should-not proofread--current-diagnostic)
        (should (equal proofread--diagnostics (list unrelated)))
        (should-not (proofread-diagnostic-at-point 2))
        (should (eq (proofread-diagnostic-at-point 7) unrelated))
        (should (equal (buffer-string) text))))))

(ert-deftest proofread-test-ignore-command-removes-aggregate-members
    ()
  "Record and remove every raw member of an aggregate at point."
  (let ((proofread--ignored-diagnostics
         (make-hash-table :test #'equal)))
    (with-temp-buffer
      (insert "helo")
      (let ((proofread-auto-check nil)
            (first
             (proofread-test--diagnostic-with-checker
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'spelling)
              'first))
            (second
             (proofread-test--diagnostic-with-checker
              (proofread-test--diagnostic-with-kind
               1 5 "helo" 'grammar)
              'second))
            (control
             (proofread-test--diagnostic-with-checker
              (proofread-test--diagnostic-with-kind
               1 5 "other" 'style)
              'control)))
        (setq first (plist-put first :checker-ordinal 0))
        (setq second (plist-put second :checker-ordinal 1))
        (setq control (plist-put control :checker-ordinal 2))
        (proofread-mode 1)
        (proofread-test--install-diagnostics
         (list first second control))
        (goto-char 2)
        (should
         (equal
          (proofread--diagnostic-members
           (proofread-diagnostic-at-point))
          (list first second)))
        (should (eq (proofread-ignore) 'ignored))
        (should (proofread--diagnostic-ignored-p first))
        (should (proofread--diagnostic-ignored-p second))
        (should-not (proofread--diagnostic-ignored-p control))
        (should (equal proofread--diagnostics (list control)))
        (should (= (length proofread--overlays) 1))
        (should (eq (proofread-diagnostic-at-point) control))))))

(ert-deftest proofread-test-ignore-command-away-from-diagnostic ()
  "`proofread-ignore' away from diagnostics reports no target."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (with-temp-buffer
      (insert "helo wrld")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread-test--diagnostic-with-kind
              1 5 "helo" 'spelling))
            (text (buffer-string)))
        (proofread-test--install-diagnostics (list diagnostic))
        (goto-char 8)
        (should-error (proofread-ignore) :type 'user-error)
        (should (equal (buffer-string) text))
        (should-not (proofread--diagnostic-ignored-p diagnostic))
        (should (= (length proofread--overlays) 1))))))

(ert-deftest proofread-test-ignore-filter-preserves-different-key ()
  "Filter ignored diagnostics before creating overlays."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (with-temp-buffer
      (insert "helo helo wrld")
      (proofread-mode 1)
      (let ((ignored
             (proofread-test--diagnostic-with-kind
              1 5 "helo" 'spelling))
            (different-kind
             (proofread-test--diagnostic-with-kind
              6 10 "helo" 'grammar))
            (different-text
             (proofread-test--diagnostic-with-kind
              11 15 "wrld" 'spelling)))
        (proofread--record-ignored-diagnostic ignored)
        (proofread--apply-backend-diagnostics
         (list ignored different-kind different-text))
        (should (equal proofread--diagnostics
                       (list different-kind different-text)))
        (should (= (length proofread--overlays) 2))
        (let ((displayed (mapcar (lambda (overlay)
                                   (overlay-get
                                    overlay
                                    'proofread-diagnostic))
                                 proofread--overlays)))
          (should (member different-kind displayed))
          (should (member different-text displayed))
          (should-not (member ignored displayed)))))))

(ert-deftest proofread-test-ignore-filters-backend-and-cache-results
    ()
  "Create no overlays for ignored backend or cached diagnostics."
  (let ((proofread--ignored-diagnostics (make-hash-table :test
                                                         #'equal)))
    (with-temp-buffer
      (insert "helo")
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
               (request (proofread-test--make-profile-request chunk))
               (diagnostic
                (proofread-test--diagnostic-with-kind
                 1 5 "helo" 'spelling))
               (entry (proofread--make-cache-entry
                       request (list diagnostic))))
          (proofread--record-ignored-diagnostic diagnostic)
          (should (eq (proofread--handle-backend-result
                       (proofread--backend-success-result
                        request (list diagnostic)))
                      'applied))
          (should-not proofread--diagnostics)
          (should-not proofread--overlays)
          (should (eq (proofread--apply-cache-entry request entry)
                      'applied))
          (should-not proofread--diagnostics)
          (should-not proofread--overlays))))))

;;;; Listing tests

(ert-deftest proofread-test-negative-request-log-limit-is-safe ()
  "A negative direct request-log limit is clamped instead of looping."
  (with-temp-buffer
    (proofread-mode 1)
    (setq proofread--request-log-enabled t)
    (let ((proofread-request-log-max-records -1))
      (proofread--request-log-record-event
       (list :type 'chunk-request
             :time (current-time)
             :log-id 1
             :request-id 1
             :buffer (current-buffer)
             :beg 1
             :end 1
             :request (list :log-id 1 :id 1 :buffer
                            (current-buffer))))
      (should-not proofread--request-log-order)
      (should (= (hash-table-count proofread--request-log-records)
                 0)))))

(ert-deftest
    proofread-test-request-log-buffer-lists-recorded-requests ()
  "List a buffer's request ranges."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-request-list-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "aa helo\nbb")
            (proofread-mode 1)
            (let* ((request
                    (list :log-id 9001
                          :id 7
                          :buffer source
                          :beg 4
                          :end 8
                          :text "helo"
                          :backend proofread-test--backend))
                   (name (proofread--request-log-list-buffer-name
                          source)))
              (unwind-protect
                  (progn
                    (proofread-show-buffer-requests source)
                    (proofread--request-log-record-event
                     (list :type 'chunk-request
                           :time (current-time)
                           :log-id 9001
                           :request-id 7
                           :buffer source
                           :beg 4
                           :end 8
                           :request request
                           :chunk request))
                    (proofread-test--flush-request-log-refresh source)
                    (with-current-buffer name
                      (should (eq major-mode
                                  'proofread-requests-buffer-mode))
                      (should (eq proofread--request-log-list-source
                                  source))
                      (should (= (length tabulated-list-entries) 1))
                      (let* ((entry (car tabulated-list-entries))
                             (id (car entry))
                             (columns (cadr entry)))
                        (should (= (plist-get id :key) 9001))
                        (should (equal (aref columns 0) "7"))
                        (should (equal (aref columns 1) "ready"))
                        (should (equal (aref columns 3) "1"))
                        (should (equal (aref columns 4) "3"))
                        (should (equal (aref columns 5) "4-8"))
                        (should (string-prefix-p
                                 "proofre" (aref columns 6)))
                        (should (equal (aref columns 7) "helo")))))
                (when-let* ((buffer (get-buffer name)))
                  (kill-buffer buffer)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-request-log-list-registry-coalesces-refresh ()
  "Coalesce list refreshes without scanning unrelated buffers."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source (generate-new-buffer
                 " *proofread-request-registry-source*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "helo")
            (proofread-mode 1))
          (setq list-buffer
                (proofread-show-buffer-requests source))
          (proofread-show-buffer-requests source)
          (with-current-buffer source
            (should (equal proofread--request-log-list-buffers
                           (list list-buffer))))
          (should (= (cl-count source proofread--request-log-sources)
                     1))
          (let ((refreshes 0)
                (schedules 0)
                refresh-function
                refresh-arguments
                (request (list :log-id 9002
                               :id 8
                               :buffer source
                               :beg 1
                               :end 5
                               :text "helo"
                               :backend proofread-test--backend)))
            (cl-letf (((symbol-function 'buffer-list)
                       (lambda (&optional _frame)
                         (error "Unexpected global buffer scan")))
                      ((symbol-function 'run-at-time)
                       (lambda (_time _repeat function
                                      &rest arguments)
                         (setq schedules (1+ schedules))
                         (setq refresh-function function)
                         (setq refresh-arguments arguments)
                         'proofread-test-request-log-timer))
                      ((symbol-function
                        'proofread--request-log-list-refresh)
                       (lambda ()
                         (setq refreshes (1+ refreshes)))))
              (proofread--request-log-record-event
               (list :type 'chunk-request
                     :time (current-time)
                     :log-id 9002
                     :request-id 8
                     :buffer source
                     :beg 1
                     :end 5
                     :request request
                     :chunk request))
              (proofread--request-log-record-event
               (list :type 'queued-request
                     :time (current-time)
                     :log-id 9002
                     :request-id 8
                     :buffer source
                     :beg 1
                     :end 5
                     :request request
                     :backend proofread-test--backend))
              (should (= schedules 1))
              (should (= refreshes 0))
              (apply refresh-function refresh-arguments))
            (should (= refreshes 1))))
      (dolist (buffer (list list-buffer source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-request-log-list-registry-prunes-dead-buffers ()
  "Prune dead request list buffers from their source registry."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source (generate-new-buffer
                 " *proofread-request-prune-source*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "helo")
            (proofread-mode 1))
          (setq list-buffer
                (proofread-show-buffer-requests source))
          (with-current-buffer list-buffer
            (let ((kill-buffer-hook nil))
              (kill-buffer list-buffer)))
          (with-current-buffer source
            (should proofread--request-log-list-buffers)
            (proofread--refresh-request-log-list-buffers)
            (should-not proofread--request-log-list-buffers))
          (proofread--request-log-disable-source source))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest
    proofread-test-request-log-buffer-follows-visible-requests ()
  "Follow real visible dispatch in the request list."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-request-live-source*")))
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert (concat "第一句。"
                            "第二句。"))
            (proofread-mode 1)
            (let ((proofread-context-size 0)
                  (proofread-max-concurrent-requests 1)
                  (recorder (proofread-test--make-backend-recorder))
                  (name (proofread--request-log-list-buffer-name
                         source)))
              (unwind-protect
                  (proofread-test--with-profile
                    (cl-letf (((symbol-function 'window-start)
                               (lambda (&optional _window)
                                 (point-min)))
                              ((symbol-function 'window-end)
                               (lambda (&optional _window _update)
                                 (point-max)))
                              ((symbol-function
                                'proofread--backend-check)
                               (plist-get recorder :function)))
                      (proofread-show-buffer-requests source)
                      (proofread-check-visible-range)
                      (proofread-test--flush-request-log-refresh
                       source)
                      (with-current-buffer name
                        (should (= (length tabulated-list-entries) 2))
                        (let ((statuses
                               (mapcar (lambda (entry)
                                         (aref (cadr entry) 1))
                                       tabulated-list-entries)))
                          (should (member "waiting" statuses))
                          (should (member "queued" statuses))))
                      (let* ((requests (funcall
                                        (plist-get recorder
                                                   :requests)))
                             (callbacks (funcall
                                         (plist-get recorder
                                                    :callbacks)))
                             (first-request (car requests))
                             (first-callback (car callbacks)))
                        (should
                         (eq
                          (funcall
                           first-callback
                           (proofread--backend-success-result
                            first-request nil))
                          'applied)))
                      (proofread-test--flush-request-log-refresh
                       source)
                      (with-current-buffer name
                        (let ((statuses
                               (mapcar (lambda (entry)
                                         (aref (cadr entry) 1))
                                       tabulated-list-entries)))
                          (should (member "applied" statuses))
                          (should (member "waiting" statuses))))))
                (when-let* ((buffer (get-buffer name)))
                  (kill-buffer buffer)))))
        (when (buffer-live-p source)
          (kill-buffer source))))))

(ert-deftest
    proofread-test-request-log-registry-preserves-other-sources ()
  "Keep monitoring other sources when one source or list closes."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source-a (generate-new-buffer
                   " *proofread-request-source-a*"))
        (source-b (generate-new-buffer
                   " *proofread-request-source-b*"))
        list-a
        list-b)
    (unwind-protect
        (save-window-excursion
          (dolist (source (list source-a source-b))
            (with-current-buffer source
              (insert "helo")
              (proofread-mode 1)))
          (setq list-a (proofread-show-buffer-requests source-a))
          (setq list-b (proofread-show-buffer-requests source-b))
          (should (= (length proofread--request-log-sources) 2))
          (should (memq #'proofread--request-log-record-event
                        proofread-request-log-hook))
          (kill-buffer source-a)
          (should-not (buffer-live-p list-a))
          (should (buffer-live-p list-b))
          (should (equal proofread--request-log-sources
                         (list source-b)))
          (with-current-buffer source-b
            (should proofread--request-log-enabled)
            (should (equal proofread--request-log-list-buffers
                           (list list-b))))
          (should (memq #'proofread--request-log-record-event
                        proofread-request-log-hook))
          (kill-buffer list-b)
          (with-current-buffer source-b
            (should-not proofread--request-log-enabled)
            (should-not proofread--request-log-list-buffers))
          (should-not proofread--request-log-sources)
          (should-not (memq #'proofread--request-log-record-event
                            proofread-request-log-hook)))
      (dolist (buffer (list list-a list-b source-a source-b))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-source-kill-closes-associated-list-buffers ()
  "Killing a source closes its lists and releases request-log hooks."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-list-source-kill*"))
          diagnostics-name
          requests-name)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (setq diagnostics-name
                  (proofread--diagnostics-buffer-name))
            (setq requests-name
                  (proofread--request-log-list-buffer-name source))
            (proofread-show-buffer-diagnostics)
            (proofread-show-buffer-requests source)
            (should (get-buffer diagnostics-name))
            (should (get-buffer requests-name))
            (should (memq #'proofread--request-log-record-event
                          proofread-request-log-hook))
            (kill-buffer source)
            (should-not (get-buffer diagnostics-name))
            (should-not (get-buffer requests-name))
            (should-not (memq #'proofread--request-log-record-event
                              proofread-request-log-hook)))
        (when (buffer-live-p source)
          (kill-buffer source))
        (dolist (name (list diagnostics-name requests-name))
          (when-let* ((buffer (and name (get-buffer name))))
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-request-log-source-kill-after-mode-disable-cleans-up ()
  "Keep source kill cleanup after `proofread-mode' is disabled."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source (generate-new-buffer
                 " *proofread-request-disabled-source*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (insert "helo")
            (proofread-mode 1))
          (setq list-buffer
                (proofread-show-buffer-requests source))
          (with-current-buffer source
            (proofread-mode -1))
          (should (buffer-live-p list-buffer))
          (kill-buffer source)
          (should-not (buffer-live-p list-buffer))
          (should-not proofread--request-log-sources)
          (should-not (memq #'proofread--request-log-record-event
                            proofread-request-log-hook)))
      (dolist (buffer (list list-buffer source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-source-major-mode-change-closes-associated-lists ()
  "Close source-owned lists before a source changes major mode."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source (generate-new-buffer
                 " *proofread-list-source-mode-change*"))
        diagnostics-buffer
        requests-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (insert "helo")
          (proofread-mode 1)
          (proofread-show-buffer-diagnostics)
          (setq diagnostics-buffer
                (get-buffer (proofread--diagnostics-buffer-name)))
          (setq requests-buffer
                (proofread-show-buffer-requests source))
          (fundamental-mode)
          (should-not (buffer-live-p diagnostics-buffer))
          (should-not (buffer-live-p requests-buffer))
          (should-not proofread--request-log-sources)
          (should-not (memq #'proofread--request-log-record-event
                            proofread-request-log-hook)))
      (dolist (buffer
               (list diagnostics-buffer requests-buffer source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-diagnostics-source-kill-after-mode-disable-cleans-up ()
  "Keep diagnostics-list cleanup after `proofread-mode' is disabled."
  (let ((source (generate-new-buffer
                 " *proofread-diagnostics-disabled-source*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (insert "helo")
          (proofread-mode 1)
          (proofread-show-buffer-diagnostics)
          (setq list-buffer
                (get-buffer (proofread--diagnostics-buffer-name)))
          (proofread-mode -1)
          (should (buffer-live-p list-buffer))
          (should (memq #'proofread--source-list-cleanup
                        kill-buffer-hook))
          (kill-buffer source)
          (should-not (buffer-live-p list-buffer)))
      (dolist (buffer (list list-buffer source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-diagnostics-source-major-mode-change-cleans-up ()
  "Close a diagnostics-only list before its source changes mode."
  (let ((source (generate-new-buffer
                 " *proofread-diagnostics-source-mode-change*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer source)
          (insert "helo")
          (proofread-mode 1)
          (proofread-show-buffer-diagnostics)
          (setq list-buffer
                (get-buffer (proofread--diagnostics-buffer-name)))
          (fundamental-mode)
          (should-not (buffer-live-p list-buffer)))
      (dolist (buffer (list list-buffer source))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest
    proofread-test-list-major-mode-change-releases-source-hooks ()
  "Unregister source state when an auxiliary list changes mode."
  (save-window-excursion
    (let ((source (generate-new-buffer
                   " *proofread-list-mode-change*"))
          diagnostics-buffer
          requests-buffer)
      (unwind-protect
          (progn
            (switch-to-buffer source)
            (insert "helo")
            (proofread-mode 1)
            (proofread-show-buffer-diagnostics)
            (setq diagnostics-buffer
                  (get-buffer (proofread--diagnostics-buffer-name)))
            (proofread-show-buffer-requests source)
            (setq requests-buffer
                  (get-buffer
                   (proofread--request-log-list-buffer-name source)))
            (with-current-buffer requests-buffer
              (fundamental-mode))
            (with-current-buffer source
              (should-not proofread--request-log-enabled))
            (should-not (memq #'proofread--request-log-record-event
                              proofread-request-log-hook))
            (with-current-buffer diagnostics-buffer
              (fundamental-mode))
            (with-current-buffer source
              (should-not proofread--diagnostics-list-buffers)
              (should-not
               (memq #'proofread--refresh-diagnostics-list-buffers
                     proofread-diagnostics-changed-hook))))
        (dolist (buffer (list diagnostics-buffer requests-buffer
                              source))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-request-log-preserves-backend-http-details ()
  "Preserve backend-specific HTTP request and response details."
  (let* ((url
          (concat
           "https://private-user:private-password@example.test:9443"
           "/v2/check?api-key=private-key#private-fragment"))
         (parameters
          (propertize
           "language=en-US&text=helo"
           'proofread-test-api-key "secret-text-property"))
         (request-details
          (proofread--request-log-backend-request-details
           (list :backend 'languagetool
                 :method "POST"
                 :url url
                 :parameters parameters)))
         (opaque-details
          (proofread--request-log-backend-request-details
           '( :backend languagetool
              :method "POST"
              :parameters (("language" . "en-US")
                           ("text" . "helo")))))
         (response-details
          (proofread--request-log-backend-response-details
           (list :backend 'languagetool
                 :url url
                 :http-status 200
                 :response "{\"matches\":[]}"))))
    (should (equal (plist-get request-details :method) "POST"))
    (should
     (equal (plist-get request-details :url)
            "https://example.test:9443"))
    (should
     (equal (plist-get request-details :parameters)
            "language=en-US&text=helo"))
    (should-not
     (text-properties-at
      0 (plist-get request-details :parameters)))
    (should-not (plist-get opaque-details :parameters))
    (should (= (plist-get response-details :http-status) 200))
    (should
     (equal (plist-get response-details :url)
            "https://example.test:9443"))
    (dolist (details (list request-details response-details))
      (proofread-test--assert-secret-not-printed
       "private-user" details)
      (proofread-test--assert-secret-not-printed
       "private-password" details)
      (proofread-test--assert-secret-not-printed
       "/v2/check" details)
      (proofread-test--assert-secret-not-printed
       "private-key" details)
      (proofread-test--assert-secret-not-printed
       "private-fragment" details))))

(ert-deftest
    proofread-test-request-log-projects-scalars-by-field-type ()
  "Omit opaque scalar values that do not match their field type."
  (with-temp-buffer
    (let* ((sentinel
            "PROOFREAD-TEST-OPAQUE-SCALAR-MUST-NOT-APPEAR")
           (opaque-symbol (make-symbol sentinel))
           (safe-event
            (proofread--request-log-safe-event
             (list :type 'backend-request
                   :time sentinel
                   :log-id sentinel
                   :request-id opaque-symbol
                   :buffer sentinel
                   :status sentinel
                   :backend sentinel
                   :method opaque-symbol
                   :pass sentinel
                   :max-passes opaque-symbol
                   :strategy sentinel)))
           (safe-request
            (proofread--request-log-safe-request
             (list :log-id sentinel
                   :id opaque-symbol
                   :generation sentinel
                   :buffer sentinel
                   :text opaque-symbol
                   :language opaque-symbol
                   :profile sentinel
                   :checker-name sentinel
                   :checker-ordinal opaque-symbol
                   :major-mode sentinel
                   :target-kind sentinel
                   :backend sentinel)))
           (typed-event
            (proofread--request-log-safe-event
             (list :type 'backend-request
                   :time (current-time)
                   :log-id 41
                   :request-id 42
                   :buffer (current-buffer)
                   :status 'active
                   :backend proofread-test--backend
                   :method "POST"
                   :pass 1
                   :max-passes 2
                   :strategy 'typed))))
      (should (equal safe-event '( :type backend-request)))
      (should-not safe-request)
      (proofread-test--assert-secret-not-printed sentinel safe-event)
      (proofread-test--assert-secret-not-printed sentinel safe-request)
      (should (= (plist-get typed-event :log-id) 41))
      (should (= (plist-get typed-event :request-id) 42))
      (should (eq (plist-get typed-event :buffer) (current-buffer)))
      (should (eq (plist-get typed-event :status) 'active))
      (should (eq (plist-get typed-event :backend)
                  proofread-test--backend))
      (should (equal (plist-get typed-event :method) "POST"))
      (should (= (plist-get typed-event :pass) 1))
      (should (= (plist-get typed-event :max-passes) 2))
      (should (eq (plist-get typed-event :strategy) 'typed)))))

(ert-deftest proofread-test-request-monitor-redacts-opaque-values ()
  "Exclude opaque backend values from every request-monitor surface."
  (save-window-excursion
    (let* ((sentinel
            "PROOFREAD-TEST-API-KEY-MUST-NOT-APPEAR")
           (backend 'proofread-test-secret-backend)
           (profile 'proofread-test-secret-profile)
           (checker 'proofread-test-secret-checker)
           (provider
            (vector 'proofread-test-provider :api-key sentinel))
           (handle
            (vector 'proofread-test-handle provider))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (proofread--request-log-sources nil)
           (proofread-request-log-hook nil)
           (source
            (generate-new-buffer
             " *proofread-request-secret-source*"))
           raw-request
           raw-result
           callback
           events
           reports
           records
           list-buffer
           detail-buffer)
      (proofread-test--register-cancellable-backend
       backend
       (lambda (request backend-callback)
         (setq raw-request request)
         (setq callback backend-callback)
         (proofread--record-request-event
          request 'backend-request
          :backend backend
          :method "POST"
          :strategy 'test-json
          :schema
          (propertize
           "{\"type\":\"object\"}"
           'proofread-test-api-key sentinel)
          :parameters
          (propertize
           "language=en-US&text=helo"
           'proofread-test-api-key sentinel)
          :prompt provider
          :prompt-text "Review this text: helo."
          :opaque provider)
         handle)
       #'ignore)
      (unwind-protect
          (let ((proofread-auto-check nil)
                (proofread-cache-max-entries 0)
                (proofread-context-size 0)
                (proofread-max-concurrent-requests 1)
                (proofread-profile profile)
                (proofread-profiles
                 (list
                  (list
                   profile
                   :language "en-US"
                   :checkers
                   (list
                    (list :name checker
                          :backend backend
                          :options
                          (list :provider provider)))))))
            (switch-to-buffer source)
            (text-mode)
            (insert "helo.")
            (proofread-mode 1)
            (let ((proofread-request-log-hook
                   (list (lambda (event)
                           (push event events)))))
              (cl-letf
                  (((symbol-function
                     'proofread-report-warning-without-window)
                    (lambda (detail summary)
                      (push (list detail summary) reports))))
                (setq list-buffer
                      (proofread-show-buffer-requests source))
                (proofread-check-buffer)
                (should raw-request)
                (should callback)
                (should
                 (string-match-p
                  (regexp-quote sentinel)
                  (prin1-to-string raw-request)))
                (should
                 (string-match-p
                  (regexp-quote sentinel)
                  (prin1-to-string handle)))
                (dolist (opaque-schema
                         (list provider '( :type "object")))
                  (should-not
                   (plist-member
                    (proofread--request-log-safe-event
                     (list :type 'backend-request
                           :schema opaque-schema))
                    :schema)))
                (should-not
                 (plist-get
                  (proofread--request-log-safe-event
                   '( :type backend-request
                      :parameters (("text" . "helo"))))
                  :parameters))
                ;; Exercise the recorder's defensive projection too,
                ;; independently of the safe hook boundary.
                (proofread--request-log-record-event
                 (list :type 'backend-dispatched
                       :time (current-time)
                       :log-id (plist-get raw-request :log-id)
                       :request-id (plist-get raw-request :id)
                       :buffer source
                       :beg (plist-get raw-request :beg)
                       :end (plist-get raw-request :end)
                       :request raw-request
                       :backend backend
                       :handle handle))
                (proofread--record-request-event
                 raw-request 'backend-response
                 :backend backend
                 :http-status 503
                 :response "Safe fake provider response"
                 :error
                 (list 'proofread-test-transport-error provider)
                 :message provider)
                (setq raw-result
                      (proofread--backend-error-result
                       raw-request
                       (list 'proofread-test-backend-error provider)
                       "Fake backend failure"))
                (should
                 (string-match-p
                  (regexp-quote sentinel)
                  (prin1-to-string raw-result)))
                (proofread--record-request-event
                 raw-request 'backend-result
                 :backend backend
                 :result raw-result)
                (should (eq (funcall callback raw-result) 'error))
                (should reports)))
            (setq events (nreverse events))
            (proofread-test--flush-request-log-refresh source)
            (with-current-buffer source
              (setq records (proofread--request-log-record-list)))
            (should (= (length records) 1))
            (let* ((record (car records))
                   (safe-request (plist-get record :request))
                   (safe-checker-identity
                    (plist-get safe-request :checker-identity))
                   (backend-dispatched
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-dispatched))
                     events))
                   (backend-request
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-request))
                     events))
                   (backend-response
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-response))
                     events))
                   (backend-result
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'backend-result))
                     events))
                   (final-result
                    (cl-find-if
                     (lambda (event)
                       (eq (plist-get event :type)
                           'final-result))
                     events)))
              (dolist (value (append events records reports))
                (proofread-test--assert-secret-not-printed
                 sentinel value))
              (should backend-dispatched)
              (should-not
               (plist-member backend-dispatched :handle))
              (should-not (plist-member record :handle))
              (dolist (property
                       '( :checker-options :state :cache-key :handle))
                (should-not (plist-member safe-request property)))
              (should (eq (plist-get safe-request :profile) profile))
              (should
               (eq (plist-get safe-request :checker-name) checker))
              (should (eq (plist-get safe-request :backend) backend))
              (should (equal (plist-get safe-request :language)
                             "en-US"))
              (should (= (plist-get safe-request :beg) 1))
              (should (= (plist-get safe-request :end) 6))
              (should (equal (plist-get safe-request :text) "helo."))
              (should
               (stringp (plist-get safe-checker-identity
                                   :fingerprint)))
              (dolist (event events)
                (should (plist-get event :time))
                (when-let* ((event-request
                             (plist-get event :request)))
                  (should
                   (equal
                    (plist-get event-request :checker-identity)
                    safe-checker-identity))))
              (should
               (equal (plist-get backend-request :prompt-text)
                      "Review this text: helo."))
              (should
               (equal (plist-get backend-request :schema)
                      "{\"type\":\"object\"}"))
              (should-not
               (text-properties-at
                0 (plist-get backend-request :schema)))
              (should
               (equal (plist-get backend-request :parameters)
                      "language=en-US&text=helo"))
              (should-not
               (text-properties-at
                0 (plist-get backend-request :parameters)))
              (should (eq (plist-get backend-request :strategy)
                          'test-json))
              (should-not (plist-member backend-request :prompt))
              (should-not (plist-member backend-request :opaque))
              (should
               (equal (plist-get backend-response :response)
                      "Safe fake provider response"))
              (should
               (eq (plist-get backend-response :error)
                   'proofread-test-transport-error))
              (should
               (equal (plist-get backend-response :message)
                      "Backend request failed"))
              (let ((logged-result
                     (plist-get backend-result :result)))
                (should (eq (plist-get logged-result :status) 'error))
                (should
                 (eq (plist-get logged-result :error)
                     'proofread-test-backend-error))
                (should
                 (equal (plist-get logged-result :message)
                        "Backend request failed")))
              (should (eq (plist-get final-result :status) 'error))
              (should (eq (plist-get record :status) 'error))
              (should (eq (plist-get record :final-status) 'error))
              (should (plist-get record :created-at))
              (should (plist-get record :updated-at))
              (with-current-buffer list-buffer
                (proofread-test--assert-secret-not-printed
                 sentinel tabulated-list-entries)
                (proofread-test--assert-secret-not-printed
                 sentinel (buffer-string))
                (should (= (length tabulated-list-entries) 1))
                (let* ((entry (car tabulated-list-entries))
                       (id (car entry))
                       (columns (cadr entry)))
                  (should (eq (plist-get id :source-buffer) source))
                  (should (equal (plist-get id :key)
                                 (plist-get record :key)))
                  (should (equal (aref columns 1) "error"))
                  (should (equal (aref columns 5) "1-6"))
                  (should (string-prefix-p
                           "proofre" (aref columns 6)))
                  (should (equal (aref columns 7) "helo.")))
                (goto-char (point-min))
                (should (tabulated-list-get-id))
                (proofread-show-request))
              (setq detail-buffer
                    (get-buffer
                     (proofread--request-log-request-buffer-name
                      record)))
              (should (buffer-live-p detail-buffer))
              (with-current-buffer detail-buffer
                (should buffer-read-only)
                (should (eq major-mode 'lisp-data-mode))
                (proofread-test--assert-secret-not-printed
                 sentinel (buffer-string))
                (goto-char (point-min))
                (dolist (heading '( ";;; Summary"
                                    ";;; Chunk request"
                                    ";;; Lifecycle events"
                                    ";;; Backend requests"
                                    ";;; Backend responses"
                                    ";;; Parsed backend results"
                                    ";;; Final result"))
                  (should (search-forward heading nil t)))
                (goto-char (point-min))
                (should (search-forward
                         "Review this text: helo." nil t))
                (should (search-forward
                         "Safe fake provider response" nil t)))))
        (dolist (buffer
                 (delete-dups
                  (list detail-buffer list-buffer source)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest
    proofread-test-request-monitor-redacts-checker-failure ()
  "Redact opaque condition data from checker preparation failures."
  (save-window-excursion
    (let* ((sentinel
            "PROOFREAD-TEST-CHECKER-KEY-MUST-NOT-APPEAR")
           (backend 'proofread-test-failing-secret-backend)
           (profile 'proofread-test-failing-secret-profile)
           (checker 'proofread-test-failing-secret-checker)
           (provider
            (vector 'proofread-test-provider :api-key sentinel))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (proofread--request-log-sources nil)
           (proofread-request-log-hook nil)
           (source
            (generate-new-buffer
             " *proofread-checker-failure-secret-source*"))
           backend-called
           raw-error-text
           events
           reports
           records
           list-buffer)
      (proofread--register-backend
       backend
       :check
       (lambda (&rest _)
         (setq backend-called t)
         (error "Failing checker must not submit work"))
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :checker-identity
       (lambda (_normalized-checker)
         (setq raw-error-text
               (format "Identity failure for %S" provider))
         (error "%s" raw-error-text))
       :cancel #'ignore)
      (unwind-protect
          (let ((proofread-auto-check nil)
                (proofread-cache-max-entries 0)
                (proofread-context-size 0)
                (proofread-profile profile)
                (proofread-profiles
                 (list
                  (list
                   profile
                   :language "en-US"
                   :checkers
                   (list
                    (list :name checker
                          :backend backend
                          :options
                          (list :provider provider)))))))
            (switch-to-buffer source)
            (text-mode)
            (insert "helo.")
            (proofread-mode 1)
            (let ((proofread-request-log-hook
                   (list (lambda (event)
                           (push event events)))))
              (cl-letf
                  (((symbol-function
                     'proofread-report-warning-without-window)
                    (lambda (detail summary)
                      (push (list detail summary) reports))))
                (setq list-buffer
                      (proofread-show-buffer-requests source))
                (proofread-check-buffer)))
            (setq events (nreverse events))
            (should raw-error-text)
            (should
             (string-match-p (regexp-quote sentinel)
                             raw-error-text))
            (should-not backend-called)
            (should (= (length reports) 1))
            (proofread-test--flush-request-log-refresh source)
            (with-current-buffer source
              (setq records (proofread--request-log-record-list)))
            (should (= (length records) 1))
            (dolist (value (append events records reports))
              (proofread-test--assert-secret-not-printed
               sentinel value))
            (let ((failure
                   (cl-find-if
                    (lambda (event)
                      (eq (plist-get event :type)
                          'checker-dispatch-failed))
                    events))
                  (record (car records)))
              (should failure)
              (should (eq (plist-get failure :profile) profile))
              (should (eq (plist-get failure :checker-name) checker))
              (should (eq (plist-get failure :backend) backend))
              (should (eq (plist-get failure :phase)
                          'checker-identity))
              (should (eq (plist-get failure :status) 'error))
              (should (eq (plist-get failure :error) 'error))
              (should (string-match-p
                       "checker identity calculation"
                       (plist-get failure :message)))
              (should (eq (plist-get record :profile) profile))
              (should (eq (plist-get record :checker-name) checker))
              (should (eq (plist-get record :backend) backend))
              (should (eq (plist-get record :phase)
                          'checker-identity))
              (should (eq (plist-get record :status) 'error)))
            (with-current-buffer list-buffer
              (proofread-test--assert-secret-not-printed
               sentinel tabulated-list-entries)
              (proofread-test--assert-secret-not-printed
               sentinel (buffer-string))
              (should (= (length tabulated-list-entries) 1))
              (let ((columns
                     (cadr (car tabulated-list-entries))))
                (should (equal (aref columns 1) "error")))))
        (dolist (buffer (list list-buffer source))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

;;;; Target selection tests

(ert-deftest proofread-test-targets-default-auto-and-buffer-local ()
  "`proofread-targets' defaults to automatic buffer-local selection."
  (should (custom-variable-p 'proofread-targets))
  (should (eq (default-value 'proofread-targets) 'auto))
  (should (local-variable-if-set-p 'proofread-targets))
  (with-temp-buffer
    (setq proofread-targets 'comments)
    (should (local-variable-p 'proofread-targets))
    (should (eq proofread-targets 'comments))
    (with-temp-buffer
      (should (eq proofread-targets 'auto)))))

(ert-deftest
    proofread-test-targets-auto-prog-selects-prose-containers ()
  "Select comments and docstrings as automatic programming targets."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n"
            ";; Comment prose token.\n"
            "(setq ordinary \"Ordinary string token.\")\n"
            "(defun sample ()\n"
            "  \"Docstring prose token.\"\n"
            "  code-token)\n")
    (let* ((chunks
            (proofread-test--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (eq proofread-targets 'auto))
      (should (string-match-p "Comment prose token" text))
      (should (string-match-p "Docstring prose token" text))
      (should-not (string-match-p "Ordinary string token" text))
      (should-not (string-match-p "setq code-token" text))
      (should (equal (delete-dups
                      (mapcar (lambda (chunk)
                                (plist-get chunk :target-kind))
                              chunks))
                     '( comment docstring))))))

(ert-deftest proofread-test-targets-auto-text-mode-selects-all-text ()
  "Automatic non-programming targets include the accessible text."
  (with-temp-buffer
    (text-mode)
    (insert "Plain prose sentence. Another sentence.")
    (let ((chunks
           (proofread-test--request-ready-chunks-for-ranges
            (list (cons (point-min) (point-max))))))
      (should (string-match-p
               "Plain prose sentence"
               (proofread-test--combined-chunk-text chunks)))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-policy) 'all))
        (should (eq (plist-get chunk :target-kind) 'text))
        (should (= (plist-get chunk :domain-beg) (point-min)))
        (should (= (plist-get chunk :domain-end) (point-max)))))))

(ert-deftest proofread-test-targets-explicit-programming-policies ()
  "Explicit target policies select their requested programming text."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n"
            ";; Comment prose token.\n"
            "(setq ordinary \"Ordinary string token.\")\n"
            "(defun sample ()\n"
            "  \"Docstring prose token.\"\n"
            "  code-token)\n")
    (dolist (case '((all t t t)
                    (comments t nil nil)
                    (docstrings nil t nil)
                    (comments-and-docstrings t t nil)))
      (setq-local proofread-targets (car case))
      (let* ((chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (text (proofread-test--combined-chunk-text chunks)))
        (should (eq (not (null (string-match-p
                                "Comment prose token" text)))
                    (nth 1 case)))
        (should (eq (not (null (string-match-p
                                "Docstring prose token" text)))
                    (nth 2 case)))
        (should (eq (not (null (string-match-p
                                "setq code-token" text)))
                    (nth 3 case)))))))

(ert-deftest proofread-test-targets-auto-c-mode-selects-comments ()
  "Include C line and block comments but exclude strings."
  (with-temp-buffer
    (c-mode)
    (insert "int code_token = 1;\n"
            "// C line comment prose.\n"
            "char *ordinary = \"not // comment prose\";\n"
            "/* C block comment prose. */\n")
    (let* ((chunks
            (proofread-test--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (string-match-p "C line comment prose" text))
      (should (string-match-p "C block comment prose" text))
      (should-not (string-match-p "code_token" text))
      (should-not (string-match-p "not // comment prose" text))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-kind) 'comment))))))

(ert-deftest proofread-test-targets-auto-python-selects-docstrings ()
  "Include Python docstrings but exclude ordinary strings."
  (with-temp-buffer
    (insert "value = \"ordinary prose string\"\n\n"
            "def sample():\n"
            "    \"\"\"Python docstring prose.\"\"\"\n"
            "    return value\n")
    (python-mode)
    (let* ((chunks
            (proofread-test--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (text (proofread-test--combined-chunk-text chunks)))
      (should (string-match-p "Python docstring prose" text))
      (should-not (string-match-p "ordinary prose string" text))
      (should-not (string-match-p "return value" text))
      (dolist (chunk chunks)
        (should (eq (plist-get chunk :target-kind) 'docstring))))))

(ert-deftest proofread-test-target-region-and-narrowing-boundaries ()
  "Clip target regions and context to the current restriction."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Outside prefix. Before context sentence. "
            "Selected target sentence. After context sentence. "
            "Outside suffix.\n"
            "(setq code-token 1)\n")
    (goto-char (point-min))
    (search-forward "Before")
    (let ((narrow-beg (match-beginning 0)))
      (search-forward "Selected")
      (let ((selected-beg (match-beginning 0)))
        (search-forward "sentence.")
        (let ((selected-end (point)))
          (search-forward "Outside suffix")
          (let ((narrow-end (match-beginning 0)))
            (narrow-to-region narrow-beg narrow-end)
            (let* ((chunks
                    (proofread-test--request-ready-chunks-for-ranges
                     (list (cons selected-beg selected-end))))
                   (chunk (car chunks))
                   (payload
                    (concat (plist-get chunk :context-before)
                            (plist-get chunk :text)
                            (plist-get chunk :context-after))))
              (should (= (length chunks) 1))
              (should (= (plist-get chunk :beg) selected-beg))
              (should (= (plist-get chunk :end) selected-end))
              (should (= (plist-get chunk :domain-beg) (point-min)))
              (should (= (plist-get chunk :domain-end) (point-max)))
              (should (equal (plist-get chunk :text)
                             "Selected target sentence."))
              (should (string-match-p "Before context sentence"
                                      payload))
              (should (string-match-p "After context sentence"
                                      payload))
              (should-not (string-match-p "Outside prefix" payload))
              (should-not (string-match-p "Outside suffix" payload))
              (should-not (string-match-p "code-token"
                                          payload)))))))))

(ert-deftest proofread-test-check-at-point-programming-targets ()
  "Point checking rejects code and dispatches the containing comment."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq code-token 1)\n;; Comment point prose.\n")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "code-token")
    (should-error (proofread-check-at-point) :type 'user-error)
    (goto-char (point-min))
    (search-forward "point prose")
    (let ((proofread-context-size 0)
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-at-point)
          (let* ((requests (funcall (plist-get recorder :requests)))
                 (request (car requests)))
            (should (= (length requests) 1))
            (should (eq (plist-get request :target-kind) 'comment))
            (should (string-match-p "Comment point prose"
                                    (plist-get request :text)))))))))

(ert-deftest
    proofread-test-target-metadata-is-part-of-request-and-cache-key ()
  "Carry target policy and kind into requests and cache keys."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Comment metadata prose.\n"
            "(defun sample ()\n  \"Docstring metadata prose.\")\n")
    (setq-local proofread-targets 'comments-and-docstrings)
    (let* ((chunks
            (proofread-test--request-ready-chunks-for-ranges
             (list (cons (point-min) (point-max)))))
           (comment
            (cl-find 'comment chunks
                     :key (lambda (chunk)
                            (plist-get chunk :target-kind))))
           (docstring
            (cl-find 'docstring chunks
                     :key (lambda (chunk)
                            (plist-get chunk :target-kind))))
           (request (proofread--make-backend-request
                     comment proofread-test--backend))
           (key
            (proofread--cache-key comment proofread-test--backend)))
      (should comment)
      (should docstring)
      (should (eq (plist-get request :target-policy)
                  'comments-and-docstrings))
      (should (eq (plist-get request :target-kind) 'comment))
      (should (= (plist-get request :domain-beg)
                 (plist-get comment :domain-beg)))
      (should (= (plist-get request :domain-end)
                 (plist-get comment :domain-end)))
      (should (eq (plist-get key :target-policy)
                  'comments-and-docstrings))
      (should (eq (plist-get key :target-kind) 'comment))
      (let ((changed-kind (copy-sequence comment))
            (changed-policy (copy-sequence comment)))
        (setq changed-kind
              (plist-put changed-kind :target-kind 'docstring))
        (setq changed-policy
              (plist-put changed-policy :target-policy 'all))
        (should-not (equal key
                           (proofread--cache-key
                            changed-kind proofread-test--backend)))
        (should-not (equal key
                           (proofread--cache-key
                            changed-policy
                            proofread-test--backend)))))))

(ert-deftest proofread-test-target-option-change-makes-request-stale
    ()
  "Reject old results after changing the target policy."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Comment stale prose.\n")
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request
                     chunk proofread-test--backend))
           (beg (plist-get request :beg))
           (diagnostic
            (proofread-test--diagnostic-for-range
             beg (+ beg 7)
             (buffer-substring-no-properties beg (+ beg 7)))))
      (setq-local proofread-targets 'all)
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-programming-request-freshness-preserves-point ()
  "Asynchronous comment freshness checks preserve point and mark."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Checked prose sentence.\n"
            "(setq cursor_and_mark_stay_here 1)\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((proofread-context-size 0)
             (chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk)))
        (goto-char (point-min))
        (search-forward "cursor_and_mark")
        (push-mark (line-end-position) t t)
        (let ((before-point (point))
              (before-mark (mark t))
              (before-mark-active mark-active))
          (should (proofread--fresh-request-p request))
          (should (= (point) before-point))
          (should (= (mark t) before-mark))
          (should (eq mark-active before-mark-active)))))))

(ert-deftest
    proofread-test-backend-nil-prunes-checked-out-of-target-diagnostics
    ()
  "A backend-less check prunes invalid checked diagnostics only."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Valid comment prose.\n"
            "(setq invalid-code 1)\n"
            "(setq outside-code 2)\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "Valid")
    (let* ((valid-beg (match-beginning 0))
           (valid-end (match-end 0))
           (valid
            (proofread-test--diagnostic-for-range
             valid-beg valid-end "Valid")))
      (search-forward "invalid-code")
      (let* ((invalid-beg (match-beginning 0))
             (invalid-end (match-end 0))
             (check-end (line-end-position))
             (invalid
              (proofread-test--diagnostic-for-range
               invalid-beg invalid-end "invalid-code")))
        (search-forward "outside-code")
        (let* ((outside-beg (match-beginning 0))
               (outside-end (match-end 0))
               (outside
                (proofread-test--diagnostic-for-range
                 outside-beg outside-end "outside-code"))
               (overlays
                (proofread-test--install-diagnostics
                 (list valid invalid outside)))
               (valid-overlay (nth 0 overlays))
               (invalid-overlay (nth 1 overlays))
               (outside-overlay (nth 2 overlays))
               (proofread-profile 'disabled)
               (proofread-profiles '((disabled :checkers nil))))
          (proofread-check-region (point-min) check-end)
          (should (equal proofread--diagnostics (list valid outside)))
          (should (overlay-buffer valid-overlay))
          (should-not (overlay-buffer invalid-overlay))
          (should (overlay-buffer outside-overlay)))))))

(ert-deftest
    proofread-test-target-pruning-keeps-zero-width-domain-end ()
  "Keep a zero-width diagnostic at its target's end."
  (with-temp-buffer
    (insert "Hello")
    (proofread-mode 1)
    (let* ((position (point-max))
           (diagnostic
            (proofread--make-diagnostic
             :beg position :end position :text "" :kind 'grammar
             :message "Missing punctuation" :suggestions '( ".")
             :source 'test :target-kind 'text))
           (overlay
            (car (proofread-test--install-diagnostics
                  (list diagnostic)))))
      (proofread--prune-diagnostics-outside-targets
       (list (cons (point-min) (point-max)))
       (list (list :kind 'text
                   :target-policy 'all
                   :domain-beg (point-min)
                   :domain-end (point-max))))
      (should (equal proofread--diagnostics (list diagnostic)))
      (should (overlay-buffer overlay)))))

(ert-deftest
    proofread-test-consecutive-line-comments-share-context-domain ()
  "Indented adjacent line comments share context until a blank line."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "    ;; First context sentence.\n"
            "    ;; Later target sentence.\n"
            "\n"
            "    ;; Isolated comment sentence.\n")
    (setq-local proofread-targets 'comments)
    (goto-char (point-min))
    (search-forward "Later")
    (let ((later-beg (match-beginning 0)))
      (search-forward "sentence.")
      (let ((later-end (point)))
        (search-forward "Isolated")
        (let ((isolated-beg (match-beginning 0)))
          (search-forward "sentence.")
          (let* ((isolated-end (point))
                 (domains
                  (proofread--comment-domains-for-ranges
                   (list (cons (point-min) (point-max)))))
                 (first-domain (nth 0 domains))
                 (isolated-domain (nth 1 domains))
                 (proofread-context-size 300)
                 (proofread-context-sentences-before 1)
                 (proofread-context-sentences-after 1)
                 (later-chunk
                  (car
                   (proofread-test--request-ready-chunks-for-ranges
                    (list (cons later-beg later-end)))))
                 (isolated-chunk
                  (car
                   (proofread-test--request-ready-chunks-for-ranges
                    (list (cons isolated-beg isolated-end))))))
            (should (= (length domains) 2))
            (should (< (car first-domain) later-beg))
            (should (<= later-end (cdr first-domain)))
            (should (< (cdr first-domain) (car isolated-domain)))
            (should (= (plist-get later-chunk :domain-beg)
                       (car first-domain)))
            (should (= (plist-get later-chunk :domain-end)
                       (cdr first-domain)))
            (should (string-match-p
                     "First context sentence"
                     (plist-get later-chunk :context-before)))
            (should (= (plist-get isolated-chunk :domain-beg)
                       (car isolated-domain)))
            (should (= (plist-get isolated-chunk :domain-end)
                       (cdr isolated-domain)))
            (should-not (string-match-p
                         "Later target sentence"
                         (plist-get isolated-chunk
                                    :context-before)))))))))

(ert-deftest
    proofread-test-consecutive-comments-use-language-sentences ()
  "Use language sentences rather than comment source lines."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; This sentence begins here and\n"
            ";; ends on this line. A second sentence starts\n"
            ";; and ends here.\n")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-targets 'comments)
    (proofread-mode 1)
    (let ((proofread-context-size 0)
          (proofread-max-concurrent-requests 10)
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (proofread-check-buffer)
          (let ((requests (funcall (plist-get recorder :requests))))
            (should (= (length requests) 2))
            (should (string-match-p
                     "This sentence begins"
                     (plist-get (nth 0 requests) :text)))
            (should (string-match-p
                     "ends on this line\\."
                     (plist-get (nth 0 requests) :text)))
            (should (string-match-p
                     "A second sentence starts"
                     (plist-get (nth 1 requests) :text)))
            (should (string-match-p
                     "and ends here\\."
                     (plist-get (nth 1 requests) :text)))
            (dolist (request requests)
              (should (eq (plist-get request :target-kind) 'comment))
              (should (equal
                       (plist-get request :text)
                       (buffer-substring-no-properties
                        (plist-get request :beg)
                        (plist-get request :end)))))))))))

(ert-deftest
    proofread-test-comment-delimiters-follow-major-mode-syntax ()
  "Mode-specific comment delimiters do not split hard-wrapped prose."
  (dolist
      (case
       (list
        (list
         'emacs-lisp-mode
         (concat
          ";; This file is free software: you can redistribute it "
          "and/or modify\n"
          ";; it under the terms of the GNU General Public License "
          "as published\n"
          ";; by the Free Software Foundation, either version 3 "
          "of the License,\n"
          ";; or (at your option) any later version.\n")
         "This file is free software" "any later version")
        (list
         'c-mode
         (concat "// First C line continues\n"
                 "// through the next source line.\n")
         "First C line" "next source line")
        (list
         'c-mode
         (concat "/* First block line continues\n"
                 " * through the next source line. */\n")
         "First block line" "next source line")
        (list
         'html-mode
         (concat "<!-- First HTML line continues\n"
                 "through the next source line. -->\n")
         "First HTML line" "next source line")))
    (with-temp-buffer
      (funcall (nth 0 case))
      (setq-local proofread-targets 'comments)
      (insert (nth 1 case))
      (let* ((chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (chunk (car chunks)))
        (should (= (length chunks) 1))
        (should (string-match-p (regexp-quote (nth 2 case))
                                (plist-get chunk :text)))
        (should (string-match-p (regexp-quote (nth 3 case))
                                (plist-get chunk :text)))
        (should (eq (plist-get chunk :target-kind) 'comment))
        (should (equal
                 (plist-get chunk :text)
                 (buffer-substring-no-properties
                  (plist-get chunk :beg)
                  (plist-get chunk :end))))))))

(ert-deftest
    proofread-test-hard-wrapped-comment-sentence-stays-in-context ()
  "Comment context keeps a logical sentence spanning source lines."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; First hard-wrapped part of one\n"
            ";; sentence ends here.\n"
            ";; Target sentence.\n")
    (setq-local proofread-targets 'comments)
    (goto-char (point-min))
    (search-forward "Target sentence.")
    (let* ((proofread-context-size 300)
           (proofread-context-sentences-before 1)
           (proofread-context-sentences-after 0)
           (chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (match-beginning 0) (match-end 0))))))
           (context (plist-get chunk :context-before)))
      (should (string-match-p "First hard-wrapped part" context))
      (should (string-match-p "sentence ends here\\." context)))))

(ert-deftest proofread-test-ignore-changes-make-request-stale ()
  "Stale requests only when relevant ignore settings change."
  (with-temp-buffer
    (insert "Alpha prose.")
    (setq-local proofread-auto-check nil)
    (setq-local proofread-ignored-properties
                '( proofread-test-ignore))
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (chars-tick (buffer-chars-modified-tick)))
        (add-text-properties
         (plist-get request :beg)
         (1+ (plist-get request :beg))
         '( proofread-test-ignore t))
        (should (= chars-tick (buffer-chars-modified-tick)))
        (should-not (proofread--fresh-request-p request)))))
  (with-temp-buffer
    (insert "Beta prose.")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk)))
        (setq-local proofread-ignored-properties
                    '( proofread-test-ignore))
        (should (proofread--fresh-request-p request))))))

(ert-deftest
    proofread-test-python-docstring-predicate-receives-full-triple-string
    ()
  "Custom predicates receive a complete Python triple-quoted string."
  (with-temp-buffer
    (insert "def sample():\n"
            "    \"\"\"Python docstring prose.\n"
            "    Continued prose.\"\"\"\n"
            "    return 1\n")
    (python-mode)
    (goto-char (point-min))
    (search-forward "\"\"\"")
    (let ((expected-beg (match-beginning 0)))
      (search-forward "\"\"\"")
      (let ((expected-end (match-end 0))
            calls)
        (setq-local proofread-targets 'docstrings)
        (setq-local
         proofread-docstring-predicate-functions
         (list (lambda (beg end)
                 (push (cons beg end) calls)
                 t)))
        (cl-letf (((symbol-function
                    'proofread--font-lock-docstring-domain)
                   (lambda (_range) nil)))
          (let ((domains
                 (proofread--docstring-domains-for-ranges
                  (list (cons (point-min) (point-max))))))
            (should (equal domains
                           (list (cons expected-beg expected-end))))
            (should calls)
            (dolist (range calls)
              (should (equal range
                             (cons expected-beg expected-end))))))))))

(ert-deftest
    proofread-test-disable-reenable-rejects-old-generation-callback ()
  "Reject old callbacks from a re-enabled mode generation."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((recorder (proofread-test--make-backend-recorder)))
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (plist-get recorder :function)))
          (let* ((old-request
                  (car (proofread-test--dispatch-profile-chunks
                        (proofread-test--request-ready-chunks-for-ranges
                         (list (cons (point-min) (point-max)))))))
                 (old-callback
                  (car (funcall (plist-get recorder :callbacks))))
                 (old-generation (plist-get old-request :generation)))
            (proofread-mode -1)
            (proofread-mode 1)
            (let* ((new-request
                    (car (proofread-test--dispatch-profile-chunks
                          (proofread-test--request-ready-chunks-for-ranges
                           (list (cons (point-min) (point-max)))))))
                   (new-log-id (plist-get new-request :log-id)))
              (should-not (= old-generation
                             (plist-get new-request :generation)))
              (should (eq
                       (funcall
                        old-callback
                        (proofread--backend-success-result
                         old-request
                         (list (proofread-test--diagnostic-for-range
                                1 5 "helo"))))
                       'stale))
              (should (= (length proofread--active-requests) 1))
              (should (= (plist-get (car proofread--active-requests)
                                    :log-id)
                         new-log-id))
              (should-not proofread--diagnostics))))))))

;;;; Backend lifecycle tests

(ert-deftest proofread-test-backend-callback-is-at-most-once ()
  "Complete requests only once when backends callback twice."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request (proofread--make-backend-request
                     chunk proofread-test--backend))
           captured-callback
           (calls 0))
      (cl-letf (((symbol-function 'proofread--backend-check)
                 (lambda (_request callback &optional _backend)
                   (setq captured-callback callback)
                   'proofread-test-handle)))
        (proofread--dispatch-backend-request
         request
         (lambda (_result)
           (setq calls (1+ calls)))
         proofread-test--backend)
        (let ((result (proofread--backend-success-result request
                                                         nil)))
          (funcall captured-callback result)
          (funcall captured-callback result))
        (should (= calls 1))
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-repeated-mode-enable-resets-owned-state ()
  "Explicitly enabling an enabled mode starts a clean generation."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((generation proofread--generation)
           (diagnostic (proofread-test--diagnostic-for-range 1 5
                                                             "helo"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (proofread--cache-write 'old-cache 'old-value)
      (proofread-mode 1)
      (should proofread-mode)
      (should-not (= proofread--generation generation))
      (should-not (overlay-buffer overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--active-requests)
      (should-not proofread--request-queue)
      (should (= (hash-table-count proofread--cache) 0)))))

(ert-deftest
    proofread-test-major-mode-change-tears-down-proofread-mode ()
  "Changing major mode removes Proofread hooks, state, and overlays."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic-for-range 1 5
                                                             "helo"))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (text-mode)
      (should-not proofread-mode)
      (should-not (overlay-buffer overlay))
      (should-not (memq (current-buffer) proofread--mode-buffers))
      (should-not (memq #'proofread--before-change
                        before-change-functions)))))

(ert-deftest
    proofread-test-zero-width-diagnostic-invalidated-by-insertion ()
  "Clear owned state after inserting at a zero-width diagnostic."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let* ((diagnostic
            (proofread--make-diagnostic
             :beg 2 :end 2 :text "" :kind 'grammar
             :message "Missing punctuation" :suggestions '( ",")
             :source 'test))
           (overlay (car (proofread-test--install-diagnostics
                          (list diagnostic)))))
      (goto-char 2)
      (insert ",")
      (should-not (overlay-buffer overlay))
      (should-not proofread--diagnostics)
      (should-not proofread--overlays))))

(ert-deftest
    proofread-test-edit-before-request-invalidates-shifted-duplicate
    ()
  "Stale requests after edits before their source range."
  (with-temp-buffer
    (insert "helo helo")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  '((6 . 10)))))
           (request (proofread--make-backend-request
                     chunk proofread-test--backend)))
      (goto-char (point-min))
      (insert "helo ")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p request)))))

(ert-deftest
    proofread-test-request-cache-key-is-frozen-at-construction ()
  "Freeze request cache keys when constructing requests."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((proofread-test--backend-identity-token "identity-a"))
      (proofread-test--with-profile
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
               (request (proofread-test--make-profile-request chunk))
               (key (plist-get request :cache-key))
               (diagnostic
                (proofread-test--diagnostic-for-range 1 6 "Alpha")))
          (let ((proofread-test--backend-identity-token "identity-b"))
            (proofread--cache-write-request request (list diagnostic))
            (should (equal (plist-get request :cache-key) key))
            (should (gethash key proofread--cache))))))))

(ert-deftest proofread-test-backend-identity-is-snapshotted ()
  "Destructive identity changes cannot mutate pending request keys."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((name (copy-sequence "alpha"))
           (proofread-test--backend-identity-token (list :name name)))
      (proofread-test--with-profile
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
               (request (proofread-test--make-profile-request chunk))
               (work-key-text
                (prin1-to-string (proofread--request-work-key request))))
          (proofread--enqueue-requests
           (list request) proofread-test--backend)
          (aset name 0 ?o)
          (should
           (equal (plist-get (plist-get request :backend-identity)
                             :token)
                  '( :name "alpha")))
          (should (equal (prin1-to-string
                          (proofread--request-work-key request))
                         work-key-text))
          (should (proofread--request-work-pending-p request))
          (should-not (proofread--fresh-request-p request)))))))

(ert-deftest
    proofread-test-backend-identity-change-makes-request-stale ()
  "Invalidate old requests when the backend identity changes."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let ((proofread-test--backend-identity-token "identity-a"))
      (proofread-test--with-profile
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
               (request (proofread-test--make-profile-request chunk)))
          (let ((proofread-test--backend-identity-token "identity-b"))
            (should-not (proofread--fresh-request-p request))))))))

(ert-deftest proofread-test-context-edit-makes-request-stale ()
  "Editing request context invalidates a still-unchanged target."
  (with-temp-buffer
    (insert "Before. Target. After.")
    (proofread-mode 1)
    (goto-char (point-min))
    (search-forward "Target.")
    (let* ((beg (match-beginning 0))
           (end (match-end 0))
           (chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons beg end)))))
           (request (proofread--make-backend-request
                     chunk proofread-test--backend)))
      (goto-char (point-min))
      (delete-char 1)
      (insert "X")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p request)))))

(ert-deftest
    proofread-test-supersede-partitions-before-lifecycle-effects
    ()
  "Publish every superseded partition before hooks and cancellation."
  (with-temp-buffer
    (let* ((request-labels
            '( (101 . active-first)
               (102 . active-retained)
               (103 . active-last)
               (104 . claimed-retained)
               (105 . claimed-selected)
               (106 . queued-selected)
               (107 . queued-retained)
               (108 . replacement)))
           (active-first
            (proofread-test--lifecycle-request
             101 12 14 'active-first-handle))
           (active-retained
            (proofread-test--lifecycle-request
             102 1 4 'active-retained-handle))
           (active-last
            (proofread-test--lifecycle-request
             103 16 18 'active-last-handle))
           (claimed-retained
            (proofread-test--lifecycle-request
             104 30 32))
           (claimed-selected
            (proofread-test--lifecycle-request
             105 10 20 'claimed-selected-handle))
           (queued-selected
            (proofread-test--lifecycle-request
             106 11 13 'queued-selected-handle))
           (queued-retained
            (proofread-test--lifecycle-request
             107 40 42))
           (replacement
            (proofread-test--lifecycle-request 108 10 20))
           (queued-selected-entry
            (list :request queued-selected
                  :backend proofread-test--backend))
           (queued-retained-entry
            (list :request queued-retained
                  :backend proofread-test--backend))
           (selected
            (list active-first active-last claimed-selected
                  queued-selected))
           (retained
            (list active-retained claimed-retained queued-retained))
           (old-requests (append selected retained))
           (proofread--active-requests
            (list active-first active-retained active-last))
           (proofread--claimed-requests
            (list claimed-retained claimed-selected))
           (proofread--request-queue
            (list queued-selected-entry queued-retained-entry))
           (proofread--request-queue-tail
            (last proofread--request-queue))
           (proofread--pending-request-keys
            (proofread-test--pending-request-table old-requests))
           (original-partition
            (symbol-function
             'proofread--partition-pending-requests))
           (partition-calls 0)
           (all-events-before-cancel t)
           event-trace
           cancelled-handles
           first-hook-state
           superseded)
      (let ((proofread-request-log-hook
             (list
              (lambda (event)
                (when (eq (plist-get event :type) 'cancelled)
                  (unless event-trace
                    (setq first-hook-state
                          (and
                           (equal proofread--active-requests
                                  (list active-retained))
                           (equal proofread--claimed-requests
                                  (list claimed-retained))
                           (equal
                            (mapcar
                             (lambda (entry)
                               (plist-get entry :request))
                             proofread--request-queue)
                            (list queued-retained replacement))
                           (eq proofread--request-queue-tail
                               (last proofread--request-queue))
                           (cl-every
                            (lambda (request)
                              (and
                               (proofread--request-state-flag-p
                                request :superseded)
                               (not
                                (proofread--request-work-pending-p
                                 request))))
                            selected)
                           (cl-every
                            #'proofread--request-work-pending-p
                            (append retained
                                    (list replacement))))))
                  (setq event-trace
                        (append
                         event-trace
                         (list
                          (list
                           (alist-get
                            (plist-get event :request-id)
                            request-labels)
                           (plist-get event :reason))))))))))
        (cl-letf
            (((symbol-function
               'proofread--partition-pending-requests)
              (lambda (predicate)
                (setq partition-calls (1+ partition-calls))
                (funcall original-partition predicate)))
             ((symbol-function 'proofread--cancel-request-handle)
              (lambda (handle)
                (unless (= (length event-trace) 4)
                  (setq all-events-before-cancel nil))
                (setq cancelled-handles
                      (append cancelled-handles (list handle))))))
          (setq superseded
                (proofread--supersede-conflicting-requests
                 (list replacement)))
          (should (= partition-calls 1))
          (should
           (equal superseded
                  (list :active (list active-first active-last)
                        :claimed (list claimed-selected)
                        :queued (list queued-selected))))
          (dolist (request selected)
            (should
             (proofread--request-state-flag-p
              request :superseded))
            (should-not
             (proofread--request-state-flag-p request :cancelled))
            (should-not
             (proofread--request-work-pending-p request)))
          (dolist (request retained)
            (should-not
             (proofread--request-state-flag-p
              request :superseded))
            (should
             (proofread--request-work-pending-p request)))
          (should (eq (car proofread--request-queue)
                      queued-retained-entry))
          (should (eq proofread--request-queue-tail
                      (last proofread--request-queue)))
          (should-not event-trace)
          (should-not cancelled-handles)
          (proofread--enqueue-requests
           (list replacement) proofread-test--backend)
          (proofread--finish-superseded-requests superseded)))
      (should first-hook-state)
      (should all-events-before-cancel)
      (should
       (equal event-trace
              '((active-first superseded)
                (active-last superseded)
                (claimed-selected superseded)
                (queued-selected superseded))))
      (should (equal cancelled-handles
                     '( active-first-handle active-last-handle)))
      (dolist (request selected)
        (should
         (proofread--request-state-flag-p request :cancelled))))))

(ert-deftest
    proofread-test-position-shift-partitions-before-lifecycle-effects
    ()
  "Finish shifted-request hooks before cancellation and scheduling."
  (with-temp-buffer
    (let* ((request-labels
            '( (201 . active-first)
               (202 . active-retained)
               (203 . active-last)
               (204 . claimed-retained)
               (205 . claimed-selected)
               (206 . queued-selected)
               (207 . late)))
           (active-first
            (proofread-test--lifecycle-request
             201 1 12 'active-first-handle))
           (active-retained
            (proofread-test--lifecycle-request
             202 1 10 'active-retained-handle))
           (active-last
            (proofread-test--lifecycle-request
             203 20 22 'active-last-handle))
           (claimed-retained
            (proofread-test--lifecycle-request
             204 2 9))
           (claimed-selected
            (proofread-test--lifecycle-request
             205 2 11 'claimed-selected-handle))
           (queued-selected
            (proofread-test--lifecycle-request
             206 5 15 'queued-selected-handle))
           (late
            (proofread-test--lifecycle-request 207 50 52))
           (queued-selected-entry
            (list :request queued-selected
                  :backend proofread-test--backend))
           (selected
            (list active-first active-last claimed-selected
                  queued-selected))
           (retained
            (list active-retained claimed-retained))
           (all-requests (append selected retained))
           (proofread--active-requests
            (list active-first active-retained active-last))
           (proofread--claimed-requests
            (list claimed-retained claimed-selected))
           (proofread--request-queue
            (list queued-selected-entry))
           (proofread--request-queue-tail
            (last proofread--request-queue))
           (proofread--pending-request-keys
            (proofread-test--pending-request-table all-requests))
           (original-partition
            (symbol-function
             'proofread--partition-pending-requests))
           (partition-calls 0)
           (all-events-before-cancel t)
           (schedule-calls 0)
           event-trace
           cancelled-handles
           first-hook-state
           schedule-state)
      (let ((proofread-request-log-hook
             (list
              (lambda (event)
                (when (eq (plist-get event :type) 'cancelled)
                  (unless event-trace
                    (setq first-hook-state
                          (and
                           (equal proofread--active-requests
                                  (list active-retained))
                           (equal proofread--claimed-requests
                                  (list claimed-retained))
                           (null proofread--request-queue)
                           (null proofread--request-queue-tail)
                           (cl-every
                            (lambda (request)
                              (and
                               (proofread--request-invalidated-p
                                request)
                               (not
                                (proofread--request-work-pending-p
                                 request))))
                            selected)
                           (cl-every
                            #'proofread--request-work-pending-p
                            retained)))
                    (proofread--enqueue-requests
                     (list late) proofread-test--backend))
                  (setq event-trace
                        (append
                         event-trace
                         (list
                          (list
                           (alist-get
                            (plist-get event :request-id)
                            request-labels)
                           (plist-get event :reason))))))))))
        (cl-letf
            (((symbol-function
               'proofread--partition-pending-requests)
              (lambda (predicate)
                (setq partition-calls (1+ partition-calls))
                (funcall original-partition predicate)))
             ((symbol-function 'proofread--cancel-request-handle)
              (lambda (handle)
                (unless (= (length event-trace) 4)
                  (setq all-events-before-cancel nil))
                (setq cancelled-handles
                      (append cancelled-handles (list handle)))))
             ((symbol-function 'proofread--schedule-queue-dispatch)
              (lambda ()
                (setq schedule-calls (1+ schedule-calls))
                (setq schedule-state
                      (and
                       (equal cancelled-handles
                              '( active-first-handle
                                 active-last-handle))
                       (equal
                        (mapcar
                         (lambda (entry)
                           (plist-get entry :request))
                         proofread--request-queue)
                        (list late))
                       (eq proofread--request-queue-tail
                           (last proofread--request-queue))))
                'scheduled)))
          (proofread--invalidate-position-shifted-requests 10)))
      (should (= partition-calls 1))
      (should first-hook-state)
      (should all-events-before-cancel)
      (should
       (equal event-trace
              '((active-first stale)
                (active-last stale)
                (claimed-selected stale)
                (queued-selected stale))))
      (should (equal cancelled-handles
                     '( active-first-handle active-last-handle)))
      (should (= schedule-calls 1))
      (should schedule-state)
      (dolist (request selected)
        (should (proofread--request-invalidated-p request))
        (should
         (proofread--request-state-flag-p request :cancelled)))
      (dolist (request retained)
        (should-not (proofread--request-invalidated-p request))
        (should
         (proofread--request-work-pending-p request)))
      (should
       (proofread--request-work-pending-p late)))))

(ert-deftest
    proofread-test-newer-overlapping-result-wins-out-of-order ()
  "A superseded result cannot overwrite a newer overlapping result."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (older (proofread--make-backend-request
                   chunk proofread-test--backend))
           (newer (proofread--make-backend-request
                   chunk proofread-test--backend))
           (old-diagnostic
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '( "hullo")))
           (new-diagnostic
            (proofread-test--diagnostic-with-suggestions
             1 5 "helo" '( "hello"))))
      (proofread--register-active-request older)
      (proofread--finish-superseded-requests
       (proofread--supersede-conflicting-requests (list newer)))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    newer (list new-diagnostic)))
                  'applied))
      (should (eq (proofread--handle-backend-result
                   (proofread--backend-success-result
                    older (list old-diagnostic)))
                  'stale))
      (should
       (equal (proofread-test--diagnostics-without-provenance
               proofread--diagnostics)
              (list new-diagnostic))))))

(ert-deftest
    proofread-test-cache-write-wakes-only-matching-queued-entries ()
  "Wake every matching cache waiter without reordering other work."
  (with-temp-buffer
    (insert "bb aa cc aa")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          cache-hit-log-ids
          (prune-calls 0)
          (reentrant-dispatches 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6) (7 . 9) (10 . 12))))
               (unrelated-a
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (matching-a
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               (unrelated-b
                (proofread-test--make-profile-request
                 (nth 2 chunks)))
               (matching-b
                (proofread-test--make-profile-request
                 (nth 3 chunks)))
               (requests
                (list unrelated-a matching-a unrelated-b matching-b))
               entries
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (should (equal (plist-get matching-a :cache-key)
                         (plist-get matching-b :cache-key)))
          (should-not (equal (plist-get matching-a :cache-key)
                             (plist-get unrelated-a :cache-key)))
          (proofread--enqueue-requests
           requests proofread-test--backend)
          (setq entries (copy-sequence proofread--request-queue))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--cache-write-request matching-a nil)
          (should (= (hash-table-count
                      proofread--cache-woken-queue-entries)
                     2))
          (add-hook
           'proofread-diagnostics-changed-hook
           (lambda ()
             (setq reentrant-dispatches (1+ reentrant-dispatches))
             (proofread--dispatch-queued-requests))
           nil t)
          (let ((original-prune
                 (symbol-function
                  'proofread--prune-stale-active-requests)))
            (cl-letf
                (((symbol-function
                   'proofread--prune-stale-active-requests)
                  (lambda ()
                    (setq prune-calls (1+ prune-calls))
                    (funcall original-prune))))
              (should-not (proofread--dispatch-queued-requests))))
          (should (= prune-calls 1))
          (should (= reentrant-dispatches 2))
          (should
           (equal (nreverse cache-hit-log-ids)
                  (list (plist-get matching-a :log-id)
                        (plist-get matching-b :log-id))))
          (should (= (length proofread--request-queue) 2))
          (should (eq (nth 0 proofread--request-queue)
                      (nth 0 entries)))
          (should (eq (nth 1 proofread--request-queue)
                      (nth 2 entries)))
          (should (proofread--request-work-pending-p unrelated-a))
          (should (proofread--request-work-pending-p unrelated-b))
          (should-not (proofread--request-work-pending-p matching-a))
          (should-not (proofread--request-work-pending-p matching-b))
          (proofread-test--assert-queue-cache-index-consistent))))))

(ert-deftest
    proofread-test-cache-queue-index-follows-lifecycle-removal ()
  "Keep exact cache wakeups synchronized through lifecycle removal."
  (with-temp-buffer
    (insert "aa bb")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6))))
               (request-a
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (request-b
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               (newer-a
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (entry-b nil)
               superseded)
          (proofread--enqueue-requests
           (list request-a request-b) proofread-test--backend)
          (setq entry-b (nth 1 proofread--request-queue))
          (proofread--cache-write-request request-a nil)
          (should (= (hash-table-count
                      proofread--cache-woken-queue-entries)
                     1))
          (setq superseded
                (proofread--supersede-conflicting-requests
                 (list newer-a)))
          (should (equal (plist-get superseded :queued)
                         (list request-a)))
          (should-not
           (gethash (plist-get request-a :cache-key)
                    proofread--request-queue-index))
          (should (eq (car proofread--request-queue) entry-b))
          (should-not (proofread--cache-wakeup-pending-p))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--finish-superseded-requests superseded)
          (should (proofread--request-state-flag-p
                   request-a :cancelled))

          (proofread--cache-write-request request-b nil)
          (should (proofread--cache-wakeup-pending-p))
          (proofread-clear-cache)
          (should-not (proofread--cache-wakeup-pending-p))
          (should (eq (car proofread--request-queue) entry-b))
          (should
           (gethash (plist-get request-b :cache-key)
                    proofread--request-queue-index))
          (proofread-test--assert-queue-cache-index-consistent)

          (proofread--cache-write-request request-b nil)
          (should (proofread--cache-wakeup-pending-p))
          (proofread--clear-scheduled-work)
          (should (proofread--request-state-flag-p
                   request-b :cancelled))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest
    proofread-test-cache-wakeup-rechecks-after-reentrant-clear ()
  "Skip invalidated wakeup snapshots after a cache-hit hook clears cache."
  (with-temp-buffer
    (insert "xx aa aa")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          cleared
          cache-hit-log-ids
          (insert-calls 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6) (7 . 9))))
               (unrelated
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (matching-a
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               (matching-b
                (proofread-test--make-profile-request
                 (nth 2 chunks)))
               (requests (list unrelated matching-a matching-b))
               entries
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (proofread--enqueue-requests
           requests proofread-test--backend)
          (setq entries (copy-sequence proofread--request-queue))
          (proofread--cache-write-request matching-a nil)
          (add-hook
           'proofread-diagnostics-changed-hook
           (lambda ()
             (unless cleared
               (setq cleared t)
               (proofread-clear-cache)))
           nil t)
          (let ((original-insert
                 (symbol-function
                  'proofread--insert-request-queue-entry)))
            (cl-letf
                (((symbol-function
                   'proofread--insert-request-queue-entry)
                  (lambda (&rest arguments)
                    (setq insert-calls (1+ insert-calls))
                    (apply original-insert arguments))))
              (should-not (proofread--dispatch-queued-requests))))
          (should cleared)
          (should (= insert-calls 0))
          (should (equal cache-hit-log-ids
                         (list (plist-get matching-a :log-id))))
          (should (= (length proofread--request-queue) 2))
          (should (eq (nth 0 proofread--request-queue)
                      (nth 0 entries)))
          (should (eq (nth 1 proofread--request-queue)
                      (nth 2 entries)))
          (should (proofread--request-work-pending-p unrelated))
          (should (proofread--request-work-pending-p matching-b))
          (should-not (proofread--request-work-pending-p matching-a))
          (should-not (proofread--cache-wakeup-pending-p))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--clear-scheduled-work)
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-disabling-cache-clears-queued-wakeups ()
  "Discard queued wakeups if caching is disabled before dispatch."
  (with-temp-buffer
    (insert "xx aa")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 128)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (wakeup-checks 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6))))
               (unrelated
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (matching
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               entries)
          (proofread--enqueue-requests
           (list unrelated matching) proofread-test--backend)
          (setq entries (copy-sequence proofread--request-queue))
          (proofread--cache-write-request matching nil)
          (should (proofread--cache-wakeup-pending-p))
          (setq proofread-cache-max-entries 0)
          (let ((original-wakeup-pending
                 (symbol-function
                  'proofread--cache-wakeup-pending-p)))
            (cl-letf
                (((symbol-function
                   'proofread--cache-wakeup-pending-p)
                  (lambda ()
                    (setq wakeup-checks (1+ wakeup-checks))
                    (when (> wakeup-checks 3)
                      (error "Cache wakeup dispatch did not converge"))
                    (funcall original-wakeup-pending))))
              (should-not (proofread--dispatch-queued-requests))))
          (should (<= wakeup-checks 2))
          (should-not (proofread--cache-wakeup-pending-p))
          (should (= (length proofread--request-queue) 2))
          (should (eq (nth 0 proofread--request-queue)
                      (nth 0 entries)))
          (should (eq (nth 1 proofread--request-queue)
                      (nth 1 entries)))
          (should (proofread--request-work-pending-p unrelated))
          (should (proofread--request-work-pending-p matching))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--clear-scheduled-work)
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-cache-write-during-prune-settles-claim ()
  "Consume a same-key cache write made while its request is claimed."
  (with-temp-buffer
    (insert "aa bb")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          cache-written
          cache-hit-log-ids)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6))))
               (waiting
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (active
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (proofread--register-active-request active)
          (proofread--enqueue-requests
           (list waiting) proofread-test--backend)
          (cl-letf
              (((symbol-function 'proofread--fresh-request-p)
                (lambda (request)
                  (when (and (eq request active)
                             (not cache-written))
                    (setq cache-written t)
                    (proofread--cache-write-request waiting nil))
                  t)))
            (should-not (proofread--dispatch-queued-requests)))
          (should cache-written)
          (should (equal cache-hit-log-ids
                         (list (plist-get waiting :log-id))))
          (should-not (proofread--request-work-pending-p waiting))
          (should-not proofread--request-queue)
          (should-not proofread--claimed-requests)
          (should (equal proofread--active-requests (list active)))
          (should-not (proofread--cache-wakeup-pending-p))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--clear-request-work)
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-cache-queue-wakeup-is-checker-isolated ()
  "Do not wake a different checker that happens to check the same text."
  (with-temp-buffer
    (insert "same")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles))
          cache-hit-checkers)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (first (nth 0 (plist-get profile :checkers)))
             (second (nth 1 (plist-get profile :checkers)))
             (chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    '((1 . 5)))))
             (first-request
              (proofread--make-backend-request
               chunk proofread-test--backend first profile))
             (second-request
              (proofread--make-backend-request
               chunk proofread-test--backend second profile))
             second-entry
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (eq (plist-get event :type) 'cache-hit)
                   (push (plist-get (plist-get event :request)
                                    :checker-name)
                         cache-hit-checkers))))))
        (should-not (equal (plist-get first-request :cache-key)
                           (plist-get second-request :cache-key)))
        ;; Put the unrelated checker first so ordinary FIFO dispatch
        ;; reaches the concurrency limit before the exact cache waiter.
        (proofread--enqueue-requests
         (list second-request first-request)
         proofread-test--backend)
        (setq second-entry (car proofread--request-queue))
        (proofread--cache-write-request first-request nil)
        (should-not (proofread--dispatch-queued-requests))
        (should (equal cache-hit-checkers '( first)))
        (should (= (length proofread--request-queue) 1))
        (should (eq (car proofread--request-queue) second-entry))
        (should (proofread--request-work-pending-p second-request))
        (should-not (proofread--request-work-pending-p first-request))
        (proofread-test--assert-queue-cache-index-consistent)))))

(ert-deftest proofread-test-cache-queue-wakeup-honors-eviction ()
  "Do not apply a queued cache wakeup after its entry is evicted."
  (with-temp-buffer
    (insert "aa bb")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 1)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          cache-hit-texts)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6))))
               (request-a
                (proofread-test--make-profile-request
                 (nth 0 chunks)))
               (request-b
                (proofread-test--make-profile-request
                 (nth 1 chunks)))
               entry-a
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get (plist-get event :request) :text)
                           cache-hit-texts))))))
          (proofread--enqueue-requests
           (list request-a request-b) proofread-test--backend)
          (setq entry-a (car proofread--request-queue))
          (proofread--cache-write-request request-a nil)
          (proofread--cache-write-request request-b nil)
          (should-not (proofread--cache-read-request request-a))
          (should (proofread--cache-read-request request-b))
          (should-not (proofread--dispatch-queued-requests))
          (should (equal cache-hit-texts '( "bb")))
          (should (= (length proofread--request-queue) 1))
          (should (eq (car proofread--request-queue) entry-a))
          (should (proofread--request-work-pending-p request-a))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--cache-write-request request-a nil)
          (should-not (proofread--dispatch-queued-requests))
          (should (equal cache-hit-texts '( "aa" "bb")))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-cache-reply-dispatch-scales-linearly ()
  "Bound reply dispatch work for a large asynchronous core check."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "example_zh-Hans.org"
                       proofread-test--directory))
    (org-mode)
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 128)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 8)
          (proofread-test--profile-language "zh-CN")
          pending
          pending-tail
          submitted
          (submit-attempts 0)
          (freshness-checks 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max))) "zh-CN"))
               (request-count (length chunks))
               (concurrency proofread-max-concurrent-requests)
               (original-submit
                (symbol-function 'proofread--submit-request))
               (original-checker-freshness
                (symbol-function
                 'proofread--request-current-checker-p)))
          (should (= request-count 107))
          (cl-labels
              ((enqueue-result (pair)
                 (let ((cell (list pair)))
                   (if pending-tail
                       (setcdr pending-tail cell)
                     (setq pending cell))
                   (setq pending-tail cell)))
               (dequeue-result ()
                 (prog1 (pop pending)
                   (unless pending
                     (setq pending-tail nil)))))
            (let ((proofread-test--backend-check-function
                   (lambda (request callback)
                     (push request submitted)
                     (enqueue-result (cons request callback))
                     (vector 'proofread-test-handle
                             (plist-get request :log-id)))))
              (cl-letf
                  (((symbol-function 'proofread--submit-request)
                    (lambda (request backend)
                      (setq submit-attempts (1+ submit-attempts))
                      (funcall original-submit request backend)))
                   ((symbol-function
                     'proofread--request-current-checker-p)
                    (lambda (request)
                      (setq freshness-checks
                            (1+ freshness-checks))
                      (funcall original-checker-freshness request))))
                (should
                 (= (length
                     (proofread-test--dispatch-profile-chunks chunks))
                    concurrency))
                (should (= (length proofread--active-requests)
                           concurrency))
                (should (= (length proofread--request-queue)
                           (- request-count concurrency)))
                (setq submit-attempts 0)
                (setq freshness-checks 0)
                (while pending
                  (pcase-let ((`(,request . ,callback)
                               (dequeue-result)))
                    (funcall callback
                             (proofread--backend-success-result
                              request nil))))
                (should (= (length submitted) request-count))
                (should
                 (= (- (length submitted) concurrency)
                    (- request-count concurrency)))
                (let* ((ordered (nreverse submitted))
                       (ids
                        (mapcar (lambda (request)
                                  (plist-get request :log-id))
                                ordered)))
                  (should (= (length (delete-dups
                                      (copy-sequence ids)))
                             request-count))
                  (should (equal ids
                                 (sort (copy-sequence ids) #'<))))
                (should (<= submit-attempts
                            (* 2 request-count)))
                (should (<= freshness-checks
                            (* 16 request-count)))
                (should-not proofread--active-requests)
                (should-not proofread--claimed-requests)
                (should-not proofread--request-queue)
                (should-not proofread--request-queue-tail)
                (should (= (hash-table-count proofread--cache)
                           request-count))
                (should (= (hash-table-count
                            proofread--pending-request-keys)
                           0))
                (proofread-test--assert-queue-cache-index-consistent)))))))))

(ert-deftest proofread-test-cache-evicts-least-recently-used-entry ()
  "The buffer-local cache honors its least-recently-used size limit."
  (with-temp-buffer
    (proofread-mode 1)
    (let ((proofread-cache-max-entries 2))
      (proofread--cache-write 'a 1)
      (proofread--cache-write 'b 2)
      (should (= (proofread--cache-read 'a) 1))
      (proofread--cache-write 'c 3)
      (should (= (proofread--cache-read 'a) 1))
      (should-not (proofread--cache-read 'b))
      (should (= (proofread--cache-read 'c) 3))
      (should (= (hash-table-count proofread--cache) 2)))))

(ert-deftest proofread-test-zero-concurrency-prunes-stale-queue-heads
    ()
  "Prune stale queue heads and resume after capacity grows."
  (with-temp-buffer
    (insert "One. Two. Three.")
    (proofread-mode 1)
    (let* ((chunks (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max)))))
           (requests
            (mapcar (lambda (chunk)
                      (proofread--make-backend-request
                       chunk proofread-test--backend))
                    chunks))
           (invalidated (nth 0 requests))
           (superseded (nth 1 requests))
           (ready (nth 2 requests))
           dispatched)
      (should (= (length requests) 3))
      (proofread--enqueue-requests
       requests proofread-test--backend)
      (proofread--invalidate-request invalidated)
      (proofread--set-request-state-flag superseded :superseded)
      (let ((proofread-max-concurrent-requests 0))
        (should-not (proofread--dispatch-queued-requests))
        (should (= (length proofread--request-queue) 1))
        (should (eq (plist-get (car proofread--request-queue)
                               :request)
                    ready))
        (should-not (proofread--request-work-pending-p invalidated))
        (should-not (proofread--request-work-pending-p superseded))
        (should (proofread--request-work-pending-p ready)))
      (let ((proofread-max-concurrent-requests 1))
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request _callback &optional _backend)
                     (setq dispatched request)
                     'proofread-test-handle)))
          (should (equal (proofread--dispatch-queued-requests)
                         (list ready)))))
      (should (eq dispatched ready))
      (should-not proofread--request-queue)
      (should-not proofread--request-queue-tail)
      (should (proofread--active-request-p ready)))))

(ert-deftest proofread-test-reentrant-queue-dispatch-submits-once ()
  "A freshness predicate cannot submit the queue head twice."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          reentered
          submitted-log-ids
          callback)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request
                       chunk proofread-test--backend))
             (log-id (plist-get request :log-id)))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread--dispatch-queued-requests))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (backend-request backend-callback
                                            &optional _backend)
                     (push (plist-get backend-request :log-id)
                           submitted-log-ids)
                     (setq callback backend-callback)
                     (list :backend 'test :log-id log-id))))
          (should (equal (proofread--dispatch-queued-requests)
                         (list request)))
          (should (equal submitted-log-ids (list log-id)))
          (should-not proofread--request-queue)
          (should-not proofread--claimed-requests)
          (should (= (length proofread--active-requests) 1))
          (should (equal
                   (gethash (proofread--request-work-key request)
                            proofread--pending-request-keys)
                   log-id))
          (funcall callback (proofread--backend-success-result
                             request nil))
          (should (equal submitted-log-ids (list log-id)))
          (should-not proofread--active-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys)
                     0)))))))

(ert-deftest
    proofread-test-old-dispatch-does-not-drain-reinitialized-queue ()
  "Stop an old dispatch transaction after mode state is reinitialized."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 1)
          reinitialized
          new-request
          submitted)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (old-request
              (proofread--make-backend-request
               chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list old-request) proofread-test--backend)
        (cl-letf
            (((symbol-function 'proofread--submit-request)
              (lambda (request _backend)
                (push request submitted)
                (unless reinitialized
                  (setq reinitialized t)
                  (proofread-mode -1)
                  (proofread-mode 1)
                  (setq new-request
                        (proofread--make-backend-request
                         (proofread--make-request-ready-chunk 1 6)
                         proofread-test--backend))
                  (proofread--enqueue-requests
                   (list new-request) proofread-test--backend))
                'stale)))
          (should-not (proofread--dispatch-queued-requests)))
        (should reinitialized)
        (should (equal submitted (list old-request)))
        (should (proofread--request-state-flag-p
                 old-request :cancelled))
        (should (= (length proofread--request-queue) 1))
        (should (eq (plist-get (car proofread--request-queue)
                               :request)
                    new-request))
        (should (proofread--request-work-pending-p new-request))
        (should-not proofread--queue-dispatch-active-p)
        (proofread-test--assert-queue-cache-index-consistent)
        (proofread--clear-scheduled-work)
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest
    proofread-test-clear-during-claimed-freshness-does-not-requeue ()
  "Do not revive a claimed request cleared by a freshness hook."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 0)
          cleared)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf
            (((symbol-function 'proofread--fresh-request-p)
              (lambda (_request)
                (unless cleared
                  (setq cleared t)
                  (proofread--clear-scheduled-work))
                t)))
          (should-not (proofread--dispatch-queued-requests)))
        (should cleared)
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not (proofread--request-work-pending-p request))
        (should-not proofread--queue-dispatch-active-p)
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest
    proofread-test-reentrant-freshness-preserves-conflicting-new-work
    ()
  "Replace claimed requests with conflicting reentrant work."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          reentered
          submitted
          callback)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request
                   old-chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list old) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread--dispatch-request-ready-chunks
                        (list new-chunk) proofread-test--backend))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request backend-callback &optional
                                    _backend)
                     (push request submitted)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :log-id (plist-get request :log-id)))))
          (let ((dispatched (proofread--dispatch-queued-requests)))
            (should (= (length dispatched) 1))
            (should (eq (car dispatched) (car submitted))))
          (let* ((new (car submitted))
                 (new-log-id (plist-get new :log-id)))
            (should-not (equal new-log-id (plist-get old :log-id)))
            (should (proofread--request-state-flag-p old :superseded))
            (should (proofread--request-state-flag-p old :cancelled))
            (should (= (length submitted) 1))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)
            (should (equal
                     (mapcar (lambda (request)
                               (plist-get request :log-id))
                             proofread--active-requests)
                     (list new-log-id)))
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       1))
            (should (equal
                     (gethash (proofread--request-work-key new)
                              proofread--pending-request-keys)
                     new-log-id))
            (funcall callback
                     (proofread--backend-success-result new nil))
            (should-not proofread--active-requests)
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       0))))))))

(ert-deftest
    proofread-test-cancel-hook-reentrant-dispatch-does-not-duplicate
    ()
  "Cancellation hooks cannot submit a retained queue entry twice."
  (with-temp-buffer
    (insert "abc def")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          nested
          submitted-log-ids
          callbacks)
      (proofread-mode 1)
      (let* ((victim-chunk (proofread--make-request-ready-chunk 1 4))
             (new-chunk (proofread--make-request-ready-chunk 2 5))
             (unrelated-chunk
              (proofread--make-request-ready-chunk 5 8))
             (victim
              (proofread--make-backend-request
               victim-chunk proofread-test--backend))
             (unrelated
              (proofread--make-backend-request
               unrelated-chunk proofread-test--backend))
             (victim-log-id (plist-get victim :log-id))
             (unrelated-log-id (plist-get unrelated :log-id))
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (and (not nested)
                            (eq (plist-get event :type) 'cancelled)
                            (equal (plist-get event :log-id)
                                   victim-log-id))
                   (setq nested t)
                   (proofread--dispatch-queued-requests))))))
        (setq victim (plist-put victim :handle 'victim-handle))
        (proofread--register-active-request victim)
        (proofread--enqueue-requests
         (list unrelated) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request callback &optional _backend)
                     (let ((log-id (plist-get request :log-id)))
                       (push log-id submitted-log-ids)
                       (push (cons log-id callback) callbacks)
                       (list :backend 'test :log-id log-id)))))
          (proofread--dispatch-request-ready-chunks
           (list new-chunk) proofread-test--backend)
          (should (equal submitted-log-ids (list unrelated-log-id)))
          (should (proofread--request-state-flag-p victim
                                                   :superseded))
          (should (proofread--request-state-flag-p victim :cancelled))
          (should-not proofread--claimed-requests)
          (should (= (length proofread--request-queue) 1))
          (let* ((new
                  (plist-get (car proofread--request-queue) :request))
                 (new-log-id (plist-get new :log-id)))
            (funcall (cdr (assq unrelated-log-id callbacks))
                     (proofread--backend-success-result unrelated
                                                        nil))
            (should (= (cl-count unrelated-log-id submitted-log-ids)
                       1))
            (should (= (cl-count new-log-id submitted-log-ids) 1))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)
            (funcall (cdr (assq new-log-id callbacks))
                     (proofread--backend-success-result new nil))
            (should-not proofread--active-requests)
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       0))))))))

(ert-deftest
    proofread-test-edit-during-claimed-freshness-prevents-submit ()
  "Stop submission after an edit during freshness checks."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          edited
          backend-calls)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request
                       chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless edited
                       (setq edited t)
                       (goto-char (point-min))
                       (delete-char 1)
                       (insert "X"))
                     t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (&rest _)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest proofread-test-active-event-edit-prevents-backend-submit
    ()
  "Stop submission after active-request event edits."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          edited
          backend-calls)
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request
                       chunk proofread-test--backend))
             (log-id (plist-get request :log-id))
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (and (not edited)
                            (eq (plist-get event :type)
                                'active-request)
                            (equal (plist-get event :log-id) log-id))
                   (setq edited t)
                   (goto-char (point-min))
                   (delete-char 1)
                   (insert "X"))))))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (&rest _)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-invalidated-active-releases-slot-for-queued-work ()
  "Free active request slots for queued work after edits."
  (with-temp-buffer
    (insert "aaa bbb")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles
          callback)
      (proofread-mode 1)
      (let* ((waiting-chunk (proofread--make-request-ready-chunk 1 4))
             (active-chunk (proofread--make-request-ready-chunk 5 8))
             (waiting
              (proofread--make-backend-request
               waiting-chunk proofread-test--backend))
             (active
              (proofread--make-backend-request
               active-chunk proofread-test--backend))
             (waiting-log-id (plist-get waiting :log-id)))
        (setq active (plist-put active :handle 'old-handle))
        (proofread--register-active-request active)
        (proofread--enqueue-requests
         (list waiting) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  ((symbol-function 'proofread--backend-check)
                   (lambda (request backend-callback &optional
                                    _backend)
                     (push (plist-get request :log-id)
                           submitted-log-ids)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :log-id (plist-get request :log-id))))
                  ((symbol-function 'proofread--cancel-request-handle)
                   (lambda (handle)
                     (push handle cancelled-handles))))
          (goto-char 6)
          (delete-char 1)
          (insert "b")
          (should
           (proofread-test--wait-for (lambda () submitted-log-ids)))
          (should (equal submitted-log-ids (list waiting-log-id)))
          (should (equal cancelled-handles (list 'old-handle)))
          (should (proofread--request-invalidated-p active))
          (should (proofread--request-state-flag-p active :cancelled))
          (should-not (proofread--active-request-p active))
          (should (proofread--active-request-p waiting))
          (should-not proofread--request-queue)
          (should-not proofread--claimed-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys) 1))
          (should (equal
                   (gethash (proofread--request-work-key waiting)
                            proofread--pending-request-keys)
                   waiting-log-id))
          (funcall callback
                   (proofread--backend-success-result waiting nil))
          (should-not proofread--active-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys)
                     0)))))))

(ert-deftest proofread-test-stale-active-request-does-not-block-queue
    ()
  "Prevent stale active work from holding request slots."
  (with-temp-buffer
    (insert "aaa bbb")
    (let ((proofread-auto-check nil)
          (proofread-test--backend-identity-token "identity-a")
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 4) (5 . 8))))
               (active
                (proofread-test--make-profile-request
                 (nth 1 chunks))))
          (setq active (plist-put active :handle 'old-handle))
          (proofread--register-active-request active)
          (setq proofread-test--backend-identity-token "identity-b")
          (let* ((waiting
                  (proofread-test--make-profile-request
                   (car chunks)))
                 (waiting-log-id (plist-get waiting :log-id)))
            (proofread--enqueue-requests
             (list waiting) proofread-test--backend)
            (cl-letf (((symbol-function 'proofread--backend-check)
                       (lambda (request _callback &optional _backend)
                         (push (plist-get request :log-id)
                               submitted-log-ids)
                         (list :backend 'test
                               :log-id (plist-get request :log-id))))
                      ((symbol-function
                        'proofread--cancel-request-handle)
                       (lambda (handle)
                         (push handle cancelled-handles))))
              (should (equal (proofread--dispatch-queued-requests)
                             (list waiting))))
            (should (equal submitted-log-ids (list waiting-log-id)))
            (should (equal cancelled-handles (list 'old-handle)))
            (should (proofread--request-invalidated-p active))
            (should (proofread--request-state-flag-p active
                                                     :cancelled))
            (should-not (proofread--active-request-p active))
            (should (proofread--active-request-p waiting))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)))))))

(ert-deftest proofread-test-context-stale-active-resumes-queued-work
    ()
  "Resume queued work after editing saved context."
  (with-temp-buffer
    (insert "Aaa. Bbb. Ccc.")
    (let ((proofread-auto-check nil)
          (proofread-context-sentences-before 0)
          (proofread-context-sentences-after 1)
          (proofread-context-size 200)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((waiting-chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 5)))))
               (active-chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((6 . 10)))))
               (waiting
                (proofread-test--make-profile-request waiting-chunk))
               (active
                (proofread-test--make-profile-request active-chunk))
               (waiting-log-id (plist-get waiting :log-id)))
          (setq active (plist-put active :handle 'old-handle))
          (proofread--register-active-request active)
          (proofread--enqueue-requests
           (list waiting) proofread-test--backend)
          (cl-letf (((symbol-function 'proofread--backend-check)
                     (lambda (request _callback &optional _backend)
                       (push (plist-get request :log-id)
                             submitted-log-ids)
                       (list :backend 'test
                             :log-id (plist-get request :log-id))))
                    ((symbol-function
                      'proofread--cancel-request-handle)
                     (lambda (handle)
                       (push handle cancelled-handles))))
            (goto-char 11)
            (delete-char 1)
            (insert "X")
            (should-not (proofread--request-invalidated-p active))
            (should (timerp proofread--queue-dispatch-timer))
            (should
             (proofread-test--wait-for (lambda () submitted-log-ids)))
            (should (equal submitted-log-ids (list waiting-log-id)))
            (should (equal cancelled-handles (list 'old-handle)))
            (should (proofread--request-invalidated-p active))
            (should (proofread--request-state-flag-p active
                                                     :cancelled))
            (should-not (proofread--active-request-p active))
            (should (proofread--active-request-p waiting))
            (should-not proofread--request-queue)
            (should-not proofread--claimed-requests)))))))

(ert-deftest proofread-test-queue-inhibition-is-buffer-specific ()
  "Keep buffer lifecycle transactions independent."
  (let ((source (generate-new-buffer " *proofread-queue-source*"))
        (other (generate-new-buffer " *proofread-queue-other*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (proofread-mode 1))
          (with-current-buffer other
            (insert "Alpha")
            (proofread-mode 1))
          (let ((proofread--inhibit-queue-dispatch source)
                submitted-log-ids)
            (with-current-buffer other
              (let* ((chunk (proofread--make-request-ready-chunk 1 6))
                     (request
                      (proofread--make-backend-request
                       chunk proofread-test--backend))
                     (log-id (plist-get request :log-id)))
                (proofread--enqueue-requests
                 (list request) proofread-test--backend)
                (cl-letf (((symbol-function
                            'proofread--fresh-request-p)
                           (lambda (_request) t))
                          ((symbol-function 'proofread--backend-check)
                           (lambda (backend-request _callback
                                                    &optional
                                                    _backend)
                             (push (plist-get backend-request :log-id)
                                   submitted-log-ids)
                             (list :backend 'test :log-id log-id))))
                  (should (equal (proofread--dispatch-queued-requests)
                                 (list request))))
                (should (equal submitted-log-ids (list log-id)))
                (should-not proofread--request-queue)
                (should-not proofread--claimed-requests)))))
      (when (buffer-live-p source)
        (kill-buffer source))
      (when (buffer-live-p other)
        (kill-buffer other)))))

(ert-deftest proofread-test-submit-error-does-not-strand-claimed-work
    ()
  "Leave no claimed or pending work after submission errors."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request (proofread--make-backend-request
                       chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--submit-request)
                   (lambda (&rest _)
                     (error "Simulated submission failure"))))
          (should-error (proofread--dispatch-queued-requests)))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--queue-dispatch-active-p)
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest proofread-test-requeue-error-does-not-strand-claimed-work
    ()
  "Leave no claimed or pending work when restoring a full request fails."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 0))
      (proofread-mode 1)
      (let* ((chunk (proofread--make-request-ready-chunk 1 6))
             (request
              (proofread--make-backend-request
               chunk proofread-test--backend)))
        (proofread--enqueue-requests
         (list request) proofread-test--backend)
        (cl-letf
            (((symbol-function 'proofread--submit-request)
              (lambda (&rest _) 'full))
             ((symbol-function 'proofread--prepend-request-queue-entry)
              (lambda (&rest _)
                (error "Simulated requeue failure"))))
          (should-error (proofread--dispatch-queued-requests)))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--queue-dispatch-active-p)
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest
    proofread-test-clear-rejects-work-enqueued-by-cancel-hook ()
  "Reject work enqueued by cancellation hooks during clearing."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          triggered
          new-log-id
          events)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request
                   old-chunk proofread-test--backend))
             (old-log-id (plist-get old :log-id)))
        (proofread--enqueue-requests
         (list old) proofread-test--backend)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (push event events)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread--dispatch-request-ready-chunks
                     (list new-chunk) proofread-test--backend))
                   ((eq (plist-get event :reason) 'cleared)
                    (setq new-log-id
                          (plist-get event :log-id))))))))
          (proofread--clear-scheduled-work))
        (should triggered)
        (should new-log-id)
        (should-not
         (cl-find-if
          (lambda (event)
            (and (equal (plist-get event :log-id) new-log-id)
                 (eq (plist-get event :type) 'queued-request)))
          events))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should-not proofread--request-queue-tail)
        (should-not proofread--queue-dispatch-timer)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-request-cleanup-rejects-active-cancel-hook-work ()
  "Reject cancellation-hook work during active cleanup."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          triggered
          rejected-log-id)
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old (proofread--make-backend-request
                   old-chunk proofread-test--backend))
             (old-log-id (plist-get old :log-id)))
        (setq old (plist-put old :handle 'old-handle))
        (proofread--register-active-request old)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread--dispatch-request-ready-chunks
                     (list new-chunk) proofread-test--backend))
                   ((eq (plist-get event :reason) 'cleared)
                    (setq rejected-log-id
                          (plist-get event :log-id))))))))
          (proofread--clear-request-work))
        (should triggered)
        (should rejected-log-id)
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should-not proofread--request-queue)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-restored-edit-does-not-block-same-work-request ()
  "Resubmit restored work after invalidating an earlier request."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          backend-requests)
      (proofread-mode 1)
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request _callback &optional _backend)
                     (setq backend-requests
                           (append backend-requests (list request)))
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
          (let* ((old-chunks
                  (proofread-test--request-ready-chunks-for-ranges
                   (list (cons (point-min) (point-max)))))
                 (old
                  (car (proofread-test--dispatch-profile-chunks
                        old-chunks))))
            (should old)
            (goto-char 2)
            (insert "x")
            (delete-region 2 3)
            (should (equal (buffer-string) "helo"))
            (should (proofread--request-invalidated-p old))
            (should-not (proofread--request-work-pending-p old))
            (let* ((new-chunks
                    (proofread-test--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max)))))
                   (new
                    (car (proofread-test--dispatch-profile-chunks
                          new-chunks))))
              (should new)
              (should (equal (proofread--request-work-key old)
                             (proofread--request-work-key new)))
              (should (= (length backend-requests) 2))
              (should-not (proofread--active-request-p old))
              (should (proofread--active-request-p new))
              (should (proofread--request-work-pending-p new)))))))))

(ert-deftest
    proofread-test-request-work-key-distinguishes-restrictions ()
  "Include accessible restrictions in request identity."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let* ((full-chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (full-request
            (proofread--make-backend-request
             full-chunk proofread-test--backend))
           narrowed-request)
      (narrow-to-region 2 6)
      (setq narrowed-request
            (proofread--make-backend-request
             (car (proofread-test--request-ready-chunks-for-ranges
                   (list (cons (point-min) (point-max)))))
             proofread-test--backend))
      (should-not (equal (proofread--request-work-key full-request)
                         (proofread--request-work-key
                          narrowed-request)))
      (should-not (proofread--fresh-request-p full-request))
      (should (proofread--fresh-request-p narrowed-request))
      (widen)
      (should (proofread--fresh-request-p full-request))
      (should-not (proofread--fresh-request-p narrowed-request)))))

(ert-deftest proofread-test-cache-hit-edit-invalidates-prepared-batch
    ()
  "Invalidate later batch work after synchronous cache-hit edits."
  (with-temp-buffer
    (insert "aaa aaa")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          calls)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((first
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 4)))))
               (second
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((5 . 8)))))
               (preview
                (proofread-test--make-profile-request first)))
          (should (equal (plist-get first :text) "aaa"))
          (should (equal (plist-get second :text) "aaa"))
          (proofread--cache-write-request preview nil)
          (add-hook
           'proofread-diagnostics-changed-hook
           (lambda ()
             (setq calls (1+ (or calls 0)))
             (when (= calls 1)
               (goto-char (point-min))
               (insert "aaa ")))
           nil t)
          (should-not
           (proofread-test--dispatch-profile-chunks
            (list first second)))
          (should (= calls 1))
          (should (equal (buffer-string) "aaa aaa aaa"))
          (should-not proofread--request-queue)
          (should (= (hash-table-count
                      proofread--pending-request-keys) 0)))))))

(ert-deftest
    proofread-test-full-queue-does-not-starve-later-cache-hit ()
  "Cached queued work runs even when earlier backend work is full."
  (with-temp-buffer
    (insert "aa bb cc")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          calls)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((active
                (proofread-test--make-profile-request
                 (car (proofread-test--request-ready-chunks-for-ranges
                       '((1 . 3))))))
               (waiting
                (proofread-test--make-profile-request
                 (car (proofread-test--request-ready-chunks-for-ranges
                       '((4 . 6))))))
               (cached
                (proofread-test--make-profile-request
                 (car (proofread-test--request-ready-chunks-for-ranges
                       '((7 . 9)))))))
          (proofread--register-active-request active)
          (proofread--cache-write-request cached nil)
          (proofread--enqueue-requests
           (list waiting cached) proofread-test--backend)
          (add-hook 'proofread-diagnostics-changed-hook
                    (lambda ()
                      (setq calls (1+ (or calls 0)))
                      (when (= calls 1)
                        (goto-char (point-min))
                        (insert "x")
                        (delete-char -1)))
                    nil t)
          (should-not (proofread--dispatch-queued-requests))
          (should (= calls 1))
          (should-not proofread--request-queue)
          (should (proofread--request-invalidated-p waiting))
          (should-not (proofread--request-work-pending-p waiting))
          (should-not (proofread--request-work-pending-p cached)))))))

(ert-deftest
    proofread-test-conflicting-request-replaces-active-at-limit ()
  "Cancel conflicting active work before enforcing limits."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          backend-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request _callback &optional _backend)
                     (setq backend-requests
                           (append backend-requests (list request)))
                     (list :backend 'test
                           :request-id (plist-get request :id))))
                  ((symbol-function 'proofread--cancel-request-handle)
                   (lambda (handle)
                     (push handle cancelled-handles))))
          (let* ((older-chunk
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((1 . 7)))))
                 (newer-chunk
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((2 . 6)))))
                 (older
                  (car (proofread-test--dispatch-profile-chunks
                        (list older-chunk))))
                 (newer
                  (car (proofread-test--dispatch-profile-chunks
                        (list newer-chunk)))))
            (should older)
            (should newer)
            (should (= (length backend-requests) 2))
            (should (= (length cancelled-handles) 1))
            (should (proofread--request-state-flag-p older
                                                     :superseded))
            (should-not (proofread--active-request-p older))
            (should (proofread--active-request-p newer))
            (should (equal (mapcar (lambda (request)
                                     (plist-get request :text))
                                   proofread--active-requests)
                           '( "bcde")))
            (should-not proofread--request-queue)
            (should-not proofread--request-queue-tail)))))))

(ert-deftest
    proofread-test-superseding-cache-hit-drains-unrelated-queue ()
  "Drain unrelated work after a superseding cache hit."
  (with-temp-buffer
    (insert "abc def")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          backend-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request _callback &optional _backend)
                     (setq backend-requests
                           (append backend-requests (list request)))
                     (list :backend 'test
                           :request-id (plist-get request :id))))
                  ((symbol-function 'proofread--cancel-request-handle)
                   (lambda (handle)
                     (push handle cancelled-handles))))
          (let* ((older-chunk
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((1 . 4)))))
                 (cached-chunk
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((1 . 5)))))
                 (unrelated-chunk
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((5 . 8)))))
                 (cached-preview
                  (proofread-test--make-profile-request cached-chunk))
                 (unrelated
                  (proofread-test--make-profile-request
                   unrelated-chunk)))
            (proofread--cache-write-request cached-preview nil)
            (let ((older
                   (car (proofread-test--dispatch-profile-chunks
                         (list older-chunk)))))
              (should older)
              (proofread--enqueue-requests
               (list unrelated) proofread-test--backend)
              (should (= (length proofread--request-queue) 1))
              (should
               (equal
                (proofread-test--dispatch-profile-chunks
                 (list cached-chunk))
                (list unrelated)))
              (should (proofread--request-state-flag-p
                       older :superseded))
              (should (= (length cancelled-handles) 1))
              (should (equal (mapcar (lambda (request)
                                       (plist-get request :text))
                                     backend-requests)
                             '( "abc" "def")))
              (should-not (proofread--active-request-p older))
              (should (proofread--active-request-p unrelated))
              (should-not proofread--request-queue)
              (should-not proofread--request-queue-tail))))))))

(ert-deftest proofread-test-synchronous-queued-callback-drains-once ()
  "Drain synchronous callbacks without duplicate submissions."
  (with-temp-buffer
    (insert "One. Two. Three.")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          submitted-log-ids)
      (proofread-mode 1)
      (let* ((chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (requests
              (mapcar (lambda (chunk)
                        (proofread--make-backend-request
                         chunk proofread-test--backend))
                      chunks))
             (expected-log-ids
              (mapcar (lambda (request)
                        (plist-get request :log-id))
                      requests)))
        (should (= (length requests) 3))
        (proofread--enqueue-requests
         requests proofread-test--backend)
        (cl-letf (((symbol-function 'proofread--backend-check)
                   (lambda (request callback &optional _backend)
                     (push (plist-get request :log-id)
                           submitted-log-ids)
                     (funcall callback
                              (proofread--backend-success-result
                               request nil))
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
          (proofread--dispatch-queued-requests))
        (setq submitted-log-ids (nreverse submitted-log-ids))
        (should (equal submitted-log-ids expected-log-ids))
        (should (= (length (delete-dups (copy-sequence
                                         submitted-log-ids)))
                   (length requests)))
        (should-not proofread--active-requests)
        (should-not proofread--request-queue)
        (should-not proofread--request-queue-tail)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-adjacent-zero-width-diagnostic-keeps-owner ()
  "Keep boundary diagnostics until their owner is cleaned."
  (dolist (producer '( left right))
    (dolist (callback-order '((left right) (right left)))
      (with-temp-buffer
        (insert "abcdef")
        (let ((proofread-auto-check nil)
              (proofread-context-size 0)
              (proofread-cache-max-entries 0))
          (proofread-mode 1)
          (proofread-test--with-profile
            (let* ((left-chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 4)))))
                   (right-chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((4 . 7)))))
                   (left-request
                    (proofread-test--make-profile-request left-chunk))
                   (right-request
                    (proofread-test--make-profile-request right-chunk))
                   (producer-request
                    (if (eq producer 'left)
                        left-request
                      right-request))
                   (boundary-diagnostic
                    (proofread--make-diagnostic
                     :beg 4 :end 4 :text "" :kind 'grammar
                     :message "Missing boundary punctuation"
                     :suggestions '( ".") :source 'test))
                   (neighbor-diagnostic
                    (if (eq producer 'left)
                        (proofread-test--diagnostic-for-range 5 6 "e")
                      (proofread-test--diagnostic-for-range 2 3 "b"))))
              (dolist (side callback-order)
                (let ((request (if (eq side 'left)
                                   left-request
                                 right-request))
                      (diagnostics
                       (if (eq side producer)
                           (list boundary-diagnostic)
                         (list neighbor-diagnostic))))
                  (should
                   (eq (proofread--handle-backend-result
                        (proofread--backend-success-result
                         request diagnostics))
                       'applied))))
              (should (= (length proofread--diagnostics) 2))
              (let ((live-boundary
                     (cl-find-if
                      (lambda (diagnostic)
                        (equal
                         (proofread-test--diagnostic-without-provenance
                          diagnostic)
                         boundary-diagnostic))
                      proofread--diagnostics))
                    (live-neighbor
                     (cl-find-if
                      (lambda (diagnostic)
                        (equal
                         (proofread-test--diagnostic-without-provenance
                          diagnostic)
                         neighbor-diagnostic))
                      proofread--diagnostics)))
                (should live-boundary)
                (should live-neighbor)
                (should (proofread--overlay-for-diagnostic
                         live-boundary))
                (should (proofread--overlay-for-diagnostic
                         live-neighbor))
                (should
                 (eq (proofread--handle-backend-result
                      (proofread--backend-success-result
                       producer-request nil))
                     'applied))
                (should-not (memq live-boundary proofread--diagnostics))
                (should-not (proofread--overlay-for-diagnostic
                             live-boundary))
                (should
                 (equal
                  (proofread-test--diagnostics-without-provenance
                   proofread--diagnostics)
                  (list neighbor-diagnostic)))
                (should (proofread--overlay-for-diagnostic
                         live-neighbor))))))))))

;;;; Runtime setup

(progn
  (proofread--register-backend
   proofread-test--backend
   :check #'proofread-test--backend-check
   :identity #'proofread-test--backend-identity
   :cancel #'proofread-test--backend-cancel))

(provide 'proofread-tests)
;;; proofread-tests.el ends here
