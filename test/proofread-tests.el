;;; proofread-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for proofread.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'proofread)

;; Keep Proofread's scheduler tests independent of Flymake's own idle
;; timer and of asynchronous backends installed by major modes.
(setq flymake-no-changes-timeout nil)

(defun proofread-test--clear-major-mode-flymake-backends ()
  "Keep unrelated major-mode Flymake backends out of core test buffers."
  (setq-local flymake-diagnostic-functions nil))

(add-hook 'after-change-major-mode-hook
          #'proofread-test--clear-major-mode-flymake-backends 90)

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

(defvar-local proofread-test--flymake-foreign-range '( 1 . 2)
  "Range reported by the fake foreign Flymake backend.")

(cl-defstruct
    (proofread-test--hash-option-snapshot
     (:constructor
      proofread-test--make-hash-option-snapshot (test entries)))
  "Comparable fake-backend snapshot of a hash-table option."
  test
  entries)

;;;; Test helpers

(defun proofread-test--tree-member-p (needle tree)
  "Return non-nil if NEEDLE appears anywhere in TREE."
  (cond
   ((eq needle tree) t)
   ((consp tree)
    (or (proofread-test--tree-member-p needle (car tree))
        (proofread-test--tree-member-p needle (cdr tree))))
   (t nil)))

(defun proofread-test--identity-root-p (value root)
  "Return non-nil when VALUE is a complete identity marked by ROOT."
  (and (integerp (proper-list-p value))
       (eq (plist-get value :proofread-test-identity-root) root)))

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

(defun proofread-test--flymake-foreign-backend
    (report-function &rest _arguments)
  "Report one non-Proofread diagnostic through REPORT-FUNCTION."
  (funcall
   report-function
   (list
    (flymake-make-diagnostic
     (current-buffer)
     (car proofread-test--flymake-foreign-range)
     (cdr proofread-test--flymake-foreign-range)
     :note "Foreign diagnostic"))))

(defun proofread-test--flymake-proofread-diagnostics ()
  "Return current Proofread diagnostics published through Flymake."
  (apply
   #'append
   (mapcar
    (lambda (flymake-diagnostic)
      (when-let* ((diagnostic
                   (proofread--flymake-to-diagnostic
                    flymake-diagnostic)))
        (copy-sequence
         (proofread--diagnostic-members diagnostic))))
    (flymake-diagnostics))))

(defun proofread-test--publish-diagnostics (diagnostics)
  "Publish DIAGNOSTICS through the Proofread Flymake bridge."
  (setq proofread--diagnostics diagnostics)
  (when (and proofread-mode
             flymake-mode
             (memq #'proofread--flymake-backend
                   flymake-diagnostic-functions))
    (flymake-start))
  diagnostics)

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

(defun proofread-test--record-request-log-event
    (source key &optional type)
  "Record a request-log event for SOURCE under KEY.
TYPE defaults to `chunk-request'."
  (let* ((type (or type 'chunk-request))
         (request (list :id key :buffer source :beg 1 :end 1))
         (event (list :type type
                      :time (current-time)
                      :log-id key
                      :request-id key
                      :buffer source
                      :beg 1
                      :end 1
                      :request request)))
    (when (eq type 'chunk-request)
      (setq event (plist-put event :chunk request)))
    (proofread--request-log-record-event event)))

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
          (lambda (request callback)
            (push request requests)
            (push callback callbacks)
            'proofread-test-handle)
          :requests
          (lambda ()
            (reverse requests))
          :callbacks
          (lambda ()
            (reverse callbacks)))))

(defun proofread-test--work-request (work)
  "Return WORK's immutable backend request payload."
  (proofread--scheduled-work-request work))

(defun proofread-test--queue-entry-work (entry)
  "Return the scheduled work owned by queue ENTRY."
  (proofread--queue-entry-work entry))

(defun proofread-test--make-request-work
    (chunk &optional backend checker profile preparation)
  "Return scheduled work for a backend request built from CHUNK.
Use BACKEND, CHECKER, PROFILE, and PREPARATION when provided."
  (let ((request
         (proofread--make-backend-request
          chunk backend checker profile preparation)))
    (proofread--make-request-work request)))

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
   (lambda (work)
     (plist-get (proofread-test--work-request work) :checker-name))
   (append
    proofread--active-requests
    proofread--claimed-requests
    (proofread--request-queue-works))))

(defun proofread-test--assert-queue-cache-index-consistent ()
  "Assert that queue-state links and cache-key indexes agree.
This checker only reads queue records; it must not repair malformed
state as part of an assertion."
  (if (null proofread--queue-state)
      (should (proofread--request-queue-empty-p))
    (let* ((state proofread--queue-state)
           (index (proofread--queue-state-index state))
           (woken (proofread--queue-state-woken state))
           (queued (make-hash-table :test #'eq))
           (entry (proofread--queue-state-head state))
           previous
           previous-sequence
           (queue-count 0)
           (indexed-count 0))
      (should (proofread--queue-state-p state))
      (should (hash-table-p index))
      (should (hash-table-p woken))
      (while entry
        (should (proofread--queue-entry-p entry))
        (should-not (gethash entry queued))
        (puthash entry t queued)
        (should (eq (proofread--queue-entry-owner entry) state))
        (should (eq (proofread--queue-entry-previous entry)
                    previous))
        (let* ((sequence (proofread--queue-entry-sequence entry))
               (key
                (proofread--request-queue-entry-cache-key entry))
               (bucket (gethash key index)))
          (should (natnump sequence))
          (when previous-sequence
            (should (< previous-sequence sequence)))
          (setq previous-sequence sequence)
          (should (hash-table-p bucket))
          (should (gethash entry bucket)))
        (setq queue-count (1+ queue-count))
        (setq previous entry)
        (setq entry (proofread--queue-entry-next entry)))
      (should (eq (proofread--queue-state-tail state) previous))
      (when-let* ((tail (proofread--queue-state-tail state)))
        (should-not (proofread--queue-entry-next tail)))
      (when previous-sequence
        (should (<= previous-sequence
                    (proofread--queue-state-next-sequence state))))
      (maphash
       (lambda (key bucket)
         (should (hash-table-p bucket))
         (should (> (hash-table-count bucket) 0))
         (maphash
          (lambda (indexed-entry _value)
            (setq indexed-count (1+ indexed-count))
            (should (gethash indexed-entry queued))
            (should (equal
                     key
                     (proofread--request-queue-entry-cache-key
                      indexed-entry))))
          bucket))
       index)
      (should (= indexed-count queue-count))
      (maphash
       (lambda (woken-entry _value)
         (should (gethash woken-entry queued))
         (should
          (gethash
           woken-entry
           (gethash
            (proofread--request-queue-entry-cache-key woken-entry)
            index))))
       woken))))

(defun proofread-test--assert-requests-settled (works)
  "Assert that WORKS and current scheduler state are settled."
  (dolist (work works)
    (should (proofread--scheduled-work-batch work))
    (should (proofread--scheduled-work-batch-settled work)))
  (dolist (batch
           (delete-dups
            (mapcar #'proofread--scheduled-work-batch works)))
    (should (zerop (plist-get batch :pending))))
  (should-not proofread--active-requests)
  (should-not proofread--claimed-requests)
  (should (proofread--request-queue-empty-p))
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
  "Return minimal scheduled work named ID from BEG to END.
When HANDLE is non-nil, attach it as the backend handle."
  (let ((work
         (proofread--make-scheduled-work
          (list :id id
                :buffer (current-buffer)
                :generation 1
                :beg beg
                :end end
                :accessible-beg 1
                :accessible-end 100)
          id id)))
    (setf (proofread--scheduled-work-handle work) handle)
    work))

(defun proofread-test--owned-lifecycle-request
    (id owner beg end)
  "Return minimal scheduled work named ID for OWNER from BEG to END."
  (let ((work (proofread-test--lifecycle-request id beg end)))
    (setf (proofread--scheduled-work-request work)
          (plist-put (proofread-test--work-request work)
                     :checker-owner owner))
    work))

(defun proofread-test--reference-conflicting-request-candidates
    (requests candidates)
  "Return conflicting CANDIDATES in input order for REQUESTS.
Implement the original per-request scan as a semantic reference for
the owner-bucketed conflict detector."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (work requests)
      (when-let* ((range
                   (proofread--request-range
                    (proofread-test--work-request work))))
        (let (entries)
          (dolist (candidate candidates)
            (when (equal
                   (plist-get (proofread-test--work-request work)
                              :checker-owner)
                   (plist-get (proofread-test--work-request candidate)
                              :checker-owner))
              (when-let* ((candidate-range
                           (proofread--request-range
                            (proofread-test--work-request
                             candidate))))
                (push (cons candidate candidate-range) entries))))
          (dolist (entry
                   (proofread--range-conflicting-entries
                    (list range) entries))
            (puthash (car entry) t table)))))
    (cl-remove-if-not
     (lambda (candidate)
       (gethash candidate table))
     candidates)))

(defun proofread-test--pending-request-table (works)
  "Return a pending-work table containing WORKS."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (work works)
      (puthash (proofread--request-work-key work)
               work
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

(defun proofread-test--snapshot-option-entry-less-p (left right)
  "Return non-nil when snapshot entry LEFT precedes RIGHT."
  (string< (prin1-to-string left)
           (prin1-to-string right)))

(defun proofread-test--snapshot-option-value (value)
  "Return the test backend's snapshot of option VALUE.
Mutable collection values are detached recursively.  Objects whose
identity belongs to a provider remain opaque to this fake backend.
Hash tables become ordered value representations that `equal' can
compare across freshness snapshots."
  (cond
   ((or (markerp value) (recordp value)) value)
   ((consp value)
    (cons (proofread-test--snapshot-option-value (car value))
          (proofread-test--snapshot-option-value (cdr value))))
   ((stringp value) (substring-no-properties value))
   ((bool-vector-p value) (copy-sequence value))
   ((vectorp value)
    (let ((copy (copy-sequence value)))
      (dotimes (index (length copy))
        (aset copy index
              (proofread-test--snapshot-option-value
               (aref copy index))))
      copy))
   ((hash-table-p value)
    (let (entries)
      (maphash
       (lambda (key item)
         (push
          (list (proofread-test--snapshot-option-value key)
                (proofread-test--snapshot-option-value item))
          entries))
       value)
      (proofread-test--make-hash-option-snapshot
       (hash-table-test value)
       (sort entries
             #'proofread-test--snapshot-option-entry-less-p))))
   (t value)))

(defun proofread-test--snapshot-checker-options (options)
  "Return the fake backend-owned snapshot of checker OPTIONS."
  (proofread-test--snapshot-option-value options))

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

(defun proofread-test--dispatch-profile-chunks (chunks &optional profile)
  "Dispatch CHUNKS through PROFILE's production result path.
When PROFILE is nil, use the current profile."
  (plist-get
   (proofread--dispatch-profile-request-ready-chunks-result
    chunks (or profile (proofread--current-profile)))
   :requests))

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
               (funcall callback result)))))
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
  (proofread-register-backend
   backend
   :check check
   :identity
   (lambda ()
     (list :backend backend :contract-version 1))
   :snapshot-options #'proofread-test--snapshot-checker-options
   :cancel cancel))

(defun proofread-test--assert-no-pending-request-work ()
  "Assert that the current buffer has no pending request work."
  (should-not proofread--active-requests)
  (should-not proofread--claimed-requests)
  (should (proofread--request-queue-empty-p))
  (proofread-test--assert-queue-cache-index-consistent)
  (should
   (zerop (hash-table-count proofread--pending-request-keys))))

(defun proofread-test--terminal-request-events (events work)
  "Return terminal EVENTS belonging to WORK."
  (let ((log-id (proofread--scheduled-work-log-id work)))
    (cl-remove-if-not
     (lambda (event)
       (and (equal (plist-get event :log-id) log-id)
            (memq (plist-get event :type)
                  '( cancelled final-result))))
     events)))

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

;;;; Range and diagnostic tests

(ert-deftest proofread-test-range-normalization-table ()
  "Keep the two range normalization adjacency policies explicit."
  (dolist
      (case
       '((((8 . 10) (1 . 3))
          ((1 . 3) (8 . 10))
          ((1 . 3) (8 . 10)))
         (((3 . 7) (1 . 4)) ((1 . 7)) ((1 . 7)))
         (((1 . 8) (2 . 4) (1 . 8)) ((1 . 8)) ((1 . 8)))
         (((4 . 6) (1 . 4)) ((1 . 6)) ((1 . 4) (4 . 6)))
         (((1 . 3) (3 . 5) (4 . 7))
          ((1 . 7))
          ((1 . 3) (3 . 7)))))
    (pcase-let ((`(,ranges ,touching ,strict) case))
      (let ((original (copy-tree ranges)))
        (should (equal (proofread--normalize-ranges ranges)
                       touching))
        (should (equal ranges original))
        (should (equal (proofread--normalize-overlapping-ranges
                        ranges)
                       strict))
        (should (equal ranges original))))))

(ert-deftest proofread-test-normalize-ranges-discards-empty-ranges ()
  "Drop malformed, reversed, and zero-width selectable ranges."
  (dolist (range '(nil invalid (1 . invalid) (2 . 1)))
    (should-not (proofread--range-valid-p range)))
  (should (equal (proofread--normalize-ranges
                  '((30 . 35) invalid (1 . 1) (10 . 20)
                    (40 . 39) (20 . 30)))
                 '((10 . 35)))))

(ert-deftest proofread-test-range-relations-table ()
  "Define overlap, conflict, containment, and intersection boundaries."
  (dolist
      (case
       '(((1 . 4) (1 . 4) t t t t)
         ((1 . 4) (3 . 6) t t nil nil)
         ((1 . 6) (2 . 4) t t t nil)
         ((1 . 3) (3 . 5) nil nil nil nil)
         ((1 . 2) (4 . 5) nil nil nil nil)
         ((1 . 4) (1 . 1) nil t t nil)
         ((1 . 4) (2 . 2) nil t t nil)
         ((1 . 4) (4 . 4) nil t t nil)
         ((2 . 2) (2 . 2) nil t t t)
         ((2 . 2) (3 . 3) nil nil nil nil)))
    (pcase-let
        ((`(,left ,right ,overlap ,conflict
                  ,left-contains ,right-contains)
          case))
      (should (proofread--range-valid-p left))
      (should (proofread--range-valid-p right))
      (should (eq (proofread--range-overlaps-p left right)
                  overlap))
      (should (eq (proofread--range-overlaps-p right left)
                  overlap))
      (should (eq (proofread--range-conflicts-p left right)
                  conflict))
      (should (eq (proofread--range-conflicts-p right left)
                  conflict))
      (should (eq (proofread--range-contains-p left right)
                  left-contains))
      (should (eq (proofread--range-contains-p right left)
                  right-contains))
      (should
       (equal
        (proofread--range-intersection left right)
        (and overlap
             (cons (max (car left) (car right))
                   (min (cdr left) (cdr right)))))))))

(ert-deftest proofread-test-range-point-coverage-table ()
  "Define half-open, strict, and zero-width point coverage."
  (dolist
      (case
       '(((1 . 4) 0 nil nil)
         ((1 . 4) 1 t nil)
         ((1 . 4) 2 t t)
         ((1 . 4) 3 t t)
         ((1 . 4) 4 nil nil)
         ((2 . 2) 1 nil nil)
         ((2 . 2) 2 t nil)
         ((2 . 2) 3 nil nil)))
    (pcase-let ((`(,range ,position ,covers ,strict) case))
      (should (eq (proofread--range-covers-position-p
                   range position)
                  covers))
      (should
       (eq (proofread--range-strictly-contains-position-p
            range position)
           strict))))
  (let ((dead-marker (make-marker)))
    (should-not
     (proofread--range-covers-position-p '(1 . 4) dead-marker))
    (should-not
     (proofread--range-strictly-contains-position-p
      '(1 . 4) dead-marker))))

(ert-deftest proofread-test-range-edit-invalidation-table ()
  "Define insertion, replacement, adjacency, and zero-width effects."
  (dolist
      (case
       '(((1 . 4) (1 . 1) nil)
         ((1 . 4) (2 . 2) t)
         ((1 . 4) (4 . 4) nil)
         ((4 . 4) (4 . 4) t)
         ((4 . 4) (3 . 3) nil)
         ((1 . 3) (3 . 5) nil)
         ((5 . 7) (3 . 5) nil)
         ((2 . 4) (3 . 5) t)
         ((3 . 3) (3 . 5) t)
         ((5 . 5) (3 . 5) t)
         ((6 . 6) (3 . 5) nil)))
    (pcase-let ((`(,range ,edit ,affected) case))
      (should
       (eq (proofread--range-affected-by-edit-p range edit)
           affected)))))

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
    proofread-test-diagnostic-membership-uses-semantic-fields ()
  "Deduplicate diagnostics by the core semantic field contract."
  (let* ((first
          (proofread-test--diagnostic-for-range 1 5 "helo"))
         (duplicate (copy-sequence first))
         (different-owner (copy-sequence first)))
    (setq duplicate (plist-put duplicate :source 'other))
    (setq duplicate
          (plist-put duplicate :suggestions '( "different")))
    (setq different-owner
          (plist-put different-owner :checker-owner
                     '( :profile multi :checker-name other)))
    (let ((result
           (proofread--new-diagnostics
            (list first duplicate different-owner) nil)))
      (should (equal result (list first different-owner)))
      (should (eq (car result) first)))))

(ert-deftest
    proofread-test-diagnostic-source-labels-preserve-first-occurrence
    ()
  "Keep unique non-nil source labels in member order."
  (let* ((first (copy-sequence "first"))
         (first-copy (copy-sequence first))
         (second (copy-sequence "second"))
         (diagnostic
          (list :proofread-aggregate t
                :diagnostics
                (list nil
                      (list :checker-name first)
                      (list :checker-name second)
                      (list :checker-name first-copy)
                      (list :source 'fallback))))
         (labels (proofread--diagnostic-source-labels diagnostic)))
    (should (equal labels '( "first" "second" "fallback")))
    (should (eq (car labels) first))))

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
  (let* ((main (proofread-test--lifecycle-request 'main 4 7))
         (zero (proofread-test--lifecycle-request 'zero 10 10))
         (overlap
          (proofread-test--lifecycle-request 'overlap 3 5))
         (contains
          (proofread-test--lifecycle-request 'contains 2 8))
         (zero-right
          (proofread-test--lifecycle-request 'zero-right 7 7))
         (zero-query-left
          (proofread-test--lifecycle-request 'zero-query-left 9 10))
         (contained
          (proofread-test--lifecycle-request 'contained 5 6))
         (contained-copy (copy-sequence contained))
         (adjacent-left
          (proofread-test--lifecycle-request 'adjacent-left 1 4))
         (adjacent-right
          (proofread-test--lifecycle-request 'adjacent-right 7 9))
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
    proofread-test-conflicting-request-owner-buckets-match-reference
    ()
  "Match the per-request conflict scan across owner bucket cases."
  (let* ((first-owner
          '( :profile multi :checker-name first))
         (first-owner-copy (copy-tree first-owner))
         (second-owner
          '( :profile multi :checker-name second))
         (second-owner-copy (copy-tree second-owner))
         (other-owner
          '( :profile multi :checker-name other))
         (bulk-owner
          '( :profile bulk :checker-name primary))
         (bulk-owner-copy (copy-tree bulk-owner))
         (bulk-other-owner
          '( :profile bulk :checker-name other))
         (bulk-request-specs
          (cl-loop
           for index downfrom 127 to 0
           for beg = (+ 1 (* index 4))
           collect
           (list (+ 1000 index) bulk-owner beg (+ beg 2))))
         (bulk-candidate-specs
          (cl-loop
           for index downfrom 127 to 0
           for beg = (+ 1 (* index 4))
           append
           (list
            (list (+ 3000 index) bulk-owner
                  (+ beg 2) (+ beg 4))
            (list (+ 2000 index) bulk-owner-copy
                  (1+ beg) (+ beg 3))
            (list (+ 4000 index) bulk-other-owner
                  beg (+ beg 2)))))
         (cases
          (list
           (list
            :name 'multiple-owners
            :request-specs
            (list
             (list 'a-late first-owner-copy 40 50)
             (list 'b-zero second-owner 60 60)
             (list 'a-first first-owner 10 20)
             (list 'b-range second-owner-copy 20 30)
             (list 'nil-range nil 90 100)
             (list 'invalid-new first-owner 55 54))
            :candidate-specs
            (list
             (list 'b-left-boundary-zero second-owner 20 20)
             (list 'cross-owner other-owner 10 20)
             (list 'a-second-overlap first-owner-copy 45 46)
             (list 'nil-overlap nil 95 96)
             (list 'a-adjacent first-owner 20 25)
             (list 'b-zero-equal second-owner-copy 60 60)
             (list 'a-first-overlap first-owner 15 18)
             (list 'b-adjacent second-owner 30 35)
             (list 'a-first-overlap first-owner-copy 15 18)
             (list 'b-cross-owner-only first-owner 25 28)
             (list 'a-right-boundary-zero first-owner 50 50)
             (list 'a-right-adjacent first-owner 50 55)
             (list 'invalid-candidate first-owner 45 44))
            :expected-ids
            '( b-left-boundary-zero a-second-overlap nil-overlap
               b-zero-equal a-first-overlap a-first-overlap
               a-right-boundary-zero)
            :equal-candidate-id 'a-first-overlap)
           (list
            :name 'zero-width-boundaries
            :request-specs
            (list
             (list 'zero first-owner 10 10)
             (list 'middle first-owner-copy 20 30)
             (list 'late first-owner 40 50))
            :candidate-specs
            (list
             (list 'right-nonempty-boundary first-owner-copy 10 15)
             (list 'other-owner-zero second-owner 10 10)
             (list 'adjacent-left first-owner 15 20)
             (list 'right-zero-boundary first-owner 30 30)
             (list 'same-zero first-owner-copy 10 10)
             (list 'inside-zero first-owner 25 25)
             (list 'adjacent-right first-owner 30 35)
             (list 'left-nonempty-boundary first-owner 5 10)
             (list 'left-zero-boundary first-owner-copy 20 20)
             (list 'separate-zero first-owner 19 19)
             (list 'far-right-zero first-owner 50 50)
             (list 'far-right-adjacent first-owner 50 55))
            :expected-ids
            '( right-nonempty-boundary right-zero-boundary
               same-zero inside-zero left-nonempty-boundary
               left-zero-boundary far-right-zero))
           (list
            :name 'no-valid-request-range
            :request-specs
            (list
             (list 'invalid-first first-owner 8 7)
             (list 'invalid-second second-owner 4 3))
            :candidate-specs
            (list
             (list 'unexamined-first first-owner 1 9)
             (list 'unexamined-second second-owner 2 6))
            :expected-ids nil
            :expected-candidate-range-calls 0)
           (list
            :name 'large-chunk-set
            :request-specs bulk-request-specs
            :candidate-specs bulk-candidate-specs
            :expected-ids
            (cl-loop
             for index downfrom 127 to 0
             collect (+ 2000 index))))))
    (dolist (case cases)
      (let* ((requests
              (mapcar
               (lambda (spec)
                 (pcase-let ((`(,id ,owner ,beg ,end) spec))
                   (proofread-test--owned-lifecycle-request
                    id owner beg end)))
               (plist-get case :request-specs)))
             (candidates
              (mapcar
               (lambda (spec)
                 (pcase-let ((`(,id ,owner ,beg ,end) spec))
                   (proofread-test--owned-lifecycle-request
                    id owner beg end)))
               (plist-get case :candidate-specs)))
             (original-requests (copy-sequence requests))
             (original-candidates (copy-sequence candidates))
             (candidate-requests
              (mapcar #'proofread-test--work-request candidates))
             (reference
              (proofread-test--reference-conflicting-request-candidates
               requests candidates))
             (actual-observation
              (let ((candidate-range-calls 0)
                    (original-request-range
                     (symbol-function 'proofread--request-range))
                    table)
                (setq table
                      (cl-letf
                          (((symbol-function
                             'proofread--request-range)
                            (lambda (request)
                              (when (memq request candidate-requests)
                                (setq candidate-range-calls
                                      (1+ candidate-range-calls)))
                              (funcall original-request-range
                                       request))))
                        (proofread--conflicting-request-table
                         requests candidates)))
                (list table candidate-range-calls)))
             (table (car actual-observation))
             (candidate-range-calls (cadr actual-observation))
             (actual
              (cl-remove-if-not
               (lambda (candidate)
                 (gethash candidate table))
               candidates))
             (expected-ids (plist-get case :expected-ids)))
        (should (eq (hash-table-test table) #'eq))
        (when (plist-member case :expected-candidate-range-calls)
          (should
           (= candidate-range-calls
              (plist-get case :expected-candidate-range-calls))))
        (should
         (= (hash-table-count table)
            (length
             (cl-delete-duplicates
              (copy-sequence reference) :test #'eq))))
        (should
         (equal
          (mapcar
           (lambda (candidate)
             (plist-get (proofread-test--work-request candidate)
                        :id))
           reference)
          expected-ids))
        (should
         (equal
          (mapcar
           (lambda (candidate)
             (plist-get (proofread-test--work-request candidate)
                        :id))
           actual)
          expected-ids))
        (should (= (length actual) (length reference)))
        (cl-mapc
         (lambda (actual-candidate reference-candidate)
           (should (eq actual-candidate reference-candidate)))
         actual reference)
        (cl-mapc
         (lambda (actual-request original-request)
           (should (eq actual-request original-request)))
         requests original-requests)
        (cl-mapc
         (lambda (actual-candidate original-candidate)
           (should (eq actual-candidate original-candidate)))
         candidates original-candidates)
        (when-let* ((equal-id
                     (plist-get case :equal-candidate-id))
                    (equal-candidates
                     (cl-remove-if-not
                      (lambda (candidate)
                        (eq
                         (plist-get
                          (proofread-test--work-request candidate)
                          :id)
                         equal-id))
                      actual)))
          (should (= (length equal-candidates) 2))
          (should (equal (car equal-candidates)
                         (cadr equal-candidates)))
          (should-not (eq (car equal-candidates)
                          (cadr equal-candidates)))
          (should (gethash (car equal-candidates) table))
          (should (gethash (cadr equal-candidates) table)))))))

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
         (proofread--queue-state (proofread--make-queue-state))
         (queued-first-entry
          (proofread--append-request-queue-entry
           proofread--queue-state
           (proofread--new-request-queue-entry
            proofread--queue-state queued-first)))
         (queued-retained-first-entry
          (proofread--append-request-queue-entry
           proofread--queue-state
           (proofread--new-request-queue-entry
            proofread--queue-state queued-retained-first)))
         (queued-retained-last-entry
          (proofread--append-request-queue-entry
           proofread--queue-state
           (proofread--new-request-queue-entry
            proofread--queue-state queued-retained-last)))
         (queued-last-entry
          (proofread--append-request-queue-entry
           proofread--queue-state
           (proofread--new-request-queue-entry
            proofread--queue-state queued-last)))
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
                  (mapcar #'proofread--queue-entry-work queue-input)))
         (request-value-snapshot
          (mapcar
           (lambda (work)
             (copy-tree (proofread--scheduled-work-request work)))
           all-requests))
         (queue-metadata-snapshot
          (mapcar
           (lambda (entry)
             (list (proofread--queue-entry-work entry)
                   (proofread--queue-entry-sequence entry)))
           queue-input))
         (selected
          (list active-first active-last claimed-selected
                queued-first queued-last))
         (expected-visits all-requests)
         (proofread--active-requests active-input)
         (proofread--claimed-requests claimed-input)
         (proofread--pending-request-keys
          (proofread-test--pending-request-table all-requests))
         (unpublished t)
         visits
         events
         cancelled-handles
         queue-index-snapshot
         queue-woken-snapshot
         queue-bucket-snapshot
         result)
    (proofread--wake-queued-cache-key
     (proofread--request-queue-entry-cache-key queued-first-entry))
    (proofread--wake-queued-cache-key
     (proofread--request-queue-entry-cache-key
      queued-retained-first-entry))
    (setq queue-index-snapshot
          (proofread--queue-state-index proofread--queue-state))
    (setq queue-woken-snapshot
          (proofread--queue-state-woken proofread--queue-state))
    (setq queue-bucket-snapshot
          (mapcar
           (lambda (entry)
             (gethash
              (proofread--request-queue-entry-cache-key entry)
              queue-index-snapshot))
           queue-input))
    (should-error
     (proofread--partition-pending-requests
      (lambda (request)
        (when (eq request queued-retained-last)
          (error "Simulated predicate failure"))
        (memq request selected))))
    (should (eq proofread--active-requests active-input))
    (should (eq proofread--claimed-requests claimed-input))
    (should (eq (proofread--queue-state-head proofread--queue-state)
                queued-first-entry))
    (should (eq (proofread--queue-state-tail proofread--queue-state)
                queued-last-entry))
    (should
     (cl-every #'eq
               (proofread--request-queue-entries)
               queue-input))
    (should (eq (proofread--queue-state-index proofread--queue-state)
                queue-index-snapshot))
    (should (eq (proofread--queue-state-woken proofread--queue-state)
                queue-woken-snapshot))
    (should
     (cl-every
      #'eq
      (mapcar
       (lambda (entry)
         (gethash
          (proofread--request-queue-entry-cache-key entry)
          queue-index-snapshot))
       queue-input)
      queue-bucket-snapshot))
    (should (= (hash-table-count queue-woken-snapshot) 2))
    (should (gethash queued-first-entry queue-woken-snapshot))
    (should (gethash queued-retained-first-entry
                     queue-woken-snapshot))
    (proofread-test--assert-queue-cache-index-consistent)
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
                              (cl-every
                               #'eq
                               (proofread--request-queue-entries)
                               queue-input)
                              (eq
                               (proofread--queue-state-head
                                proofread--queue-state)
                               queued-first-entry)
                              (eq
                               (proofread--queue-state-tail
                                proofread--queue-state)
                               queued-last-entry))
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
     (cl-every #'eq (proofread--request-queue-entries)
               (list queued-retained-first-entry
                     queued-retained-last-entry)))
    (should (eq (proofread--queue-state-tail proofread--queue-state)
                queued-retained-last-entry))
    (should (eq (proofread--queue-state-index proofread--queue-state)
                queue-index-snapshot))
    (should (eq (proofread--queue-state-woken proofread--queue-state)
                queue-woken-snapshot))
    (should-not (gethash queued-first-entry queue-woken-snapshot))
    (should (gethash queued-retained-first-entry
                     queue-woken-snapshot))
    (proofread-test--assert-queue-cache-index-consistent)
    (should (equal active-input active-snapshot))
    (should (cl-every #'eq active-input active-snapshot))
    (should (equal claimed-input claimed-snapshot))
    (should (cl-every #'eq claimed-input claimed-snapshot))
    (should (equal queue-input queue-snapshot))
    (should (cl-every #'eq queue-input queue-snapshot))
    (should
     (equal
      (mapcar #'proofread--scheduled-work-request all-requests)
      request-value-snapshot))
    (should
     (equal
      (mapcar
       (lambda (entry)
         (list (proofread--queue-entry-work entry)
               (proofread--queue-entry-sequence entry)))
       queue-input)
      queue-metadata-snapshot))
    (dolist (entry (list queued-first-entry queued-last-entry))
      (should-not (proofread--queue-entry-owner entry))
      (should-not (proofread--queue-entry-previous entry))
      (should-not (proofread--queue-entry-next entry)))
    (dolist (work all-requests)
      (should (eq (proofread--request-work-pending-p work)
                  work))
      (should-not
       (proofread--request-state-flag-p work :superseded))
      (should-not
       (proofread--request-state-flag-p work :invalidated))
      (should-not
       (proofread--request-state-flag-p work :cancelled)))
    (should-not events)
    (should-not cancelled-handles)))

(ert-deftest
    proofread-test-edit-affected-diagnostics-preserve-boundaries ()
  "Collect edit-affected identities in source order without copying."
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
           (_published-diagnostics
            (proofread-test--publish-diagnostics diagnostics)))
      (should (equal interior interior-copy))
      (should-not (eq interior interior-copy))
      (let ((affected
             (proofread--edit-affected-diagnostics 3 3))
            (expected-diagnostics (list interior interior-copy zero)))
        (should (equal affected expected-diagnostics))
        (should (cl-every #'eq affected expected-diagnostics)))
      (let ((affected
             (proofread--edit-affected-diagnostics 6 9))
            (expected-diagnostics (list covered end-zero)))
        (should (equal affected expected-diagnostics))
        (should
         (cl-every #'eq affected expected-diagnostics))))))

;;;; Flymake conversion tests

(ert-deftest proofread-test-flymake-conversion-preserves-data ()
  "Preserve Proofread data in a source-aware Flymake diagnostic."
  (with-temp-buffer
    (insert "hello")
    (let* ((owner (list :profile 'test :checker-name 'grammar))
           (suggestions (list "hello" "hullo"))
           (diagnostic
            (proofread--make-diagnostic
             :beg 2
             :end 6
             :text "ello"
             :kind 'spelling
             :message "Possible misspelling"
             :suggestions suggestions
             :source 'raw-backend))
           (diagnostic
            (plist-put diagnostic :source-label "grammar-checker"))
           (diagnostic
            (plist-put diagnostic :checker-owner owner))
           (original (copy-tree diagnostic))
           (constructor
            (symbol-function 'flymake-make-diagnostic))
           (calls 0)
           flymake-diagnostic)
      (cl-letf (((symbol-function 'flymake-make-diagnostic)
                 (lambda (&rest arguments)
                   (setq calls (1+ calls))
                   (apply constructor arguments))))
        (setq flymake-diagnostic
              (proofread--diagnostic-to-flymake diagnostic)))
      (should (= calls 1))
      (should (eq (flymake-diagnostic-buffer flymake-diagnostic)
                  (current-buffer)))
      (should (= (flymake-diagnostic-beg flymake-diagnostic) 2))
      (should (= (flymake-diagnostic-end flymake-diagnostic) 6))
      (should (eq (flymake-diagnostic-type flymake-diagnostic)
                  proofread--flymake-diagnostic-type))
      (should
       (equal (flymake-diagnostic-text flymake-diagnostic)
              "grammar-checker: Possible misspelling"))
      (let* ((data
              (flymake-diagnostic-data flymake-diagnostic))
             (unwrapped
              (proofread--flymake-to-diagnostic
               flymake-diagnostic)))
        (should (proofread--flymake-data-p data))
        (should (equal (proofread--flymake-data-range data)
                       (cons 2 6)))
        (should-not
         (proofread--flymake-data-anchor-edge data))
        (should (eq unwrapped diagnostic))
        (should (eq (plist-get unwrapped :checker-owner) owner))
        (should (eq (plist-get unwrapped :suggestions) suggestions))
        (should
         (equal (plist-get unwrapped :suggestions)
                '("hello" "hullo")))
        (should-not
         (proofread--flymake-to-diagnostic
          (flymake-make-diagnostic
           (current-buffer) 2 6 :warning "Other" data)))
        (should-not
         (proofread--flymake-to-diagnostic
          (flymake-make-diagnostic
           (current-buffer) 2 6
           proofread--flymake-diagnostic-type
           "Other" diagnostic))))
      (should (equal diagnostic original))
      (should
       (eq (get proofread--flymake-diagnostic-type
                'flymake-category)
           'flymake-warning))
      (should
       (equal (get proofread--flymake-diagnostic-type
                   'flymake-type-name)
              "proofread"))
      (should
       (= (get proofread--flymake-diagnostic-type 'severity)
          (warning-numeric-level :warning)))
      (should
       (eq (alist-get
            'face
            (get proofread--flymake-diagnostic-type
                 'flymake-overlay-control))
           'proofread-face)))))

(ert-deftest proofread-test-flymake-zero-width-anchors ()
  "Anchor zero-width diagnostics to characters in a nonempty buffer."
  (with-temp-buffer
    (insert "abc")
    (set-buffer-modified-p nil)
    (narrow-to-region 2 3)
    (dolist (case '((1 1 2 :beg)
                    (2 2 3 :beg)
                    (4 3 4 :end)))
      (pcase-let* ((`(,position ,expected-beg ,expected-end ,edge)
                    case)
                   (diagnostic
                    (proofread--make-diagnostic
                     :beg position
                     :end position
                     :text ""
                     :kind 'style
                     :message "Insert text"
                     :suggestions '("x")
                     :source 'test))
                   (original (copy-tree diagnostic))
                   (flymake-diagnostic
                    (proofread--diagnostic-to-flymake diagnostic))
                   (data
                    (flymake-diagnostic-data flymake-diagnostic)))
        (should (= (flymake-diagnostic-beg flymake-diagnostic)
                   expected-beg))
        (should (= (flymake-diagnostic-end flymake-diagnostic)
                   expected-end))
        (should (= (- expected-end expected-beg) 1))
        (should (equal (proofread--flymake-data-range data)
                       (cons position position)))
        (should (eq (proofread--flymake-data-anchor-edge data)
                    edge))
        (should (eq (proofread--flymake-to-diagnostic
                     flymake-diagnostic)
                    diagnostic))
        (should (equal (proofread-diagnostic-range diagnostic)
                       (cons position position)))
        (should (equal diagnostic original))))
    (should (= (point-min) 2))
    (should (= (point-max) 3))
    (save-restriction
      (widen)
      (should (equal (buffer-string) "abc")))
    (should-not (buffer-modified-p))))

(ert-deftest proofread-test-flymake-empty-buffer-anchor ()
  "Keep the only valid zero-width anchor in an empty buffer."
  (with-temp-buffer
    (let* ((diagnostic
            (proofread--make-diagnostic
             :beg 1
             :end 1
             :text ""
             :kind 'style
             :message "Insert text"
             :suggestions '("x")
             :source 'test))
           (flymake-diagnostic
            (proofread--diagnostic-to-flymake diagnostic))
           (data (flymake-diagnostic-data flymake-diagnostic)))
      (should (= (flymake-diagnostic-beg flymake-diagnostic) 1))
      (should (= (flymake-diagnostic-end flymake-diagnostic) 1))
      (should (equal (proofread--flymake-data-range data)
                     (cons 1 1)))
      (should (eq (proofread--flymake-data-anchor-edge data)
                  :empty))
      (should (eq (proofread--flymake-to-diagnostic
                   flymake-diagnostic)
                  diagnostic))
      (should (equal (buffer-string) ""))
      (should-not (buffer-modified-p)))))

;;;; Flymake bridge tests

(ert-deftest proofread-test-flymake-bridge-snapshots-latest-token ()
  "Publish each full snapshot and retain only the latest report token."
  (with-temp-buffer
    (insert "abcdef")
    (setq-local proofread-mode t)
    (let (captured-a captured-b reports-a reports-b report-a report-b)
      (setq report-a
            (lambda (&rest arguments)
              (setq captured-a
                    (eq proofread--flymake-report-function report-a))
              (push arguments reports-a)))
      (setq report-b
            (lambda (&rest arguments)
              (setq captured-b
                    (eq proofread--flymake-report-function report-b))
              (push arguments reports-b)))
      (proofread--flymake-backend report-a)
      (should captured-a)
      (should (eq proofread--flymake-report-function report-a))
      (should (equal reports-a '((nil))))
      (let ((diagnostics
             (list
              (proofread-test--diagnostic-for-range 1 3 "ab")
              (proofread-test--diagnostic-for-range 4 7 "def"))))
        (setq proofread--diagnostics diagnostics)
        (proofread--flymake-backend report-b)
        (should captured-b)
        (should (eq proofread--flymake-report-function report-b))
        (should (= (length (caar reports-b)) 2))
        (should
         (equal (mapcar #'proofread--flymake-to-diagnostic
                        (caar reports-b))
                diagnostics)))
      (narrow-to-region 2 4)
      (proofread--disable-flymake-bridge)
      (should (equal reports-a '((nil))))
      (should
       (equal (car reports-b)
              '(nil :region (1 . 7))))
      (should-not proofread--flymake-report-function))))

(ert-deftest proofread-test-flymake-bridge-coexists-and-clears-widely ()
  "Clear only Proofread diagnostics while preserving another backend."
  (with-temp-buffer
    (insert "helo foreign")
    (setq-local proofread-auto-check nil)
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
    (let ((flymake-start-on-flymake-mode nil))
      (flymake-mode 1))
    (unwind-protect
        (progn
          (let ((original-mode (symbol-function 'flymake-mode))
                (original-start (symbol-function 'flymake-start))
                (mode-calls 0)
                (start-calls 0))
            (cl-letf (((symbol-function 'flymake-mode)
                       (lambda (&optional argument)
                         (setq mode-calls (1+ mode-calls))
                         (funcall original-mode argument)))
                      ((symbol-function 'flymake-start)
                       (lambda (&rest arguments)
                         (setq start-calls (1+ start-calls))
                         (apply original-start arguments))))
              (proofread-mode 1))
            (should (= mode-calls 0))
            (should (= start-calls 1)))
          (setq proofread--diagnostics
                (list
                 (proofread-test--diagnostic-for-range 1 5 "helo")))
          (flymake-start)
          (let ((diagnostics (flymake-diagnostics)))
            (should (= (length diagnostics) 2))
            (should
             (= (cl-count #'proofread--flymake-backend diagnostics
                          :key #'flymake-diagnostic-backend)
                1))
            (should
             (= (cl-count
                 #'proofread-test--flymake-foreign-backend diagnostics
                 :key #'flymake-diagnostic-backend)
                1)))
          ;; The Proofread diagnostic lies outside this restriction.
          ;; Teardown must nevertheless clear it from Flymake.
          (narrow-to-region 7 10)
          (proofread-mode -1)
          (should flymake-mode)
          (should-not
           (memq #'proofread--flymake-backend
                 flymake-diagnostic-functions))
          (should
           (memq #'proofread-test--flymake-foreign-backend
                 flymake-diagnostic-functions))
          (should-not
           (memq #'proofread--flymake-mode-changed flymake-mode-hook))
          (should-not proofread--flymake-report-function)
          (save-restriction
            (widen)
            (let ((diagnostics (flymake-diagnostics)))
              (should (= (length diagnostics) 1))
              (should
               (eq (flymake-diagnostic-backend (car diagnostics))
                   #'proofread-test--flymake-foreign-backend)))))
      (when proofread-mode
        (proofread-mode -1))
      (when flymake-mode
        (flymake-mode -1)))))

(ert-deftest proofread-test-flymake-bridge-isolates-conversion-errors ()
  "Replace stale diagnostics without disabling the bridge on errors."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (unwind-protect
        (progn
          (proofread-mode 1)
          (setq proofread--diagnostics
                (list
                 (proofread-test--diagnostic-for-range 1 6 "Alpha")))
          (flymake-start)
          (should (= (length (flymake-diagnostics)) 1))
          (cl-letf
              (((symbol-function
                 'proofread--flymake-diagnostics-snapshot)
                (lambda ()
                  (error "Simulated conversion failure")))
               ((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (_message _summary))))
            (flymake-start))
          (should-not (flymake-diagnostics))
          (should-not
           (memq #'proofread--flymake-backend
                 (flymake-disabled-backends)))
          (flymake-start)
          (should (= (length (flymake-diagnostics)) 1)))
      (when proofread-mode
        (proofread-mode -1))
      (when flymake-mode
        (flymake-mode -1)))))

(ert-deftest proofread-test-flymake-bridge-enable-is-idempotent ()
  "Enable Flymake once and explicitly start one check per enable."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
    (let ((original-mode (symbol-function 'flymake-mode))
          (original-start (symbol-function 'flymake-start))
          (flymake-start-on-flymake-mode t)
          (flymake-no-changes-timeout 17)
          (mode-calls 0)
          (start-calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'flymake-mode)
                     (lambda (&optional argument)
                       (setq mode-calls (1+ mode-calls))
                       (funcall original-mode argument)))
                    ((symbol-function 'flymake-start)
                     (lambda (&rest arguments)
                       (setq start-calls (1+ start-calls))
                       (apply original-start arguments))))
            (proofread-mode 1)
            (proofread-mode 1)
            (should flymake-mode)
            (should (= mode-calls 1))
            (should (= start-calls 2))
            (should flymake-start-on-flymake-mode)
            (should (= flymake-no-changes-timeout 17))
            (should
             (= (cl-count #'proofread--flymake-backend
                          flymake-diagnostic-functions)
                1))
            (should
             (= (cl-count #'proofread--flymake-mode-changed
                          flymake-mode-hook)
                1))
            (should
             (memq #'proofread-test--flymake-foreign-backend
                   flymake-diagnostic-functions))
            (proofread-mode -1)
            (should flymake-mode)
            (should-not
             (memq #'proofread--flymake-backend
                   flymake-diagnostic-functions)))
        (when proofread-mode
          (proofread-mode -1))
        (when flymake-mode
          (funcall original-mode -1))))))

(ert-deftest proofread-test-disabling-flymake-disables-proofread ()
  "Synchronously tear Proofread down when Flymake is disabled."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
    (proofread-mode 1)
    (setq proofread--diagnostics
          (list
           (proofread-test--diagnostic-for-range 1 6 "Alpha")))
    (flymake-start)
    (let ((report-function proofread--flymake-report-function)
          report-calls)
      (setq proofread--flymake-report-function
            (lambda (&rest arguments)
              (push arguments report-calls)
              (apply report-function arguments)))
      (flymake-mode -1)
      (should-not proofread-mode)
      (should (equal report-calls
                     '((nil :region (1 . 6)))))
      (should-not proofread--flymake-report-function)
      (should-not
       (memq #'proofread--flymake-backend
             flymake-diagnostic-functions))
      (should-not
       (memq #'proofread--flymake-mode-changed flymake-mode-hook))
      (should
       (memq #'proofread-test--flymake-foreign-backend
             flymake-diagnostic-functions))
      (should-not (memq (current-buffer) proofread--mode-buffers))
      (should-not (flymake-diagnostics)))))

(ert-deftest proofread-test-kill-cleans-flymake-bridge-in-either-order ()
  "Clean the bridge whether Flymake precedes or follows Proofread."
  (dolist (flymake-preexisting '(nil t))
    (let ((buffer
           (generate-new-buffer
            (format " *proofread-flymake-kill-%s*"
                    flymake-preexisting)))
          report-calls)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (setq-local flymake-diagnostic-functions
                          (list
                           #'proofread-test--flymake-foreign-backend))
              (when flymake-preexisting
                (let ((flymake-start-on-flymake-mode nil))
                  (flymake-mode 1)))
              (proofread-mode 1)
              (should (eq (car kill-buffer-hook)
                          #'proofread--kill-buffer))
              (let ((report-function
                     proofread--flymake-report-function))
                (setq proofread--flymake-report-function
                      (lambda (&rest arguments)
                        (push arguments report-calls)
                        (apply report-function arguments)))))
            (kill-buffer buffer)
            (should-not (buffer-live-p buffer))
            (should (equal report-calls
                           '((nil :region (1 . 6)))))
            (should-not (memq buffer proofread--mode-buffers)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

;;;; Flymake diagnostic commit tests

(ert-deftest
    proofread-test-regional-report-precedes-hook-and-preserves-foreign
    ()
  "Publish one regional snapshot before hooks without touching peers."
  (with-temp-buffer
    (insert "helo")
    (setq-local proofread-auto-check nil)
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
    (proofread-test--with-profile
      (proofread-mode 1)
      (let* ((foreign-before
              (cl-find-if
               (lambda (diagnostic)
                 (eq (flymake-diagnostic-backend diagnostic)
                     #'proofread-test--flymake-foreign-backend))
               (flymake-diagnostics)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 5)))))
             (request (proofread-test--make-profile-request chunk))
             (work (proofread--make-request-work request))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo"))
             (original-report-function
              proofread--flymake-report-function)
             (report-count 0)
             (hook-count 0)
             events
             report-arguments
             hook-flymake
             hook-model)
        (should foreign-before)
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq report-count (1+ report-count))
                (setq report-arguments arguments)
                (push 'report events)
                (apply original-report-function arguments)))
        (add-hook
         'proofread-diagnostics-changed-hook
         (lambda ()
           (setq hook-count (1+ hook-count))
           (setq hook-flymake
                 (proofread-test--flymake-proofread-diagnostics))
           (setq hook-model (copy-sequence proofread--diagnostics))
           (push 'hook events))
         nil t)
        (should
         (eq
          (proofread--handle-backend-result
           work
           (proofread--backend-success-result
            request (list diagnostic)))
          'applied))
        (should (= report-count 1))
        (should (= hook-count 1))
        (should (equal (reverse events) '(report hook)))
        (should (plist-get (cdr report-arguments) :region))
        (should (equal hook-flymake hook-model))
        (should (equal hook-model proofread--diagnostics))
        (should
         (eq
          foreign-before
          (cl-find-if
           (lambda (candidate)
             (eq (flymake-diagnostic-backend candidate)
                 #'proofread-test--flymake-foreign-backend))
           (flymake-diagnostics))))))))

(ert-deftest
    proofread-test-equal-final-replacement-publishes-new-identity ()
  "Publish an equal final replacement with its new model identity."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0))
      (proofread-test--with-profile
        (proofread-mode 1)
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((1 . 5)))))
               (work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (request (proofread-test--work-request work))
               (raw
                (proofread-test--diagnostic-for-range 1 5 "helo"))
               (old
                (proofread--diagnostic-with-request-provenance
                 request raw)))
          (proofread-test--publish-diagnostics (list old))
          (proofread--record-diagnostic-request-ranges
           (list old) (cons 1 5))
          (flymake-start)
          (let ((original-report-function
                 proofread--flymake-report-function)
                (report-count 0)
                (hook-count 0)
                events
                report-arguments)
            (setq proofread--flymake-report-function
                  (lambda (&rest arguments)
                    (setq report-count (1+ report-count))
                    (setq report-arguments arguments)
                    (push 'report events)
                    (apply original-report-function arguments)))
            (add-hook
             'proofread-diagnostics-changed-hook
             (lambda ()
               (setq hook-count (1+ hook-count))
               (push 'hook events))
             nil t)
            (should
             (eq
              (proofread--handle-backend-result
               work
               (proofread--backend-success-result
                request (list (copy-sequence raw))))
              'applied))
            (let ((live (car proofread--diagnostics))
                  (reported
                   (mapcar #'proofread--flymake-to-diagnostic
                           (car report-arguments))))
              (should (= report-count 1))
              (should (= hook-count 1))
              (should (equal (reverse events) '(report hook)))
              (should (plist-get (cdr report-arguments) :region))
              (should (equal live old))
              (should-not (eq live old))
              (should (eq (car reported) live))
              (should
               (eq
                (car
                 (proofread-test--flymake-proofread-diagnostics))
                live)))))))))

(ert-deftest
    proofread-test-partial-report-includes-all-checkers-and-skips-no-op
    ()
  "Report every checker after a partial change and skip duplicates."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles)))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checkers (plist-get profile :checkers))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 5)))))
             (first-work
              (proofread-test--make-request-work
               chunk proofread-test--backend (car checkers) profile))
             (second-work
              (proofread-test--make-request-work
               chunk proofread-test--backend (cadr checkers) profile))
             (first-request
              (proofread-test--work-request first-work))
             (second-request
              (proofread-test--work-request second-work))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo"))
             (second-diagnostic
              (plist-put
               (copy-sequence diagnostic)
               :message "Second checker issue")))
        (should
         (eq
          (proofread--handle-backend-result
           first-work
           (proofread--backend-partial-success-result
            first-request (list diagnostic)))
          'applied))
        (let ((original-report-function
               proofread--flymake-report-function)
              (report-count 0)
              (hook-count 0)
              events
              report-arguments
              hook-flymake
              hook-model)
          (setq proofread--flymake-report-function
                (lambda (&rest arguments)
                  (setq report-count (1+ report-count))
                  (setq report-arguments arguments)
                  (push 'report events)
                  (apply original-report-function arguments)))
          (add-hook
           'proofread-diagnostics-changed-hook
           (lambda ()
             (setq hook-count (1+ hook-count))
             (setq hook-flymake
                   (proofread-test--flymake-proofread-diagnostics))
             (setq hook-model
                   (copy-sequence proofread--diagnostics))
             (push 'hook events))
           nil t)
          (let ((partial
                 (proofread--backend-partial-success-result
                  second-request (list second-diagnostic))))
            (should
             (eq (proofread--handle-backend-result
                  second-work partial)
                 'applied))
            (should (= report-count 1))
            (should (= hook-count 1))
            (should (equal (reverse events) '(report hook)))
            (should (plist-get (cdr report-arguments) :region))
            (let ((reported
                   (apply
                    #'append
                    (mapcar
                     (lambda (flymake-diagnostic)
                       (copy-sequence
                        (proofread--diagnostic-members
                         (proofread--flymake-to-diagnostic
                          flymake-diagnostic))))
                     (car report-arguments)))))
              (should
               (equal
                (mapcar (lambda (live-diagnostic)
                          (plist-get live-diagnostic :checker-name))
                        reported)
                '(first second))))
            (should (= (length hook-flymake) (length hook-model)))
            (dolist (live-diagnostic hook-model)
              (should (memq live-diagnostic hook-flymake)))
            (should
             (eq (proofread--handle-backend-result
                  second-work partial)
                 'applied))
            (should (= report-count 1))
            (should (= hook-count 1))
            (should (equal (reverse events) '(report hook)))
            (should (= (length proofread--diagnostics) 2))))))))

(ert-deftest
    proofread-test-regional-report-expands-zero-width-anchor-while-narrowed
    ()
  "Expand a request-end anchor and retain another checker's survivor."
  (with-temp-buffer
    (insert "ab cd")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles)))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checkers (plist-get profile :checkers))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 3)))))
             (first-work
              (proofread-test--make-request-work
               chunk proofread-test--backend (car checkers) profile))
             (first-request
              (proofread-test--work-request first-work))
             (first
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 3 3 "")
               'first))
             (second
              (plist-put
               (proofread-test--diagnostic-with-checker
                (proofread-test--diagnostic-for-range 3 3 "")
                'second)
               :message "Second checker survivor")))
        (proofread-test--publish-diagnostics (list first second))
        (proofread--record-diagnostic-request-ranges
         (list first) (cons 1 3))
        (flymake-start)
        (should
         (= (length
             (proofread-test--flymake-proofread-diagnostics))
            2))
        (let ((original-report-function
               proofread--flymake-report-function)
              (report-count 0)
              (hook-count 0)
              events
              report-arguments
              hook-flymake)
          (setq proofread--flymake-report-function
                (lambda (&rest arguments)
                  (setq report-count (1+ report-count))
                  (setq report-arguments arguments)
                  (push 'report events)
                  (apply original-report-function arguments)))
          (add-hook
           'proofread-diagnostics-changed-hook
           (lambda ()
             (setq hook-count (1+ hook-count))
             (setq hook-flymake
                   (proofread-test--flymake-proofread-diagnostics))
             (push 'hook events))
           nil t)
          (narrow-to-region 4 6)
          (should
           (proofread--replace-backend-diagnostics
            first-request nil))
          (should (= (point-min) 4))
          (should (= (point-max) 6))
          (should (= report-count 1))
          (should (= hook-count 1))
          (should (equal (reverse events) '(report hook)))
          (let* ((region
                  (plist-get (cdr report-arguments) :region))
                 (reported
                  (mapcar #'proofread--flymake-to-diagnostic
                          (car report-arguments))))
            (should region)
            ;; The old logical position 3 was presented at [3, 4].
            (should (< 3 (cdr region)))
            (should (< (car region) 4))
            (should
             (> (cdr region)
                (proofread--position-integer
                 (plist-get first-request :end))))
            (should (equal reported (list second))))
          (should (equal proofread--diagnostics (list second)))
          (should (equal hook-flymake (list second)))
          (should
           (equal (proofread-test--flymake-proofread-diagnostics)
                  (list second))))))))

(ert-deftest
    proofread-test-empty-buffer-commit-reports-snapshot-and-skips-no-op
    ()
  "Report an empty-buffer snapshot once and skip a later no-op."
  (with-temp-buffer
    (let ((proofread-auto-check nil)
          (report-count 0)
          (hook-count 0)
          events
          original-report-function
          report-arguments
          report-completed-p
          hook-model)
      (proofread-mode 1)
      (setq original-report-function
            proofread--flymake-report-function)
      (setq proofread--flymake-report-function
            (lambda (&rest arguments)
              (setq report-count (1+ report-count))
              (setq report-arguments arguments)
              (push 'report events)
              (apply original-report-function arguments)
              (setq report-completed-p t)))
      (add-hook
       'proofread-diagnostics-changed-hook
       (lambda ()
         (setq hook-count (1+ hook-count))
         (setq hook-model (copy-sequence proofread--diagnostics))
         (push 'hook events))
       nil t)
      (proofread--apply-backend-diagnostics
       (list
        (proofread-test--diagnostic-for-range 1 1 ""))
       (cons 1 1))
      (should (= report-count 1))
      (should (= hook-count 1))
      (should (equal (reverse events) '(report hook)))
      (should (equal (cdr report-arguments)
                     '(:region (1 . 1))))
      (should report-completed-p)
      (let ((reported
             (mapcar #'proofread--flymake-to-diagnostic
                     (car report-arguments))))
        (should (= (length reported) 1))
        (should (eq (car reported) (car hook-model))))
      (should-not
       (proofread--commit-diagnostic-state
        (cons 1 1) (lambda () nil)))
      (should (= report-count 1))
      (should (= hook-count 1))
      (should (equal (reverse events) '(report hook))))))

(ert-deftest proofread-test-edit-commit-republishes-boundary-range ()
  "Republish a moved Flymake range before notifying edit observers."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (diagnostic
           (proofread-test--diagnostic-for-range 1 5 "helo"))
          (report-count 0)
          (hook-count 0)
          events
          hook-range
          hook-flymake-range)
      (proofread-mode 1)
      (proofread-test--publish-diagnostics (list diagnostic))
      (let ((original-report-function
             proofread--flymake-report-function))
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq report-count (1+ report-count))
                (push 'report events)
                (apply original-report-function arguments))))
      (add-hook
       'proofread-diagnostics-changed-hook
       (lambda ()
         (setq hook-count (1+ hook-count))
         (setq hook-range
               (proofread-diagnostic-range diagnostic))
         (when-let* ((flymake-diagnostic
                      (car (proofread--owned-flymake-diagnostics))))
           (setq hook-flymake-range
                 (cons
                  (flymake-diagnostic-beg flymake-diagnostic)
                  (flymake-diagnostic-end flymake-diagnostic))))
         (push 'hook events))
       nil t)
      (goto-char (point-min))
      (insert "x")
      (should (= report-count 1))
      (should (= hook-count 1))
      (should (equal (reverse events) '(report hook)))
      (should (equal hook-range '(2 . 6)))
      (should (equal hook-flymake-range '(2 . 6)))
      (should (equal (proofread--diagnostic-range diagnostic)
                     '(1 . 5)))
      (should-not (proofread-diagnostic-at-point 1))
      (should (eq (proofread-diagnostic-at-point 2) diagnostic))
      ;; Insertion at the half-open end stays outside and changes no
      ;; published diagnostic state.
      (goto-char 6)
      (insert "q")
      (should (= report-count 1))
      (should (= hook-count 1))
      (should (equal (proofread-diagnostic-range diagnostic)
                     '(2 . 6))))))

(ert-deftest proofread-test-ignore-aggregate-commits-once-per-buffer ()
  "Remove all aggregate ignore keys in one buffer commit."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread--ignored-diagnostics
           (make-hash-table :test #'equal))
          (first
           (plist-put
            (proofread-test--diagnostic-for-range 1 5 "helo")
            :source 'first-ignore-source))
          (second
           (plist-put
            (proofread-test--diagnostic-for-range 1 5 "helo")
            :source 'second-ignore-source))
          (report-count 0)
          (hook-count 0))
      (proofread-mode 1)
      (proofread-test--publish-diagnostics (list first second))
      (let ((original-report-function
             proofread--flymake-report-function))
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq report-count (1+ report-count))
                (apply original-report-function arguments))))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq hook-count (1+ hook-count)))
                nil t)
      (goto-char 2)
      (should
       (= (length
           (proofread--diagnostic-members
            (proofread-diagnostic-at-point)))
          2))
      (should (eq (proofread-ignore) 'ignored))
      (should (= report-count 1))
      (should (= hook-count 1))
      (should-not proofread--diagnostics)
      (should (= (hash-table-count proofread--ignored-diagnostics) 2)))))

(ert-deftest proofread-test-narrowed-clear-is-one-backend-local-commit
    ()
  "Clear widely once, preserve foreign diagnostics, and skip a no-op."
  (with-temp-buffer
    (insert "abcdefgh")
    (let ((proofread-auto-check nil)
          (diagnostic
           (proofread-test--diagnostic-for-range 1 4 "abc"))
          (report-count 0)
          (hook-count 0))
      (setq-local flymake-diagnostic-functions
                  (list #'proofread-test--flymake-foreign-backend))
      (proofread-mode 1)
      (proofread-test--publish-diagnostics (list diagnostic))
      (let ((foreign-before
             (cl-find-if
              (lambda (flymake-diagnostic)
                (eq (flymake-diagnostic-backend flymake-diagnostic)
                    #'proofread-test--flymake-foreign-backend))
              (flymake-diagnostics)))
            (original-report-function
             proofread--flymake-report-function))
        (should foreign-before)
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq report-count (1+ report-count))
                (apply original-report-function arguments)))
        (add-hook 'proofread-diagnostics-changed-hook
                  (lambda ()
                    (setq hook-count (1+ hook-count)))
                  nil t)
        (narrow-to-region 5 9)
        (proofread-clear)
        (should (= report-count 1))
        (should (= hook-count 1))
        (should-not proofread--diagnostics)
        (should
         (eq foreign-before
             (cl-find-if
              (lambda (flymake-diagnostic)
                (eq (flymake-diagnostic-backend flymake-diagnostic)
                    #'proofread-test--flymake-foreign-backend))
              (flymake-diagnostics))))
        (proofread-clear)
        (should (= report-count 1))
        (should (= hook-count 1))))))

;;;; Flymake face and mode tests

(ert-deftest proofread-test-face-defaults-avoid-fixed-colors ()
  "Proofread faces are defined without fixed color attributes."
  (dolist (face '( proofread-face))
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

(ert-deftest proofread-test-face-uses-font-lock-warning-face ()
  "Diagnostic text uses the theme's font-lock warning face."
  (let ((spec (face-default-spec 'proofread-face)))
    (should
     (proofread-test--tree-member-p 'font-lock-warning-face spec))
    (should (proofread-test--tree-member-p :underline spec))))

(ert-deftest proofread-test-clear-preserves-unrelated-overlays ()
  "Clearing diagnostics preserves unrelated overlays."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread-clear)
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-edit-invalidates-proofread-diagnostic ()
  "Editing covered text removes only the Proofread diagnostic."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--publish-diagnostics (list diagnostic))
      (goto-char 3)
      (insert "x")
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics))))

(ert-deftest proofread-test-before-change-paths-select-same-state ()
  "Select the same identities for ordinary and deferred invalidation."
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
      (proofread-test--publish-diagnostics (list first same outside))
      (proofread--before-change 3 3)
      (let ((ordinary-diagnostics
             (copy-sequence
              proofread--pending-invalidated-diagnostics)))
        (setq proofread--pending-invalidated-diagnostics nil)
        (setq proofread--pending-diagnostic-ranges nil)
        (let ((proofread--inhibit-diagnostic-invalidation
               (current-buffer))
              (proofread--deferred-correction-diagnostics nil))
          (proofread--before-change 3 3)
          (proofread--before-change 3 3)
          (should (= (length
                      proofread--deferred-correction-diagnostics)
                     (length ordinary-diagnostics)))
          (dolist (diagnostic ordinary-diagnostics)
            (should
             (memq diagnostic
                   proofread--deferred-correction-diagnostics))))))))

(ert-deftest proofread-test-disable-mode-clears-proofread-diagnostics ()
  "Disabling `proofread-mode' clears its Flymake diagnostics only."
  (with-temp-buffer
    (insert "hello world")
    (proofread-mode 1)
    (let* ((diagnostic (proofread-test--diagnostic))
           (foreign-overlay (make-overlay 1 6)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread-mode -1)
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--diagnostics))))

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
              (should-not (proofread-test--flymake-proofread-diagnostics))
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
            (let ((proofread-test--backend-check-function
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

(ert-deftest proofread-test-check-ranges-consumes-selection-plan-once
    ()
  "Use one selection plan throughout the main check pipeline."
  (with-temp-buffer
    (insert "abcd")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let* ((raw-ranges (list (cons 4 1)))
           (selected-ranges (list (cons 1 2) (cons 3 5)))
           (domain-token (list 'complete-domain))
           (domains
            (list (list :kind 'text
                        :target-policy 'all
                        :domain-beg 1
                        :domain-end 5
                        :token domain-token)))
           (islands
            (list (list :beg 1 :end 2 :kind 'text)
                  (list :beg 3 :end 5 :kind 'text)))
           (plan
            (proofread--make-selection-plan
             selected-ranges domains islands))
           (profile (list :language "en" :checkers '( checker)))
           (chunks (list (list :text "a") (list :text "cd")))
           (dispatch-result
            (list :supported-count 1
                  :requests '( request-a request-b)))
           (plan-count 0)
           (profile-count 0)
           (prune-count 0)
           (chunk-count 0)
           (dispatch-count 0)
           prune-arguments
           chunk-arguments
           dispatch-arguments
           messages)
      (cl-letf
          (((symbol-function 'proofread--current-profile)
            (lambda ()
              (setq profile-count (1+ profile-count))
              profile))
           ((symbol-function 'proofread--selection-plan-for-ranges)
            (lambda (ranges)
              (setq plan-count (1+ plan-count))
              (should (eq ranges raw-ranges))
              plan))
           ((symbol-function 'proofread--normalize-accessible-ranges)
            (lambda (&rest _)
              (ert-fail "Check path normalized ranges outside plan")))
           ((symbol-function
             'proofread--prune-invalid-checked-diagnostics)
            (lambda (received-plan received-profile)
              (setq prune-count (1+ prune-count))
              (setq prune-arguments
                    (list received-plan received-profile))))
           ((symbol-function
             'proofread--request-ready-chunks-for-islands)
            (lambda (received-islands language)
              (setq chunk-count (1+ chunk-count))
              (setq chunk-arguments
                    (list received-islands language))
              chunks))
           ((symbol-function
             'proofread--dispatch-profile-request-ready-chunks-result)
            (lambda (received-chunks received-profile)
              (setq dispatch-count (1+ dispatch-count))
              (setq dispatch-arguments
                    (list received-chunks received-profile))
              dispatch-result))
           ((symbol-function 'proofread--target-domains-for-ranges)
            (lambda (&rest _)
              (ert-fail "Check path rediscovered target domains")))
           ((symbol-function 'proofread--target-islands-for-ranges)
            (lambda (&rest _)
              (ert-fail "Check path rediscovered target islands")))
           ((symbol-function 'message)
            (lambda (format-string &rest arguments)
              (push (apply #'format format-string arguments)
                    messages))))
        (proofread--check-ranges raw-ranges "selected" t))
      (should (= plan-count 1))
      (should (= profile-count 1))
      (should (= prune-count 1))
      (should (= chunk-count 1))
      (should (= dispatch-count 1))
      (should (eq (car prune-arguments) plan))
      (should (eq (cadr prune-arguments) profile))
      (should (eq (car chunk-arguments) islands))
      (should (equal (cadr chunk-arguments) "en"))
      (should (eq (car dispatch-arguments) chunks))
      (should (eq (cadr dispatch-arguments) profile))
      (should
       (equal messages
              '( "proofread: dispatched 2 requests from 2 selected \
ranges"))))))

(ert-deftest proofread-test-check-ranges-preserves-empty-dispatch-states
    ()
  "Keep empty, unsupported, and supported-zero-chunk feedback distinct."
  (dolist
      (case
       '( (:checkers nil
                     :islands (island)
                     :chunks (chunk)
                     :result nil
                     :chunk-count 0
                     :dispatch-count 0
                     :message
                     "proofread: collected 1 buffer range; \
no available backend")
          (:checkers (checker)
                     :islands (island)
                     :chunks (chunk)
                     :result (:supported-count 0 :requests nil)
                     :chunk-count 1
                     :dispatch-count 1
                     :message
                     "proofread: collected 1 buffer range; \
no available backend")
          (:checkers (checker)
                     :islands nil
                     :chunks nil
                     :result (:supported-count 1 :requests nil)
                     :chunk-count 1
                     :dispatch-count 1
                     :message
                     "proofread: dispatched 0 requests from 1 buffer range")))
    (with-temp-buffer
      (insert "a")
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let* ((ranges (list (cons (point-min) (point-max))))
             (plan
              (proofread--make-selection-plan
               ranges nil (plist-get case :islands)))
             (profile
              (list :language "en"
                    :checkers (plist-get case :checkers)))
             (chunk-count 0)
             (dispatch-count 0)
             messages)
        (cl-letf
            (((symbol-function 'proofread--current-profile)
              (lambda () profile))
             ((symbol-function 'proofread--selection-plan-for-ranges)
              (lambda (_ranges) plan))
             ((symbol-function
               'proofread--prune-invalid-checked-diagnostics)
              #'ignore)
             ((symbol-function
               'proofread--request-ready-chunks-for-islands)
              (lambda (_islands _language)
                (setq chunk-count (1+ chunk-count))
                (plist-get case :chunks)))
             ((symbol-function
               'proofread--dispatch-profile-request-ready-chunks-result)
              (lambda (_chunks _profile)
                (setq dispatch-count (1+ dispatch-count))
                (plist-get case :result)))
             ((symbol-function 'message)
              (lambda (format-string &rest arguments)
                (push (apply #'format format-string arguments)
                      messages))))
          (proofread--check-ranges ranges "buffer" t))
        (should (= chunk-count (plist-get case :chunk-count)))
        (should (= dispatch-count (plist-get case :dispatch-count)))
        (should (equal messages (list (plist-get case :message))))))))

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
                  (let ((proofread-test--backend-check-function
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
            (let ((proofread-test--backend-check-function
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
          (let ((proofread-test--backend-check-function
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

(ert-deftest proofread-test-check-at-point-builds-selected-chunk-once
    ()
  "Build and dispatch the point selection without repeating stages."
  (with-temp-buffer
    (insert "Outside prefix. First.  Second sentence. Third. "
            "Outside suffix.")
    (goto-char (point-min))
    (search-forward "First.")
    (let ((narrow-beg (match-beginning 0)))
      (search-forward "Third.")
      (let ((narrow-end (match-end 0)))
        (narrow-to-region narrow-beg narrow-end)
        (goto-char (point-min))
        (search-forward "Second sentence.")
        (goto-char (+ (match-beginning 0) 3))
        (push-mark (point-min) t t)
        (setq-local proofread-auto-check nil)
        (proofread-mode 1)
        (let ((proofread-test--profile-language "en")
              (proofread-context-size 100)
              (proofread-context-sentences-before 1)
              (proofread-context-sentences-after 1)
              (plan-function
               (symbol-function
                'proofread--selection-plan-for-ranges))
              (span-function
               (symbol-function
                'proofread--request-spans-for-islands))
              (materialize-function
               (symbol-function
                'proofread--request-ready-chunks-for-request-spans))
              (chunk-function
               (symbol-function 'proofread--make-request-ready-chunk))
              (profile-function
               (symbol-function 'proofread--current-profile))
              (check-function
               (symbol-function 'proofread--check-selection-plan))
              (before-text (buffer-string))
              (before-tick (buffer-chars-modified-tick))
              (before-point (point))
              (before-mark (mark t))
              (before-mark-active mark-active)
              (before-min (point-min))
              (before-max (point-max))
              (plan-count 0)
              (span-count 0)
              (materialize-count 0)
              (chunk-count 0)
              (profile-count 0)
              (check-count 0)
              (dispatch-count 0)
              discovered-domains
              selected-plan
              selected-profile
              selected-request-spans
              materialized-request-spans
              dispatched-chunks
              dispatched-profile)
          (proofread-test--with-profile
            (cl-letf
                (((symbol-function
                   'proofread--selection-plan-for-ranges)
                  (lambda (ranges)
                    (setq plan-count (1+ plan-count))
                    (let ((plan (funcall plan-function ranges)))
                      (setq discovered-domains
                            (proofread--selection-plan-domains plan))
                      plan)))
                 ((symbol-function
                   'proofread--request-spans-for-islands)
                  (lambda (islands)
                    (setq span-count (1+ span-count))
                    (funcall span-function islands)))
                 ((symbol-function
                   'proofread--make-request-ready-chunk)
                  (lambda (beg end &optional language)
                    (setq chunk-count (1+ chunk-count))
                    (funcall chunk-function beg end language)))
                 ((symbol-function
                   'proofread--request-ready-chunks-for-request-spans)
                  (lambda (request-spans &optional language)
                    (setq materialize-count (1+ materialize-count))
                    (setq materialized-request-spans request-spans)
                    (funcall materialize-function
                             request-spans language)))
                 ((symbol-function 'proofread--current-profile)
                  (lambda ()
                    (setq profile-count (1+ profile-count))
                    (funcall profile-function)))
                 ((symbol-function 'proofread--check-selection-plan)
                  (lambda
                    (plan profile scope &optional force-feedback
                          request-spans)
                    (setq check-count (1+ check-count))
                    (setq selected-plan plan)
                    (setq selected-profile profile)
                    (setq selected-request-spans request-spans)
                    (funcall check-function
                             plan profile scope force-feedback
                             request-spans)))
                 ((symbol-function
                   'proofread--dispatch-profile-request-ready-chunks-result)
                  (lambda (chunks profile)
                    (setq dispatch-count (1+ dispatch-count))
                    (setq dispatched-chunks chunks)
                    (setq dispatched-profile profile)
                    '( :supported-count 1 :requests (request))))
                 ((symbol-function
                   'proofread--request-ready-chunks-for-islands)
                  (lambda (&rest _)
                    (ert-fail
                     "Point check rebuilt chunks from islands")))
                 ((symbol-function 'proofread--check-ranges)
                  (lambda (&rest _)
                    (ert-fail "Point check re-entered range checking"))))
              (proofread-check-at-point)))
          (should (= plan-count 1))
          (should (= span-count 1))
          (should (= materialize-count 1))
          (should (= chunk-count 1))
          (should (= profile-count 1))
          (should (= check-count 1))
          (should (= dispatch-count 1))
          (should (proofread--selection-plan-p selected-plan))
          (should (= (length selected-request-spans) 1))
          (should (eq materialized-request-spans
                      selected-request-spans))
          (should (eq dispatched-profile selected-profile))
          (let* ((range
                  (car (proofread--selection-plan-ranges
                        selected-plan)))
                 (domain
                  (car (proofread--selection-plan-domains
                        selected-plan)))
                 (island
                  (car (proofread--selection-plan-islands
                        selected-plan)))
                 (span (car selected-request-spans)))
            (should (= (length discovered-domains) 1))
            (should (eq domain (car discovered-domains)))
            (should (eq (plist-get span :owner-domain) domain))
            (should (= (cl-count :beg span) 1))
            (should (= (cl-count :end span) 1))
            (should (equal range
                           (cons (plist-get span :beg)
                                 (plist-get span :end))))
            (should (= (plist-get island :beg) (car range)))
            (should (= (plist-get island :end) (cdr range))))
          (let ((chunk (car dispatched-chunks)))
            (should (= (length dispatched-chunks) 1))
            (should (equal (plist-get chunk :text)
                           "Second sentence."))
            (should (equal (plist-get chunk :language) "en"))
            (should (string-match-p
                     "First" (plist-get chunk :context-before)))
            (should (string-match-p
                     "Third" (plist-get chunk :context-after)))
            (should-not (string-match-p
                         "Outside" (plist-get chunk :context-before)))
            (should-not (string-match-p
                         "Outside" (plist-get chunk :context-after))))
          (should (equal (buffer-string) before-text))
          (should (= (buffer-chars-modified-tick) before-tick))
          (should (= (point) before-point))
          (should (= (mark t) before-mark))
          (should (eq mark-active before-mark-active))
          (should (= (point-min) before-min))
          (should (= (point-max) before-max)))))))

(ert-deftest
    proofread-test-check-at-point-rejects-before-forced-retirement ()
  "Reject an invalid point before retiring pending automatic work."
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
      (let ((proofread-ignored-properties '( proofread-test-ignore))
            (proofread--pending-work 'pending-token)
            (proofread--idle-timer 'timer-token)
            (cancel-count 0)
            (profile-count 0))
        (cl-letf
            (((symbol-function 'proofread--cancel-idle-timer)
              (lambda ()
                (setq cancel-count (1+ cancel-count))
                (setq proofread--idle-timer nil)))
             ((symbol-function 'proofread--current-profile)
              (lambda ()
                (setq profile-count (1+ profile-count))
                nil)))
          (should-error (proofread-check-at-point t)
                        :type 'user-error))
        (should (= cancel-count 0))
        (should (= profile-count 0))
        (should (eq proofread--pending-work 'pending-token))
        (should (eq proofread--idle-timer 'timer-token))))))

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
    (should-not (proofread--request-ready-range-at-point)))
  (with-temp-buffer
    (insert "Alpha user@example.com Beta")
    (goto-char (point-min))
    (search-forward "user@example.com")
    (goto-char (+ (match-beginning 0) 2))
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (should-not (proofread--request-ready-range-at-point))))

(ert-deftest proofread-test-check-at-point-programming-delimiters ()
  "Select comment and docstring prose from their opening delimiters."
  (dolist
      (case
       '((";; Comment delimiter prose.\n"
          comment "Comment delimiter prose" ";;")
         ("(defun sample ()\n  \"Docstring delimiter prose.\")\n"
          docstring "Docstring delimiter prose" "\"Docstring")))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert (nth 0 case))
      (goto-char (point-min))
      (search-forward (nth 3 case))
      (goto-char (match-beginning 0))
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-context-size 0)
            (recorder (proofread-test--make-backend-recorder)))
        (proofread-test--with-profile
          (let ((proofread-test--backend-check-function
                 (plist-get recorder :function)))
            (proofread-check-at-point)
            (let* ((requests (funcall (plist-get recorder :requests)))
                   (request (car requests)))
              (should (= (length requests) 1))
              (should (eq (plist-get request :target-kind)
                          (nth 1 case)))
              (should (string-match-p
                       (nth 2 case) (plist-get request :text))))))))))

(ert-deftest proofread-test-check-at-point-rejects-empty-selections ()
  "Reject empty, whitespace-only, and zero-width selections."
  (dolist (text '("" " \t\n"))
    (with-temp-buffer
      (insert text)
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (should-error (proofread-check-at-point) :type 'user-error)))
  (with-temp-buffer
    (insert "Alpha prose.")
    (goto-char 4)
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (narrow-to-region (point) (point))
    (should-error (proofread-check-at-point) :type 'user-error)))

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
            (should (= (length timers) 2))
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
    (let* ((manual-work
            (proofread-test--lifecycle-request
             'manual-request 1 1))
           timer-count)
      (proofread--enqueue-requests (list manual-work))
      (let ((state proofread--queue-state)
            (manual-entry (proofread--request-queue-head)))
        (cl-letf (((symbol-function 'run-with-idle-timer)
                   (lambda (_seconds _repeat _function &rest _args)
                     (setq timer-count (1+ (or timer-count 0)))
                     'proofread-test-timer)))
          (insert "!")
          (should-not timer-count)
          (should-not proofread--pending-work)
          (should-not proofread--idle-timer)
          (should (eq proofread--queue-state state))
          (should
           (equal (proofread--request-queue-entries)
                  (list manual-entry)))
          (proofread-test--assert-queue-cache-index-consistent))))))

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
            (let ((manual-work
                   (proofread-test--lifecycle-request
                    'manual-request 1 1))
                  timer-count)
              (proofread--enqueue-requests (list manual-work))
              (let ((state proofread--queue-state)
                    (manual-entry (proofread--request-queue-head)))
                (cl-letf (((symbol-function 'run-with-idle-timer)
                           (lambda (_seconds _repeat _function &rest
                                             _args)
                             (setq timer-count (1+ (or timer-count 0)))
                             'proofread-test-timer)))
                  (proofread--window-scroll (selected-window)
                                            (point-min))
                  (run-hooks 'window-configuration-change-hook)
                  (should-not timer-count)
                  (should-not proofread--pending-work)
                  (should-not proofread--idle-timer)
                  (should (eq proofread--queue-state state))
                  (should
                   (equal (proofread--request-queue-entries)
                          (list manual-entry)))
                  (proofread-test--assert-queue-cache-index-consistent)))))
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
      (let ((proofread-test--backend-check-function
             (lambda (_request _callback)
               (setq backend-calls (1+ (or backend-calls 0))))))
        (cl-letf (((symbol-function 'run-with-idle-timer)
                   (lambda (_seconds _repeat _function &rest _args)
                     'proofread-test-timer)))
          (insert "!")
          (should proofread--pending-work)
          (should-not backend-calls))))))

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
                (let ((proofread-test--backend-check-function
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
              (run-hook-with-args 'window-scroll-functions
                                  (selected-window) (point-min))
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (switch-to-buffer plain-buffer)
              (run-hook-with-args 'window-scroll-functions
                                  (selected-window) (point-min))
              (with-current-buffer plain-buffer
                (should-not proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)
        (kill-buffer plain-buffer)))))

(ert-deftest proofread-test-window-activity-hooks-are-buffer-local ()
  "Install window activity hooks only in enabled buffers."
  (let ((first-buffer
         (generate-new-buffer " *proofread-window-hooks-first*"))
        (second-buffer
         (generate-new-buffer " *proofread-window-hooks-second*")))
    (unwind-protect
        (progn
          (dolist (buffer (list first-buffer second-buffer))
            (with-current-buffer buffer
              (setq-local proofread-auto-check nil)
              (proofread-mode 1)))
          (should-not
           (memq #'proofread--window-scroll
                 (default-value 'window-scroll-functions)))
          (should-not
           (memq #'proofread--mark-pending-work
                 (default-value
                  'window-configuration-change-hook)))
          (with-current-buffer first-buffer
            (should (local-variable-p 'window-scroll-functions))
            (should
             (local-variable-p
              'window-configuration-change-hook))
            (should (= (cl-count #'proofread--window-scroll
                                 window-scroll-functions)
                       1))
            (should
             (= (cl-count
                 #'proofread--mark-pending-work
                 window-configuration-change-hook)
                1))
            (proofread-mode 1)
            (should (= (cl-count #'proofread--window-scroll
                                 window-scroll-functions)
                       1))
            (should
             (= (cl-count
                 #'proofread--mark-pending-work
                 window-configuration-change-hook)
                1))
            (proofread-mode -1)
            (should-not
             (memq #'proofread--window-scroll
                   window-scroll-functions))
            (should-not
             (memq #'proofread--mark-pending-work
                   window-configuration-change-hook)))
          (with-current-buffer second-buffer
            (should
             (memq #'proofread--window-scroll
                   window-scroll-functions))
            (should
             (memq #'proofread--mark-pending-work
                   window-configuration-change-hook))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest
    proofread-test-window-activity-with-two-windows-schedules-once ()
  "Schedule one idle check when two windows show the same buffer."
  (save-window-excursion
    (let ((buffer
           (generate-new-buffer " *proofread-window-hooks-shared*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (proofread-mode 1)
            (let ((first-window (selected-window))
                  (second-window (split-window-right))
                  timer-count)
              (set-window-buffer second-window buffer)
              (setq proofread-auto-check t)
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (_seconds _repeat _function &rest
                                           _args)
                           (setq timer-count
                                 (1+ (or timer-count 0)))
                           'proofread-test-window-timer)))
                (with-selected-window first-window
                  (run-hook-with-args
                   'window-scroll-functions first-window
                   (window-start first-window)))
                (with-selected-window second-window
                  (run-hook-with-args
                   'window-scroll-functions second-window
                   (window-start second-window)))
                (should (= timer-count 1))
                (should proofread--pending-work))))
        (kill-buffer buffer)))))

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
              (run-hooks 'window-configuration-change-hook)
              (with-current-buffer proofread-buffer
                (should proofread--pending-work))
              (should (= timer-count 1))))
        (kill-buffer proofread-buffer)))))

(ert-deftest
    proofread-test-window-activity-does-not-enumerate-windows ()
  "Handle window activity without scanning windows or frames."
  (with-temp-buffer
    (insert "Alpha")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (setq proofread-auto-check t)
    (let (timer-count)
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (_seconds _repeat _function &rest _args)
                   (setq timer-count (1+ (or timer-count 0)))
                   'proofread-test-window-timer))
                ((symbol-function 'window-list)
                 (lambda (&rest _args)
                   (ert-fail "Window activity enumerated windows")))
                ((symbol-function 'frame-list)
                 (lambda ()
                   (ert-fail "Window activity enumerated frames"))))
        (proofread--window-scroll (selected-window) (point-min))
        ;; Exercise Proofread's installed callback without invoking
        ;; unrelated standard hooks loaded by Flymake.
        (proofread--mark-pending-work)
        (should (= timer-count 1))
        (should proofread--pending-work)))))

(ert-deftest proofread-test-unload-cleans-stale-local-window-hooks ()
  "Unload local hooks from normal and stale registered buffers."
  (let* ((first-buffer
          (generate-new-buffer
           " *proofread-window-hooks-stale-first*"))
         (second-buffer
          (generate-new-buffer
           " *proofread-window-hooks-stale-second*"))
         (buffers (list first-buffer second-buffer))
         (proofread--mode-buffers nil)
         (proofread--request-log-sources nil)
         (report-calls (make-hash-table :test #'eq))
         (proofread-request-log-hook
          (copy-sequence proofread-request-log-hook)))
    (unwind-protect
        (progn
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (insert "Alpha")
              (setq-local proofread-auto-check nil)
              (setq-local flymake-diagnostic-functions
                          (list
                           #'proofread-test--flymake-foreign-backend))
              (proofread-mode 1)
              (should
               (memq #'proofread--window-scroll
                     window-scroll-functions))
              (let ((source buffer)
                    (report-function
                     proofread--flymake-report-function))
                (setq proofread--flymake-report-function
                      (lambda (&rest arguments)
                        (puthash
                         source
                         (cons arguments (gethash source report-calls))
                         report-calls)
                        (apply report-function arguments))))
              ;; Simulate an interrupted teardown that left the
              ;; buffer registered after the mode variable changed.
              (when (eq buffer second-buffer)
                (setq proofread-mode nil))))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame) buffers))
                    ((symbol-function 'remove-variable-watcher)
                     (lambda (&rest _arguments)
                       (ert-fail
                        "Proofread unload removed a variable watcher"))))
            (proofread-unload-function))
          (dolist (buffer buffers)
            (with-current-buffer buffer
              (should-not proofread-mode)
              (should flymake-mode)
              (should
               (equal (gethash buffer report-calls)
                      '((nil :region (1 . 6)))))
              (should-not proofread--flymake-report-function)
              (should-not
               (memq #'proofread--flymake-backend
                     flymake-diagnostic-functions))
              (should
               (memq #'proofread-test--flymake-foreign-backend
                     flymake-diagnostic-functions))
              (should-not
               (memq #'proofread--flymake-mode-changed
                     flymake-mode-hook))
              (should-not
               (memq #'proofread--window-scroll
                     window-scroll-functions))
              (should-not
               (memq #'proofread--mark-pending-work
                     window-configuration-change-hook)))
            (should-not (memq buffer proofread--mode-buffers))))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

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
                        after-change-functions))
      (should-not (memq #'proofread--window-scroll
                        window-scroll-functions))
      (should-not
       (memq #'proofread--mark-pending-work
             window-configuration-change-hook)))))

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
    (should-not (memq buffer proofread--mode-buffers))
    (should-not (proofread--idle-timer-run buffer))))

;;;; Chunk and context tests

(ert-deftest
    proofread-test-sentence-spans-handle-whitespace-and-edges ()
  "Split sentences across separators and buffer boundaries."
  (with-temp-buffer
    (should-not
     (proofread--sentence-spans-in-paragraph
      (cons (point-min) (point-max))))
    (insert "First.\t \r\nSecond")
    (let ((spans
           (proofread--sentence-spans-in-paragraph
            (cons (point-min) (point-max)))))
      (should (equal (proofread-test--span-texts spans)
                     '( "First." "Second")))
      (should (= (caar spans) (point-min)))
      (should (= (cdr (car (last spans))) (point-max))))))

(ert-deftest proofread-test-context-selected-spans-clamps-count ()
  "Select no after-context spans for non-positive counts."
  (let ((spans '((1 . 2) (2 . 3) (3 . 4))))
    (should-not
     (proofread--context-selected-spans spans 'after -1))
    (should-not
     (proofread--context-selected-spans spans 'after 0))
    (should
     (equal (proofread--context-selected-spans spans 'after 2)
            '((1 . 2) (2 . 3))))
    (should
     (equal (proofread--context-selected-spans spans 'after 4)
            spans))))

(ert-deftest proofread-test-context-search-beg-handles-buffer-edges
    ()
  "Find context boundaries in empty and unterminated buffers."
  (with-temp-buffer
    (let ((proofread-context-size 100))
      (should (= (proofread--context-search-beg (point-min))
                 (point-min)))
      (insert "Context.\n\nTarget")
      (let ((target-beg (save-excursion
                          (goto-char (point-min))
                          (search-forward "Target")
                          (match-beginning 0))))
        (should (= (proofread--context-search-beg target-beg)
                   target-beg))
        (should (= (point-max) (+ target-beg (length "Target")))))
      (erase-buffer)
      (insert "   \nTarget")
      (put-text-property 1 3 'field 'first)
      (put-text-property 3 4 'field 'second)
      (should (= (proofread--context-search-beg 5) 4)))))

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
        (should-not (proofread-test--flymake-proofread-diagnostics))
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
        (should-not (proofread-test--flymake-proofread-diagnostics))
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

(ert-deftest proofread-test-org-structural-lines-use-element-api ()
  "Recognize Org structural lines using Org's element model."
  (with-temp-buffer
    (org-mode)
    (let ((lines
           '( (t "* Heading")
              (t "SCHEDULED: <2026-07-20 Mon>")
              (t ":PROPERTIES:")
              (t ":CUSTOM_ID: example")
              (t ":END:")
              (skip "")
              (t "#+TITLE: Title")
              (t "#+CAPTION: Caption")
              (nil "Captioned paragraph.")
              (skip "")
              (t "-----")
              (skip "")
              (t "| First | Second |")
              (t "|-------+--------|")
              (skip "")
              (t "- First item")
              (nil "  continuation")
              (t "+ Second item")
              (skip "")
              (t ":NOTES:")
              (t "Drawer prose.")
              (t "- Drawer item")
              (t ":END:")
              (skip "")
              (t "#+begin_quote")
              (t "Quote prose.")
              (t "#+begin_example")
              (t "Nested example.")
              (t "#+end_example")
              (t "#+end_quote")
              (skip "")
              (nil "Plain paragraph."))))
      (dolist (entry lines)
        (insert (cadr entry) "\n"))
      (goto-char (point-min))
      (string-match "\\(match\\)" "match")
      (let ((saved-match-data (match-data)))
        (should (proofread--org-structural-line-p))
        (should (equal (match-data) saved-match-data)))
      (dolist (entry lines)
        (unless (eq (car entry) 'skip)
          (should
           (eq (and (proofread--org-structural-line-p) t)
               (car entry))))
        (forward-line 1))))
  (with-temp-buffer
    (text-mode)
    (insert "* Org-looking text\n")
    (goto-char (point-min))
    (should-not (proofread--org-structural-line-p))
    (should-not (proofread--context-stop-line-at-point-p))))

(ert-deftest proofread-test-org-structural-lines-respect-narrowing ()
  "Recognize an Org block whose delimiters are outside the restriction."
  (with-temp-buffer
    (org-mode)
    (insert "Outside before.\n")
    (insert "#+begin_quote\n")
    (let ((content-beg (point)))
      (insert "Inside target.")
      (let ((content-end (point)))
        (insert "\n#+end_quote\nOutside after.")
        (goto-char content-beg)
        (should (proofread--org-structural-line-p))
        (narrow-to-region content-beg content-end)
        (goto-char (point-min))
        (let ((beg (point-min))
              (end (point-max))
              (position (point)))
          (should (proofread--org-structural-line-p))
          (should (= (point-min) beg))
          (should (= (point-max) end))
          (should (= (point) position))
          (let* ((proofread-context-size 300)
                 (chunks
                  (proofread-test--request-ready-chunks-for-ranges
                   (list (cons beg end))))
                 (chunk (proofread-test--chunk-with-text
                         chunks "Inside target.")))
            (should chunk)
            (should (equal (plist-get chunk :context-before) ""))
            (should (equal (plist-get chunk :context-after) ""))))))))

(ert-deftest
    proofread-test-request-ready-context-stops-at-org-structure ()
  "Org structural lines stop request-ready sentence context search."
  (dolist
      (text
       '( "前文。\n* 标题\n目标句。"
          "前文。\n* 标题\nSCHEDULED: <2026-07-20 Mon>\n目标句。"
          "前文。\n#+TITLE: 标题\n目标句。"
          "前文。\n-----\n目标句。"
          "前文。\n:PROPERTIES:\n\
:CUSTOM_ID: x\n:END:\n目标句。"
          "前文。\n:NOTES:\n抽屉内容。\n:END:\n目标句。"
          "前文。\n- 项目\n目标句。"
          "前文。\n| 表格 |\n目标句。"
          "前文。\n#+begin_quote\n引用。\n\
#+begin_example\n嵌套块。\n#+end_example\n\
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

(ert-deftest
    proofread-test-result-paths-add-request-provenance-once ()
  "Annotate network, partial, and cached diagnostics exactly once."
  (let (path-counts)
    (dolist (path '( network partial cache))
      (with-temp-buffer
        (insert "helo")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 10))
          (proofread-mode 1)
          (proofread-test--with-profile
            (let* ((chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 5)))))
                   (work
                    (proofread--make-request-work
                     (proofread-test--make-profile-request chunk)))
                   (request (proofread-test--work-request work))
                   (diagnostic
                    (proofread-test--diagnostic-for-range 1 5 "helo"))
                   (entry
                    (when (eq path 'cache)
                      (proofread--make-cache-entry
                       request (list diagnostic))))
                   (original
                    (symbol-function
                     'proofread--diagnostics-with-request-provenance))
                   (provenance-calls 0))
              (cl-letf
                  (((symbol-function
                     'proofread--diagnostics-with-request-provenance)
                    (lambda (candidate-request diagnostics)
                      (setq provenance-calls (1+ provenance-calls))
                      (funcall original candidate-request diagnostics))))
                (should
                 (eq
                  (pcase path
                    ('network
                     (proofread--handle-backend-result
                      work
                      (proofread--backend-success-result
                       request (list diagnostic))))
                    ('partial
                     (proofread--handle-backend-result
                      work
                      (proofread--backend-partial-success-result
                       request (list diagnostic))))
                    ('cache
                     (proofread--apply-cache-entry work entry)))
                  'applied)))
              (push (cons path provenance-calls) path-counts))))))
    (should
     (equal (nreverse path-counts)
            '((network . 1) (partial . 1) (cache . 1))))))

(ert-deftest
    proofread-test-cache-snapshots-backend-diagnostics-before-hooks ()
  "Snapshot backend diagnostics before diagnostic hooks can mutate them."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((1 . 5)))))
               (work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (request (proofread-test--work-request work))
               (diagnostic
                (proofread-test--diagnostic-for-range 1 5 "helo")))
          (setq-local
           proofread-diagnostics-changed-hook
           (list
            (lambda ()
              (setf (plist-get diagnostic :message)
                    "mutated after apply"))))
          (should
           (eq
            (proofread--handle-backend-result
             work
             (proofread--backend-success-result
              request (list diagnostic)))
            'applied))
          (should
           (equal (plist-get diagnostic :message)
                  "mutated after apply"))
          (should
           (equal
            (plist-get
             (car
              (plist-get
               (proofread--cache-read-request work)
               :diagnostics))
             :message)
            "Possible misspelling")))))))

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
                (let ((proofread-test--backend-check-function
                       (lambda (backend-request backend-callback)
                         (setq backend-calls
                               (1+ (or backend-calls 0)))
                         (setq request backend-request)
                         (setq callback backend-callback)
                         'proofread-test-handle)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update) 5)))
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
                      (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
                      (proofread-clear)
                      (setq proofread--diagnostics nil)
                      (proofread-check-visible-range)
                      (should (= backend-calls 1))
                      (should
                       (equal
                        (proofread-test--diagnostics-without-provenance
                         proofread--diagnostics)
                        (list diagnostic)))
                      (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))))))))
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
             (profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     work
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should (= (length proofread--diagnostics) 1))
        (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
        (should (eq (proofread--handle-backend-result
                     work
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list diagnostic)))
        (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
        (should (eq (proofread--handle-backend-result
                     work
                     (proofread--backend-success-result request nil))
                    'applied))
        (should-not proofread--diagnostics)
        (should-not (proofread-test--flymake-proofread-diagnostics))))))

(ert-deftest proofread-test-result-handler-shares-continuable-decision
    ()
  "Compute one continuable decision for every valid result status."
  (dolist (case
           '((ok t applied 1)
             (ok nil stale 0)
             (error t error 0)
             (error nil stale 0)))
    (pcase-let
        ((`(,result-status ,continuable ,expected-status
                           ,expected-diagnostic-count)
          case))
      (with-temp-buffer
        (insert "helo")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 0)
              final-events
              (continuable-calls 0)
              (report-calls 0))
          (proofread-mode 1)
          (proofread-test--with-profile
            (let* ((chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 5)))))
                   (work
                    (proofread--make-request-work
                     (proofread-test--make-profile-request chunk)))
                   (request (proofread-test--work-request work))
                   (diagnostic
                    (proofread-test--diagnostic-for-range
                     1 5 "helo"))
                   (result
                    (pcase result-status
                      ('ok
                       (proofread--backend-success-result
                        request (list diagnostic)))
                      ('error
                       (proofread--backend-error-result
                        request 'proofread-test-backend-failure
                        "Test backend failure"))))
                   (proofread-request-log-hook
                    (list
                     (lambda (event)
                       (when (eq (plist-get event :type)
                                 'final-result)
                         (push event final-events))))))
              (cl-letf
                  (((symbol-function
                     'proofread--request-continuable-p)
                    (lambda (candidate)
                      (should (eq candidate work))
                      (setq continuable-calls
                            (1+ continuable-calls))
                      continuable))
                   ((symbol-function 'proofread--fresh-request-p)
                    (lambda (_candidate)
                      (ert-fail
                       "Result handler bypassed continuable predicate")))
                   ((symbol-function 'proofread--latest-request-p)
                    (lambda (_candidate)
                      (ert-fail
                       "Result handler bypassed continuable predicate")))
                   ((symbol-function 'proofread--report-backend-error)
                    (lambda (_result)
                      (setq report-calls (1+ report-calls)))))
                (should
                 (eq (proofread--handle-backend-result work result)
                     expected-status)))
              (should (= continuable-calls 1))
              (should
               (= report-calls
                  (if (and (eq result-status 'error)
                           continuable)
                      1
                    0)))
              (should
               (= (length proofread--diagnostics)
                  expected-diagnostic-count))
              (should (= (length final-events) 1))
              (should (eq (plist-get (car final-events) :status)
                          expected-status))
              (should
               (eq (plist-get
                    (plist-get (car final-events) :result)
                    :status)
                   result-status)))))))))

(ert-deftest
    proofread-test-malformed-result-skips-continuable-predicates ()
  "Do not run freshness or user predicates for a malformed status."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(setq proofread-test-value \"Custom prose.\")\n")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          (proofread-targets 'docstrings)
          final-events
          (continuable-calls 0)
          (freshness-calls 0)
          (user-predicate-calls 0))
      (setq-local
       proofread-docstring-predicate-functions
       (list
        (lambda (_beg _end)
          (setq user-predicate-calls
                (1+ user-predicate-calls))
          t)))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
               (work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (request (proofread-test--work-request work))
               (result
                (list :status 'malformed :request request))
               (original-continuable
                (symbol-function 'proofread--request-continuable-p))
               (original-fresh
                (symbol-function 'proofread--fresh-request-p))
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'final-result)
                     (push event final-events))))))
          (should chunk)
          (should (> user-predicate-calls 0))
          (setq user-predicate-calls 0)
          (cl-letf
              (((symbol-function 'proofread--request-continuable-p)
                (lambda (candidate)
                  (setq continuable-calls
                        (1+ continuable-calls))
                  (funcall original-continuable candidate)))
               ((symbol-function 'proofread--fresh-request-p)
                (lambda (candidate)
                  (setq freshness-calls (1+ freshness-calls))
                  (funcall original-fresh candidate))))
            (should (eq (proofread--handle-backend-result
                         work result)
                        'error)))
          (should (zerop continuable-calls))
          (should (zerop freshness-calls))
          (should (zerop user-predicate-calls))
          (should (= (length final-events) 1))
          (should (eq (plist-get (car final-events) :status)
                      'error))
          (should
           (eq (plist-get
                (plist-get (car final-events) :result) :status)
               'malformed)))))))

(ert-deftest
    proofread-test-result-continuable-predicate-rechecks-after-reentry
    ()
  "Recheck latest ownership after freshness publishes newer work."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          final-events
          (freshness-calls 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((1 . 5)))))
               (old-work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (new-work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (old-request (proofread-test--work-request old-work))
               (diagnostic
                (proofread-test--diagnostic-for-range 1 5 "helo"))
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (and
                          (eq (plist-get event :type) 'final-result)
                          (equal
                           (plist-get event :log-id)
                           (proofread--scheduled-work-log-id old-work)))
                     (push event final-events))))))
          (proofread--register-active-request old-work)
          (cl-letf
              (((symbol-function 'proofread--fresh-request-p)
                (lambda (candidate)
                  (should (eq candidate old-work))
                  (setq freshness-calls (1+ freshness-calls))
                  (unless (proofread--request-state-flag-p
                           old-work :superseded)
                    (let ((superseded
                           (proofread--supersede-conflicting-requests
                            (list new-work))))
                      (should
                       (equal (plist-get superseded :active)
                              (list old-work)))
                      (proofread--enqueue-requests (list new-work))))
                  t)))
            (should
             (eq (proofread--handle-backend-result
                  old-work
                  (proofread--backend-success-result
                   old-request (list diagnostic)))
                 'stale)))
          (should (= freshness-calls 1))
          (should (proofread--request-state-flag-p
                   old-work :superseded))
          (should-not proofread--diagnostics)
          (should-not (proofread-test--flymake-proofread-diagnostics))
          (should (= (length final-events) 1))
          (should (eq (plist-get (car final-events) :status)
                      'stale))
          (should (eq (proofread--request-work-pending-p new-work)
                      new-work))
          (proofread--clear-scheduled-work))))))

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
             (profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
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
             (changed 0))
        (should (eq (proofread--handle-backend-result
                     work
                     (proofread--backend-success-result request (list old)))
                    'applied))
        (proofread-clear-cache)
        (add-hook 'proofread-diagnostics-changed-hook
                  (lambda () (setq changed (1+ changed))) nil t)
        (should (eq (proofread--handle-backend-result work partial)
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list old later-range earlier-range)))
        (should
         (= (length (proofread-test--flymake-proofread-diagnostics)) 3))
        (should (= changed 1))
        (should (= (hash-table-count proofread--cache) 0))
        (should (eq (proofread--handle-backend-result work partial)
                    'applied))
        (should
         (equal (proofread-test--diagnostics-without-provenance
                 proofread--diagnostics)
                (list old later-range earlier-range)))
        (should
         (= (length (proofread-test--flymake-proofread-diagnostics)) 3))
        (should (= changed 1))))))

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
                (let ((proofread-test--backend-check-function
                       (plist-get recorder :function)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
                    (proofread-check-visible-range)
                    (should (= (length (funcall
                                        (plist-get recorder :requests)))
                               1))
                    (should (equal (plist-get
                                    (car (funcall
                                          (plist-get recorder
                                                     :requests)))
                                    :text)
                                   "helo")))))))
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
                       (profile (proofread--current-profile))
                       (checker
                        (proofread-test--current-profile-checker
                         profile))
                       (cached-work
                        (proofread-test--make-request-work
                         (car chunks) proofread-test--backend checker
                         profile))
                       (cached-diagnostic
                        (proofread-test--diagnostic-with-kind
                         1 6 "Alpha" 'spelling)))
                  (proofread--cache-write-request
                   cached-work (list cached-diagnostic))
                  (let ((proofread-test--backend-check-function
                         (plist-get recorder :function)))
                    (cl-letf (((symbol-function 'window-start)
                               (lambda (&optional _window) (point-min)))
                              ((symbol-function 'window-end)
                               (lambda (&optional _window _update)
                                 (point-max))))
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
                      (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))))))))
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
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 6 "Alpha")))
      (proofread--cache-write-request work (list diagnostic))
      (let ((proofread-test--backend-identity-token "identity-b"))
        (should-not (proofread--cache-read-request
                     (proofread-test--make-request-work
                      chunk proofread-test--backend))))
      (let ((changed-chunk (plist-put (copy-sequence chunk)
                                      :text "Beta")))
        (should-not
         (proofread--cache-read-request
          (proofread-test--make-request-work
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
             (profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo")))
        (insert "!")
        (should (eq (proofread--handle-backend-result
                     work
                     (proofread--backend-success-result
                      request (list diagnostic)))
                    'stale))
        (should (= (hash-table-count proofread--cache) 0))
        (let* ((fresh-work
                (proofread-test--make-request-work
                 (car
                  (proofread-test--request-ready-chunks-for-ranges
                   (list (cons (point-min) (point-max)))))
                 proofread-test--backend checker profile))
               (fresh-request
                (proofread-test--work-request fresh-work)))
          (should (eq (proofread--handle-backend-result
                       fresh-work
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
           (work (proofread-test--make-request-work chunk))
           (request (proofread-test--work-request work))
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (entry (proofread--make-cache-entry request (list
                                                        diagnostic))))
      (delete-region 1 5)
      (insert "hello")
      (should (eq (proofread--apply-cache-entry work entry)
                  'stale))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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

(ert-deftest proofread-test-removed-options-retain-obsolete-metadata ()
  "Retain compiler-facing migration metadata for removed options."
  (dolist (case
           '((proofread-backend
              "0.2.0" "proofread-profiles" "proofread-profile")
             (proofread-language "0.2.0" ":language")
             (proofread-echo-area-messages
              "0.3.0" "eldoc-mode" "Flymake")))
    (let* ((variable (car case))
           (expected-version (cadr case))
           (required-fragments (cddr case))
           (metadata (get variable 'byte-obsolete-variable)))
      (should-not (boundp variable))
      (should-not (custom-variable-p variable))
      (should (= (length metadata) 3))
      (let ((replacement (car metadata))
            (access-type (cadr metadata))
            (version (caddr metadata)))
        (should (stringp replacement))
        (dolist (fragment required-fragments)
          (should (string-match-p (regexp-quote fragment)
                                  replacement)))
        (should-not access-type)
        (should (equal version expected-version))))))

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

(ert-deftest proofread-test-profile-normalization-keeps-raw-options ()
  "Leave opaque checker options untouched during core normalization."
  (let* ((provider
          (record 'proofread-test-provider 'opaque-identity))
         (mutable-value (list "initial"))
         (options (list :provider provider
                        :mutable-value mutable-value))
         (proofread-profile 'raw-options)
         (proofread-profiles
          (list
           (list
            'raw-options
            :checkers
            (list
             (list :name 'only
                   :backend proofread-test--backend
                   :options options)))))
         (checker
          (car (plist-get (proofread--current-profile) :checkers))))
    (should (eq (plist-get checker :options) options))
    (should (eq (plist-get (plist-get checker :options) :provider)
                provider))
    (should (eq (plist-get (plist-get checker :options)
                           :mutable-value)
                mutable-value))))

(ert-deftest proofread-test-fake-backend-snapshots-owned-options ()
  "Detach fake backend collections while preserving opaque identities."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((provider
            (record 'proofread-test-provider 'opaque-identity))
           (position (copy-marker (point-min)))
           (name (copy-sequence "formal"))
           (vector-value (vector (list "nested")))
           (table-value (make-hash-table :test #'equal))
           (table-key (list "key"))
           (table-list (list "table"))
           (options
            (list :provider provider
                  :position position
                  :name name
                  :vector vector-value
                  :table table-value)))
      (puthash table-key table-list table-value)
      (let* ((checker
              (list :profile 'multi
                    :name 'only
                    :backend proofread-test--backend
                    :options options))
             (snapshot-checker
              (proofread--checker-with-options-snapshot checker))
             (snapshot (plist-get snapshot-checker :options)))
        (should-not (eq snapshot options))
        (should (eq (plist-get snapshot :provider) provider))
        (should (eq (plist-get snapshot :position) position))
        (should-not (eq (plist-get snapshot :name) name))
        (should-not (eq (plist-get snapshot :vector) vector-value))
        (should-not (eq (aref (plist-get snapshot :vector) 0)
                        (aref vector-value 0)))
        (should-not (eq (plist-get snapshot :table) table-value))
        (let ((table-snapshot (plist-get snapshot :table)))
          (should
           (proofread-test--hash-option-snapshot-p table-snapshot))
          (should
           (eq (proofread-test--hash-option-snapshot-test
                table-snapshot)
               'equal))
          (should
           (equal (proofread-test--hash-option-snapshot-entries
                   table-snapshot)
                  '(( ("key") ("table"))))))
        (should
         (equal
          snapshot
          (plist-get
           (proofread--checker-with-options-snapshot checker)
           :options)))
        (setcar (aref vector-value 0) "changed")
        (setcar table-list "changed")
        (aset name 0 ?X)
        (should
         (equal (plist-get snapshot :name) "formal"))
        (should
         (equal (aref (plist-get snapshot :vector) 0)
                '( "nested")))
        (should
         (equal
          (proofread-test--hash-option-snapshot-entries
           (plist-get snapshot :table))
          '(( ("key") ("table")))))))))

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

(ert-deftest proofread-test-buffer-local-nil-profile-disables-dispatch
    ()
  "Let one buffer disable dispatch with a buffer-local nil profile."
  (let ((proofread-profile 'english)
        (proofread-profiles
         `((english
            :language "en-US"
            :checkers (( :name primary
                         :backend ,proofread-test--backend)))))
        (backend-calls 0))
    (with-temp-buffer
      (insert "Alpha")
      (setq-local proofread-profile nil)
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-test--backend-check-function
             (lambda (_request _callback)
               (setq backend-calls (1+ backend-calls))
               'proofread-test-handle)))
        (should
         (equal (proofread--current-profile)
                '( :name nil
                   :language nil
                   :display-language nil
                   :checkers nil)))
        (proofread-check-buffer))
      (should (zerop backend-calls))
      (should-not proofread--active-requests))))

(ert-deftest proofread-test-buffer-local-empty-profile-disables-dispatch
    ()
  "Let one buffer select an explicitly disabled profile."
  (let ((proofread-profile 'enabled)
        (proofread-profiles
         `((enabled
            :checkers (( :name primary
                         :backend ,proofread-test--backend)))
           (disabled
            :checkers nil)))
        (backend-calls 0))
    (with-temp-buffer
      (insert "Alpha")
      (setq-local proofread-profile 'disabled)
      (setq-local proofread-auto-check nil)
      (proofread-mode 1)
      (let ((proofread-test--backend-check-function
             (lambda (_request _callback)
               (setq backend-calls (1+ backend-calls))
               'proofread-test-handle)))
        (let ((profile (proofread--current-profile)))
          (should (eq (plist-get profile :name) 'disabled))
          (should-not (plist-get profile :checkers))
          (should
           (zerop
            (plist-get
             (proofread--dispatch-profile-request-ready-chunks-result
              nil profile)
             :supported-count))))
        (proofread-check-buffer))
      (should (zerop backend-calls))
      (should-not proofread--active-requests))))

(ert-deftest proofread-test-profile-named-legacy-is-ordinary-profile ()
  "Treat `legacy' as an ordinary explicit profile and checker name."
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
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (let ((proofread-test--backend-check-function
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
          (should
           (equal (plist-get request :checker-owner)
                  '( :profile legacy :checker-name legacy))))))))

(ert-deftest proofread-test-profile-and-ad-hoc-ownership-are-distinct
    ()
  "Keep explicit profile and ad-hoc request ownership distinct."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-profile 'ad-hoc)
          (proofread-profiles
           `((ad-hoc
              :language "en-US"
              :checkers (( :name ad-hoc
                           :backend ,proofread-test--backend)))))
          (proofread-auto-check nil)
          (proofread-context-size 0))
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))) "en-US")))
             (profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (profile-work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (ad-hoc-work
              (proofread-test--make-request-work
               chunk proofread-test--backend))
             (profile-request
              (proofread-test--work-request profile-work))
             (ad-hoc-request
              (proofread-test--work-request ad-hoc-work)))
        (should
         (equal (plist-get profile-request :checker-owner)
                '( :profile ad-hoc :checker-name ad-hoc)))
        (should
         (equal (plist-get ad-hoc-request :checker-owner)
                '( :profile ad-hoc :checker-name ad-hoc :ad-hoc t)))
        (dolist (key '( :checker-owner :checker-identity))
          (should-not
           (equal (plist-get profile-request key)
                  (plist-get ad-hoc-request key))))
        (should-not
         (equal (proofread--scheduled-work-cache-key profile-work)
                (proofread--scheduled-work-cache-key ad-hoc-work)))
        (should
         (zerop
          (hash-table-count
           (proofread--conflicting-request-table
            (list profile-work) (list ad-hoc-work)))))
        (should
         (zerop
          (hash-table-count
           (proofread--conflicting-request-table
            (list ad-hoc-work) (list profile-work)))))
        (should (proofread--fresh-request-p profile-work))
        (should (proofread--fresh-request-p ad-hoc-work))
        (let ((proofread-profile nil))
          (should-not (proofread--fresh-request-p profile-work))
          (should (proofread--fresh-request-p ad-hoc-work)))))))

(ert-deftest proofread-test-invalid-profile-never-falls-back
    ()
  "Reject missing and malformed profiles without dispatching."
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
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-profile (car case))
            (proofread-profiles (cadr case))
            (proofread-auto-check nil)
            (backend-calls 0))
        (proofread-mode 1)
        (let ((proofread-test--backend-check-function
               (lambda (_request _callback)
                 (setq backend-calls (1+ backend-calls))
                 'proofread-test-handle)))
          (should-error (proofread-check-buffer)))
        (should (zerop backend-calls))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
        (should
         (zerop
          (hash-table-count proofread--pending-request-keys)))))))

(ert-deftest proofread-test-nil-profile-disables-dispatch ()
  "Ignore removed options when no proofreading profile is selected."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-profile nil)
          (proofread-auto-check nil)
          (backend-calls 0)
          (removed-options
           (list (intern (concat "proofread-" "backend"))
                 (intern (concat "proofread-" "language")))))
      (proofread-mode 1)
      (let ((proofread-test--backend-check-function
             (lambda (_request _callback)
               (setq backend-calls (1+ backend-calls))
               'proofread-test-handle)))
        (should
         (equal (proofread--current-profile)
                '( :name nil
                   :language nil
                   :display-language nil
                   :checkers nil)))
        (cl-progv removed-options
            (list proofread-test--backend "en-US")
          (proofread-check-buffer)))
      (should (zerop backend-calls))
      (should-not proofread--active-requests))))

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
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-profile 'multi)
          (proofread-profiles
           `((multi
              :checkers
              (( :name unavailable
                 :backend proofread-test-unavailable)
               ( :name available
                 :backend ,proofread-test--backend)))))
          (recorder (proofread-test--make-backend-recorder)))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checkers (plist-get profile :checkers))
             (chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (proofread-test--backend-check-function
              (plist-get recorder :function))
             (result
              (proofread--dispatch-profile-request-ready-chunks-result
               chunks profile))
             (requests (plist-get result :requests)))
        (should
         (equal (mapcar (lambda (checker)
                          (plist-get checker :checker-ordinal))
                        checkers)
                '( 0 1)))
        (should (= (plist-get result :supported-count) 1))
        (should (= (length requests) 1))
        (should (eq (plist-get (car requests) :checker-name)
                    'available))
        (should (= (plist-get (car requests) :checker-ordinal) 1)))))
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
      (let ((proofread-test--backend-check-function
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

(ert-deftest
    proofread-test-profile-publishes-checker-batches-and-drains-once ()
  "Publish checker-major work with one drain and checker-local batches."
  (with-temp-buffer
    (insert "First. Second.")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 0)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles))
          (original-dispatch
           (symbol-function 'proofread--dispatch-queued-requests))
          (dispatch-count 0))
      (proofread-mode 1)
      (let ((chunks
             (mapcar
              (lambda (range)
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list range))))
              '((1 . 7) (8 . 15)))))
        (should (cl-every #'identity chunks))
        (cl-letf
            (((symbol-function 'proofread--dispatch-queued-requests)
              (lambda ()
                (setq dispatch-count (1+ dispatch-count))
                (funcall original-dispatch))))
          (let* ((result
                  (proofread--dispatch-profile-request-ready-chunks-result
                   chunks (proofread--current-profile)))
                 (works (proofread--request-queue-works))
                 (batches
                  (mapcar #'proofread--scheduled-work-batch works)))
            (should-not (plist-get result :requests))
            (should (= (plist-get result :supported-count) 2))
            (should-not (plist-get result :failures))
            (should (= dispatch-count 1))
            (should
             (equal
              (mapcar
               (lambda (work)
                 (plist-get (proofread-test--work-request work)
                            :checker-name))
               works)
              '(first first second second)))
            (should (= (length batches) 4))
            (should (cl-every #'identity batches))
            (should (eq (nth 0 batches) (nth 1 batches)))
            (should (eq (nth 2 batches) (nth 3 batches)))
            (should-not (eq (nth 0 batches) (nth 2 batches)))
            (should (= (plist-get (nth 0 batches) :pending) 2))
            (should (= (plist-get (nth 2 batches) :pending) 2))
            (proofread-test--assert-queue-cache-index-consistent)))))))

(ert-deftest
    proofread-test-profile-preparation-inhibits-reentrant-drain ()
  "Finish every checker preparation before a reentrant queue drain."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-preparation-reentry-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 0)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'first :backend backend
                     :options '( :name first))
               (list :name 'second :backend backend
                     :options '( :name second))))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (original-drain
            (symbol-function 'proofread--drain-request-queue))
           preparations
           drain-observations
           reentered)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (let ((name (plist-get options :name)))
           (unless (memq name preparations)
             (setq preparations (append preparations (list name))))
           (unless reentered
             (setq reentered t)
             (proofread--dispatch-queued-requests))
           (copy-sequence options))))
      (proofread-mode 1)
      (let ((chunk
             (car
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))))
        (cl-letf
            (((symbol-function 'proofread--drain-request-queue)
              (lambda ()
                (push (copy-sequence preparations)
                      drain-observations)
                (funcall original-drain))))
          (proofread--dispatch-profile-request-ready-chunks-result
           (list chunk) (proofread--current-profile))))
      (should reentered)
      (should (equal preparations '( first second)))
      (should (equal (nreverse drain-observations)
                     '(( first second))))
      (should (= (proofread--request-queue-length) 2))
      (should-not proofread--queue-dispatch-timer)
      (proofread-test--assert-queue-cache-index-consistent))))

(ert-deftest
    proofread-test-profile-preparation-edit-prevents-publication ()
  "Do not publish work prepared across a source-buffer edit."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-preparation-edit-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'first :backend backend
                     :options '( :edit t))
               (list :name 'second :backend backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           edited
           events)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (when (and (plist-get options :edit)
                    (not edited))
           (setq edited t)
           (goto-char (point-max))
           (insert "!"))
         (copy-sequence options)))
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 6)))))
             (proofread-request-log-hook
              (list (lambda (event)
                      (push (plist-get event :type) events))))
             (result
              (proofread--dispatch-profile-request-ready-chunks-result
               (list chunk) (proofread--current-profile))))
        (should edited)
        (should-not (plist-get result :requests))
        (should (= (plist-get result :supported-count) 2))
        (should-not (plist-get result :failures))
        (should-not (memq 'chunk-request events))
        (should-not (memq 'queued-request events))
        (should (proofread--request-queue-empty-p))
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest
    proofread-test-profile-preparation-buffer-kill-aborts-remaining-work ()
  "Stop profile preparation when an adapter kills its source buffer."
  (let ((buffer (generate-new-buffer " *proofread-killed-preparation*"))
        result
        raised
        (snapshot-calls 0))
    (unwind-protect
        (with-current-buffer buffer
          (insert "Alpha")
          (let* ((backend 'proofread-test-preparation-kill-backend)
                 (proofread-auto-check nil)
                 (proofread-context-size 0)
                 (proofread-profile 'multi)
                 (proofread-profiles
                  (list
                   (list
                    'multi
                    :checkers
                    (list
                     (list :name 'first :backend backend)
                     (list :name 'second :backend backend)))))
                 (proofread--backend-registry
                  (make-hash-table :test #'eq)))
            (proofread-register-backend
             backend
             :check #'ignore
             :identity
             (lambda ()
               (list :backend backend :contract-version 1))
             :snapshot-options
             (lambda (options)
               (setq snapshot-calls (1+ snapshot-calls))
               (kill-buffer buffer)
               (copy-sequence options)))
            (proofread-mode 1)
            (let ((chunk
                   (car
                    (proofread-test--request-ready-chunks-for-ranges
                     '((1 . 6))))))
              (condition-case err
                  (setq result
                        (proofread--dispatch-profile-request-ready-chunks-result
                         (list chunk) (proofread--current-profile)))
                (error
                 (setq raised err))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (should-not raised)
    (should (= snapshot-calls 1))
    (should-not (buffer-live-p buffer))
    (should
     (equal result
            '( :requests nil :supported-count 0 :failures nil)))))

(ert-deftest
    proofread-test-profile-checker-identity-kill-skips-source-label ()
  "Abort without a source-label call when checker identity kills its buffer."
  (let ((buffer
         (generate-new-buffer " *proofread-killed-by-identity*"))
        result
        raised
        (identity-calls 0)
        (source-label-calls 0))
    (unwind-protect
        (with-current-buffer buffer
          (insert "Alpha")
          (let* ((backend 'proofread-test-identity-kill-backend)
                 (proofread-auto-check nil)
                 (proofread-context-size 0)
                 (proofread-profile 'multi)
                 (proofread-profiles
                  (list
                   (list
                    'multi
                    :checkers
                    (list (list :name 'only :backend backend)))))
                 (proofread--backend-registry
                  (make-hash-table :test #'eq)))
            (proofread-register-backend
             backend
             :check #'ignore
             :identity
             (lambda ()
               (list :backend backend :contract-version 1))
             :snapshot-options #'copy-sequence
             :checker-identity
             (lambda (_checker)
               (setq identity-calls (1+ identity-calls))
               (kill-buffer buffer)
               (list :backend backend :contract-version 1))
             :source-label
             (lambda (_checker)
               (setq source-label-calls (1+ source-label-calls))
               "unreachable"))
            (proofread-mode 1)
            (let ((chunk
                   (car
                    (proofread-test--request-ready-chunks-for-ranges
                     '((1 . 6))))))
              (condition-case err
                  (setq result
                        (proofread--dispatch-profile-request-ready-chunks-result
                         (list chunk) (proofread--current-profile)))
                (error
                 (setq raised err))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (should-not raised)
    (should (= identity-calls 1))
    (should (zerop source-label-calls))
    (should-not (buffer-live-p buffer))
    (should
     (equal result
            '( :requests nil :supported-count 0 :failures nil)))))

(ert-deftest
    proofread-test-profile-active-transaction-keeps-request-list-contract
    ()
  "Return nil requests when an active queue transaction owns draining."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 2)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles)))
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 6)))))
             (transaction
              (make-symbol "proofread-active-transaction"))
             (proofread--queue-dispatch-active-p transaction)
             (proofread--queue-dispatch-transaction transaction)
             (proofread--queue-dispatch-requested-p nil)
             (result
              (proofread--dispatch-profile-request-ready-chunks-result
               (list chunk) (proofread--current-profile))))
        (should-not (plist-get result :requests))
        (should proofread--queue-dispatch-requested-p)
        (should (= (proofread--request-queue-length) 2))
        (should
         (equal
          (mapcar
           (lambda (work)
             (plist-get (proofread-test--work-request work)
                        :checker-name))
           (proofread--request-queue-works))
          '( first second)))
        (proofread-test--assert-queue-cache-index-consistent)
        (proofread--clear-request-work)
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest
    proofread-test-profile-root-drains-work-published-by-nested-prepare ()
  "Let the root profile transaction drain nested preparation work."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-nested-profile-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 2)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'first :backend backend)
               (list :name 'second :backend backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           reentered
           dispatch-chunks
           dispatch-profile
           nested-result
           submitted)
      (proofread-register-backend
       backend
       :check
       (lambda (request _callback)
         (push (plist-get request :checker-name) submitted)
         (list :backend backend
               :request-id (plist-get request :id)))
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (unless reentered
           (setq reentered t)
           (setq nested-result
                 (proofread--dispatch-profile-request-ready-chunks-result
                  dispatch-chunks dispatch-profile)))
         (copy-sequence options)))
      (proofread-mode 1)
      (setq dispatch-chunks
            (list
             (car
              (proofread-test--request-ready-chunks-for-ranges
               '((1 . 6))))))
      (setq dispatch-profile (proofread--current-profile))
      (let ((result
             (proofread--dispatch-profile-request-ready-chunks-result
              dispatch-chunks dispatch-profile)))
        (should reentered)
        (should-not (plist-get nested-result :requests))
        (should
         (equal
          (mapcar (lambda (request)
                    (plist-get request :checker-name))
                  (plist-get result :requests))
          '( first second)))
        (should (equal (nreverse submitted) '( first second)))
        (should (= (length proofread--active-requests) 2))
        (should (proofread--request-queue-empty-p))
        (should-not proofread--queue-dispatch-timer)
        (proofread--clear-request-work)))))

(ert-deftest
    proofread-test-profile-buffer-transactions-isolate-a-b-a-reentry ()
  "Keep each buffer's profile preparation transaction independent."
  (let ((buffer-a (generate-new-buffer " *proofread-profile-a*"))
        (buffer-b (generate-new-buffer " *proofread-profile-b*"))
        (backend-a 'proofread-test-profile-a-backend)
        (backend-b 'proofread-test-profile-b-backend)
        (proofread--backend-registry (make-hash-table :test #'eq))
        chunks-a
        chunks-b
        profile-a
        profile-b
        a-first-snapshot-count
        a-second-snapshot-count
        entered-b
        entered-nested-a
        outer-a-second-prepared-p
        outer-a-second-state
        nested-a-result
        b-result
        a-submissions
        b-submissions)
    (unwind-protect
        (progn
          (proofread-register-backend
           backend-a
           :check
           (lambda (request _callback)
             (push (cons (plist-get request :checker-name)
                         outer-a-second-prepared-p)
                   a-submissions)
             (list :backend backend-a
                   :request-id (plist-get request :id)))
           :identity
           (lambda ()
             (list :backend backend-a :contract-version 1))
           :snapshot-options
           (lambda (options)
             (pcase (plist-get options :name)
               ('first
                (setq a-first-snapshot-count
                      (1+ (or a-first-snapshot-count 0)))
                (when (= a-first-snapshot-count 1)
                  (setq entered-b t)
                  (with-current-buffer buffer-b
                    (setq b-result
                          (proofread--dispatch-profile-request-ready-chunks-result
                           chunks-b profile-b)))))
               ('second
                (setq a-second-snapshot-count
                      (1+ (or a-second-snapshot-count 0)))
                (when (= a-second-snapshot-count 2)
                  (setq outer-a-second-state
                        (list
                         :a-submissions
                         (copy-tree a-submissions)
                         :b-submissions
                         (copy-sequence b-submissions)
                         :a-queued
                         (mapcar
                          (lambda (work)
                            (plist-get
                             (proofread-test--work-request work)
                             :checker-name))
                          (proofread--request-queue-works))))
                  (setq outer-a-second-prepared-p t))))
             (copy-sequence options)))
          (proofread-register-backend
           backend-b
           :check
           (lambda (request _callback)
             (push (plist-get request :checker-name) b-submissions)
             (list :backend backend-b
                   :request-id (plist-get request :id)))
           :identity
           (lambda ()
             (list :backend backend-b :contract-version 1))
           :snapshot-options
           (lambda (options)
             (unless entered-nested-a
               (setq entered-nested-a t)
               (with-current-buffer buffer-a
                 (setq nested-a-result
                       (proofread--dispatch-profile-request-ready-chunks-result
                        chunks-a profile-a))))
             (copy-sequence options)))
          (with-current-buffer buffer-a
            (insert "Alpha")
            (setq-local proofread-auto-check nil)
            (setq-local proofread-cache-max-entries 0)
            (setq-local proofread-context-size 0)
            (setq-local proofread-max-concurrent-requests 2)
            (setq-local proofread-profile 'a)
            (setq-local
             proofread-profiles
             `((a
                :checkers
                (( :name first :backend ,backend-a
                   :options ( :name first))
                 ( :name second :backend ,backend-a
                   :options ( :name second))))))
            (proofread-mode 1)
            (setq chunks-a
                  (list
                   (car
                    (proofread-test--request-ready-chunks-for-ranges
                     '((1 . 6))))))
            (setq profile-a (proofread--current-profile)))
          (with-current-buffer buffer-b
            (insert "Beta")
            (setq-local proofread-auto-check nil)
            (setq-local proofread-cache-max-entries 0)
            (setq-local proofread-context-size 0)
            (setq-local proofread-max-concurrent-requests 1)
            (setq-local proofread-profile 'b)
            (setq-local
             proofread-profiles
             `((b
                :checkers
                (( :name only :backend ,backend-b)))))
            (proofread-mode 1)
            (setq chunks-b
                  (list
                   (car
                    (proofread-test--request-ready-chunks-for-ranges
                     '((1 . 5))))))
            (setq profile-b (proofread--current-profile)))
          (with-current-buffer buffer-a
            (let ((result
                   (proofread--dispatch-profile-request-ready-chunks-result
                    chunks-a profile-a)))
              (should entered-b)
              (should entered-nested-a)
              (should-not (plist-get nested-a-result :requests))
              (should
               (equal
                (mapcar
                 (lambda (request)
                   (plist-get request :checker-name))
                 (plist-get b-result :requests))
                '( only)))
              (should
               (equal outer-a-second-state
                      '( :a-submissions nil
                         :b-submissions ( only)
                         :a-queued ( first second))))
              (should
               (equal
                (mapcar
                 (lambda (request)
                   (plist-get request :checker-name))
                 (plist-get result :requests))
                '( first second)))
              (should
               (equal (nreverse a-submissions)
                      '(( first . t) ( second . t))))
              (should (= (length proofread--active-requests) 2))
              (should (proofread--request-queue-empty-p))
              (should-not proofread--queue-dispatch-timer)
              (proofread--clear-request-work)))
          (with-current-buffer buffer-b
            (should (equal b-submissions '( only)))
            (should (= (length proofread--active-requests) 1))
            (should (proofread--request-queue-empty-p))
            (should-not proofread--queue-dispatch-timer)
            (proofread--clear-request-work)))
      (when (buffer-live-p buffer-a)
        (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b)
        (kill-buffer buffer-b)))))

(ert-deftest
    proofread-test-profile-state-reset-starts-independent-nested-transaction
    ()
  "Resume nested profile work after its outer buffer state is replaced."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-profile-state-reset-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 1)
           (proofread-profile 'single)
           (proofread-profiles
            (list
             (list
              'single
              :checkers
              (list (list :name 'only :backend backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           reentered
           dispatch-chunks
           dispatch-profile
           old-generation
           old-queue-state
           new-generation
           new-queue-state
           submitted
           cancelled-events
           (proofread-request-log-hook
            (list
             (lambda (event)
               (when (eq (plist-get event :type) 'cancelled)
                 (push event cancelled-events))))))
      (proofread-register-backend
       backend
       :check
       (lambda (request _callback)
         (push (cons (plist-get request :checker-name)
                     (plist-get request :generation))
               submitted)
         (list :backend backend
               :request-id (plist-get request :id)))
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (unless reentered
           (setq reentered t)
           (setq old-generation proofread--generation)
           (setq old-queue-state proofread--queue-state)
           (proofread--initialize-buffer-state)
           (setq new-generation proofread--generation)
           (setq new-queue-state proofread--queue-state)
           (proofread--dispatch-profile-request-ready-chunks-result
            dispatch-chunks dispatch-profile))
         (copy-sequence options)))
      (proofread-mode 1)
      (setq dispatch-chunks
            (list
             (car
              (proofread-test--request-ready-chunks-for-ranges
               '((1 . 6))))))
      (setq dispatch-profile (proofread--current-profile))
      (let ((result
             (proofread--dispatch-profile-request-ready-chunks-result
              dispatch-chunks dispatch-profile)))
        (should reentered)
        (should-not (equal old-generation new-generation))
        (should-not (eq old-queue-state new-queue-state))
        (should
         (equal
          (list
           :outer-requests
           (mapcar
            (lambda (request)
              (plist-get request :checker-name))
            (plist-get result :requests))
           :submitted (reverse submitted)
           :active-count (length proofread--active-requests)
           :queued
           (mapcar
            (lambda (work)
              (let ((request (proofread-test--work-request work)))
                (cons (plist-get request :checker-name)
                      (plist-get request :generation))))
            (proofread--request-queue-works))
           :cancelled cancelled-events
           :timer (and (timerp proofread--queue-dispatch-timer) t))
          (list
           :outer-requests nil
           :submitted nil
           :active-count 0
           :queued (list (cons 'only new-generation))
           :cancelled nil
           :timer t)))
        (let ((timer proofread--queue-dispatch-timer))
          (cancel-timer timer)
          (proofread--queue-dispatch-timer-run (current-buffer)))
        (should
         (equal
          (list
           :submitted (reverse submitted)
           :active
           (mapcar
            (lambda (work)
              (let ((request (proofread-test--work-request work)))
                (cons (plist-get request :checker-name)
                      (plist-get request :generation))))
            proofread--active-requests)
           :queued (proofread--request-queue-works)
           :cancelled cancelled-events
           :timer (and (timerp proofread--queue-dispatch-timer) t))
          (list
           :submitted (list (cons 'only new-generation))
           :active (list (cons 'only new-generation))
           :queued nil
           :cancelled nil
           :timer nil)))
        (proofread-test--assert-queue-cache-index-consistent)
        (proofread--clear-request-work)
        (proofread-test--assert-no-pending-request-work)))))

(ert-deftest proofread-test-profile-empty-chunks-skip-checker-identity
    ()
  "Treat no chunks as an empty dispatch for a supported checker."
  (let ((proofread-profile 'multi)
        (proofread-profiles
         (proofread-test--ordered-profiles '( only)))
        (proofread--backend-registry (make-hash-table :test #'eq))
        (descriptor-calls 0)
        (snapshot-calls 0)
        (identity-calls 0)
        (source-calls 0)
        reports)
    (proofread-register-backend
     proofread-test--backend
     :check #'ignore
     :identity
     (lambda ()
       (setq identity-calls (1+ identity-calls))
       (error "Identity must not be requested for empty chunks"))
     :snapshot-options
     (lambda (_options)
       (setq snapshot-calls (1+ snapshot-calls))
       (error "Options must not be snapshotted for empty chunks"))
     :source-label
     (lambda (_checker)
       (setq source-calls (1+ source-calls))
       (error "Source label must not be requested for empty chunks")))
    (let ((original-descriptor
           (symbol-function 'proofread--backend-descriptor)))
      (cl-letf
          (((symbol-function 'proofread--backend-descriptor)
            (lambda (backend)
              (setq descriptor-calls (1+ descriptor-calls))
              (funcall original-descriptor backend)))
           ((symbol-function 'proofread-report-warning-without-window)
            (lambda (detail summary)
              (push (list detail summary) reports))))
        (should
         (equal
          (proofread--dispatch-profile-request-ready-chunks-result
           nil (proofread--current-profile))
          '( :requests nil :supported-count 1 :failures nil)))))
    (should (= descriptor-calls 1))
    (should (zerop snapshot-calls))
    (should (zerop identity-calls))
    (should (zerop source-calls))
    (should-not reports)))

(ert-deftest proofread-test-unsupported-checker-skips-options-snapshot
    ()
  "Do not call a checker snapshot hook for an unsupported backend."
  (let* ((backend 'proofread-test-unavailable-snapshot-backend)
         (proofread--backend-registry (make-hash-table :test #'eq))
         (snapshot-calls 0)
         (profile '( :name multi :checkers nil))
         (checker
          (list :profile 'multi
                :name 'only
                :checker-ordinal 0
                :backend backend
                :options (list :tone 'formal))))
    (should
     (equal
      (proofread--prepare-profile-checker-dispatch
       '(unused-chunk) profile checker)
      '( :status unsupported)))
    (proofread-register-backend
     backend
     :check #'ignore
     :identity
     (lambda ()
       (list :backend backend :contract-version 1))
     :snapshot-options
     (lambda (options)
       (setq snapshot-calls (1+ snapshot-calls))
       (proofread-test--snapshot-checker-options options)))
    (should
     (equal
      (proofread--prepare-profile-checker-dispatch
       nil profile checker)
      '( :status prepared :supported t :work nil)))
    (should (zerop snapshot-calls))))

(ert-deftest
    proofread-test-backend-wide-nil-identity-fails-preparation ()
  "Reject a nil backend-wide identity during checker preparation."
  (let* ((backend 'proofread-test-nil-identity-backend)
         (proofread--backend-registry
          (make-hash-table :test #'eq))
         (profile '( :name multi :checkers nil))
         (checker
          (list :profile 'multi
                :name 'only
                :checker-ordinal 0
                :backend backend
                :options nil)))
    (proofread-register-backend
     backend
     :check #'ignore
     :identity (lambda () nil)
     :snapshot-options (lambda (_options) nil))
    (let* ((result
            (proofread--prepare-profile-checker-dispatch
             '(unused-chunk) profile checker))
           (failure (plist-get result :failure)))
      (should (eq (plist-get result :status) 'failed))
      (should (plist-get result :supported))
      (should (eq (plist-get failure :phase) 'checker-identity))
      (should (eq (plist-get failure :error) 'error)))))

(ert-deftest
    proofread-test-profile-supported-count-isolates-preparation-failure ()
  "Count supported failures while isolating unsupported checkers."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-mixed-preparation-backend)
           (unsupported 'proofread-test-mixed-unsupported-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 0)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'unsupported :backend unsupported)
               (list :name 'failed :backend backend
                     :options '( :fail t))
               (list :name 'successful :backend backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (failed-snapshot-calls 0)
           (successful-snapshot-calls 0)
           reports)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (if (plist-get options :fail)
             (progn
               (setq failed-snapshot-calls
                     (1+ failed-snapshot-calls))
               (error "Simulated checker preparation failure"))
           (setq successful-snapshot-calls
                 (1+ successful-snapshot-calls))
           (copy-tree options))))
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (result
              (cl-letf
                  (((symbol-function
                     'proofread-report-warning-without-window)
                    (lambda (detail summary)
                      (push (list detail summary) reports))))
                (proofread--dispatch-profile-request-ready-chunks-result
                 (list chunk) (proofread--current-profile))))
             (failures (plist-get result :failures))
             (queued (proofread--request-queue-works)))
        (should (= failed-snapshot-calls 1))
        (should (> successful-snapshot-calls 0))
        (should (= (plist-get result :supported-count) 2))
        (should-not (plist-get result :requests))
        (should (= (length failures) 1))
        (should (= (length reports) 1))
        (let ((failure (car failures)))
          (should (eq (plist-get failure :checker-name) 'failed))
          (should (eq (plist-get failure :phase) 'checker-options)))
        (should (= (length queued) 1))
        (should
         (eq
          (plist-get (proofread-test--work-request (car queued))
                     :checker-name)
          'successful))))))

(ert-deftest
    proofread-test-profile-failure-reporting-error-does-not-block-dispatch ()
  "Submit successful checker work when failure reporting signals."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-failure-reporting-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 2)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'failed :backend backend
                     :options '( :fail t))
               (list :name 'successful :backend backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (report-calls 0)
           submitted)
      (proofread-register-backend
       backend
       :check
       (lambda (request _callback)
         (push request submitted)
         (list :backend backend
               :request-id (plist-get request :id)))
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (if (plist-get options :fail)
             (error "Simulated checker preparation failure")
           (copy-sequence options))))
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 6)))))
             (result
              (cl-letf
                  (((symbol-function
                     'proofread--report-checker-dispatch-failure)
                    (lambda (_failure)
                      (setq report-calls (1+ report-calls))
                      (signal
                       'error
                       '("Simulated failure-reporting error")))))
                (proofread--dispatch-profile-request-ready-chunks-result
                 (list chunk) (proofread--current-profile))))
             (requests (plist-get result :requests))
             (failures (plist-get result :failures)))
        (should (= report-calls 1))
        (should (= (plist-get result :supported-count) 2))
        (should (= (length failures) 1))
        (should (eq (plist-get (car failures) :checker-name) 'failed))
        (should (eq (plist-get (car failures) :phase)
                    'checker-options))
        (should (= (length requests) 1))
        (should (eq (plist-get (car requests) :checker-name)
                    'successful))
        (should (= (length submitted) 1))
        (should (eq (plist-get (car submitted) :checker-name)
                    'successful))
        (should (= (length proofread--active-requests) 1))
        (should (proofread--request-queue-empty-p))
        (should-not proofread--queue-dispatch-timer)
        (proofread--clear-request-work)
        (proofread-test--assert-no-pending-request-work)
        (should-not proofread--queue-dispatch-timer)))))

(ert-deftest proofread-test-checker-preparation-snapshots-options-once
    ()
  "Snapshot checker options once before request construction."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((backend 'proofread-test-preparation-snapshot-backend)
           (proofread-auto-check nil)
           (proofread-context-size 0)
           (proofread-profile 'snapshot)
           (proofread-profiles
            `((snapshot
               :checkers (( :name only :backend ,backend)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (descriptor-calls 0)
           (snapshot-calls 0)
           (identity-calls 0)
           snapshot)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (setq identity-calls (1+ identity-calls))
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (should-not options)
         (setq snapshot-calls (1+ snapshot-calls))
         (setq snapshot (list :resolved t))))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (original-descriptor
              (symbol-function 'proofread--backend-descriptor))
             (preparation
              (cl-letf
                  (((symbol-function
                     'proofread--backend-descriptor)
                    (lambda (queried-backend)
                      (setq descriptor-calls
                            (1+ descriptor-calls))
                      (funcall original-descriptor queried-backend))))
                (proofread--prepare-profile-checker-dispatch
                 (list chunk) profile checker)))
             (work (caar (plist-get preparation :work)))
             (request (proofread-test--work-request work))
             (checker-identity
              (plist-get request :checker-identity)))
        (should (= descriptor-calls 1))
        (should (= snapshot-calls 1))
        (should (= identity-calls 1))
        (should (eq (plist-get preparation :status) 'prepared))
        (should (= (length (plist-get preparation :work)) 1))
        (should (eq (plist-get request :checker-options) snapshot))
        (should (eq (plist-get checker-identity :options)
                    snapshot))))))

(ert-deftest
    proofread-test-checker-preparation-shares-one-options-snapshot ()
  "Share one backend-owned snapshot across one checker preparation."
  (with-temp-buffer
    (text-mode)
    (set-syntax-table (copy-syntax-table (syntax-table)))
    (modify-syntax-entry ?\n ".")
    (modify-syntax-entry ?\r ".")
    (insert "First. Second.")
    (let* ((backend 'proofread-test-options-sharing-backend)
           (tone (copy-sequence "formal"))
           (mutable (list "original"))
           (identity-root (make-symbol "identity-root"))
           (identity-token (copy-sequence "identity"))
           (raw-identity
            (list :proofread-test-identity-root identity-root
                  :backend backend
                  :contract-version 1
                  :tone "formal"
                  :token identity-token))
           (source-label (copy-sequence "test model"))
           (raw-options (list :tone tone :mutable mutable))
           (proofread-auto-check nil)
           (proofread-context-size 0)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'only
                     :backend backend
                     :options raw-options)))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (snapshot-calls 0)
           (descriptor-calls 0)
           (backend-identity-calls 0)
           (identity-calls 0)
           (identity-snapshot-calls 0)
           (source-calls 0)
           snapshot-input
           snapshot
           identity-options
           source-options)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (setq backend-identity-calls
               (1+ backend-identity-calls))
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (setq snapshot-calls (1+ snapshot-calls))
         (setq snapshot-input options)
         (setq snapshot
               (proofread-test--snapshot-checker-options options)))
       :checker-identity
       (lambda (checker)
         (setq identity-calls (1+ identity-calls))
         (setq identity-options (plist-get checker :options))
         raw-identity)
       :source-label
       (lambda (checker)
         (setq source-calls (1+ source-calls))
         (setq source-options (plist-get checker :options))
         source-label))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (preparation
              (let ((original-descriptor
                     (symbol-function
                      'proofread--backend-descriptor))
                    (original-snapshot
                     (symbol-function 'proofread--snapshot-value)))
                (cl-letf
                    (((symbol-function 'proofread--backend-descriptor)
                      (lambda (queried-backend)
                        (setq descriptor-calls
                              (1+ descriptor-calls))
                        (funcall original-descriptor queried-backend)))
                     ((symbol-function 'proofread--snapshot-value)
                      (lambda (value)
                        (when (proofread-test--identity-root-p
                               value identity-root)
                          (setq identity-snapshot-calls
                                (1+ identity-snapshot-calls)))
                        (funcall original-snapshot value))))
                  (proofread--prepare-profile-checker-dispatch
                   chunks profile checker))))
             (works (mapcar #'car
                            (plist-get preparation :work)))
             (requests (mapcar #'proofread-test--work-request works))
             (backend-identity
              (plist-get (car requests) :backend-identity))
             (checker-identity
              (plist-get (car requests) :checker-identity))
             (cache-keys
              (mapcar (lambda (work)
                        (copy-tree
                         (proofread--scheduled-work-cache-key work)))
                      works)))
        (should (eq (plist-get preparation :status) 'prepared))
        (should (= (length requests) 2))
        (should (= descriptor-calls 1))
        (should (= snapshot-calls 1))
        (should (zerop backend-identity-calls))
        (should (= identity-calls 1))
        (should (= identity-snapshot-calls 1))
        (should (= source-calls 1))
        (should (eq snapshot-input raw-options))
        (should (eq identity-options snapshot))
        (should (eq source-options snapshot))
        (should-not (eq backend-identity raw-identity))
        (should (eq backend-identity
                    (plist-get checker-identity :backend-identity)))
        (dolist (request requests)
          (should (eq (plist-get request :checker-options)
                      snapshot))
          (should (eq (plist-get request :backend-identity)
                      backend-identity))
          (should (eq (plist-get request :checker-identity)
                      checker-identity))
          (should (eq (plist-get request :source-label)
                      (plist-get (car requests) :source-label))))
        (aset tone 0 ?X)
        (aset identity-token 0 ?X)
        (aset source-label 0 ?X)
        (setcar mutable "changed")
        (dolist (request requests)
          (let ((options (plist-get request :checker-options)))
            (should (equal (plist-get options :tone) "formal"))
            (should (equal (plist-get options :mutable)
                           '( "original")))
            (should (equal (plist-get
                            (plist-get request :backend-identity)
                            :token)
                           "identity"))
            (should (equal (plist-get request :source-label)
                           "test model"))))
        (should
         (equal
          cache-keys
          (mapcar #'proofread--scheduled-work-cache-key works)))))))

(ert-deftest
    proofread-test-checker-preparation-snapshots-backend-identity-once
    ()
  "Detach and share one backend-wide identity per preparation."
  (with-temp-buffer
    (text-mode)
    (set-syntax-table (copy-syntax-table (syntax-table)))
    (modify-syntax-entry ?\n ".")
    (modify-syntax-entry ?\r ".")
    (insert "First. Second.")
    (let* ((backend 'proofread-test-backend-identity-snapshot)
           (identity-root (make-symbol "identity-root"))
           (token (copy-sequence "identity"))
           (raw-identity
            (list :proofread-test-identity-root identity-root
                  :backend backend
                  :contract-version 1
                  :token token))
           (raw-options '( :tone formal))
           (profile
            (list :name 'multi
                  :checkers
                  (list
                   (list :profile 'multi
                         :name 'only
                         :checker-ordinal 0
                         :backend backend
                         :options raw-options))))
           (checker (car (plist-get profile :checkers)))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (descriptor-calls 0)
           (snapshot-calls 0)
           (identity-calls 0)
           (identity-snapshot-calls 0)
           (source-calls 0)
           options-snapshot)
      (proofread-register-backend
       backend
       :check #'ignore
       :identity
       (lambda ()
         (setq identity-calls (1+ identity-calls))
         raw-identity)
       :snapshot-options
       (lambda (options)
         (setq snapshot-calls (1+ snapshot-calls))
         (setq options-snapshot (copy-tree options)))
       :source-label
       (lambda (_checker)
         (setq source-calls (1+ source-calls))
         nil))
      (let* ((chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (original-descriptor
              (symbol-function 'proofread--backend-descriptor))
             (original-snapshot
              (symbol-function 'proofread--snapshot-value))
             (preparation
              (cl-letf
                  (((symbol-function 'proofread--backend-descriptor)
                    (lambda (queried-backend)
                      (setq descriptor-calls
                            (1+ descriptor-calls))
                      (funcall original-descriptor queried-backend)))
                   ((symbol-function 'proofread--snapshot-value)
                    (lambda (value)
                      (when (proofread-test--identity-root-p
                             value identity-root)
                        (setq identity-snapshot-calls
                              (1+ identity-snapshot-calls)))
                      (funcall original-snapshot value))))
                (proofread--prepare-profile-checker-dispatch
                 chunks profile checker)))
             (works
              (mapcar #'car (plist-get preparation :work)))
             (requests (mapcar #'proofread-test--work-request works))
             (backend-identity
              (plist-get (car requests) :backend-identity))
             (checker-identity
              (plist-get (car requests) :checker-identity))
             (cache-keys
              (mapcar (lambda (work)
                        (copy-tree
                         (proofread--scheduled-work-cache-key work)))
                      works)))
        (should (eq (plist-get preparation :status) 'prepared))
        (should (= (length requests) 2))
        (should (= descriptor-calls 1))
        (should (= snapshot-calls 1))
        (should (= identity-calls 1))
        (should (= identity-snapshot-calls 1))
        (should (= source-calls 1))
        (should-not (eq backend-identity raw-identity))
        (should (eq backend-identity
                    (plist-get checker-identity :backend-identity)))
        (should (eq options-snapshot
                    (plist-get checker-identity :options)))
        (dolist (request requests)
          (should (eq (plist-get request :backend-identity)
                      backend-identity))
          (should (eq (plist-get request :checker-identity)
                      checker-identity)))
        (aset token 0 ?X)
        (should (equal (plist-get backend-identity :token)
                       "identity"))
        (should
         (equal
          cache-keys
          (mapcar #'proofread--scheduled-work-cache-key works)))))))

(ert-deftest
    proofread-test-checker-preparation-keeps-captured-descriptor ()
  "Keep one descriptor through preparation and recapture on submit."
  (with-temp-buffer
    (text-mode)
    (insert "Alpha")
    (let* ((backend 'proofread-test-descriptor-mutation-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 1)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'only
                     :backend backend
                     :options '( :tone formal))))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           events
           (old-checks 0)
           (new-checks 0)
           old-cancels
           new-cancels)
      (cl-labels
          ((identity (checker event)
             (push event events)
             (list :backend backend
                   :contract-version 1
                   :tone
                   (plist-get (plist-get checker :options) :tone)))
           (register-new ()
             (proofread-register-backend
              backend
              :check
              (lambda (_request _callback)
                (setq new-checks (1+ new-checks))
                'new-handle)
              :identity
              (lambda ()
                (list :backend backend :contract-version 1))
              :snapshot-options
              (lambda (_options)
                (push 'new-snapshot events)
                '( :tone formal))
              :checker-identity
              (lambda (checker)
                (identity checker 'new-identity))
              :source-label
              (lambda (_checker)
                (push 'new-source events)
                "new source")
              :cancel
              (lambda (handle)
                (push handle new-cancels)))))
        (proofread-register-backend
         backend
         :check
         (lambda (_request _callback)
           (setq old-checks (1+ old-checks))
           'old-handle)
         :identity
         (lambda ()
           (list :backend backend :contract-version 1))
         :snapshot-options
         (lambda (_options)
           (push 'old-snapshot events)
           (register-new)
           '( :tone formal))
         :checker-identity
         (lambda (checker)
           (identity checker 'old-identity))
         :source-label
         (lambda (_checker)
           (push 'old-source events)
           "old source")
         :cancel
         (lambda (handle)
           (push handle old-cancels)))
        (proofread-mode 1)
        (let* ((profile (proofread--current-profile))
               (checker (car (plist-get profile :checkers)))
               (chunks
                (proofread-test--request-ready-chunks-for-ranges
                 (list (cons (point-min) (point-max)))))
               (old-preparation
                (proofread--prepare-profile-checker-dispatch
                 chunks profile checker))
               (old-work
                (caar (plist-get old-preparation :work)))
               (old-request
                (proofread-test--work-request old-work)))
          (should (eq (plist-get old-preparation :status) 'prepared))
          (should (equal (nreverse events)
                         '(old-snapshot old-identity old-source)))
          (should (equal (plist-get old-request :source-label)
                         "old source"))
          (setq events nil)
          (let* ((new-preparation
                  (proofread--prepare-profile-checker-dispatch
                   chunks profile checker))
                 (new-work
                  (caar (plist-get new-preparation :work)))
                 (new-request
                  (proofread-test--work-request new-work)))
            (should (eq (plist-get new-preparation :status)
                        'prepared))
            (should (equal (nreverse events)
                           '(new-snapshot new-identity new-source)))
            (should (equal (plist-get new-request :source-label)
                           "new source"))
            (should
             (equal (proofread--scheduled-work-cache-key old-work)
                    (proofread--scheduled-work-cache-key new-work)))
            (let ((descriptor-calls 0)
                  (original-descriptor
                   (symbol-function 'proofread--backend-descriptor)))
              (cl-letf
                  (((symbol-function 'proofread--backend-descriptor)
                    (lambda (queried-backend)
                      (setq descriptor-calls
                            (1+ descriptor-calls))
                      (funcall original-descriptor queried-backend))))
                (should
                 (equal (proofread--scheduled-work-cache-key old-work)
                        (proofread--cache-key old-request backend))))
              (should (zerop descriptor-calls))))
          (setq events nil)
          (let ((descriptor-calls 0)
                (original-descriptor
                 (symbol-function 'proofread--backend-descriptor)))
            (cl-letf
                (((symbol-function 'proofread--backend-descriptor)
                  (lambda (queried-backend)
                    (setq descriptor-calls
                          (1+ descriptor-calls))
                    (funcall original-descriptor queried-backend))))
              (should (proofread--fresh-request-p old-work)))
            (should (= descriptor-calls 1)))
          (should (equal (nreverse events)
                         '(new-snapshot new-identity)))
          (setq events nil)
          (let ((transaction
                 (proofread--make-profile-dispatch-transaction
                  (current-buffer) proofread--generation
                  proofread--queue-state)))
            (proofread--publish-profile-checker-dispatches
             (list old-preparation) transaction)
            (proofread--dispatch-queued-requests))
          (should (zerop old-checks))
          (should (= new-checks 1))
          (should (proofread--active-request-p old-work))
          (proofread--cancel-active-requests)
          (should-not old-cancels)
          (should (equal new-cancels '(new-handle))))))))

(ert-deftest
    proofread-test-profile-synchronous-callback-sees-complete-publication
    ()
  "Prepare and publish every checker before a synchronous callback."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((first-backend 'proofread-test-first-sync-backend)
           (later-backend 'proofread-test-later-sync-backend)
           (proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 2)
           (proofread-profile 'multi)
           (proofread-profiles
            (list
             (list
              'multi
              :checkers
              (list
               (list :name 'first :backend first-backend)
               (list :name 'later :backend later-backend
                     :options '( :tone formal))))))
           (proofread--backend-registry
            (make-hash-table :test #'eq))
           (old-snapshot-calls 0)
           (new-snapshot-calls 0)
           (old-check-calls 0)
           (new-check-calls 0)
           old-options-snapshot
           later-request
           publication-before-first
           pending-before-first
           prepared-before-first
           old-cancelled
           new-cancelled
           register-new-later)
      (setq register-new-later
            (lambda ()
              (proofread-register-backend
               later-backend
               :check
               (lambda (request _callback)
                 (setq new-check-calls (1+ new-check-calls))
                 (setq later-request request)
                 'new-later-handle)
               :identity
               (lambda ()
                 (list :backend later-backend :contract-version 1))
               :snapshot-options
               (lambda (options)
                 (setq new-snapshot-calls (1+ new-snapshot-calls))
                 (proofread-test--snapshot-checker-options options))
               :cancel
               (lambda (handle)
                 (push handle new-cancelled)))))
      (proofread-register-backend
       later-backend
       :check
       (lambda (_request _callback)
         (setq old-check-calls (1+ old-check-calls))
         'old-later-handle)
       :identity
       (lambda ()
         (list :backend later-backend :contract-version 1))
       :snapshot-options
       (lambda (options)
         (setq old-snapshot-calls (1+ old-snapshot-calls))
         (setq old-options-snapshot
               (proofread-test--snapshot-checker-options options)))
       :cancel
       (lambda (handle)
         (push handle old-cancelled)))
      (proofread-register-backend
       first-backend
       :check
       (lambda (request callback)
         (setq prepared-before-first old-snapshot-calls)
         (setq publication-before-first
               (proofread-test--scheduled-checker-names))
         (setq pending-before-first
               (hash-table-count proofread--pending-request-keys))
         (funcall register-new-later)
         (funcall callback
                  (proofread--backend-success-result request nil))
         'first-handle)
       :identity
       (lambda ()
         (list :backend first-backend :contract-version 1))
       :snapshot-options #'proofread-test--snapshot-checker-options)
      (proofread-mode 1)
      (let* ((chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (result
              (proofread--dispatch-profile-request-ready-chunks-result
               (list chunk) (proofread--current-profile))))
        (should (= prepared-before-first 1))
        (should (equal publication-before-first '(first later)))
        (should (= pending-before-first 2))
        (should (= old-snapshot-calls 1))
        (should (> new-snapshot-calls 0))
        (should (zerop old-check-calls))
        (should (= new-check-calls 1))
        (should later-request)
        (should
         (eq (plist-get later-request :checker-options)
             old-options-snapshot))
        (should
         (equal
          (mapcar (lambda (request)
                    (plist-get request :checker-name))
                  (plist-get result :requests))
          '(first later)))
        (should (= (length proofread--active-requests) 1))
        (proofread--clear-request-work)
        (should-not old-cancelled)
        (should (equal new-cancelled '(new-later-handle)))))))

(ert-deftest proofread-test-bare-cache-key-captures-one-descriptor ()
  "Build both cache identities from one backend descriptor lookup."
  (let* ((backend 'proofread-test-cache-descriptor-backend)
         (identity-root (make-symbol "identity-root"))
         (token (copy-sequence "identity"))
         (raw-identity
          (list :proofread-test-identity-root identity-root
                :backend backend
                :contract-version 1
                :token token))
         (proofread--backend-registry
          (make-hash-table :test #'eq))
         (descriptor-calls 0)
         (snapshot-calls 0)
         (identity-calls 0)
         (identity-snapshot-calls 0))
    (proofread-register-backend
     backend
     :check #'ignore
     :identity
     (lambda ()
       (setq identity-calls (1+ identity-calls))
       raw-identity)
     :snapshot-options
     (lambda (_options)
       (setq snapshot-calls (1+ snapshot-calls))
       nil))
    (let* ((original-descriptor
            (symbol-function 'proofread--backend-descriptor))
           (original-snapshot
            (symbol-function 'proofread--snapshot-value))
           (key
            (cl-letf
                (((symbol-function 'proofread--backend-descriptor)
                  (lambda (queried-backend)
                    (setq descriptor-calls
                          (1+ descriptor-calls))
                    (funcall original-descriptor queried-backend)))
                 ((symbol-function 'proofread--snapshot-value)
                  (lambda (value)
                    (when (proofread-test--identity-root-p
                           value identity-root)
                      (setq identity-snapshot-calls
                            (1+ identity-snapshot-calls)))
                    (funcall original-snapshot value))))
              (proofread--cache-key
               (list :backend backend
                     :text "Alpha"
                     :language "en-US"
                     :major-mode 'text-mode
                     :target-policy 'all
                     :target-kind 'prose)
               backend))))
      (should (= descriptor-calls 1))
      (should (= snapshot-calls 1))
      (should (= identity-calls 1))
      (should (= identity-snapshot-calls 1))
      (should (eq (plist-get key :backend)
                  (plist-get (plist-get key :checker)
                             :backend-identity)))
      (aset token 0 ?X)
      (should (equal (plist-get (plist-get key :backend) :token)
                     "identity")))))

(ert-deftest
    proofread-test-profile-source-label-is-snapshotted-once-per-checker
    ()
  "Snapshot one safe source label for every dispatched checker."
  (with-temp-buffer
    (text-mode)
    (set-syntax-table (copy-syntax-table (syntax-table)))
    (modify-syntax-entry ?\n ".")
    (modify-syntax-entry ?\r ".")
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
      (proofread-register-backend
       proofread-test--backend
       :check (plist-get recorder :function)
       :identity #'proofread-test--backend-identity
       :snapshot-options #'proofread-test--snapshot-checker-options
       :source-label
       (lambda (checker)
         (push (copy-sequence checker) calls)
         (propertize
          (format "　\n%s\rmodel\tname　"
                  (plist-get checker :name))
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
        (proofread-register-backend
         proofread-test--backend
         :check (plist-get recorder :function)
         :identity #'proofread-test--backend-identity
         :snapshot-options #'proofread-test--snapshot-checker-options
         :source-label
         (lambda (_checker)
           (setq calls (1+ calls))
           (pcase failure
             ('error (error "secret source-label failure"))
             ('invalid '( secret invalid value))
             ('blank "　\n\t "))))
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
      (proofread-register-backend
       proofread-test--backend
       :check (plist-get recorder :function)
       :identity #'proofread-test--backend-identity
       :snapshot-options #'proofread-test--snapshot-checker-options
       :source-label (lambda (_checker) label)
       :cancel (lambda (handle)
                 (push handle cancelled-handles)))
      (proofread-mode 1)
      (proofread-check-buffer)
      (let ((old (car (funcall (plist-get recorder :requests))))
            (old-work (car proofread--active-requests)))
        (should old)
        (should (eq (proofread-test--work-request old-work) old))
        (should (equal (plist-get old :source-label) "old-model"))
        (setq label "new-model")
        (proofread-check-buffer)
        (let* ((requests (funcall (plist-get recorder :requests)))
               (callbacks (funcall (plist-get recorder :callbacks)))
               (new (cadr requests))
               (new-work (car proofread--active-requests)))
          (should (= (length requests) 2))
          (should (eq (proofread-test--work-request new-work) new))
          (should (equal (plist-get new :source-label) "new-model"))
          (should
           (equal (proofread--scheduled-work-cache-key old-work)
                  (proofread--scheduled-work-cache-key new-work)))
          (should-not (equal (proofread--request-work-key old-work)
                             (proofread--request-work-key new-work)))
          (should
           (proofread--request-state-flag-p old-work :superseded))
          (should (equal cancelled-handles
                         '(proofread-test-handle)))
          (should-not (proofread--active-request-p old-work))
          (should (proofread--active-request-p new-work))
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
    (proofread-register-backend
     proofread-test--backend
     :check #'ignore
     :identity #'proofread-test--backend-identity
     :snapshot-options #'proofread-test--snapshot-checker-options
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
             (proofread-test--backend-check-function
              (plist-get recorder :function))
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
               ((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports)))
               ((symbol-function 'proofread--progress-message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        progress))))
            (proofread-check-buffer)
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (works
                    (mapcar #'proofread--scheduled-work-for-request
                            requests)))
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
              (proofread-test--assert-requests-settled works)
              (proofread-test--assert-one-checker-report reports))))))))

(ert-deftest
    proofread-test-profile-checker-options-failure-isolates-checker
    ()
  "Continue later checkers after an options snapshot cannot be made."
  (dolist (failure '( error invalid))
    (with-temp-buffer
      (text-mode)
      (insert "First. Second.")
      (let* ((sentinel
              "PROOFREAD-TEST-SNAPSHOT-SECRET-MUST-NOT-APPEAR")
             (provider
              (vector 'proofread-test-provider :api-key sentinel))
             (proofread-auto-check nil)
             (proofread-cache-max-entries 0)
             (proofread-context-size 0)
             (proofread-max-concurrent-requests 20)
             (proofread-profile 'multi)
             (proofread-profiles
              (list
               (list
                'multi
                :checkers
                (list
                 (list :name 'failed
                       :backend proofread-test--backend
                       :options
                       (list :failure failure
                             :provider provider))
                 (list :name 'later
                       :backend proofread-test--backend)))))
             (proofread--backend-registry
              (make-hash-table :test #'eq))
             (recorder (proofread-test--make-backend-recorder))
             (failed-snapshot-calls 0)
             raw-error-text
             events
             progress
             reports)
        (proofread-register-backend
         proofread-test--backend
         :check (plist-get recorder :function)
         :identity #'proofread-test--backend-identity
         :snapshot-options
         (lambda (options)
           (if-let* ((kind (plist-get options :failure)))
               (progn
                 (setq failed-snapshot-calls
                       (1+ failed-snapshot-calls))
                 (pcase kind
                   ('error
                    (setq raw-error-text
                          (format "Snapshot failure for %S" provider))
                    (error "%s" raw-error-text))
                   ('invalid (vector :provider provider))))
             (proofread-test--snapshot-checker-options options))))
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
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (works
                    (mapcar #'proofread--scheduled-work-for-request
                            requests)))
              (should (= failed-snapshot-calls 1))
              (when (eq failure 'error)
                (should (string-match-p (regexp-quote sentinel)
                                        raw-error-text)))
              (proofread-test--assert-secret-not-printed
               sentinel events)
              (proofread-test--assert-secret-not-printed
               sentinel reports)
              (proofread-test--assert-checker-dispatch-failure-event
               events 'checker-options)
              (proofread-test--assert-one-checker-report reports)
              (proofread-test--assert-successful-checker-requests
               requests '( later))
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
              (proofread-test--assert-requests-settled works))))))))

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
        (proofread-register-backend
         proofread-test--backend
         :check (plist-get recorder :function)
         :identity #'proofread-test--backend-identity
         :snapshot-options #'proofread-test--snapshot-checker-options
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
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (works
                    (mapcar #'proofread--scheduled-work-for-request
                            requests)))
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
              (proofread-test--assert-requests-settled works)
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
                       (push event events))))
              (proofread-test--backend-check-function
               (plist-get recorder :function)))
          (cl-letf
              (((symbol-function 'proofread--make-backend-request)
                (lambda (chunk &optional backend checker profile
                               preparation)
                  (if (eq (plist-get checker :name) 'failed)
                      (progn
                        (setq failed-construction-calls
                              (1+ failed-construction-calls))
                        (error "Simulated request construction failure"))
                    (funcall original-make-request
                             chunk backend checker profile
                             preparation))))
               ((symbol-function
                 'proofread-report-warning-without-window)
                (lambda (detail summary)
                  (push (list detail summary) reports)))
               ((symbol-function 'proofread--progress-message)
                (lambda (format-string &rest args)
                  (push (apply #'format format-string args)
                        progress))))
            (proofread-check-buffer)
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (works
                    (mapcar #'proofread--scheduled-work-for-request
                            requests)))
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
              (proofread-test--assert-requests-settled works)
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
               all-works
               events
               progress
               reports)
          (proofread-mode 1)
          (let ((proofread-request-log-hook
                 (list (lambda (event)
                         (push event events))))
                (proofread-test--backend-check-function
                 (lambda (request callback)
                   (push request all-requests)
                   (push (proofread--scheduled-work-for-request request)
                         all-works)
                   (if (eq (plist-get request :checker-name) 'failed)
                       (pcase failure-mode
                         ('signal
                          (error "Simulated submission failure"))
                         ('nil-handle nil))
                     (funcall recorder-function request callback)))))
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
              (setq all-requests (nreverse all-requests))
              (setq all-works (nreverse all-works))
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
                (dolist (work
                         (cl-remove-if-not
                          (lambda (candidate)
                            (eq
                             (plist-get
                              (proofread-test--work-request candidate)
                              :checker-name)
                             'failed))
                          all-works))
                  (should-not (proofread--scheduled-work-handle work))
                  (should-not
                   (proofread--request-work-pending-p work)))
                (should
                 (equal
                  (proofread-test--complete-recorded-requests recorder)
                  (make-list (length requests) 'applied)))
                (proofread-test--assert-request-diagnostics requests)
                (proofread-test--assert-requests-settled all-works)
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
           all-works
           events
           reports)
      (proofread-mode 1)
      (let ((proofread-request-log-hook
             (list (lambda (event)
                     (push event events))))
            (proofread-test--backend-check-function
             (lambda (request callback)
               (push request all-requests)
               (push (proofread--scheduled-work-for-request request)
                     all-works)
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
                 (funcall recorder-function request callback)))))
        (cl-letf
            (((symbol-function
               'proofread-report-warning-without-window)
              (lambda (detail summary)
                (push (list detail summary) reports))))
          (proofread-check-buffer)
          (setq all-requests (nreverse all-requests))
          (setq all-works (nreverse all-works))
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
            (proofread-test--assert-requests-settled all-works)
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
           work
           events
           reports)
      (proofread-mode 1)
      (let ((proofread-request-log-hook
             (list (lambda (event)
                     (push event events))))
            (proofread-test--backend-check-function
             (lambda (backend-request callback)
               (setq request backend-request)
               (setq work
                     (proofread--scheduled-work-for-request
                      backend-request))
               (funcall
                callback
                (proofread--backend-success-result
                 backend-request nil))
               nil)))
        (cl-letf
            (((symbol-function 'proofread--cache-write-request)
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
        (should-not (proofread--scheduled-work-handle work))
        (should-not reports)
        (should-not
         (cl-find-if
          (lambda (event)
            (and
             (eq (plist-get event :type) 'final-result)
             (eq (plist-get (plist-get event :result) :phase)
                 'submission)))
          events))
        (should-not (proofread--request-work-pending-p work))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
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
        (proofread-test--dispatch-profile-chunks chunks profile)
        (let* ((queued (proofread--request-queue-works))
               (requests
                (mapcar #'proofread-test--work-request queued)))
          (should (= (length queued) 2))
          (should (equal (mapcar (lambda (request)
                                   (plist-get request :checker-name))
                                 requests)
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
      (let ((proofread-test--backend-check-function
             (lambda (request _callback)
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
          (proofread-test--dispatch-profile-chunks
           (list old-chunk) profile)
          (let* ((old-first
                  (cl-find
                   'first proofread--active-requests
                   :key (lambda (work)
                          (plist-get
                           (proofread-test--work-request work)
                           :checker-name))))
                 (old-second
                  (cl-find
                   'second proofread--active-requests
                   :key (lambda (work)
                          (plist-get
                           (proofread-test--work-request work)
                           :checker-name)))))
            (should old-first)
            (should old-second)
            (proofread-test--dispatch-profile-chunks
             (list new-chunk)
             (plist-put (copy-sequence profile)
                        :checkers (list first-checker)))
            (let ((new-first
                   (cl-find-if
                    (lambda (work)
                      (let ((request
                             (proofread-test--work-request work)))
                        (and (eq (plist-get request :checker-name)
                                 'first)
                             (equal (plist-get request :text)
                                    "bcde"))))
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
    proofread-test-profile-cancellation-hook-invalidates-all-replacements
    ()
  "Publish every checker replacement before cancellation hooks can edit."
  (with-temp-buffer
    (insert "abcdef")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-max-concurrent-requests 8)
           (proofread-profile 'multi)
           (proofread-profiles (proofread-test--ordered-profiles))
           (proofread-request-log-hook nil)
           submitted
           old-works
           replacement-works
           replacement-log-ids
           replacement-cancellations
           replacement-publications
           first-hook-state
           hook-error
           drain-requested
           timer-scheduled-in-hook)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (old-chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((1 . 7)))))
             (replacement-chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                '((2 . 6)))))
             (proofread-test--backend-check-function
              (lambda (request _callback)
                (push request submitted)
                (list :backend proofread-test--backend
                      :request-id (plist-get request :id)))))
        (proofread--dispatch-profile-request-ready-chunks-result
         (list old-chunk) profile)
        (setq old-works (copy-sequence proofread--active-requests))
        (should (= (length old-works) 2))
        (should (= (length submitted) 2))
        (setq submitted nil)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (let ((type (plist-get event :type))
                        (log-id (plist-get event :log-id)))
                    (when (and replacement-log-ids
                               (memq log-id replacement-log-ids))
                      (pcase type
                        ('cancelled
                         (push log-id replacement-cancellations))
                        ('queued-request
                         (push log-id replacement-publications))))
                    (when (and (not first-hook-state)
                               (eq type 'cancelled)
                               (eq (plist-get event :reason)
                                   'superseded))
                      (condition-case err
                          (progn
                            (setq replacement-works
                                  (copy-sequence
                                   (proofread--request-queue-works)))
                            (setq replacement-log-ids
                                  (mapcar
                                   #'proofread--scheduled-work-log-id
                                   replacement-works))
                            (setq first-hook-state
                                  (list
                                   :inhibited
                                   (proofread--queue-dispatch-inhibited-p)
                                   :names
                                   (mapcar
                                    (lambda (work)
                                      (plist-get
                                       (proofread-test--work-request work)
                                       :checker-name))
                                    replacement-works)
                                   :pending-count
                                   (hash-table-count
                                    proofread--pending-request-keys)
                                   :all-pending
                                   (cl-every
                                    #'proofread--request-work-pending-p
                                    replacement-works)
                                   :active-count
                                   (length proofread--active-requests)
                                   :claimed-count
                                   (length proofread--claimed-requests)
                                   :batch-count
                                   (length
                                    (delete-dups
                                     (mapcar
                                      #'proofread--scheduled-work-batch
                                      replacement-works)))
                                   :submitted
                                   (copy-sequence submitted)))
                            (setq drain-requested t)
                            (proofread--dispatch-queued-requests)
                            (setq timer-scheduled-in-hook
                                  (timerp
                                   proofread--queue-dispatch-timer))
                            (goto-char (point-min))
                            (insert "x"))
                        (error
                         (setq hook-error err)))))))))
          (proofread--dispatch-profile-request-ready-chunks-result
           (list replacement-chunk) profile)))
      (should-not hook-error)
      (should drain-requested)
      (should timer-scheduled-in-hook)
      (should
       (equal first-hook-state
              '( :inhibited t
                 :names ( first second)
                 :pending-count 2
                 :all-pending t
                 :active-count 0
                 :claimed-count 0
                 :batch-count 2
                 :submitted nil)))
      (should (= (length replacement-works) 2))
      (should-not submitted)
      (should-not proofread--queue-dispatch-timer)
      (should
       (equal (sort (copy-sequence replacement-cancellations) #'<)
              (sort (copy-sequence replacement-log-ids) #'<)))
      (should
       (equal (sort (copy-sequence replacement-publications) #'<)
              (sort (copy-sequence replacement-log-ids) #'<)))
      (dolist (work replacement-works)
        (should (proofread--request-invalidated-p work))
        (should (proofread--request-state-flag-p work :cancelled))
        (should (proofread--scheduled-work-batch-settled work)))
      (dolist (work old-works)
        (should (proofread--request-state-flag-p work :superseded))
        (should (proofread--request-state-flag-p work :cancelled)))
      (proofread-test--assert-no-pending-request-work))))

(ert-deftest
    proofread-test-profile-batch-attachment-error-publishes-nothing ()
  "Leave shared request state unchanged when batch attachment fails."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles))
          (original-attach
           (symbol-function 'proofread--attach-request-batch))
          (attach-count 0)
          raised)
      (proofread-mode 1)
      (let ((chunk
             (car
              (proofread-test--request-ready-chunks-for-ranges
               '((1 . 6))))))
        (cl-letf
            (((symbol-function 'proofread--attach-request-batch)
              (lambda (works)
                (setq attach-count (1+ attach-count))
                (if (= attach-count 2)
                    (error "Simulated batch attachment failure")
                  (funcall original-attach works)))))
          (condition-case err
              (proofread--dispatch-profile-request-ready-chunks-result
               (list chunk) (proofread--current-profile))
            (error
             (setq raised err)))))
      (should (eq (car raised) 'error))
      (should (= attach-count 2))
      (should (proofread--request-queue-empty-p))
      (should-not proofread--active-requests)
      (should-not proofread--queue-dispatch-timer)
      (proofread-test--assert-no-pending-request-work))))

(ert-deftest
    proofread-test-profile-publication-error-schedules-root-fallback ()
  "Schedule root queue continuation after publication unwinds."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0)
          (proofread-profile 'multi)
          (proofread-profiles (proofread-test--ordered-profiles))
          raised)
      (proofread-mode 1)
      (let ((chunk
             (car
              (proofread-test--request-ready-chunks-for-ranges
               '((1 . 6))))))
        (cl-letf
            (((symbol-function
               'proofread--record-prepared-work-publication)
              (lambda (_prepared)
                (error "Simulated publication failure"))))
          (condition-case err
              (proofread--dispatch-profile-request-ready-chunks-result
               (list chunk) (proofread--current-profile))
            (error
             (setq raised err)))))
      (should (eq (car raised) 'error))
      (should (= (proofread--request-queue-length) 2))
      (should (timerp proofread--queue-dispatch-timer))
      (proofread--cancel-queue-dispatch-timer)
      (proofread--clear-request-work)
      (proofread-test--assert-no-pending-request-work))))

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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     work
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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
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
              work
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
             (first-work
              (proofread-test--make-request-work
               chunk proofread-test--backend first-checker profile))
             (second-work
              (proofread-test--make-request-work
               chunk proofread-test--backend second-checker profile))
             (first-request
              (proofread-test--work-request first-work))
             (second-request
              (proofread-test--work-request second-work))
             (first-diagnostic
              (proofread-test--diagnostic-with-suggestions
               1 5 "helo" '( "hello")))
             (second-diagnostic
              (proofread-test--diagnostic-with-suggestions
               1 5 "helo" '( "hullo"))))
        (should (eq (proofread--handle-backend-result
                     second-work
                     (proofread--backend-success-result
                      second-request (list second-diagnostic)))
                    'applied))
        (should (eq (proofread--handle-backend-result
                     first-work
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
                     first-work
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
      (let ((proofread-test--backend-check-function
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
      (let ((inside
             (cl-find 1 proofread--diagnostics
                      :key (lambda (diagnostic)
                             (plist-get diagnostic :beg))))
            (outside
             (cl-find 10 proofread--diagnostics
                      :key (lambda (diagnostic)
                             (plist-get diagnostic :beg)))))
        (should inside)
        (should outside)
        (setq-local proofread-profile 'profile-b)
        (let ((proofread-test--backend-check-function
               (plist-get profile-b-recorder :function)))
          (proofread-check-region 1 5)
          (should-not (memq inside proofread--diagnostics))
          (should (memq outside proofread--diagnostics))
          (should-not
           (memq inside
                 (proofread-test--flymake-proofread-diagnostics)))
          (should
           (memq outside
                 (proofread-test--flymake-proofread-diagnostics)))
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
          (should
           (equal (proofread-test--flymake-proofread-diagnostics)
                  (list outside))))))))

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
      (let ((proofread-test--backend-check-function
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
      (let ((first
             (cl-find 'first proofread--diagnostics
                      :key (lambda (diagnostic)
                             (plist-get diagnostic :checker-name))))
            (second
             (cl-find 'second proofread--diagnostics
                      :key (lambda (diagnostic)
                             (plist-get diagnostic :checker-name)))))
        (should first)
        (should second)
        (setq proofread-profiles
              `((multi
                 :checkers
                 (( :name second
                    :backend ,proofread-test--backend)))))
        (let ((proofread-test--backend-check-function
               (plist-get replacement-recorder :function)))
          (proofread-check-buffer)
          (should-not (memq first proofread--diagnostics))
          (should (memq second proofread--diagnostics))
          (should-not
           (memq first
                 (proofread-test--flymake-proofread-diagnostics)))
          (should
           (memq second
                 (proofread-test--flymake-proofread-diagnostics)))
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
          (should-not
           (proofread-test--flymake-proofread-diagnostics)))))))

(ert-deftest
    proofread-test-disabled-profiles-retire-profile-diagnostics-only
    ()
  "Disabled profiles retire profile diagnostics but keep ad-hoc ones."
  (dolist (disabled-profile '(nil disabled))
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
            (disabled-recorder
             (proofread-test--make-backend-recorder))
            profile-diagnostic
            ad-hoc-diagnostic)
        (proofread-mode 1)
        (let ((proofread-test--backend-check-function
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
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
               (work
                (proofread-test--make-request-work
                 chunk proofread-test--backend))
               (request (proofread-test--work-request work)))
          (should (plist-get
                   (plist-get request :checker-owner) :ad-hoc))
          (should
           (eq
            (proofread--handle-backend-result
             work
             (proofread--backend-success-result
              request
              (list
               (proofread-test--diagnostic-with-suggestions
                1 5 "helo" '( "hullo")))))
            'applied)))
        (setq ad-hoc-diagnostic
              (cl-find-if
               (lambda (diagnostic)
                 (plist-get
                  (plist-get diagnostic :checker-owner) :ad-hoc))
               proofread--diagnostics))
        (should profile-diagnostic)
        (should ad-hoc-diagnostic)
        (setq-local proofread-profile disabled-profile)
        (let ((proofread-test--backend-check-function
               (plist-get disabled-recorder :function)))
          (proofread-check-buffer))
        (should-not
         (funcall (plist-get disabled-recorder :requests)))
        (should-not (memq profile-diagnostic proofread--diagnostics))
        (should (equal proofread--diagnostics
                       (list ad-hoc-diagnostic)))
        (should
         (equal (proofread-test--flymake-proofread-diagnostics)
                (list ad-hoc-diagnostic)))))))

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
          (let ((proofread-test--backend-check-function
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
        (let ((proofread-test--backend-check-function
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
      (let ((proofread-test--backend-check-function
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
      (let ((proofread-test--backend-check-function
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
                 (work
                  (proofread-test--make-request-work
                   chunk proofread-test--backend checker profile))
                 (request (proofread-test--work-request work)))
            (proofread--cache-write-request
             work
             (list
              (proofread-test--ordered-checker-diagnostic request))))
          (let ((proofread-test--backend-check-function
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
    proofread-test-profile-cache-entry-is-provider-neutral
    ()
  "Cache relative payloads and add current request provenance on use."
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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (diagnostic
              (append
               (proofread-test--diagnostic-for-range
                1 5 "helo")
               '( :backend-extra kept))))
        (should
         (eq
          (proofread--handle-backend-result
           work
           (proofread--backend-success-result
            request (list diagnostic)))
          'applied))
        (let* ((entry (proofread--cache-read-request work))
               (cached (car (plist-get entry :diagnostics))))
          (should
           (equal
            (cl-loop for (key _value) on entry by #'cddr
                     collect key)
            '( :text :diagnostics)))
          (should (equal (plist-get entry :text) "helo"))
          (should (eq (plist-get cached :source) 'test))
          (should (eq (plist-get cached :backend-extra) 'kept))
          (should
           (equal cached
                  (proofread--diagnostic-to-relative
                   diagnostic request)))
          (dolist (key proofread-test--diagnostic-provenance-keys)
            (should-not (plist-member cached key)))
          (let ((saved-entry (copy-tree entry)))
            (should (eq (proofread--apply-cache-entry work entry)
                        'applied))
            (should (equal entry saved-entry)))
          (let ((live (car proofread--diagnostics)))
            (should (eq (plist-get live :source) 'test))
            (should (eq (plist-get live :backend-extra) 'kept))
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
      (proofread-register-backend
       proofread-test--backend
       :check #'proofread-test--backend-check
       :identity #'proofread-test--backend-identity
       :snapshot-options #'proofread-test--snapshot-checker-options
       :source-label (lambda (_checker) label))
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (old-work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (old-request
              (proofread-test--work-request old-work))
             (diagnostic
              (append
               (proofread--diagnostic-with-request-provenance
                old-request
                (proofread-test--diagnostic-for-range 1 5 "helo"))
               '( :backend-extra kept))))
        (proofread--cache-write-request old-work (list diagnostic))
        (let* ((entry (proofread--cache-read-request old-work))
               (cached (car (plist-get entry :diagnostics))))
          (dolist (key proofread-test--diagnostic-provenance-keys)
            (should-not (plist-member cached key)))
          (should (eq (plist-get cached :backend-extra) 'kept))
          (setq label "new-model")
          (let* ((new-work
                  (proofread-test--make-request-work
                   chunk proofread-test--backend checker profile))
                 (new-request
                  (proofread-test--work-request new-work)))
            (should
             (equal (proofread--scheduled-work-cache-key old-work)
                    (proofread--scheduled-work-cache-key new-work)))
            (should (equal (plist-get new-request :source-label)
                           "new-model"))
            (should (eq (proofread--apply-cache-entry new-work entry)
                        'applied))
            (let ((live (car proofread--diagnostics)))
              (should (equal (plist-get live :source-label)
                             "new-model"))
              (should (eq (plist-get live :source) 'test))
              (should (eq (plist-get live :backend-extra) 'kept))
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
             (first-work
              (proofread-test--make-request-work
               chunk proofread-test--backend (car checkers)
               profile))
             (second-work
              (proofread-test--make-request-work
               chunk proofread-test--backend (cadr checkers)
               profile))
             (first-request
              (proofread-test--work-request first-work))
             (second-request
              (proofread-test--work-request second-work))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 5 "helo")))
        (should (eq (proofread--handle-backend-result
                     first-work
                     (proofread--backend-partial-success-result
                      first-request (list diagnostic)))
                    'applied))
        (should (eq (proofread--handle-backend-result
                     second-work
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
           (strict-work
            (proofread-test--make-request-work
             chunk proofread-test--backend strict profile))
           (gentle-work
            (proofread-test--make-request-work
             chunk proofread-test--backend gentle profile))
           (strict-relaxed-work
            (proofread-test--make-request-work
             chunk proofread-test--backend strict-relaxed profile)))
      (should-not
       (equal (proofread--scheduled-work-cache-key strict-work)
              (proofread--scheduled-work-cache-key gentle-work)))
      (should-not
       (equal (proofread--scheduled-work-cache-key strict-work)
              (proofread--scheduled-work-cache-key
               strict-relaxed-work))))))

(ert-deftest
    proofread-test-profile-cache-key-uses-backend-checker-identity ()
  "Let backend checker identity own snapshotted options in cache keys."
  (let ((proofread--backend-registry (make-hash-table :test #'eq))
        identity-checkers)
    (proofread-register-backend
     proofread-test--backend
     :check (lambda (_request _callback) nil)
     :identity
     (lambda ()
       '( :backend proofread-test-backend
          :contract-version 1))
     :snapshot-options #'proofread-test--snapshot-checker-options
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
             (formal-a-work
              (proofread-test--make-request-work
               chunk proofread-test--backend formal-a profile))
             (formal-b-work
              (proofread-test--make-request-work
               chunk proofread-test--backend formal-b profile))
             (relaxed-work
              (proofread-test--make-request-work
               chunk proofread-test--backend relaxed profile)))
        (should
         (equal (proofread--scheduled-work-cache-key formal-a-work)
                (proofread--scheduled-work-cache-key formal-b-work)))
        (should-not
         (equal (proofread--scheduled-work-cache-key formal-a-work)
                (proofread--scheduled-work-cache-key relaxed-work)))
        (should
         (cl-every
          (lambda (checker)
            (not (plist-member checker :checker-ordinal)))
          identity-checkers))
        (should-not
         (string-match-p
          (regexp-quote "secret-a")
          (prin1-to-string
           (proofread--scheduled-work-cache-key formal-a-work))))))))

(ert-deftest proofread-test-cache-contract-v5-isolates-v4-namespace
    ()
  "Keep provenance-bearing cache entries out of the namespace."
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
               (profile (proofread--current-profile))
               (checker
                (proofread-test--current-profile-checker profile))
               (work
                (proofread-test--make-request-work
                 chunk proofread-test--backend checker profile))
               (new-key (proofread--scheduled-work-cache-key work))
               (v4-key (copy-tree new-key)))
          (setf (plist-get v4-key :contract-version) 4)
          (should (= proofread--contract-version 5))
          (should (= (plist-get new-key :contract-version) 5))
          (should (= (plist-get v4-key :contract-version) 4))
          (should (plist-member new-key :checker))
          (should (plist-member new-key :display-language))
          (should (proofread--cache-write v4-key 'old-value))
          (should (eq (proofread--cache-read v4-key) 'old-value))
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
               (profile (proofread--current-profile))
               (checker
                (proofread-test--current-profile-checker profile))
               (work
                (proofread-test--make-request-work
                 chunk proofread-test--backend checker profile))
               (request (proofread-test--work-request work)))
          (should (proofread--request-current-checker-p request))
          (should (proofread--fresh-request-p work))
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
              (let ((incomplete-work
                     (proofread--make-request-work
                      incomplete-request)))
                (should-not
                 (proofread--fresh-request-p incomplete-work))))))))))

(ert-deftest
    proofread-test-profile-checker-change-makes-request-stale
    ()
  "Reject requests after profile language or checker identity changes."
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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile)))
        (should (proofread--fresh-request-p work))
        (let ((proofread-profiles
               `((multi
                  :language "fr"
                  :checkers
                  (( :name strict
                     :backend ,proofread-test--backend
                     :options ( :tone formal)))))))
          (should-not (proofread--fresh-request-p work)))
        (let ((proofread-profiles
               `((multi
                  :language "en-US"
                  :checkers
                  (( :name strict
                     :backend ,proofread-test--backend
                     :options ( :tone relaxed)))))))
          (should-not (proofread--fresh-request-p work)))))))

(ert-deftest
    proofread-test-backend-options-snapshot-defines-cache-freshness ()
  "Use backend-normalized options for cache and freshness identity."
  (let* ((backend 'proofread-test-normalizing-options-backend)
         (proofread--backend-registry (make-hash-table :test #'eq))
         (snapshot-calls 0))
    (proofread-register-backend
     backend
     :check #'ignore
     :identity
     (lambda ()
       (list :backend backend :contract-version 1))
     :snapshot-options
     (lambda (options)
       (setq snapshot-calls (1+ snapshot-calls))
       (list :tone (downcase (plist-get options :tone)))))
    (with-temp-buffer
      (insert "Alpha")
      (let* ((raw-tone (copy-sequence "FORMAL"))
             (proofread-auto-check nil)
             (proofread-context-size 0)
             (proofread-profile 'multi)
             (proofread-profiles
              (list
               (list
                'multi
                :checkers
                (list
                 (list :name 'only
                       :backend backend
                       :options
                       (list :tone raw-tone
                             :volatile '( first))))))))
        (proofread-mode 1)
        (let* ((profile (proofread--current-profile))
               (checker (car (plist-get profile :checkers)))
               (chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
               (work
                (proofread-test--make-request-work
                 chunk backend checker profile))
               (request (proofread-test--work-request work)))
          (should (equal (plist-get request :checker-options)
                         '( :tone "formal")))
          (aset raw-tone 0 ?X)
          (should (equal (plist-get request :checker-options)
                         '( :tone "formal")))
          (setq proofread-profiles
                (list
                 (list
                  'multi
                  :checkers
                  (list
                   (list :name 'only
                         :backend backend
                         :options
                         '( :tone "formal"
                            :volatile (second)))))))
          (should (proofread--request-current-checker-p request))
          (should (proofread--fresh-request-p work))
          (let* ((equivalent-profile (proofread--current-profile))
                 (equivalent-checker
                  (car (plist-get equivalent-profile :checkers)))
                 (equivalent-work
                  (proofread-test--make-request-work
                   chunk backend equivalent-checker
                   equivalent-profile)))
            (should
             (equal (proofread--scheduled-work-cache-key
                     equivalent-work)
                    (proofread--scheduled-work-cache-key work))))
          (setq proofread-profiles
                (list
                 (list
                  'multi
                  :checkers
                  (list
                   (list :name 'only
                         :backend backend
                         :options '( :tone "relaxed"))))))
          (should-not (proofread--request-current-checker-p request))
          (should-not (proofread--fresh-request-p work))
          (let* ((changed-profile (proofread--current-profile))
                 (changed-checker
                  (car (plist-get changed-profile :checkers)))
                 (changed-work
                  (proofread-test--make-request-work
                   chunk backend changed-checker changed-profile)))
            (should-not
             (equal (proofread--scheduled-work-cache-key changed-work)
                    (proofread--scheduled-work-cache-key work))))
          (should (> snapshot-calls 1)))))))

(ert-deftest proofread-test-hash-option-snapshot-is-cache-stable ()
  "Keep backend-normalized hash options comparable across snapshots."
  (with-temp-buffer
    (insert "Alpha")
    (let* ((table (make-hash-table :test #'eq))
           (key (copy-sequence "key"))
           (proofread-auto-check nil)
           (proofread-context-size 0)
           (proofread-profile 'hash-options)
           (proofread-profiles
            (list
             (list
              'hash-options
              :checkers
              (list
               (list :name 'only
                     :backend proofread-test--backend
                     :options (list :table table)))))))
      (puthash key (list "value") table)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker (car (plist-get profile :checkers)))
             (chunk
              (car
               (proofread-test--request-ready-chunks-for-ranges
                (list (cons (point-min) (point-max))))))
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (current-profile (proofread--current-profile))
             (current-checker
              (car (plist-get current-profile :checkers)))
             (equivalent-work
              (proofread-test--make-request-work
               chunk proofread-test--backend current-checker
               current-profile)))
        (should (proofread--request-current-checker-p request))
        (should (proofread--fresh-request-p work))
        (should
         (equal (proofread--scheduled-work-cache-key equivalent-work)
                (proofread--scheduled-work-cache-key work)))
        (aset key 0 ?X)
        (should-not (proofread--request-current-checker-p request))
        (should-not (proofread--fresh-request-p work))))))

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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend checker profile))
             (request (proofread-test--work-request work))
             (diagnostic
              (proofread-test--diagnostic-for-range
               1 6 "Alpha")))
        (should (equal (plist-get request :display-language)
                       "English"))
        (proofread--cache-write-request work (list diagnostic))
        (let ((proofread-profiles
               `((multi
                  :language "en-US"
                  :display-language "American English"
                  :checkers
                  (( :name strict
                     :backend ,proofread-test--backend))))))
          (should-not (proofread--fresh-request-p work))
          (let* ((changed-profile (proofread--current-profile))
                 (changed-checker
                  (car (plist-get changed-profile :checkers)))
                 (changed-work
                  (proofread-test--make-request-work
                   chunk proofread-test--backend changed-checker
                   changed-profile))
                 (changed-request
                  (proofread-test--work-request changed-work)))
            (should (equal (plist-get changed-request :language)
                           (plist-get request :language)))
            (should (equal
                     (plist-get changed-request :display-language)
                     "American English"))
            (should-not
             (equal (proofread--scheduled-work-cache-key changed-work)
                    (proofread--scheduled-work-cache-key work)))
            (should-not
             (proofread--cache-read-request changed-work))))))))

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
      (let ((proofread-test--backend-check-function
             (lambda (request _callback)
               (list :backend proofread-test--backend
                     :request-id (plist-get request :id)))))
        (proofread-check-region (point-min) (point-max))
        (should (= (length proofread--active-requests) 1))
        (should (= (proofread--request-queue-length) 1))
        (let ((owners
               (mapcar
                (lambda (work)
                  (plist-get (proofread-test--work-request work)
                             :checker-name))
                (append
                 proofread--active-requests
                 (proofread--request-queue-works)))))
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
          (let ((work (car proofread--active-requests)))
            (proofread--clear-request-work)
            (should (= (length cancelled) 1))
            (should (eq (car cancelled) handle))
            (should (equal (prin1-to-string handle)
                           printed-handle))
            (should
             (proofread--request-state-flag-p work :cancelled))
            (proofread-test--assert-no-pending-request-work)
            (proofread--clear-request-work)
            (should (= (length cancelled) 1))))))))

(ert-deftest
    proofread-test-cancellation-keeps-captured-cancel-operation ()
  "Use the captured cancel operation after registry replacement or removal."
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
          (let ((work (car proofread--active-requests)))
            (pcase transition
              ('unregister
               (proofread-unregister-backend backend))
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
             (proofread--request-state-flag-p work :cancelled))
            (proofread-test--assert-no-pending-request-work)))))))

(ert-deftest
    proofread-test-submission-captures-descriptor-check-cancel-pair ()
  "Capture check and cancel before invoking the registered check operation."
  (let* ((backend 'proofread-test-descriptor-pair-backend)
         (handle (make-symbol "proofread-test-descriptor-pair-handle"))
         (proofread--backend-registry (make-hash-table :test #'eq))
         (old-check-calls 0)
         (new-check-calls 0)
         old-cancelled
         new-cancelled)
    (proofread-test--register-cancellable-backend
     backend
     (lambda (_request _callback)
       (setq old-check-calls (1+ old-check-calls))
       (proofread-test--register-cancellable-backend
        backend
        (lambda (&rest _)
          (setq new-check-calls (1+ new-check-calls))
          'proofread-test-replacement-handle)
        (lambda (backend-handle)
          (push backend-handle new-cancelled)))
       handle)
     (lambda (backend-handle)
       (push backend-handle old-cancelled)))
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread-profile 'descriptor-pair)
            (proofread-profiles
             (list
              (list
               'descriptor-pair
               :checkers
               (list (list :name 'only :backend backend))))))
        (proofread-mode 1)
        (proofread-check-buffer)
        (should (= old-check-calls 1))
        (should (zerop new-check-calls))
        (should (= (length proofread--active-requests) 1))
        (let ((work (car proofread--active-requests)))
          (proofread--clear-request-work)
          (should (equal old-cancelled (list handle)))
          (should-not new-cancelled)
          (should
           (proofread--request-state-flag-p work :cancelled))
          (proofread-test--assert-no-pending-request-work))))))

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
        (let ((works (copy-sequence proofread--active-requests)))
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
          (dolist (work works)
            (should
             (proofread--request-state-flag-p work :cancelled)))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest
    proofread-test-terminal-event-settles-when-hook-warning-signals ()
  "Settle final and cancelled batches after hook reporting signals."
  (dolist (type '( final-result cancelled))
    (with-temp-buffer
      (let* ((work
              (proofread-test--lifecycle-request
               (if (eq type 'final-result) 501 502) 1 2))
             (request (proofread-test--work-request work))
             (batch (proofread--attach-request-batch (list work)))
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
               work type
               :result
               (proofread--backend-success-result request nil)
               :status 'applied))
             ('cancelled
              (proofread--record-request-event
               work type :reason 'cleared)))))
        (should (= (length reports) 1))
        (should
         (equal (caar reports)
                "Proofread request log hook error (error)"))
        (proofread-test--assert-secret-not-printed
         "Sensitive request hook failure" reports)
        (should (zerop (plist-get batch :pending)))
        (should (proofread--scheduled-work-batch-settled work))))))

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
        (let ((work (car proofread--active-requests)))
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
           (proofread--request-state-flag-p work :cancelled))
          (should-not proofread--idle-timer)
          (should-not proofread--queue-dispatch-timer)
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest proofread-test-backend-registry-routes-submission
    ()
  "Route submission through a registered backend descriptor."
  (let* ((proofread--backend-registry
          (make-hash-table :test #'eq))
         (cancel (lambda (_handle)
                   (error "Unexpected cancellation")))
         checked
         result)
    (proofread-register-backend
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
     :snapshot-options #'proofread-test--snapshot-checker-options
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
    (with-temp-buffer
      (insert "Alpha")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 0)
            (proofread-context-size 0)
            (proofread-profile proofread-test--profile)
            (proofread-profiles (proofread-test--profiles)))
        (proofread-mode 1)
        (let* ((chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      (list (cons (point-min) (point-max))))))
               (request (proofread-test--make-profile-request chunk))
               (work (proofread--make-request-work request))
               (handle
                (proofread--dispatch-backend-request
                 work
                 (lambda (backend-result)
                   (setq result backend-result)))))
          (should (eq checked request))
          (should (eq handle 'proofread-test-registry-handle))
          (should-not result)
          (should (proofread-test--wait-for (lambda () result)))
          (should (eq (plist-get result :status) 'ok)))))
    (proofread-unregister-backend proofread-test--backend)
    (should-not
     (proofread--supported-backend-p proofread-test--backend))))

(ert-deftest proofread-test-backend-registry-validates-source-label
    ()
  "Reject a non-callable backend source-label operation."
  (let ((proofread--backend-registry (make-hash-table :test #'eq)))
    (should-error
     (proofread-register-backend
      proofread-test--backend
      :check #'ignore
      :identity #'proofread-test--backend-identity
      :snapshot-options #'proofread-test--snapshot-checker-options
      :source-label 'not-callable))
    (should-not
     (gethash proofread-test--backend proofread--backend-registry))))

(ert-deftest proofread-test-backend-registry-requires-options-snapshot
    ()
  "Reject absent, non-callable, duplicate, and unknown operations."
  (let ((proofread--backend-registry (make-hash-table :test #'eq))
        (base
         (list :check #'ignore
               :identity #'proofread-test--backend-identity)))
    (dolist
        (descriptor
         (list
          base
          (append base '( :snapshot-options not-callable))
          (append
           base
           (list :snapshot-options
                 #'proofread-test--snapshot-checker-options
                 :snapshot-options
                 #'proofread-test--snapshot-checker-options))
          (append
           base
           (list :snapshot-options
                 #'proofread-test--snapshot-checker-options
                 :unknown-operation #'ignore))))
      (should-error
       (apply #'proofread-register-backend
              proofread-test--backend descriptor))
      (should-not
       (gethash proofread-test--backend
                proofread--backend-registry)))))

(ert-deftest proofread-test-backend-options-snapshot-must-be-plist ()
  "Reject every malformed checker options snapshot envelope."
  (dolist (invalid
           (list [:tone formal]
                 '( :tone . formal)
                 '( :tone)
                 '(tone formal)))
    (let ((proofread--backend-registry
           (make-hash-table :test #'eq)))
      (proofread-register-backend
       proofread-test--backend
       :check #'ignore
       :identity #'proofread-test--backend-identity
       :snapshot-options (lambda (_options) invalid))
      (should-error
       (proofread--checker-with-options-snapshot
        (list :profile 'multi
              :name 'only
              :backend proofread-test--backend
              :options '( :tone formal))))))
  (let* ((cycle (list :tone 'formal))
         (tail (last cycle))
         (proofread--backend-registry
          (make-hash-table :test #'eq)))
    (setcdr tail cycle)
    (unwind-protect
        (progn
          (proofread-register-backend
           proofread-test--backend
           :check #'ignore
           :identity #'proofread-test--backend-identity
           :snapshot-options (lambda (_options) cycle))
          (should-error
           (proofread--checker-with-options-snapshot
            (list :profile 'multi
                  :name 'only
                  :backend proofread-test--backend
                  :options '( :tone formal)))))
      (setcdr tail nil))))

(ert-deftest proofread-test-backend-registry-lazily-loads-feature ()
  "Load a known backend feature once before resolving its descriptor."
  (let ((proofread--backend-features
         '((proofread-test-lazy . proofread-test-lazy-feature)))
        (proofread--backend-registry (make-hash-table :test #'eq))
        loaded-feature)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (setq loaded-feature feature)
                 (proofread-register-backend
                  'proofread-test-lazy
                  :check (lambda (_request _callback) 'test-handle)
                  :identity
                  (lambda ()
                    '( :backend proofread-test-lazy
                       :contract-version 1))
                  :snapshot-options
                  #'proofread-test--snapshot-checker-options)
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
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (descriptor-calls 0)
           (original-descriptor
            (symbol-function 'proofread--backend-descriptor))
           (request
            (let ((request
                   (cl-letf
                       (((symbol-function 'proofread--backend-descriptor)
                         (lambda (backend)
                           (setq descriptor-calls
                                 (1+ descriptor-calls))
                           (funcall original-descriptor backend))))
                     (proofread--make-backend-request
                      chunk 'unknown-backend))))
              (setq request (plist-put request :checker-owner nil))
              (plist-put request :checker-identity nil)))
           (work (proofread--make-request-work request))
           result)
      (should (= descriptor-calls 1))
      (should
       (eq (plist-get request :checker-identity)
           (plist-get (proofread--scheduled-work-cache-key work)
                      :checker)))
      (should-not (proofread--supported-backend-p 'unknown-backend))
      (should (proofread--dispatch-backend-request
               work
               (lambda (backend-result)
                 (setq result backend-result))))
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
          (dolist (key '( :cache-key :log-id :state :batch :handle))
            (should-not (plist-member request key)))
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
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (request
            (let ((request
                   (proofread--make-backend-request
                    chunk 'unknown-backend)))
              (setq request (plist-put request :checker-owner nil))
              (plist-put request :checker-identity nil)))
           (work (proofread--make-request-work request))
           result)
      (should (proofread--dispatch-backend-request
               work
               (lambda (backend-result)
                 (setq result backend-result))))
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
             (work (proofread--make-request-work request))
             result
             active-at-callback)
        (should (proofread--dispatch-backend-request
                 work
                 (lambda (backend-result)
                   (setq result backend-result)
                   (with-current-buffer buffer
                     (setq active-at-callback
                           proofread--active-requests)))))
        (should (proofread--active-request-p work))
        (should (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'ok))
        (should-not active-at-callback)
        (should-not (proofread--active-request-p work))))))

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
             (work (proofread--make-request-work request))
             result
             active-at-callback)
        (should
         (proofread--dispatch-backend-request
          work
          (lambda (backend-result)
            (setq result backend-result)
            (with-current-buffer buffer
              (setq active-at-callback
                    proofread--active-requests)))))
        (should (proofread--active-request-p work))
        (should
         (proofread-test--wait-for (lambda () result)))
        (should (eq (plist-get result :status) 'error))
        (should (equal (buffer-string) before-text))
        (should-not active-at-callback)
        (should-not
         (proofread--active-request-p work))))))

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
                (let ((proofread-test--backend-check-function
                       (lambda (request callback)
                         (push request requests)
                         (push callback callbacks)
                         'proofread-test-handle)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
                    (proofread-check-visible-range)
                    (setq requests (nreverse requests))
                    (should (equal (mapcar (lambda (request)
                                             (plist-get request :text))
                                           requests)
                                   '( "Alpha " " Beta")))
                    (should (= (length callbacks) 2))
                    (should (= (length proofread--active-requests) 2))
                    (should-not proofread--diagnostics)
                    (should-not (proofread-test--flymake-proofread-diagnostics)))))))
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
                (let ((proofread-test--backend-check-function
                       (lambda (request callback)
                         (push request requests)
                         (push callback callbacks)
                         'proofread-test-handle)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
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
                               3)))))))
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
                (let ((proofread-test--backend-check-function
                       (plist-get recorder :function)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
                    (proofread-show-buffer-requests buffer)
                    (proofread-check-visible-range)
                    (should (= (length (funcall
                                        (plist-get recorder :requests)))
                               2))
                    (should (= (length proofread--active-requests) 2))
                    (should (= (proofread--request-queue-length) 1))
                    (proofread-check-visible-range)
                    (should (= (length (funcall
                                        (plist-get recorder :requests)))
                               2))
                    (should (= (length proofread--active-requests) 2))
                    (should (= (proofread--request-queue-length) 1))
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
                              (mapcar (lambda (work)
                                        (plist-get
                                         (proofread-test--work-request work)
                                         :id))
                                      proofread--active-requests)))
                        (should (= (length all-requests) 3))
                        (should (= (length proofread--active-requests)
                                   2))
                        (should (proofread--request-queue-empty-p))
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
                                        active-ids)))))))))
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
        (let ((proofread-test--backend-check-function
               (lambda (_request _callback)
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
            (let ((request
                   (proofread-test--work-request
                    (car proofread--active-requests))))
              (should (eq (plist-get request :buffer) first-buffer))
              (should (eq (plist-get request :profile)
                          'first-profile))
              (should (eq (plist-get request :checker-name)
                          'first-checker))))
          (with-current-buffer second-buffer
            (should (= (length proofread--active-requests) 1))
            (let ((request
                   (proofread-test--work-request
                    (car proofread--active-requests))))
              (should (eq (plist-get request :buffer) second-buffer))
              (should (eq (plist-get request :profile)
                          'second-profile))
              (should (eq (plist-get request :checker-name)
                          'second-checker)))))
      (kill-buffer first-buffer)
      (kill-buffer second-buffer))))

(ert-deftest
    proofread-test-fresh-result-records-and-publishes-diagnostics ()
  "Fresh successful results update the model and Flymake publication."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-fresh-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let (request
                  callback
                  work)
              (proofread-test--with-profile
                (let ((proofread-test--backend-check-function
                       (lambda (backend-request backend-callback)
                         (setq request backend-request)
                         (setq callback backend-callback)
                         'proofread-test-handle)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
                    (proofread-check-visible-range)
                    (setq work (car proofread--active-requests))
                    (should (eq (proofread-test--work-request work)
                                request))
                    (should (proofread--active-request-p work))
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
                      (should
                       (= (length
                           (proofread-test--flymake-proofread-diagnostics))
                          1))
                      (should (= (length (flymake-diagnostics)) 1))
                      (should-not (proofread--active-request-p
                                   work))))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-live-range-does-not-mutate-backend-result
    ()
  "Keep stored diagnostics and backend results immutable after edits."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (work (proofread--make-request-work request))
             (diagnostic
              (proofread-test--diagnostic-for-range 1 5 "helo"))
             (result
              (proofread--backend-success-result
               request (list diagnostic))))
        (should (eq (proofread--handle-backend-result work result)
                    'applied))
        (let ((live (car proofread--diagnostics)))
          (should-not (eq live diagnostic))
          (goto-char (point-min))
          (insert "x")
          (should (equal (proofread--diagnostic-range live)
                         '( 1 . 5)))
          (should (equal (proofread-diagnostic-range live)
                         '( 2 . 6)))
          (should
           (equal (proofread--diagnostic-range diagnostic)
                  '( 1 . 5)))
          (should (eq (car (plist-get result :diagnostics))
                      diagnostic)))))))

(ert-deftest
    proofread-test-context-does-not-shift-diagnostic-range ()
  "Do not shift the accepted Flymake range for sentence context."
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
               (work (proofread--make-request-work request))
               (diagnostic
                (proofread-test--diagnostic-for-range
                 (plist-get request :beg)
                 (+ (plist-get request :beg) 2)
                 "目标")))
          (should (equal (plist-get request :context-before) "前文。"))
          (should (equal (plist-get request :context-after) "后文。"))
          (should (eq (proofread--handle-backend-result
                       work
                       (proofread--backend-success-result
                        request (list diagnostic)))
                      'applied))
          (should
           (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
          (let ((flymake-diagnostic (car (flymake-diagnostics))))
            (should (= (flymake-diagnostic-beg flymake-diagnostic)
                       (plist-get diagnostic :beg)))
            (should (= (flymake-diagnostic-end flymake-diagnostic)
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
        (let ((proofread-test--backend-check-function
               (lambda (backend-request backend-callback)
                 (setq request backend-request)
                 (setq callback backend-callback)
                 'proofread-test-handle)))
          (cl-letf (((symbol-function 'window-start)
                     (lambda (&optional _window) (point-min)))
                    ((symbol-function 'window-end)
                     (lambda (&optional _window _update) (point-max))))
            (proofread-check-visible-range))))
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
                  callback
                  work)
              (proofread-test--with-profile
                (let ((proofread-test--backend-check-function
                       (lambda (backend-request backend-callback)
                         (setq request backend-request)
                         (setq callback backend-callback)
                         'proofread-test-handle)))
                  (cl-letf (((symbol-function 'window-start)
                             (lambda (&optional _window) (point-min)))
                            ((symbol-function 'window-end)
                             (lambda (&optional _window _update)
                               (point-max))))
                    (proofread-check-visible-range)
                    (setq work (car proofread--active-requests))
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
                    (should-not (proofread-test--flymake-proofread-diagnostics))
                    (should-not (proofread--active-request-p work))
                    (should-not proofread--active-requests))))))
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
                  callback
                  work)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update) 5))
                          (proofread-test--backend-check-function
                           (lambda (backend-request
                                    backend-callback)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (setq work (car proofread--active-requests))
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
                  (should-not (proofread-test--flymake-proofread-diagnostics))
                  (should-not (proofread--active-request-p
                               work))))))
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
                  callback
                  work)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update) 5))
                          (proofread-test--backend-check-function
                           (lambda (backend-request
                                    backend-callback)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (setq work (car proofread--active-requests))
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
                  (should-not (proofread-test--flymake-proofread-diagnostics))
                  (should-not (proofread--active-request-p
                               work))))))
        (kill-buffer buffer)))))

(ert-deftest proofread-test-backend-error-result-publishes-no-diagnostics
    ()
  "Backend error results preserve text and publish no diagnostics."
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *proofread-error-result*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "helo world")
            (proofread-mode 1)
            (let ((before-text (buffer-string))
                  request
                  callback
                  work)
              (proofread-test--with-profile
                (cl-letf (((symbol-function 'window-start)
                           (lambda (&optional _window) (point-min)))
                          ((symbol-function 'window-end)
                           (lambda (&optional _window _update)
                             (point-max)))
                          (proofread-test--backend-check-function
                           (lambda (backend-request
                                    backend-callback)
                             (setq request backend-request)
                             (setq callback backend-callback)
                             'proofread-test-handle)))
                  (proofread-check-visible-range)
                  (setq work (car proofread--active-requests))
                  (should (eq (funcall
                               callback
                               (proofread--backend-error-result
                                request 'proofread-test-backend-failure
                                "Test backend failure"))
                              'error))
                  (should (equal (buffer-string) before-text))
                  (should-not proofread--diagnostics)
                  (should-not (proofread-test--flymake-proofread-diagnostics))
                  (should-not (proofread--active-request-p
                               work))))))
        (kill-buffer buffer)))))

(ert-deftest
    proofread-test-warning-report-preserves-detail-and-shortens-echo
    ()
  "Log full background warnings but echo a short summary."
  (let* ((detail (concat "Backend detail line one\n"
                         (make-string 600 ?x)))
         (summary (concat "　backend\trequest\r\nfailed　"
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
      (with-temp-buffer
        (set-syntax-table (copy-syntax-table (syntax-table)))
        (modify-syntax-entry ?\n ".")
        (modify-syntax-entry ?\r ".")
        (proofread-report-warning-without-window detail summary)))
    (should (equal captured-warning-args
                   (list 'proofread detail :warning)))
    (should (eq captured-minimum-level :error))
    (should captured-truncation)
    (should (string-prefix-p "proofread: backend request failed "
                             captured-echo))
    (should (<= (string-width captured-echo) 120))
    (should-not (string-match-p "[\n\r]" captured-echo))))

(ert-deftest
    proofread-test-checker-failure-cleans-before-truncating-warning ()
  "Clean checker failure warnings before bounding their width."
  (with-temp-buffer
    (set-syntax-table (copy-syntax-table (syntax-table)))
    (modify-syntax-entry ?\n ".")
    (modify-syntax-entry ?\r ".")
    (let* ((raw-message
            (concat "　First\n\tsecond\rthird　"
                    (make-string 400 ?x)))
           (failure
            (list :profile 'multi
                  :checker-name 'failed
                  :backend proofread-test--backend
                  :phase 'request-construction
                  :error 'error
                  :message raw-message))
           (proofread-request-log-hook nil)
           captured-detail)
      (cl-letf
          (((symbol-function
             'proofread-report-warning-without-window)
            (lambda (detail _summary)
              (setq captured-detail detail))))
        (proofread--report-checker-dispatch-failure failure))
      (should (string-prefix-p "First second third "
                               captured-detail))
      (should (<= (string-width captured-detail) 320))
      (should-not (string-match-p "[\t\n\r　]"
                                  captured-detail)))))

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
                    (proofread-test--backend-check-function
                     (plist-get recorder :function)))
            (should (= (length
                        (proofread-test--dispatch-profile-chunks
                         chunks))
                       4))
            (let* ((requests
                    (funcall (plist-get recorder :requests)))
                   (works
                    (mapcar #'proofread--scheduled-work-for-request
                            requests))
                   (callbacks
                    (funcall (plist-get recorder :callbacks))))
              (should (= (length requests) 4))
              (should (cl-every #'proofread--scheduled-work-p works))
              (should
               (cl-every #'proofread--scheduled-work-batch works))
              (should
               (cl-every
                (lambda (work)
                  (eq (proofread--scheduled-work-batch work)
                      (proofread--scheduled-work-batch (car works))))
                (cdr works)))
              (dotimes (index 4)
                (funcall
                 (nth index callbacks)
                 (proofread--backend-error-result
                  (nth index requests)
                  'proofread-test-backend-invalid-diagnostics
                  (format "Failure kind %d" index)))
                (should (= (length warnings) (if (= index 3) 1 0))))
              (proofread-test--assert-requests-settled works)
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
              (let ((proofread-test--backend-check-function
                     (plist-get second-recorder :function)))
                (proofread-test--dispatch-profile-chunks
                 (cl-subseq chunks 0 2))
                (let* ((requests
                        (funcall
                         (plist-get second-recorder :requests)))
                       (works
                        (mapcar #'proofread--scheduled-work-for-request
                                requests))
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
                   (cadr works) nil 'test-cancelled)
                  (should (= (length warnings) 2))
                  (proofread-test--assert-requests-settled works))))
            (let* ((direct
                    (proofread-test--make-profile-request
                     (car chunks)))
                   (work (proofread--make-request-work direct)))
              (should
               (eq (proofread--handle-backend-result
                    work
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
      (proofread-test--publish-diagnostics (list first second))
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
      (proofread-test--publish-diagnostics
       (list same-start-long invalid-beg last invalid-backward
             same-start-short first))
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
      (proofread-test--publish-diagnostics
       (list third invalid first second))
      (let ((entries (proofread--navigation-entries t)))
        (should
         (eq (car (proofread--next-navigation-entry-after
                   1 entries))
             first))
        (should
         (eq (car (proofread--next-navigation-entry-after
                   3 entries))
             second))
        (should
         (eq (car (proofread--next-navigation-entry-after
                   6 entries))
             third))
        (should-not
         (proofread--next-navigation-entry-after 9 entries))
        (should-not
         (proofread--previous-navigation-entry-before 3 entries))
        (should
         (eq (car (proofread--previous-navigation-entry-before
                   6 entries))
             first))
        (should
         (eq (car (proofread--previous-navigation-entry-before
                   9 entries))
             second))
        (should
         (eq (car (proofread--previous-navigation-entry-before
                   11 entries))
             third))))))

(ert-deftest
    proofread-test-navigation-treats-zero-width-diagnostic-as-current
    ()
  "Navigate from a zero-width diagnostic through equal-start entries."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let ((zero (proofread-test--diagnostic-for-range 3 3 ""))
          (nonempty
           (proofread-test--diagnostic-for-range 3 5 "cd")))
      (proofread-test--publish-diagnostics (list nonempty zero))
      (setq proofread--current-diagnostic zero)
      (should
       (eq (car (proofread--next-navigation-entry-after
                 3 (proofread--navigation-entries t)))
           nonempty))
      (setq proofread--current-diagnostic nonempty)
      (should
       (eq (car (proofread--previous-navigation-entry-before
                 3 (proofread--navigation-entries t)))
           zero)))))

(ert-deftest
    proofread-test-navigation-recognizes-fresh-zero-width-aggregate
    ()
  "Continue through an equivalent aggregate freshly built by Flymake UI."
  (with-temp-buffer
    (insert "abcdef")
    (proofread-mode 1)
    (let* ((first
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 3 3 "")
             'first))
           (second
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 3 3 "")
             'second))
           (nonempty
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 3 5 "cd")
             'third)))
      (proofread-test--publish-diagnostics
       (list first second nonempty))
      (should
       (= (length (proofread-test--flymake-proofread-diagnostics)) 3))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (should
       (equal (proofread--diagnostic-members
               proofread--current-diagnostic)
              (list first second)))
      (proofread-next)
      (should (= (point) 3))
      (should (eq proofread--current-diagnostic nonempty))
      (proofread-previous)
      (should (= (point) 3))
      (should
       (equal (proofread--diagnostic-members
               proofread--current-diagnostic)
              (list first second)))
      (should-error (proofread-previous) :type 'user-error)
      (proofread-next)
      (should (eq proofread--current-diagnostic nonempty))
      (should-error (proofread-next) :type 'user-error))))

(ert-deftest
    proofread-test-proofread-next-moves-to-nearest-diagnostic ()
  "`proofread-next' moves point to the nearest later diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--publish-diagnostics (list second first))
      (should
       (= (length (proofread-test--flymake-proofread-diagnostics)) 2))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (should (equal proofread--current-diagnostic first))
      (proofread-next)
      (should (= (point) 7))
      (should (equal proofread--current-diagnostic second)))))

(ert-deftest proofread-test-navigation-and-list-use-flymake-accessors
    ()
  "Read UI positions from Flymake rather than transitional live markers."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-for-range 3 4 "c")))
      (proofread-test--publish-diagnostics (list diagnostic))
      (should
       (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
      (let* ((flymake-diagnostic
              (car (proofread--owned-flymake-diagnostics)))
             (data (flymake-diagnostic-data flymake-diagnostic)))
        (set-marker (proofread--flymake-data-live-beg-marker data) 7)
        (set-marker (proofread--flymake-data-live-end-marker data) 8))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (should
       (equal (proofread--diagnostic-line-column diagnostic)
              '( 1 . 2)))
      (let ((columns
             (cadr (car (proofread--diagnostics-list-entries)))))
        (should (equal (aref columns 0) "1"))
        (should (equal (aref columns 1) "2"))))))

(ert-deftest
    proofread-test-proofread-previous-moves-to-nearest-diagnostic ()
  "Move to the nearest earlier diagnostic with `proofread-previous'."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--publish-diagnostics (list second first))
      (should
       (= (length (proofread-test--flymake-proofread-diagnostics)) 2))
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
      (proofread-test--publish-diagnostics (list first second))
      (goto-char 7)
      (should-error (proofread-next) :type 'user-error)
      (should (= (point) 7))
      (goto-char 3)
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) 3)))))

(ert-deftest proofread-test-navigation-ignores-foreign-flymake-diagnostics
    ()
  "Navigate only through diagnostics from the Proofread backend."
  (with-temp-buffer
    (insert "abcdefghij")
    (setq-local proofread-test--flymake-foreign-range '( 5 . 6))
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--publish-diagnostics (list second first))
      (should (= (length (flymake-diagnostics)) 3))
      (should
       (cl-find #'proofread-test--flymake-foreign-backend
                (flymake-diagnostics)
                :key #'flymake-diagnostic-backend))
      (goto-char 1)
      (proofread-next)
      (should (= (point) 3))
      (proofread-next)
      (should (= (point) 7))
      (proofread-previous)
      (should (= (point) 3))
      (should-error (proofread-previous) :type 'user-error)
      (should (= (point) 3)))))

(ert-deftest proofread-test-navigation-tracks-one-current-diagnostic ()
  "Track exactly one Proofread diagnostic as current during navigation."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g")))
      (proofread-test--publish-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (should (eq proofread--current-diagnostic first))
      (proofread-next)
      (should (eq proofread--current-diagnostic second))
      (proofread--clear-current-diagnostic)
      (should-not proofread--current-diagnostic))))

(ert-deftest proofread-test-navigation-preserves-buffer-text ()
  "Navigation commands move point without changing buffer text."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((first (proofread-test--diagnostic-for-range 3 4 "c"))
          (second (proofread-test--diagnostic-for-range 7 8 "g"))
          (text (buffer-string)))
      (proofread-test--publish-diagnostics (list first second))
      (goto-char 1)
      (proofread-next)
      (goto-char (point-max))
      (proofread-previous)
      (should (equal (buffer-string) text)))))

(ert-deftest proofread-test-navigation-clears-current-state ()
  "Clear current diagnostic state with diagnostics or mode disable."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c")))
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread--mark-current-diagnostic diagnostic)
      (should proofread--current-diagnostic)
      (proofread-clear)
      (should-not proofread--current-diagnostic)
      (should-not (proofread-test--flymake-proofread-diagnostics))))
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 3 4 "c")))
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread--mark-current-diagnostic diagnostic)
      (proofread-mode -1)
      (should-not proofread--current-diagnostic)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-lists-current-buffer ()
  "List diagnostics for the source buffer."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo\nbb teh")
      (setq-local flymake-diagnostic-functions
                  (list #'proofread-test--flymake-foreign-backend))
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
              (proofread-test--publish-diagnostics (list second
                                                         first))
              (should
               (= (length
                   (proofread-test--flymake-proofread-diagnostics))
                  2))
              (goto-char 2)
              (proofread-show-buffer-diagnostics)
              (should (= (point) 2))
              (with-current-buffer name
                (should (eq major-mode
                            'proofread-diagnostics-buffer-mode))
                (should (eq next-error-function
                            #'proofread--diagnostics-next-error))
                (should (eq proofread--diagnostics-buffer-source
                            source))
                (should (= (length tabulated-list-entries) 2))
                (should-not
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward "Foreign diagnostic" nil t)))
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
              (proofread-test--publish-diagnostics (list first
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
              (proofread-test--publish-diagnostics
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
      (proofread-test--publish-diagnostics
       (list same-range-different-text different-text
             different-range))
      (should (= (length (proofread--navigation-diagnostics)) 3)))))

(ert-deftest
    proofread-test-show-buffer-diagnostics-selects-fresh-aggregate
    ()
  "Select a list row using an equivalent freshly built aggregate."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo")
      (proofread-mode 1)
      (let* ((earlier
              (proofread-test--diagnostic-with-checker
               (proofread-test--diagnostic-for-range 1 3 "aa")
               'earlier))
             (first
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
              (proofread-test--publish-diagnostics
               (list earlier first second))
              (goto-char 4)
              (let ((aggregate (proofread-diagnostic-at-point)))
                (should
                 (proofread--aggregate-diagnostic-p aggregate))
                (cl-letf (((symbol-function
                            'pulse-momentary-highlight-one-line)
                           (lambda (&rest _args)
                             'highlighted)))
                  (proofread-show-buffer-diagnostics aggregate)))
              (with-current-buffer name
                (let ((selected
                       (plist-get (tabulated-list-get-id)
                                  :diagnostic)))
                  (should
                   (proofread--aggregate-diagnostic-p selected))
                  (should
                   (equal (proofread--diagnostic-members selected)
                          (list first second))))))
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
              (proofread-test--publish-diagnostics (list diagnostic))
              (should
               (= (length
                   (proofread-test--flymake-proofread-diagnostics))
                  1))
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

(ert-deftest proofread-test-show-diagnostic-rejects-stale-list-row ()
  "Reject a list row no longer published by the Flymake bridge."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (insert "aa helo zz")
      (proofread-mode 1)
      (let* ((diagnostic
              (proofread-test--diagnostic-for-range 4 8 "helo"))
             (name (proofread--diagnostics-buffer-name)))
        (unwind-protect
            (progn
              (proofread-test--publish-diagnostics (list diagnostic))
              (proofread-show-buffer-diagnostics)
              (funcall proofread--flymake-report-function
                       nil :region (cons (point-min) (point-max)))
              (should-not (flymake-diagnostics))
              (with-current-buffer name
                (goto-char (point-min))
                (let ((condition
                       (should-error
                        (proofread-show-diagnostic (point))
                        :type 'user-error)))
                  (should
                   (equal (error-message-string condition)
                          "Proofread diagnostic is stale")))))
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
              (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list later long short))
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
      (proofread-test--publish-diagnostics (list first second))
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
               'second)))
        (setq first (plist-put first :checker-ordinal 0))
        (setq different-text
              (plist-put different-text :checker-ordinal 1))
        (setq second (plist-put second :checker-ordinal 2))
        ;; Publish in the inverse of checker order, with a
        ;; different-text entry between aggregate members.
        (proofread-test--publish-diagnostics
         (append (nreverse remote-diagnostics)
                 (list second different-text first)))
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
  "Use only position-scoped Flymake queries for point lookup."
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
                 (original-query
                  (symbol-function 'flymake-diagnostics))
                 queries)
            (proofread-test--publish-diagnostics
             (append (nreverse remote-diagnostics)
                     (list first second)))
            (cl-letf
                (((symbol-function 'flymake-diagnostics)
                  (lambda (&optional beg end)
                    (unless beg
                      (ert-fail
                       "Point lookup made a buffer-wide Flymake query"))
                    (push (list beg end) queries)
                    (funcall original-query beg end))))
              (should
               (proofread--aggregate-diagnostic-p
                (proofread-diagnostic-at-point 1))))
            (should (equal queries '((1 nil))))
            (push (length queries) call-counts)))))
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
      (proofread-test--publish-diagnostics (list same-start zero))
      (should (eq (proofread-diagnostic-at-point 3) zero))))
  (with-temp-buffer
    (insert "abcd")
    (let ((proofread-auto-check nil)
          (zero
           (proofread-test--diagnostic-for-range 3 3 ""))
          (earlier
           (proofread-test--diagnostic-for-range 2 4 "bc")))
      (proofread-mode 1)
      (proofread-test--publish-diagnostics (list zero earlier))
      (should (eq (proofread-diagnostic-at-point 3) earlier)))))

(ert-deftest proofread-test-flymake-backed-range-and-point-follow-edit
    ()
  "Read moved ranges and stable aggregates from Flymake diagnostics."
  (with-temp-buffer
    (insert "xhelo")
    (let ((proofread-auto-check nil)
          (first
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 2 6 "helo")
            'same))
          (second
           (proofread-test--diagnostic-with-checker
            (proofread-test--diagnostic-for-range 2 6 "helo")
            'same)))
      (proofread-mode 1)
      (setq first (plist-put first :checker-ordinal 0))
      (setq second (plist-put second :checker-ordinal 0))
      (proofread-test--publish-diagnostics (list first second))
      (should (= (length (flymake-diagnostics)) 1))
      (goto-char (point-min))
      (insert "y")
      (should (equal (proofread--diagnostic-range first) '(2 . 6)))
      (should (equal (proofread-diagnostic-range first) '(3 . 7)))
      (should-not (proofread-diagnostic-at-point 2))
      (let ((diagnostic (proofread-diagnostic-at-point 3)))
        (should (equal (proofread-diagnostic-range diagnostic)
                       '( 3 . 7)))
        (should (equal (proofread--diagnostic-members diagnostic)
                       (list first second))))
      ;; Preserve Proofread's half-open insertion semantics at both
      ;; endpoints: insertions at either boundary remain outside.
      (goto-char 3)
      (insert "z")
      (should (equal (proofread-diagnostic-range first) '(4 . 8)))
      (should-not (proofread-diagnostic-at-point 3))
      (goto-char 8)
      (insert "q")
      (should (equal (proofread-diagnostic-range first) '(4 . 8)))
      (should-not (proofread-diagnostic-at-point 8)))))

(ert-deftest proofread-test-flymake-backed-point-recovers-zero-width
    ()
  "Recover both zero-width Flymake anchor directions after edits."
  (with-temp-buffer
    (insert "abcd")
    (let ((proofread-auto-check nil)
          (beg-anchor
           (proofread-test--diagnostic-for-range 2 2 ""))
          (end-anchor
           (proofread-test--diagnostic-for-range 5 5 "")))
      (setf (plist-get end-anchor :message) "End anchor")
      (proofread-mode 1)
      (proofread-test--publish-diagnostics
       (list beg-anchor end-anchor))
      (should (= (length (flymake-diagnostics)) 2))
      (should (eq (proofread-diagnostic-at-point 2) beg-anchor))
      (should-not (proofread-diagnostic-at-point 3))
      (should-not (proofread-diagnostic-at-point 4))
      (should (eq (proofread-diagnostic-at-point 5) end-anchor))
      (goto-char (point-min))
      (insert "x")
      (should (equal (proofread-diagnostic-range beg-anchor)
                     '(3 . 3)))
      (should (equal (proofread-diagnostic-range end-anchor)
                     '(6 . 6)))
      (should (eq (proofread-diagnostic-at-point 3) beg-anchor))
      (should (eq (proofread-diagnostic-at-point 6) end-anchor)))))

(ert-deftest proofread-test-flymake-backed-empty-buffer-fallback ()
  "Preserve point lookup where Flymake cannot display an empty anchor."
  (with-temp-buffer
    (let ((proofread-auto-check nil)
          (diagnostic
           (proofread-test--diagnostic-for-range 1 1 "")))
      (proofread-mode 1)
      (setq proofread--diagnostics (list diagnostic))
      (flymake-start)
      (should-not (flymake-diagnostics))
      (should (eq (proofread-diagnostic-at-point) diagnostic))
      (should (equal (proofread--navigation-diagnostics)
                     (list diagnostic)))
      (should (equal (proofread-diagnostic-range diagnostic)
                     '(1 . 1))))))

(ert-deftest proofread-test-flymake-backed-queries-exclude-lookalike
    ()
  "Exclude a foreign backend even when its type and data look owned."
  (with-temp-buffer
    (insert "helo")
    (let* ((proofread-auto-check nil)
           (diagnostic
            (proofread-test--diagnostic-for-range 1 5 "helo"))
           (foreign-backend
            (lambda (report-function &rest _arguments)
              (funcall
               report-function
               (list
                (proofread--diagnostic-to-flymake
                 diagnostic '(0)))))))
      (proofread-mode 1)
      (add-hook 'flymake-diagnostic-functions
                foreign-backend t t)
      (setq proofread--diagnostics (list diagnostic))
      (flymake-start)
      (should (= (length (flymake-diagnostics)) 2))
      (should (= (length (proofread--owned-flymake-diagnostics)) 1))
      (should (eq (proofread-diagnostic-at-point 2) diagnostic))
      (should (equal (proofread--navigation-diagnostics)
                     (list diagnostic))))))

(ert-deftest proofread-test-flymake-backed-queries-require-data-tag ()
  "Reject a bridge diagnostic without Proofread's data wrapper."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil)
          (diagnostic
           (proofread-test--diagnostic-for-range 1 5 "helo")))
      (proofread-mode 1)
      (setq proofread--diagnostics (list diagnostic))
      (cl-letf
          (((symbol-function 'proofread--flymake-diagnostics-snapshot)
            (lambda (&optional _region)
              (list
               (flymake-make-diagnostic
                (current-buffer) 1 5
                proofread--flymake-diagnostic-type
                "Invalid wrapper" '(not-proofread-data))))))
        (flymake-start))
      (should (= (length (flymake-diagnostics)) 1))
      (should-not (proofread--owned-flymake-diagnostics))
      (should-not (proofread-diagnostic-at-point 2))
      (should-not (proofread--navigation-diagnostics)))))

(ert-deftest proofread-test-flymake-backed-queries-preserve-narrowing
    ()
  "Query Flymake ranges widely without changing narrowing semantics."
  (with-temp-buffer
    (insert "abcdefgh")
    (let ((proofread-auto-check nil)
          (hidden
           (proofread-test--diagnostic-for-range 1 4 "abc"))
          (visible
           (proofread-test--diagnostic-for-range 6 8 "fg")))
      (proofread-mode 1)
      (setq proofread--diagnostics (list hidden visible))
      (flymake-start)
      (narrow-to-region 5 9)
      (let ((minimum (point-min))
            (maximum (point-max)))
        (should (equal (proofread-diagnostic-range hidden) '(1 . 4)))
        (should (eq (proofread-diagnostic-at-point 2) hidden))
        (should (equal (proofread--navigation-diagnostics)
                       (list hidden visible)))
        (should (equal (proofread--navigation-diagnostics t)
                       (list visible)))
        (goto-char (point-min))
        (proofread-next)
        (should (= (point) 6))
        (should (eq proofread--current-diagnostic visible))
        (should-error (proofread-previous) :type 'user-error)
        (should (= (point) 6))
        (should (= (point-min) minimum))
        (should (= (point-max) maximum))))))

(ert-deftest
    proofread-test-diagnostic-at-point-follows-identity-removal ()
  "Ignore a diagnostic removed by identity from the core model."
  (with-temp-buffer
    (insert "abcdefghij")
    (let ((proofread-auto-check nil)
          (stale
           (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
          (live
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (proofread-mode 1)
      (proofread-test--publish-diagnostics (list stale live))
      (proofread--remove-diagnostics (list stale))
      (should-not (memq stale proofread--diagnostics))
      (should (eq (proofread-diagnostic-at-point 4) live)))))

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
      (let ((old-live (car proofread--diagnostics)))
        (should (eq (proofread-diagnostic-at-point 2) old-live))
        (proofread--replace-backend-diagnostics request (list new))
        (let ((new-live (car proofread--diagnostics)))
          (should-not
           (memq old-live
                 (proofread-test--flymake-proofread-diagnostics)))
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
      (proofread-test--publish-diagnostics
       (list first second third))
      (proofread--remove-diagnostics (list second))
      (should
       (equal
        (proofread--diagnostic-members
         (proofread-diagnostic-at-point 2))
        (list first third)))
      (proofread--remove-diagnostics (list first))
      (should (eq (proofread-diagnostic-at-point 2) third))
      (proofread--remove-diagnostics (list third))
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

(ert-deftest proofread-test-diagnostic-message-field-whitespace-modes
    ()
  "Clean single-line fields while preserving multiline content."
  (with-temp-buffer
    (set-syntax-table (copy-syntax-table (syntax-table)))
    (modify-syntax-entry ?\n ".")
    (modify-syntax-entry ?\r ".")
    (let ((field
           (propertize "　Alpha\tBeta\r\nGamma　"
                       'face 'error)))
      (should
       (equal (proofread--format-diagnostic-message-field field t)
              "Alpha Beta Gamma"))
      (should-not
       (text-properties-at
        0 (proofread--format-diagnostic-message-field field t)))
      (should
       (equal
        (proofread--format-diagnostic-message-field
         "  Alpha\n Beta  " nil)
        "Alpha\n Beta"))
      (should-not
       (proofread--format-diagnostic-message-field "　\t\r\n" t)))))

(ert-deftest proofread-test-list-field-cleans-before-truncation ()
  "Clean list fields before applying their display width bound."
  (let* ((raw
          (propertize "　Alpha\tBeta\r\nGamma　" 'face 'bold))
         (clean (proofread--format-list-field raw))
         (bounded (proofread--format-list-field raw 10)))
    (should (equal clean "Alpha Beta Gamma"))
    (should (eq (get-text-property 0 'face clean) 'bold))
    (should (<= (string-width bounded) 10))
    (should-not (string-match-p "[\t\n\r　]" bounded))
    (should (equal (proofread--format-list-field "　\t\r\n") ""))
    (should (equal (proofread--format-list-field nil) "-"))))

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
           :source-face 'font-lock-keyword-face
           :message-face 'font-lock-comment-face)))
    (should (equal message "test: Possible misspelling"))
    (should
     (eq (get-text-property 0 'face message)
         'font-lock-keyword-face))
    (should
     (eq (get-text-property 4 'face message)
         'font-lock-keyword-face))
    (should-not (get-text-property 5 'face message))
    (should
     (eq (get-text-property 6 'face message)
         'font-lock-comment-face))
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
           :source-face 'font-lock-keyword-face
           :message-face 'font-lock-comment-face
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
         'font-lock-keyword-face))
    (should
     (eq (get-text-property (+ second-source 14) 'face message)
         'font-lock-comment-face))))

(ert-deftest proofread-test-public-diagnostic-message-fallbacks ()
  "The shared message formatter handles blank and non-string fields."
  (dolist (raw-message '(nil "" " \t\n"))
    (let ((message
           (proofread-format-diagnostic-message
            (list :source " "
                  :message raw-message
                  :text (propertize "helo" 'face 'error))
            :message-face 'font-lock-comment-face)))
      (should (equal message "Proofread: helo"))
      (should
       (eq (get-text-property 0 'face message)
           'font-lock-comment-face))))
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
    proofread-test-public-diagnostic-at-point-requires-publication ()
  "Return only diagnostics currently published by the bridge."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (setq proofread--diagnostics (list diagnostic))
      (should-not (proofread-diagnostic-at-point 4))
      (flymake-start)
      (should (eq (proofread-diagnostic-at-point 4) diagnostic))
      (funcall proofread--flymake-report-function
               nil :region (cons (point-min) (point-max)))
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest
    proofread-test-public-diagnostic-at-point-skips-unpublished-overlap
    ()
  "The public lookup skips an earlier unreported model diagnostic."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((stale
           (proofread-test--diagnostic-for-range 2 8 "bcdefg"))
          (live
           (proofread-test--diagnostic-for-range 3 6 "cde")))
      (setq proofread--diagnostics (list live))
      (flymake-start)
      (setq proofread--diagnostics (list stale live))
      (should (eq (proofread-diagnostic-at-point 4) live)))))

(ert-deftest proofread-test-flymake-eldoc-is-the-only-generic-provider
    ()
  "Use Flymake's one generic ElDoc provider for Proofread diagnostics."
  (with-temp-buffer
    (insert "helo")
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1))
      (proofread-mode 1)
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1))
      (goto-char 2)
      (let ((calls 0))
        (flymake-eldoc-function
         (lambda (&rest _arguments)
           (setq calls (1+ calls))))
        (should (= calls 0)))
      (proofread-test--publish-diagnostics
       (list (proofread-test--diagnostic-for-range 1 5 "helo")))
      (let ((calls 0)
            callback-arguments)
        (flymake-eldoc-function
         (lambda (document &rest properties)
           (setq calls (1+ calls))
           (setq callback-arguments (cons document properties))))
        (should (= calls 1))
        (should
         (equal (substring-no-properties
                 (car callback-arguments))
                "test: Possible misspelling"))
        (should
         (equal (substring-no-properties
                 (plist-get (cdr callback-arguments) :echo))
                "test: Possible misspelling"))))))

(ert-deftest proofread-test-flymake-eldoc-keeps-foreign-diagnostics ()
  "Report one Proofread aggregate and foreign diagnostics through ElDoc."
  (with-temp-buffer
    (insert "helo")
    (setq-local flymake-diagnostic-functions
                (list #'proofread-test--flymake-foreign-backend))
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
      (proofread-test--publish-diagnostics (list first second))
      (goto-char 1)
      (let ((calls 0)
            callback-arguments)
        (flymake-eldoc-function
         (lambda (document &rest properties)
           (setq calls (1+ calls))
           (setq callback-arguments (cons document properties))))
        (should (= calls 1))
        (let ((lines
               (split-string
                (substring-no-properties
                 (plist-get (cdr callback-arguments) :echo))
                "\n" t)))
          (should (= (length lines) 2))
          (should
           (= (cl-count
               "first: First message; second: Second message"
               lines :test #'equal)
              1))
          (should
           (= (cl-count "Foreign diagnostic" lines :test #'equal)
              1)))))))

(ert-deftest proofread-test-eldoc-mode-lifecycle-is-flymake-owned ()
  "Leave ElDoc state unchanged while Flymake owns its provider."
  (with-temp-buffer
    (text-mode)
    (setq-local eldoc-documentation-functions nil)
    (eldoc-mode -1)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should-not eldoc-mode)
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1))
      (proofread-mode -1)
      (should-not eldoc-mode)
      (should flymake-mode)
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1))))
  (with-temp-buffer
    (text-mode)
    (add-hook 'eldoc-documentation-functions #'ignore nil t)
    (eldoc-mode 1)
    (should eldoc-mode)
    (let ((proofread-auto-check nil))
      (proofread-mode 1)
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1))
      (proofread-mode -1)
      (should eldoc-mode)
      (should (memq #'ignore eldoc-documentation-functions))
      (should (= (cl-count #'flymake-eldoc-function
                           eldoc-documentation-functions)
                 1)))
    (eldoc-mode -1)))

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
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread-clear)
      (should (= calls 1))
      (should-not (proofread-diagnostic-at-point 4)))))

(ert-deftest proofread-test-clear-preserves-reentrant-diagnostics ()
  "Preserve diagnostic state installed by the clear notification."
  (with-temp-buffer
    (insert "abcdefghij")
    (proofread-mode 1)
    (let ((old
           (proofread-test--diagnostic-for-range 1 4 "abc"))
          (replacement
           (proofread-test--diagnostic-for-range 5 8 "efg"))
          (reentered-p nil)
          (report-count 0)
          (hook-count 0))
      (proofread-test--publish-diagnostics (list old))
      (let ((original-report-function
             proofread--flymake-report-function))
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq report-count (1+ report-count))
                (apply original-report-function arguments))))
      (add-hook
       'proofread-diagnostics-changed-hook
       (lambda ()
         (setq hook-count (1+ hook-count))
         (unless reentered-p
           (setq reentered-p t)
           (proofread--apply-backend-diagnostics
            (list replacement) '(5 . 8))))
       nil t)
      (proofread-clear)
      (should (= report-count 2))
      (should (= hook-count 2))
      (should (= (length proofread--diagnostics) 1))
      (let ((installed (car proofread--diagnostics)))
        (should (equal installed replacement))
        (should (gethash installed
                         proofread--diagnostic-request-ranges))
        (should (eq (proofread-diagnostic-at-point 6) installed))))))

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
      (proofread-test--publish-diagnostics (list diagnostic))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (error "Simulated frontend failure"))
                nil t)
      (goto-char 2)
      (should (eq (proofread-correct-at-point) 'applied))
      (should (equal (buffer-string) "hello"))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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
      (proofread-test--publish-diagnostics (list old))
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
        (proofread-test--publish-diagnostics (list diagnostic))
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
        (proofread-test--publish-diagnostics (list diagnostic))
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
        (proofread-test--publish-diagnostics (list first second))
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
        (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
        (proofread-test--publish-diagnostics (list diagnostic))
        (goto-char 2)
        (proofread-describe)
        (should (equal (buffer-string) text))))))

(ert-deftest
    proofread-test-describe-preserves-diagnostics-and-publication ()
  "Do not mutate diagnostics or their publication while describing them."
  (save-window-excursion
    (with-temp-buffer
      (insert "helo world")
      (proofread-mode 1)
      (let ((diagnostic
             (proofread-test--diagnostic-for-range
              1 5 "helo")))
        (proofread-test--publish-diagnostics (list diagnostic))
        (let ((diagnostics-before (copy-sequence
                                   proofread--diagnostics))
              (publication-before
               (mapcar
                (lambda (flymake-diagnostic)
                  (list (flymake-diagnostic-buffer flymake-diagnostic)
                        (flymake-diagnostic-beg flymake-diagnostic)
                        (flymake-diagnostic-end flymake-diagnostic)
                        (flymake-diagnostic-type flymake-diagnostic)
                        (flymake-diagnostic-text flymake-diagnostic)))
                (flymake-diagnostics))))
          (goto-char 2)
          (proofread-describe)
          (should (equal proofread--diagnostics diagnostics-before))
          (should
           (equal
            (mapcar
             (lambda (flymake-diagnostic)
               (list (flymake-diagnostic-buffer flymake-diagnostic)
                     (flymake-diagnostic-beg flymake-diagnostic)
                     (flymake-diagnostic-end flymake-diagnostic)
                     (flymake-diagnostic-type flymake-diagnostic)
                     (flymake-diagnostic-text flymake-diagnostic)))
             (flymake-diagnostics))
            publication-before)))))))

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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list first second))
      (goto-char 5)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _args)
                   (setq collection-seen collection)
                   "hello")))
        (should (eq (proofread-correct-at-point) 'applied)))
      (should (equal collection-seen '( "hello" "hullo")))
      (should (equal (buffer-string) "aa hello zz"))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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
        (proofread-test--publish-diagnostics
         (list
          (proofread-test--diagnostic-with-suggestions
           1 5 "helo" '( "hello"))))
        (goto-char 2)
        (setq entry-point 'single)
        (proofread-correct-at-point))
      (with-temp-buffer
        (insert "helo wrld")
        (proofread-mode 1)
        (proofread-test--publish-diagnostics
         (list
          (proofread-test--diagnostic-with-suggestions
           1 5 "helo" '( "hello"))
          (proofread-test--diagnostic-with-suggestions
           6 10 "wrld" '( "world"))))
        (setq entry-point 'batch)
        (proofread-correct-buffer)))
    (should (equal (nreverse calls) '( single batch)))))

(ert-deftest proofread-test-correction-plan-uses-explicit-records ()
  "Represent validated correction and repair state with records."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello"))))
      (proofread-test--publish-diagnostics (list diagnostic))
      (let* ((plan
              (proofread--prepare-correction-plan
               (list (cons diagnostic "hello")) nil))
             (entries (proofread--correction-plan-entries plan))
             (entry (car entries))
             (source-state
              (cl-find
               (current-buffer)
               (proofread--correction-plan-buffer-states plan)
               :key #'proofread--correction-buffer-state-buffer
               :test #'eq)))
        (should (proofread--correction-plan-p plan))
        (should (= (length entries) 1))
        (should (proofread--correction-entry-p entry))
        (should (eq (proofread--correction-entry-diagnostic entry)
                    diagnostic))
        (should (equal (proofread--correction-entry-suggestion entry)
                       "hello"))
        (should (equal (proofread--correction-entry-range entry)
                       '( 1 . 5)))
        (should
         (proofread--correction-entry-container-snapshotted-p
          entry))
        (should-not (proofread--correction-entry-container entry))
        (should (equal (proofread--correction-plan-region plan)
                       '( 1 . 5)))
        (should
         (equal (proofread--correction-plan-affected-diagnostics
                 plan)
                (list diagnostic)))
        (should (eq (proofread--correction-plan-source plan)
                    (current-buffer)))
        (should-not
         (proofread--correction-plan-preserve-excursion-p plan))
        (should (proofread--correction-buffer-state-p source-state))
        (should
         (equal
          (proofread--correction-buffer-state-range-snapshot
           source-state)
          (proofread--correction-plan-source-range-snapshot
           plan)))))))

(ert-deftest
    proofread-test-correction-transaction-orchestrates-plan-stages ()
  "Run the named correction-plan stages once and in order."
  (with-temp-buffer
    (let ((plan
           (proofread--make-correction-plan
            nil nil nil nil (current-buffer) nil nil))
          (corrections '( (diagnostic . "replacement")))
          events)
      (cl-letf
          (((symbol-function 'proofread--prepare-correction-plan)
            (lambda (actual-corrections preserve-excursion-p)
              (should (equal actual-corrections corrections))
              (should-not preserve-excursion-p)
              (push 'prepare events)
              plan))
           ((symbol-function 'proofread--apply-correction-plan)
            (lambda (actual-plan)
              (should (eq actual-plan plan))
              (push 'apply events)
              '( deferred)))
           ((symbol-function 'proofread--commit-correction-plan)
            (lambda (actual-plan deferred-diagnostics)
              (should (eq actual-plan plan))
              (should (equal deferred-diagnostics '( deferred)))
              (push 'commit events)))
           ((symbol-function 'proofread--repair-correction-plan)
            (lambda (actual-plan)
              (should (eq actual-plan plan))
              (push 'repair events)))
           ((symbol-function
             'proofread--restore-correction-plan-after-rollback)
            (lambda (&rest _arguments)
              (ert-fail "Unexpected correction rollback"))))
        (proofread--run-correction-transaction corrections))
      (should (equal (nreverse events)
                     '( prepare apply commit repair))))))

(ert-deftest
    proofread-test-correction-transaction-repairs-after-rollback ()
  "Restore and repair a plan when its application fails."
  (with-temp-buffer
    (let ((plan
           (proofread--make-correction-plan
            nil nil nil nil (current-buffer) nil nil))
          (corrections '( (diagnostic . "replacement")))
          events)
      (cl-letf
          (((symbol-function 'proofread--prepare-correction-plan)
            (lambda (&rest _arguments)
              (push 'prepare events)
              plan))
           ((symbol-function 'proofread--apply-correction-plan)
            (lambda (actual-plan)
              (should (eq actual-plan plan))
              (push 'apply events)
              (error "Correction application failed")))
           ((symbol-function 'proofread--commit-correction-plan)
            (lambda (&rest _arguments)
              (ert-fail "Unexpected correction commit")))
           ((symbol-function
             'proofread--restore-correction-plan-after-rollback)
            (lambda (actual-plan)
              (should (eq actual-plan plan))
              (push 'rollback events)))
           ((symbol-function 'proofread--repair-correction-plan)
            (lambda (actual-plan)
              (should (eq actual-plan plan))
              (push 'repair events))))
        (should-error
         (proofread--run-correction-transaction corrections)
         :type 'error))
      (should (equal (nreverse events)
                     '( prepare apply rollback repair))))))

(ert-deftest
    proofread-test-correction-plan-applies-entries-in-reverse-order ()
  "Route each batch entry through apply-one in reverse order."
  (with-temp-buffer
    (let* ((first
            (proofread--make-correction-entry
             'first "first" '( 1 . 2) nil nil))
           (second
            (proofread--make-correction-entry
             'second "second" '( 3 . 4) nil nil))
           (plan
            (proofread--make-correction-plan
             (list first second) nil nil nil (current-buffer) nil t))
           calls)
      (cl-letf
          (((symbol-function 'proofread--apply-correction-entry)
            (lambda (entry preserve-excursion-p)
              (push (list entry preserve-excursion-p) calls))))
        (should-not (proofread--apply-correction-plan plan)))
      (should (equal (nreverse calls)
                     (list (list second t) (list first t)))))))

(ert-deftest
    proofread-test-single-correction-preserves-transaction-order ()
  "Keep single-correction point, mark, hook, and undo ordering."
  (with-temp-buffer
    (insert "aa helo zz")
    (proofread-mode 1)
    (proofread-test--publish-diagnostics
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
    (proofread-test--publish-diagnostics
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
    (proofread-test--publish-diagnostics
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics
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
      (proofread-test--publish-diagnostics (list outside inside))
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
      (proofread-test--publish-diagnostics (list first hidden last))
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
      (proofread-test--publish-diagnostics (list unavailable
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
      (proofread-test--publish-diagnostics (list available adjacent))
      (proofread-correct-buffer)
      (should (equal (buffer-string) "hellowrld"))
      (should (equal proofread--diagnostics (list adjacent)))
      (should
       (equal (proofread-diagnostic-range adjacent) '( 6 . 10)))
      (should (equal (buffer-substring-no-properties 6 10) "wrld")))))

(ert-deftest
    proofread-test-corrections-affected-identities-preserve-order ()
  "Keep affected diagnostic ordering around the correction scan."
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
           (_published-diagnostics
            (proofread-test--publish-diagnostics diagnostics))
           (expected-diagnostics
            (list zero-correction zero-right main overlap contains))
           (plan
            (proofread--prepare-correction-plan
             (list (cons zero-correction "X")
                   (cons main "Y"))
             t))
           (affected-diagnostics
            (proofread--correction-plan-affected-diagnostics plan)))
      (should (equal affected-diagnostics expected-diagnostics))
      (should (cl-every #'eq affected-diagnostics
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
      (proofread-test--publish-diagnostics (list long short))
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
      (proofread-test--publish-diagnostics (list first second))
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
      (proofread-test--publish-diagnostics (list first second
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
      (proofread-test--publish-diagnostics (list first second))
      (should-error (proofread-correct-buffer))
      (should (equal (buffer-string) "helo wrld"))
      (should (equal proofread--diagnostics (list first second)))
      (should (= (length
                  (proofread-test--flymake-proofread-diagnostics))
                 2)))))

(ert-deftest
    proofread-test-correct-buffer-revalidates-after-selection ()
  "Never overwrite edits made during suggestion selection."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello" "hullo"))))
      (proofread-test--publish-diagnostics (list diagnostic))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (erase-buffer)
                   (insert "user text")
                   "hello")))
        (should-error (proofread-correct-buffer) :type 'user-error))
      (should (equal (buffer-string) "user text"))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

(ert-deftest
    proofread-test-correction-uses-revalidated-range-for-state ()
  "Use live ranges when a failed edit hook leaves stored state stale."
  (with-temp-buffer
    (insert "ahelo")
    (proofread-mode 1)
    (let ((survivor
           (proofread-test--diagnostic-for-range 2 2 ""))
          (target
           (proofread-test--diagnostic-with-suggestions
            2 6 "helo" '( "hello" "hullo"))))
      (proofread-test--publish-diagnostics (list survivor target))
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
      ;; The zero-width diagnostic moved to the correction boundary
      ;; even though its stored plist stayed at the old position.
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics))
      (should-not (proofread-diagnostic-at-point 2)))))

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
             (_published-diagnostics
              (proofread-test--publish-diagnostics
               (list diagnostic))))
        (goto-char (plist-get diagnostic :beg))
        (should-error (proofread-correct-at-point) :type 'user-error)
        (should (equal (buffer-string) before))
        (should (equal proofread--diagnostics (list diagnostic)))
        (should (eq (proofread-diagnostic-at-point
                     (plist-get diagnostic :beg))
                    diagnostic))))))

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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list first second))
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
           (_published-diagnostics
            (proofread-test--publish-diagnostics diagnostics))
           (original-report-function
            proofread--flymake-report-function)
           (report-count 0)
           (calls 0))
      ;; Make the published positions differ from the immutable stored
      ;; plist positions before exercising rollback restoration.
      (goto-char (point-min))
      (insert "x")
      (setq proofread--flymake-report-function
            (lambda (&rest arguments)
              (setq report-count (1+ report-count))
              (apply original-report-function arguments)))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls)))
                nil t)
      (goto-char 6)
      (should-error (proofread-correct-buffer) :type 'user-error)
      (should (equal (buffer-string) "x\"helo wrld\""))
      (should (equal proofread--diagnostics diagnostics))
      ;; The failed edit can temporarily remove Flymake diagnostics even
      ;; though the atomic change group restores the text, so Proofread
      ;; republishes the unchanged snapshot without notifying model
      ;; observers.
      (should (= report-count 1))
      (should (= calls 0))
      (let ((published
             (proofread-test--flymake-proofread-diagnostics)))
        (should (= (length published) 2))
        (should (cl-every
                 (lambda (diagnostic)
                   (memq diagnostic published))
                 diagnostics)))
      (should
       (equal (mapcar #'proofread-diagnostic-range diagnostics)
              '((3 . 7) (8 . 12))))
      (should (= (point) 6)))))

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
        (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list first second))
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
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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
            (proofread-test--publish-diagnostics
             (list (proofread-test--diagnostic-with-suggestions
                    1 5 "helo" '( "hello")))))
          (with-current-buffer source
            (insert "wrng")
            (proofread-mode 1)
            (proofread-test--publish-diagnostics
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
            (should-not (proofread-test--flymake-proofread-diagnostics))))
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
            (proofread-test--publish-diagnostics
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
              (proofread-test--publish-diagnostics (list diagnostic))
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
              (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))))
          (with-current-buffer other
            (should (equal (buffer-string) "hxlo"))
            (should-not proofread--diagnostics)
            (should-not (proofread-test--flymake-proofread-diagnostics))))
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
          (reports 0)
          events
          hook-flymake
          (first
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello")))
          (second
           (proofread-test--diagnostic-with-suggestions
            6 10 "wrld" '( "world"))))
      (proofread-test--publish-diagnostics (list first second))
      (let ((original-report-function
             proofread--flymake-report-function))
        (setq proofread--flymake-report-function
              (lambda (&rest arguments)
                (setq reports (1+ reports))
                (push 'report events)
                (apply original-report-function arguments))))
      (add-hook 'proofread-diagnostics-changed-hook
                (lambda ()
                  (setq calls (1+ calls))
                  (setq hook-flymake
                        (proofread-test--flymake-proofread-diagnostics))
                  (push 'hook events))
                nil t)
      (proofread-correct-buffer)
      (should (= reports 1))
      (should (= calls 1))
      (should (equal (reverse events) '(report hook)))
      (should-not hook-flymake))))

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
      (proofread-test--publish-diagnostics (list diagnostic))
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

(ert-deftest proofread-test-apply-unpublished-diagnostic-rejected ()
  "Reject a model identity no longer published by the Flymake bridge."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread-test--diagnostic-with-suggestions
            1 5 "helo" '( "hello"))))
      (proofread-test--publish-diagnostics (list diagnostic))
      (funcall proofread--flymake-report-function
               nil :region (cons (point-min) (point-max)))
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
      (proofread-test--publish-diagnostics (list diagnostic))
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
      (proofread-test--publish-diagnostics (list diagnostic))
      (goto-char 5)
      (proofread-correct-at-point)
      (should (equal (buffer-string) "aa hello zz"))
      (undo)
      (should (equal (buffer-string) "aa helo zz")))))

(ert-deftest proofread-test-apply-invalidates-affected-diagnostics ()
  "Suggestion application removes affected diagnostics only."
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
           (foreign-overlay (make-overlay 3 9)))
      (overlay-put foreign-overlay 'category 'foreign-overlay)
      (proofread-test--publish-diagnostics
       (list target overlap outside))
      (proofread--mark-current-diagnostic target)
      (goto-char 5)
      (proofread-correct-at-point)
      (should (overlay-buffer foreign-overlay))
      (should-not proofread--current-diagnostic)
      (should (equal proofread--diagnostics (list outside)))
      (should (equal
               (proofread-test--flymake-proofread-diagnostics)
               (list outside)))
      (should-not (proofread-diagnostic-at-point 5))
      (should (eq (proofread-diagnostic-at-point 10) outside)))))

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
        (proofread-test--publish-diagnostics (list diagnostic))
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

(ert-deftest proofread-test-ignore-command-removes-matching-diagnostics
    ()
  "Record ignored keys and remove their matching diagnostics."
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
             (foreign-overlay (make-overlay 1 15))
             (text (buffer-string)))
        (overlay-put foreign-overlay 'category 'foreign-overlay)
        (proofread-test--publish-diagnostics
         (list target unrelated same-key))
        (proofread--mark-current-diagnostic target)
        (goto-char 2)
        (should (eq (proofread-ignore) 'ignored))
        (should (proofread--diagnostic-ignored-p target))
        (should (overlay-buffer foreign-overlay))
        (should-not proofread--current-diagnostic)
        (should (equal proofread--diagnostics (list unrelated)))
        (should (equal
                 (proofread-test--flymake-proofread-diagnostics)
                 (list unrelated)))
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
        (proofread-test--publish-diagnostics
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
        (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))
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
        (proofread-test--publish-diagnostics (list diagnostic))
        (goto-char 8)
        (should-error (proofread-ignore) :type 'user-error)
        (should (equal (buffer-string) text))
        (should-not (proofread--diagnostic-ignored-p diagnostic))
        (should (= (length (proofread-test--flymake-proofread-diagnostics)) 1))))))

(ert-deftest proofread-test-ignore-filter-preserves-different-key ()
  "Filter ignored diagnostics before publishing them."
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
        (should
         (equal (proofread-test--flymake-proofread-diagnostics)
                (list different-kind different-text)))))))

(ert-deftest proofread-test-ignore-filters-backend-and-cache-results
    ()
  "Publish no diagnostics for ignored backend or cached results."
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
               (work (proofread--make-request-work request))
               (diagnostic
                (proofread-test--diagnostic-with-kind
                 1 5 "helo" 'spelling))
               (entry (proofread--make-cache-entry
                       request (list diagnostic))))
          (proofread--record-ignored-diagnostic diagnostic)
          (should (eq (proofread--handle-backend-result
                       work
                       (proofread--backend-success-result
                        request (list diagnostic)))
                      'applied))
          (should-not proofread--diagnostics)
          (should-not (proofread-test--flymake-proofread-diagnostics))
          (should (eq (proofread--apply-cache-entry work entry)
                      'applied))
          (should-not proofread--diagnostics)
          (should-not (proofread-test--flymake-proofread-diagnostics)))))))

;;;; Listing tests

(ert-deftest proofread-test-list-columns-use-display-columns ()
  "Show tab, wide, and combining characters as display columns."
  (with-temp-buffer
    (setq-local proofread-auto-check nil)
    (setq-local tab-width 8)
    (insert "\t中e" (string #x0301) "X")
    (proofread-mode 1)
    (let* ((cases '((2 . 8) (3 . 10) (5 . 11)))
           (diagnostics
            (mapcar
             (lambda (case)
               (proofread--make-diagnostic
                :beg (car case) :end (car case) :text ""
                :kind 'style :message "Test" :source 'test))
             cases)))
      (proofread-test--publish-diagnostics diagnostics)
      (should
       (= (length (proofread-test--flymake-proofread-diagnostics)) 3))
      (narrow-to-region 2 (point-max))
      (let ((diagnostic-entries
             (proofread--diagnostics-list-entries)))
        (should (= (length diagnostic-entries) 3))
        (cl-mapc
         (lambda (case diagnostic)
           (let* ((position (car case))
                  (expected-column (cdr case))
                  (record
                   (list :source-buffer (current-buffer)
                         :key position
                         :beg position
                         :end position))
                  (request-line-column
                   (proofread--request-log-record-line-column record))
                  (diagnostic-line-column
                   (proofread--diagnostic-line-column diagnostic))
                  (request-entry
                   (proofread--request-log-record-entry record))
                  (request-summary
                   (proofread--request-log-record-summary record))
                  (diagnostic-entry
                   (cl-find
                    diagnostic diagnostic-entries
                    :key (lambda (entry)
                           (plist-get (car entry) :diagnostic))
                    :test #'eq))
                  (diagnostic-columns (cadr diagnostic-entry)))
             (should (equal request-line-column
                            (cons 1 expected-column)))
             (should (equal diagnostic-line-column
                            (cons 1 expected-column)))
             (should (= (plist-get (car request-entry) :column)
                        expected-column))
             (should (= (plist-get request-summary :column)
                        expected-column))
             (should
              (equal (aref (cadr request-entry) 4)
                     (number-to-string expected-column)))
             (should
              (equal (aref diagnostic-columns 1)
                     (number-to-string expected-column)))))
         cases diagnostics)))))

(ert-deftest
    proofread-test-request-list-accepts-buffer-object-and-name ()
  "Resolve a live request-list source from its object or name."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (source
         (generate-new-buffer " *proofread-request-source-input*"))
        list-buffer)
    (unwind-protect
        (save-window-excursion
          (with-current-buffer source
            (setq-local proofread-auto-check nil)
            (proofread-mode 1))
          (setq list-buffer
                (proofread-show-buffer-requests source))
          (should
           (eq (proofread-show-buffer-requests
                (buffer-name source))
               list-buffer))
          (should
           (eq (buffer-local-value
                'proofread--request-log-list-source list-buffer)
               source)))
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer))
      (when (buffer-live-p source)
        (kill-buffer source)))))

(ert-deftest proofread-test-request-list-rejects-dead-sources ()
  "Reject dead source objects and nonexistent source names."
  (let* ((source
          (generate-new-buffer " *proofread-request-source-dead*"))
         (name (buffer-name source)))
    (kill-buffer source)
    (should-error (proofread-show-buffer-requests source)
                  :type 'user-error)
    (should-error (proofread-show-buffer-requests name)
                  :type 'user-error)))

(ert-deftest
    proofread-test-request-log-ring-preserves-insertion-order ()
  "Keep insertion order when a bounded request record is updated."
  (with-temp-buffer
    (setq-local proofread-request-log-max-records 3)
    (setq proofread--request-log-enabled t)
    (dolist (key '(30 10 20))
      (proofread-test--record-request-log-event
       (current-buffer) key))
    (should (ring-p proofread--request-log-order))
    (should (= (ring-size proofread--request-log-order) 3))
    (should (equal (ring-elements proofread--request-log-order)
                   '(20 10 30)))
    (proofread-test--record-request-log-event
     (current-buffer) 10 'queued-request)
    (should (equal (ring-elements proofread--request-log-order)
                   '(20 10 30)))
    (should (= (hash-table-count proofread--request-log-records)
               3))
    (let* ((records (proofread--request-log-record-list))
           (updated (cl-find 10 records
                             :key (lambda (record)
                                    (plist-get record :key)))))
      (should (equal (mapcar (lambda (record)
                               (plist-get record :key))
                             records)
                     '(30 10 20)))
      (should (eq (plist-get updated :status) 'queued))
      (should (equal (mapcar (lambda (event)
                               (plist-get event :type))
                             (plist-get updated :events))
                     '(chunk-request queued-request))))
    (proofread-test--record-request-log-event
     (current-buffer) 40)
    (should (equal (ring-elements proofread--request-log-order)
                   '(40 20 10)))
    (should (= (hash-table-count proofread--request-log-records)
               3))
    (should-not (gethash 30 proofread--request-log-records))
    (should (equal (mapcar (lambda (record)
                             (plist-get record :key))
                           (proofread--request-log-record-list))
                   '(10 20 40)))))

(ert-deftest proofread-test-request-log-ring-migrates-list-order ()
  "Preserve legacy insertion order while replacing its order list."
  (with-temp-buffer
    (setq-local proofread-request-log-max-records 2)
    (setq proofread--request-log-records
          (make-hash-table :test #'equal))
    (dolist (key '(30 10 20))
      (puthash key
               (list :key key
                     :log-id key
                     :source-buffer (current-buffer))
               proofread--request-log-records))
    (setq proofread--request-log-order '(30 10 20))
    (should (equal (mapcar (lambda (record)
                             (plist-get record :key))
                           (proofread--request-log-record-list))
                   '(10 20)))
    (should (ring-p proofread--request-log-order))
    (should (equal (ring-elements proofread--request-log-order)
                   '(20 10)))
    (should (= (hash-table-count proofread--request-log-records)
               2))
    (should-not (gethash 30 proofread--request-log-records))))

(ert-deftest proofread-test-request-log-ring-resizes-and-prunes ()
  "Synchronize request record storage when its ring is resized."
  (with-temp-buffer
    (setq-local proofread-request-log-max-records 3)
    (setq proofread--request-log-enabled t)
    (dolist (key '(1 2 3))
      (proofread-test--record-request-log-event
       (current-buffer) key))
    (setq-local proofread-request-log-max-records 2)
    (proofread-test--record-request-log-event
     (current-buffer) 3 'queued-request)
    (should (equal (mapcar (lambda (record)
                             (plist-get record :key))
                           (proofread--request-log-record-list))
                   '(2 3)))
    (should (= (ring-size proofread--request-log-order) 2))
    (should (equal (ring-elements proofread--request-log-order)
                   '(3 2)))
    (should (= (hash-table-count proofread--request-log-records)
               2))
    (should-not (gethash 1 proofread--request-log-records))
    (setq-local proofread-request-log-max-records 4)
    (dolist (key '(4 5))
      (proofread-test--record-request-log-event
       (current-buffer) key))
    (should (= (ring-size proofread--request-log-order) 4))
    (should (equal (ring-elements proofread--request-log-order)
                   '(5 4 3 2)))
    (should (equal (mapcar (lambda (record)
                             (plist-get record :key))
                           (proofread--request-log-record-list))
                   '(2 3 4 5)))
    (should (= (hash-table-count proofread--request-log-records)
               4))
    (setq-local proofread-request-log-max-records 0)
    (proofread-test--record-request-log-event
     (current-buffer) 6)
    (should-not (proofread--request-log-record-list))
    (should (= (ring-size proofread--request-log-order) 0))
    (should (ring-empty-p proofread--request-log-order))
    (should (= (hash-table-count proofread--request-log-records)
               0))))

(ert-deftest
    proofread-test-request-log-shrink-does-not-reinsert-update ()
  "Do not reinsert an updated record evicted by a pending shrink."
  (with-temp-buffer
    (setq-local proofread-request-log-max-records 3)
    (setq proofread--request-log-enabled t)
    (dolist (key '(1 2 3))
      (proofread-test--record-request-log-event
       (current-buffer) key))
    (setq-local proofread-request-log-max-records 2)
    (proofread-test--record-request-log-event
     (current-buffer) 1 'queued-request)
    (should (equal (ring-elements proofread--request-log-order)
                   '(3 2)))
    (should (= (hash-table-count proofread--request-log-records)
               2))
    (should-not (gethash 1 proofread--request-log-records))
    (should (equal (mapcar (lambda (record)
                             (plist-get record :key))
                           (proofread--request-log-record-list))
                   '(2 3)))))

(ert-deftest proofread-test-request-log-ignores-dead-source ()
  "Ignore request-log records whose source buffer is dead."
  (let* ((proofread--request-log-sources nil)
         (source
          (generate-new-buffer " *proofread-request-dead-log*"))
         event)
    (with-current-buffer source
      (setq proofread--request-log-enabled t)
      (proofread-test--record-request-log-event source 1)
      (setq event
            (proofread--request-log-safe-event
             (list :type 'chunk-request
                   :time (current-time)
                   :log-id 2
                   :request-id 2
                   :buffer source
                   :beg 1
                   :end 1
                   :request (list :id 2 :buffer source)))))
    (setq proofread--request-log-sources (list source))
    (kill-buffer source)
    (cl-letf (((symbol-function
                'proofread--request-log-ensure-records)
               (lambda ()
                 (error "Dead source state was accessed"))))
      (should-not
       (proofread--request-log-record-canonical-event event))
      (should-not (proofread--request-log-record-list source))
      (should-not (proofread--request-log-lookup-record source 1)))
    (proofread--prune-request-log-sources)
    (should-not proofread--request-log-sources)))

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
             :request (list :id 1 :buffer
                            (current-buffer))))
      (should (ring-p proofread--request-log-order))
      (should (= (ring-size proofread--request-log-order) 0))
      (should (ring-empty-p proofread--request-log-order))
      (should (= (hash-table-count proofread--request-log-records)
                 0))
      (should-not (proofread--request-log-record-list)))))

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
                    (list :id 7
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
                (request (list :id 8
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
                              (proofread-test--backend-check-function
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
          (should-not (memq #'proofread--request-log-record-event
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
          (should-not (memq #'proofread--request-log-record-event
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
  "Killing a source closes its lists and releases monitor state."
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
            (should-not (memq #'proofread--request-log-record-event
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
           (proofread--request-log-safe-event
            (list :type 'backend-request
                  :backend 'languagetool
                  :method "POST"
                  :url url
                  :parameters parameters))))
         (opaque-details
          (proofread--request-log-backend-request-details
           (proofread--request-log-safe-event
            '( :type backend-request
               :backend languagetool
               :method "POST"
               :parameters (("language" . "en-US")
                            ("text" . "helo"))))))
         (response-details
          (proofread--request-log-backend-response-details
           (proofread--request-log-safe-event
            (list :type 'backend-response
                  :backend 'languagetool
                  :url url
                  :http-status 200
                  :response "{\"matches\":[]}")))))
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

(ert-deftest proofread-test-request-log-schema-declares-every-event ()
  "Declare every request event with named callable sanitizers."
  (let* ((property-sanitizers
          (plist-get proofread--request-log-schema
                     :property-sanitizers))
         (objects (plist-get proofread--request-log-schema :objects))
         (event-schema
          (plist-get proofread--request-log-schema :events))
         (event-types (mapcar #'car event-schema))
         (expected-types
          '( t chunk-request queued-request active-request
             backend-dispatched backend-request backend-response
             backend-result cache-hit cancelled final-result
             checker-dispatch-failed)))
    (should
     (equal (mapcar #'car property-sanitizers)
            (delete-dups (mapcar #'car property-sanitizers))))
    (dolist (entry property-sanitizers)
      (should (keywordp (car entry)))
      (let ((sanitizer (cdr entry)))
        (should (symbolp sanitizer))
        (should (fboundp sanitizer))))
    (should
     (equal (mapcar #'car objects)
            (delete-dups (mapcar #'car objects))))
    (dolist (entry objects)
      (let ((fields (cdr entry)))
        (should
         (equal (mapcar #'car fields)
                (delete-dups (mapcar #'car fields))))
        (dolist (field fields)
          (should (= (length field) 2))
          (should (keywordp (car field)))
          (let ((sanitizer (cadr field)))
            (should (symbolp sanitizer))
            (should
             (string-prefix-p
              "proofread--request-log-safe-object-"
              (symbol-name sanitizer)))
            (should (fboundp sanitizer))))))
    (should (equal event-types expected-types))
    (dolist (entry event-schema)
      (let ((fields (cdr entry)))
        (should
         (equal (mapcar #'car fields)
                (delete-dups (mapcar #'car fields))))
        (dolist (field fields)
          (should (= (length field) 2))
          (should (keywordp (car field)))
          (let ((sanitizer (cadr field)))
            (should (symbolp sanitizer))
            (should
             (string-prefix-p
              "proofread--request-log-safe-event-"
              (symbol-name sanitizer)))
            (should (fboundp sanitizer))))))))

(ert-deftest proofread-test-request-log-event-schema-golden-projections ()
  "Project every request event to its complete safe visible shape."
  (with-temp-buffer
    (let* ((sentinel
            "PROOFREAD-TEST-EVENT-SCHEMA-SECRET-MUST-NOT-APPEAR")
           (opaque (vector 'provider :secret sentinel))
           (time '(1 2 3 4))
           (request
            (list :id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :text "helo"
                  :backend proofread-test--backend
                  :checker-options opaque
                  :provider opaque))
           (safe-request
            (list :id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :text "helo"
                  :backend proofread-test--backend))
           (chunk
            (list :beg 2
                  :end 6
                  :text "helo"
                  :context-before "Before."
                  :context-after "After."
                  :language "en-US"
                  :major-mode 'text-mode
                  :target-kind 'text
                  :domain-beg 1
                  :domain-end 8
                  :accessible-beg 1
                  :accessible-end 8
                  :provider opaque))
           (safe-chunk
            '( :beg 2
               :end 6
               :text "helo"
               :context-before "Before."
               :context-after "After."
               :language "en-US"
               :major-mode text-mode
               :target-kind text
               :domain-beg 1
               :domain-end 8
               :accessible-beg 1
               :accessible-end 8))
           (diagnostic
            (list :beg 2
                  :end 6
                  :text "helo"
                  :kind 'spelling
                  :message "Possible misspelling"
                  :target-kind 'text
                  :language "en-US"
                  :display-language "English"
                  :profile 'writing
                  :checker-name 'strict
                  :checker-ordinal 1
                  :checker-owner
                  '( :profile writing :checker-name strict :ad-hoc nil)
                  :source-label "Test checker"
                  :source 'test
                  :suggestions '("hello")
                  :provider opaque))
           (safe-diagnostic
            '( :beg 2
               :end 6
               :text "helo"
               :kind spelling
               :message "Possible misspelling"
               :target-kind text
               :language "en-US"
               :display-language "English"
               :profile writing
               :checker-name strict
               :checker-ordinal 1
               :checker-owner
               ( :profile writing :checker-name strict :ad-hoc nil)
               :source-label "Test checker"
               :source test
               :suggestions ("hello")))
           (entry
            (list :text "helo"
                  :diagnostics (list diagnostic)
                  :provider opaque))
           (safe-entry
            (list :text "helo"
                  :diagnostics (list safe-diagnostic)))
           (result
            (list :status 'error
                  :source 'network
                  :partial t
                  :phase 'parse
                  :diagnostics (list diagnostic)
                  :error (list 'proofread-test-backend-error opaque)
                  :message opaque
                  :provider opaque))
           (safe-result
            (list :status 'error
                  :source 'network
                  :partial t
                  :phase 'parse
                  :diagnostics (list safe-diagnostic)
                  :error 'proofread-test-backend-error
                  :message "Backend request failed"))
           (url
            (concat
             "https://private-user:private-password@example.test:9443"
             "/v2/check?api-key=private-key#private-fragment"))
           (common-input
            (list :time time
                  :log-id 31
                  :request-id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :status 'waiting
                  :request request))
           (common-expected
            (list :time time
                  :log-id 31
                  :request-id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :status 'waiting
                  :request safe-request))
           (cases
            (list
             (list 'chunk-request
                   (list :chunk chunk)
                   (list :chunk safe-chunk))
             (list 'queued-request
                   (list :backend proofread-test--backend)
                   (list :backend proofread-test--backend))
             (list 'active-request
                   (list :backend proofread-test--backend)
                   (list :backend proofread-test--backend))
             (list 'backend-dispatched
                   (list :backend proofread-test--backend)
                   (list :backend proofread-test--backend))
             (list
              'backend-request
              (list :backend proofread-test--backend
                    :method "POST"
                    :url url
                    :parameters "language=en-US&text=helo"
                    :pass 1
                    :max-passes 2
                    :strategy 'json
                    :schema "{\"type\":\"object\"}"
                    :prompt-text "Review this text: helo."
                    :reported-diagnostics (list diagnostic))
              (list :backend proofread-test--backend
                    :method "POST"
                    :pass 1
                    :max-passes 2
                    :strategy 'json
                    :url "https://example.test:9443"
                    :parameters "language=en-US&text=helo"
                    :schema "{\"type\":\"object\"}"
                    :prompt-text "Review this text: helo."
                    :reported-diagnostics (list safe-diagnostic)))
             (list
              'backend-response
              (list :backend proofread-test--backend
                    :url url
                    :http-status 503
                    :pass 1
                    :response "Safe provider response"
                    :error (list 'file-error opaque)
                    :message opaque)
              (list :backend proofread-test--backend
                    :http-status 503
                    :pass 1
                    :url "https://example.test:9443"
                    :response "Safe provider response"
                    :error 'file-error
                    :message "Backend request failed"))
             (list
              'backend-result
              (list :backend proofread-test--backend
                    :pass 1
                    :source 'network
                    :entry entry
                    :result result)
              (list :backend proofread-test--backend
                    :pass 1
                    :source 'network
                    :entry safe-entry
                    :result safe-result))
             (list 'cache-hit
                   (list :entry entry)
                   (list :entry safe-entry))
             (list 'cancelled
                   (list :reason 'cleared)
                   (list :reason 'cleared))
             (list 'final-result
                   (list :result result)
                   (list :result safe-result))
             (list
              'checker-dispatch-failed
              (list :profile 'writing
                    :checker-name 'strict
                    :backend proofread-test--backend
                    :phase 'checker-options
                    :error (list 'wrong-type-argument opaque))
              (list :profile 'writing
                    :checker-name 'strict
                    :backend proofread-test--backend
                    :phase 'checker-options
                    :error 'wrong-type-argument
                    :message
                    "Checker strict failed during checker options snapshot"))))
           (event-types
            '( chunk-request queued-request active-request
               backend-dispatched backend-request backend-response
               backend-result cache-hit cancelled final-result
               checker-dispatch-failed)))
      (should (equal (mapcar #'car cases) event-types))
      (dolist (case cases)
        (let* ((type (car case))
               (event
                (append
                 (list :type type)
                 common-input
                 (cadr case)
                 (list :unknown opaque
                       :checker-options opaque
                       :prompt opaque
                       :provider opaque
                       :handle opaque)))
               (expected
                (append (list :type type)
                        common-expected
                        (caddr case)))
               (safe (proofread--request-log-safe-event event)))
          (should (equal safe expected))
          (proofread-test--assert-secret-not-printed sentinel safe)
          (dolist (property
                   '( :unknown :checker-options :prompt :provider
                      :handle))
            (should-not (plist-member safe property))))))))

(ert-deftest
    proofread-test-request-log-event-schema-bounds-malformed-payloads ()
  "Reject malformed events or reduce them to bounded safe values."
  (let* ((sentinel
          "PROOFREAD-TEST-MALFORMED-EVENT-MUST-NOT-APPEAR")
         (opaque-symbol 'proofread-test-unknown-event)
         (opaque (vector 'provider :secret sentinel))
         (events
          (list
           nil
           opaque
           (cons :type 'backend-request)
           '( :type backend-request :method)
           (list :type opaque-symbol :request opaque)
           (list :type 'chunk-request :chunk opaque)
           (list :type 'backend-request
                 :schema opaque
                 :prompt-text opaque
                 :reported-diagnostics opaque)
           (list :type 'backend-response
                 :url sentinel
                 :response opaque
                 :error opaque
                 :message opaque)
           (list :type 'backend-result
                 :entry opaque
                 :result
                 (list :status opaque
                       :request opaque
                       :diagnostics (list opaque)
                       :error opaque
                       :message opaque))
           (list :type 'cache-hit :entry opaque)
           (list :type 'final-result :result opaque)
           (list :type 'checker-dispatch-failed
                 :profile opaque
                 :checker-name opaque
                 :backend opaque
                 :phase opaque
                 :error opaque))))
    (dolist (event events)
      (let ((safe (proofread--request-log-safe-event event)))
        (should (proper-list-p safe))
        (should (< (length (prin1-to-string safe)) 1024))
        (proofread-test--assert-secret-not-printed sentinel safe)))))

(ert-deftest proofread-test-request-log-unknown-event-keeps-common-fields ()
  "Keep only safe common fields for an unknown request event type."
  (with-temp-buffer
    (let* ((sentinel "PROOFREAD-TEST-UNKNOWN-EVENT-MUST-NOT-APPEAR")
           (event
            (list :type 'proofread-test-unknown-event
                  :time '(1 2 3 4)
                  :log-id 31
                  :request-id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :status 'waiting
                  :request
                  (list :id 17
                        :buffer (current-buffer)
                        :beg 2
                        :end 6
                        :text "helo"
                        :checker-options sentinel)
                  :backend proofread-test--backend
                  :message sentinel
                  :unknown sentinel))
           (safe (proofread--request-log-safe-event event)))
      (should
       (equal
        safe
        (list :type 'proofread-test-unknown-event
              :time '(1 2 3 4)
              :log-id 31
              :request-id 17
              :buffer (current-buffer)
              :beg 2
              :end 6
              :status 'waiting
              :request
              (list :id 17
                    :buffer (current-buffer)
                    :beg 2
                    :end 6
                    :text "helo"))))
      (proofread-test--assert-secret-not-printed sentinel safe)
      (dolist (property '( :backend :message :unknown))
        (should-not (plist-member safe property))))))

(ert-deftest
    proofread-test-request-log-event-schema-preserves-empty-fields ()
  "Preserve established explicit nil and derived request fields."
  (with-temp-buffer
    (let* ((request
            (list :id 17
                  :buffer (current-buffer)
                  :beg 2
                  :end 6
                  :text "helo"))
           (safe-request (copy-sequence request)))
      (dolist
          (case
           '( (( :type chunk-request)
               ( :type chunk-request :chunk nil))
              (( :type backend-result)
               ( :type backend-result :result nil))
              (( :type cache-hit)
               ( :type cache-hit :entry nil))
              (( :type final-result)
               ( :type final-result :result nil))
              (( :type backend-response :error nil :message nil)
               ( :type backend-response
                 :error nil
                 :message "Backend request failed"))
              (( :type checker-dispatch-failed)
               ( :type checker-dispatch-failed
                 :error nil
                 :message "Checker nil failed during nil"))
              (( :type backend-request :backend nil)
               ( :type backend-request :backend nil))))
        (should
         (equal (proofread--request-log-safe-event (car case))
                (cadr case))))
      (should
       (equal
        (proofread--request-log-safe-event
         (list :type 'final-result
               :result (list :status 'ok :request request)))
        (list :type 'final-result
              :request safe-request
              :result
              (list :status 'ok :request safe-request)))))))

(ert-deftest
    proofread-test-request-log-sanitizes-normal-events-once ()
  "Sanitize one normal event once across recording, hooks, and reads."
  (let ((proofread--request-log-sources nil)
        (proofread-request-log-hook nil)
        (original-sanitizer
         (symbol-function 'proofread--request-log-safe-event)))
    (with-temp-buffer
      (let* ((source (current-buffer))
             (request
              (list :id 71
                    :buffer source
                    :beg 1
                    :end 5
                    :text "helo"))
             (sanitizations 0)
             first-events
             second-events)
        (setq proofread--request-log-enabled t)
        (setq proofread-request-log-hook
              (list
               (lambda (event)
                 (push event first-events))
               (lambda (event)
                 (push event second-events))))
        (cl-letf
            (((symbol-function 'proofread--request-log-safe-event)
              (lambda (event)
                (setq sanitizations (1+ sanitizations))
                (funcall original-sanitizer event))))
          (proofread--record-request-event
           request 'backend-request
           :backend proofread-test--backend
           :method "POST")
          (should (= sanitizations 1))
          (should (= (length first-events) 1))
          (should (= (length second-events) 1))
          (let ((records (proofread--request-log-record-list source)))
            (should (= (length records) 1))
            (should
             (eq (plist-get (car (plist-get (car records) :events))
                            :type)
                 'backend-request)))
          (should
           (proofread--request-log-lookup-record source 71))
          (should (= sanitizations 1)))))))

(ert-deftest
    proofread-test-request-log-recorder-error-does-not-block-hooks ()
  "Continue public hooks after the internal recorder fails."
  (with-temp-buffer
    (let* ((sentinel
            "PROOFREAD-TEST-RECORDER-ERROR-MUST-NOT-APPEAR")
           (request
            (list :id 72
                  :buffer (current-buffer)
                  :beg 1
                  :end 5
                  :text "helo"))
           observed
           reports
           (proofread-request-log-hook
            (list (lambda (event)
                    (setq observed event)))))
      (cl-letf
          (((symbol-function
             'proofread--request-log-record-canonical-event)
            (lambda (_event)
              (error "%s" sentinel)))
           ((symbol-function
             'proofread-report-warning-without-window)
            (lambda (detail summary)
              (push (list detail summary) reports))))
        (should
         (proofread--record-request-event
          request 'backend-request :method "POST")))
      (should (eq (plist-get observed :type) 'backend-request))
      (should
       (equal reports
              '(( "Proofread request log recorder error (error)"
                  "request log recorder failed; see *Warnings*"))))
      (proofread-test--assert-secret-not-printed sentinel observed)
      (proofread-test--assert-secret-not-printed sentinel reports))))

(ert-deftest
    proofread-test-request-log-updates-history-without-rescanning ()
  "Sanitize each appended event once and expose histories in order."
  (let ((original-sanitizer
         (symbol-function 'proofread--request-log-safe-event)))
    (with-temp-buffer
      (let* ((source (current-buffer))
             (request
              (list :id 88
                    :buffer source
                    :beg 1
                    :end 5
                    :text "helo"))
             (result
              (list :status 'ok
                    :request request
                    :diagnostics nil))
             (specific-events
              (list
               (list :type 'chunk-request :chunk request)
               (list :type 'backend-request :pass 1)
               (list :type 'backend-request :pass 2)
               (list :type 'backend-response :pass 1)
               (list :type 'backend-response :pass 2)
               (list :type 'backend-result :result result)
               (list :type 'final-result
                     :status 'applied
                     :result result)))
             (expected-types
              '( chunk-request backend-request backend-request
                 backend-response backend-response backend-result
                 final-result))
             (sanitizations 0)
             (index 0))
        (setq proofread--request-log-enabled t)
        (cl-letf
            (((symbol-function 'proofread--request-log-safe-event)
              (lambda (event)
                (setq sanitizations (1+ sanitizations))
                (funcall original-sanitizer event))))
          (dolist (specific specific-events)
            (setq index (1+ index))
            (proofread--request-log-record-event
             (append
              (list :time (list 1 index 0 0)
                    :log-id 88
                    :request-id 88
                    :buffer source
                    :beg 1
                    :end 5
                    :request request)
              specific)))
          (should (= sanitizations (length specific-events)))
          (let* ((records
                  (proofread--request-log-record-list source))
                 (record (car records)))
            (should (= (length records) 1))
            (should
             (equal
              (mapcar (lambda (event)
                        (plist-get event :type))
                      (plist-get record :events))
              expected-types))
            (should
             (equal
              (mapcar (lambda (event)
                        (plist-get event :pass))
                      (plist-get record :backend-requests))
              '(1 2)))
            (should
             (equal
              (mapcar (lambda (event)
                        (plist-get event :pass))
                      (plist-get record :backend-responses))
              '(1 2)))
            (should (= (length (plist-get record :backend-results))
                       1)))
          (should
           (proofread--request-log-lookup-record source 88))
          (should (= sanitizations (length specific-events))))))))

(ert-deftest proofread-test-request-log-isolates-hook-mutations ()
  "Give every request-log hook a detached event snapshot."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (request-text (copy-sequence "helo"))
           (request
            (list :id 99
                  :buffer source
                  :beg 1
                  :end 5
                  :text request-text))
           (suggestion (copy-sequence "hello"))
           (diagnostic
            (list :beg 1
                  :end 5
                  :text request-text
                  :kind 'spelling
                  :message "Possible misspelling"
                  :suggestions (list suggestion)))
           (result
            (list :status 'ok
                  :request request
                  :diagnostics (list diagnostic)))
           mutator-event
           observer-event)
      (setq proofread--request-log-enabled t)
      (setq proofread-request-log-hook
            (list
             (lambda (event)
               (setq mutator-event event)
               (let* ((hook-request (plist-get event :request))
                      (hook-result (plist-get event :result))
                      (result-request
                       (plist-get hook-result :request))
                      (hook-diagnostic
                       (car (plist-get hook-result :diagnostics))))
                 (aset (plist-get hook-request :text) 0 ?X)
                 (aset (plist-get result-request :text) 0 ?X)
                 (setcar (plist-get hook-diagnostic :suggestions)
                         "changed")
                 (setf (plist-get hook-result :status) 'error)
                 (setf (plist-get event :status) 'poisoned)))
             (lambda (event)
               (setq observer-event event))))
      (proofread--record-request-event
       request 'backend-result
       :status 'waiting
       :backend proofread-test--backend
       :result result)
      (should mutator-event)
      (should observer-event)
      (should-not (eq mutator-event observer-event))
      (should-not
       (eq (plist-get (plist-get mutator-event :request) :text)
           (plist-get (plist-get observer-event :request) :text)))
      (should (eq (plist-get observer-event :status) 'waiting))
      (should
       (equal (plist-get (plist-get observer-event :request) :text)
              "helo"))
      (let* ((observer-result (plist-get observer-event :result))
             (observer-diagnostic
              (car (plist-get observer-result :diagnostics))))
        (should (eq (plist-get observer-result :status) 'ok))
        (should
         (equal (plist-get observer-diagnostic :suggestions)
                '("hello"))))
      (should (equal request-text "helo"))
      (should (eq (plist-get result :status) 'ok))
      (should (equal (plist-get diagnostic :suggestions)
                     '("hello")))
      (aset (plist-get (plist-get observer-event :request) :text)
            1 ?Y)
      (setf (plist-get observer-event :status) 'observer-poisoned)
      (let* ((record
              (car (proofread--request-log-record-list source)))
             (stored-event (car (plist-get record :events)))
             (stored-result
              (car (plist-get record :backend-results)))
             (stored-diagnostic
              (car (plist-get stored-result :diagnostics))))
        (should (eq (plist-get record :status) 'parsed))
        (should (eq (plist-get stored-event :status) 'waiting))
        (should (eq (plist-get stored-result :status) 'ok))
        (should
         (equal (plist-get (plist-get record :request) :text)
                "helo"))
        (should
         (equal (plist-get stored-diagnostic :suggestions)
                '("hello")))))))

(ert-deftest
    proofread-test-request-log-snapshots-mutable-producer-events ()
  "Snapshot mutable producer data before publishing or recording it."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (raw-text (copy-sequence "helo"))
           (raw-message (copy-sequence "Possible misspelling"))
           (raw-suggestion (copy-sequence "hello"))
           (request
            (list :id 404
                  :buffer source
                  :beg 1
                  :end 5
                  :text raw-text))
           (diagnostic
            (list :beg 1
                  :end 5
                  :text raw-text
                  :kind 'spelling
                  :message raw-message
                  :suggestions (list raw-suggestion)))
           (result
            (list :status 'ok
                  :request request
                  :diagnostics (list diagnostic)))
           observed-event
           returned-event)
      (setq proofread--request-log-enabled t)
      (setq proofread-request-log-hook
            (list (lambda (event)
                    (setq observed-event event))))
      (setq returned-event
            (proofread--record-request-event
             request 'final-result
             :status 'applied
             :result result))
      (should observed-event)
      (should-not
       (eq raw-text
           (plist-get (plist-get returned-event :request) :text)))
      (should-not
       (eq (plist-get (plist-get returned-event :request) :text)
           (plist-get (plist-get observed-event :request) :text)))
      (aset raw-text 0 ?X)
      (aset raw-message 0 ?X)
      (aset raw-suggestion 0 ?X)
      (setf (plist-get result :status) 'error)
      (aset (plist-get (plist-get returned-event :request) :text)
            1 ?Y)
      (setf (plist-get returned-event :status) 'returned-poisoned)
      (should (eq (plist-get observed-event :status) 'applied))
      (should
       (equal (plist-get (plist-get observed-event :request) :text)
              "helo"))
      (let* ((record
              (car (proofread--request-log-record-list source)))
             (stored-result (plist-get record :final-result))
             (stored-diagnostic
              (car (plist-get stored-result :diagnostics))))
        (should (eq (plist-get record :status) 'applied))
        (should (eq (plist-get stored-result :status) 'ok))
        (should
         (equal (plist-get (plist-get record :request) :text)
                "helo"))
        (should
         (equal (plist-get stored-diagnostic :message)
                "Possible misspelling"))
        (should
         (equal (plist-get stored-diagnostic :suggestions)
                '("hello")))))))

(ert-deftest
    proofread-test-request-log-direct-recorder-sanitizes-untrusted-events
    ()
  "Bound and redact an untrusted event passed directly to the recorder."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (sentinel
            "PROOFREAD-TEST-DIRECT-RECORDER-SECRET-MUST-NOT-APPEAR")
           (provider (vector 'provider :secret sentinel))
           (long-error-text
            (concat sentinel (make-string 100000 ?x)))
           (request
            (list :id 505
                  :buffer source
                  :beg 1
                  :end 5
                  :text "helo"
                  :checker-options (list :provider provider)
                  :provider provider))
           safe-event
           record)
      (setq proofread--request-log-enabled t)
      (setq safe-event
            (proofread--request-log-record-event
             (list :type 'backend-response
                   :time '(1 2 3 4)
                   :log-id 505
                   :request-id 505
                   :buffer source
                   :beg 1
                   :end 5
                   :request request
                   :error (list 'file-error long-error-text provider)
                   :message long-error-text
                   :handle provider
                   :opaque provider)))
      (setq record
            (car (proofread--request-log-record-list source)))
      (should (eq (plist-get safe-event :error) 'file-error))
      (should
       (equal (plist-get safe-event :message)
              "Backend request failed"))
      (dolist (property '( :checker-options :provider :handle :opaque))
        (should-not (plist-member safe-event property)))
      (dolist (value (list safe-event record))
        (proofread-test--assert-secret-not-printed sentinel value))
      (should (< (length (prin1-to-string safe-event)) 1024))
      (should (< (length (prin1-to-string record)) 4096))
      (should (eq (plist-get record :status) 'returned))
      (let ((response
             (car (plist-get record :backend-responses))))
        (should (eq (plist-get response :error) 'file-error))
        (should
         (equal (plist-get response :message)
                "Backend request failed"))))))

(ert-deftest proofread-test-request-log-public-reads-are-detached ()
  "Return detached records from list and lookup read boundaries."
  (with-temp-buffer
    (let* ((source (current-buffer))
           (request
            (list :id 606
                  :buffer source
                  :beg 1
                  :end 5
                  :text (copy-sequence "helo")))
           (diagnostic
            (list :beg 1
                  :end 5
                  :text "helo"
                  :kind 'spelling
                  :message "Possible misspelling"
                  :suggestions (list (copy-sequence "hello"))))
           (result
            (list :status 'ok
                  :request request
                  :diagnostics (list diagnostic))))
      (setq proofread--request-log-enabled t)
      (proofread--request-log-record-event
       (list :type 'backend-result
             :time '(1 2 3 4)
             :log-id 606
             :request-id 606
             :buffer source
             :beg 1
             :end 5
             :request request
             :result result))
      (let* ((first-list
              (car (proofread--request-log-record-list source)))
             (first-lookup
              (proofread--request-log-lookup-record source 606))
             (list-request (plist-get first-list :request))
             (lookup-request (plist-get first-lookup :request))
             (list-event (car (plist-get first-list :events)))
             (lookup-event (car (plist-get first-lookup :events)))
             (list-result
              (car (plist-get first-list :backend-results)))
             (lookup-result
              (car (plist-get first-lookup :backend-results)))
             (list-diagnostic
              (car (plist-get list-result :diagnostics)))
             (lookup-diagnostic
              (car (plist-get lookup-result :diagnostics))))
        (should-not (eq first-list first-lookup))
        (should-not (eq list-request lookup-request))
        (should-not
         (eq (plist-get list-request :text)
             (plist-get lookup-request :text)))
        (should-not
         (eq (car (plist-get list-diagnostic :suggestions))
             (car (plist-get lookup-diagnostic :suggestions))))
        (setf (plist-get first-list :status) 'list-poisoned)
        (setf (plist-get list-event :type) 'list-poisoned)
        (aset (plist-get list-request :text) 0 ?X)
        (aset (car (plist-get list-diagnostic :suggestions)) 0 ?X)
        (should (eq (plist-get first-lookup :status) 'parsed))
        (should (eq (plist-get lookup-event :type) 'backend-result))
        (should (equal (plist-get lookup-request :text) "helo"))
        (should
         (equal (plist-get lookup-diagnostic :suggestions)
                '("hello")))
        (setf (plist-get first-lookup :status) 'lookup-poisoned)
        (setf (plist-get lookup-event :type) 'lookup-poisoned)
        (aset (plist-get lookup-request :text) 0 ?Y)
        (aset (car (plist-get lookup-diagnostic :suggestions)) 0 ?Y)
        (let* ((second-list
                (car (proofread--request-log-record-list source)))
               (second-request (plist-get second-list :request))
               (second-event
                (car (plist-get second-list :events)))
               (second-result
                (car (plist-get second-list :backend-results)))
               (second-diagnostic
                (car (plist-get second-result :diagnostics))))
          (should (eq (plist-get second-list :status) 'parsed))
          (should (eq (plist-get second-event :type)
                      'backend-result))
          (should (equal (plist-get second-request :text) "helo"))
          (should
           (equal (plist-get second-diagnostic :suggestions)
                  '("hello"))))))))

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
           raw-work
           payload-snapshot
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
                (setq raw-work (car proofread--active-requests))
                (should (proofread--scheduled-work-p raw-work))
                (should
                 (eq (proofread--scheduled-work-request raw-work)
                     raw-request))
                (should
                 (equal (proofread--plist-keys
                         raw-request "backend request")
                        proofread--backend-request-keys))
                (dolist (property
                         '( :log-id :state :cache-key :handle
                            :batch :batch-settled))
                  (should-not (plist-member raw-request property)))
                (should
                 (eq (car proofread--active-requests) raw-work))
                (should
                 (proofread--scheduled-work-handle raw-work))
                (should
                 (= (gethash raw-request
                             proofread--request-log-owner-ids)
                    (proofread--scheduled-work-log-id raw-work)))
                (setq payload-snapshot (copy-tree raw-request))
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
                       :log-id
                       (proofread--scheduled-work-log-id raw-work)
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
                (should (eq (plist-get raw-result :request)
                            raw-request))
                (should (equal raw-request payload-snapshot))
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
                       '( :checker-options :log-id :state :cache-key
                          :handle :batch :batch-settled))
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
    proofread-test-request-monitor-redacts-checker-options-failure ()
  "Redact opaque condition data from options snapshot failures."
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
      (proofread-register-backend
       backend
       :check
       (lambda (&rest _)
         (setq backend-called t)
         (error "Failing checker must not submit work"))
       :identity
       (lambda ()
         (list :backend backend :contract-version 1))
       :snapshot-options
       (lambda (_options)
         (setq raw-error-text
               (format "Options snapshot failure for %S" provider))
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
                          'checker-options))
              (should (eq (plist-get failure :status) 'error))
              (should (eq (plist-get failure :error) 'error))
              (should (string-match-p
                       "checker options snapshot"
                       (plist-get failure :message)))
              (should (eq (plist-get record :profile) profile))
              (should (eq (plist-get record :checker-name) checker))
              (should (eq (plist-get record :backend) backend))
              (should (eq (plist-get record :phase)
                          'checker-options))
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

(ert-deftest proofread-test-selection-plan-normalizes-raw-ranges ()
  "Retain normalized ranges, complete domains, and selected islands."
  (with-temp-buffer
    (insert "XXabcdefghijYY")
    (narrow-to-region 3 13)
    (let* ((proofread-targets 'all)
           (minimum (point-min))
           (maximum (point-max))
           (marker-beg (copy-marker (+ minimum 6)))
           (marker-end (copy-marker (+ minimum 8)))
           (raw-ranges
            (list (cons marker-beg marker-end)
                  (cons (+ minimum 4) minimum)
                  (cons (- minimum 10) (1+ minimum))
                  (cons maximum (+ maximum 20))
                  (cons (+ minimum 5) (+ minimum 5))
                  (cons nil (+ minimum 2))
                  'invalid))
           (expected-ranges
            (list (cons minimum (+ minimum 4))
                  (cons (+ minimum 6) (+ minimum 8))))
           (plan (proofread--selection-plan-for-ranges raw-ranges))
           (ranges (proofread--selection-plan-ranges plan))
           (domains (proofread--selection-plan-domains plan))
           (islands (proofread--selection-plan-islands plan))
           (domain (car domains)))
      (should (proofread--selection-plan-p plan))
      (should (equal ranges expected-ranges))
      (should (markerp (caar raw-ranges)))
      (should
       (equal (nth 1 raw-ranges)
              (cons (+ minimum 4) minimum)))
      (dolist (range ranges)
        (should (integerp (car range)))
        (should (integerp (cdr range))))
      (should (= (length domains) 1))
      (should (eq (plist-get domain :kind) 'text))
      (should (eq (plist-get domain :target-policy) 'all))
      (should (= (plist-get domain :domain-beg) minimum))
      (should (= (plist-get domain :domain-end) maximum))
      (should
       (equal
        (mapcar (lambda (island)
                  (cons (plist-get island :beg)
                        (plist-get island :end)))
                islands)
        expected-ranges))
      (dolist (island islands)
        (should (= (plist-get island :domain-beg) minimum))
        (should (= (plist-get island :domain-end) maximum))
        (should (eq (plist-get island :target-policy) 'all)))
      (should
       (equal (proofread--target-domains-for-ranges raw-ranges)
              domains))
      (should
       (equal (proofread--target-islands-for-ranges raw-ranges)
              islands)))))

(ert-deftest proofread-test-selection-plan-normalizes-once ()
  "Normalize accessible ranges and snapshot target policy once."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert ";; Comment prose.\n"
            "(defun sample ()\n"
            "  \"Docstring prose.\")\n")
    (setq-local proofread-targets 'comments-and-docstrings)
    (goto-char (point-max))
    (push-mark (point-min) t t)
    (let ((normalizer
           (symbol-function 'proofread--normalize-accessible-ranges))
          (policy-function
           (symbol-function 'proofread--effective-target-policy))
          (normalization-count 0)
          (policy-count 0)
          (before-point (point))
          (before-mark (mark t))
          (before-mark-active mark-active))
      (cl-letf
          (((symbol-function 'proofread--normalize-accessible-ranges)
            (lambda (ranges)
              (setq normalization-count (1+ normalization-count))
              (funcall normalizer ranges)))
           ((symbol-function 'proofread--effective-target-policy)
            (lambda ()
              (setq policy-count (1+ policy-count))
              (funcall policy-function))))
        (let* ((plan
                (proofread--selection-plan-for-ranges
                 (list (cons (point-max) (point-min)))))
               (domains (proofread--selection-plan-domains plan)))
          (should (= normalization-count 1))
          (should (= policy-count 1))
          (should
           (equal (proofread--selection-plan-ranges plan)
                  (list (cons (point-min) (point-max)))))
          (should
           (equal (mapcar (lambda (domain)
                            (plist-get domain :kind))
                          domains)
                  '( comment docstring)))
          (dolist (domain domains)
            (should
             (eq (plist-get domain :target-policy)
                 'comments-and-docstrings)))))
      (should (= (point) before-point))
      (should (= (mark t) before-mark))
      (should (eq mark-active before-mark-active)))))

(ert-deftest proofread-test-selection-plan-retains-discovered-domains
    ()
  "Keep discovery domains instead of rebuilding them from islands."
  (with-temp-buffer
    (text-mode)
    (insert "abcd")
    (let* ((token (list 'discovery-token))
           (domain
            (list :kind 'text
                  :target-policy 'all
                  :domain-beg (point-min)
                  :domain-end (point-max)
                  :token token))
           arguments
           plan)
      (cl-letf
          (((symbol-function
             'proofread--target-domains-in-normalized-ranges)
            (lambda (ranges policy minimum maximum)
              (setq arguments
                    (list ranges policy minimum maximum))
              (list domain))))
        (setq plan
              (proofread--selection-plan-for-ranges '((2 . 4)))))
      (should (equal arguments '(((2 . 4)) all 1 5)))
      (should
       (eq (car (proofread--selection-plan-domains plan)) domain))
      (should
       (eq (plist-get
            (car (proofread--selection-plan-islands plan)) :token)
           token)))))

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
        (let ((proofread-test--backend-check-function
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
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work))
           (beg (plist-get request :beg))
           (diagnostic
            (proofread-test--diagnostic-for-range
             beg (+ beg 7)
             (buffer-substring-no-properties beg (+ beg 7)))))
      (setq-local proofread-targets 'all)
      (should (eq (proofread--handle-backend-result
                   work
                   (proofread--backend-success-result
                    request (list diagnostic)))
                  'stale))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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
             (request (proofread-test--make-profile-request chunk))
             (work (proofread--make-request-work request)))
        (goto-char (point-min))
        (search-forward "cursor_and_mark")
        (push-mark (line-end-position) t t)
        (let ((before-point (point))
              (before-mark (mark t))
              (before-mark-active mark-active))
          (should (proofread--fresh-request-p work))
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
               (proofread-profile 'disabled)
               (proofread-profiles '((disabled :checkers nil))))
          (proofread-test--publish-diagnostics
           (list valid invalid outside))
          (proofread-check-region (point-min) check-end)
          (should (equal proofread--diagnostics (list valid outside)))
          (should
           (equal (proofread-test--flymake-proofread-diagnostics)
                  (list valid outside))))))))

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
           (ranges (list (cons (point-min) (point-max))))
           (domains
            (list (list :kind 'text
                        :target-policy 'all
                        :domain-beg (point-min)
                        :domain-end (point-max))))
           (plan
            (proofread--make-selection-plan ranges domains nil)))
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread--prune-invalid-checked-diagnostics
       plan '( :checkers nil))
      (should (equal proofread--diagnostics (list diagnostic)))
      (should (eq (proofread-diagnostic-at-point position)
                  diagnostic)))))

(ert-deftest
    proofread-test-check-pruning-is-atomic-and-owner-complete ()
  "Prune all invalid checked diagnostics in one observable change."
  (with-temp-buffer
    (insert "abcdefghijklmnopqrst")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (let* ((active-checker
            (list :profile 'multi
                  :name 'active
                  :backend proofread-test--backend))
           (unsupported-checker
            (list :profile 'multi
                  :name 'unsupported
                  :backend 'proofread-test-pruning-unsupported))
           (profile
            (list :name 'multi
                  :checkers
                  (list active-checker unsupported-checker)))
           (active-owner
            (proofread--checker-owner active-checker))
           (unsupported-owner
            (proofread--checker-owner unsupported-checker))
           (inactive-owner
            '( :profile multi :checker-name inactive))
           (ad-hoc-owner
            '( :profile ad-hoc :checker-name ad-hoc :ad-hoc t))
           (active
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 1 2 "a")
             'active))
           (unsupported
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 3 4 "c")
             'unsupported))
           (inactive
            (proofread-test--diagnostic-with-checker
             (proofread-test--diagnostic-for-range 5 6 "e")
             'inactive))
           (unowned
            (proofread-test--diagnostic-for-range 7 8 "g"))
           (ad-hoc
            (plist-put
             (proofread-test--diagnostic-for-range 8 9 "h")
             :checker-owner ad-hoc-owner))
           (ignored
            (plist-put
             (proofread-test--diagnostic-for-range 9 10 "i")
             :checker-owner ad-hoc-owner))
           (outside-target
            (proofread-test--diagnostic-for-range 12 13 "l"))
           (unchecked
            (plist-put
             (proofread-test--diagnostic-for-range 17 18 "q")
             :checker-owner inactive-owner))
           (diagnostics
            (list active unsupported inactive unowned ad-hoc ignored
                  outside-target unchecked))
           (_published-diagnostics
            (proofread-test--publish-diagnostics diagnostics))
           (retained
            (list active unsupported unowned ad-hoc unchecked))
           (ranges '((1 . 15)))
           (domains
            '(( :kind text :target-policy all
                :domain-beg 1 :domain-end 11)))
           (plan
            (proofread--make-selection-plan ranges domains nil))
           (checked-function
            (symbol-function 'proofread--checked-diagnostic-entries))
           (sort-function
            (symbol-function 'proofread--sorted-target-domains))
           (candidate-scan-count 0)
           (domain-sort-count 0)
           (report-count 0)
           (hook-count 0)
           reentrant-p
           report-arguments
           hook-flymake
           observed)
      (should-not
       (proofread--supported-backend-p
        'proofread-test-pruning-unsupported))
      (should (equal active-owner
                     (plist-get active :checker-owner)))
      (should (equal unsupported-owner
                     (plist-get unsupported :checker-owner)))
      (add-text-properties 9 10 '( proofread-test-ignore t))
      (let ((proofread-ignored-properties '( proofread-test-ignore)))
        (flymake-start)
        (let ((original-report-function
               proofread--flymake-report-function))
          (setq proofread--flymake-report-function
                (lambda (&rest arguments)
                  (setq report-count (1+ report-count))
                  (setq report-arguments arguments)
                  (apply original-report-function arguments))))
        (add-hook
         'proofread-diagnostics-changed-hook
         (lambda ()
           (setq hook-count (1+ hook-count))
           (push (copy-sequence proofread--diagnostics) observed)
           (setq hook-flymake
                 (proofread-test--flymake-proofread-diagnostics))
           (when (= hook-count 1)
             (setq reentrant-p t)
             (unwind-protect
                 (proofread--prune-invalid-checked-diagnostics
                  plan profile)
               (setq reentrant-p nil))))
         nil t)
        (cl-letf
            (((symbol-function 'proofread--checked-diagnostic-entries)
              (lambda (checked-ranges)
                (unless reentrant-p
                  (setq candidate-scan-count
                        (1+ candidate-scan-count)))
                (funcall checked-function checked-ranges)))
             ((symbol-function 'proofread--sorted-target-domains)
              (lambda (target-domains)
                (unless reentrant-p
                  (setq domain-sort-count (1+ domain-sort-count)))
                (funcall sort-function target-domains))))
          (proofread--prune-invalid-checked-diagnostics
           plan profile)))
      (should (= candidate-scan-count 1))
      (should (= domain-sort-count 1))
      (should (= report-count 1))
      (should (= hook-count 1))
      (should (equal (cdr report-arguments)
                     '(:region (1 . 15))))
      (should
       (equal
        (mapcar #'proofread--flymake-to-diagnostic
                (car report-arguments))
        (list active unsupported unowned ad-hoc)))
      (should (equal (car observed) retained))
      (should (equal proofread--diagnostics retained))
      (should (= (length hook-flymake) (length retained)))
      (dolist (diagnostic retained)
        (should (memq diagnostic hook-flymake)))
      (dolist (diagnostic (list inactive ignored outside-target))
        (should-not (memq diagnostic hook-flymake))))))

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
        (let ((proofread-test--backend-check-function
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
             (work (proofread--make-request-work request))
             (chars-tick (buffer-chars-modified-tick)))
        (add-text-properties
         (plist-get request :beg)
         (1+ (plist-get request :beg))
         '( proofread-test-ignore t))
        (should (= chars-tick (buffer-chars-modified-tick)))
        (should-not (proofread--fresh-request-p work)))))
  (with-temp-buffer
    (insert "Beta prose.")
    (setq-local proofread-auto-check nil)
    (proofread-mode 1)
    (proofread-test--with-profile
      (let* ((chunk
              (car (proofread-test--request-ready-chunks-for-ranges
                    (list (cons (point-min) (point-max))))))
             (request (proofread-test--make-profile-request chunk))
             (work (proofread--make-request-work request)))
        (setq-local proofread-ignored-properties
                    '( proofread-test-ignore))
        (should (proofread--fresh-request-p work))))))

(ert-deftest
    proofread-test-docstring-predicates-isolate-errors-and-short-circuit
    ()
  "Continue after predicate errors and stop after the first match."
  (let (calls)
    (let ((proofread-docstring-predicate-functions
           (list
            'not-a-function
            (lambda (beg end)
              (push (list 'error beg end) calls)
              (error "Simulated predicate failure"))
            (lambda (beg end)
              (push (list 'miss beg end) calls)
              nil)
            (lambda (beg end)
              (push (list 'match beg end) calls)
              'accepted)
            (lambda (_beg _end)
              (ert-fail "Predicate evaluation did not short-circuit")))))
      (should (eq (proofread--docstring-predicate-matches-p 3 9)
                  t))
      (should (equal (nreverse calls)
                     '((error 3 9) (miss 3 9) (match 3 9)))))
    (setq calls nil)
    (let ((proofread-docstring-predicate-functions
           (list
            (lambda (_beg _end)
              (push 'error calls)
              (error "Simulated predicate failure"))
            (lambda (_beg _end)
              (push 'miss calls)
              nil))))
      (should-not (proofread--docstring-predicate-matches-p 1 2))
      (should (equal (nreverse calls) '( error miss))))))

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
        (let ((proofread-test--backend-check-function
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
                   (new-work (car proofread--active-requests)))
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
              (should (eq (proofread-test--work-request new-work)
                          new-request))
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
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work))
           (original-remove-active-request
            (symbol-function 'proofread--remove-active-request))
           (original-dispatch-queued-requests
            (symbol-function 'proofread--dispatch-queued-requests))
           captured-callback
           (callback-calls 0)
           (cleanup-calls 0)
           (queue-continuations 0))
      (let ((proofread-test--backend-check-function
             (lambda (_request callback)
               (setq captured-callback callback)
               'proofread-test-handle)))
        (cl-letf
            (((symbol-function 'proofread--remove-active-request)
              (lambda (active-work)
                (setq cleanup-calls (1+ cleanup-calls))
                (funcall original-remove-active-request active-work)))
             ((symbol-function 'proofread--dispatch-queued-requests)
              (lambda ()
                (setq queue-continuations (1+ queue-continuations))
                (funcall original-dispatch-queued-requests))))
          (proofread--dispatch-backend-request
           work
           (lambda (_result)
             (setq callback-calls (1+ callback-calls))
             'proofread-test-callback-value))
          (let ((result (proofread--backend-success-result request nil)))
            (should (eq (funcall captured-callback result)
                        'proofread-test-callback-value))
            (should-not (funcall captured-callback result))))
        (should (= callback-calls 1))
        (should (= cleanup-calls 1))
        (should (= queue-continuations 1))
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-running-backend-callback-is-at-most-once ()
  "Ignore a reentrant backend callback while settlement is running."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work))
           (original-remove-active-request
            (symbol-function 'proofread--remove-active-request))
           (original-dispatch-queued-requests
            (symbol-function 'proofread--dispatch-queued-requests))
           captured-callback
           reentrant-value
           (callback-calls 0)
           (cleanup-calls 0)
           (queue-continuations 0))
      (let ((proofread-test--backend-check-function
             (lambda (_request callback)
               (setq captured-callback callback)
               'proofread-test-handle)))
        (cl-letf
            (((symbol-function 'proofread--remove-active-request)
              (lambda (active-work)
                (setq cleanup-calls (1+ cleanup-calls))
                (funcall original-remove-active-request active-work)))
             ((symbol-function 'proofread--dispatch-queued-requests)
              (lambda ()
                (setq queue-continuations (1+ queue-continuations))
                (funcall original-dispatch-queued-requests))))
          (proofread--dispatch-backend-request
           work
           (lambda (result)
             (setq callback-calls (1+ callback-calls))
             (setq reentrant-value
                   (funcall captured-callback result))
             'proofread-test-callback-value))
          (should
           (eq
            (funcall captured-callback
                     (proofread--backend-success-result request nil))
            'proofread-test-callback-value)))
        (should-not reentrant-value)
        (should (= callback-calls 1))
        (should (= cleanup-calls 1))
        (should (= queue-continuations 1))
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-failed-backend-callback-cleans-up-once ()
  "Clean active state and continue the queue once when a callback fails."
  (with-temp-buffer
    (insert "Alpha")
    (proofread-mode 1)
    (let* ((chunk
            (car (proofread-test--request-ready-chunks-for-ranges
                  (list (cons (point-min) (point-max))))))
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work))
           (original-remove-active-request
            (symbol-function 'proofread--remove-active-request))
           (original-dispatch-queued-requests
            (symbol-function 'proofread--dispatch-queued-requests))
           captured-callback
           active-at-callback
           (callback-calls 0)
           (cleanup-calls 0)
           (queue-continuations 0))
      (let ((proofread-test--backend-check-function
             (lambda (_request callback)
               (setq captured-callback callback)
               'proofread-test-handle)))
        (cl-letf
            (((symbol-function 'proofread--remove-active-request)
              (lambda (active-work)
                (setq cleanup-calls (1+ cleanup-calls))
                (funcall original-remove-active-request active-work)))
             ((symbol-function 'proofread--dispatch-queued-requests)
              (lambda ()
                (setq queue-continuations (1+ queue-continuations))
                (funcall original-dispatch-queued-requests))))
          (proofread--dispatch-backend-request
           work
           (lambda (_result)
             (setq callback-calls (1+ callback-calls))
             (setq active-at-callback
                   (proofread--active-request-p work))
             (error "Simulated callback failure")))
          (let* ((result (proofread--backend-success-result request nil))
                 (condition
                  (should-error
                   (funcall captured-callback result)
                   :type 'error)))
            (should
             (equal (error-message-string condition)
                    "Simulated callback failure"))
            (should-not (funcall captured-callback result))))
        (should-not active-at-callback)
        (should (= callback-calls 1))
        (should (= cleanup-calls 1))
        (should (= queue-continuations 1))
        (should-not proofread--active-requests)))))

(ert-deftest proofread-test-repeated-mode-enable-resets-owned-state ()
  "Explicitly enabling an enabled mode starts a clean generation."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((generation proofread--generation)
          (diagnostic (proofread-test--diagnostic-for-range 1 5
                                                            "helo")))
      (proofread-test--publish-diagnostics (list diagnostic))
      (proofread--cache-write 'old-cache 'old-value)
      (proofread-mode 1)
      (should proofread-mode)
      (should-not (= proofread--generation generation))
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics))
      (should-not proofread--active-requests)
      (should (proofread--request-queue-empty-p))
      (should (= (hash-table-count proofread--cache) 0))
      (should (= (cl-count #'proofread--window-scroll
                           window-scroll-functions)
                 1))
      (should
       (= (cl-count #'proofread--mark-pending-work
                    window-configuration-change-hook)
          1)))))

(ert-deftest
    proofread-test-major-mode-change-tears-down-proofread-mode ()
  "Changing major mode removes Proofread hooks and owned state."
  (with-temp-buffer
    (insert "helo")
    (proofread-mode 1)
    (let ((diagnostic (proofread-test--diagnostic-for-range 1 5
                                                            "helo"))
          (report-function proofread--flymake-report-function)
          report-calls)
      (proofread-test--publish-diagnostics (list diagnostic))
      (setq proofread--flymake-report-function
            (lambda (&rest arguments)
              (push arguments report-calls)
              (apply report-function arguments)))
      (narrow-to-region 2 3)
      (text-mode)
      (should-not proofread-mode)
      (should (equal report-calls
                     '((nil :region (1 . 5)))))
      (should-not proofread--diagnostics)
      (should-not (memq (current-buffer) proofread--mode-buffers))
      (should-not proofread--flymake-report-function)
      (should-not
       (memq #'proofread--flymake-backend
             flymake-diagnostic-functions))
      (should-not
       (memq #'proofread--flymake-mode-changed flymake-mode-hook))
      (should-not (memq #'proofread--before-change
                        before-change-functions))
      (should-not (memq #'proofread--window-scroll
                        window-scroll-functions))
      (should-not
       (memq #'proofread--mark-pending-work
             window-configuration-change-hook)))))

(ert-deftest
    proofread-test-zero-width-diagnostic-invalidated-by-insertion ()
  "Clear owned state after inserting at a zero-width diagnostic."
  (with-temp-buffer
    (insert "ab")
    (proofread-mode 1)
    (let ((diagnostic
           (proofread--make-diagnostic
            :beg 2 :end 2 :text "" :kind 'grammar
            :message "Missing punctuation" :suggestions '( ",")
            :source 'test)))
      (proofread-test--publish-diagnostics (list diagnostic))
      (goto-char 2)
      (insert ",")
      (should-not proofread--diagnostics)
      (should-not (proofread-test--flymake-proofread-diagnostics)))))

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
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work)))
      (goto-char (point-min))
      (insert "helo ")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p work)))))

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
               (work (proofread--make-request-work request))
               (key (proofread--scheduled-work-cache-key work))
               (diagnostic
                (proofread-test--diagnostic-for-range 1 6 "Alpha")))
          (let ((proofread-test--backend-identity-token "identity-b"))
            (proofread--cache-write-request work (list diagnostic))
            (should (equal (proofread--scheduled-work-cache-key work)
                           key))
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
               (work (proofread--make-request-work request))
               (work-key-text
                (prin1-to-string (proofread--request-work-key work))))
          (proofread--enqueue-requests (list work))
          (aset name 0 ?o)
          (should
           (equal (plist-get (plist-get request :backend-identity)
                             :token)
                  '( :name "alpha")))
          (should (equal (prin1-to-string
                          (proofread--request-work-key work))
                         work-key-text))
          (should (proofread--request-work-pending-p work))
          (should-not (proofread--fresh-request-p work)))))))

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
               (request (proofread-test--make-profile-request chunk))
               (work
                (proofread--make-request-work
                 request)))
          (let ((proofread-test--backend-identity-token "identity-b"))
            (should-not (proofread--fresh-request-p work))))))))

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
           (work
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (request (proofread-test--work-request work)))
      (goto-char (point-min))
      (delete-char 1)
      (insert "X")
      (should (equal
               (buffer-substring-no-properties
                (plist-get request :beg) (plist-get request :end))
               (plist-get request :text)))
      (should-not (proofread--fresh-request-p work)))))

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
           (queue-state (proofread--make-queue-state))
           (queued-selected-entry
            (proofread--new-request-queue-entry
             queue-state queued-selected))
           (queued-retained-entry
            (proofread--new-request-queue-entry
             queue-state queued-retained))
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
           (proofread--queue-state
            (progn
              (proofread--append-request-queue-entry
               queue-state queued-selected-entry)
              (proofread--append-request-queue-entry
               queue-state queued-retained-entry)
              queue-state))
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
                            (proofread--request-queue-works)
                            (list queued-retained replacement))
                           (eq
                            (proofread--queue-state-tail
                             proofread--queue-state)
                            (car (last
                                  (proofread--request-queue-entries))))
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
          (should (eq (proofread--request-queue-head)
                      queued-retained-entry))
          (should (eq (proofread--queue-state-tail
                       proofread--queue-state)
                      queued-retained-entry))
          (should-not event-trace)
          (should-not cancelled-handles)
          (proofread--enqueue-requests (list replacement))
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
           (queue-state (proofread--make-queue-state))
           (queued-selected-entry
            (proofread--new-request-queue-entry
             queue-state queued-selected))
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
           (proofread--queue-state
            (progn
              (proofread--append-request-queue-entry
               queue-state queued-selected-entry)
              queue-state))
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
                           (proofread--request-queue-empty-p)
                           (null (proofread--queue-state-tail
                                  proofread--queue-state))
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
                    (proofread--enqueue-requests (list late)))
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
                        (proofread--request-queue-works)
                        (list late))
                       (eq
                        (proofread--queue-state-tail
                         proofread--queue-state)
                        (car (last
                              (proofread--request-queue-entries))))))
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
           (older
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (newer
            (proofread-test--make-request-work
             chunk proofread-test--backend))
           (older-request (proofread-test--work-request older))
           (newer-request (proofread-test--work-request newer))
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
                   newer
                   (proofread--backend-success-result
                    newer-request (list new-diagnostic)))
                  'applied))
      (should (eq (proofread--handle-backend-result
                   older
                   (proofread--backend-success-result
                    older-request (list old-diagnostic)))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (matching-a
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               (unrelated-b
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 2 chunks))))
               (matching-b
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 3 chunks))))
               (works
                (list unrelated-a matching-a unrelated-b matching-b))
               entries
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (should
           (equal (proofread--scheduled-work-cache-key matching-a)
                  (proofread--scheduled-work-cache-key matching-b)))
          (should-not
           (equal (proofread--scheduled-work-cache-key matching-a)
                  (proofread--scheduled-work-cache-key unrelated-a)))
          (proofread--enqueue-requests works)
          (setq entries (proofread--request-queue-entries))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--cache-write-request
           matching-a
           (list
            (proofread-test--diagnostic-for-range 4 6 "aa")))
          (should (= (hash-table-count
                      (proofread--queue-state-woken
                       proofread--queue-state))
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
                  (list (proofread--scheduled-work-log-id matching-a)
                        (proofread--scheduled-work-log-id matching-b))))
          (should (= (proofread--request-queue-length) 2))
          (should (eq (nth 0 (proofread--request-queue-entries))
                      (nth 0 entries)))
          (should (eq (nth 1 (proofread--request-queue-entries))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (request-b
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               (newer-a
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (entry-b nil)
               superseded)
          (proofread--enqueue-requests (list request-a request-b))
          (setq entry-b (nth 1 (proofread--request-queue-entries)))
          (proofread--cache-write-request request-a nil)
          (should (= (hash-table-count
                      (proofread--queue-state-woken
                       proofread--queue-state))
                     1))
          (setq superseded
                (proofread--supersede-conflicting-requests
                 (list newer-a)))
          (should (equal (plist-get superseded :queued)
                         (list request-a)))
          (should-not
           (gethash (proofread--scheduled-work-cache-key request-a)
                    (proofread--queue-state-index
                     proofread--queue-state)))
          (should (eq (proofread--request-queue-head) entry-b))
          (should-not (proofread--cache-wakeup-pending-p))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--finish-superseded-requests superseded)
          (should (proofread--request-state-flag-p
                   request-a :cancelled))

          (proofread--cache-write-request request-b nil)
          (should (proofread--cache-wakeup-pending-p))
          (proofread-clear-cache)
          (should-not (proofread--cache-wakeup-pending-p))
          (should (eq (proofread--request-queue-head) entry-b))
          (should
           (gethash (proofread--scheduled-work-cache-key request-b)
                    (proofread--queue-state-index
                     proofread--queue-state)))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (matching-a
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               (matching-b
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 2 chunks))))
               (works (list unrelated matching-a matching-b))
               entries
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (proofread--enqueue-requests works)
          (setq entries (proofread--request-queue-entries))
          (proofread--cache-write-request
           matching-a
           (list
            (proofread-test--diagnostic-for-range 4 6 "aa")))
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
                         (list
                          (proofread--scheduled-work-log-id
                           matching-a))))
          (should (= (proofread--request-queue-length) 2))
          (should (eq (nth 0 (proofread--request-queue-entries))
                      (nth 0 entries)))
          (should (eq (nth 1 (proofread--request-queue-entries))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (matching
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               entries)
          (proofread--enqueue-requests (list unrelated matching))
          (setq entries (proofread--request-queue-entries))
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
          (should (= (proofread--request-queue-length) 2))
          (should (eq (nth 0 (proofread--request-queue-entries))
                      (nth 0 entries)))
          (should (eq (nth 1 (proofread--request-queue-entries))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (active
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get event :log-id)
                           cache-hit-log-ids))))))
          (proofread--register-active-request active)
          (proofread--enqueue-requests (list waiting))
          (cl-letf
              (((symbol-function 'proofread--fresh-request-p)
                (lambda (work)
                  (when (and (eq work active)
                             (not cache-written))
                    (setq cache-written t)
                    (proofread--cache-write-request waiting nil))
                  t)))
            (should-not (proofread--dispatch-queued-requests)))
          (should cache-written)
          (should (equal cache-hit-log-ids
                         (list
                          (proofread--scheduled-work-log-id waiting))))
          (should-not (proofread--request-work-pending-p waiting))
          (should (proofread--request-queue-empty-p))
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
             (first-work
              (proofread--make-request-work
               first-request))
             (second-request
              (proofread--make-backend-request
               chunk proofread-test--backend second profile))
             (second-work
              (proofread--make-request-work
               second-request))
             second-entry
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (eq (plist-get event :type) 'cache-hit)
                   (push (plist-get (plist-get event :request)
                                    :checker-name)
                         cache-hit-checkers))))))
        (should-not
         (equal (proofread--scheduled-work-cache-key first-work)
                (proofread--scheduled-work-cache-key second-work)))
        ;; Put the unrelated checker first so ordinary FIFO dispatch
        ;; reaches the concurrency limit before the exact cache waiter.
        (proofread--enqueue-requests (list second-work first-work))
        (setq second-entry (proofread--request-queue-head))
        (proofread--cache-write-request first-work nil)
        (should-not (proofread--dispatch-queued-requests))
        (should (equal cache-hit-checkers '( first)))
        (should (= (proofread--request-queue-length) 1))
        (should (eq (proofread--request-queue-head) second-entry))
        (should (proofread--request-work-pending-p second-work))
        (should-not (proofread--request-work-pending-p first-work))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 0 chunks))))
               (request-b
                (proofread--make-request-work
                 (proofread-test--make-profile-request (nth 1 chunks))))
               entry-a
               (proofread-request-log-hook
                (list
                 (lambda (event)
                   (when (eq (plist-get event :type) 'cache-hit)
                     (push (plist-get (plist-get event :request) :text)
                           cache-hit-texts))))))
          (proofread--enqueue-requests (list request-a request-b))
          (setq entry-a (proofread--request-queue-head))
          (proofread--cache-write-request request-a nil)
          (proofread--cache-write-request request-b nil)
          (should-not (proofread--cache-read-request request-a))
          (should (proofread--cache-read-request request-b))
          (should-not (proofread--dispatch-queued-requests))
          (should (equal cache-hit-texts '( "bb")))
          (should (= (proofread--request-queue-length) 1))
          (should (eq (proofread--request-queue-head) entry-a))
          (should (proofread--request-work-pending-p request-a))
          (proofread-test--assert-queue-cache-index-consistent)
          (proofread--cache-write-request request-a nil)
          (should-not (proofread--dispatch-queued-requests))
          (should (equal cache-hit-texts '( "aa" "bb")))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest
    proofread-test-cache-woken-miss-restores-the-same-fifo-entry ()
  "Restore a claimed cache waiter without changing its FIFO identity."
  (with-temp-buffer
    (insert "aa bb cc")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 3) (4 . 6) (7 . 9))))
               (works
                (mapcar
                 (lambda (chunk)
                   (proofread--make-request-work
                    (proofread-test--make-profile-request chunk)))
                 chunks))
               (target (nth 1 works))
               entries
               freshness-called)
          (proofread--enqueue-requests works)
          (setq entries (proofread--request-queue-entries))
          (proofread--cache-write-request target nil)
          (should (gethash
                   (nth 1 entries)
                   (proofread--queue-state-woken
                    proofread--queue-state)))
          ;; Clear the cache from a freshness hook after the exact
          ;; waiter is claimed but before its cache entry can apply.
          (let ((original-fresh-request-p
                 (symbol-function 'proofread--fresh-request-p))
                (target-entry (nth 1 entries)))
            (cl-letf (((symbol-function 'proofread--fresh-request-p)
                       (lambda (work)
                         (should (eq work target))
                         (setq freshness-called t)
                         (should (memq target
                                       proofread--claimed-requests))
                         (should-not
                          (proofread--queue-entry-owner target-entry))
                         (should-not
                          (proofread--queue-entry-previous target-entry))
                         (should-not
                          (proofread--queue-entry-next target-entry))
                         (let* ((key
                                 (proofread--request-queue-entry-cache-key
                                  target-entry))
                                (bucket
                                 (gethash
                                  key
                                  (proofread--queue-state-index
                                   proofread--queue-state))))
                           (should-not
                            (and bucket
                                 (gethash target-entry bucket))))
                         (should-not
                          (gethash
                           target-entry
                           (proofread--queue-state-woken
                            proofread--queue-state)))
                         (proofread-clear-cache)
                         (funcall original-fresh-request-p work))))
              (should (= (proofread--drain-cache-woken-requests) 1))))
          (should freshness-called)
          (should (cl-every #'eq
                            (proofread--request-queue-entries)
                            entries))
          (should-not proofread--claimed-requests)
          (should-not (proofread--cache-wakeup-pending-p))
          (should (proofread--request-work-pending-p target))
          (proofread-test--assert-queue-cache-index-consistent))))))

(ert-deftest
    proofread-test-claimed-terminal-paths-settle-once ()
  "Settle each queue terminal path once and release its pending key."
  (dolist (case
           '(( queue cached final-result applied)
             ( queue error final-result error)
             ( queue stale cancelled stale)
             ( queue invalidated cancelled stale)
             ( queue signal cancelled error)
             ( cache-woken cached final-result applied)
             ( cache-woken stale cancelled stale)
             ( cache-woken signal cancelled error)))
    (pcase-let ((`(,drain ,outcome ,event-type ,detail) case))
      (with-temp-buffer
        (insert "Alpha")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 8)
              (proofread-context-size 0)
              events)
          (proofread-mode 1)
          (proofread-test--with-profile
            (let* ((chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 6)))))
                   (work
                    (proofread--make-request-work
                     (proofread-test--make-profile-request chunk)))
                   (request (proofread-test--work-request work))
                   (batch (proofread--attach-request-batch (list work)))
                   (proofread-request-log-hook
                    (list
                     (lambda (event)
                       (when (and
                              (eq (plist-get event :type)
                                  'cancelled)
                              (equal
                               (plist-get event :log-id)
                               (proofread--scheduled-work-log-id
                                work)))
                         (should-not
                          (memq work proofread--claimed-requests))
                         (should-not
                          (eq (proofread--request-work-pending-p work)
                              work)))
                       (push event events)))))
              (proofread--enqueue-requests (list work))
              (when (eq drain 'cache-woken)
                (proofread--cache-write-request work nil))
              (cl-labels
                  ((terminal-status
                     ()
                     (pcase outcome
                       ('cached
                        (proofread--record-request-event
                         work 'final-result
                         :result
                         (proofread--backend-success-result request nil)
                         :status 'applied)
                        'cached)
                       ('error
                        (proofread--record-request-event
                         work 'final-result
                         :result
                         (proofread--backend-error-result
                          request 'proofread-test-error)
                         :status 'error)
                        'error)
                       ('invalidated
                        (proofread--invalidate-request work)
                        'stale)
                       ('stale 'stale)
                       ('signal
                        (error "Simulated claimed-work failure")))))
                (pcase drain
                  ('queue
                   (cl-letf
                       (((symbol-function 'proofread--submit-request)
                         (lambda (candidate)
                           (should (eq candidate work))
                           (terminal-status))))
                     (if (eq outcome 'signal)
                         (should-error
                          (proofread--drain-request-queue))
                       (should-not
                        (proofread--drain-request-queue)))))
                  ('cache-woken
                   (cl-letf
                       (((symbol-function
                          'proofread--cache-woken-request-status)
                         (lambda (candidate)
                           (should (eq candidate work))
                           (terminal-status))))
                     (if (eq outcome 'signal)
                         (should-error
                          (proofread--drain-cache-woken-requests))
                       (should
                        (= (proofread--drain-cache-woken-requests)
                           1)))))))
              (let ((terminal-events
                     (proofread-test--terminal-request-events
                      events work)))
                (should (= (length terminal-events) 1))
                (should (eq (plist-get (car terminal-events) :type)
                            event-type))
                (if (eq event-type 'cancelled)
                    (should (eq (plist-get (car terminal-events)
                                           :reason)
                                detail))
                  (should (eq (plist-get (car terminal-events)
                                         :status)
                              detail))))
              (should (zerop (plist-get batch :pending)))
              (should (proofread--scheduled-work-batch-settled work))
              (if (eq event-type 'cancelled)
                  (should (proofread--request-state-flag-p
                           work :cancelled))
                (should-not (proofread--request-state-flag-p
                             work :cancelled)))
              (proofread-test--assert-no-pending-request-work))))))))

(ert-deftest
    proofread-test-cache-stale-result-has-one-terminal-event ()
  "Treat a stale cache result as already settled by its final event."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 8)
          (proofread-context-size 0)
          events
          (freshness-calls 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk
                (car
                 (proofread-test--request-ready-chunks-for-ranges
                  '((1 . 6)))))
               (work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (batch (proofread--attach-request-batch (list work)))
               (proofread-request-log-hook
                (list (lambda (event)
                        (push event events)))))
          (proofread--enqueue-requests (list work))
          (proofread--cache-write-request work nil)
          (cl-letf (((symbol-function 'proofread--fresh-request-p)
                     (lambda (candidate)
                       (should (eq candidate work))
                       (setq freshness-calls (1+ freshness-calls))
                       (= freshness-calls 1))))
            (should (= (proofread--drain-cache-woken-requests) 1)))
          (let ((terminal-events
                 (proofread-test--terminal-request-events events work)))
            (should (= (length terminal-events) 1))
            (should (eq (plist-get (car terminal-events) :type)
                        'final-result))
            (should (eq (plist-get (car terminal-events) :status)
                        'stale)))
          (should (= freshness-calls 2))
          (should (zerop (plist-get batch :pending)))
          (should-not
           (proofread--request-state-flag-p work :cancelled))
          (proofread-test--assert-no-pending-request-work))))))

(ert-deftest
    proofread-test-cache-woken-status-checks-lifecycle-twice ()
  "Avoid a redundant lifecycle check after freshness settles."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          (proofread-cache-max-entries 8)
          (lifecycle-calls 0))
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunk (proofread--make-request-ready-chunk 1 6))
               (work
                (proofread--make-request-work
                 (proofread-test--make-profile-request chunk)))
               (original-lifecycle
                (symbol-function
                 'proofread--request-lifecycle-current-p)))
          (cl-letf
              (((symbol-function
                 'proofread--request-lifecycle-current-p)
                (lambda (candidate)
                  (setq lifecycle-calls (1+ lifecycle-calls))
                  (funcall original-lifecycle candidate)))
               ((symbol-function 'proofread--fresh-request-p)
                (lambda (candidate)
                  (should (eq candidate work))
                  t)))
            (should (eq (proofread--cache-woken-request-status work)
                        'miss)))
          (should (= lifecycle-calls 2)))))))

(ert-deftest
    proofread-test-claimed-restore-preserves-entry-and-fifo ()
  "Restore the same claimed entry in FIFO order without settling it."
  (dolist (drain '( queue cache-woken))
    (with-temp-buffer
      (insert "aa bb cc")
      (let ((proofread-auto-check nil)
            (proofread-cache-max-entries 8)
            (proofread-context-size 0)
            (proofread-max-concurrent-requests 0)
            events)
        (proofread-mode 1)
        (proofread-test--with-profile
          (let* ((chunks
                  (proofread-test--request-ready-chunks-for-ranges
                   '((1 . 3) (4 . 6) (7 . 9))))
                 (works
                  (mapcar
                   (lambda (chunk)
                     (proofread--make-request-work
                      (proofread-test--make-profile-request chunk)))
                   chunks))
                 (target
                  (if (eq drain 'queue)
                      (car works)
                    (nth 1 works)))
                 (batch (proofread--attach-request-batch (list target)))
                 entries
                 (proofread-request-log-hook
                  (list (lambda (event)
                          (push event events)))))
            (proofread--enqueue-requests works)
            (setq entries (proofread--request-queue-entries))
            (pcase drain
              ('queue
               (cl-letf
                   (((symbol-function 'proofread--submit-request)
                     (lambda (candidate)
                       (should (eq candidate target))
                       'full)))
                 (should-not (proofread--drain-request-queue))))
              ('cache-woken
               (proofread--cache-write-request target nil)
               (cl-letf
                   (((symbol-function
                      'proofread--cache-woken-request-status)
                     (lambda (candidate)
                       (should (eq candidate target))
                       'miss)))
                 (should
                  (= (proofread--drain-cache-woken-requests) 1)))))
            (should (cl-every #'eq
                              (proofread--request-queue-entries)
                              entries))
            (should-not proofread--claimed-requests)
            (should (eq (gethash
                         (proofread--request-work-key target)
                         proofread--pending-request-keys)
                        target))
            (should-not
             (proofread-test--terminal-request-events events target))
            (should (= (plist-get batch :pending) 1))
            (should-not
             (proofread--scheduled-work-batch-settled target))
            (proofread-test--assert-queue-cache-index-consistent)
            (proofread--clear-scheduled-work)))))))

(ert-deftest
    proofread-test-claimed-reentrant-state-change-does-not-leak ()
  "Retire claims once after reentrant dispatch state changes."
  (dolist (case
           '(( queue clear stale)
             ( cache-woken clear miss)
             ( queue transaction full)
             ( cache-woken transaction miss)
             ( queue lifecycle full)
             ( cache-woken lifecycle miss)
             ( queue identity full)
             ( cache-woken identity miss)))
    (pcase-let ((`(,drain ,change ,status) case))
      (with-temp-buffer
        (insert "Alpha")
        (let ((proofread-auto-check nil)
              (proofread-cache-max-entries 8)
              (proofread-context-size 0)
              events)
          (proofread-mode 1)
          (proofread-test--with-profile
            (let* ((chunk
                    (car
                     (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 6)))))
                   (work
                    (proofread--make-request-work
                     (proofread-test--make-profile-request chunk)))
                   (batch (proofread--attach-request-batch (list work)))
                   (transaction
                    (make-symbol "proofread-test-queue-transaction"))
                   (replacement
                    (make-symbol "proofread-test-replacement-transaction"))
                   (proofread-request-log-hook
                    (list (lambda (event)
                            (push event events)))))
              (proofread--enqueue-requests (list work))
              (when (eq drain 'cache-woken)
                (proofread--cache-write-request work nil))
              (let ((proofread--queue-dispatch-transaction transaction))
                (setq proofread--queue-dispatch-active-p transaction)
                (cl-labels
                    ((change-state
                       ()
                       (pcase change
                         ('clear
                          (proofread--clear-scheduled-work))
                         ('transaction
                          (setq proofread--queue-dispatch-active-p
                                replacement))
                         ('lifecycle
                          (proofread--set-request-state-flag
                           work :invalidated))
                         ('identity
                          (proofread--forget-request-work work)))
                       status))
                  (pcase drain
                    ('queue
                     (cl-letf
                         (((symbol-function 'proofread--submit-request)
                           (lambda (candidate)
                             (should (eq candidate work))
                             (change-state))))
                       (should-not
                        (proofread--drain-request-queue))))
                    ('cache-woken
                     (cl-letf
                         (((symbol-function
                            'proofread--cache-woken-request-status)
                           (lambda (candidate)
                             (should (eq candidate work))
                             (change-state))))
                       (should
                        (= (proofread--drain-cache-woken-requests)
                           1)))))))
              (let ((terminal-events
                     (proofread-test--terminal-request-events
                      events work)))
                (should (= (length terminal-events) 1))
                (should (eq (plist-get (car terminal-events) :type)
                            'cancelled)))
              (should (zerop (plist-get batch :pending)))
              (should (proofread--scheduled-work-batch-settled work))
              (should (proofread--request-state-flag-p work :cancelled))
              (proofread-test--assert-no-pending-request-work))))))))

(ert-deftest proofread-test-queue-state-mutations-preserve-invariants ()
  "Keep queue record links and indexes consistent across mutations."
  (with-temp-buffer
    (proofread-mode 1)
    (cl-labels
        ((assert-detached
           (entry)
           (should-not (proofread--queue-entry-owner entry))
           (should-not (proofread--queue-entry-previous entry))
           (should-not (proofread--queue-entry-next entry))))
      (let* ((state proofread--queue-state)
             (works
              (mapcar
               (lambda (id)
                 (proofread-test--lifecycle-request id id (1+ id)))
               '( 1 2 3 4)))
             entries
             sequences)
        (dolist (work works)
          (proofread--append-request-queue-entry
           state
           (proofread--new-request-queue-entry
            state work))
          (proofread-test--assert-queue-cache-index-consistent))
        (setq entries (proofread--request-queue-entries))
        (setq sequences
              (mapcar #'proofread--queue-entry-sequence entries))
        (should (equal (mapcar #'proofread--queue-entry-work entries)
                       works))
        (should (cl-every #'< sequences (cdr sequences)))
        (let ((middle (nth 1 entries)))
          (should (eq (proofread--claim-request-queue-entry middle)
                      middle))
          (assert-detached middle)
          (proofread-test--assert-queue-cache-index-consistent)
          (should (eq (car proofread--claimed-requests)
                      (nth 1 works)))
          (should (eq (proofread--insert-request-queue-entry middle)
                      middle))
          (proofread--release-claimed-request (nth 1 works))
          (proofread-test--assert-queue-cache-index-consistent)
          (should (cl-every #'eq
                            (proofread--request-queue-entries)
                            entries))
          (should
           (equal (mapcar #'proofread--queue-entry-sequence entries)
                  sequences)))
        (let ((head (car entries)))
          (should (eq (proofread--unlink-request-queue-entry head)
                      head))
          (assert-detached head))
        (proofread-test--assert-queue-cache-index-consistent)
        (let ((tail (car (last entries))))
          (should (eq (proofread--unlink-request-queue-entry tail)
                      tail))
          (assert-detached tail))
        (proofread-test--assert-queue-cache-index-consistent)
        (let ((cleared (proofread--clear-request-queue state)))
          (should
           (cl-every
            #'eq cleared
            (list (nth 1 entries) (nth 2 entries))))
          (dolist (entry cleared)
            (assert-detached entry)))
        (proofread-test--assert-queue-cache-index-consistent)
        (should (proofread--request-queue-empty-p))
        (should-not (proofread--queue-state-head state))
        (should-not (proofread--queue-state-tail state))))))

(ert-deftest proofread-test-scheduler-uses-canonical-request-backend ()
  "Submit and log only the backend selected by the checker."
  (with-temp-buffer
    (insert "Alpha")
    (let ((proofread-auto-check nil)
          events
          queried-backends
          submitted)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((profile (proofread--current-profile))
               (checker
                (proofread-test--current-profile-checker profile))
               (backend (plist-get checker :backend))
               (chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 6)))))
               (original-descriptor
                (symbol-function 'proofread--backend-descriptor))
               requests)
          (should-not (fboundp 'proofread--queue-entry-backend))
          (let ((proofread-request-log-hook
                 (list
                  (lambda (event)
                    (when (memq (plist-get event :type)
                                '( queued-request active-request
                                   backend-dispatched))
                      (push (cons (plist-get event :type)
                                  (plist-get event :backend))
                            events))))))
            (cl-letf
                (((symbol-function 'proofread--backend-descriptor)
                  (lambda (queried-backend)
                    (push queried-backend queried-backends)
                    (funcall original-descriptor queried-backend)))
                 (proofread-test--backend-check-function
                  (lambda (backend-request _callback)
                    (setq submitted backend-request)
                    'proofread-test-handle)))
              (setq requests
                    (plist-get
                     (proofread--dispatch-profile-request-ready-chunks-result
                      (list chunk) profile)
                     :requests))))
          (should (= (length requests) 1))
          (should (eq submitted (car requests)))
          (should (eq (plist-get submitted :backend) backend))
          (should queried-backends)
          (should (cl-every (lambda (queried-backend)
                              (eq queried-backend backend))
                            queried-backends))
          (should
           (equal
            (nreverse events)
            (mapcar
             (lambda (type) (cons type backend))
             '( queued-request active-request backend-dispatched)))))))))

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
                             (plist-get request :id)))))
              (cl-letf
                  (((symbol-function 'proofread--submit-request)
                    (lambda (work)
                      (setq submit-attempts (1+ submit-attempts))
                      (funcall original-submit work)))
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
                (should (= (proofread--request-queue-length)
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
                                  (plist-get request :id))
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
                (should (proofread--request-queue-empty-p))
                (should-not
                 (proofread--queue-state-tail proofread--queue-state))
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
           (works
            (mapcar (lambda (chunk)
                      (proofread-test--make-request-work
                       chunk proofread-test--backend))
                    chunks))
           (invalidated (nth 0 works))
           (superseded (nth 1 works))
           (ready (nth 2 works))
           (ready-request (proofread-test--work-request ready))
           dispatched)
      (should (= (length works) 3))
      (proofread--enqueue-requests works)
      (proofread--invalidate-request invalidated)
      (proofread--set-request-state-flag superseded :superseded)
      (let ((proofread-max-concurrent-requests 0))
        (should-not (proofread--dispatch-queued-requests))
        (should (= (proofread--request-queue-length) 1))
        (should (eq (proofread--queue-entry-work
                     (proofread--request-queue-head))
                    ready))
        (should-not (proofread--request-work-pending-p invalidated))
        (should-not (proofread--request-work-pending-p superseded))
        (should (proofread--request-work-pending-p ready)))
      (let ((proofread-max-concurrent-requests 1))
        (let ((proofread-test--backend-check-function
               (lambda (request _callback)
                 (setq dispatched request)
                 'proofread-test-handle)))
          (should (equal (proofread--dispatch-queued-requests)
                         (list ready-request)))))
      (should (eq dispatched ready-request))
      (should (proofread--request-queue-empty-p))
      (should-not
       (proofread--queue-state-tail proofread--queue-state))
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
             (work
              (proofread-test--make-request-work
               chunk proofread-test--backend))
             (request (proofread-test--work-request work))
             (log-id (proofread--scheduled-work-log-id work)))
        (proofread--enqueue-requests (list work))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread--dispatch-queued-requests))
                     t))
                  (proofread-test--backend-check-function
                   (lambda (_backend-request backend-callback)
                     (push log-id submitted-log-ids)
                     (setq callback backend-callback)
                     (list :backend 'test :log-id log-id))))
          (should (equal (proofread--dispatch-queued-requests)
                         (list request)))
          (should (equal submitted-log-ids (list log-id)))
          (should (proofread--request-queue-empty-p))
          (should-not proofread--claimed-requests)
          (should (= (length proofread--active-requests) 1))
          (should (equal
                   (gethash (proofread--request-work-key work)
                            proofread--pending-request-keys)
                   work))
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
              (proofread-test--make-request-work
               chunk proofread-test--backend)))
        (proofread--enqueue-requests (list old-request))
        (cl-letf
            (((symbol-function 'proofread--submit-request)
              (lambda (request)
                (push request submitted)
                (unless reinitialized
                  (setq reinitialized t)
                  (proofread-mode -1)
                  (proofread-mode 1)
                  (setq new-request
                        (proofread-test--make-request-work
                         (proofread--make-request-ready-chunk 1 6)
                         proofread-test--backend))
                  (proofread--enqueue-requests (list new-request)))
                'stale)))
          (should-not (proofread--dispatch-queued-requests)))
        (should reinitialized)
        (should (equal submitted (list old-request)))
        (should (proofread--request-state-flag-p
                 old-request :cancelled))
        (should (= (proofread--request-queue-length) 1))
        (should (eq (proofread--queue-entry-work
                     (proofread--request-queue-head))
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
              (proofread-test--make-request-work
               chunk proofread-test--backend)))
        (proofread--enqueue-requests (list request))
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
          (proofread-profile proofread-test--profile)
          (proofread-profiles (proofread-test--profiles))
          reentered
          submitted
          callback)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old
              (proofread-test--make-request-work
               old-chunk proofread-test--backend checker profile)))
        (proofread--enqueue-requests (list old))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless reentered
                       (setq reentered t)
                       (proofread-test--dispatch-profile-chunks
                        (list new-chunk) profile))
                     t))
                  (proofread-test--backend-check-function
                   (lambda (request backend-callback)
                     (push request submitted)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
          (let ((dispatched (proofread--dispatch-queued-requests)))
            (should (= (length dispatched) 1))
            (should (eq (car dispatched) (car submitted))))
          (let* ((new-request (car submitted))
                 (new-work (car proofread--active-requests))
                 (new-log-id
                  (proofread--scheduled-work-log-id new-work)))
            (should-not
             (equal new-log-id
                    (proofread--scheduled-work-log-id old)))
            (should (proofread--request-state-flag-p old :superseded))
            (should (proofread--request-state-flag-p old :cancelled))
            (should (= (length submitted) 1))
            (should (proofread--request-queue-empty-p))
            (should-not proofread--claimed-requests)
            (should (equal proofread--active-requests
                           (list new-work)))
            (should (= (hash-table-count
                        proofread--pending-request-keys)
                       1))
            (should (equal
                     (gethash (proofread--request-work-key new-work)
                              proofread--pending-request-keys)
                     new-work))
            (funcall callback
                     (proofread--backend-success-result
                      new-request nil))
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
          (proofread-profile proofread-test--profile)
          (proofread-profiles (proofread-test--profiles))
          nested
          submitted-requests
          callbacks)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (victim-chunk
              (proofread--make-request-ready-chunk 1 4))
             (new-chunk (proofread--make-request-ready-chunk 2 5))
             (unrelated-chunk
              (proofread--make-request-ready-chunk 5 8))
             (victim
              (proofread-test--make-request-work
               victim-chunk proofread-test--backend checker profile))
             (unrelated
              (proofread-test--make-request-work
               unrelated-chunk proofread-test--backend checker profile))
             (unrelated-request
              (proofread-test--work-request unrelated))
             (victim-log-id
              (proofread--scheduled-work-log-id victim))
             (proofread-request-log-hook
              (list
               (lambda (event)
                 (when (and (not nested)
                            (eq (plist-get event :type) 'cancelled)
                            (equal (plist-get event :log-id)
                                   victim-log-id))
                   (setq nested t)
                   (proofread--dispatch-queued-requests))))))
        (setf (proofread--scheduled-work-handle victim)
              'victim-handle)
        (proofread--register-active-request victim)
        (proofread--enqueue-requests (list unrelated))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  (proofread-test--backend-check-function
                   (lambda (request callback)
                     (push request submitted-requests)
                     (push (cons request callback) callbacks)
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
          (proofread-test--dispatch-profile-chunks
           (list new-chunk) profile)
          (should (equal submitted-requests
                         (list unrelated-request)))
          (should (proofread--request-state-flag-p victim
                                                   :superseded))
          (should (proofread--request-state-flag-p victim :cancelled))
          (should-not proofread--claimed-requests)
          (should (= (proofread--request-queue-length) 1))
          (let* ((new-work
                  (proofread--queue-entry-work
                   (proofread--request-queue-head)))
                 (new-request
                  (proofread-test--work-request new-work)))
            (funcall (cdr (assq unrelated-request callbacks))
                     (proofread--backend-success-result
                      unrelated-request nil))
            (should (= (cl-count unrelated-request submitted-requests
                                 :test #'eq)
                       1))
            (should (= (cl-count new-request submitted-requests
                                 :test #'eq)
                       1))
            (should (proofread--request-queue-empty-p))
            (should-not proofread--claimed-requests)
            (funcall (cdr (assq new-request callbacks))
                     (proofread--backend-success-result
                      new-request nil))
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
             (request
              (proofread-test--make-request-work
               chunk proofread-test--backend)))
        (proofread--enqueue-requests (list request))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request)
                     (unless edited
                       (setq edited t)
                       (goto-char (point-min))
                       (delete-char 1)
                       (insert "X"))
                     t))
                  (proofread-test--backend-check-function
                   (lambda (_request _callback)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
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
             (request
              (proofread-test--make-request-work
               chunk proofread-test--backend))
             (log-id (proofread--scheduled-work-log-id request))
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
        (proofread--enqueue-requests (list request))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  (proofread-test--backend-check-function
                   (lambda (_request _callback)
                     (setq backend-calls (1+ (or backend-calls 0)))
                     'unexpected-handle)))
          (should-not (proofread--dispatch-queued-requests)))
        (should (equal (buffer-string) "Xlpha"))
        (should-not backend-calls)
        (should (proofread--request-invalidated-p request))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-invalidated-active-releases-slot-for-queued-work ()
  "Free active request slots for queued work after edits."
  (with-temp-buffer
    (insert "aaa bbb")
    (let ((proofread-auto-check nil)
          (proofread-max-concurrent-requests 1)
          submitted-requests
          cancelled-handles
          callback)
      (proofread-mode 1)
      (let* ((waiting-chunk (proofread--make-request-ready-chunk 1 4))
             (active-chunk (proofread--make-request-ready-chunk 5 8))
             (waiting
              (proofread-test--make-request-work
               waiting-chunk proofread-test--backend))
             (active
              (proofread-test--make-request-work
               active-chunk proofread-test--backend))
             (waiting-request (proofread-test--work-request waiting)))
        (setf (proofread--scheduled-work-handle active) 'old-handle)
        (proofread--register-active-request active)
        (proofread--enqueue-requests (list waiting))
        (cl-letf (((symbol-function 'proofread--fresh-request-p)
                   (lambda (_request) t))
                  (proofread-test--backend-check-function
                   (lambda (request backend-callback)
                     (push request submitted-requests)
                     (setq callback backend-callback)
                     (list :backend 'test
                           :request-id (plist-get request :id))))
                  ((symbol-function 'proofread--cancel-request-handle)
                   (lambda (handle)
                     (push handle cancelled-handles))))
          (goto-char 6)
          (delete-char 1)
          (insert "b")
          (should
           (proofread-test--wait-for (lambda () submitted-requests)))
          (should (equal submitted-requests (list waiting-request)))
          (should (equal cancelled-handles (list 'old-handle)))
          (should (proofread--request-invalidated-p active))
          (should (proofread--request-state-flag-p active :cancelled))
          (should-not (proofread--active-request-p active))
          (should (proofread--active-request-p waiting))
          (should (proofread--request-queue-empty-p))
          (should-not proofread--claimed-requests)
          (should (= (hash-table-count
                      proofread--pending-request-keys) 1))
          (should (equal
                   (gethash (proofread--request-work-key waiting)
                            proofread--pending-request-keys)
                   waiting))
          (funcall callback
                   (proofread--backend-success-result
                    waiting-request nil))
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
          submitted-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((chunks
                (proofread-test--request-ready-chunks-for-ranges
                 '((1 . 4) (5 . 8))))
               (active-request
                (proofread-test--make-profile-request (nth 1 chunks)))
               (active
                (proofread--make-request-work
                 active-request)))
          (setf (proofread--scheduled-work-handle active) 'old-handle)
          (proofread--register-active-request active)
          (setq proofread-test--backend-identity-token "identity-b")
          (let* ((waiting-request
                  (proofread-test--make-profile-request (car chunks)))
                 (waiting
                  (proofread--make-request-work
                   waiting-request)))
            (proofread--enqueue-requests (list waiting))
            (let ((proofread-test--backend-check-function
                   (lambda (request _callback)
                     (push request submitted-requests)
                     (list :backend 'test
                           :request-id (plist-get request :id)))))
              (cl-letf
                  (((symbol-function
                     'proofread--cancel-request-handle)
                    (lambda (handle)
                      (push handle cancelled-handles))))
                (should (equal (proofread--dispatch-queued-requests)
                               (list waiting-request)))))
            (should (equal submitted-requests (list waiting-request)))
            (should (equal cancelled-handles (list 'old-handle)))
            (should (proofread--request-invalidated-p active))
            (should (proofread--request-state-flag-p active
                                                     :cancelled))
            (should-not (proofread--active-request-p active))
            (should (proofread--active-request-p waiting))
            (should (proofread--request-queue-empty-p))
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
          submitted-requests
          cancelled-handles)
      (proofread-mode 1)
      (proofread-test--with-profile
        (let* ((waiting-chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((1 . 5)))))
               (active-chunk
                (car (proofread-test--request-ready-chunks-for-ranges
                      '((6 . 10)))))
               (waiting-request
                (proofread-test--make-profile-request waiting-chunk))
               (waiting
                (proofread--make-request-work
                 waiting-request))
               (active-request
                (proofread-test--make-profile-request active-chunk))
               (active
                (proofread--make-request-work
                 active-request)))
          (setf (proofread--scheduled-work-handle active) 'old-handle)
          (proofread--register-active-request active)
          (proofread--enqueue-requests (list waiting))
          (let ((proofread-test--backend-check-function
                 (lambda (request _callback)
                   (push request submitted-requests)
                   (list :backend 'test
                         :request-id (plist-get request :id)))))
            (cl-letf
                (((symbol-function
                   'proofread--cancel-request-handle)
                  (lambda (handle)
                    (push handle cancelled-handles))))
              (goto-char 11)
              (delete-char 1)
              (insert "X")
              (should-not (proofread--request-invalidated-p active))
              (should (timerp proofread--queue-dispatch-timer))
              (should
               (proofread-test--wait-for (lambda () submitted-requests)))
              (should (equal submitted-requests (list waiting-request)))
              (should (equal cancelled-handles (list 'old-handle)))
              (should (proofread--request-invalidated-p active))
              (should (proofread--request-state-flag-p active
                                                       :cancelled))
              (should-not (proofread--active-request-p active))
              (should (proofread--active-request-p waiting))
              (should (proofread--request-queue-empty-p))
              (should-not proofread--claimed-requests))))))))

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
                     (work
                      (proofread-test--make-request-work
                       chunk proofread-test--backend))
                     (request (proofread-test--work-request work))
                     (log-id
                      (proofread--scheduled-work-log-id work)))
                (proofread--enqueue-requests (list work))
                (cl-letf (((symbol-function
                            'proofread--fresh-request-p)
                           (lambda (_request) t))
                          (proofread-test--backend-check-function
                           (lambda (_backend-request _callback)
                             (push log-id submitted-log-ids)
                             (list :backend 'test :log-id log-id))))
                  (should (equal (proofread--dispatch-queued-requests)
                                 (list request))))
                (should (equal submitted-log-ids (list log-id)))
                (should (proofread--request-queue-empty-p))
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
             (request
              (proofread-test--make-request-work
               chunk proofread-test--backend)))
        (proofread--enqueue-requests (list request))
        (cl-letf (((symbol-function 'proofread--submit-request)
                   (lambda (_work)
                     (error "Simulated submission failure"))))
          (should-error (proofread--dispatch-queued-requests)))
        (should (proofread--request-state-flag-p request :cancelled))
        (should-not proofread--queue-dispatch-active-p)
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
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
              (proofread-test--make-request-work
               chunk proofread-test--backend)))
        (proofread--enqueue-requests (list request))
        (cl-letf
            (((symbol-function 'proofread--submit-request)
              (lambda (_work) 'full))
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
          (proofread-profile proofread-test--profile)
          (proofread-profiles (proofread-test--profiles))
          triggered
          new-log-id
          events)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old
              (proofread-test--make-request-work
               old-chunk proofread-test--backend checker profile))
             (old-log-id (proofread--scheduled-work-log-id old)))
        (proofread--enqueue-requests (list old))
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (push event events)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread-test--dispatch-profile-chunks
                     (list new-chunk) profile))
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
        (should (proofread--request-queue-empty-p))
        (should-not
         (proofread--queue-state-tail proofread--queue-state))
        (should-not proofread--queue-dispatch-timer)
        (should (= (hash-table-count proofread--pending-request-keys)
                   0))))))

(ert-deftest
    proofread-test-nested-profile-clear-rejections-settle-all-batches ()
  "Settle nested profile batches rejected by cancellation hooks."
  (with-temp-buffer
    (insert "abcdef")
    (let* ((proofread-auto-check nil)
           (proofread-cache-max-entries 0)
           (proofread-context-size 0)
           (proofread-profile 'multi)
           (proofread-profiles (proofread-test--ordered-profiles))
           (original-reject
            (symbol-function 'proofread--reject-request-during-clear))
           rejection-scope
           outer-rejected
           nested-rejected
           (stage 0))
      (proofread-mode 1)
      (let* ((old-chunk (proofread--make-request-ready-chunk 1 5))
             (dispatch-chunks
              (proofread-test--request-ready-chunks-for-ranges
               '((2 . 6))))
             (dispatch-profile (proofread--current-profile))
             (old
              (proofread-test--make-request-work
               old-chunk proofread-test--backend))
             (old-log-id (proofread--scheduled-work-log-id old)))
        (proofread--enqueue-requests (list old))
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (when (eq (plist-get event :type) 'cancelled)
                    (cond
                     ((and (zerop stage)
                           (equal (plist-get event :log-id)
                                  old-log-id))
                      (setq stage 1)
                      (let ((previous-scope rejection-scope))
                        (setq rejection-scope 'outer)
                        (unwind-protect
                            (proofread--dispatch-profile-request-ready-chunks-result
                             dispatch-chunks dispatch-profile)
                          (setq rejection-scope previous-scope))))
                     ((and (= stage 1)
                           (eq (plist-get event :reason) 'cleared))
                      (setq stage 2)
                      (let ((previous-scope rejection-scope))
                        (setq rejection-scope 'nested)
                        (unwind-protect
                            (proofread--dispatch-profile-request-ready-chunks-result
                             dispatch-chunks dispatch-profile)
                          (setq rejection-scope previous-scope))))))))))
          (cl-letf
              (((symbol-function 'proofread--reject-request-during-clear)
                (lambda (work)
                  (pcase rejection-scope
                    ('outer (push work outer-rejected))
                    ('nested (push work nested-rejected)))
                  (funcall original-reject work))))
            (proofread--clear-scheduled-work)))
        (setq outer-rejected (nreverse outer-rejected))
        (setq nested-rejected (nreverse nested-rejected))
        (should (= stage 2))
        (should (= (length outer-rejected) 2))
        (should (= (length nested-rejected) 2))
        (let* ((works (append outer-rejected nested-rejected))
               (batches
                (delete-dups
                 (mapcar #'proofread--scheduled-work-batch works))))
          (should (cl-every #'proofread--scheduled-work-batch works))
          (should (cl-every
                   #'proofread--scheduled-work-batch-settled works))
          (should (= (length batches) 4))
          (dolist (batch batches)
            (should (zerop (plist-get batch :pending)))))
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
        (should-not proofread--queue-dispatch-timer)
        (should (zerop
                 (hash-table-count proofread--pending-request-keys)))
        (proofread-test--assert-queue-cache-index-consistent)))))

(ert-deftest
    proofread-test-request-cleanup-rejects-active-cancel-hook-work ()
  "Reject cancellation-hook work during active cleanup."
  (with-temp-buffer
    (insert "abcdef")
    (let ((proofread-auto-check nil)
          (proofread-profile proofread-test--profile)
          (proofread-profiles (proofread-test--profiles))
          triggered
          rejected-log-id)
      (proofread-mode 1)
      (let* ((profile (proofread--current-profile))
             (checker
              (proofread-test--current-profile-checker profile))
             (old-chunk (proofread--make-request-ready-chunk 1 5))
             (new-chunk (proofread--make-request-ready-chunk 2 6))
             (old
              (proofread-test--make-request-work
               old-chunk proofread-test--backend checker profile))
             (old-log-id (proofread--scheduled-work-log-id old)))
        (setf (proofread--scheduled-work-handle old) 'old-handle)
        (proofread--register-active-request old)
        (let ((proofread-request-log-hook
               (list
                (lambda (event)
                  (cond
                   ((and (not triggered)
                         (eq (plist-get event :type) 'cancelled)
                         (equal (plist-get event :log-id) old-log-id))
                    (setq triggered t)
                    (proofread-test--dispatch-profile-chunks
                     (list new-chunk) profile))
                   ((eq (plist-get event :reason) 'cleared)
                    (setq rejected-log-id
                          (plist-get event :log-id))))))))
          (proofread--clear-request-work))
        (should triggered)
        (should rejected-log-id)
        (should-not proofread--active-requests)
        (should-not proofread--claimed-requests)
        (should (proofread--request-queue-empty-p))
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
        (let ((proofread-test--backend-check-function
               (lambda (request _callback)
                 (setq backend-requests
                       (append backend-requests (list request)))
                 (list :backend 'test
                       :request-id (plist-get request :id)))))
          (let* ((old-chunks
                  (proofread-test--request-ready-chunks-for-ranges
                   (list (cons (point-min) (point-max)))))
                 (old-request
                  (car (proofread-test--dispatch-profile-chunks
                        old-chunks)))
                 (old (car proofread--active-requests)))
            (should old-request)
            (goto-char 2)
            (insert "x")
            (delete-region 2 3)
            (should (equal (buffer-string) "helo"))
            (should (proofread--request-invalidated-p old))
            (should-not (proofread--request-work-pending-p old))
            (let* ((new-chunks
                    (proofread-test--request-ready-chunks-for-ranges
                     (list (cons (point-min) (point-max)))))
                   (new-request
                    (car (proofread-test--dispatch-profile-chunks
                          new-chunks)))
                   (new (car proofread--active-requests)))
              (should new-request)
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
            (proofread-test--make-request-work
             full-chunk proofread-test--backend))
           narrowed-request)
      (narrow-to-region 2 6)
      (setq narrowed-request
            (proofread-test--make-request-work
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request first))))
          (should (equal (plist-get first :text) "aaa"))
          (should (equal (plist-get second :text) "aaa"))
          (proofread--cache-write-request
           preview
           (list
            (proofread-test--diagnostic-for-range 1 4 "aaa")))
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
          ;; The cache publication and its reentrant source edit are
          ;; separate diagnostic commits.
          (should (= calls 2))
          (should (equal (buffer-string) "aaa aaa aaa"))
          (should (proofread--request-queue-empty-p))
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
                (proofread--make-request-work
                 (proofread-test--make-profile-request
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((1 . 3)))))))
               (waiting
                (proofread--make-request-work
                 (proofread-test--make-profile-request
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((4 . 6)))))))
               (cached
                (proofread--make-request-work
                 (proofread-test--make-profile-request
                  (car (proofread-test--request-ready-chunks-for-ranges
                        '((7 . 9))))))))
          (proofread--register-active-request active)
          (proofread--cache-write-request
           cached
           (list
            (proofread-test--diagnostic-for-range 7 9 "cc")))
          (proofread--enqueue-requests (list waiting cached))
          (add-hook 'proofread-diagnostics-changed-hook
                    (lambda ()
                      (setq calls (1+ (or calls 0)))
                      (when (= calls 1)
                        (goto-char (point-min))
                        (insert "x")
                        (delete-char -1)))
                    nil t)
          (should-not (proofread--dispatch-queued-requests))
          ;; Cache publication plus the hook's insertion and deletion
          ;; each publish one coherent diagnostic state.
          (should (= calls 3))
          (should (proofread--request-queue-empty-p))
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
        (let ((proofread-test--backend-check-function
               (lambda (request _callback)
                 (setq backend-requests
                       (append backend-requests (list request)))
                 (list :backend 'test
                       :request-id (plist-get request :id)))))
          (cl-letf (((symbol-function 'proofread--cancel-request-handle)
                     (lambda (handle)
                       (push handle cancelled-handles))))
            (let* ((older-chunk
                    (car (proofread-test--request-ready-chunks-for-ranges
                          '((1 . 7)))))
                   (newer-chunk
                    (car (proofread-test--request-ready-chunks-for-ranges
                          '((2 . 6)))))
                   (older-request
                    (car (proofread-test--dispatch-profile-chunks
                          (list older-chunk))))
                   (older (car proofread--active-requests))
                   (newer-request
                    (car (proofread-test--dispatch-profile-chunks
                          (list newer-chunk))))
                   (newer (car proofread--active-requests)))
              (should older-request)
              (should newer-request)
              (should (= (length backend-requests) 2))
              (should (= (length cancelled-handles) 1))
              (should (proofread--request-state-flag-p older
                                                       :superseded))
              (should-not (proofread--active-request-p older))
              (should (proofread--active-request-p newer))
              (should (equal (mapcar (lambda (work)
                                       (plist-get
                                        (proofread-test--work-request work)
                                        :text))
                                     proofread--active-requests)
                             '( "bcde")))
              (should (proofread--request-queue-empty-p))
              (should-not
               (proofread--queue-state-tail
                proofread--queue-state)))))))))

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
        (let ((proofread-test--backend-check-function
               (lambda (request _callback)
                 (setq backend-requests
                       (append backend-requests (list request)))
                 (list :backend 'test
                       :request-id (plist-get request :id)))))
          (cl-letf (((symbol-function 'proofread--cancel-request-handle)
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
                    (proofread--make-request-work
                     (proofread-test--make-profile-request cached-chunk)))
                   (unrelated-request
                    (proofread-test--make-profile-request
                     unrelated-chunk))
                   (unrelated
                    (proofread--make-request-work
                     unrelated-request)))
              (proofread--cache-write-request cached-preview nil)
              (let* ((older-request
                      (car (proofread-test--dispatch-profile-chunks
                            (list older-chunk))))
                     (older (car proofread--active-requests)))
                (should older-request)
                (proofread--enqueue-requests (list unrelated))
                (should (= (proofread--request-queue-length) 1))
                (should
                 (equal
                  (proofread-test--dispatch-profile-chunks
                   (list cached-chunk))
                  (list unrelated-request)))
                (should (proofread--request-state-flag-p
                         older :superseded))
                (should (= (length cancelled-handles) 1))
                (should (equal (mapcar (lambda (request)
                                         (plist-get request :text))
                                       backend-requests)
                               '( "abc" "def")))
                (should-not (proofread--active-request-p older))
                (should (proofread--active-request-p unrelated))
                (should (proofread--request-queue-empty-p))
                (should-not
                 (proofread--queue-state-tail
                  proofread--queue-state))))))))))

(ert-deftest proofread-test-synchronous-queued-callback-drains-once ()
  "Drain synchronous callbacks without duplicate submissions."
  (with-temp-buffer
    (insert "One. Two. Three.")
    (let ((proofread-auto-check nil)
          (proofread-context-size 0)
          (proofread-max-concurrent-requests 1)
          submitted-request-ids)
      (proofread-mode 1)
      (let* ((chunks
              (proofread-test--request-ready-chunks-for-ranges
               (list (cons (point-min) (point-max)))))
             (works
              (mapcar (lambda (chunk)
                        (proofread-test--make-request-work
                         chunk proofread-test--backend))
                      chunks))
             (expected-request-ids
              (mapcar (lambda (work)
                        (plist-get (proofread-test--work-request work)
                                   :id))
                      works)))
        (should (= (length works) 3))
        (proofread--enqueue-requests works)
        (let ((proofread-test--backend-check-function
               (lambda (request callback)
                 (push (plist-get request :id)
                       submitted-request-ids)
                 (funcall callback
                          (proofread--backend-success-result
                           request nil))
                 (list :backend 'test
                       :request-id (plist-get request :id)))))
          (proofread--dispatch-queued-requests))
        (setq submitted-request-ids
              (nreverse submitted-request-ids))
        (should (equal submitted-request-ids expected-request-ids))
        (should (= (length (delete-dups (copy-sequence
                                         submitted-request-ids)))
                   (length works)))
        (should-not proofread--active-requests)
        (should (proofread--request-queue-empty-p))
        (should-not
         (proofread--queue-state-tail proofread--queue-state))
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
                   (left-work
                    (proofread--make-request-work
                     left-request))
                   (right-request
                    (proofread-test--make-profile-request right-chunk))
                   (right-work
                    (proofread--make-request-work
                     right-request))
                   (producer-request
                    (if (eq producer 'left)
                        left-request
                      right-request))
                   (producer-work
                    (if (eq producer 'left)
                        left-work
                      right-work))
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
                      (work (if (eq side 'left)
                                left-work
                              right-work))
                      (diagnostics
                       (if (eq side producer)
                           (list boundary-diagnostic)
                         (list neighbor-diagnostic))))
                  (should
                   (eq (proofread--handle-backend-result
                        work
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
                (should (eq (proofread-diagnostic-at-point 4)
                            live-boundary))
                (should
                 (eq (proofread-diagnostic-at-point
                      (plist-get live-neighbor :beg))
                     live-neighbor))
                (should
                 (eq (proofread--handle-backend-result
                      producer-work
                      (proofread--backend-success-result
                       producer-request nil))
                     'applied))
                (should-not (memq live-boundary proofread--diagnostics))
                (should-not (proofread-diagnostic-at-point 4))
                (should
                 (equal
                  (proofread-test--diagnostics-without-provenance
                   proofread--diagnostics)
                  (list neighbor-diagnostic)))
                (should
                 (eq (proofread-diagnostic-at-point
                      (plist-get live-neighbor :beg))
                     live-neighbor))))))))))

;;;; Runtime setup

(progn
  (proofread-register-backend
   proofread-test--backend
   :check #'proofread-test--backend-check
   :identity #'proofread-test--backend-identity
   :snapshot-options #'proofread-test--snapshot-checker-options
   :cancel #'proofread-test--backend-cancel))

(provide 'proofread-tests)
;;; proofread-tests.el ends here
