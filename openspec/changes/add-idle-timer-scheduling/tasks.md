## 1. Pending Work State

- [ ] 1.1 Add buffer-local pending scheduled-work state for visible
  proofreading.
- [ ] 1.2 Add buffer-local idle timer state associated with the pending buffer.
- [ ] 1.3 Add a helper that marks the current buffer pending and schedules or
  reuses an idle timer.
- [ ] 1.4 Ensure the mark helper is cheap and does not scan visible ranges,
  chunk text, cache entries, or dispatch backend requests.

## 2. Activity Hooks

- [ ] 2.1 Install an edit hook while `proofread-mode` is enabled that marks the
  buffer pending after text changes.
- [ ] 2.2 Install window activity hooks that mark affected live `proofread-mode`
  buffers pending.
- [ ] 2.3 Ensure edit and window hooks do not synchronously call
  `proofread-check-visible` or `proofread-backend-check`.
- [ ] 2.4 Ensure activity outside `proofread-mode` buffers does not schedule
  proofreading work.

## 3. Idle Timer Scheduling

- [ ] 3.1 Schedule one-shot idle timers using `proofread-idle-delay`.
- [ ] 3.2 Reuse an existing live buffer timer when repeated activity occurs
  before the idle callback runs.
- [ ] 3.3 In the timer callback, check `buffer-live-p` before switching to the
  target buffer.
- [ ] 3.4 In the timer callback, re-check that `proofread-mode` is still enabled
  before doing work.
- [ ] 3.5 In the timer callback, drop work when pending state has already been
  cleared.
- [ ] 3.6 Clear pending state and timer state before invoking the visible-check
  dispatch path.

## 4. Mode Lifecycle Cleanup

- [ ] 4.1 Clear pending work state when `proofread-mode` is disabled.
- [ ] 4.2 Cancel or invalidate the buffer's idle timer when `proofread-mode` is
  disabled.
- [ ] 4.3 Ensure a timer firing after mode disable does not invoke visible-check
  dispatch or create backend requests.
- [ ] 4.4 Ensure a timer firing after buffer kill does not signal an error or
  recreate proofread-owned state.

## 5. Tests

- [ ] 5.1 Add ERT coverage that editing marks pending and schedules an idle
  timer.
- [ ] 5.2 Add ERT coverage that editing does not synchronously call backend
  dispatch.
- [ ] 5.3 Add ERT coverage that repeated edits before idle callback coalesce
  into one scheduled visible check.
- [ ] 5.4 Add ERT coverage that later activity after an idle callback can
  schedule a new check.
- [ ] 5.5 Add ERT coverage that window activity marks only live `proofread-mode`
  buffers pending.
- [ ] 5.6 Add ERT coverage that disabling `proofread-mode` clears pending state
  and timer state.
- [ ] 5.7 Add ERT coverage that a stale timer after mode disable does not call
  visible-check dispatch.
- [ ] 5.8 Add ERT coverage that a timer targeting a killed buffer is ignored
  without error.

## 6. Validation

- [ ] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 6.2 Run OpenSpec status or validation for `add-idle-timer-scheduling` and
  confirm the change is apply-ready.
