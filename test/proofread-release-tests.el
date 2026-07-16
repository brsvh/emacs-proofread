;;; proofread-release-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Bingshan Chang <chang@bingshan.org>

;;; Commentary:

;; Tests for the local Proofread release preparation and verification
;; tool.

;;; Code:

(require 'ert)
(require 'proofread-release)
(require 'seq)

;;;; Fixtures

(defconst proofread-release-test--commit
  "0123456789abcdef0123456789abcdef01234567"
  "Commit hash used by release test fixtures.")

(defconst proofread-release-test--other-commit
  "89abcdef0123456789abcdef0123456789abcdef"
  "Alternative commit hash used by release test fixtures.")

(defun proofread-release-test--digest (character)
  "Return a test SHA-256 consisting of CHARACTER."
  (make-string 64 character))

(defun proofread-release-test--package
    (name version character &optional requires release-tag commit)
  "Return test package NAME at VERSION using digest CHARACTER.

REQUIRES, RELEASE-TAG, and COMMIT override their normal defaults."
  (proofread-release--make-package
   :name name
   :version version
   :sha256 (proofread-release-test--digest character)
   :asset (format "%s-%s.tar" name version)
   :requires requires
   :release-tag (or release-tag (format "%s-v%s" name version))
   :commit (or commit proofread-release-test--commit)))

(defun proofread-release-test--bootstrap ()
  "Return the empty release manifest."
  `((schema . ,proofread-release--schema)
    (tag . :null)
    (commit . :null)
    (previous . :null)
    (released_package . :null)
    (packages . [])))

(defun proofread-release-test--manifest
    (tag commit released-package packages &optional previous)
  "Return a schema 2 manifest.

TAG, COMMIT, RELEASED-PACKAGE, PACKAGES, and PREVIOUS define the manifest."
  `((schema . ,proofread-release--schema)
    (tag . ,tag)
    (commit . ,commit)
    (previous . ,(or previous :null))
    (released_package . ,released-package)
    (packages
     . ,(vconcat
         (mapcar #'proofread-release--package-to-json packages)))))

(defun proofread-release-test--legacy-package-json
    (package &optional lifecycle change)
  "Return legacy JSON for PACKAGE.

LIFECYCLE and CHANGE default to active new-package metadata."
  `((name . ,(proofread-release--package-name package))
    (lifecycle . ,(or lifecycle "active"))
    (change . ,(or change "new"))
    (version . ,(proofread-release--package-version package))
    (asset . ,(if (equal lifecycle "retired")
                  :null
                (proofread-release--package-asset package)))
    (sha256 . ,(proofread-release--package-sha256 package))
    (requires
     . ,(proofread-release--requirements-to-json
         (proofread-release--package-requires package)))))

(defun proofread-release-test--legacy-manifest (tag commit packages)
  "Return a legacy aggregate manifest for TAG, COMMIT, and PACKAGES."
  `((schema . ,proofread-release--legacy-schema)
    (tag . ,tag)
    (commit . ,commit)
    (previous . :null)
    (packages
     . ,(vconcat
         (mapcar #'proofread-release-test--legacy-package-json packages)))
    (install_order
     . ,(vconcat
         (mapcar #'proofread-release--package-name packages)))))

(defun proofread-release-test--manifest-package (manifest name)
  "Return package NAME parsed from MANIFEST."
  (seq-find
   (lambda (package)
     (equal (proofread-release--package-name package) name))
   (proofread-release--packages-from-manifest manifest)))

(defun proofread-release-test--read-lines (file)
  "Return FILE contents as a list of lines."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

(defun proofread-release-test--create-archive
    (directory name version requires body &optional extra-files)
  "Create a fixture archive in DIRECTORY.

NAME, VERSION, REQUIRES, and BODY describe its main library.
EXTRA-FILES maps additional relative file names to their contents."
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
       ";;; %s.el --- Release fixture  "
       "-*- lexical-binding: t; -*-\n\n"
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

(defun proofread-release-test--archive-package
    (archive release-tag &optional commit)
  "Return release metadata for ARCHIVE under RELEASE-TAG.

COMMIT defaults to `proofread-release-test--commit'."
  (proofread-release--with-release-identity
   (proofread-release--package-from-archive archive)
   release-tag
   (or commit proofread-release-test--commit)))

(defun proofread-release-test--write-manifest
    (directory released packages)
  "Write a manifest for RELEASED and PACKAGES in DIRECTORY."
  (let ((file (expand-file-name "manifest.json" directory)))
    (proofread-release--write-json
     (proofread-release-test--manifest
      (proofread-release--package-release-tag released)
      (proofread-release--package-commit released)
      (proofread-release--package-name released)
      packages)
     file)
    file))

(defvar proofread-release-test--load-order nil
  "Package load order recorded by release archive fixtures.")

(defun proofread-release-test--recording-body (marker prelude)
  "Return fixture source that records MARKER after evaluating PRELUDE."
  (format
   (concat
    "(defvar proofread-release-test--load-order nil)\n"
    "%s\n"
    "(setq proofread-release-test--load-order\n"
    "      (append proofread-release-test--load-order '(%S)))")
   prelude marker))

;;;; Manifest validation

(ert-deftest proofread-release-test-bootstrap-manifest-is-valid ()
  "A newly bootstrapped release manifest is valid."
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

(ert-deftest proofread-release-test-legacy-bootstrap-manifest-is-valid ()
  "A legacy bootstrap release manifest remains readable."
  (let ((manifest
         `((schema . ,proofread-release--legacy-schema)
           (tag . :null)
           (commit . :null)
           (previous . :null)
           (packages . [])
           (install_order . []))))
    (should
     (proofread-release--validate-manifest manifest))))

(ert-deftest
    proofread-release-test-rejects-object-in-place-of-array ()
  "Manifest validation rejects an object in place of an array."
  (let ((manifest (proofread-release-test--bootstrap)))
    (setcdr (assq 'packages manifest) nil)
    (should-error
     (proofread-release--validate-manifest manifest))))

(ert-deftest proofread-release-test-rejects-duplicate-json-fields ()
  "Manifest parsing rejects duplicate JSON object fields."
  (let ((file (make-temp-file "proofread-release-duplicate-")))
    (unwind-protect
        (progn
          (proofread-release--write-text
           (concat
            "{\"schema\":2,\"tag\":null,\"tag\":\"proofread-v9.9.9\","
            "\"commit\":null,\"previous\":null,"
            "\"released_package\":null,\"packages\":[]}")
           file)
          (should-error
           (proofread-release--validate-manifest
            (proofread-release--read-json file))))
      (delete-file file))))

(ert-deftest proofread-release-test-parses-package-tags ()
  "Package release tags select a known package and version."
  (should
   (equal
    (proofread-release--tag-package-and-version
     "proofread-popup-v0.1.1"
     '("proofread" "proofread-popup"))
    '("proofread-popup" . "0.1.1")))
  (should-error
   (proofread-release--tag-package-and-version
    "v0.1.1" '("proofread")))
  (should-error
   (proofread-release--tag-package-and-version
    "unknown-v0.1.1" '("proofread"))))

;;;; Package release manifests

(ert-deftest proofread-release-test-updates-one-package-record ()
  "A package release updates only the released package record."
  (let* ((old-core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (old-popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0"))))
         (previous
          (proofread-release-test--manifest
           "proofread-popup-v0.1.0"
           proofread-release-test--commit
           "proofread-popup"
           (list old-core old-popup)))
         (new-core
          (proofread-release-test--package
           "proofread" "0.2.0" ?c))
         (manifest
          (proofread-release--new-manifest
           "proofread-v0.2.0"
           proofread-release-test--other-commit
           previous
           new-core))
         (core
          (proofread-release-test--manifest-package
           manifest "proofread"))
         (popup
          (proofread-release-test--manifest-package
           manifest "proofread-popup")))
    (should
     (equal (proofread-release--field manifest 'released_package)
            "proofread"))
    (should
     (equal (proofread-release--field manifest 'previous)
            "proofread-popup-v0.1.0"))
    (should
     (equal (proofread-release--package-release-tag core)
            "proofread-v0.2.0"))
    (should
     (equal (proofread-release--package-commit core)
            proofread-release-test--other-commit))
    (should
     (equal (proofread-release--package-release-tag popup)
            "proofread-popup-v0.1.0"))
    (should
     (equal (proofread-release--package-version popup)
            "0.1.0"))
    (should
     (equal (proofread-release--package-requires popup)
            '(("proofread" . "0.1.0"))))))

(ert-deftest proofread-release-test-updates-popup-after-core ()
  "Popup 0.1.1 can follow a core 0.2.0 package release."
  (let* ((core
          (proofread-release-test--package
           "proofread" "0.2.0" ?a))
         (old-popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0"))))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.2.0"
           proofread-release-test--commit
           "proofread"
           (list core old-popup)
           "proofread-popup-v0.1.0"))
         (new-popup
          (proofread-release-test--package
           "proofread-popup" "0.1.1" ?c
           '(("proofread" . "0.2.0"))
           nil proofread-release-test--other-commit))
         (manifest
          (proofread-release--new-manifest
           "proofread-popup-v0.1.1"
           proofread-release-test--other-commit
           previous
           new-popup))
         (manifest-core
          (proofread-release-test--manifest-package
           manifest "proofread"))
         (manifest-popup
          (proofread-release-test--manifest-package
           manifest "proofread-popup")))
    (should
     (equal (proofread-release--field manifest 'released_package)
            "proofread-popup"))
    (should
     (equal (proofread-release--field manifest 'previous)
            "proofread-v0.2.0"))
    (should
     (equal (proofread-release--package-version manifest-core)
            "0.2.0"))
    (should
     (equal (proofread-release--package-release-tag manifest-core)
            "proofread-v0.2.0"))
    (should
     (equal (proofread-release--package-version manifest-popup)
            "0.1.1"))
    (should
     (equal (proofread-release--package-requires manifest-popup)
            '(("proofread" . "0.2.0"))))
    (should
     (equal
      (mapcar
       #'proofread-release--package-name
       (proofread-release--required-dependencies
        previous new-popup))
      '("proofread")))))

(ert-deftest proofread-release-test-does-not-retire-absent-package ()
  "A package release preserves unrelated package records."
  (let* ((old-core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (old-popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list old-core old-popup)))
         (new-core
          (proofread-release-test--package
           "proofread" "0.2.0" ?c))
         (manifest
          (proofread-release--new-manifest
           "proofread-v0.2.0"
           proofread-release-test--other-commit
           previous
           new-core)))
    (should
     (proofread-release-test--manifest-package
      manifest "proofread-popup"))))

(ert-deftest
    proofread-release-test-rejects-change-without-version-increase ()
  "Reject changed contents without a version bump."
  (let* ((old
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list old)))
         (current
          (proofread-release-test--package
           "proofread" "0.1.0" ?b)))
    (should-error
     (proofread-release--new-manifest
      "proofread-v0.1.0"
      proofread-release-test--other-commit
      previous
      current))))

(ert-deftest proofread-release-test-rejects-version-rollback ()
  "Reject a package version rollback."
  (let* ((old
          (proofread-release-test--package
           "proofread" "0.2.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.2.0"
           proofread-release-test--commit
           "proofread"
           (list old)))
         (current
          (proofread-release-test--package
           "proofread" "0.1.0" ?b)))
    (should-error
     (proofread-release--new-manifest
      "proofread-v0.1.0"
      proofread-release-test--other-commit
      previous
      current))))

(ert-deftest
    proofread-release-test-rejects-equivalent-version-rewrite ()
  "Reject rewriting an equivalent version string."
  (let* ((old
          (proofread-release-test--package
           "proofread" "1.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v1.0.0"
           proofread-release-test--commit
           "proofread"
           (list old)))
         (current
          (proofread-release-test--package
           "proofread" "1.0.0" ?a)))
    (should
     (= (proofread-release--version-comparison "1.0.0" "1.0") 0))
    (should-error
     (proofread-release--new-manifest
      "proofread-v1.0.0"
      proofread-release-test--other-commit
      previous
      current))))

(ert-deftest proofread-release-test-rejects-unchanged-package-release ()
  "A non-legacy package release must make an effective package change."
  (let* ((old
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list old)))
         (current
          (proofread-release-test--package
           "proofread" "0.1.0" ?a)))
    (should-error
     (proofread-release--new-manifest
      "proofread-v0.1.0"
      proofread-release-test--other-commit
      previous
      current))))

(ert-deftest proofread-release-test-canonicalizes-legacy-manifests ()
  "A package tag may canonicalize matching legacy aggregate metadata."
  (let* ((legacy-core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a nil "v0.1.0"))
         (legacy-popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0")) "v0.1.0"))
         (previous
          (proofread-release-test--legacy-manifest
           "v0.1.0"
           proofread-release-test--commit
           (list legacy-core legacy-popup)))
         (current
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (manifest
          (proofread-release--new-manifest
           "proofread-v0.1.0"
           proofread-release-test--other-commit
           previous
           current))
         (core
          (proofread-release-test--manifest-package
           manifest "proofread"))
         (popup
          (proofread-release-test--manifest-package
           manifest "proofread-popup")))
    (should
     (proofread-release--validate-manifest manifest))
    (should
     (equal (proofread-release--field manifest 'previous) "v0.1.0"))
    (should
     (equal (proofread-release--package-release-tag core)
            "proofread-v0.1.0"))
    (should
     (equal (proofread-release--package-release-tag popup)
            "v0.1.0"))))

;;;; Dependency validation

(ert-deftest proofread-release-test-finds-required-dependencies ()
  "Internal dependencies are selected from the previous ledger."
  (let* ((core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list core)))
         (popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.1.0"))))
         (dependencies
          (proofread-release--required-dependencies
           previous popup)))
    (should
     (equal
      (mapcar #'proofread-release--package-name dependencies)
      '("proofread")))))

(ert-deftest
    proofread-release-test-finds-transitive-reverse-dependencies ()
  "Verification selects forward and transitive reverse dependencies."
  (let* ((base
          (proofread-release-test--package "base" "1.0.0" ?a))
         (candidate
          (proofread-release-test--package
           "core" "2.0.0" ?b '(("base" . "1.0.0"))))
         (middle
          (proofread-release-test--package
           "middle" "1.0.0" ?c '(("core" . "1.0.0"))))
         (top
          (proofread-release-test--package
           "top" "1.0.0" ?d '(("middle" . "1.0.0"))))
         (unrelated
          (proofread-release-test--package "unrelated" "1.0.0" ?e)))
    (should
     (equal
      (mapcar
       #'proofread-release--package-name
       (proofread-release--verification-packages
        candidate (list top unrelated base middle)))
      '("base" "core" "middle" "top")))))

(ert-deftest
    proofread-release-test-rejects-unsatisfied-internal-dependency ()
  "Dependency resolution rejects an insufficient ledger package."
  (let* ((core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (previous
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list core)))
         (popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b
           '(("proofread" . "0.2.0")))))
    (should-error
     (proofread-release--required-dependencies
      previous popup))))

(ert-deftest proofread-release-test-rejects-project-dependency-cycle ()
  "Dependency ordering rejects a cycle among project packages."
  (let ((first
         (proofread-release-test--package
          "proofread" "0.1.0" ?a
          '(("proofread-popup" . "0.1.0"))))
        (second
         (proofread-release-test--package
          "proofread-popup" "0.1.0" ?b
          '(("proofread" . "0.1.0")))))
    (should-error
     (proofread-release--collect-dependencies
      first (list first second)))))

;;;; Replay and release metadata

(ert-deftest proofread-release-test-validates-identical-replay ()
  "Replay validation accepts only an identical tag and commit."
  (let* ((package
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (manifest
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list package)))
         (current
          (proofread-release-test--package
           "proofread" "0.1.0" ?a)))
    (should
     (proofread-release--replay-manifest-p
      manifest
      "proofread-v0.1.0"
      proofread-release-test--commit
      current))
    (should-error
     (proofread-release--replay-manifest-p
      manifest
      "proofread-v0.1.0"
      proofread-release-test--other-commit
      current))))

(ert-deftest
    proofread-release-test-rejects-mismatched-released-package-record ()
  "Manifest validation checks the released package record."
  (let* ((package
          (proofread-release-test--package
           "proofread" "0.1.0" ?a nil "v0.1.0"))
         (manifest
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list package))))
    (should-error
     (proofread-release--validate-manifest manifest))))

(ert-deftest proofread-release-test-checks-released-nix-version ()
  "Nix version checks validate the released package only."
  (let* ((core
          (proofread-release-test--package
           "proofread" "0.1.0" ?a))
         (popup
          (proofread-release-test--package
           "proofread-popup" "0.1.0" ?b))
         (manifest
          (proofread-release-test--manifest
           "proofread-v0.1.0"
           proofread-release-test--commit
           "proofread"
           (list core popup)))
         (file (make-temp-file "proofread-release-manifest-")))
    (unwind-protect
        (progn
          (proofread-release--write-json manifest file)
          (should
           (proofread-release-check-package-version
            file "proofread" "0.1.0"))
          (should-error
           (proofread-release-check-package-version
            file "proofread-popup" "0.1.0"))
          (should-error
           (proofread-release-check-package-version
            file "proofread" "0.2.0")))
      (delete-file file))))

;;;; Archive integration

(ert-deftest
    proofread-release-test-prepares-and-installs-single-package-releases ()
  "Release preparation creates installable per-package handoffs."
  (let* ((directory
          (make-temp-file "proofread-release-integration-" t))
         (previous (expand-file-name "previous.json" directory))
         (dependencies-file
          (expand-file-name "dependencies.json" directory))
         (core-output (expand-file-name "core-handoff" directory))
         (addon-output (expand-file-name "addon-handoff" directory))
         (core-name "proofread-release-fixture-core")
         (addon-name "proofread-release-fixture-addon")
         (core
          (proofread-release-test--create-archive
           directory core-name "1.0.0"
           '((emacs "30.1"))
           "(message \"core loaded\")"))
         (addon
          (proofread-release-test--create-archive
           directory addon-name "1.1.0"
           `((emacs "30.1") (,(intern core-name) "1.0.0"))
           (format "(require '%s)" core-name))))
    (unwind-protect
        (progn
          (proofread-release-bootstrap previous)
          (proofread-release-prepare-package
           core-name
           "1.0.0"
           (format "%s-v1.0.0" core-name)
           proofread-release-test--commit
           previous
           core-output
           core
           nil)
          (let ((core-manifest
                 (expand-file-name "assets/manifest.json" core-output)))
            (should
             (equal
              (proofread-release-test--read-lines
               (expand-file-name "expected-assets.txt" core-output))
              (sort
               (list "manifest.json"
                     (format "%s-1.0.0.tar" core-name))
               #'string<)))
            (should-not
             (file-exists-p
              (expand-file-name "assets/SHA256SUMS" core-output)))
            (should
             (proofread-release-verify-install
              core-manifest
              (list core)))
            (should
             (equal
              (mapcar
               #'proofread-release--package-name
               (proofread-release-required-dependencies
                addon-name
                "1.1.0"
                (format "%s-v1.1.0" addon-name)
                core-manifest
                addon
                dependencies-file))
              (list core-name)))
            (proofread-release-prepare-package
             addon-name
             "1.1.0"
             (format "%s-v1.1.0" addon-name)
             proofread-release-test--other-commit
             core-manifest
             addon-output
             addon
             (list core)))
          (let ((addon-manifest
                 (expand-file-name "assets/manifest.json" addon-output)))
            (should
             (equal
              (proofread-release-test--read-lines
               (expand-file-name "expected-assets.txt" addon-output))
              (sort
               (list "manifest.json"
                     (format "%s-1.1.0.tar" addon-name))
               #'string<)))
            (should-not
             (file-exists-p
              (expand-file-name "assets/SHA256SUMS" addon-output)))
            (should
             (proofread-release-verify-install
              addon-manifest
              (list core addon)))))
      (delete-directory directory t))))

(ert-deftest
    proofread-release-test-rejects-core-incompatible-with-released-popup ()
  "Reverse verification loads the released popup against a new core."
  (let* ((directory
          (make-temp-file "proofread-release-reverse-broken-" t))
         (core-name "proofread-release-fixture-broken-core")
         (popup-name "proofread-release-fixture-broken-popup")
         (current-api (intern (format "%s-current-api" core-name)))
         (legacy-api (intern (format "%s-legacy-api" core-name)))
         (core-archive
          (proofread-release-test--create-archive
           directory core-name "2.0.0"
           '((emacs "30.1"))
           (format "(defun %s () t)" current-api)))
         (popup-archive
          (proofread-release-test--create-archive
           directory popup-name "1.0.0"
           `((emacs "30.1") (,(intern core-name) "1.0.0"))
           (format
            "(require '%s)\n(funcall (intern %S))"
            core-name (symbol-name legacy-api))))
         (core
          (proofread-release-test--archive-package
           core-archive
           (format "%s-v2.0.0" core-name)
           proofread-release-test--other-commit))
         (popup
          (proofread-release-test--archive-package
           popup-archive (format "%s-v1.0.0" popup-name)))
         (manifest
          (proofread-release-test--write-manifest
           directory core (list core popup))))
    (unwind-protect
        (let ((condition
               (should-error
                (proofread-release-verify-install
                 manifest (list popup-archive core-archive)))))
          (should
           (string-match-p
            (regexp-quote (symbol-name legacy-api))
            (error-message-string condition)))
          (should
           (string-match-p
            (regexp-quote popup-name)
            (error-message-string condition))))
      (when (fboundp current-api)
        (fmakunbound current-api))
      (when (fboundp legacy-api)
        (fmakunbound legacy-api))
      (delete-directory directory t))))

(ert-deftest
    proofread-release-test-verifies-corrected-core-and-popup-releases ()
  "Corrected core and popup releases pass reverse and forward checks."
  (let* ((directory
          (make-temp-file "proofread-release-reverse-fixed-" t))
         (core-name "proofread-release-fixture-fixed-core")
         (alpha-name "proofread-release-fixture-alpha-popup")
         (zeta-name "proofread-release-fixture-zeta-popup")
         (current-api (intern (format "%s-current-api" core-name)))
         (legacy-api (intern (format "%s-legacy-api" core-name)))
         (core-archive
          (proofread-release-test--create-archive
           directory core-name "2.0.0"
           '((emacs "30.1"))
           (proofread-release-test--recording-body
            'core
            (format
             "(defun %s () t)\n(defun %s () (%s))"
             current-api legacy-api current-api))))
         (alpha-archive
          (proofread-release-test--create-archive
           directory alpha-name "1.0.0"
           `((emacs "30.1") (,(intern core-name) "1.0.0"))
           (proofread-release-test--recording-body
            'alpha
            (format "(require '%s)\n(%s)" core-name legacy-api))))
         (zeta-archive
          (proofread-release-test--create-archive
           directory zeta-name "1.0.0"
           `((emacs "30.1") (,(intern core-name) "1.0.0"))
           (proofread-release-test--recording-body
            'zeta
            (format "(require '%s)\n(%s)" core-name legacy-api))))
         (alpha-candidate-archive
          (proofread-release-test--create-archive
           directory alpha-name "1.1.0"
           `((emacs "30.1") (,(intern core-name) "2.0.0"))
           (proofread-release-test--recording-body
            'alpha
            (format "(require '%s)\n(%s)" core-name current-api))))
         (old-core
          (proofread-release-test--package
           core-name "1.0.0" ?c '(("emacs" . "30.1"))))
         (alpha
          (proofread-release-test--archive-package
           alpha-archive (format "%s-v1.0.0" alpha-name)))
         (zeta
          (proofread-release-test--archive-package
           zeta-archive (format "%s-v1.0.0" zeta-name))))
    (unwind-protect
        (let ((previous-file
               (expand-file-name "legacy-manifest.json" directory))
              (verification-file
               (expand-file-name "verification-packages.json" directory))
              (core-output
               (expand-file-name "core-handoff" directory))
              (popup-output
               (expand-file-name "popup-handoff" directory)))
          (proofread-release--write-json
           (proofread-release-test--legacy-manifest
            "v1.0.0"
            proofread-release-test--commit
            (list zeta old-core alpha))
           previous-file)
          (should
           (equal
            (mapcar
             #'proofread-release--package-name
             (proofread-release-verification-packages
              core-name
              "2.0.0"
              (format "%s-v2.0.0" core-name)
              previous-file
              core-archive
              verification-file))
            (list alpha-name zeta-name)))
          (should (file-exists-p verification-file))
          (proofread-release-prepare-package
           core-name
           "2.0.0"
           (format "%s-v2.0.0" core-name)
           proofread-release-test--other-commit
           previous-file
           core-output
           core-archive
           (list zeta-archive alpha-archive))
          (let ((core-manifest
                 (expand-file-name "assets/manifest.json" core-output)))
            (setq proofread-release-test--load-order nil)
            (should
             (proofread-release-verify-install
              core-manifest
              (list zeta-archive core-archive alpha-archive)))
            (should
             (equal proofread-release-test--load-order
                    '(core alpha zeta)))
            (proofread-release-prepare-package
             alpha-name
             "1.1.0"
             (format "%s-v1.1.0" alpha-name)
             proofread-release-test--commit
             core-manifest
             popup-output
             alpha-candidate-archive
             (list core-archive)))
          (let ((popup-manifest
                 (expand-file-name "assets/manifest.json" popup-output)))
            (setq proofread-release-test--load-order nil)
            (should
             (proofread-release-verify-install
              popup-manifest
              (list alpha-candidate-archive core-archive)))
            (should
             (equal proofread-release-test--load-order '(core alpha)))))
      (setq proofread-release-test--load-order nil)
      (when (fboundp current-api)
        (fmakunbound current-api))
      (when (fboundp legacy-api)
        (fmakunbound legacy-api))
      (delete-directory directory t))))

(ert-deftest
    proofread-release-test-reports-invalid-reverse-dependency-archives ()
  "Reverse verification diagnoses missing, changed, and extra archives."
  (let* ((directory
          (make-temp-file "proofread-release-reverse-archives-" t))
         (changed-directory
          (make-temp-file "proofread-release-reverse-changed-" t))
         (core-name "proofread-release-fixture-archive-core")
         (popup-name "proofread-release-fixture-archive-popup")
         (extra-name "proofread-release-fixture-extra-popup")
         (legacy-api (intern (format "%s-legacy-api" core-name)))
         (core-archive
          (proofread-release-test--create-archive
           directory core-name "2.0.0"
           '((emacs "30.1"))
           (format "(defun %s () t)" legacy-api)))
         (popup-requires
          `((emacs "30.1") (,(intern core-name) "1.0.0")))
         (popup-archive
          (proofread-release-test--create-archive
           directory popup-name "1.0.0" popup-requires
           (format "(require '%s)\n(%s)" core-name legacy-api)))
         (changed-popup-archive
          (proofread-release-test--create-archive
           changed-directory popup-name "1.0.0" popup-requires
           (format
            "(require '%s)\n(%s)\n(message \"changed\")"
            core-name legacy-api)))
         (extra-archive
          (proofread-release-test--create-archive
           directory extra-name "1.0.0"
           '((emacs "30.1"))
           "(message \"extra\")"))
         (core
          (proofread-release-test--archive-package
           core-archive
           (format "%s-v2.0.0" core-name)
           proofread-release-test--other-commit))
         (popup
          (proofread-release-test--archive-package
           popup-archive (format "%s-v1.0.0" popup-name)))
         (manifest
          (proofread-release-test--write-manifest
           directory core (list core popup))))
    (unwind-protect
        (let ((missing
               (should-error
                (proofread-release-verify-install
                 manifest (list core-archive))))
              (changed
               (should-error
                (proofread-release-verify-install
                 manifest (list core-archive changed-popup-archive))))
              (extra
               (should-error
                (proofread-release-verify-install
                 manifest
                 (list core-archive popup-archive extra-archive)))))
          (should
           (string-match-p
            (regexp-quote popup-name) (error-message-string missing)))
          (should
           (string-match-p
            (regexp-quote popup-name) (error-message-string changed)))
          (should
           (string-match-p
            (regexp-quote extra-name) (error-message-string extra))))
      (when (fboundp legacy-api)
        (fmakunbound legacy-api))
      (delete-directory directory t)
      (delete-directory changed-directory t))))

(provide 'proofread-release-tests)
;;; proofread-release-tests.el ends here
