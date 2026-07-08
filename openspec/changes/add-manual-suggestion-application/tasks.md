## 1. Application Target

- [ ] 1.1 Reuse or add a helper that returns the proofread-owned diagnostic at
  point for application.
- [ ] 1.2 Add a helper that finds the live proofread-owned overlay associated
  with the target diagnostic.
- [ ] 1.3 Ensure application ignores foreign overlays and diagnostics not owned
  by proofread.
- [ ] 1.4 Add ERT coverage for target diagnostic and overlay lookup.

## 2. Suggestion Selection

- [ ] 2.1 Add a helper that extracts suggestions from a diagnostic as strings in
  stored order.
- [ ] 2.2 For a single suggestion, select it after explicit command invocation
  without prompting for a second choice.
- [ ] 2.3 For multiple suggestions, prompt with completion and preserve
  suggestion order in candidates.
- [ ] 2.4 Report no available suggestion when the diagnostic has no suggestions.
- [ ] 2.5 Add ERT coverage for single suggestion, multiple suggestions, and no
  suggestion behavior.

## 3. Pre-Apply Validation

- [ ] 3.1 Validate that the target diagnostic range is valid before replacement.
- [ ] 3.2 Validate that the target diagnostic still has a live proofread-owned
  overlay.
- [ ] 3.3 Validate that current buffer text in the diagnostic range equals the
  diagnostic `:text`.
- [ ] 3.4 Refuse application with a clear reason when overlay state is stale.
- [ ] 3.5 Refuse application with a clear reason when buffer text mismatches the
  diagnostic original text.
- [ ] 3.6 Add ERT coverage for stale overlay and text mismatch rejection.

## 4. Replacement and Undo

- [ ] 4.1 Implement `proofread-apply-suggestion` as an interactive command.
- [ ] 4.2 Replace only the diagnostic `:beg` to `:end` range with the selected
  suggestion.
- [ ] 4.3 Preserve text outside the diagnostic range.
- [ ] 4.4 Add explicit undo boundaries so the replacement is a coherent undoable
  change.
- [ ] 4.5 Add ERT coverage that undo restores the original diagnostic text.

## 5. Overlay Cleanup

- [ ] 5.1 Delete or mark invalid proofread-owned overlays affected by the
  replaced diagnostic range after application.
- [ ] 5.2 Ensure stale proofread overlays for the replaced text are not left
  visible.
- [ ] 5.3 Preserve unrelated overlays that overlap the replacement range.
- [ ] 5.4 Clear current-diagnostic highlighting for invalidated proofread
  overlays when needed.
- [ ] 5.5 Add ERT coverage for affected proofread overlay invalidation and
  foreign overlay preservation.

## 6. Non-Automatic Behavior

- [ ] 6.1 Ensure diagnostics creation, backend callbacks, cache hits,
  navigation, and description do not apply suggestions automatically.
- [ ] 6.2 Keep `proofread-apply-suggestion` as the only text-mutating entry
  point introduced by this change.
- [ ] 6.3 Add focused assertions proving non-apply commands leave buffer text
  unchanged.

## 7. Validation

- [ ] 7.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 7.2 Run OpenSpec status or validation for
  `add-manual-suggestion-application` and confirm the change is apply-ready.
