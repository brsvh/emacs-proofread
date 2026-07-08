## Why

`proofread-check-visible` should start from the text the user is actually
viewing, not from an implicit whole-buffer scan. Adding visible range discovery
now gives later chunking and request scheduling work a precise, inexpensive
input range set.

## What Changes

- Add an internal helper that finds visible window ranges for the current
  buffer.
- Normalize the collected ranges by sorting and merging overlapping or adjacent
  ranges, so the same buffer displayed in multiple windows does not duplicate
  work.
- Change `proofread-check-visible` from a placeholder into a command that
  collects visible ranges into proofread-owned pending range state.
- Preserve the current boundary that no backend request, whole-buffer check, or
  chunk scheduling is implemented by this change.
- Avoid expensive text scanning in visible range discovery and window-related
  paths.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: `proofread-check-visible` gains visible range discovery
  behavior and updates pending range state for the current buffer without
  scanning invisible buffer text.

## Impact

- Affects `lisp/proofread.el` visible-range helpers and
  `proofread-check-visible`.
- Adds ERT coverage in `test/proofread-tests.el` for single-window,
  multi-window, and no-window display scenarios.
- Depends on the existing proofread-owned buffer state and overlay groundwork
  from `add-proofread-overlays`.
- Adds no backend dependency, network behavior, timers, or whole-buffer
  proofreading flow.
