## ADDED Requirements

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
