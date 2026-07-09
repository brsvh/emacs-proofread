## Why

Users need a way to move through proofreading diagnostics in the current buffer
before describe, apply, and ignore commands can be useful. Basic next/previous
navigation closes the first interactive loop after diagnostics have been
created.

## What Changes

- Implement `proofread-next` for moving to the next proofread diagnostic after
  point.
- Implement `proofread-previous` for moving to the previous proofread diagnostic
  before point.
- Add diagnostic sorting helpers so navigation order is deterministic.
- Track or derive the current diagnostic and visually distinguish it with
  `proofread-current-face` or equivalent proofread-owned overlay state.
- Use a no-wrap navigation policy: at boundaries, report that there is no next
  or previous diagnostic instead of jumping around.
- Do not add a diagnostics list buffer, global navigation, describe behavior,
  apply behavior, or ignore behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add current-buffer diagnostic navigation and current
  diagnostic highlighting.

## Impact

- Affects `lisp/proofread.el` navigation commands, diagnostic ordering helpers,
  and proofread-owned overlay highlighting.
- Adds ERT coverage in `test/proofread-tests.el` for sorting, next/previous
  movement, no-wrap boundaries, empty diagnostic sets, and current diagnostic
  visual state.
- Depends on `add-diagnostic-cache` so navigation operates on diagnostics
  produced through the finalized diagnostic application/cache path.
- Adds no list UI, project-wide navigation, text mutation, description panel,
  suggestion application, or ignore workflow.
