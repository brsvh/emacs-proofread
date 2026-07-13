;;; proofread-release-tests.el --- Tests for release tooling  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;;; Commentary:

;; Tests for the local Proofread release preparation and verification tool.

;;; Code:

(require 'ert)
(require 'proofread-release)

(defconst proofread-release-tests--commit
  "0123456789abcdef0123456789abcdef01234567")

(defconst proofread-release-tests--other-commit
  "89abcdef0123456789abcdef0123456789abcdef")

(defun proofread-release-tests--digest (character)
  "Return a test SHA-256 consisting of CHARACTER."
  (make-string 64 character))

(defun proofread-release-tests--package
    (name version character &optional requires lifecycle change)
  "Return test package NAME at VERSION using digest CHARACTER.

REQUIRES, LIFECYCLE, and CHANGE override their normal defaults."
  (proofread-release--make-package
   :name name
   :version version
   :sha256 (proofread-release-tests--digest character)
   :asset
   (unless (equal lifecycle "retired")
     (format "%s-%s.tar" name version))
   :requires requires
   :lifecycle (or lifecycle "active")
   :change (or change "unchanged")))

(defun proofread-release-tests--bootstrap ()
  "Return the empty release manifest."
  `((schema . ,proofread-release--schema)
    (tag . :null)
    (commit . :null)
    (previous . :null)
    (packages . [])
    (install_order . [])))

(defun proofread-release-tests--manifest (tag commit packages order)
  "Return a manifest for TAG, COMMIT, PACKAGES, and install ORDER."
  `((schema . ,proofread-release--schema)
    (tag . ,tag)
    (commit . ,commit)
    (previous . :null)
    (packages
     . ,(vconcat
         (mapcar #'proofread-release--package-to-json packages)))
    (install_order . ,(vconcat order))))

(defun proofread-release-tests--manifest-package (manifest name)
  "Return package NAME parsed from MANIFEST."
  (seq-find
   (lambda (package)
     (equal (proofread-release--package-name package) name))
   (proofread-release--packages-from-manifest manifest)))

(defun proofread-release-tests--create-archive
    (directory name version requires body &optional extra-files)
  "Create a fixture archive in DIRECTORY.

NAME, VERSION, REQUIRES, and BODY describe its main library.
EXTRA-FILES is an alist of additional relative file names and contents."
  (let* ((package-directory-name (format "%s-%s" name version))
         (package-directory
          (expand-file-name package-directory-name directory))
         (archive
          (expand-file-name
           (concat package-directory-name ".tar")
           directory)))
    (make-directory package-directory t)
    (proofread-release--write-text
     (format
      (concat
       ";;; %s.el --- Release fixture  -*- lexical-binding: t; -*-\n\n"
       ";;; Code:\n\n%s\n\n(provide '%s)\n;;; %s.el ends here\n")
      name body name name)
     (expand-file-name (concat name ".el") package-directory))
    (proofread-release--write-text
     (format
      (concat
       ";;; %s-pkg.el --- Release fixture package "
       "-*- no-byte-compile: t; lexical-binding: t; -*-\n\n"
       "(define-package %S %S \"Release fixture\" '%S)\n")
      name name version requires)
     (expand-file-name
      (concat name "-pkg.el")
      package-directory))
    (dolist (file extra-files)
      (proofread-release--write-text
       (cdr file)
       (expand-file-name (car file) package-directory)))
    (let ((default-directory directory))
      (unless
          (zerop
           (call-process
            "tar" nil nil nil
            "--sort=name"
            "--mtime=@0"
            "--owner=0"
            "--group=0"
            "--numeric-owner"
            "-cf" archive
            package-directory-name))
        (error "Could not create release fixture: %s" name)))
    archive))

(ert-deftest proofread-release-bootstrap-manifest-is-valid ()
  (let ((file (make-temp-file "proofread-release-bootstrap-")))
    (unwind-protect
        (progn
          (delete-file file)
          (proofread-release-bootstrap file)
          (should
           (proofread-release--validate-manifest
            (proofread-release--read-json file))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest proofread-release-rejects-object-in-place-of-array ()
  (let ((manifest (proofread-release-tests--bootstrap)))
    (setcdr (assq 'packages manifest) nil)
    (should-error
     (proofread-release--validate-manifest manifest))))

(ert-deftest proofread-release-rejects-duplicate-json-fields ()
  (let ((file (make-temp-file "proofread-release-duplicate-")))
    (unwind-protect
        (progn
          (proofread-release--write-text
           (concat
            "{\"schema\":1,\"tag\":null,\"tag\":\"v9.9.9\","
            "\"commit\":null,\"previous\":null,\"packages\":[],"
            "\"install_order\":[]}")
           file)
          (should-error
           (proofread-release--validate-manifest
            (proofread-release--read-json file))))
      (delete-file file))))

(ert-deftest proofread-release-first-snapshot-marks-packages-new ()
  (let* ((core
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a))
         (popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0"))))
         (manifest
          (proofread-release--new-manifest
           "v0.1.0"
           proofread-release-tests--commit
           (proofread-release-tests--bootstrap)
           (list core popup))))
    (should
     (equal
      (mapcar #'proofread-release--package-change
              (proofread-release--packages-from-manifest manifest))
      '("new" "new")))
    (should
     (equal (proofread-release--field manifest 'install_order)
            ["proofread" "proofread-popup"]))))

(ert-deftest proofread-release-snapshot-classifies-update-and-unchanged ()
  (let* ((old-core
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (old-popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b nil "active" "new"))
         (previous
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list old-core old-popup)
           '("proofread" "proofread-popup")))
         (core
          (proofread-release-tests--package
           "proofread" "0.2.0" ?c))
         (popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b))
         (manifest
          (proofread-release--new-manifest
           "v0.2.0"
           proofread-release-tests--other-commit
           previous
           (list core popup))))
    (should
     (equal
      (proofread-release--package-change
       (proofread-release-tests--manifest-package manifest "proofread"))
      "updated"))
    (should
     (equal
      (proofread-release--package-change
       (proofread-release-tests--manifest-package
        manifest "proofread-popup"))
      "unchanged"))))

(ert-deftest proofread-release-rejects-change-without-version-increase ()
  (let ((current
         (proofread-release-tests--package
          "proofread" "0.1.0" ?b))
        (previous
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a)))
    (should-error
     (proofread-release--classify-package current previous))))

(ert-deftest proofread-release-rejects-version-rollback ()
  (let ((current
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a))
        (previous
         (proofread-release-tests--package
          "proofread" "0.2.0" ?b)))
    (should-error
     (proofread-release--classify-package current previous))))

(ert-deftest proofread-release-rejects-equivalent-version-rewrite ()
  (let ((current
         (proofread-release-tests--package
          "proofread" "1.0.0" ?a))
        (previous
         (proofread-release-tests--package
          "proofread" "1.0" ?a)))
    (should
     (= (proofread-release--version-comparison "1.0.0" "1.0") 0))
    (should-error
     (proofread-release--classify-package current previous))))

(ert-deftest proofread-release-retires-missing-package ()
  (let* ((old-core
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (old-popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b nil "active" "new"))
         (previous
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list old-core old-popup)
           '("proofread" "proofread-popup")))
         (core
          (proofread-release-tests--package
           "proofread" "0.2.0" ?c))
         (manifest
          (proofread-release--new-manifest
           "v0.2.0"
           proofread-release-tests--other-commit
           previous
           (list core)))
         (popup
          (proofread-release-tests--manifest-package
           manifest "proofread-popup")))
    (should
     (equal (proofread-release--package-lifecycle popup) "retired"))
    (should
     (equal (proofread-release--package-change popup) "retired"))
    (should-not (proofread-release--package-asset popup))))

(ert-deftest proofread-release-rejects-retired-package-reactivation ()
  (let ((current
         (proofread-release-tests--package
          "proofread" "0.2.0" ?b))
        (previous
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a nil "retired" "retired")))
    (should-error
     (proofread-release--classify-package current previous))))

(ert-deftest proofread-release-rejects-empty-snapshot-change ()
  (let* ((old
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (previous
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list old)
           '("proofread")))
         (current
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a)))
    (should-error
     (proofread-release--new-manifest
      "v0.1.1"
      proofread-release-tests--other-commit
      previous
      (list current)))))

(ert-deftest proofread-release-rejects-snapshot-tag-rollback ()
  (let* ((old
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (previous
          (proofread-release-tests--manifest
           "v0.2.0"
           proofread-release-tests--commit
           (list old)
           '("proofread")))
         (current
          (proofread-release-tests--package
           "proofread" "0.2.0" ?b)))
    (should-error
     (proofread-release--new-manifest
      "v0.1.0"
      proofread-release-tests--other-commit
      previous
      (list current)))))

(ert-deftest proofread-release-rejects-unsatisfied-internal-dependency ()
  (let ((core
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a))
        (popup
         (proofread-release-tests--package
          "proofread-popup" "0.2.0" ?b
          '(("proofread" . "0.2.0")))))
    (should-error
     (proofread-release--validate-dependencies
      (list core popup)
      nil))))

(ert-deftest proofread-release-rejects-dependency-retired-this-release ()
  (let ((core
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a nil "active" "new"))
        (popup
         (proofread-release-tests--package
          "proofread-popup" "0.2.0" ?b
          '(("proofread" . "0.1.0")))))
    (should-error
     (proofread-release--validate-dependencies
      (list popup)
      (list core)))))

(ert-deftest proofread-release-rejects-project-dependency-cycle ()
  (let ((first
         (proofread-release-tests--package
          "proofread" "0.1.0" ?a
          '(("proofread-popup" . "0.1.0"))))
        (second
         (proofread-release-tests--package
          "proofread-popup" "0.1.0" ?b
          '(("proofread" . "0.1.0")))))
    (should-error
     (proofread-release--dependency-order
      (list first second)))))

(ert-deftest proofread-release-validates-identical-replay ()
  (let* ((old
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (manifest
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list old)
           '("proofread")))
         (current
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a)))
    (should
     (proofread-release--replay-manifest-p
      manifest
      "v0.1.0"
      proofread-release-tests--commit
      (list current)))
    (should-error
     (proofread-release--replay-manifest-p
      manifest
      "v0.1.0"
      proofread-release-tests--other-commit
      (list current)))))

(ert-deftest proofread-release-rejects-incomplete-install-order ()
  (let* ((core
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0")) "active" "new"))
         (manifest
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list core popup)
           '("proofread" "proofread"))))
    (should-error
     (proofread-release--validate-manifest manifest))))

(ert-deftest proofread-release-rejects-invalid-lifecycle-change ()
  (let* ((package
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "retired" "new"))
         (manifest
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list package)
           nil)))
    (should-error
     (proofread-release--validate-manifest manifest))))

(ert-deftest proofread-release-checks-complete-nix-version-set ()
  (let* ((core
          (proofread-release-tests--package
           "proofread" "0.1.0" ?a nil "active" "new"))
         (popup
          (proofread-release-tests--package
           "proofread-popup" "0.1.0" ?b nil "active" "new"))
         (manifest
          (proofread-release-tests--manifest
           "v0.1.0"
           proofread-release-tests--commit
           (list core popup)
           '("proofread" "proofread-popup")))
         (file (make-temp-file "proofread-release-manifest-")))
    (unwind-protect
        (progn
          (proofread-release--write-json manifest file)
          (should
           (proofread-release-check-versions
            file
            '("proofread=0.1.0" "proofread-popup=0.1.0")))
          (should-error
           (proofread-release-check-versions
            file
            '("proofread=0.1.0"))))
      (delete-file file))))

(ert-deftest proofread-release-prepares-and-installs-real-archives ()
  (let* ((directory
          (make-temp-file "proofread-release-integration-" t))
         (previous (expand-file-name "previous.json" directory))
         (output (expand-file-name "handoff" directory))
         (core-name "proofread-release-fixture-core")
         (addon-name "proofread-release-fixture-addon")
         (llm-name (concat core-name "-llm"))
         (llm-file (concat llm-name ".el"))
         (languagetool-name (concat core-name "-languagetool"))
         (languagetool-file (concat languagetool-name ".el"))
         (core
          (proofread-release-tests--create-archive
           directory core-name "1.0.0"
           '((emacs "30.1"))
           (format "(require '%s)\n(require '%s)"
                   llm-name languagetool-name)
           `((,llm-file
              . ,(format
                  (concat
                   ";;; %s --- Release fixture LLM backend  "
                   "-*- lexical-binding: t; -*-\n\n"
                   "(provide '%s)\n;;; %s ends here\n")
                  llm-file llm-name llm-file))
             (,languagetool-file
              . ,(format
                  (concat
                   ";;; %s --- Release fixture LanguageTool backend  "
                   "-*- lexical-binding: t; -*-\n\n"
                   "(provide '%s)\n;;; %s ends here\n")
                  languagetool-file
                  languagetool-name
                  languagetool-file)))))
         (addon
          (proofread-release-tests--create-archive
           directory addon-name "1.1.0"
           `((emacs "30.1") (,(intern core-name) "1.0.0"))
           (format "(require '%s)" core-name))))
    (unwind-protect
        (progn
          (proofread-release-bootstrap previous)
          (proofread-release-prepare
           "v1.0.0"
           proofread-release-tests--commit
           previous
           output
           (list core addon))
          (let ((manifest
                 (expand-file-name "assets/manifest.json" output)))
            (should
             (proofread-release--validate-manifest
              (proofread-release--read-json manifest)))
            (should (proofread-release-verify-install manifest))))
      (delete-directory directory t))))

(provide 'proofread-release-tests)
;;; proofread-release-tests.el ends here
