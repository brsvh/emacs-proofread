## 1. Ignore State and Keys

- [ ] 1.1 Add an in-memory session-local ignore table for proofread diagnostics.
- [ ] 1.2 Add a helper that builds ignore keys from diagnostic `:text` and
  `:kind`.
- [ ] 1.3 Add helper predicates for checking whether a diagnostic is ignored.
- [ ] 1.4 Ensure different text or different kind produces a different ignore
  key.
- [ ] 1.5 Add ERT coverage for exact key match, different text, and different
  kind behavior.

## 2. Ignore Command

- [ ] 2.1 Implement `proofread-ignore` as an interactive command using the
  diagnostic-at-point helper.
- [ ] 2.2 When point is on a proofread-owned diagnostic, record the diagnostic
  ignore key in memory.
- [ ] 2.3 Remove or invalidate the corresponding proofread-owned overlay in the
  current buffer.
- [ ] 2.4 Report a clear no-target message when point is not on a
  proofread-owned diagnostic.
- [ ] 2.5 Ensure `proofread-ignore` does not modify buffer text.

## 3. Overlay and Diagnostic Cleanup

- [ ] 3.1 Remove only proofread-owned overlays whose diagnostics match the
  ignored key.
- [ ] 3.2 Preserve unrelated proofread diagnostics with different text or kind.
- [ ] 3.3 Preserve foreign overlays even when they overlap the ignored
  diagnostic range.
- [ ] 3.4 Clear current-diagnostic highlighting if the current diagnostic is
  ignored.
- [ ] 3.5 Add ERT coverage for overlay removal, unrelated diagnostic
  preservation, and foreign overlay preservation.

## 4. Display Filtering

- [ ] 4.1 Add a helper that filters ignored diagnostics from a diagnostics list.
- [ ] 4.2 Integrate ignored-diagnostic filtering before proofread-owned overlay
  creation.
- [ ] 4.3 Ensure ignored diagnostics from backend results or cache hits do not
  create overlays.
- [ ] 4.4 Ensure diagnostics with same text but different kind remain
  displayable.
- [ ] 4.5 Ensure diagnostics with same kind but different text remain
  displayable.

## 5. Tests

- [ ] 5.1 Add ERT coverage that ignoring a diagnostic removes its current
  proofread-owned overlay.
- [ ] 5.2 Add ERT coverage that the same text and kind is not displayed again in
  the same session.
- [ ] 5.3 Add ERT coverage that different kind with the same text is still
  displayed.
- [ ] 5.4 Add ERT coverage that different text with the same kind is still
  displayed.
- [ ] 5.5 Add ERT coverage that ignoring one diagnostic does not remove
  unrelated diagnostics.
- [ ] 5.6 Add ERT coverage that `proofread-ignore` away from diagnostics reports
  no target and preserves buffer text.

## 6. Validation

- [ ] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 6.2 Run OpenSpec status or validation for `add-ignore-diagnostics` and
  confirm the change is apply-ready.
