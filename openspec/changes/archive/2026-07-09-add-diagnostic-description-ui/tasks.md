## 1. Diagnostic Lookup

- [x] 1.1 Add an internal helper that detects whether point is inside a
  diagnostic range.
- [x] 1.2 Add an internal helper that returns the proofread-owned diagnostic at
  point.
- [x] 1.3 Use navigation ordering when multiple proofread-owned diagnostics
  cover point.
- [x] 1.4 Ensure lookup ignores foreign overlays and invalid diagnostic ranges.
- [x] 1.5 Add ERT coverage for diagnostic-at-point lookup and overlap ordering.

## 2. Description Formatting

- [x] 2.1 Add a formatter helper for diagnostic description text.
- [x] 2.2 Include diagnostic kind, message, original text, suggestions,
  confidence, and source when present.
- [x] 2.3 Preserve suggestions in their stored order.
- [x] 2.4 Handle missing optional fields without signaling errors.
- [x] 2.5 Ensure formatting depends only on package-level diagnostic plist
  fields, not backend-private structures.

## 3. Description UI

- [x] 3.1 Implement a simple help-buffer style display for formatted diagnostic
  descriptions.
- [x] 3.2 Ensure displaying the help buffer does not modify the source buffer
  text.
- [x] 3.3 Ensure displaying the help buffer does not mutate source buffer
  diagnostics or overlays.
- [x] 3.4 Keep the UI scoped to the diagnostic at point; do not add a full
  diagnostics list panel.

## 4. Command Behavior

- [x] 4.1 Implement `proofread-describe` as an interactive command using the
  diagnostic-at-point helper.
- [x] 4.2 When point is on a proofread-owned diagnostic, display its formatted
  details.
- [x] 4.3 When point is not on a proofread-owned diagnostic, report that there
  is no proofread diagnostic at point.
- [x] 4.4 Ensure no-diagnostic behavior leaves point and buffer text unchanged.

## 5. Tests

- [x] 5.1 Add ERT coverage that `proofread-describe` displays kind, message,
  original text, confidence, and source for a diagnostic at point.
- [x] 5.2 Add ERT coverage that multiple suggestions display in stable stored
  order.
- [x] 5.3 Add ERT coverage that missing optional fields do not signal errors.
- [x] 5.4 Add ERT coverage that invoking `proofread-describe` away from
  diagnostics reports no diagnostic at point.
- [x] 5.5 Add ERT coverage that describing a diagnostic does not modify source
  buffer text.
- [x] 5.6 Add ERT coverage that describing a diagnostic does not mutate
  proofread-owned diagnostics or overlays.

## 6. Validation

- [x] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [x] 6.2 Run OpenSpec status or validation for `add-diagnostic-description-ui`
  and confirm the change is apply-ready.
