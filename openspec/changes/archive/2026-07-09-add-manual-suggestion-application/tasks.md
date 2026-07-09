## 1. Application Target

- [x] 1.1 Reuse or add a helper that returns the proofread-owned diagnostic at
  point for application.
- [x] 1.2 Add a helper that finds the live proofread-owned overlay associated
  with the target diagnostic.
- [x] 1.3 Ensure application ignores foreign overlays and diagnostics not owned
  by proofread.
- [x] 1.4 Add ERT coverage for target diagnostic and overlay lookup.

## 2. Suggestion Selection

- [x] 2.1 Add a helper that extracts suggestions from a diagnostic as strings in
  stored order.
- [x] 2.2 For a single suggestion, select it after explicit command invocation
  without prompting for a second choice.
- [x] 2.3 For multiple suggestions, prompt with completion and preserve
  suggestion order in candidates.
- [x] 2.4 Report no available suggestion when the diagnostic has no suggestions.
- [x] 2.5 Add ERT coverage for single suggestion, multiple suggestions, and no
  suggestion behavior.

## 3. Pre-Apply Validation

- [x] 3.1 Validate that the target diagnostic range is valid before replacement.
- [x] 3.2 Validate that the target diagnostic still has a live proofread-owned
  overlay.
- [x] 3.3 Validate that current buffer text in the diagnostic range equals the
  diagnostic `:text`.
- [x] 3.4 Refuse application with a clear reason when overlay state is stale.
- [x] 3.5 Refuse application with a clear reason when buffer text mismatches the
  diagnostic original text.
- [x] 3.6 Add ERT coverage for stale overlay and text mismatch rejection.

## 4. Replacement and Undo

- [x] 4.1 Implement `proofread-apply-suggestion` as an interactive command.
- [x] 4.2 Replace only the diagnostic `:beg` to `:end` range with the selected
  suggestion.
- [x] 4.3 Preserve text outside the diagnostic range.
- [x] 4.4 Add explicit undo boundaries so the replacement is a coherent undoable
  change.
- [x] 4.5 Add ERT coverage that undo restores the original diagnostic text.

## 5. Overlay Cleanup

- [x] 5.1 Delete or mark invalid proofread-owned overlays affected by the
  replaced diagnostic range after application.
- [x] 5.2 Ensure stale proofread overlays for the replaced text are not left
  visible.
- [x] 5.3 Preserve unrelated overlays that overlap the replacement range.
- [x] 5.4 Clear current-diagnostic highlighting for invalidated proofread
  overlays when needed.
- [x] 5.5 Add ERT coverage for affected proofread overlay invalidation and
  foreign overlay preservation.

## 6. Non-Automatic Behavior

- [x] 6.1 Ensure diagnostics creation, backend callbacks, cache hits,
  navigation, and description do not apply suggestions automatically.
- [x] 6.2 Keep `proofread-apply-suggestion` as the only text-mutating entry
  point introduced by this change.
- [x] 6.3 Add focused assertions proving non-apply commands leave buffer text
  unchanged.

## 7. Validation

- [x] 7.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [x] 7.2 Run OpenSpec status or validation for
  `add-manual-suggestion-application` and confirm the change is apply-ready.
