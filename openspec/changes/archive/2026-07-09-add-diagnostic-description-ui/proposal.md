## Why

Overlays alone show that text has a proofreading issue, but they do not give the
user enough context to decide what to do next. A diagnostic description command
lets users inspect the reason, original text, suggestions, confidence, and
source before later apply or ignore workflows exist.

## What Changes

- Implement `proofread-describe` for the diagnostic at point.
- Add a helper that finds the proofread-owned diagnostic covering point.
- Display diagnostic details in a simple help-buffer style UI.
- Show diagnostic kind, message, original text, suggestions, confidence, and
  source when those fields are present.
- Handle missing optional diagnostic fields without errors.
- Display multiple suggestions in their stored order.
- Do not add a complex diagnostics list panel, batch report, apply command, or
  ignore command behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add current diagnostic description UI for proofread-owned
  diagnostics at point.

## Impact

- Affects `lisp/proofread.el` diagnostic lookup and `proofread-describe` command
  behavior.
- Adds ERT coverage in `test/proofread-tests.el` for describing a diagnostic, no
  diagnostic at point, missing optional fields, multiple suggestions, and source
  buffer preservation.
- Depends on `add-diagnostic-navigation` so description works against the
  current-buffer diagnostic/navigation model.
- Adds no list buffer, batch report, suggestion application, ignore workflow, or
  backend-specific display logic.
