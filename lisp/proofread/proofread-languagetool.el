;;; proofread-languagetool.el --- Local LanguageTool backend  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; Assisted-by: Codex:gpt-5.6-sol
;; Author: Bingshan Chang <chang@bingshan.org>
;; Keywords: convenience, wp

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

;; This library implements a local LanguageTool backend for Proofread.
;; It reuses a server already listening on the configured loopback URL
;; and can start `languagetool-http-server' lazily when no server is
;; available.  One managed server is shared by all Proofread buffers
;; in the Emacs session.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'proofread)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-parse)
(require 'url-util)

;;;; Options

(defgroup proofread-languagetool nil
  "Local LanguageTool backend for Proofread."
  :group 'proofread
  :prefix "proofread-languagetool-")

(defcustom proofread-languagetool-server-url
  "http://127.0.0.1:8081/v2"
  "Base URL of the LanguageTool v2 HTTP API.
The URL should not contain credentials, query parameters, or a
fragment.  Plain HTTP is accepted only for loopback hosts.  Automatic
server startup is supported only for a loopback HTTP URL with an
explicit port."
  :type 'string
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-auto-start t
  "Whether to start a local LanguageTool server when none responds.
When nil, Proofread only uses a server already available at
`proofread-languagetool-server-url'.  Ordinary checks then ignore
managed-startup options, while explicit server startup still uses and
validates them."
  :type 'boolean
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-command
  "languagetool-http-server"
  "Command used to start the local LanguageTool HTTP server.
The value may be an executable string, or a nonempty list of strings
whose first element is the executable and whose remaining elements are
fixed arguments.  The executable may be found through variable
`exec-path' or be an absolute file name.  No shell is used.  Fixed
arguments are visible in operating-system process listings and must
not contain credentials; use a protected config file or environment
variable for secrets."
  :type '(choice
          (string :tag "Executable")
          (repeat :tag "Executable and fixed arguments" string))
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-config-file
  (let ((file (getenv "PROOFREAD_LANGUAGETOOL_CONFIG")))
    (and file (not (string-empty-p file)) file))
  "Specify an optional absolute Java properties file for LanguageTool.
The environment variable `PROOFREAD_LANGUAGETOOL_CONFIG' supplies the
initial value.  Avoid placing credentials in a properties file that
is readable by other local users."
  :type '(choice
          (const :tag "Server defaults" nil)
          (file :must-match t))
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-startup-timeout 15.0
  "Seconds to wait for a managed LanguageTool server to become ready."
  :type 'number
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-health-timeout 3.0
  "Seconds to wait for one LanguageTool server health probe."
  :type 'number
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-request-timeout 10.0
  "Seconds to wait for one LanguageTool check request."
  :type 'number
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-level 'default
  "LanguageTool checking level used for requests.
The value `picky' enables additional style rules."
  :type '(choice
          (const :tag "Default" default)
          (const :tag "Picky" picky))
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-preferred-variants nil
  "Specify preferred variants for automatic language detection.
Each value is a LanguageTool long language code such as `en-US' or
`de-DE'.  Send these values only when the effective LanguageTool
language uses automatic detection."
  :type '(repeat string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-mother-tongue nil
  "Optional mother-tongue language code for false-friend checks."
  :type '(choice
          (const :tag "Unspecified" nil)
          string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-enabled-rules nil
  "LanguageTool rule identifiers enabled for each check."
  :type '(repeat string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-disabled-rules nil
  "LanguageTool rule identifiers disabled for each check."
  :type '(repeat string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-enabled-categories nil
  "LanguageTool category identifiers enabled for each check."
  :type '(repeat string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-disabled-categories nil
  "LanguageTool category identifiers disabled for each check."
  :type '(repeat string)
  :local t
  :group 'proofread-languagetool)

(defcustom proofread-languagetool-enabled-only nil
  "Whether to run only explicitly enabled rules and categories.
When non-nil, at least one rule or category must be enabled, and no
rule or category may be disabled."
  :type 'boolean
  :local t
  :group 'proofread-languagetool)

;;;; Constants and state

(defconst proofread-languagetool--contract-version 1
  "Version of the LanguageTool backend request contract.")

(defconst proofread-languagetool--probe-delay 0.1
  "Seconds between managed server health probes.")

(defconst proofread-languagetool--log-limit 50000
  "Maximum characters retained in the managed server log buffer.")

(defconst proofread-languagetool--server-buffer-name
  " *proofread-languagetool-server*"
  "Name of the managed LanguageTool server log buffer.")

(defconst proofread-languagetool--transport-session-global-options
  '( proofread-languagetool-server-url
     proofread-languagetool-auto-start
     proofread-languagetool-health-timeout)
  "Transport options that must remain global for the server manager.")

(defconst proofread-languagetool--managed-session-global-options
  '( proofread-languagetool-command
     proofread-languagetool-config-file
     proofread-languagetool-startup-timeout)
  "Managed-startup options that must remain global when used.")

(defconst proofread-languagetool--json-missing
  (make-symbol "proofread-languagetool-json-missing")
  "Sentinel used for a missing LanguageTool JSON member.")

(defconst proofread-languagetool--json-null
  (make-symbol "proofread-languagetool-json-null")
  "Sentinel used for a LanguageTool JSON null value.")

(defconst proofread-languagetool--json-false
  (make-symbol "proofread-languagetool-json-false")
  "Sentinel used for a LanguageTool JSON false value.")

(defvar proofread-languagetool--server-process nil
  "LanguageTool process owned by this Emacs session, or nil.")

(defvar proofread-languagetool--server-process-session nil
  "Server session associated with the owned LanguageTool process.")

(defvar proofread-languagetool--server-state 'unknown
  "Readiness state of the configured LanguageTool server.")

(defvar proofread-languagetool--server-session nil
  "Snapshot describing the server associated with the current state.")

(defvar proofread-languagetool--server-waiters nil
  "Backend handles waiting for the LanguageTool server to be ready.")

(defvar proofread-languagetool--live-handles nil
  "All undelivered LanguageTool backend handles.")

(defvar proofread-languagetool--server-generation 0
  "Generation used to reject stale process and health callbacks.")

(defvar proofread-languagetool--startup-timer nil
  "Timer limiting managed LanguageTool startup.")

(defvar proofread-languagetool--probe-timeout-timer nil
  "Timer limiting the active LanguageTool health probe.")

(defvar proofread-languagetool--probe-retry-timer nil
  "Timer scheduling the next LanguageTool health probe.")

(defvar proofread-languagetool--probe-retry-token nil
  "Unique token associated with the scheduled health probe.")

(defvar proofread-languagetool--probe-buffer nil
  "URL retrieval buffer for the active LanguageTool health probe.")

(defvar proofread-languagetool--shutting-down-p nil
  "Non-nil while intentionally stopping the managed server.")

(defvar proofread-languagetool--force-start-p nil
  "Non-nil when an interactive command requested managed startup.")

;;;; Configuration and identity

(defun proofread-languagetool--positive-timeout (value option)
  "Return positive numeric VALUE for OPTION, or signal an error."
  (unless (and (numberp value) (> value 0))
    (error "%s must be a positive number" option))
  value)

(defun proofread-languagetool--loopback-host-p (host)
  "Return non-nil when HOST names a loopback interface."
  (member (downcase (or host ""))
          '( "127.0.0.1" "::1" "[::1]" "localhost")))

(defun proofread-languagetool--normalize-server-url (value)
  "Return safe LanguageTool base URL VALUE without trailing slashes."
  (unless (and (stringp value)
               (not (string-empty-p (string-trim value))))
    (error "LanguageTool server URL must be a nonempty string"))
  (when (string-match-p "[[:space:][:cntrl:]]" value)
    (error
     (concat "LanguageTool server URL cannot contain whitespace "
             "or control characters")))
  (when (string-match-p
         "%\\(?:0[0-9A-Fa-f]\\|1[0-9A-Fa-f]\\|7[Ff]\\)"
         value)
    (error (concat "LanguageTool server URL cannot contain encoded "
                   "control characters")))
  (let* ((url (replace-regexp-in-string
               "/+\\'" "" value))
         (parsed (url-generic-parse-url url))
         (type (downcase (or (url-type parsed) "")))
         (host (url-host parsed))
         (port (url-port parsed)))
    (unless (member type '( "http" "https"))
      (error "LanguageTool server URL must use HTTP or HTTPS"))
    (when (or (url-user parsed) (url-password parsed))
      (error "LanguageTool server URL cannot contain credentials"))
    (unless (and (stringp host) (not (string-empty-p host)))
      (error "LanguageTool server URL must contain a host"))
    (when (and (equal type "http")
               (not (proofread-languagetool--loopback-host-p host)))
      (error (concat "LanguageTool server URL requires HTTPS outside "
                     "the loopback interface")))
    (unless (and (integerp port) (> port 0) (< port 65536))
      (error "LanguageTool server URL contains an invalid port"))
    (when (or (url-target parsed)
              (string-match-p "[?#]" url))
      (error (concat "LanguageTool server URL cannot contain a query "
                     "or fragment")))
    (unless (string-suffix-p "/v2" (url-filename parsed))
      (error "LanguageTool server URL must end in /v2"))
    url))

(defun proofread-languagetool--normalized-server-url ()
  "Return the configured safe LanguageTool base URL."
  (proofread-languagetool--normalize-server-url
   proofread-languagetool-server-url))

(defun proofread-languagetool--endpoint (action &optional base-url)
  "Return LanguageTool endpoint ACTION under BASE-URL.
When BASE-URL is nil, validate and use the configured server URL."
  (concat (or base-url
              (proofread-languagetool--normalized-server-url))
          "/" action))

(defun proofread-languagetool--managed-port (session)
  "Return managed startup port for SESSION, or signal an error."
  (let* ((url (url-generic-parse-url
               (plist-get session :base-url)))
         (type (url-type url))
         (host (url-host url))
         (port (url-portspec url)))
    (unless (equal type "http")
      (error "Managed LanguageTool startup requires an HTTP URL"))
    (unless (proofread-languagetool--loopback-host-p host)
      (error "Managed LanguageTool startup requires a loopback URL"))
    (unless (equal (url-filename url) "/v2")
      (error (concat "Managed LanguageTool startup requires the "
                     "direct /v2 path")))
    (unless (and (integerp port) (> port 0) (< port 65536))
      (error (concat "Managed LanguageTool startup requires an "
                     "explicit port")))
    port))

(defun proofread-languagetool--normalized-identifiers (values option)
  "Return sorted LanguageTool identifiers from VALUES for OPTION."
  (unless (listp values)
    (error "%s must be a list of strings" option))
  (let (result)
    (dolist (value values)
      (unless (stringp value)
        (error "%s entries must be strings" option))
      (let ((identifier (string-trim value)))
        (when (or (string-empty-p identifier)
                  (string-match-p "," identifier))
          (error "%s contains an invalid identifier" option))
        (push identifier result)))
    (sort (delete-dups result) #'string<)))

(defun proofread-languagetool--safe-identifiers (values)
  "Return a stable identity value for identifier VALUES."
  (condition-case nil
      (proofread-languagetool--normalized-identifiers
       values 'identity)
    (error (format "%S" values))))

(defun proofread-languagetool--normalized-preferred-variants (values)
  "Return preferred language variant VALUES in user order."
  (unless (listp values)
    (error (concat "LanguageTool preferred variants must be a list "
                   "of strings")))
  (let ((bases (make-hash-table :test #'equal))
        result)
    (dolist (value values)
      (unless (stringp value)
        (error "LanguageTool preferred variants must be strings"))
      (let ((variant (string-trim value)))
        (when (or (string-empty-p variant)
                  (string-match-p "," variant))
          (error (concat "LanguageTool contains an invalid preferred "
                         "variant")))
        (unless (string-match "\\`\\([^-]+\\)-\\(.+\\)\\'" variant)
          (error (concat "LanguageTool preferred variants require a "
                         "long language code")))
        (let* ((base (downcase (match-string 1 variant)))
               (existing (gethash base bases)))
          (when (and existing (not (equal existing variant)))
            (error "LanguageTool preferred variants conflict for %s"
                   base))
          (unless (member variant result)
            (puthash base variant bases)
            (setq result (append result (list variant)))))))
    result))

(defun proofread-languagetool--safe-preferred-variants (values)
  "Return a stable identity value for preferred variant VALUES."
  (condition-case nil
      (proofread-languagetool--normalized-preferred-variants values)
    (error (format "%S" values))))

(defun proofread-languagetool--source-options (source)
  "Return binding-local options from SOURCE, or nil.
SOURCE may be a backend request or a normalized profile binding."
  (or (plist-get source :binding-options)
      (plist-get source :options)))

(defun proofread-languagetool--option (source key fallback)
  "Return SOURCE binding option KEY, or FALLBACK when absent."
  (let ((options (proofread-languagetool--source-options source)))
    (if (plist-member options key)
        (plist-get options key)
      fallback)))

(defun proofread-languagetool--effective-language (request)
  "Return the LanguageTool language option effective for REQUEST."
  (proofread-languagetool--option
   request :language (plist-get request :language)))

(defun proofread-languagetool--effective-level (source)
  "Return the checking level effective for SOURCE."
  (proofread-languagetool--option
   source :level proofread-languagetool-level))

(defun proofread-languagetool--effective-preferred-variants
    (source)
  "Return preferred language variants effective for SOURCE."
  (proofread-languagetool--option
   source :preferred-variants
   proofread-languagetool-preferred-variants))

(defun proofread-languagetool--effective-mother-tongue
    (source)
  "Return the mother-tongue option effective for SOURCE."
  (proofread-languagetool--option
   source :mother-tongue proofread-languagetool-mother-tongue))

(defun proofread-languagetool--effective-enabled-rules
    (source)
  "Return enabled rules effective for SOURCE."
  (proofread-languagetool--option
   source :enabled-rules proofread-languagetool-enabled-rules))

(defun proofread-languagetool--effective-disabled-rules
    (source)
  "Return disabled rules effective for SOURCE."
  (proofread-languagetool--option
   source :disabled-rules proofread-languagetool-disabled-rules))

(defun proofread-languagetool--effective-enabled-categories
    (source)
  "Return enabled categories effective for SOURCE."
  (proofread-languagetool--option
   source :enabled-categories
   proofread-languagetool-enabled-categories))

(defun proofread-languagetool--effective-disabled-categories
    (source)
  "Return disabled categories effective for SOURCE."
  (proofread-languagetool--option
   source :disabled-categories
   proofread-languagetool-disabled-categories))

(defun proofread-languagetool--effective-enabled-only (source)
  "Return enabled-only mode effective for SOURCE."
  (proofread-languagetool--option
   source :enabled-only proofread-languagetool-enabled-only))

(defun proofread-languagetool--safe-language (language)
  "Return a stable identity value for LANGUAGE."
  (condition-case nil
      (cond
       ((null language) "auto")
       ((and (stringp language)
             (not (string-empty-p (string-trim language))))
        (string-trim language))
       (t
        (error "Invalid language")))
    (error (format "%S" language))))

(defun proofread-languagetool--normalized-config-file ()
  "Return the configured absolute server config file, or nil."
  (when proofread-languagetool-config-file
    (unless (and (stringp proofread-languagetool-config-file)
                 (not (string-empty-p
                       proofread-languagetool-config-file)))
      (error "LanguageTool config file must be a nonempty string"))
    (unless (file-name-absolute-p proofread-languagetool-config-file)
      (error "LanguageTool config file must be an absolute path"))
    (when (file-remote-p proofread-languagetool-config-file)
      (error "LanguageTool config file must be a local path"))
    (let ((absolute
           (expand-file-name proofread-languagetool-config-file)))
      (if (file-exists-p absolute)
          (file-truename absolute)
        absolute))))

(defun proofread-languagetool--command-prefix (command)
  "Return validated COMMAND as a fresh argument-prefix list."
  (let ((prefix
         (cond
          ((stringp command) (list command))
          ((listp command) command)
          (t
           (error (concat "LanguageTool command must be a string or "
                          "list of strings"))))))
    (unless (and prefix
                 (cl-every #'stringp prefix)
                 (not (string-empty-p (string-trim (car prefix)))))
      (error "LanguageTool command must have a nonempty executable"))
    (mapcar #'copy-sequence prefix)))

(defun proofread-languagetool--find-command-executable (program)
  "Return the resolved local executable for PROGRAM, or nil."
  (let ((resolved
         (cond
          ((file-name-absolute-p program)
           (and (not (file-remote-p program))
                (file-executable-p program)
                program))
          (t (executable-find program)))))
    (when resolved
      (let ((absolute (expand-file-name resolved)))
        (or (ignore-errors (file-truename absolute))
            absolute)))))

(defun proofread-languagetool--command-snapshot ()
  "Return the configured command with its executable resolved."
  (let* ((string-command-p
          (stringp proofread-languagetool-command))
         (prefix
          (proofread-languagetool--command-prefix
           proofread-languagetool-command))
         (resolved
          (proofread-languagetool--find-command-executable
           (car prefix))))
    (when resolved
      (setcar prefix resolved))
    (if string-command-p (car prefix) prefix)))

(defun proofread-languagetool--safe-command-snapshot ()
  "Return a non-secret cache identity for the configured command."
  (let ((snapshot
         (condition-case nil
             (proofread-languagetool--command-snapshot)
           (error proofread-languagetool-command))))
    (list :fingerprint
          (secure-hash 'sha256 (prin1-to-string snapshot)))))

(defun proofread-languagetool--config-identity-for-file (file)
  "Return non-secret identity information for config FILE."
  (when file
    (let ((attributes (file-attributes file 'string)))
      (list :path-hash (secure-hash 'sha256 file)
            :size (and attributes (file-attribute-size attributes))
            :modified
            (and attributes
                 (float-time
                  (file-attribute-modification-time attributes)))))))

(defun proofread-languagetool--config-identity ()
  "Return non-secret identity information for the server config file."
  (condition-case nil
      (proofread-languagetool--config-identity-for-file
       (proofread-languagetool--normalized-config-file))
    (error 'invalid)))

(defun proofread-languagetool--managed-session-snapshot ()
  "Return validated settings used only for managed server startup."
  (let ((config-file
         (proofread-languagetool--normalized-config-file))
        (command (proofread-languagetool--command-snapshot))
        (startup-timeout
         (proofread-languagetool--positive-timeout
          proofread-languagetool-startup-timeout
          'proofread-languagetool-startup-timeout)))
    (list :config-file config-file
          :command command
          :startup-timeout startup-timeout
          :managed-identity
          (list :server-config
	        (proofread-languagetool--config-identity-for-file
	         config-file)
	        :command command
	        :startup-timeout startup-timeout))))

(defun proofread-languagetool--reject-local-session-options
    (&optional buffer managed)
  "Reject session-global options made local in BUFFER.
When MANAGED is non-nil, also reject managed-startup options."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (dolist
          (option
           (append
            proofread-languagetool--transport-session-global-options
            (and
             managed
             proofread-languagetool--managed-session-global-options)))
        (when (local-variable-p option buffer)
          (error "%s must not be buffer-local" option))))))

(defun proofread-languagetool--server-session-snapshot
    (&optional buffer managed)
  "Return a validated server session snapshot for BUFFER.
When MANAGED is non-nil, include settings required for managed
startup even when automatic startup is disabled."
  (let* ((auto-start (and proofread-languagetool-auto-start t))
         (managed-session-p (or auto-start managed)))
    (proofread-languagetool--reject-local-session-options
     buffer managed-session-p)
    (let* ((base-url
            (proofread-languagetool--normalized-server-url))
           (parsed (url-generic-parse-url base-url))
           (managed-snapshot
            (and managed-session-p
                 (proofread-languagetool--managed-session-snapshot)))
           (request-timeout
            (proofread-languagetool--positive-timeout
             proofread-languagetool-request-timeout
             'proofread-languagetool-request-timeout))
           (health-timeout
            (proofread-languagetool--positive-timeout
             proofread-languagetool-health-timeout
             'proofread-languagetool-health-timeout))
           (identity
            (append
             (list :server-url base-url)
             (when auto-start
               (plist-get managed-snapshot :managed-identity))
             (list :auto-start auto-start
                   :health-timeout health-timeout)))
           (session
            (append
             (list :identity identity
                   :base-url base-url
                   :check-url
                   (proofread-languagetool--endpoint "check" base-url)
                   :health-url
                   (proofread-languagetool--endpoint
                    "healthcheck" base-url)
                   :host (url-host parsed)
                   :loopback
                   (proofread-languagetool--loopback-host-p
                    (url-host parsed)))
             managed-snapshot
             (list :auto-start auto-start
                   :request-timeout request-timeout
                   :health-timeout health-timeout))))
      (when managed-session-p
        (proofread-languagetool--managed-port session))
      session)))

(defun proofread-languagetool--same-session-p (first second)
  "Return non-nil when FIRST and SECOND identify the same server."
  (and first second
       (equal (plist-get first :identity)
              (plist-get second :identity))))

(defun proofread-languagetool--same-managed-session-p (first second)
  "Return non-nil when FIRST and SECOND share managed settings."
  (let ((identity (and first
                       (plist-get first :managed-identity))))
    (and identity second
         (equal identity (plist-get second :managed-identity)))))

(defun proofread-languagetool--current-session-p
    (generation session)
  "Return non-nil when GENERATION and SESSION are still current."
  (and (not proofread-languagetool--shutting-down-p)
       (integerp generation)
       (= generation proofread-languagetool--server-generation)
       (proofread-languagetool--same-session-p
        session proofread-languagetool--server-session)))

(defun proofread-languagetool--server-identity ()
  "Return the stable, non-secret LanguageTool server identity."
  (append
   (list :backend 'languagetool
         :server-url
         (condition-case nil
             (proofread-languagetool--normalized-server-url)
           (error "Invalid")))
   (when proofread-languagetool-auto-start
     (list :server-config (proofread-languagetool--config-identity)
           :server-command
           (proofread-languagetool--safe-command-snapshot)))))

(defun proofread-languagetool--request-options-identity
    (source)
  "Return the stable LanguageTool request-options identity for SOURCE."
  (append
   (when (plist-member
          (proofread-languagetool--source-options source)
          :language)
     (list :language
           (proofread-languagetool--safe-language
            (proofread-languagetool--option source :language nil))))
   (list :level (proofread-languagetool--effective-level source)
         :preferred-variants
         (proofread-languagetool--safe-preferred-variants
          (proofread-languagetool--effective-preferred-variants
           source))
         :mother-tongue
         (proofread-languagetool--effective-mother-tongue source)
         :enabled-rules
         (proofread-languagetool--safe-identifiers
          (proofread-languagetool--effective-enabled-rules
           source))
         :disabled-rules
         (proofread-languagetool--safe-identifiers
          (proofread-languagetool--effective-disabled-rules
           source))
         :enabled-categories
         (proofread-languagetool--safe-identifiers
          (proofread-languagetool--effective-enabled-categories
           source))
         :disabled-categories
         (proofread-languagetool--safe-identifiers
          (proofread-languagetool--effective-disabled-categories
           source))
         :enabled-only
         (proofread-languagetool--effective-enabled-only source)
         :contract-version proofread-languagetool--contract-version)))

(defun proofread-languagetool--identity-for-source (source)
  "Return stable LanguageTool identity for SOURCE."
  (append
   (proofread-languagetool--server-identity)
   (proofread-languagetool--request-options-identity source)))

(defun proofread-languagetool--identity ()
  "Return the stable, non-secret LanguageTool backend identity."
  (proofread-languagetool--identity-for-source nil))

(defun proofread-languagetool--binding-identity (binding)
  "Return stable cache identity for normalized profile BINDING."
  (proofread-languagetool--identity-for-source binding))

;;;; Request encoding and response parsing

(defun proofread-languagetool--request-language (request)
  "Return the LanguageTool language code for REQUEST."
  (let ((language (proofread-languagetool--effective-language
                   request)))
    (cond
     ((null language) "auto")
     ((and (stringp language)
           (not (string-empty-p (string-trim language))))
      (string-trim language))
     (t
      (error
       "Proofread language must be nil or a nonempty string")))))

(defun proofread-languagetool--form-encode (parameters)
  "Return application/x-www-form-urlencoded PARAMETERS."
  (mapconcat
   (lambda (parameter)
     (concat (url-hexify-string (car parameter))
             "="
             (url-hexify-string (cdr parameter))))
   parameters "&"))

(defun proofread-languagetool--request-data (request)
  "Return HTTP and range data for LanguageTool REQUEST."
  (let* ((before (or (plist-get request :context-before) ""))
         (text (plist-get request :text))
         (after (or (plist-get request :context-after) ""))
         (language (proofread-languagetool--request-language request))
         (level (proofread-languagetool--effective-level request))
         (preferred-variants
          (proofread-languagetool--effective-preferred-variants
           request))
         (mother-tongue
          (proofread-languagetool--effective-mother-tongue
           request))
         (enabled-only
          (proofread-languagetool--effective-enabled-only request))
         (enabled
          (proofread-languagetool--normalized-identifiers
           (proofread-languagetool--effective-enabled-rules
            request)
           'proofread-languagetool-enabled-rules))
         (disabled
          (proofread-languagetool--normalized-identifiers
           (proofread-languagetool--effective-disabled-rules
            request)
           'proofread-languagetool-disabled-rules))
         (enabled-categories
          (proofread-languagetool--normalized-identifiers
           (proofread-languagetool--effective-enabled-categories
            request)
           'proofread-languagetool-enabled-categories))
         (disabled-categories
          (proofread-languagetool--normalized-identifiers
           (proofread-languagetool--effective-disabled-categories
            request)
           'proofread-languagetool-disabled-categories))
         parameters)
    (unless (and (stringp before) (stringp text) (stringp after))
      (error "LanguageTool request text and context must be strings"))
    (unless (memq level '( default picky))
      (error "Invalid LanguageTool checking level: %S"
             level))
    (when (and enabled-only
               (or disabled disabled-categories))
      (error (concat "LanguageTool enabled-only mode cannot include "
                     "disabled rules or categories")))
    (when (and enabled-only
               (null enabled)
               (null enabled-categories))
      (error (concat "LanguageTool enabled-only mode requires an "
                     "enabled rule or category")))
    (setq parameters
          (list (cons "language" language)
                (cons "text" (concat before text after))
                (cons "level" (symbol-name level))))
    (when (and (equal language "auto") preferred-variants)
      (push (cons
             "preferredVariants"
             (string-join
              (proofread-languagetool--normalized-preferred-variants
               preferred-variants)
              ","))
            parameters))
    (when mother-tongue
      (unless (and (stringp mother-tongue)
                   (not (string-empty-p
                         (string-trim mother-tongue))))
        (error (concat "LanguageTool mother tongue must be a "
                       "nonempty string")))
      (push (cons "motherTongue"
                  (string-trim mother-tongue))
            parameters))
    (when enabled
      (push (cons "enabledRules" (string-join enabled ","))
            parameters))
    (when disabled
      (push (cons "disabledRules" (string-join disabled ","))
            parameters))
    (when enabled-categories
      (push (cons "enabledCategories"
                  (string-join enabled-categories ","))
            parameters))
    (when disabled-categories
      (push (cons "disabledCategories"
                  (string-join disabled-categories ","))
            parameters))
    (when enabled-only
      (push (cons "enabledOnly" "true") parameters))
    (setq parameters (nreverse parameters))
    (list :body (proofread-languagetool--form-encode parameters)
          :parameters parameters
          :text (concat before text after)
          :target-beg (length before)
          :target-end (+ (length before) (length text)))))

(defun proofread-languagetool--utf16-offset-to-index (text offset)
  "Convert UTF-16 code-unit OFFSET in TEXT to an Emacs string index.
Return nil when OFFSET is out of range or splits a surrogate pair."
  (when (and (stringp text) (integerp offset) (>= offset 0))
    (let ((index 0)
          (units 0)
          result)
      (while (and (null result) (< index (length text)))
        (cond
         ((= units offset)
          (setq result index))
         ((> units offset)
          (setq index (length text)))
         (t
          (setq units
                (+ units
                   (if (> (aref text index) #xffff) 2 1)))
          (setq index (1+ index)))))
      (cond
       (result result)
       ((= units offset) index)
       (t nil)))))

(defun proofread-languagetool--json-value (object key)
  "Return hash-table OBJECT's string KEY, or the missing sentinel."
  (if (hash-table-p object)
      (gethash key object proofread-languagetool--json-missing)
    proofread-languagetool--json-missing))

(defun proofread-languagetool--array-list (value)
  "Return JSON array VALUE as a list, or signal an error."
  (unless (vectorp value)
    (error "Expected a JSON array"))
  (append value nil))

(defun proofread-languagetool--diagnostic-kind (issue-type)
  "Return a Proofread diagnostic kind for ISSUE-TYPE."
  (pcase issue-type
    ((or "misspelling" "typographical") 'spelling)
    ("grammar" 'grammar)
    ((or "style" "register" "locale-violation"
         "non-conformance")
     'style)
    (_ 'other)))

(defun proofread-languagetool--replacement-values (match)
  "Return replacement strings from LanguageTool MATCH."
  (let ((replacements
         (proofread-languagetool--json-value
          match "replacements"))
        values)
    (unless (memq replacements
                  (list proofread-languagetool--json-missing
                        proofread-languagetool--json-null))
      (dolist (replacement
               (proofread-languagetool--array-list replacements))
        (unless (hash-table-p replacement)
          (error "LanguageTool replacement must be a JSON object"))
        (let ((value
               (proofread-languagetool--json-value
                replacement "value")))
          (when (stringp value)
            (push value values)))))
    (delete-dups (nreverse values))))

(defun proofread-languagetool--match-diagnostic
    (request request-data full-text match)
  "Return a Proofread diagnostic for LanguageTool MATCH.
REQUEST identifies the source request.  REQUEST-DATA describes
FULL-TEXT and the target within it.  Return nil for a valid match that
does not stay wholly inside the target."
  (unless (hash-table-p match)
    (error "LanguageTool match must be a JSON object"))
  (let* ((offset
          (proofread-languagetool--json-value match "offset"))
         (match-length
          (proofread-languagetool--json-value match "length"))
         (message
          (proofread-languagetool--json-value match "message"))
         (rule (proofread-languagetool--json-value match "rule"))
         (issue-type (and (hash-table-p rule)
                          (proofread-languagetool--json-value
                           rule "issueType")))
         start end)
    (unless (and (integerp offset) (>= offset 0)
                 (integerp match-length) (>= match-length 0)
                 (stringp message))
      (error "LanguageTool returned an invalid match"))
    (setq start
          (proofread-languagetool--utf16-offset-to-index
           full-text offset))
    (setq end
          (proofread-languagetool--utf16-offset-to-index
           full-text (+ offset match-length)))
    (unless (and start end (<= start end))
      (error "LanguageTool returned an invalid UTF-16 range"))
    (when (and (<= (plist-get request-data :target-beg) start)
               (<= end (plist-get request-data :target-end)))
      (proofread--diagnostic-from-request-relative-range
       request
       (cons (- start (plist-get request-data :target-beg))
             (- end (plist-get request-data :target-beg)))
       (list :kind
             (proofread-languagetool--diagnostic-kind issue-type)
             :message message
             :suggestions
             (proofread-languagetool--replacement-values match)
             :source 'languagetool)))))

(defun proofread-languagetool--parse-response
    (request request-data response)
  "Return diagnostics parsed from LanguageTool RESPONSE for REQUEST.
REQUEST-DATA describes the submitted text and target range."
  (let* ((payload
          (json-parse-string response
                             :object-type 'hash-table
                             :array-type 'array
                             :null-object
                             proofread-languagetool--json-null
                             :false-object
                             proofread-languagetool--json-false))
         (matches
          (proofread-languagetool--json-value payload "matches"))
         diagnostics)
    (unless (vectorp matches)
      (error "LanguageTool response has no matches array"))
    (dolist (match
             (proofread-languagetool--array-list matches))
      (when-let* ((diagnostic
                   (proofread-languagetool--match-diagnostic
                    request request-data
                    (plist-get request-data :text) match)))
        (push diagnostic diagnostics)))
    (nreverse diagnostics)))

;;;; Request handles and HTTP transport

(defun proofread-languagetool--new-handle (request callback)
  "Return a backend handle for REQUEST and CALLBACK."
  (let ((handle
         (list :backend 'languagetool
               :request request
               :callback callback
               :request-data nil
               :session nil
               :cancelled nil
               :delivered nil
               :timer nil
               :http-buffer nil
               :server-generation nil
               :url nil)))
    (push handle proofread-languagetool--live-handles)
    handle))

(defun proofread-languagetool--cancel-handle-timer (handle)
  "Cancel and clear HANDLE's timer."
  (when-let* ((timer (plist-get handle :timer))
              ((timerp timer)))
    (cancel-timer timer))
  (setf (plist-get handle :timer) nil))

(defun proofread-languagetool--handle-live-p (handle)
  "Return non-nil when HANDLE may still perform backend work."
  (and (not proofread-languagetool--shutting-down-p)
       (not (plist-get handle :cancelled))
       (not (plist-get handle :delivered))
       (memq handle proofread-languagetool--live-handles)))

(defun proofread-languagetool--kill-url-buffer (buffer)
  "Kill retrieval BUFFER and its process without prompting."
  (when (buffer-live-p buffer)
    (when-let* ((process (ignore-errors
                           (get-buffer-process buffer))))
      (ignore-errors
        (set-process-query-on-exit-flag process nil))
      (ignore-errors (delete-process process)))
    (when (buffer-live-p buffer)
      (condition-case nil
          (with-current-buffer buffer
            (let ((kill-buffer-query-functions nil)
                  (kill-buffer-hook nil))
              (kill-buffer buffer)))
        (error nil)))))

(defun proofread-languagetool--deliver (handle result)
  "Deliver RESULT through HANDLE at most once."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered))
    (setf (plist-get handle :delivered) t)
    (setq proofread-languagetool--live-handles
          (delq handle proofread-languagetool--live-handles))
    (setq proofread-languagetool--server-waiters
          (delq handle proofread-languagetool--server-waiters))
    (proofread-languagetool--cancel-handle-timer handle)
    (let ((buffer (plist-get handle :http-buffer)))
      (setf (plist-get handle :http-buffer) nil)
      (proofread-languagetool--kill-url-buffer buffer))
    (proofread--record-request-event
     (plist-get handle :request) 'backend-result
     :backend 'languagetool
     :result result)
    (funcall (plist-get handle :callback) result)))

(defun proofread-languagetool--deliver-error
    (handle error-symbol message)
  "Deliver ERROR-SYMBOL with MESSAGE through HANDLE."
  (proofread-languagetool--deliver
   handle
   (proofread--backend-error-result
    (plist-get handle :request) error-symbol message)))

(defun proofread-languagetool--deliver-error-later
    (handle error-symbol message)
  "Deliver ERROR-SYMBOL and MESSAGE through HANDLE on the next turn."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered))
    (proofread-languagetool--cancel-handle-timer handle)
    (setf (plist-get handle :timer)
          (run-at-time
           0 nil
           #'proofread-languagetool--deliver-error
           handle error-symbol message))))

(defun proofread-languagetool--cancel (handle)
  "Cancel the LanguageTool request represented by HANDLE."
  (when (listp handle)
    (setf (plist-get handle :cancelled) t)
    (setq proofread-languagetool--live-handles
          (delq handle proofread-languagetool--live-handles))
    (proofread-languagetool--cancel-handle-timer handle)
    (setq proofread-languagetool--server-waiters
          (delq handle proofread-languagetool--server-waiters))
    (let ((buffer (plist-get handle :http-buffer)))
      (setf (plist-get handle :http-buffer) nil)
      (proofread-languagetool--kill-url-buffer buffer))))

(defun proofread-languagetool--settle-live-handles
    (error-symbol message)
  "Settle all live handles, including handles added by callbacks.
Use ERROR-SYMBOL and MESSAGE for each result."
  (while proofread-languagetool--live-handles
    (let ((handles
           (copy-sequence proofread-languagetool--live-handles)))
      (dolist (handle handles)
        (condition-case nil
            (proofread-languagetool--deliver-error
             handle error-symbol message)
          (error nil))))))

(defun proofread-languagetool--http-body ()
  "Return the decoded body in the current URL response buffer."
  (let* ((end-of-headers
          (and (boundp 'url-http-end-of-headers)
               (symbol-value 'url-http-end-of-headers)))
         (start
          (cond
           ((markerp end-of-headers)
            (marker-position end-of-headers))
           ((integerp end-of-headers)
            end-of-headers)
           (t (error "Malformed HTTP response headers"))))
         (raw
          (progn
            (unless (<= (point-min) start (point-max))
              (error "Malformed HTTP response body range"))
            (buffer-substring-no-properties start (point-max)))))
    (string-trim-left
     (if (multibyte-string-p raw)
         raw
       (decode-coding-string raw 'utf-8))
     "[\r\n]+")))

(defun proofread-languagetool--bounded-message (message)
  "Return a single-line, bounded version of MESSAGE."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[[:space:]]+" " " (or message "LanguageTool request failed"))
   500 nil nil t))

(defun proofread-languagetool--callback-status-error (status)
  "Return transport error from URL callback STATUS.
Signal an error when STATUS is not a URL callback status plist."
  (cond
   ((null status) nil)
   ((listp status) (plist-get status :error))
   (t (error "Malformed URL callback status"))))

(defun proofread-languagetool--http-response-status ()
  "Return the current integer HTTP response status, or nil."
  (let ((status
         (and (boundp 'url-http-response-status)
              (symbol-value 'url-http-response-status))))
    (unless (or (null status) (integerp status))
      (error "Malformed HTTP response status"))
    status))

(defun proofread-languagetool--record-response
    (handle &rest properties)
  "Record a backend response for HANDLE with PROPERTIES."
  (apply #'proofread--record-request-event
         (plist-get handle :request) 'backend-response
         :backend 'languagetool
         :url (plist-get handle :url)
         properties))

(defun proofread-languagetool--request-timeout (handle)
  "Fail the LanguageTool request represented by HANDLE."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered))
    (when (proofread-languagetool--current-session-p
           (plist-get handle :server-generation)
           (plist-get handle :session))
      (setq proofread-languagetool--server-state 'unknown))
    (proofread-languagetool--record-response
     handle
     :error 'languagetool-request-timeout
     :message "LanguageTool request timed out")
    (proofread-languagetool--deliver-error
     handle 'languagetool-request-timeout
     "LanguageTool request timed out")))

(defun proofread-languagetool--check-response (status handle)
  "Handle LanguageTool check response STATUS for HANDLE."
  (let* ((buffer (current-buffer))
         (active-p
          (eq buffer (plist-get handle :http-buffer))))
    (when active-p
      (setf (plist-get handle :http-buffer) nil)
      (proofread-languagetool--cancel-handle-timer handle))
    (unwind-protect
        (when (and active-p
                   (proofread-languagetool--handle-live-p handle))
          (let ((status-result
                 (condition-case err
                     (list :ok
		           (proofread-languagetool--callback-status-error
                            status))
                   (error
                    (list :error (error-message-string err))))))
            (if (eq (car status-result) :error)
                (let ((message
                       (proofread-languagetool--bounded-message
                        (cadr status-result))))
                  (proofread-languagetool--record-response
                   handle
                   :error 'languagetool-invalid-response
                   :message message)
                  (proofread-languagetool--deliver-error
                   handle 'languagetool-invalid-response message))
              (let ((transport-error (cadr status-result)))
                (if transport-error
                    (let ((http-status
                           (ignore-errors
                             (proofread-languagetool--http-response-status)))
                          (body
                           (ignore-errors
                             (proofread-languagetool--http-body)))
                          (message
                           (proofread-languagetool--bounded-message
                            (format "%S" transport-error))))
                      (proofread-languagetool--record-response
                       handle
                       :http-status http-status
                       :response body
                       :error 'languagetool-transport-error
                       :message message)
                      (when
                          (proofread-languagetool--current-session-p
                           (plist-get handle :server-generation)
                           (plist-get handle :session))
                        (setq proofread-languagetool--server-state
                              'unknown))
                      (proofread-languagetool--deliver-error
                       handle 'languagetool-transport-error message))
                  (let ((decoded
                         (condition-case err
                             (list
                              :ok
                              (proofread-languagetool--http-response-status)
                              (proofread-languagetool--http-body))
                           (error
                            (list :error
			          (error-message-string err))))))
                    (if (eq (car decoded) :error)
                        (let ((message
                               (proofread-languagetool--bounded-message
                                (cadr decoded))))
                          (proofread-languagetool--record-response
                           handle
                           :error 'languagetool-invalid-response
                           :message message)
                          (proofread-languagetool--deliver-error
                           handle 'languagetool-invalid-response
                           message))
                      (let* ((http-status (nth 1 decoded))
                             (body (nth 2 decoded))
                             (response-error
                              (unless (eq http-status 200)
                                'languagetool-http-error))
                             (message
                              (and response-error
                                   (proofread-languagetool--bounded-message
                                    (format
                                     "LanguageTool HTTP status %s: %s"
                                     (or http-status "unknown")
                                     body)))))
                        (proofread-languagetool--record-response
                         handle
                         :http-status http-status
                         :response body
                         :error response-error
                         :message message)
                        (if response-error
                            (proofread-languagetool--deliver-error
                             handle response-error message)
                          (condition-case err
                              (proofread-languagetool--deliver
                               handle
                               (proofread--backend-success-result
                                (plist-get handle :request)
                                (proofread-languagetool--parse-response
                                 (plist-get handle :request)
                                 (plist-get handle :request-data)
                                 body)))
                            (error
                             (proofread-languagetool--deliver-error
                              handle
                              'languagetool-invalid-response
                              (error-message-string err)))))))))))))
      (proofread-languagetool--kill-url-buffer buffer))))

(defun proofread-languagetool--submit (handle)
  "Submit the check request represented by HANDLE."
  (unless (or (plist-get handle :cancelled)
              (plist-get handle :delivered))
    (condition-case err
        (let* ((request (plist-get handle :request))
               (request-data (plist-get handle :request-data))
               (session (plist-get handle :session))
               (check-url (plist-get session :check-url))
               (timeout (plist-get session :request-timeout))
               (url-request-method "POST")
               (url-request-data (plist-get request-data :body))
               (url-request-extra-headers
                '(("Content-Type" .
                   "application/x-www-form-urlencoded; charset=utf-8")
                  ("Accept" . "application/json")))
               (url-proxy-services
                (if (proofread-languagetool--loopback-host-p
                     (plist-get session :host))
                    nil
                  url-proxy-services))
               buffer)
          (setf (plist-get handle :url) check-url)
          (setf (plist-get handle :server-generation)
                proofread-languagetool--server-generation)
          (proofread--record-request-event
           request 'backend-request
           :backend 'languagetool
           :method "POST"
           :url check-url
           :parameters (plist-get request-data :parameters))
          (when (proofread-languagetool--handle-live-p handle)
            (setq buffer
                  (cl-progv '( url-max-redirections) '( 0)
                    (url-retrieve
                     check-url
                     #'proofread-languagetool--check-response
                     (list handle) t t)))
            (unless (buffer-live-p buffer)
              (error
               "LanguageTool request did not return a live buffer"))
            (with-current-buffer buffer
              (set (make-local-variable 'url-max-redirections) 0))
            (if (proofread-languagetool--handle-live-p handle)
                (progn
                  (setf (plist-get handle :http-buffer) buffer)
                  (setf (plist-get handle :timer)
                        (run-at-time
                         timeout nil
                         #'proofread-languagetool--request-timeout
                         handle)))
              (proofread-languagetool--kill-url-buffer buffer))))
      (error
       (let ((message (error-message-string err)))
         (when (plist-get handle :url)
           (proofread-languagetool--record-response
            handle
            :error 'languagetool-request-error
            :message message))
         (proofread-languagetool--deliver-error-later
          handle 'languagetool-request-error message))))))

;;;; Server readiness and managed process lifecycle

(defun proofread-languagetool--cancel-global-timer (symbol)
  "Cancel the timer stored in variable SYMBOL and set it to nil."
  (when-let* ((timer (symbol-value symbol))
              ((timerp timer)))
    (cancel-timer timer))
  (set symbol nil))

(defun proofread-languagetool--cancel-probe-retry ()
  "Cancel the scheduled LanguageTool health-probe retry."
  (proofread-languagetool--cancel-global-timer
   'proofread-languagetool--probe-retry-timer)
  (setq proofread-languagetool--probe-retry-token nil))

(defun proofread-languagetool--clear-probe ()
  "Cancel the active LanguageTool health probe."
  (proofread-languagetool--cancel-global-timer
   'proofread-languagetool--probe-timeout-timer)
  (let ((buffer proofread-languagetool--probe-buffer))
    (setq proofread-languagetool--probe-buffer nil)
    (proofread-languagetool--kill-url-buffer buffer)))

(defun proofread-languagetool--cancel-readiness-work ()
  "Cancel all asynchronous LanguageTool server-readiness work."
  (proofread-languagetool--cancel-global-timer
   'proofread-languagetool--startup-timer)
  (proofread-languagetool--cancel-probe-retry)
  (proofread-languagetool--clear-probe))

(defun proofread-languagetool--forget-owned-process ()
  "Forget and return the LanguageTool process owned by this session."
  (prog1 proofread-languagetool--server-process
    (setq proofread-languagetool--server-process nil)
    (setq proofread-languagetool--server-process-session nil)))

(defun proofread-languagetool--stop-owned-process ()
  "Stop and forget the LanguageTool process owned by this session."
  (let ((process (proofread-languagetool--forget-owned-process))
        (proofread-languagetool--shutting-down-p t))
    (when (process-live-p process)
      (set-process-query-on-exit-flag process nil)
      (delete-process process))))

(defun proofread-languagetool--defer-waiters
    (error-symbol message)
  "Fail current server waiters later with ERROR-SYMBOL and MESSAGE."
  (let ((waiters (nreverse proofread-languagetool--server-waiters)))
    (setq proofread-languagetool--server-waiters nil)
    (dolist (handle waiters)
      (condition-case nil
          (proofread-languagetool--deliver-error-later
           handle error-symbol message)
        (error nil)))))

(defun proofread-languagetool--drain-waiters (session)
  "Submit live requests waiting for SESSION readiness."
  (let ((waiters (nreverse proofread-languagetool--server-waiters)))
    (setq proofread-languagetool--server-waiters nil)
    (dolist (handle waiters)
      (if (proofread-languagetool--same-session-p
           (plist-get handle :session) session)
          (proofread-languagetool--submit handle)
        (proofread-languagetool--deliver-error-later
         handle 'languagetool-session-changed
         "LanguageTool server configuration changed")))))

(defun proofread-languagetool--fail-waiters
    (error-symbol message)
  "Fail server waiters with ERROR-SYMBOL and MESSAGE."
  (let ((waiters (nreverse proofread-languagetool--server-waiters)))
    (setq proofread-languagetool--server-waiters nil)
    (dolist (handle waiters)
      (condition-case nil
          (proofread-languagetool--deliver-error
           handle error-symbol message)
        (error nil)))))

(defun proofread-languagetool--fail-readiness
    (error-symbol message)
  "End the readiness attempt with ERROR-SYMBOL and MESSAGE."
  (cl-incf proofread-languagetool--server-generation)
  (setq proofread-languagetool--server-state 'unknown)
  (setq proofread-languagetool--force-start-p nil)
  (proofread-languagetool--cancel-readiness-work)
  (proofread-languagetool--fail-waiters error-symbol message))

(defun proofread-languagetool--server-ready (generation session)
  "Mark server GENERATION and SESSION ready and submit waiters."
  (when (proofread-languagetool--current-session-p
         generation session)
    (proofread-languagetool--cancel-readiness-work)
    (setq proofread-languagetool--server-state 'ready)
    (setq proofread-languagetool--force-start-p nil)
    (proofread-languagetool--drain-waiters session)))

(defun proofread-languagetool--server-command (session)
  "Return the argument prefix used for managed startup of SESSION."
  (let* ((prefix
          (proofread-languagetool--command-prefix
           (plist-get session :command)))
         (resolved
          (proofread-languagetool--find-command-executable
           (car prefix))))
    (unless resolved
      (error "Cannot find LanguageTool command: %s" (car prefix)))
    (setcar prefix resolved)
    prefix))

(defun proofread-languagetool--server-arguments (session)
  "Return arguments for managed startup of SESSION."
  (let ((config-file (plist-get session :config-file))
        arguments)
    (when config-file
      (unless (file-readable-p config-file)
        (error "LanguageTool config file is not readable: %s"
               config-file))
      (setq arguments
            (append arguments
                    (list "--config" config-file))))
    (append arguments
            (list "--port"
                  (number-to-string
                   (proofread-languagetool--managed-port session))))))

(defun proofread-languagetool--process-filter (process output)
  "Append PROCESS OUTPUT to a bounded diagnostic buffer."
  (when-let* ((buffer (process-buffer process))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (at-end-p (= (point) (point-max))))
        (goto-char (point-max))
        (insert output)
        (when (> (buffer-size) proofread-languagetool--log-limit)
          (delete-region
           (point-min)
           (- (point-max) proofread-languagetool--log-limit)))
        (when at-end-p
          (goto-char (point-max)))))))

(defun proofread-languagetool--process-sentinel (process _event)
  "Update managed server state when PROCESS exits."
  (when (and (eq process proofread-languagetool--server-process)
             (memq (process-status process)
                   '( exit signal closed failed)))
    (let ((state proofread-languagetool--server-state))
      (proofread-languagetool--forget-owned-process)
      (unless proofread-languagetool--shutting-down-p
        (pcase state
          ('starting
           (proofread-languagetool--fail-readiness
            'languagetool-startup-failed
            (format "LanguageTool server exited with status %d"
                    (process-exit-status process))))
          ('probing
           (condition-case nil
               (proofread-languagetool--begin-readiness-check
                proofread-languagetool--server-session)
             (error nil)))
          (_
           (setq proofread-languagetool--server-state 'unknown)))))))

(defun proofread-languagetool--startup-timeout
    (generation session)
  "Fail startup for unready server GENERATION and SESSION."
  (when (and (proofread-languagetool--current-session-p
              generation session)
             (eq proofread-languagetool--server-state 'starting))
    (proofread-languagetool--stop-owned-process)
    (proofread-languagetool--fail-readiness
     'languagetool-startup-timeout
     "LanguageTool server did not become ready in time")))

(defun proofread-languagetool--arm-startup-timeout
    (generation session)
  "Arm the managed startup timeout for GENERATION and SESSION."
  (proofread-languagetool--cancel-global-timer
   'proofread-languagetool--startup-timer)
  (setq proofread-languagetool--startup-timer
        (run-at-time
         (plist-get session :startup-timeout) nil
         #'proofread-languagetool--startup-timeout
         generation session)))

(defun proofread-languagetool--start-managed-server
    (generation session)
  "Start or reprobe a managed server for GENERATION and SESSION."
  (when (proofread-languagetool--current-session-p
         generation session)
    (let (new-process)
      (condition-case err
          (let ((existing proofread-languagetool--server-process)
                (existing-session
                 proofread-languagetool--server-process-session))
            (when (and (process-live-p existing)
                       (not
                        (and
                         (proofread-languagetool--same-session-p
                          existing-session
                          session)
                         (proofread-languagetool--same-managed-session-p
                          existing-session
                          session))))
              (proofread-languagetool--stop-owned-process)
              (setq existing nil))
            (setq proofread-languagetool--server-state 'starting)
            (proofread-languagetool--arm-startup-timeout
             generation session)
            (if (process-live-p existing)
                (proofread-languagetool--schedule-probe
                 generation 'startup session 0)
              (let* ((command-prefix
                      (proofread-languagetool--server-command
                       session))
                     (arguments
                      (proofread-languagetool--server-arguments
                       session))
                     (buffer
                      (get-buffer-create
                       proofread-languagetool--server-buffer-name))
                     (process
                      (setq new-process
                            (make-process
                             :name "proofread-languagetool-server"
                             :buffer buffer
                             :command
                             (append command-prefix arguments)
                             :connection-type 'pipe
                             :filter
                             #'proofread-languagetool--process-filter
                             :sentinel
                             #'proofread-languagetool--process-sentinel
                             :noquery t))))
                (set-process-query-on-exit-flag process nil)
                (setq proofread-languagetool--server-process process)
                (setq proofread-languagetool--server-process-session
                      session)
                (proofread-languagetool--schedule-probe
                 generation 'startup session 0))))
        (error
         (when (eq new-process
                   proofread-languagetool--server-process)
           (proofread-languagetool--forget-owned-process))
         (when (process-live-p new-process)
           (let ((proofread-languagetool--shutting-down-p t))
             (set-process-query-on-exit-flag new-process nil)
             (delete-process new-process)))
         (proofread-languagetool--fail-readiness
          'languagetool-startup-error
          (error-message-string err)))))))

(defun proofread-languagetool--probe-failed
    (generation phase session)
  "Handle failed health probe for GENERATION, PHASE, and SESSION."
  (when (proofread-languagetool--current-session-p
         generation session)
    (pcase phase
      ('external
       (if (or (plist-get session :auto-start)
               proofread-languagetool--force-start-p)
           (proofread-languagetool--start-managed-server
            generation session)
         (proofread-languagetool--fail-readiness
          'languagetool-unavailable
          "No LanguageTool server is available")))
      ('startup
       (let* ((process proofread-languagetool--server-process)
              (live-p (process-live-p process)))
         (if (and (eq proofread-languagetool--server-state 'starting)
                  live-p)
             (proofread-languagetool--schedule-probe
              generation 'startup session
              proofread-languagetool--probe-delay)
           (unless live-p
             (proofread-languagetool--forget-owned-process))
           (proofread-languagetool--fail-readiness
            'languagetool-startup-failed
            "LanguageTool server exited before becoming ready")))))))

(defun proofread-languagetool--probe-timeout
    (generation phase session buffer)
  "Abort BUFFER probe for GENERATION, PHASE, and SESSION."
  (when (and (proofread-languagetool--current-session-p
              generation session)
             (eq buffer proofread-languagetool--probe-buffer))
    (proofread-languagetool--clear-probe)
    (proofread-languagetool--probe-failed
     generation phase session)))

(defun proofread-languagetool--probe-response
    (status generation phase session)
  "Handle probe STATUS for GENERATION, PHASE, and SESSION."
  (let* ((buffer (current-buffer))
         (active
          (and (eq buffer proofread-languagetool--probe-buffer)
               (proofread-languagetool--current-session-p
                generation session))))
    (unwind-protect
        (when active
          (setq proofread-languagetool--probe-buffer nil)
          (proofread-languagetool--cancel-global-timer
           'proofread-languagetool--probe-timeout-timer)
          (if
              (condition-case nil
                  (and
                   (not
                    (proofread-languagetool--callback-status-error
                     status))
                   (eq
                    (proofread-languagetool--http-response-status)
                    200)
                   (equal
                    (string-trim
                     (proofread-languagetool--http-body))
                    "OK"))
                (error nil))
              (proofread-languagetool--server-ready
               generation session)
            (proofread-languagetool--probe-failed
             generation phase session)))
      (proofread-languagetool--kill-url-buffer buffer))))

(defun proofread-languagetool--run-probe
    (generation phase session token)
  "Run TOKEN probe for GENERATION, PHASE, and SESSION."
  (when (and (eq token proofread-languagetool--probe-retry-token)
             (proofread-languagetool--current-session-p
              generation session))
    (proofread-languagetool--cancel-probe-retry)
    (let (buffer timeout-timer published-p)
      (condition-case nil
          (let* ((url-request-method "GET")
                 (url-request-data nil)
                 (url-request-extra-headers nil)
                 (url-proxy-services
                  (if (plist-get session :loopback)
                      nil
                    url-proxy-services))
                 (retrieved
                  (cl-progv '( url-max-redirections) '( 0)
                    (url-retrieve
                     (plist-get session :health-url)
                     #'proofread-languagetool--probe-response
                     (list generation phase session) t t))))
            (setq buffer retrieved)
            (unless (buffer-live-p buffer)
              (error
               "LanguageTool probe did not return a live buffer"))
            (with-current-buffer buffer
              (set (make-local-variable 'url-max-redirections) 0))
            (when (and
                   (proofread-languagetool--current-session-p
                    generation session)
                   (null proofread-languagetool--probe-buffer)
                   (null proofread-languagetool--probe-retry-token))
              (setq timeout-timer
                    (run-at-time
                     (plist-get session :health-timeout) nil
                     #'proofread-languagetool--probe-timeout
                     generation phase session buffer))
              (when (and
                     (proofread-languagetool--current-session-p
                      generation session)
                     (null proofread-languagetool--probe-buffer)
                     (null proofread-languagetool--probe-retry-token))
                (setq proofread-languagetool--probe-buffer buffer)
                (setq proofread-languagetool--probe-timeout-timer
                      timeout-timer)
                (setq published-p t)))
            (unless published-p
              (when (timerp timeout-timer)
                (cancel-timer timeout-timer))
              (proofread-languagetool--kill-url-buffer buffer)))
        (error
         (when (timerp timeout-timer)
           (cancel-timer timeout-timer))
         (proofread-languagetool--kill-url-buffer buffer)
         (proofread-languagetool--probe-failed
          generation phase session))))))

(defun proofread-languagetool--schedule-probe
    (generation phase session delay)
  "Schedule a probe for GENERATION, PHASE, and SESSION after DELAY."
  (when (proofread-languagetool--current-session-p
         generation session)
    (proofread-languagetool--cancel-probe-retry)
    (let* ((token (list generation phase session))
           (timer
            (run-at-time delay nil
                         #'proofread-languagetool--run-probe
                         generation phase session token)))
      (setq proofread-languagetool--probe-retry-token token)
      (setq proofread-languagetool--probe-retry-timer timer))))

(defun proofread-languagetool--begin-readiness-check (session)
  "Probe an existing server described by SESSION."
  (unless proofread-languagetool--shutting-down-p
    (let ((same-session
           (proofread-languagetool--same-session-p
            session proofread-languagetool--server-session)))
      (cl-incf proofread-languagetool--server-generation)
      (proofread-languagetool--cancel-readiness-work)
      (unless same-session
        (setq proofread-languagetool--force-start-p nil)
        (proofread-languagetool--defer-waiters
         'languagetool-session-changed
         "LanguageTool server configuration changed")
        (proofread-languagetool--stop-owned-process))
      (setq proofread-languagetool--server-session session)
      (setq proofread-languagetool--server-state 'probing)
      (condition-case err
          (proofread-languagetool--schedule-probe
           proofread-languagetool--server-generation
           'external session 0)
        (error
         (proofread-languagetool--fail-readiness
          'languagetool-unavailable
          (format "Cannot schedule LanguageTool health probe: %s"
                  (error-message-string err)))
         (signal (car err) (cdr err)))))))

(defun proofread-languagetool--ensure-server (handle)
  "Submit HANDLE when the configured LanguageTool server is ready."
  (let ((session (plist-get handle :session)))
    (cond
     (proofread-languagetool--shutting-down-p
      (proofread-languagetool--deliver-error-later
       handle 'languagetool-stopped
       "LanguageTool backend is stopping"))
     ((not (proofread-languagetool--same-session-p
            session proofread-languagetool--server-session))
      (proofread-languagetool--begin-readiness-check session)
      (push handle proofread-languagetool--server-waiters))
     ((eq proofread-languagetool--server-state 'ready)
      (proofread-languagetool--submit handle))
     ((memq proofread-languagetool--server-state
            '( probing starting))
      (push handle proofread-languagetool--server-waiters))
     (t
      (proofread-languagetool--begin-readiness-check session)
      (push handle proofread-languagetool--server-waiters)))))

(defun proofread-languagetool--check (request callback)
  "Asynchronously check REQUEST and invoke CALLBACK once.
Return a cancellable LanguageTool backend handle."
  (let ((handle
         (proofread-languagetool--new-handle request callback)))
    (if proofread-languagetool--shutting-down-p
        (proofread-languagetool--deliver-error-later
         handle 'languagetool-stopped
         "LanguageTool backend is stopping")
      (condition-case err
          (let ((buffer (plist-get request :buffer)))
            (unless (buffer-live-p buffer)
              (error "Proofread request buffer is no longer live"))
            (with-current-buffer buffer
              (let ((session
                     (proofread-languagetool--server-session-snapshot
                      buffer))
                    (request-data
                     (proofread-languagetool--request-data request)))
                (setf (plist-get handle :session) session)
                (setf (plist-get handle :request-data) request-data)
                (setf (plist-get handle :url)
                      (plist-get session :check-url))
                (proofread-languagetool--ensure-server handle))))
        (error
         (proofread-languagetool--deliver-error-later
          handle 'languagetool-configuration-error
          (error-message-string err)))))
    handle))

;;;; Commands and feature lifecycle

;;;###autoload
(defun proofread-languagetool-start-server ()
  "Reuse or asynchronously start the configured LanguageTool server."
  (interactive)
  (if proofread-languagetool--shutting-down-p
      (message "LanguageTool backend is stopping")
    (let ((session
           (proofread-languagetool--server-session-snapshot nil t)))
      (let* ((replace-owned-p
              (and
               (process-live-p proofread-languagetool--server-process)
               (not
                (proofread-languagetool--same-managed-session-p
                 proofread-languagetool--server-process-session
                 session))))
             (same-session-p
              (proofread-languagetool--same-session-p
               session proofread-languagetool--server-session))
             (same-managed-session-p
              (proofread-languagetool--same-managed-session-p
               session proofread-languagetool--server-session)))
        (when replace-owned-p
          (proofread-languagetool--stop-owned-process))
        (cond
         ((and (not replace-owned-p)
               same-session-p
               (eq proofread-languagetool--server-state 'ready)))
         ((and (not replace-owned-p)
               same-session-p
               same-managed-session-p
               (memq proofread-languagetool--server-state
                     '( probing starting)))
          (setq proofread-languagetool--force-start-p t))
         (t
          (proofread-languagetool--begin-readiness-check session)
          (setq proofread-languagetool--force-start-p t)))))
    (message "LanguageTool server readiness check started")))

(defun proofread-languagetool--teardown
    (error-symbol message)
  "Release resources and settle every live handle.
Use ERROR-SYMBOL and MESSAGE for each result."
  (let ((proofread-languagetool--shutting-down-p t))
    (cl-incf proofread-languagetool--server-generation)
    (setq proofread-languagetool--server-state 'unknown)
    (setq proofread-languagetool--server-session nil)
    (setq proofread-languagetool--force-start-p nil)
    (proofread-languagetool--cancel-readiness-work)
    (setq proofread-languagetool--server-waiters nil)
    (proofread-languagetool--settle-live-handles
     error-symbol message)
    (proofread-languagetool--stop-owned-process)))

;;;###autoload
(defun proofread-languagetool-stop-server ()
  "Stop the LanguageTool server owned by this Emacs session.
An external server reused by this backend is never stopped."
  (interactive)
  (proofread-languagetool--teardown
   'languagetool-stopped "LanguageTool server was stopped")
  (when (called-interactively-p 'interactive)
    (message "Managed LanguageTool server stopped")))

(defun proofread-languagetool--kill-emacs ()
  "Stop owned LanguageTool resources before Emacs exits."
  (proofread-languagetool-stop-server))

(defun proofread-languagetool-unload-function ()
  "Unload the LanguageTool backend and release its resources."
  (remove-hook 'kill-emacs-hook #'proofread-languagetool--kill-emacs)
  (proofread--unregister-backend 'languagetool)
  (proofread-languagetool--teardown
   'languagetool-unloaded "LanguageTool backend was unloaded")
  (proofread-languagetool--kill-url-buffer
   (get-buffer proofread-languagetool--server-buffer-name))
  nil)

;;;; Runtime setup

(progn
  (add-hook 'kill-emacs-hook
            #'proofread-languagetool--kill-emacs)
  (proofread--register-backend
   'languagetool
   :check #'proofread-languagetool--check
   :identity #'proofread-languagetool--identity
   :binding-identity #'proofread-languagetool--binding-identity
   :cancel #'proofread-languagetool--cancel))

(provide 'proofread-languagetool)
;;; proofread-languagetool.el ends here
