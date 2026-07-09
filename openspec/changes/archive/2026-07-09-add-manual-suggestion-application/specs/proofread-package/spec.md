## ADDED Requirements

### Requirement: Manual suggestion selection

The system SHALL allow users to manually choose a suggestion for the
proofread-owned diagnostic at point.

#### Scenario: Single suggestion is selected by command invocation

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with exactly one suggestion
- **THEN** proofread selects that suggestion for application
- **AND** the selection happens only because the user invoked the command

#### Scenario: Multiple suggestions use completion

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with multiple suggestions
- **THEN** proofread prompts the user to choose one suggestion through
  completion
- **AND** completion candidates preserve the diagnostic's suggestion order

#### Scenario: No suggestion reports unavailable

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with no suggestions
- **THEN** proofread reports that no suggestion is available
- **AND** buffer text remains unchanged

### Requirement: Suggestion application validation

The system SHALL validate diagnostic state and source text before applying a
suggestion.

#### Scenario: Valid diagnostic text can be replaced

- **WHEN** `proofread-apply-suggestion` is invoked on a proofread-owned
  diagnostic with a selected suggestion
- **AND** the diagnostic has a live proofread-owned overlay
- **AND** the diagnostic range is valid
- **AND** the buffer text in the diagnostic range equals the diagnostic original
  text
- **THEN** proofread replaces only the diagnostic range with the selected
  suggestion

#### Scenario: Stale overlay rejects application

- **WHEN** `proofread-apply-suggestion` is invoked for a diagnostic whose
  proofread-owned overlay is no longer live or valid
- **THEN** proofread refuses to apply the suggestion
- **AND** proofread reports that the diagnostic is stale
- **AND** buffer text remains unchanged

#### Scenario: Text mismatch rejects application

- **WHEN** `proofread-apply-suggestion` is invoked for a diagnostic whose
  current buffer text no longer equals the diagnostic original text
- **THEN** proofread refuses to apply the suggestion
- **AND** proofread reports that the diagnostic text no longer matches
- **AND** buffer text remains unchanged

#### Scenario: Replacement stays within diagnostic range

- **WHEN** proofread applies a selected suggestion
- **THEN** proofread replaces only text between the diagnostic `:beg` and `:end`
  positions
- **AND** text outside that range remains unchanged

### Requirement: Suggestion application cleanup and undo

The system SHALL integrate manual suggestion application with proofread overlay
cleanup and Emacs undo.

#### Scenario: Application creates undo boundary

- **WHEN** proofread applies a selected suggestion
- **THEN** the replacement is recorded as a coherent undoable change
- **AND** undo can restore the original diagnostic text

#### Scenario: Affected proofread overlays are invalidated

- **WHEN** proofread applies a selected suggestion
- **THEN** proofread deletes or marks invalid proofread-owned overlays affected
  by the replaced diagnostic range
- **AND** stale proofread overlays for the replaced text are not left visible

#### Scenario: Foreign overlays are preserved

- **WHEN** proofread applies a selected suggestion in a range that also has
  unrelated overlays
- **THEN** proofread does not delete overlays that are not proofread-owned

#### Scenario: Application is not automatic

- **WHEN** diagnostics are created, described, navigated, cached, or refreshed
- **THEN** proofread does not apply suggestions unless
  `proofread-apply-suggestion` is explicitly invoked
