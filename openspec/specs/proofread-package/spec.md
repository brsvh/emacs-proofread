## Purpose

Define the initial loadable Emacs Lisp package surface for `proofread-mode`.

## Requirements

### Requirement: Loadable proofread package

The system SHALL provide a loadable Emacs Lisp package file at
`lisp/proofread.el`.

#### Scenario: Package loads in batch Emacs

- **WHEN** Emacs is run in batch mode with `lisp` on `load-path`
- **THEN** requiring `proofread` succeeds without errors

#### Scenario: Package provides feature

- **WHEN** `proofread.el` is loaded
- **THEN** the `proofread` feature is provided

### Requirement: Buffer-local proofread minor mode

The system SHALL define `proofread-mode` as a buffer-local minor mode.

#### Scenario: Enable mode in a text buffer

- **WHEN** `proofread-mode` is enabled in a buffer
- **THEN** the mode is active in that buffer

#### Scenario: Disable mode in a text buffer

- **WHEN** `proofread-mode` is disabled in a buffer where it is active
- **THEN** the mode is no longer active in that buffer

#### Scenario: Enabling mode has no proofreading side effects

- **WHEN** `proofread-mode` is enabled in a buffer containing text
- **THEN** the buffer text remains unchanged
- **AND** no proofread overlays, timers, requests, or cache entries are created

### Requirement: Public command surface

The system SHALL define interactive command entry points for the planned
proofreading workflow.

#### Scenario: Public commands are interactive

- **WHEN** the package is loaded
- **THEN** `proofread-check-visible`, `proofread-check-buffer`,
  `proofread-next`, `proofread-previous`, `proofread-describe`,
  `proofread-apply-suggestion`, `proofread-ignore`, and `proofread-clear` are
  interactive commands

#### Scenario: Placeholder commands do not modify text

- **WHEN** any placeholder command is invoked in a text buffer
- **THEN** the command reports that behavior is not implemented yet
- **AND** the buffer text remains unchanged

### Requirement: Diagnostic plist representation

The system SHALL represent proofread diagnostics as structured plist data that
can exist independently from overlay objects.

#### Scenario: Diagnostic contains required fields

- **WHEN** proofread code constructs a diagnostic
- **THEN** the diagnostic can contain `:beg`, `:end`, `:text`, `:kind`,
  `:message`, `:suggestions`, `:confidence`, and `:source`

#### Scenario: Diagnostic does not require overlay ownership

- **WHEN** a diagnostic is created before display behavior exists
- **THEN** the diagnostic remains usable without requiring an overlay object

### Requirement: Buffer-local proofread state

The system SHALL maintain proofread-owned state separately for each buffer where
`proofread-mode` is enabled.

#### Scenario: Enabling mode initializes proofread state

- **WHEN** `proofread-mode` is enabled in a buffer
- **THEN** proofread-owned buffer-local state is initialized for diagnostics,
  overlays, pending ranges, requests, and cache

#### Scenario: State does not leak across buffers

- **WHEN** `proofread-mode` is enabled in two buffers
- **THEN** each buffer has independent proofread-owned state

#### Scenario: Disabling mode clears proofread state

- **WHEN** `proofread-mode` is disabled in a buffer
- **THEN** proofread-owned buffer-local diagnostics, overlays, pending ranges,
  requests, and cache state are cleared in that buffer

#### Scenario: Disabling mode preserves unrelated state

- **WHEN** `proofread-mode` is disabled in a buffer that has unrelated mode
  state or overlays
- **THEN** only proofread-owned buffer-local state is cleared

### Requirement: Theme-compatible proofread faces

The system SHALL define package-owned faces for normal and current proofread
diagnostics without hard-coded color values or spelling-package face reuse.

#### Scenario: Proofread faces are available

- **WHEN** the package is loaded
- **THEN** `proofread-face` is a defined face
- **AND** `proofread-current-face` is a defined face

#### Scenario: Proofread faces avoid fixed colors

- **WHEN** the default face specifications are inspected
- **THEN** they do not hard-code color values
- **AND** they do not reuse another spelling or diagnostic package's face as the
  proofread face

### Requirement: Proofread-owned diagnostic overlays

The system SHALL display diagnostics using proofread-owned overlays that remain
separate from the canonical diagnostic data.

#### Scenario: Overlay stores diagnostic metadata

- **WHEN** proofread creates an overlay for a diagnostic
- **THEN** the overlay has category `proofread-overlay`
- **AND** the overlay stores the diagnostic in its `proofread-diagnostic`
  property
- **AND** the diagnostic remains available outside the overlay object

#### Scenario: Overlay display is isolated from other packages

- **WHEN** proofread creates an overlay
- **THEN** the overlay does not reuse another spelling or diagnostic package's
  category, keymap, face, or modification hook

### Requirement: Proofread overlay cleanup

The system SHALL clear only proofread-owned overlays in the current buffer.

#### Scenario: Clear deletes proofread overlays

- **WHEN** `proofread-clear` is invoked in a buffer containing proofread-owned
  overlays
- **THEN** proofread-owned overlays in that buffer are deleted
- **AND** proofread overlay state for that buffer is cleared

#### Scenario: Clear preserves unrelated overlays

- **WHEN** `proofread-clear` is invoked in a buffer containing overlays from
  another package or category
- **THEN** unrelated overlays remain live

### Requirement: Proofread overlay edit invalidation

The system SHALL remove or invalidate proofread-owned overlays when their
covered text is modified.

#### Scenario: Editing covered text invalidates proofread overlay

- **WHEN** text covered by a proofread-owned overlay is modified
- **THEN** that overlay is deleted or marked invalid
- **AND** no backend request is scheduled by the modification hook

#### Scenario: Editing covered text preserves unrelated overlays

- **WHEN** text covered by an unrelated overlay is modified
- **THEN** proofread overlay invalidation does not delete that unrelated overlay
