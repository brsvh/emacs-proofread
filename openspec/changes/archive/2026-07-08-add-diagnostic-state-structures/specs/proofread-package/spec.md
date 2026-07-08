## ADDED Requirements

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
