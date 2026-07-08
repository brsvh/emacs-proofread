## Context

Diagnostics are stored as proofread-owned plist data and displayed with
proofread-owned overlays. After cache and result application are in place, the
buffer can contain diagnostics from backend or cache sources, but users still
need commands to move through them predictably.

This change implements only current-buffer next/previous navigation. It should
use the package-owned diagnostics and overlays already maintained by
`proofread-mode`, without scanning foreign overlays or modifying buffer text.

## Goals / Non-Goals

**Goals:**

- Sort proofread diagnostics deterministically by buffer position.
- Implement `proofread-next` and `proofread-previous` for the current buffer.
- Use a single no-wrap policy for both directions.
- Provide consistent feedback when diagnostics are missing or when navigation
  reaches a boundary.
- Highlight the current diagnostic using `proofread-current-face` or equivalent
  proofread-owned overlay state.
- Keep navigation read-only with respect to buffer text.

**Non-Goals:**

- No diagnostics list buffer.
- No cross-buffer or project-wide navigation.
- No describe, apply, or ignore behavior.
- No automatic backend requests from navigation commands.
- No navigation through diagnostics owned by other packages.

## Decisions

- Navigate over proofread-owned diagnostics, not arbitrary overlays.

  The canonical data is `proofread--diagnostics`; overlays are display objects
  that can be deleted or refreshed. Navigation should sort and select
  diagnostics from the proofread-owned state, then use matching proofread-owned
  overlays only for visual highlighting.

- Sort by beginning position, then end position.

  Sorting by `:beg` and then `:end` gives deterministic behavior for overlapping
  or adjacent diagnostics. Invalid diagnostics with missing or non-position
  ranges should be ignored by navigation helpers rather than causing movement
  errors.

- Use no-wrap navigation.

  `proofread-next` should move only to diagnostics strictly after point, and
  `proofread-previous` should move only to diagnostics strictly before point. At
  boundaries, commands should report there is no next or previous diagnostic
  rather than wrapping. This keeps both directions symmetric and easy to test.

- Highlight exactly one current diagnostic.

  After successful navigation, the selected diagnostic should be visually
  distinguished. Existing proofread overlays should return to `proofread-face`
  and the selected diagnostic's overlay should use `proofread-current-face`, or
  an equivalent proofread-owned marker should produce the same visible state.

- Keep feedback user-visible but non-destructive.

  Empty diagnostic sets and no-wrap boundaries should report a message or
  `user-error` consistently. The commands must not insert, delete, or otherwise
  modify buffer text.

## Risks / Trade-offs

- Diagnostics and overlays can get out of sync -> Navigation should rely on
  diagnostics for movement and use overlay highlighting only when matching
  proofread-owned overlays exist.
- No-wrap can require an extra command after manually moving point backward or
  forward -> The behavior is explicit and avoids surprising jumps.
- Overlapping diagnostics can make "current" ambiguous -> Deterministic sorting
  by `:beg` then `:end` defines the selection order.
- Highlight updates could touch foreign overlays by mistake -> Filter strictly
  by proofread overlay ownership before changing overlay face state.
