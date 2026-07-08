## ADDED Requirements

### Requirement: Diagnostic navigation ordering

The system SHALL provide deterministic ordering for proofread-owned diagnostics
in the current buffer.

#### Scenario: Diagnostics are sorted by range

- **WHEN** proofread sorts diagnostics for navigation
- **THEN** diagnostics are ordered by `:beg` position
- **AND** diagnostics with the same `:beg` are ordered by `:end` position

#### Scenario: Invalid ranges are ignored for navigation

- **WHEN** proofread prepares diagnostics for navigation
- **AND** a diagnostic has missing, invalid, or non-position range data
- **THEN** that diagnostic is not used as a navigation target
- **AND** navigation continues to use valid proofread-owned diagnostics

### Requirement: Current-buffer diagnostic navigation

The system SHALL implement `proofread-next` and `proofread-previous` for
proofread-owned diagnostics in the current buffer.

#### Scenario: Next moves to diagnostic after point

- **WHEN** `proofread-next` is invoked with point before a later proofread
  diagnostic
- **THEN** point moves to the beginning of the nearest later proofread
  diagnostic
- **AND** buffer text remains unchanged

#### Scenario: Previous moves to diagnostic before point

- **WHEN** `proofread-previous` is invoked with point after an earlier proofread
  diagnostic
- **THEN** point moves to the beginning of the nearest earlier proofread
  diagnostic
- **AND** buffer text remains unchanged

#### Scenario: Navigation ignores foreign overlays

- **WHEN** the current buffer contains overlays not owned by proofread
- **THEN** `proofread-next` and `proofread-previous` do not navigate to those
  overlays
- **AND** only proofread-owned diagnostics are used as targets

### Requirement: Diagnostic navigation boundaries

The system SHALL use one no-wrap boundary policy for diagnostic navigation.

#### Scenario: Empty diagnostics report no target

- **WHEN** `proofread-next` or `proofread-previous` is invoked in a buffer with
  no proofread-owned diagnostics
- **THEN** point remains unchanged
- **AND** proofread reports that there is no proofread diagnostic to navigate to

#### Scenario: Next at end reports boundary

- **WHEN** `proofread-next` is invoked with point at or after the last
  proofread-owned diagnostic
- **THEN** point remains unchanged
- **AND** proofread reports that there is no next proofread diagnostic
- **AND** proofread does not wrap to the first diagnostic

#### Scenario: Previous at beginning reports boundary

- **WHEN** `proofread-previous` is invoked with point at or before the first
  proofread-owned diagnostic
- **THEN** point remains unchanged
- **AND** proofread reports that there is no previous proofread diagnostic
- **AND** proofread does not wrap to the last diagnostic

### Requirement: Current diagnostic highlighting

The system SHALL visually distinguish the currently selected proofread
diagnostic without modifying buffer text.

#### Scenario: Navigating marks selected diagnostic current

- **WHEN** `proofread-next` or `proofread-previous` moves to a proofread-owned
  diagnostic
- **THEN** that diagnostic is treated as the current diagnostic
- **AND** its proofread-owned overlay uses `proofread-current-face` or an
  equivalent proofread-owned current diagnostic visual state

#### Scenario: Previous current diagnostic is cleared

- **WHEN** navigation selects a different proofread-owned diagnostic
- **THEN** the previously current diagnostic is no longer visually marked as
  current
- **AND** unrelated overlays remain unchanged
