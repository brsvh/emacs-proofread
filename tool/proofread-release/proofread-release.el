#!/usr/bin/env -S emacs --quick --script
;;; proofread-release.el --- Prepare Proofread releases  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This internal tool validates Makefile-built Emacs package archives,
;; compares them with the cumulative release manifest, verifies forward
;; dependencies and released reverse dependents in isolation, and prepares
;; the immutable handoff consumed by the release workflow.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'package)
(require 'seq)
(require 'subr-x)

(defconst proofread-release--schema 2
  "Current release manifest schema.")

(defconst proofread-release--legacy-schema 1
  "Legacy aggregate release manifest schema.")

(defconst proofread-release--semver-regexp
  "\\(?:0\\|[1-9][0-9]*\\)\\.\\(?:0\\|[1-9][0-9]*\\)\\.\\(?:0\\|[1-9][0-9]*\\)"
  "Strict three-component semantic version regexp.")

(cl-defstruct
    (proofread-release--package
     (:constructor proofread-release--make-package))
  name version sha256 asset requires release-tag commit file)

(defun proofread-release--field (object field)
  "Return the unique FIELD from JSON OBJECT."
  (unless (listp object)
    (error "Manifest object containing %s must be an object" field))
  (let ((entries
         (seq-filter
          (lambda (entry)
            (and (consp entry) (eq (car entry) field)))
          object)))
    (unless (= (length entries) 1)
      (error "Manifest field must occur exactly once: %s" field))
    (cdar entries)))

(defun proofread-release--optional-field (object field)
  "Return FIELD from JSON OBJECT, or nil when FIELD is absent."
  (unless (listp object)
    (error "Manifest object containing %s must be an object" field))
  (let ((entries
         (seq-filter
          (lambda (entry)
            (and (consp entry) (eq (car entry) field)))
          object)))
    (when (> (length entries) 1)
      (error "Manifest field must occur at most once: %s" field))
    (cdar entries)))

(defun proofread-release--string-field (object field)
  "Return string FIELD from JSON OBJECT."
  (let ((value (proofread-release--field object field)))
    (unless (stringp value)
      (error "Manifest field %s must be a string" field))
    value))

(defun proofread-release--nullable-string-field (object field)
  "Return nullable string FIELD from JSON OBJECT."
  (let ((value (proofread-release--field object field)))
    (unless (or (stringp value) (eq value :null))
      (error "Manifest field %s must be a string or null" field))
    value))

(defun proofread-release--safe-name-p (name)
  "Return non-nil when NAME is a safe Emacs package name."
  (and (stringp name)
       (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" name)))

(defun proofread-release--safe-asset-p (name)
  "Return non-nil when NAME is a safe release asset name."
  (and (stringp name)
       (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'" name)))

(defun proofread-release--legacy-tag-p (tag)
  "Return non-nil when TAG is a legacy aggregate release tag."
  (and (stringp tag)
       (string-match-p
        (concat "\\`v" proofread-release--semver-regexp "\\'")
        tag)))

(defun proofread-release--package-tag-p (tag)
  "Return non-nil when TAG is a package release tag."
  (and (stringp tag)
       (string-match-p
        (concat
         "\\`[a-z0-9][a-z0-9-]*-v"
         proofread-release--semver-regexp
         "\\'")
        tag)))

(defun proofread-release--safe-tag-p (tag)
  "Return non-nil when TAG is a supported release tag."
  (or (proofread-release--legacy-tag-p tag)
      (proofread-release--package-tag-p tag)))

(defun proofread-release--validate-tag (tag)
  "Validate release TAG and return it."
  (unless (proofread-release--safe-tag-p tag)
    (error "Invalid release tag: %S" tag))
  tag)

(defun proofread-release--validate-commit (commit)
  "Validate release COMMIT and return it."
  (unless (and (stringp commit)
               (string-match-p "\\`[0-9a-f]\\{40\\}\\'" commit))
    (error "Invalid release commit: %S" commit))
  commit)

(defun proofread-release--version-list (version)
  "Return VERSION as an Emacs version list."
  (unless (stringp version)
    (error "Version must be a string: %S" version))
  (version-to-list version))

(defun proofread-release--tag-package-and-version (tag packages)
  "Return the package name and version selected by TAG among PACKAGES."
  (proofread-release--validate-tag tag)
  (when (proofread-release--legacy-tag-p tag)
    (error "Legacy aggregate tag is not a package release tag: %s" tag))
  (let ((matches nil))
    (dolist (package packages)
      (unless (proofread-release--safe-name-p package)
        (error "Invalid release package name: %S" package))
      (let ((prefix (concat package "-v")))
        (when (string-prefix-p prefix tag)
          (let ((version (substring tag (length prefix))))
            (when (string-match-p
                   (concat "\\`" proofread-release--semver-regexp "\\'")
                   version)
              (push (cons package version) matches))))))
    (pcase (length matches)
      (0 (error "Release tag does not select a known package: %s" tag))
      (1 (car matches))
      (_ (error "Release tag ambiguously selects a package: %s" tag)))))

(defun proofread-release--file-sha256 (file)
  "Return the SHA-256 digest of the literal bytes in FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun proofread-release--read-json (file)
  "Read and return the JSON object in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer
     :object-type 'alist
     :array-type 'array)))

(defun proofread-release--write-json (object file)
  "Write OBJECT as stable, pretty-printed JSON to FILE."
  (with-temp-buffer
    (insert (json-serialize object))
    (json-pretty-print-buffer)
    (goto-char (point-max))
    (unless (bolp)
      (insert "\n"))
    (write-region (point-min) (point-max) file nil 'silent)))

(defun proofread-release--write-text (text file)
  "Write TEXT to FILE with no status message."
  (with-temp-buffer
    (insert text)
    (write-region (point-min) (point-max) file nil 'silent)))

(defun proofread-release--array-list (value field)
  "Return JSON array VALUE as a list for manifest FIELD."
  (unless (vectorp value)
    (error "Manifest field %s must be an array" field))
  (append value nil))

(defun proofread-release--requirements-from-json (value)
  "Return normalized package requirements parsed from JSON VALUE."
  (let ((seen (make-hash-table :test #'equal)))
    (sort
     (mapcar
      (lambda (requirement)
        (let ((name (proofread-release--string-field requirement 'name))
              (version
               (proofread-release--string-field requirement 'version)))
          (unless (proofread-release--safe-name-p name)
            (error "Invalid dependency name: %S" name))
          (when (gethash name seen)
            (error "Duplicate package dependency: %s" name))
          (puthash name t seen)
          (proofread-release--version-list version)
          (cons name version)))
      (proofread-release--array-list value 'requires))
     (lambda (left right)
       (string< (car left) (car right))))))

(defun proofread-release--requirements-to-json (requirements)
  "Return JSON for normalized REQUIREMENTS."
  (vconcat
   (mapcar
    (lambda (requirement)
      `((name . ,(car requirement))
        (version . ,(cdr requirement))))
    requirements)))

(defun proofread-release--package-from-json (object &optional defaults)
  "Return a schema 2 release package parsed from JSON OBJECT.

DEFAULTS supplies fallback `release-tag' and `commit' values."
  (let* ((name (proofread-release--string-field object 'name))
         (version (proofread-release--string-field object 'version))
         (asset (proofread-release--string-field object 'asset))
         (sha256 (proofread-release--string-field object 'sha256))
         (requires
          (proofread-release--requirements-from-json
           (proofread-release--field object 'requires)))
         (release-tag
          (or (proofread-release--optional-field object 'release_tag)
              (plist-get defaults :release-tag)))
         (commit
          (or (proofread-release--optional-field object 'commit)
              (plist-get defaults :commit))))
    (unless (proofread-release--safe-name-p name)
      (error "Invalid package name in manifest: %S" name))
    (proofread-release--version-list version)
    (unless (equal asset (format "%s-%s.tar" name version))
      (error "Invalid asset for package %s: %S" name asset))
    (unless (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256)
      (error "Invalid SHA-256 for package %s" name))
    (proofread-release--validate-tag release-tag)
    (proofread-release--validate-commit commit)
    (let* ((selection
            (when (proofread-release--package-tag-p release-tag)
              (proofread-release--tag-package-and-version release-tag (list name))))
           (selected-name (car selection))
           (selected-version (cdr selection)))
      (when selection
        (unless (and (equal selected-name name)
                     (equal selected-version version))
          (error "Package release tag does not match package %s" name))))
    (proofread-release--make-package
     :name name
     :version version
     :sha256 sha256
     :asset asset
     :requires requires
     :release-tag release-tag
     :commit commit)))

(defun proofread-release--legacy-package-from-json (object release-tag commit)
  "Return an active package parsed from legacy package OBJECT."
  (let* ((name (proofread-release--string-field object 'name))
         (version (proofread-release--string-field object 'version))
         (lifecycle
          (proofread-release--string-field object 'lifecycle))
         (asset-value (proofread-release--field object 'asset))
         (sha256 (proofread-release--string-field object 'sha256))
         (requires
          (proofread-release--requirements-from-json
           (proofread-release--field object 'requires))))
    (unless (proofread-release--safe-name-p name)
      (error "Invalid package name in legacy manifest: %S" name))
    (proofread-release--version-list version)
    (unless (member lifecycle '("active" "retired"))
      (error "Invalid legacy package lifecycle for %s: %s" name lifecycle))
    (unless (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256)
      (error "Invalid SHA-256 for legacy package %s" name))
    (when (equal lifecycle "active")
      (unless (and (stringp asset-value)
                   (equal asset-value (format "%s-%s.tar" name version)))
        (error "Invalid active legacy asset for package %s" name))
      (proofread-release--make-package
       :name name
       :version version
       :sha256 sha256
       :asset asset-value
       :requires requires
       :release-tag release-tag
       :commit commit))))

(defun proofread-release--schema (manifest)
  "Return MANIFEST schema number."
  (proofread-release--field manifest 'schema))

(defun proofread-release--packages-from-manifest (manifest)
  "Return the sorted active package list represented by MANIFEST."
  (let ((schema (proofread-release--schema manifest))
        (seen (make-hash-table :test #'equal))
        packages)
    (pcase schema
      (2
       (dolist (object
                (proofread-release--array-list
                 (proofread-release--field manifest 'packages)
                 'packages))
         (let* ((package (proofread-release--package-from-json object))
                (name (proofread-release--package-name package)))
           (when (gethash name seen)
             (error "Duplicate package in manifest: %s" name))
           (puthash name t seen)
           (push package packages))))
      (1
       (let ((tag (proofread-release--field manifest 'tag))
             (commit (proofread-release--field manifest 'commit)))
         (if (eq tag :null)
             (unless (eq commit :null)
               (error "Invalid legacy bootstrap release manifest"))
           (proofread-release--validate-tag tag)
           (proofread-release--validate-commit commit)
           (dolist (object
                    (proofread-release--array-list
                     (proofread-release--field manifest 'packages)
                     'packages))
             (let ((package
                    (proofread-release--legacy-package-from-json
                     object tag commit)))
               (when package
                 (let ((name (proofread-release--package-name package)))
                   (when (gethash name seen)
                     (error "Duplicate package in legacy manifest: %s" name))
                   (puthash name t seen)
                   (push package packages))))))))
      (_ (error "Unsupported release manifest schema: %S" schema)))
    (sort packages
          (lambda (left right)
            (string< (proofread-release--package-name left)
                     (proofread-release--package-name right))))))

(defun proofread-release--package-table (packages)
  "Return a name-indexed hash table containing PACKAGES."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (package packages)
      (let ((name (proofread-release--package-name package)))
        (when (gethash name table)
          (error "Duplicate package: %s" name))
        (puthash name package table)))
    table))

(defun proofread-release--manifest-package (manifest name)
  "Return package NAME from MANIFEST, or nil."
  (gethash name
           (proofread-release--package-table
            (proofread-release--packages-from-manifest manifest))))

(defun proofread-release--validate-schema-2-manifest (manifest)
  "Validate schema 2 MANIFEST and return it."
  (let* ((tag (proofread-release--nullable-string-field manifest 'tag))
         (commit (proofread-release--nullable-string-field manifest 'commit))
         (previous
          (proofread-release--nullable-string-field manifest 'previous))
         (released-package
          (proofread-release--nullable-string-field
           manifest 'released_package))
         (packages (proofread-release--packages-from-manifest manifest)))
    (if (eq tag :null)
        (unless (and (eq commit :null)
                     (eq previous :null)
                     (eq released-package :null)
                     (null packages))
          (error "Invalid bootstrap release manifest"))
      (proofread-release--validate-tag tag)
      (proofread-release--validate-commit commit)
      (unless (or (eq previous :null)
                  (proofread-release--safe-tag-p previous))
        (error "Invalid previous release tag: %S" previous))
      (unless (proofread-release--safe-name-p released-package)
        (error "Invalid released package: %S" released-package))
      (let* ((table (proofread-release--package-table packages))
             (package (gethash released-package table))
             (selection
              (proofread-release--tag-package-and-version
               tag (mapcar #'proofread-release--package-name packages))))
        (unless package
          (error "Released package is absent from manifest: %s"
                 released-package))
        (unless (and (equal (car selection) released-package)
                     (equal (cdr selection)
                            (proofread-release--package-version package)))
          (error "Manifest tag does not match released package"))
        (unless (and (equal (proofread-release--package-release-tag package)
                            tag)
                     (equal (proofread-release--package-commit package)
                            commit))
          (error "Released package record does not match manifest tag"))))
    manifest))

(defun proofread-release--validate-legacy-manifest (manifest)
  "Validate legacy schema 1 MANIFEST and return it."
  (let ((tag (proofread-release--field manifest 'tag))
        (commit (proofread-release--field manifest 'commit))
        (previous (proofread-release--field manifest 'previous)))
    (if (eq tag :null)
        (unless (and (eq commit :null)
                     (eq previous :null)
                     (null (proofread-release--array-list
                            (proofread-release--field manifest 'packages)
                            'packages)))
          (error "Invalid legacy bootstrap release manifest"))
      (proofread-release--validate-tag tag)
      (proofread-release--validate-commit commit)
      (unless (or (eq previous :null)
                  (proofread-release--safe-tag-p previous))
        (error "Invalid legacy previous release tag: %S" previous)))
    (proofread-release--packages-from-manifest manifest)
    manifest))

(defun proofread-release--validate-manifest (manifest)
  "Validate MANIFEST and return it."
  (pcase (proofread-release--schema manifest)
    (2 (proofread-release--validate-schema-2-manifest manifest))
    (1 (proofread-release--validate-legacy-manifest manifest))
    (_ (error "Unsupported release manifest schema"))))

(defun proofread-release--archive-description (archive)
  "Return the package description stored in ARCHIVE."
  (unless (and (file-regular-p archive)
               (not (file-symlink-p archive)))
    (error "Release archive is not a regular file: %s" archive))
  (let ((buffer (find-file-noselect archive t)))
    (unwind-protect
        (with-current-buffer buffer
          (package-tar-file-info))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun proofread-release--requirements-from-description (description)
  "Return normalized requirements from package DESCRIPTION."
  (sort
   (mapcar
    (lambda (requirement)
      (cons (symbol-name (car requirement))
            (package-version-join (cadr requirement))))
    (package-desc-reqs description))
   (lambda (left right)
     (string< (car left) (car right)))))

(defun proofread-release--package-from-archive (archive)
  "Return release metadata read from package ARCHIVE."
  (let* ((absolute (expand-file-name archive))
         (description (proofread-release--archive-description absolute))
         (name (symbol-name (package-desc-name description)))
         (version
          (package-version-join
           (package-desc-version description)))
         (asset (file-name-nondirectory absolute)))
    (unless (proofread-release--safe-name-p name)
      (error "Invalid package name in archive: %S" name))
    (unless (equal asset (format "%s-%s.tar" name version))
      (error "Archive name does not match package metadata: %s" asset))
    (proofread-release--make-package
     :name name
     :version version
     :sha256 (proofread-release--file-sha256 absolute)
     :asset asset
     :requires
     (proofread-release--requirements-from-description description)
     :file absolute)))

(defun proofread-release--read-archives (archives)
  "Return sorted package metadata read from ARCHIVES."
  (let ((seen (make-hash-table :test #'equal))
        packages)
    (dolist (archive archives)
      (let* ((package (proofread-release--package-from-archive archive))
             (name (proofread-release--package-name package)))
        (when (gethash name seen)
          (error "Duplicate release package archive: %s" name))
        (puthash name t seen)
        (push package packages)))
    (sort packages
          (lambda (left right)
            (string< (proofread-release--package-name left)
                     (proofread-release--package-name right))))))

(defun proofread-release--version-comparison (left right)
  "Compare version strings LEFT and RIGHT."
  (let ((left-list (proofread-release--version-list left))
        (right-list (proofread-release--version-list right)))
    (cond
     ((version-list-< left-list right-list) -1)
     ((version-list-< right-list left-list) 1)
     (t 0))))

(defun proofread-release--tag-canonicalizes-package-p (tag old-package)
  "Return non-nil when TAG canonicalizes legacy OLD-PACKAGE metadata."
  (and old-package
       (proofread-release--legacy-tag-p
        (proofread-release--package-release-tag old-package))
       (let ((selection
              (proofread-release--tag-package-and-version
               tag (list (proofread-release--package-name old-package)))))
         (and (equal (car selection)
                     (proofread-release--package-name old-package))
              (equal (cdr selection)
                     (proofread-release--package-version old-package))))))

(defun proofread-release--with-release-identity (package tag commit)
  "Return a copy of PACKAGE tagged with release TAG and COMMIT."
  (proofread-release--make-package
   :name (proofread-release--package-name package)
   :version (proofread-release--package-version package)
   :sha256 (proofread-release--package-sha256 package)
   :asset (proofread-release--package-asset package)
   :requires (proofread-release--package-requires package)
   :release-tag tag
   :commit commit
   :file (proofread-release--package-file package)))

(defun proofread-release--classify-package-release (package old-package tag)
  "Validate PACKAGE against OLD-PACKAGE for TAG and return change kind."
  (cond
   ((not old-package) "new")
   ((proofread-release--tag-canonicalizes-package-p tag old-package)
    (unless (and (equal (proofread-release--package-version package)
                        (proofread-release--package-version old-package))
                 (equal (proofread-release--package-sha256 package)
                        (proofread-release--package-sha256 old-package))
                 (equal (proofread-release--package-requires package)
                        (proofread-release--package-requires old-package)))
      (error "Canonical package tag differs from legacy package: %s"
             (proofread-release--package-name package)))
    "canonicalized")
   (t
    (pcase (proofread-release--version-comparison
            (proofread-release--package-version package)
            (proofread-release--package-version old-package))
      (-1
       (error "Package version moved backwards: %s"
              (proofread-release--package-name package)))
      (0
       (unless (equal (proofread-release--package-version package)
                      (proofread-release--package-version old-package))
         (error "Package version did not increase: %s"
                (proofread-release--package-name package)))
       (if (and (equal (proofread-release--package-sha256 package)
                       (proofread-release--package-sha256 old-package))
                (equal (proofread-release--package-requires package)
                       (proofread-release--package-requires old-package)))
           "unchanged"
         (error "Package changed without a version increase: %s"
                (proofread-release--package-name package))))
      (1 "updated")))))

(defun proofread-release--package-to-json (package)
  "Return the JSON representation of PACKAGE."
  `((name . ,(proofread-release--package-name package))
    (version . ,(proofread-release--package-version package))
    (release_tag . ,(proofread-release--package-release-tag package))
    (commit . ,(proofread-release--package-commit package))
    (asset . ,(proofread-release--package-asset package))
    (sha256 . ,(proofread-release--package-sha256 package))
    (requires
     . ,(proofread-release--requirements-to-json
         (proofread-release--package-requires package)))))

(defun proofread-release--satisfies-requirement-p (package requirement)
  "Return non-nil if PACKAGE satisfies REQUIREMENT."
  (not
   (version-list-<
    (proofread-release--version-list
     (proofread-release--package-version package))
    (proofread-release--version-list (cdr requirement)))))

(defun proofread-release--collect-dependencies (package packages)
  "Return internal dependencies of PACKAGE from PACKAGES in install order."
  (let ((table (proofread-release--package-table packages))
        (visiting (make-hash-table :test #'equal))
        (visited (make-hash-table :test #'equal))
        dependencies)
    (cl-labels
        ((visit
           (current)
           (dolist (requirement
                    (proofread-release--package-requires current))
             (let* ((name (car requirement))
                    (dependency (gethash name table)))
               (when dependency
                 (when (equal name (proofread-release--package-name package))
                   (error "Project package dependency cycle detected"))
                 (unless (proofread-release--satisfies-requirement-p
                          dependency requirement)
                   (error "%s requires %s %s, but the ledger contains %s"
                          (proofread-release--package-name current)
                          name
                          (cdr requirement)
                          (proofread-release--package-version dependency)))
                 (when (gethash name visiting)
                   (error "Project package dependency cycle detected"))
                 (unless (gethash name visited)
                   (puthash name t visiting)
                   (visit dependency)
                   (remhash name visiting)
                   (puthash name t visited)
                   (push dependency dependencies)))))))
      (visit package))
    (nreverse dependencies)))

(defun proofread-release--dependency-order (packages)
  "Return PACKAGES in internal dependency order."
  (let ((table (proofread-release--package-table packages))
        (pending
         (sort
          (copy-sequence packages)
          (lambda (left right)
            (string< (proofread-release--package-name left)
                     (proofread-release--package-name right)))))
        installed
        order)
    (while pending
      (let ((ready
             (seq-find
              (lambda (package)
                (seq-every-p
                 (lambda (requirement)
                   (let ((name (car requirement)))
                     (or (not (gethash name table))
                         (member name installed))))
                 (proofread-release--package-requires package)))
              pending)))
        (unless ready
          (error "Project package dependency cycle detected"))
        (setq pending (delq ready pending))
        (push (proofread-release--package-name ready) installed)
        (push ready order)))
    (nreverse order)))

(defun proofread-release--verification-packages (candidate packages)
  "Return packages needed to verify CANDIDATE against PACKAGES.
The result includes CANDIDATE, its internal dependencies, and every
active reverse dependent whose transitive internal dependency closure
contains CANDIDATE.  Include each reverse dependent's closure and
return the union in deterministic installation order."
  (let* ((candidate-name
          (proofread-release--package-name candidate))
         (graph
          (cons
           candidate
           (seq-remove
            (lambda (package)
              (equal (proofread-release--package-name package)
                     candidate-name))
            packages)))
         (selected (make-hash-table :test #'equal)))
    (cl-labels
        ((select
           (package)
           (puthash (proofread-release--package-name package)
                    package selected)))
      (select candidate)
      (dolist (dependency
               (proofread-release--collect-dependencies
                candidate graph))
        (select dependency))
      (dolist (package graph)
        (unless (equal (proofread-release--package-name package)
                       candidate-name)
          (let ((dependencies
                 (proofread-release--collect-dependencies
                  package graph)))
            (when (seq-some
                   (lambda (dependency)
                     (equal
                      (proofread-release--package-name dependency)
                      candidate-name))
                   dependencies)
              (select package)
              (dolist (dependency dependencies)
                (select dependency))))))
      (proofread-release--dependency-order
       (hash-table-values selected)))))

(defun proofread-release--verification-companions (candidate packages)
  "Return non-candidate packages needed to verify CANDIDATE.
PACKAGES is the active project package graph."
  (let ((candidate-name
         (proofread-release--package-name candidate)))
    (seq-remove
     (lambda (package)
       (equal (proofread-release--package-name package)
              candidate-name))
     (proofread-release--verification-packages candidate packages))))

(defun proofread-release--same-package-p (left right)
  "Return non-nil if LEFT and RIGHT describe the same package archive."
  (and (equal (proofread-release--package-name left)
              (proofread-release--package-name right))
       (equal (proofread-release--package-version left)
              (proofread-release--package-version right))
       (equal (proofread-release--package-sha256 left)
              (proofread-release--package-sha256 right))
       (equal (proofread-release--package-asset left)
              (proofread-release--package-asset right))
       (equal (proofread-release--package-requires left)
              (proofread-release--package-requires right))))

(defun proofread-release--verify-package-archives (packages archives)
  "Verify that PACKAGES are provided exactly by ARCHIVES."
  (let ((provided (proofread-release--package-table
                   (proofread-release--read-archives archives)))
        (expected (proofread-release--package-table packages)))
    (dolist (package packages)
      (let* ((name (proofread-release--package-name package))
             (archive (gethash name provided)))
        (unless archive
          (error "Missing verification archive: %s" name))
        (unless (proofread-release--same-package-p archive package)
          (error "Verification archive differs from manifest: %s" name))))
    (maphash
     (lambda (name _package)
       (unless (gethash name expected)
         (error "Unexpected verification archive: %s" name)))
     provided)))

(defun proofread-release--new-manifest (tag commit previous-manifest package)
  "Return a new manifest for TAG, COMMIT, and released PACKAGE."
  (let* ((previous-tag (proofread-release--field previous-manifest 'tag))
         (previous-packages
          (proofread-release--packages-from-manifest previous-manifest))
         (previous-table (proofread-release--package-table previous-packages))
         (name (proofread-release--package-name package))
         (version (proofread-release--package-version package))
         (selection
          (proofread-release--tag-package-and-version tag (list name)))
         (old-package (gethash name previous-table))
         (change
          (proofread-release--classify-package-release
           package old-package tag))
         (released
          (proofread-release--with-release-identity package tag commit))
         packages)
    (unless (equal (cdr selection) version)
      (error "Release tag version does not match archive version"))
    (when (equal change "unchanged")
      (error "The package release contains no effective change: %s" name))
    (maphash
     (lambda (package-name old)
       (push (if (equal package-name name) released old) packages))
     previous-table)
    (unless old-package
      (push released packages))
    (setq packages
          (sort packages
                (lambda (left right)
                  (string< (proofread-release--package-name left)
                           (proofread-release--package-name right)))))
    `((schema . ,proofread-release--schema)
      (tag . ,tag)
      (commit . ,commit)
      (previous . ,previous-tag)
      (released_package . ,name)
      (packages
       . ,(vconcat
           (mapcar #'proofread-release--package-to-json packages))))))

(defun proofread-release--replay-manifest-p (manifest tag commit package)
  "Validate a replay of MANIFEST for TAG, COMMIT, and PACKAGE."
  (proofread-release--validate-schema-2-manifest manifest)
  (unless (equal (proofread-release--field manifest 'tag) tag)
    (error "Release replay tag mismatch"))
  (unless (equal (proofread-release--field manifest 'commit) commit)
    (error "Release tag already records a different commit"))
  (let* ((released-name
          (proofread-release--field manifest 'released_package))
         (record
          (proofread-release--manifest-package manifest released-name)))
    (unless (and record
                 (equal released-name
                        (proofread-release--package-name package))
                 (proofread-release--same-package-p record package))
      (error "Release replay differs for package %s"
             (proofread-release--package-name package))))
  t)

(defun proofread-release--release-notes (manifest)
  "Return Markdown release notes for MANIFEST."
  (let* ((tag (proofread-release--string-field manifest 'tag))
         (commit (proofread-release--string-field manifest 'commit))
         (released-name
          (proofread-release--string-field manifest 'released_package))
         (package (proofread-release--manifest-package manifest released-name))
         (dependencies
          (proofread-release--collect-dependencies
           package (proofread-release--packages-from-manifest manifest))))
    (concat
     (format "# Release %s\n\n" tag)
     (format "Repository snapshot `%s` at `%s`.\n\n" tag commit)
     (format "This release publishes `%s` version `%s`.\n\n"
             released-name
             (proofread-release--package-version package))
     "| Package | Version | Release tag | Asset |\n"
     "| --- | --- | --- | --- |\n"
     (mapconcat
      (lambda (record)
        (format "| `%s` | `%s` | `%s` | `%s` |"
                (proofread-release--package-name record)
                (proofread-release--package-version record)
                (proofread-release--package-release-tag record)
                (proofread-release--package-asset record)))
      (cons package dependencies)
      "\n")
     "\n")))

(defun proofread-release--plan-json (manifest mode dependencies)
  "Return the workflow plan for MANIFEST using MODE and DEPENDENCIES."
  (let* ((released-name
          (proofread-release--string-field manifest 'released_package))
         (package (proofread-release--manifest-package manifest released-name)))
    `((schema . ,proofread-release--schema)
      (mode . ,mode)
      (tag . ,(proofread-release--field manifest 'tag))
      (commit . ,(proofread-release--field manifest 'commit))
      (previous . ,(proofread-release--field manifest 'previous))
      (released_package . ,released-name)
      (asset . ,(proofread-release--package-asset package))
      (dependencies
       . ,(vconcat
           (mapcar #'proofread-release--package-to-json dependencies))))))

(defun proofread-release--write-expected-assets (assets-dir output)
  "Write the expected ordinary asset names from ASSETS-DIR to OUTPUT."
  (let ((names
         (sort
          (mapcar #'file-name-nondirectory
                  (directory-files assets-dir nil "\\`[^.]"))
          #'string<)))
    (dolist (name names)
      (unless (proofread-release--safe-asset-p name)
        (error "Unsafe release asset name: %s" name)))
    (proofread-release--write-text
     (concat (string-join names "\n") "\n")
     output)))

(defun proofread-release--validate-package-inputs (package version tag archive)
  "Validate PACKAGE, VERSION, TAG, and ARCHIVE agree."
  (let* ((selection
          (proofread-release--tag-package-and-version tag (list package)))
         (archive-package (proofread-release--package-from-archive archive)))
    (unless (proofread-release--safe-name-p package)
      (error "Invalid release package: %S" package))
    (proofread-release--version-list version)
    (unless (and (equal (car selection) package)
                 (equal (cdr selection) version))
      (error "Release tag does not match requested package/version"))
    (unless (and (equal (proofread-release--package-name archive-package)
                        package)
                 (equal (proofread-release--package-version archive-package)
                        version))
      (error "Release archive metadata does not match requested package"))
    archive-package))

(defun proofread-release--required-dependencies (previous-manifest package)
  "Return dependency packages required by PACKAGE from PREVIOUS-MANIFEST."
  (let* ((name (proofread-release--package-name package))
         (ledger-packages
          (seq-remove
           (lambda (record)
             (equal (proofread-release--package-name record) name))
           (proofread-release--packages-from-manifest previous-manifest))))
    (proofread-release--collect-dependencies
     package
     (cons package ledger-packages))))

(defun proofread-release-required-dependencies
    (package version tag previous-file archive &optional output-file)
  "Write required internal dependencies for PACKAGE VERSION TAG.

PREVIOUS-FILE supplies the cumulative ledger and ARCHIVE supplies the
candidate package archive.  When OUTPUT-FILE is nil, write JSON to stdout."
  (let* ((previous
          (proofread-release--validate-manifest
           (proofread-release--read-json previous-file)))
         (archive-package
          (proofread-release--validate-package-inputs
           package version tag archive))
         (dependencies
          (proofread-release--required-dependencies previous archive-package))
         (json (vconcat
                (mapcar #'proofread-release--package-to-json dependencies))))
    (if output-file
        (proofread-release--write-json json output-file)
      (princ (json-serialize json))
      (princ "\n"))
    dependencies))

(defun proofread-release-verification-packages
    (package version tag previous-file archive &optional output-file)
  "Write packages needed to verify PACKAGE VERSION at TAG.

PREVIOUS-FILE supplies the cumulative ledger and ARCHIVE supplies the
candidate package archive.  The output contains every non-candidate archive
required for forward and reverse-dependency installation verification.
When OUTPUT-FILE is nil, write JSON to stdout."
  (let* ((previous
          (proofread-release--validate-manifest
           (proofread-release--read-json previous-file)))
         (archive-package
          (proofread-release--validate-package-inputs
           package version tag archive))
         (verification-packages
          (proofread-release--verification-companions
           archive-package
           (proofread-release--packages-from-manifest previous)))
         (json
          (vconcat
           (mapcar
            #'proofread-release--package-to-json
            verification-packages))))
    (if output-file
        (proofread-release--write-json json output-file)
      (princ (json-serialize json))
      (princ "\n"))
    verification-packages))

(defun proofread-release-prepare-package
    (package version tag commit previous-file output archive
             verification-archives)
  "Prepare release handoff for PACKAGE VERSION at TAG and COMMIT.

PREVIOUS-FILE supplies the previous ledger, OUTPUT receives the handoff,
ARCHIVE is the package being released, and VERIFICATION-ARCHIVES are the exact
non-candidate archive set needed for forward and reverse verification."
  (proofread-release--validate-commit commit)
  (let* ((previous
          (proofread-release--validate-manifest
           (proofread-release--read-json previous-file)))
         (archive-package
          (proofread-release--validate-package-inputs
           package version tag archive))
         (previous-tag (proofread-release--field previous 'tag))
         (mode
          (if (and (equal (proofread-release--schema previous)
                          proofread-release--schema)
                   (equal previous-tag tag))
              "replay"
            "new"))
         (manifest
          (if (equal mode "replay")
              (progn
                (proofread-release--replay-manifest-p
                 previous tag commit archive-package)
                previous)
            (proofread-release--new-manifest
             tag commit previous archive-package)))
         (released
          (proofread-release--manifest-package manifest package))
         (dependencies
          (proofread-release--collect-dependencies
           released (proofread-release--packages-from-manifest manifest)))
         (verification-companions
          (proofread-release--verification-companions
           released (proofread-release--packages-from-manifest manifest))))
    (proofread-release--verify-package-archives
     verification-companions verification-archives)
    (when (file-exists-p output)
      (error "Release output already exists: %s" output))
    (let ((assets-dir (expand-file-name "assets" output)))
      (make-directory assets-dir t)
      (copy-file archive
                 (expand-file-name
                  (file-name-nondirectory archive)
                  assets-dir))
      (proofread-release--write-json
       manifest
       (expand-file-name "manifest.json" assets-dir))
      (proofread-release--write-expected-assets
       assets-dir
       (expand-file-name "expected-assets.txt" output))
      (proofread-release--write-json
       (proofread-release--plan-json manifest mode dependencies)
       (expand-file-name "plan.json" output))
      (copy-file previous-file
                 (expand-file-name "previous-manifest.json" output))
      (proofread-release--write-text
       (proofread-release--release-notes manifest)
       (expand-file-name "release-notes.md" output)))
    manifest))

(defun proofread-release-bootstrap (output)
  "Write an empty release manifest to OUTPUT."
  (when (file-exists-p output)
    (error "Bootstrap manifest already exists: %s" output))
  (proofread-release--write-json
   `((schema . ,proofread-release--schema)
     (tag . :null)
     (commit . :null)
     (previous . :null)
     (released_package . :null)
     (packages . []))
   output))

(defun proofread-release--archives-by-name (archives)
  "Return a package-name table for ARCHIVES."
  (proofread-release--package-table
   (proofread-release--read-archives archives)))

(defun proofread-release--archive-for-package (package archives)
  "Return the archive metadata for PACKAGE from ARCHIVES."
  (or (gethash (proofread-release--package-name package) archives)
      (error "Missing archive for package: %s"
             (proofread-release--package-name package))))

(defun proofread-release-verify-install (manifest-file archives)
  "Install and load the release verification set from MANIFEST-FILE.

ARCHIVES must contain exactly the candidate archive and the released archives
selected for its forward and reverse-dependency verification."
  (let* ((manifest
          (proofread-release--validate-schema-2-manifest
           (proofread-release--read-json manifest-file)))
         (released-name
          (proofread-release--string-field manifest 'released_package))
         (packages (proofread-release--packages-from-manifest manifest))
         (released
          (or (proofread-release--manifest-package manifest released-name)
              (error "Released package missing from manifest: %s"
                     released-name)))
         (install-order
          (proofread-release--verification-packages released packages))
         (provided (proofread-release--archives-by-name archives))
         (expected (proofread-release--package-table install-order)))
    (maphash
     (lambda (name _package)
       (unless (gethash name expected)
         (error "Unexpected archive for package: %s" name)))
     provided)
    (dolist (package install-order)
      (let ((archive (proofread-release--archive-for-package package provided)))
        (unless (proofread-release--same-package-p archive package)
          (error "Archive metadata differs from manifest: %s"
                 (proofread-release--package-asset package)))))
    (let ((package-dir (make-temp-file "proofread-release-packages-" t))
          (init-dir (make-temp-file "proofread-release-init-" t))
          (old-features features)
          (old-load-path load-path)
          (old-package-alist package-alist)
          (old-package-activated-list package-activated-list)
          (old-package-selected-packages package-selected-packages)
          (old-package--initialized
           (and (boundp 'package--initialized)
                package--initialized)))
      (unwind-protect
          (let ((package-user-dir package-dir)
                (package-archives nil)
                (package-archive-contents nil)
                (package-check-signature nil)
                (package-enable-at-startup nil)
                (package-native-compile nil)
                (package-quickstart nil)
                (user-emacs-directory
                 (file-name-as-directory init-dir)))
            (package-initialize)
            (dolist (package install-order)
              (let ((name (proofread-release--package-name package)))
                (when (or (featurep (intern name))
                          (locate-library name))
                  (error "Project package is already available: %s" name))))
            (dolist (package install-order)
              (let* ((name (proofread-release--package-name package))
                     (archive
                      (proofread-release--archive-for-package
                       package provided))
                     (version
                      (proofread-release--package-version package)))
                (package-install-file
                 (proofread-release--package-file archive))
                (unless (package-installed-p
                         (intern name)
                         (proofread-release--version-list version))
                  (error "Package was not installed: %s" name))
                (let ((description
                       (car (alist-get (intern name) package-alist))))
                  (unless (and description
                               (equal (package-desc-version description)
                                      (proofread-release--version-list version)))
                    (error "Package installed at an unexpected version: %s"
                           name)))
                (condition-case condition
                    (require (intern name))
                  (error
                   (error
                    "Could not load verification package %s: %s"
                    name
                    (error-message-string condition))))
                (let ((library (locate-library name)))
                  (unless (and library
                               (file-in-directory-p library package-dir))
                    (error "Package did not load from the isolated directory: %s"
                           name))))))
        (setq features old-features)
        (setq load-path old-load-path)
        (setq package-alist old-package-alist)
        (setq package-activated-list old-package-activated-list)
        (setq package-selected-packages old-package-selected-packages)
        (when (boundp 'package--initialized)
          (setq package--initialized old-package--initialized))
        (delete-directory package-dir t)
        (delete-directory init-dir t))))
  t)

(defun proofread-release-check-package-version
    (manifest-file package version)
  "Check PACKAGE VERSION against MANIFEST-FILE."
  (let* ((manifest
          (proofread-release--validate-schema-2-manifest
           (proofread-release--read-json manifest-file)))
         (released-name
          (proofread-release--string-field manifest 'released_package))
         (record (proofread-release--manifest-package manifest package)))
    (unless (equal released-name package)
      (error "Manifest released package mismatch: %s != %s"
             released-name package))
    (unless record
      (error "Package is missing from manifest: %s" package))
    (unless (equal (proofread-release--package-version record) version)
      (error "Package version mismatch for %s: %s != %s"
             package
             version
             (proofread-release--package-version record))))
  t)

(defun proofread-release-main ()
  "Run the release tool command in `command-line-args-left'."
  (when (equal (car command-line-args-left) "--")
    (pop command-line-args-left))
  (let ((command (pop command-line-args-left)))
    (pcase command
      ("bootstrap"
       (unless (= (length command-line-args-left) 1)
         (error "Usage: bootstrap OUTPUT"))
       (proofread-release-bootstrap (pop command-line-args-left)))
      ("required-dependencies"
       (unless (member (length command-line-args-left) '(5 6))
         (error
          (concat
           "Usage: required-dependencies PACKAGE VERSION TAG PREVIOUS "
           "ARCHIVE [OUTPUT]")))
       (let ((package (pop command-line-args-left))
             (version (pop command-line-args-left))
             (tag (pop command-line-args-left))
             (previous (pop command-line-args-left))
             (archive (pop command-line-args-left))
             (output (pop command-line-args-left)))
         (proofread-release-required-dependencies
          package version tag previous archive output)))
      ("verification-packages"
       (unless (member (length command-line-args-left) '(5 6))
         (error
          (concat
           "Usage: verification-packages PACKAGE VERSION TAG PREVIOUS "
           "ARCHIVE [OUTPUT]")))
       (let ((package (pop command-line-args-left))
             (version (pop command-line-args-left))
             (tag (pop command-line-args-left))
             (previous (pop command-line-args-left))
             (archive (pop command-line-args-left))
             (output (pop command-line-args-left)))
         (proofread-release-verification-packages
          package version tag previous archive output)))
      ("prepare-package"
       (when (< (length command-line-args-left) 7)
         (error
          (concat
           "Usage: prepare-package PACKAGE VERSION TAG COMMIT PREVIOUS "
           "OUTPUT ARCHIVE [VERIFICATION-ARCHIVE...]")))
       (let ((package (pop command-line-args-left))
             (version (pop command-line-args-left))
             (tag (pop command-line-args-left))
             (commit (pop command-line-args-left))
             (previous (pop command-line-args-left))
             (output (pop command-line-args-left))
             (archive (pop command-line-args-left)))
         (proofread-release-prepare-package
          package version tag commit previous output archive
          command-line-args-left)
         (setq command-line-args-left nil)))
      ("verify-install"
       (when (< (length command-line-args-left) 2)
         (error "Usage: verify-install MANIFEST ARCHIVE..."))
       (let ((manifest (pop command-line-args-left)))
         (proofread-release-verify-install
          manifest command-line-args-left)
         (setq command-line-args-left nil)))
      ("validate"
       (unless (= (length command-line-args-left) 1)
         (error "Usage: validate MANIFEST"))
       (proofread-release--validate-manifest
        (proofread-release--read-json
         (pop command-line-args-left))))
      ("check-package-version"
       (unless (= (length command-line-args-left) 3)
         (error "Usage: check-package-version MANIFEST PACKAGE VERSION"))
       (proofread-release-check-package-version
        (pop command-line-args-left)
        (pop command-line-args-left)
        (pop command-line-args-left)))
      (_
       (error "Unknown release command: %S" command)))))

(defun proofread-release--script-invocation-p ()
  "Return non-nil when this file is the `--script' entry point."
  (let ((script (cadr (member "-scriptload" command-line-args))))
    (and load-file-name
         script
         (file-equal-p load-file-name script))))

(when (proofread-release--script-invocation-p)
  (proofread-release-main))

(provide 'proofread-release)
;;; proofread-release.el ends here
