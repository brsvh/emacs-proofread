## Why

Proofreading systems produce false positives, and repeatedly showing the same
unwanted diagnostic makes the workflow noisy. A session-local ignore command
lets users dismiss exact diagnostic patterns without introducing persistent
project rules or automatic text changes.

## What Changes

- Implement `proofread-ignore`.
- Add an in-memory ignore list for the current Emacs session.
- Build ignore keys from exact diagnostic text and diagnostic kind.
- Ignore the proofread-owned diagnostic at point.
- Remove the ignored diagnostic's proofread-owned overlay from the current
  buffer.
- Filter ignored diagnostics before creating proofread-owned overlays.
- Keep exact matching conservative: the same text with a different kind is not
  ignored.
- Do not add persistent ignore rules, project-level dictionaries, or word-list
  management.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add session-local diagnostic ignoring and pre-display
  filtering for exact diagnostic text/kind matches.

## Impact

- Affects `lisp/proofread.el` ignore command behavior, diagnostic filtering,
  overlay creation, and in-memory session state.
- Adds ERT coverage in `test/proofread-tests.el` for exact matches, different
  kinds, unrelated diagnostics, overlay removal, and filtering before overlay
  creation.
- Depends on `add-manual-suggestion-application` so ignore uses the same
  diagnostic-at-point and proofread-owned overlay model as the other manual
  diagnostic actions.
- Adds no persistent ignore storage, project dictionary, automatic correction,
  or deletion of foreign overlays.
