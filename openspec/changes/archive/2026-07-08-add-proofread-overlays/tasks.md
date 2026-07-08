## 1. Faces and Overlay Ownership

- [x] 1.1 Define `proofread-face` and `proofread-current-face` as package-owned
  faces without hard-coded color values.
- [x] 1.2 Add proofread overlay ownership helpers for category
  `proofread-overlay` and live-overlay checks.
- [x] 1.3 Add an internal helper that creates an overlay for a diagnostic,
  assigns proofread-owned face/category metadata, stores `proofread-diagnostic`,
  and tracks it in `proofread--overlays`.

## 2. Overlay Lifecycle

- [x] 2.1 Ensure created overlays remain a display layer while diagnostics stay
  available in `proofread--diagnostics`.
- [x] 2.2 Add a cheap modification hook that deletes or invalidates only the
  modified proofread-owned overlay.
- [x] 2.3 Implement `proofread-clear` to delete current-buffer proofread
  overlays and clear proofread overlay state without touching unrelated
  overlays.
- [x] 2.4 Ensure disabling `proofread-mode` also removes proofread-owned
  overlays through the same cleanup path.

## 3. Validation

- [x] 3.1 Add ERT coverage that created overlays have category
  `proofread-overlay` and the expected `proofread-diagnostic` property.
- [x] 3.2 Add ERT coverage that `proofread-clear` deletes proofread overlays but
  preserves unrelated overlays.
- [x] 3.3 Add ERT coverage that editing text inside a proofread overlay deletes
  or invalidates it without deleting unrelated overlays.
- [x] 3.4 Run batch load and ERT smoke checks for the proofread package.
