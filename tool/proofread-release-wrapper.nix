{
  coreutils,
  emacs,
  writeTextFile,
  ...
}:
let
  script = ''
    #!${coreutils}/bin/env -S ${emacs}/bin/emacs --quick --script
    ;;; proofread-release.el --- Prepare Proofread releases  -*- lexical-binding: t; -*-

    ;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

    ;; This file is not part of GNU Emacs.

    ;;; Commentary:

    ;; This internal tool validates Makefile-built Emacs package archives,
    ;; compares them with the cumulative release manifest, verifies package
    ;; dependencies and installation, and prepares the immutable handoff consumed
    ;; by the release workflow.

    ;;; Code:

    (require 'cl-lib)
    (require 'json)
    (require 'package)
    (require 'seq)
    (require 'subr-x)

    (defconst proofread-release--schema 1
      "Current release manifest schema.")

    (cl-defstruct
        (proofread-release--package
         (:constructor proofread-release--make-package))
      name version sha256 asset requires lifecycle change)

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

    (defun proofread-release--string-field (object field)
      "Return string FIELD from JSON OBJECT."
      (let ((value (proofread-release--field object field)))
        (unless (stringp value)
          (error "Manifest field %s must be a string" field))
        value))

    (defun proofread-release--safe-name-p (name)
      "Return non-nil when NAME is a safe Emacs package name."
      (and (stringp name)
           (string-match-p
            "\\`[a-z0-9][a-z0-9-]*\\'"
            name)))

    (defun proofread-release--valid-tag-p (tag)
      "Return non-nil when TAG is a supported snapshot tag."
      (and (stringp tag)
           (string-match-p
            "\\`v\\(?:0\\|[1-9][0-9]*\\)\\.\\(?:0\\|[1-9][0-9]*\\)\\.\\(?:0\\|[1-9][0-9]*\\)\\'"
            tag)))

    (defun proofread-release--validate-commit (commit)
      "Validate release COMMIT and return it."
      (unless (and (stringp commit)
                   (string-match-p "\\`[0-9a-f]\\{40\\}\\'" commit))
        (error "Invalid release commit: %S" commit))
      commit)

    (defun proofread-release--tag-version (tag)
      "Return the Emacs version list represented by snapshot TAG."
      (unless (proofread-release--valid-tag-p tag)
        (error "Invalid release tag: %S" tag))
      (version-to-list (substring tag 1)))

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
              (ignore (version-to-list version))
              (cons name version)))
          (proofread-release--array-list value 'requires))
         (lambda (left right)
           (string< (car left) (car right))))))

    (defun proofread-release--package-from-json (object)
      "Return a release package parsed from JSON OBJECT."
      (let* ((name (proofread-release--string-field object 'name))
             (version (proofread-release--string-field object 'version))
             (lifecycle
              (proofread-release--string-field object 'lifecycle))
             (change (proofread-release--string-field object 'change))
             (asset-value (proofread-release--field object 'asset))
             (sha256 (proofread-release--string-field object 'sha256))
             (requires
              (proofread-release--requirements-from-json
               (proofread-release--field object 'requires))))
        (unless (proofread-release--safe-name-p name)
          (error "Invalid package name in manifest: %S" name))
        (ignore (version-to-list version))
        (unless (member lifecycle '("active" "retired"))
          (error "Invalid package lifecycle for %s: %s" name lifecycle))
        (unless (member change '("new" "updated" "unchanged" "retired"))
          (error "Invalid package change for %s: %s" name change))
        (unless (if (equal lifecycle "active")
                    (member change '("new" "updated" "unchanged"))
                  (member change '("retired" "unchanged")))
          (error "Invalid lifecycle/change combination for %s: %s/%s"
                 name lifecycle change))
        (unless (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256)
          (error "Invalid SHA-256 for package %s" name))
        (pcase lifecycle
          ("active"
           (unless (and (stringp asset-value)
                        (equal asset-value
                               (format "%s-%s.tar" name version)))
             (error "Invalid active asset for package %s" name)))
          ("retired"
           (unless (eq asset-value :null)
             (error "Retired package %s must not have an asset" name))))
        (proofread-release--make-package
         :name name
         :version version
         :sha256 sha256
         :asset (unless (eq asset-value :null) asset-value)
         :requires requires
         :lifecycle lifecycle
         :change change)))

    (defun proofread-release--packages-from-manifest (manifest)
      "Return the sorted package list represented by MANIFEST."
      (let ((seen (make-hash-table :test #'equal))
            packages)
        (dolist (object
                 (proofread-release--array-list
                  (proofread-release--field manifest 'packages)
                  'packages))
          (let* ((package (proofread-release--package-from-json object))
                 (name (proofread-release--package-name package)))
            (when (gethash name seen)
              (error "Duplicate package in manifest: %s" name))
            (puthash name t seen)
            (push package packages)))
        (sort packages
              (lambda (left right)
                (string< (proofread-release--package-name left)
                         (proofread-release--package-name right))))))

    (defun proofread-release--validate-manifest (manifest)
      "Validate MANIFEST and return it."
      (unless (equal (proofread-release--field manifest 'schema)
                     proofread-release--schema)
        (error "Unsupported release manifest schema"))
      (let* ((tag (proofread-release--field manifest 'tag))
             (commit (proofread-release--field manifest 'commit))
             (previous (proofread-release--field manifest 'previous))
             (install-order
              (proofread-release--array-list
               (proofread-release--field manifest 'install_order)
               'install_order))
             (packages (proofread-release--packages-from-manifest manifest)))
        (if (eq tag :null)
            (unless (and (eq commit :null)
                         (eq previous :null)
                         (null packages)
                         (null install-order))
              (error "Invalid bootstrap release manifest"))
          (proofread-release--tag-version tag)
          (proofread-release--validate-commit commit)
          (unless (or (eq previous :null)
                      (proofread-release--valid-tag-p previous))
            (error "Invalid previous release tag: %S" previous))
          (when (stringp previous)
            (unless (version-list-<
                     (proofread-release--tag-version previous)
                     (proofread-release--tag-version tag))
              (error "Previous release tag must precede the current tag")))
          (dolist (name install-order)
            (unless (stringp name)
              (error "Install order entries must be strings")))
          (let ((active
                 (seq-filter
                  (lambda (package)
                    (equal
                     (proofread-release--package-lifecycle package)
                     "active"))
                  packages)))
            (when (eq previous :null)
              (unless
                  (seq-every-p
                   (lambda (package)
                     (and
                      (equal
                       (proofread-release--package-lifecycle package)
                       "active")
                      (equal
                       (proofread-release--package-change package)
                       "new")))
                   packages)
                (error "The first release may contain only new active packages")))
            (proofread-release--validate-dependencies active packages)
            (unless (equal install-order
                           (proofread-release--dependency-order active))
              (error "Install order is not the complete dependency order"))))
        manifest))

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
      (let* ((description (proofread-release--archive-description archive))
             (name (symbol-name (package-desc-name description)))
             (version
              (package-version-join
               (package-desc-version description)))
             (asset (file-name-nondirectory archive)))
        (unless (proofread-release--safe-name-p name)
          (error "Invalid package name in archive: %S" name))
        (unless (equal asset (format "%s-%s.tar" name version))
          (error "Archive name does not match package metadata: %s" asset))
        (proofread-release--make-package
         :name name
         :version version
         :sha256 (proofread-release--file-sha256 archive)
         :asset asset
         :requires
         (proofread-release--requirements-from-description description)
         :lifecycle "active")))

    (defun proofread-release--read-archives (archives)
      "Return sorted package metadata read from ARCHIVES."
      (unless archives
        (error "No release archives were provided"))
      (let ((seen (make-hash-table :test #'equal))
            packages)
        (dolist (archive archives)
          (let* ((package
                  (proofread-release--package-from-archive
                   (expand-file-name archive)))
                 (name (proofread-release--package-name package)))
            (when (gethash name seen)
              (error "Duplicate release package: %s" name))
            (puthash name t seen)
            (push package packages)))
        (sort packages
              (lambda (left right)
                (string< (proofread-release--package-name left)
                         (proofread-release--package-name right))))))

    (defun proofread-release--package-table (packages)
      "Return a name-indexed hash table containing PACKAGES."
      (let ((table (make-hash-table :test #'equal)))
        (dolist (package packages)
          (puthash (proofread-release--package-name package) package table))
        table))

    (defun proofread-release--validate-dependencies (current previous)
      "Validate dependencies in CURRENT against CURRENT and PREVIOUS packages."
      (let ((active (proofread-release--package-table current))
            (known (proofread-release--package-table previous)))
        (dolist (package current)
          (dolist (requirement
                   (proofread-release--package-requires package))
            (let* ((name (car requirement))
                   (required-version (cdr requirement))
                   (dependency (gethash name active))
                   (historical (gethash name known)))
              (cond
               (dependency
                (when (version-list-<
                       (version-to-list
                        (proofread-release--package-version dependency))
                       (version-to-list required-version))
                  (error "%s requires %s %s, but the snapshot contains %s"
                         (proofread-release--package-name package)
                         name
                         required-version
                         (proofread-release--package-version dependency))))
               (historical
                (error "%s depends on missing or retired project package %s"
                       (proofread-release--package-name package)
                       name))))))))

    (defun proofread-release--dependency-order (packages)
      "Return the internal dependency order for PACKAGES."
      (let ((active (proofread-release--package-table packages))
            (pending (copy-sequence packages))
            installed
            order)
        (while pending
          (let ((ready
                 (seq-find
                  (lambda (package)
                    (seq-every-p
                     (lambda (requirement)
                       (let ((name (car requirement)))
                         (or (not (gethash name active))
                             (member name installed))))
                     (proofread-release--package-requires package)))
                  pending)))
            (unless ready
              (error "Project package dependency cycle detected"))
            (setq pending (delq ready pending))
            (push (proofread-release--package-name ready) installed)
            (push (proofread-release--package-name ready) order)))
        (nreverse order)))

    (defun proofread-release--version-comparison (left right)
      "Compare version strings LEFT and RIGHT."
      (let ((left-list (version-to-list left))
            (right-list (version-to-list right)))
        (cond
         ((version-list-< left-list right-list) -1)
         ((version-list-< right-list left-list) 1)
         (t 0))))

    (defun proofread-release--classify-package (package previous)
      "Return PACKAGE classified against PREVIOUS package metadata."
      (if (not previous)
          (setf (proofread-release--package-change package) "new")
        (when (equal (proofread-release--package-lifecycle previous) "retired")
          (error "Retired package cannot be reactivated: %s"
                 (proofread-release--package-name package)))
        (pcase (proofread-release--version-comparison
                (proofread-release--package-version package)
                (proofread-release--package-version previous))
          (-1
           (error "Package version moved backwards: %s"
                  (proofread-release--package-name package)))
          (0
           (unless (equal (proofread-release--package-version package)
                          (proofread-release--package-version previous))
             (error "Package version did not increase: %s"
                    (proofread-release--package-name package)))
           (unless (equal (proofread-release--package-sha256 package)
                          (proofread-release--package-sha256 previous))
             (error "Package changed without a version increase: %s"
                    (proofread-release--package-name package)))
           (setf (proofread-release--package-change package) "unchanged"))
          (1
           (setf (proofread-release--package-change package) "updated"))))
      package)

    (defun proofread-release--retire-package (package)
      "Return a retired copy of historical PACKAGE."
      (proofread-release--make-package
       :name (proofread-release--package-name package)
       :version (proofread-release--package-version package)
       :sha256 (proofread-release--package-sha256 package)
       :requires (proofread-release--package-requires package)
       :lifecycle "retired"
       :change
       (if (equal (proofread-release--package-lifecycle package) "active")
           "retired"
         "unchanged")))

    (defun proofread-release--replay-manifest-p (manifest tag commit current)
      "Validate a replay of MANIFEST for TAG, COMMIT, and CURRENT packages."
      (unless (equal (proofread-release--field manifest 'commit) commit)
        (error "Release tag already records a different commit"))
      (let* ((previous (proofread-release--packages-from-manifest manifest))
             (active
              (seq-filter
               (lambda (package)
                 (equal
                  (proofread-release--package-lifecycle package)
                  "active"))
               previous))
             (previous-table (proofread-release--package-table active)))
        (unless (= (length current) (length active))
          (error "Release replay has a different active package set"))
        (dolist (package current)
          (let ((old
                 (gethash
                  (proofread-release--package-name package)
                  previous-table)))
            (unless (and old
                         (equal
                          (proofread-release--package-version package)
                          (proofread-release--package-version old))
                         (equal
                          (proofread-release--package-sha256 package)
                          (proofread-release--package-sha256 old))
                         (equal
                          (proofread-release--package-requires package)
                          (proofread-release--package-requires old)))
              (error "Release replay differs for package %s"
                     (proofread-release--package-name package))))))
      (unless (equal (proofread-release--field manifest 'tag) tag)
        (error "Release replay tag mismatch"))
      t)

    (defun proofread-release--package-to-json (package)
      "Return the JSON representation of PACKAGE."
      `((name . ,(proofread-release--package-name package))
        (lifecycle . ,(proofread-release--package-lifecycle package))
        (change . ,(proofread-release--package-change package))
        (version . ,(proofread-release--package-version package))
        (asset . ,(or (proofread-release--package-asset package) :null))
        (sha256 . ,(proofread-release--package-sha256 package))
        (requires
         . ,(vconcat
             (mapcar
              (lambda (requirement)
                `((name . ,(car requirement))
                  (version . ,(cdr requirement))))
              (proofread-release--package-requires package))))))

    (defun proofread-release--new-manifest (tag commit previous-manifest current)
      "Return a new manifest for TAG, COMMIT, and CURRENT packages."
      (let* ((previous-tag (proofread-release--field previous-manifest 'tag))
             (previous
              (proofread-release--packages-from-manifest previous-manifest))
             (previous-table (proofread-release--package-table previous))
             (current-table (proofread-release--package-table current))
             packages
             changed)
        (unless (eq previous-tag :null)
          (unless (version-list-<
                   (proofread-release--tag-version previous-tag)
                   (proofread-release--tag-version tag))
            (error "Release tag does not advance the snapshot version")))
        (dolist (package current)
          (proofread-release--classify-package
           package
           (gethash
            (proofread-release--package-name package)
            previous-table))
          (unless (equal (proofread-release--package-change package) "unchanged")
            (setq changed t))
          (push package packages))
        (dolist (package previous)
          (unless (gethash (proofread-release--package-name package) current-table)
            (let ((retired (proofread-release--retire-package package)))
              (when (equal (proofread-release--package-change retired) "retired")
                (setq changed t))
              (push retired packages))))
        (unless changed
          (error "The snapshot contains no package changes"))
        (setq packages
              (sort packages
                    (lambda (left right)
                      (string< (proofread-release--package-name left)
                               (proofread-release--package-name right)))))
        `((schema . ,proofread-release--schema)
          (tag . ,tag)
          (commit . ,commit)
          (previous . ,previous-tag)
          (packages
           . ,(vconcat
               (mapcar #'proofread-release--package-to-json packages)))
          (install_order
           . ,(vconcat
               (proofread-release--dependency-order current))))))

    (defun proofread-release--release-notes (manifest)
      "Return Markdown release notes for MANIFEST."
      (let ((tag (proofread-release--string-field manifest 'tag))
            (commit (proofread-release--string-field manifest 'commit))
            (packages (proofread-release--packages-from-manifest manifest)))
        (concat
         (format "# Release %s\n\n" tag)
         (format "Repository snapshot `%s` at `%s`.\n\n" tag commit)
         "This release contains the complete set of active Emacs packages.\n\n"
         "| Package | Version | Lifecycle | Change | Asset |\n"
         "| --- | --- | --- | --- | --- |\n"
         (mapconcat
          (lambda (package)
            (format "| `%s` | `%s` | `%s` | `%s` | %s |"
                    (proofread-release--package-name package)
                    (proofread-release--package-version package)
                    (proofread-release--package-lifecycle package)
                    (proofread-release--package-change package)
                    (if-let* ((asset
                               (proofread-release--package-asset package)))
                        (format "`%s`" asset)
                      "—")))
          packages
          "\n")
         "\n")))

    (defun proofread-release--plan-json (manifest mode)
      "Return the workflow plan for MANIFEST using MODE."
      (let ((changes (make-hash-table :test #'equal)))
        (dolist (change '("new" "updated" "unchanged" "retired"))
          (puthash change nil changes))
        (dolist (package (proofread-release--packages-from-manifest manifest))
          (let ((change (proofread-release--package-change package)))
            (puthash change
                     (append (gethash change changes)
                             (list (proofread-release--package-name package)))
                     changes)))
        `((schema . ,proofread-release--schema)
          (mode . ,mode)
          (tag . ,(proofread-release--field manifest 'tag))
          (commit . ,(proofread-release--field manifest 'commit))
          (changes
           . ((new . ,(vconcat (gethash "new" changes)))
              (updated . ,(vconcat (gethash "updated" changes)))
              (unchanged . ,(vconcat (gethash "unchanged" changes)))
              (retired . ,(vconcat (gethash "retired" changes))))))))

    (defun proofread-release--write-text (text file)
      "Write TEXT to FILE with no status message."
      (with-temp-buffer
        (insert text)
        (write-region (point-min) (point-max) file nil 'silent)))

    (defun proofread-release--write-checksums (assets-dir packages)
      "Write SHA256SUMS in ASSETS-DIR for active PACKAGES and manifest."
      (let* ((names
              (sort
               (append
                (mapcar #'proofread-release--package-asset packages)
                '("manifest.json"))
               #'string<))
             (contents
              (mapconcat
               (lambda (name)
                 (format "%s  %s"
                         (proofread-release--file-sha256
                          (expand-file-name name assets-dir))
                         name))
               names
               "\n")))
        (proofread-release--write-text
         (concat contents "\n")
         (expand-file-name "SHA256SUMS" assets-dir))))

    (defun proofread-release--write-expected-assets (assets-dir output)
      "Write the expected ordinary asset names from ASSETS-DIR to OUTPUT."
      (let ((names
             (sort
              (mapcar #'file-name-nondirectory
                      (directory-files assets-dir nil "\\`[^.]"))
              #'string<)))
        (dolist (name names)
          (unless (string-match-p
                   "\\`[A-Za-z0-9][A-Za-z0-9._-]*\\'"
                   name)
            (error "Unsafe release asset name: %s" name)))
        (proofread-release--write-text
         (concat (string-join names "\n") "\n")
         output)))

    (defun proofread-release-prepare (tag commit previous-file output archives)
      "Prepare a release for TAG and COMMIT using PREVIOUS-FILE.

        Write the complete workflow handoff under OUTPUT from ARCHIVES."
      (proofread-release--tag-version tag)
      (proofread-release--validate-commit commit)
      (let* ((previous
              (proofread-release--validate-manifest
               (proofread-release--read-json previous-file)))
             (current (proofread-release--read-archives archives))
             (previous-packages
              (proofread-release--packages-from-manifest previous))
             (previous-tag (proofread-release--field previous 'tag))
             (mode
              (if (and (stringp previous-tag)
                       (equal previous-tag tag))
                  "replay"
                "new"))
             manifest)
        (proofread-release--validate-dependencies current previous-packages)
        (proofread-release--dependency-order current)
        (if (equal mode "replay")
            (progn
              (proofread-release--replay-manifest-p
               previous tag commit current)
              (setq manifest previous))
          (setq manifest
                (proofread-release--new-manifest
                 tag commit previous current)))
        (when (file-exists-p output)
          (error "Release output already exists: %s" output))
        (let ((assets-dir (expand-file-name "assets" output)))
          (make-directory assets-dir t)
          (dolist (archive archives)
            (copy-file archive
                       (expand-file-name
                        (file-name-nondirectory archive)
                        assets-dir)))
          (if (equal mode "replay")
              (copy-file previous-file
                         (expand-file-name "manifest.json" assets-dir))
            (proofread-release--write-json
             manifest
             (expand-file-name "manifest.json" assets-dir)))
          (proofread-release--write-checksums assets-dir current)
          (proofread-release--write-expected-assets
           assets-dir
           (expand-file-name "expected-assets.txt" output))
          (proofread-release--write-json
           (proofread-release--plan-json manifest mode)
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
         (packages . [])
         (install_order . []))
       output))

    (defun proofread-release--verify-checksums (manifest-file expected)
      "Verify SHA256SUMS next to MANIFEST-FILE contains EXPECTED names."
      (let* ((directory (file-name-directory manifest-file))
             (checksum-file (expand-file-name "SHA256SUMS" directory))
             seen)
        (with-temp-buffer
          (insert-file-contents checksum-file)
          (goto-char (point-min))
          (while (not (eobp))
            (unless (looking-at
                     "\\([0-9a-f]\\{64\\}\\)  \\([A-Za-z0-9][A-Za-z0-9._-]*\\)$")
              (error "Invalid SHA256SUMS line"))
            (let ((digest (match-string 1))
                  (name (match-string 2)))
              (when (member name seen)
                (error "Duplicate checksum entry: %s" name))
              (push name seen)
              (unless (equal
                       digest
                       (proofread-release--file-sha256
                        (expand-file-name name directory)))
                (error "Checksum mismatch: %s" name)))
            (forward-line 1)))
        (unless (equal (sort seen #'string<)
                       (sort (copy-sequence expected) #'string<))
          (error "SHA256SUMS does not cover the exact release asset set"))))

    (defun proofread-release--verify-archive (directory package)
      "Verify PACKAGE against its archive in DIRECTORY."
      (let* ((asset (proofread-release--package-asset package))
             (actual
              (proofread-release--package-from-archive
               (expand-file-name asset directory))))
        (unless (and
                 (equal (proofread-release--package-name actual)
                        (proofread-release--package-name package))
                 (equal (proofread-release--package-version actual)
                        (proofread-release--package-version package))
                 (equal (proofread-release--package-sha256 actual)
                        (proofread-release--package-sha256 package))
                 (equal (proofread-release--package-asset actual) asset)
                 (equal (proofread-release--package-requires actual)
                        (proofread-release--package-requires package)))
          (error "Archive metadata differs from manifest: %s" asset))))

    (defun proofread-release-verify-install (manifest-file)
      "Install and load packages described by MANIFEST-FILE in isolation."
      (let* ((manifest
              (proofread-release--validate-manifest
               (proofread-release--read-json manifest-file)))
             (packages (proofread-release--packages-from-manifest manifest))
             (active
              (seq-filter
               (lambda (package)
                 (equal
                  (proofread-release--package-lifecycle package)
                  "active"))
               packages))
             (active-table (proofread-release--package-table active))
             (order
              (proofread-release--array-list
               (proofread-release--field manifest 'install_order)
               'install_order))
             (directory (file-name-directory manifest-file))
             (package-dir (make-temp-file "proofread-release-packages-" t))
             (init-dir (make-temp-file "proofread-release-init-" t)))
        (proofread-release--verify-checksums
         manifest-file
         (cons "manifest.json"
               (mapcar #'proofread-release--package-asset active)))
        (dolist (package active)
          (proofread-release--verify-archive directory package))
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
              (dolist (name order)
                (when (or (featurep (intern name))
                          (locate-library name))
                  (error "Project package is already available: %s" name)))
              (dolist (name order)
                (let* ((package (gethash name active-table))
                       (version (proofread-release--package-version package))
                       (archive
                        (expand-file-name
                         (proofread-release--package-asset package)
                         directory)))
                  (package-install-file archive)
                  (unless (package-installed-p
                           (intern name)
                           (version-to-list version))
                    (error "Package was not installed: %s" name))
                  (let ((description
                         (car (alist-get (intern name) package-alist))))
                    (unless (and description
                                 (equal (package-desc-version description)
                                        (version-to-list version)))
                      (error "Package installed at an unexpected version: %s"
                             name)))
                  (require (intern name))
                  (let ((library (locate-library name)))
                    (unless (and library
                                 (file-in-directory-p library package-dir))
                      (error "Package did not load from the isolated directory: %s"
                             name))))))
          (delete-directory package-dir t)
          (delete-directory init-dir t)))
      t)

    (defun proofread-release-check-versions (manifest-file assignments)
      "Check Nix version ASSIGNMENTS against MANIFEST-FILE.

        Each assignment must have the form NAME=VERSION."
      (let* ((manifest
              (proofread-release--validate-manifest
               (proofread-release--read-json manifest-file)))
             (packages
              (seq-filter
               (lambda (package)
                 (equal
                  (proofread-release--package-lifecycle package)
                  "active"))
               (proofread-release--packages-from-manifest manifest)))
             (expected (proofread-release--package-table packages))
             (seen (make-hash-table :test #'equal)))
        (dolist (assignment assignments)
          (unless (string-match
                   "\\`\\([a-z0-9][a-z0-9-]*\\)=\\(.+\\)\\'"
                   assignment)
            (error "Invalid Nix version assignment: %s" assignment))
          (let* ((name (match-string 1 assignment))
                 (version (match-string 2 assignment))
                 (package (gethash name expected)))
            (unless package
              (error "Unexpected Nix package version: %s" name))
            (when (gethash name seen)
              (error "Duplicate Nix package version: %s" name))
            (puthash name t seen)
            (unless (equal version
                           (proofread-release--package-version package))
              (error "Nix version mismatch for %s: %s != %s"
                     name
                     version
                     (proofread-release--package-version package)))))
        (dolist (package packages)
          (unless (gethash (proofread-release--package-name package) seen)
            (error "Nix package version is missing: %s"
                   (proofread-release--package-name package)))))
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
          ("prepare"
           (when (< (length command-line-args-left) 5)
             (error "Usage: prepare TAG COMMIT PREVIOUS OUTPUT ARCHIVE..."))
           (let ((tag (pop command-line-args-left))
                 (commit (pop command-line-args-left))
                 (previous (pop command-line-args-left))
                 (output (pop command-line-args-left)))
             (proofread-release-prepare
              tag commit previous output command-line-args-left)
             (setq command-line-args-left nil)))
          ("verify-install"
           (unless (= (length command-line-args-left) 1)
             (error "Usage: verify-install MANIFEST"))
           (proofread-release-verify-install
            (pop command-line-args-left)))
          ("validate"
           (unless (= (length command-line-args-left) 1)
             (error "Usage: validate MANIFEST"))
           (proofread-release--validate-manifest
            (proofread-release--read-json
             (pop command-line-args-left))))
          ("check-versions"
           (when (< (length command-line-args-left) 2)
             (error "Usage: check-versions MANIFEST NAME=VERSION..."))
           (let ((manifest (pop command-line-args-left)))
             (proofread-release-check-versions
              manifest command-line-args-left)
             (setq command-line-args-left nil)))
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
  '';
in
writeTextFile {
  name = "proofread-release";
  destination = "/bin/proofread-release";
  executable = true;
  text = script;
}
