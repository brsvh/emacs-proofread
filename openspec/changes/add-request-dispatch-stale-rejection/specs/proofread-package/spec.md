## ADDED Requirements

### Requirement: Request dispatch from visible chunks

The system SHALL dispatch request-ready visible chunks through the configured
backend protocol.

#### Scenario: Visible check dispatches request-ready chunks

- **WHEN** `proofread-check-visible` is invoked in a buffer with
  `proofread-mode` enabled and an available backend configured
- **THEN** proofread collects the current visible ranges
- **AND** proofread builds request-ready chunks from those ranges
- **AND** proofread dispatches chunk-level backend requests for those chunks

#### Scenario: Active requests are buffer-local

- **WHEN** proofread dispatches backend requests in a buffer
- **THEN** each in-flight request is recorded in that buffer's active request
  state
- **AND** active requests from another buffer are not mixed with that state

#### Scenario: Request snapshot records stale-check metadata

- **WHEN** proofread dispatches a backend request for a chunk
- **THEN** the request snapshot contains the buffer, range boundaries, chunk
  text, `major-mode`, language, and `buffer-chars-modified-tick`
- **AND** the snapshot is sufficient to validate the callback result before
  applying diagnostics

### Requirement: Fresh backend result application

The system SHALL apply backend diagnostics only after validating that the
request still matches the current buffer state.

#### Scenario: Fresh successful diagnostics are accepted

- **WHEN** a successful backend result containing diagnostics returns for a live
  buffer where `proofread-mode` is still enabled
- **AND** the buffer modified tick matches the request snapshot
- **AND** the request range is still valid
- **AND** the buffer text at the request range still equals the request text
- **THEN** proofread records the result diagnostics in proofread-owned state
- **AND** proofread creates proofread-owned overlays for those diagnostics

#### Scenario: Backend error result does not modify buffer text

- **WHEN** a backend request completes with an error result
- **THEN** proofread removes the active request entry for that request
- **AND** proofread does not modify buffer text
- **AND** proofread does not create diagnostic overlays from the error result

### Requirement: Stale backend result rejection

The system SHALL reject backend results that no longer match the originating
buffer state.

#### Scenario: Killed buffer rejects result

- **WHEN** a backend result returns after the originating buffer has been killed
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** no buffer-local proofread state is recreated for the killed buffer

#### Scenario: Disabled mode rejects result

- **WHEN** a backend result returns after `proofread-mode` has been disabled in
  the originating buffer
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** no proofread-owned buffer state is changed

#### Scenario: Modified tick rejects result

- **WHEN** a backend result returns after the originating buffer's
  `buffer-chars-modified-tick` differs from the request snapshot
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** proofread-owned diagnostic state is not updated from that result

#### Scenario: Text mismatch rejects result

- **WHEN** a backend result returns while the originating buffer is live and
  `proofread-mode` is enabled
- **AND** the buffer text at the request range no longer equals the request text
- **THEN** proofread drops the result
- **AND** no proofread overlay is created
- **AND** proofread-owned diagnostic state is not updated from that result

#### Scenario: Stale result cleanup removes active request

- **WHEN** proofread rejects a stale backend result for a live buffer
- **THEN** the active request entry for that request is removed
- **AND** no stale request entry remains for the rejected result
