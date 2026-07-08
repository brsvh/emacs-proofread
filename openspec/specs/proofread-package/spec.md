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
