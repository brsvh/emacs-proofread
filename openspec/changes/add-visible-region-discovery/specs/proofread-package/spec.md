## ADDED Requirements

### Requirement: Visible range discovery

The system SHALL collect normalized visible text ranges for the current buffer
when `proofread-check-visible` is invoked.

#### Scenario: Single visible window range is collected

- **WHEN** `proofread-check-visible` is invoked in a buffer displayed by one
  live window
- **THEN** proofread pending range state contains the visible range from that
  window
- **AND** no backend request, timer, cache entry, or diagnostic overlay is
  created

#### Scenario: Multiple visible window ranges are deduplicated

- **WHEN** `proofread-check-visible` is invoked in a buffer displayed by
  multiple live windows
- **THEN** proofread pending range state contains sorted visible ranges for that
  buffer
- **AND** overlapping or adjacent ranges are merged so the same text is not
  represented more than once

#### Scenario: No visible window produces no ranges

- **WHEN** `proofread-check-visible` is invoked in a buffer that is not
  displayed by any live window
- **THEN** proofread pending range state is empty
- **AND** the command does not fall back to the whole buffer

#### Scenario: Invisible buffer text is not scanned

- **WHEN** `proofread-check-visible` is invoked in a large buffer with only part
  of the buffer visible
- **THEN** proofread range discovery uses live window boundaries for the current
  buffer
- **AND** text outside the collected visible ranges is not traversed for
  proofreading work by this command
