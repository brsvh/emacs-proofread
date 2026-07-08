## ADDED Requirements

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
