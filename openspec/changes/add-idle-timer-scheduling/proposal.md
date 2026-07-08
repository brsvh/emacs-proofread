## Why

Editing and window activity can happen many times per second, so proofreading
must not run backend dispatch synchronously in those paths. Idle scheduling lets
the mode coalesce noisy activity and check visible text only after the user
pauses.

## What Changes

- Add buffer-local pending work state for scheduled visible proofreading.
- Add idle timer scheduling based on `proofread-idle-delay`.
- Mark buffers pending from cheap edit and window-activity hooks.
- Coalesce repeated activity inside the idle delay into one scheduled visible
  check.
- Ensure idle callbacks re-check buffer liveness and `proofread-mode` before
  doing work.
- Clear pending work state when `proofread-mode` is disabled.
- Do not add a global multi-buffer queue optimizer.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add idle timer scheduling for visible proofreading work
  after editing and window activity.

## Impact

- Affects `lisp/proofread.el` mode lifecycle, edit/window hooks, pending work
  state, and idle timer callback flow.
- Adds ERT coverage in `test/proofread-tests.el` for no synchronous backend
  dispatch during input, coalescing repeated edits, and cleanup when disabling
  `proofread-mode`.
- Depends on `add-request-dispatch-stale-rejection` so scheduled work can reuse
  the visible-check dispatch and stale-result rejection path.
- Adds no real backend, global multi-buffer scheduler, or cross-buffer queue
  prioritization.
