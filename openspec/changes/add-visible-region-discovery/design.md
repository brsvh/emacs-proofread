## Context

The package already has buffer-local state, proofread-owned overlays, and a
placeholder `proofread-check-visible` command. The next useful boundary is to
discover visible text ranges without triggering proofreading requests, so later
chunking can consume a small, user-relevant range set.

The implementation must work when the current buffer is visible in one window,
multiple windows, or no window. It must also keep range discovery cheap: window
metadata is acceptable, but scanning buffer text outside the resulting ranges is
not.

## Goals / Non-Goals

**Goals:**

- Collect visible ranges for the current buffer from all live windows that
  display it.
- Normalize ranges by sorting and merging overlaps or adjacent spans.
- Store the result in `proofread--pending-ranges` when `proofread-check-visible`
  runs.
- Make the no-window case produce no pending ranges rather than falling back to
  the whole buffer.
- Cover single-window, multi-window, and no-window scenarios with ERT tests.

**Non-Goals:**

- No whole-buffer check implementation.
- No backend request dispatch, chunking, cache lookup, timers, or idle
  scheduling.
- No traversal of invisible buffer contents except later configuration-allowed
  context collection, which remains out of scope for this change.
- No window hooks or automatic background range refresh.

## Decisions

- Use live window boundaries as the source of truth.

  The helper should collect windows with `get-buffer-window-list` for the
  current buffer, then read each window's `window-start` and `window-end`. This
  follows what the user can see in Emacs and naturally handles multiple windows
  on the same buffer. The alternative of starting from point or the selected
  window would miss other visible views of the same buffer.

- Normalize ranges as buffer-position cons cells.

  Internal pending range state can use simple `(BEG . END)` spans sorted by
  `BEG`. A small normalization helper should discard empty or invalid spans and
  merge overlapping or adjacent spans. The alternative of preserving one entry
  per window would push duplicate handling into later chunking and scheduling
  code.

- Keep `proofread-check-visible` as collection-only behavior.

  The command should replace `proofread--pending-ranges` with the normalized
  visible range set and report what it collected, but it should not create
  overlays or send requests. The alternative of immediately calling backend or
  chunking code would mix range discovery with later scheduling work and make
  this change harder to validate.

- Treat no-window buffers as having no visible ranges.

  If the current buffer is not displayed in any live window, the helper returns
  nil and the command leaves `proofread--pending-ranges` empty. Falling back to
  the whole buffer would violate the visible-only contract and be dangerous for
  large buffers.

## Risks / Trade-offs

- Window boundary freshness -> Call `window-end` with an update argument so
  Emacs computes a usable end position before the range is recorded.
- Folded, narrowed, or partially redisplayed text can make visible positions
  subtle -> Keep this change limited to Emacs window boundaries and add focused
  tests for the supported cases; later chunking can refine context handling.
- Adjacent windows may be merged into a larger range -> This intentionally
  reduces duplicate scheduling, but it can include a small gap when two visible
  ranges touch exactly at a boundary. Later chunking can split normalized ranges
  by size.
- `proofread--pending-ranges` is current-buffer state -> Helpers that inspect
  multiple windows must not switch buffers for expensive work or mutate state in
  other buffers.
