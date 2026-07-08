## ADDED Requirements

### Requirement: Idle scheduling for proofreading work

The system SHALL schedule visible proofreading work through idle timers instead
of running backend dispatch synchronously during user activity.

#### Scenario: Editing schedules without synchronous backend dispatch

- **WHEN** text is edited in a buffer where `proofread-mode` is enabled
- **THEN** proofread marks that buffer as having pending visible proofreading
  work
- **AND** proofread schedules or reuses an idle timer based on
  `proofread-idle-delay`
- **AND** proofread does not synchronously call the backend from the edit hook

#### Scenario: Window activity schedules visible check

- **WHEN** window activity affects a buffer where `proofread-mode` is enabled
- **THEN** proofread marks that buffer as having pending visible proofreading
  work
- **AND** proofread schedules or reuses an idle timer based on
  `proofread-idle-delay`
- **AND** proofread does not synchronously call the backend from the window
  activity hook

#### Scenario: Idle callback runs scheduled visible check

- **WHEN** the idle timer fires for a live buffer where `proofread-mode` is
  enabled and pending work remains
- **THEN** proofread clears the pending marker for that scheduled work
- **AND** proofread invokes the visible-check dispatch path for that buffer

### Requirement: Idle scheduling coalesces repeated activity

The system SHALL coalesce repeated activity during the idle delay into one
scheduled visible check per buffer.

#### Scenario: Consecutive edits reuse one scheduled timer

- **WHEN** multiple edits occur in the same `proofread-mode` buffer before the
  idle timer fires
- **THEN** proofread keeps a single pending scheduled check for that buffer
- **AND** proofread does not create one backend dispatch per edit
- **AND** the scheduled visible check runs once after the idle delay when the
  buffer is still eligible

#### Scenario: Activity after idle callback can schedule again

- **WHEN** a scheduled visible check has already run for a buffer
- **AND** later editing or window activity occurs in that buffer
- **THEN** proofread marks the buffer pending again
- **AND** proofread schedules or reuses an idle timer for the later work

### Requirement: Idle scheduling respects mode lifecycle

The system SHALL not process scheduled work for killed buffers or buffers where
`proofread-mode` is no longer enabled.

#### Scenario: Disabling mode clears pending work

- **WHEN** `proofread-mode` is disabled in a buffer with pending scheduled work
- **THEN** proofread clears that buffer's pending work state
- **AND** proofread cancels or invalidates the buffer's idle timer
- **AND** the disabled buffer is not processed by that scheduled work later

#### Scenario: Idle callback ignores killed buffer

- **WHEN** an idle timer callback runs after its target buffer has been killed
- **THEN** proofread drops the scheduled work
- **AND** proofread does not signal an error
- **AND** proofread does not recreate proofread-owned state for the killed
  buffer

#### Scenario: Idle callback rechecks mode state

- **WHEN** an idle timer callback runs for a live buffer where `proofread-mode`
  is no longer enabled
- **THEN** proofread drops the scheduled work
- **AND** proofread does not invoke the visible-check dispatch path
- **AND** proofread does not create backend requests for that buffer
