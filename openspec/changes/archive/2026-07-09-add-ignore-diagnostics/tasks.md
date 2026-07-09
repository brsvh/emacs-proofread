## 1. Ignore State and Keys

- [x] 1.1 Add an in-memory session-local ignore table for proofread diagnostics.
- [x] 1.2 Add a helper that builds ignore keys from diagnostic `:text` and
  `:kind`.
- [x] 1.3 Add helper predicates for checking whether a diagnostic is ignored.
- [x] 1.4 Ensure different text or different kind produces a different ignore
  key.
- [x] 1.5 Add ERT coverage for exact key match, different text, and different
  kind behavior.

## 2. Ignore Command

- [x] 2.1 Implement `proofread-ignore` as an interactive command using the
  diagnostic-at-point helper.
- [x] 2.2 When point is on a proofread-owned diagnostic, record the diagnostic
  ignore key in memory.
- [x] 2.3 Remove or invalidate the corresponding proofread-owned overlay in the
  current buffer.
- [x] 2.4 Report a clear no-target message when point is not on a
  proofread-owned diagnostic.
- [x] 2.5 Ensure `proofread-ignore` does not modify buffer text.

## 3. Overlay and Diagnostic Cleanup

- [x] 3.1 Remove only proofread-owned overlays whose diagnostics match the
  ignored key.
- [x] 3.2 Preserve unrelated proofread diagnostics with different text or kind.
- [x] 3.3 Preserve foreign overlays even when they overlap the ignored
  diagnostic range.
- [x] 3.4 Clear current-diagnostic highlighting if the current diagnostic is
  ignored.
- [x] 3.5 Add ERT coverage for overlay removal, unrelated diagnostic
  preservation, and foreign overlay preservation.

## 4. Display Filtering

- [x] 4.1 Add a helper that filters ignored diagnostics from a diagnostics list.
- [x] 4.2 Integrate ignored-diagnostic filtering before proofread-owned overlay
  creation.
- [x] 4.3 Ensure ignored diagnostics from backend results or cache hits do not
  create overlays.
- [x] 4.4 Ensure diagnostics with same text but different kind remain
  displayable.
- [x] 4.5 Ensure diagnostics with same kind but different text remain
  displayable.

## 5. Tests

- [x] 5.1 Add ERT coverage that ignoring a diagnostic removes its current
  proofread-owned overlay.
- [x] 5.2 Add ERT coverage that the same text and kind is not displayed again in
  the same session.
- [x] 5.3 Add ERT coverage that different kind with the same text is still
  displayed.
- [x] 5.4 Add ERT coverage that different text with the same kind is still
  displayed.
- [x] 5.5 Add ERT coverage that ignoring one diagnostic does not remove
  unrelated diagnostics.
- [x] 5.6 Add ERT coverage that `proofread-ignore` away from diagnostics reports
  no target and preserves buffer text.

## 6. Validation

- [x] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [x] 6.2 Run OpenSpec status or validation for `add-ignore-diagnostics` and
  confirm the change is apply-ready.
