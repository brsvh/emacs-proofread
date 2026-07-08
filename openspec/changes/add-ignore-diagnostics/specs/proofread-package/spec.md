## ADDED Requirements

### Requirement: Session-local diagnostic ignore keys

The system SHALL maintain an in-memory ignore list for proofread diagnostics in
the current Emacs session.

#### Scenario: Ignore key uses exact text and kind

- **WHEN** proofread builds an ignore key for a diagnostic
- **THEN** the key contains the diagnostic original text
- **AND** the key contains the diagnostic kind
- **AND** no other diagnostic fields are required for the key

#### Scenario: Exact text and kind match ignored entry

- **WHEN** a diagnostic has the same original text and kind as an ignored
  diagnostic
- **THEN** proofread treats that diagnostic as ignored for the current session

#### Scenario: Different kind does not match ignored entry

- **WHEN** a diagnostic has the same original text as an ignored diagnostic but
  a different kind
- **THEN** proofread does not treat that diagnostic as ignored by that entry

#### Scenario: Different text does not match ignored entry

- **WHEN** a diagnostic has the same kind as an ignored diagnostic but different
  original text
- **THEN** proofread does not treat that diagnostic as ignored by that entry

### Requirement: Ignore command

The system SHALL implement `proofread-ignore` for proofread-owned diagnostics at
point.

#### Scenario: Ignoring diagnostic records ignore entry

- **WHEN** `proofread-ignore` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread records an in-memory ignore entry for that diagnostic's
  exact text and kind

#### Scenario: Ignoring diagnostic removes matching proofread overlay

- **WHEN** `proofread-ignore` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread removes or invalidates the corresponding proofread-owned
  overlay in the current buffer
- **AND** buffer text remains unchanged

#### Scenario: Ignoring does not remove unrelated diagnostics

- **WHEN** `proofread-ignore` is invoked for one proofread-owned diagnostic
- **THEN** proofread does not remove unrelated proofread diagnostics with
  different text or kind

#### Scenario: Ignoring preserves foreign overlays

- **WHEN** `proofread-ignore` removes or invalidates proofread-owned overlays
- **THEN** overlays not owned by proofread remain live

#### Scenario: No diagnostic at point reports no target

- **WHEN** `proofread-ignore` is invoked and no proofread-owned diagnostic
  covers point
- **THEN** proofread reports that there is no proofread diagnostic at point
- **AND** buffer text remains unchanged

### Requirement: Ignored diagnostic display filtering

The system SHALL filter ignored diagnostics before creating proofread-owned
overlays.

#### Scenario: Ignored diagnostic is not displayed again

- **WHEN** proofread is about to display diagnostics
- **AND** a diagnostic has the same exact text and kind as an ignored entry
- **THEN** proofread filters out that diagnostic before overlay creation
- **AND** no proofread-owned overlay is created for that ignored diagnostic

#### Scenario: Different kind remains displayable

- **WHEN** proofread is about to display a diagnostic with the same text as an
  ignored entry but a different kind
- **THEN** proofread does not filter out that diagnostic because of the ignored
  entry
- **AND** the diagnostic remains eligible for proofread overlay creation

#### Scenario: Different text remains displayable

- **WHEN** proofread is about to display a diagnostic with the same kind as an
  ignored entry but different text
- **THEN** proofread does not filter out that diagnostic because of the ignored
  entry
- **AND** the diagnostic remains eligible for proofread overlay creation
