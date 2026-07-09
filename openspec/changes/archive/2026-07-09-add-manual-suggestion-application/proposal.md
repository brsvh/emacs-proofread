## Why

Users need a controlled way to turn accepted proofreading suggestions into text
changes. Manual suggestion application completes the loop from diagnostic
discovery to user-approved correction without introducing automatic or bulk
edits.

## What Changes

- Implement `proofread-apply-suggestion`.
- Use the diagnostic at point as the application target.
- Use completion to choose among multiple suggestions.
- Apply a single suggestion only after explicit user command invocation.
- Before replacement, validate that the proofread overlay/diagnostic is still
  current enough to apply and that the buffer text at the diagnostic range still
  equals the diagnostic original text.
- Replace only the diagnostic range with the chosen suggestion.
- Create clear undo boundaries around the replacement.
- Delete or mark affected proofread-owned overlays invalid after replacement.
- Do not add automatic fixing, batch application, or project-wide application.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add manually triggered suggestion application for
  proofread-owned diagnostics at point.

## Impact

- Affects `lisp/proofread.el` suggestion application command, diagnostic
  validation, overlay invalidation, and undo behavior.
- Adds ERT coverage in `test/proofread-tests.el` for single suggestion, multiple
  suggestions, stale overlay rejection, text mismatch rejection, affected
  overlay invalidation, and undo behavior.
- Depends on `add-diagnostic-description-ui` so application uses the same
  diagnostic-at-point model exposed to the user before applying changes.
- Adds no automatic correction, batch apply, global apply, or backend-specific
  application logic.
