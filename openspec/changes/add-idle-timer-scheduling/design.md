## Context

The request-dispatch change makes `proofread-check-visible` the boundary that
collects visible ranges, builds request-ready chunks, dispatches backend work,
and rejects stale results. Calling that boundary directly from editing or window
hooks would put visible range discovery and backend dispatch on hot input paths.

This change introduces a scheduling layer above visible checking. Editing and
window activity should only mark the relevant buffer as pending and ensure an
idle timer exists. The timer callback, running after `proofread-idle-delay`,
revalidates buffer liveness and `proofread-mode` before invoking the visible
check path.

## Goals / Non-Goals

**Goals:**

- Track pending scheduled work per buffer.
- Schedule visible proofreading through `proofread-idle-delay`.
- Keep edit and window hooks cheap: no visible range scan, chunking, cache
  lookup, or backend dispatch in those hooks.
- Coalesce repeated activity before idle time into one scheduled visible check
  per buffer.
- Clear pending state and timers when `proofread-mode` is disabled.
- Ignore killed buffers and buffers where `proofread-mode` is no longer active.

**Non-Goals:**

- No global priority queue or multi-buffer scheduler optimization.
- No request cancellation protocol for already dispatched backend work.
- No full-buffer scheduling.
- No change to stale-result rejection semantics.

## Decisions

- Use buffer-local pending state plus a buffer-associated idle timer.

  A buffer-local pending flag keeps scheduling decisions isolated and easy to
  clear on mode disable. A timer associated with the buffer avoids a global
  queue while still allowing the callback to find the intended buffer. The
  callback must treat the buffer reference as tentative and check
  `buffer-live-p` before switching to it.

- Coalesce by reusing an existing live idle timer.

  When activity marks a buffer pending, scheduling should create a timer only if
  no live timer already exists for that buffer. Repeated edits or scroll events
  before idle time update the same pending state and reuse the timer, producing
  one scheduled check after the idle delay.

- Make activity hooks mark-only.

  Edit hooks and window activity hooks should call a small marker function that
  sets pending state and schedules/reuses the idle timer. They must not call
  `proofread-check-visible`, visible range helpers, chunking helpers, or backend
  dispatch directly.

- Revalidate mode state in the timer callback.

  The callback should drop work if the buffer has been killed, if
  `proofread-mode` is disabled, or if pending state has already been cleared.
  This prevents disabled buffers from being processed by stale timers.

- Clear pending state before running the visible check.

  Clearing first prevents a visible check from being treated as still pending
  while it dispatches backend work. If more activity happens after the callback
  starts, that activity can mark pending again and schedule a later check.

## Risks / Trade-offs

- Per-buffer timers can create more timer objects than a global queue -> Accept
  for the first version because the lifecycle is simpler and scoped.
- Window hooks can be global in shape -> Keep their body limited to identifying
  the affected buffer and marking it pending only when `proofread-mode` is
  active.
- Timers can fire after mode disable or buffer kill -> Always clear timer state
  on disable and re-check buffer liveness/mode state in the callback.
- Coalescing can delay proofreading while the user keeps typing -> This is the
  intended behavior; checking should happen after the user pauses.
