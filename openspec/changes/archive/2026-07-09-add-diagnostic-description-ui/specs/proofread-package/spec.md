## ADDED Requirements

### Requirement: Diagnostic lookup at point

The system SHALL find proofread-owned diagnostics that cover point in the
current buffer.

#### Scenario: Diagnostic at point is found

- **WHEN** point is inside the range of a proofread-owned diagnostic
- **THEN** proofread identifies that diagnostic as the diagnostic at point

#### Scenario: Overlapping diagnostics use stable order

- **WHEN** multiple proofread-owned diagnostics cover point
- **THEN** proofread selects the first covering diagnostic in navigation order
- **AND** navigation order is sorted by `:beg` and then `:end`

#### Scenario: Foreign overlays are ignored

- **WHEN** point is inside an overlay not owned by proofread
- **AND** no proofread-owned diagnostic covers point
- **THEN** proofread does not treat that foreign overlay as a diagnostic at
  point

### Requirement: Diagnostic description command

The system SHALL implement `proofread-describe` for the proofread-owned
diagnostic at point.

#### Scenario: Describe shows diagnostic details

- **WHEN** `proofread-describe` is invoked with point on a proofread-owned
  diagnostic
- **THEN** proofread displays the diagnostic kind
- **AND** proofread displays the diagnostic message
- **AND** proofread displays the original diagnostic text
- **AND** proofread displays suggestions when present
- **AND** proofread displays confidence when present
- **AND** proofread displays source when present

#### Scenario: Describe does not modify source buffer

- **WHEN** `proofread-describe` is invoked with point on a proofread-owned
  diagnostic
- **THEN** the source buffer text remains unchanged
- **AND** proofread-owned diagnostics and overlays in the source buffer remain
  unchanged

#### Scenario: Describe reports no diagnostic at point

- **WHEN** `proofread-describe` is invoked and no proofread-owned diagnostic
  covers point
- **THEN** point remains unchanged
- **AND** proofread reports that there is no proofread diagnostic at point

### Requirement: Diagnostic description formatting

The system SHALL format diagnostic descriptions using stable package-level
diagnostic fields.

#### Scenario: Missing optional fields are handled

- **WHEN** `proofread-describe` displays a diagnostic that lacks optional fields
  such as suggestions, confidence, or source
- **THEN** proofread displays the available diagnostic information
- **AND** proofread does not signal an error because those optional fields are
  missing

#### Scenario: Suggestions keep stored order

- **WHEN** a diagnostic contains multiple suggestions
- **THEN** `proofread-describe` displays those suggestions in the same order as
  stored in the diagnostic

#### Scenario: Description avoids backend-private structures

- **WHEN** `proofread-describe` formats a diagnostic
- **THEN** the displayed description is derived from package-level diagnostic
  fields
- **AND** the display logic does not depend on backend-private result structures
