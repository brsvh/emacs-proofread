.DELETE_ON_ERROR:
.ONESHELL:

SHELL := /bin/sh

# Tools and paths.
EMACS ?= emacs
EMACS_BATCH := $(EMACS) -Q --batch

BUILD_FILE := Makefile
DIST_DIR := dist
LISP_DIR := lisp

# Core package files.
PROOFREAD_LISP_FILES := $(LISP_DIR)/proofread.el
PROOFREAD_MAIN := $(firstword $(PROOFREAD_LISP_FILES))
PROOFREAD_ELC_FILES := $(PROOFREAD_LISP_FILES:.el=.elc)
PROOFREAD_PKG := $(LISP_DIR)/proofread-pkg.el
PROOFREAD_AUTOLOADS := $(LISP_DIR)/proofread-autoloads.el
PROOFREAD_ARCHIVE_STAMP := $(DIST_DIR)/.proofread-archive

# Popup package files.
PROOFREAD_POPUP_LISP_FILES := $(LISP_DIR)/proofread-popup.el
PROOFREAD_POPUP_MAIN := \
	$(firstword $(PROOFREAD_POPUP_LISP_FILES))
PROOFREAD_POPUP_ELC_FILES := \
	$(PROOFREAD_POPUP_LISP_FILES:.el=.elc)
PROOFREAD_POPUP_PKG := $(LISP_DIR)/proofread-popup-pkg.el
PROOFREAD_POPUP_AUTOLOADS := \
	$(LISP_DIR)/proofread-popup-autoloads.el
PROOFREAD_POPUP_ARCHIVE_STAMP := \
	$(DIST_DIR)/.proofread-popup-archive

# Generated files.
PKG_FILES := $(PROOFREAD_PKG) $(PROOFREAD_POPUP_PKG)
AUTOLOAD_FILES := \
	$(PROOFREAD_AUTOLOADS) \
	$(PROOFREAD_POPUP_AUTOLOADS)
ELC_FILES := \
	$(PROOFREAD_ELC_FILES) \
	$(PROOFREAD_POPUP_ELC_FILES)
ARCHIVE_STAMPS := \
	$(PROOFREAD_ARCHIVE_STAMP) \
	$(PROOFREAD_POPUP_ARCHIVE_STAMP)
GENERATED_FILES := $(PKG_FILES) $(AUTOLOAD_FILES) $(ELC_FILES)

# Batch Emacs expressions.
# bake-format off
define GENERATE_PKG_ELISP
(progn
  (require (quote package))
  (let ((source
         (expand-file-name (getenv "PACKAGE_SOURCE")))
        (output
         (expand-file-name (getenv "PACKAGE_OUTPUT"))))
    (with-current-buffer (find-file-noselect source)
      (package-generate-description-file
       (package-buffer-info)
       output))))
endef

define GENERATE_AUTOLOADS_ELISP
(progn
  (require (quote package))
  (package-generate-autoloads
   (getenv "PACKAGE_NAME")
   (getenv "PACKAGE_DIR")))
endef

define PACKAGE_VERSION_ELISP
(progn
  (require (quote package))
  (with-current-buffer
      (find-file-noselect
       (expand-file-name (getenv "PACKAGE_SOURCE")))
    (princ
     (package-version-join
      (package-desc-version
       (package-buffer-info))))))
endef

define CHECK_ARCHIVE_ELISP
(progn
  (require (quote package))
  (let ((archive (getenv "PACKAGE_ARCHIVE"))
        (name (intern (getenv "PACKAGE_NAME")))
        (version (getenv "PACKAGE_VERSION")))
    (with-current-buffer (find-file-noselect archive)
      (let ((desc (package-tar-file-info)))
        (unless
            (and
             (eq (package-desc-name desc) name)
             (equal
              (package-version-join
               (package-desc-version desc))
              version))
          (error "Archive metadata mismatch"))))))
endef
# bake-format on

.PHONY: \
	all \
	clean \
	proofread \
	proofread-pkg \
	proofread-autoloads \
	proofread-compile \
	proofread-archive \
	proofread-popup \
	proofread-popup-pkg \
	proofread-popup-autoloads \
	proofread-popup-compile \
	proofread-popup-archive

all: proofread proofread-popup

proofread: \
	proofread-pkg \
	proofread-autoloads \
	proofread-compile \
	proofread-archive

proofread-pkg: $(PROOFREAD_PKG)

proofread-autoloads: $(PROOFREAD_AUTOLOADS)

proofread-compile: $(PROOFREAD_ELC_FILES)

proofread-archive: $(PROOFREAD_ARCHIVE_STAMP)

proofread-popup: \
	proofread-popup-pkg \
	proofread-popup-autoloads \
	proofread-popup-compile \
	proofread-popup-archive

proofread-popup-pkg: $(PROOFREAD_POPUP_PKG)

proofread-popup-autoloads: $(PROOFREAD_POPUP_AUTOLOADS)

proofread-popup-compile: $(PROOFREAD_POPUP_ELC_FILES)

proofread-popup-archive: $(PROOFREAD_POPUP_ARCHIVE_STAMP)

$(PROOFREAD_PKG): $(PROOFREAD_MAIN) $(BUILD_FILE)
$(PROOFREAD_POPUP_PKG): $(PROOFREAD_POPUP_MAIN) $(BUILD_FILE)

$(PKG_FILES):
	@env \
		PACKAGE_SOURCE="$<" \
		PACKAGE_OUTPUT="$@" \
		$(EMACS_BATCH) \
		--eval '$(GENERATE_PKG_ELISP)'

$(PROOFREAD_AUTOLOADS): \
	$(PROOFREAD_LISP_FILES) \
	$(BUILD_FILE)
$(PROOFREAD_POPUP_AUTOLOADS): \
	$(PROOFREAD_POPUP_LISP_FILES) \
	$(BUILD_FILE)

$(AUTOLOAD_FILES):
	@set -eu
	package_name="$(patsubst %-autoloads.el,%,$(notdir $@))"
	temp_dir=$$(mktemp -d)
	trap 'rm -rf "$$temp_dir"' EXIT HUP INT TERM
	cp $(filter %.el,$^) "$$temp_dir/"
	env \
		PACKAGE_DIR="$$temp_dir" \
		PACKAGE_NAME="$$package_name" \
		$(EMACS_BATCH) \
		--eval '$(GENERATE_AUTOLOADS_ELISP)'
	cp "$$temp_dir/$${package_name}-autoloads.el" "$@"

$(PROOFREAD_ELC_FILES) &: \
	$(PROOFREAD_LISP_FILES) \
	$(BUILD_FILE)
	$(EMACS_BATCH) -L $(LISP_DIR) \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(PROOFREAD_LISP_FILES)

$(PROOFREAD_POPUP_ELC_FILES) &: \
	$(PROOFREAD_POPUP_LISP_FILES) \
	$(PROOFREAD_ELC_FILES) \
	$(BUILD_FILE)
	$(EMACS_BATCH) -L $(LISP_DIR) \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(PROOFREAD_POPUP_LISP_FILES)

$(PROOFREAD_ARCHIVE_STAMP): \
	$(PROOFREAD_LISP_FILES) \
	$(PROOFREAD_PKG) \
	COPYING \
	$(BUILD_FILE)
$(PROOFREAD_POPUP_ARCHIVE_STAMP): \
	$(PROOFREAD_POPUP_LISP_FILES) \
	$(PROOFREAD_POPUP_PKG) \
	COPYING \
	$(BUILD_FILE)

$(ARCHIVE_STAMPS):
	@set -eu
	package_name="$(patsubst .%-archive,%,$(notdir $@))"
	version=$$(env \
		PACKAGE_SOURCE="$<" \
		$(EMACS_BATCH) \
		--eval '$(PACKAGE_VERSION_ELISP)')
	package_dir="$${package_name}-$${version}"
	archive="$(DIST_DIR)/$${package_dir}.tar"
	temp_dir=$$(mktemp -d)
	trap 'rm -rf "$$temp_dir"' EXIT HUP INT TERM
	mkdir -p "$$temp_dir/$$package_dir" "$(DIST_DIR)"
	cp $(filter %.el,$^) "$$temp_dir/$$package_dir/"
	cp COPYING "$$temp_dir/$$package_dir/"
	chmod -R u=rwX,go=rX "$$temp_dir/$$package_dir"
	tar \
		--sort=name \
		--mtime=@0 \
		--owner=0 \
		--group=0 \
		--numeric-owner \
		-cf "$$temp_dir/$${package_dir}.tar" \
		-C "$$temp_dir" \
		"$$package_dir"
	env \
		PACKAGE_ARCHIVE="$$temp_dir/$${package_dir}.tar" \
		PACKAGE_NAME="$$package_name" \
		PACKAGE_VERSION="$$version" \
		$(EMACS_BATCH) \
		--eval '$(CHECK_ARCHIVE_ELISP)'
	old_archive=
	if test -f "$@"; then
		IFS= read -r old_archive < "$@" || :
	fi
	mv "$$temp_dir/$${package_dir}.tar" "$$archive"
	if test -n "$$old_archive" \
		&& test "$$old_archive" != "$$archive"; then
		$(RM) "$$old_archive"
	fi
	printf '%s\n' "$$archive" > "$@"
	printf 'Created %s\n' "$$archive"

clean:
	$(RM) $(GENERATED_FILES)
	rm -rf "$(DIST_DIR)"