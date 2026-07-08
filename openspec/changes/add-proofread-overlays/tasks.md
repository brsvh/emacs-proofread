## 1. Faces and Overlay Ownership

- [ ] 1.1 Define `proofread-face` and `proofread-current-face` as package-owned
  faces without hard-coded color values.
- [ ] 1.2 Add proofread overlay ownership helpers for category
  `proofread-overlay` and live-overlay checks.
- [ ] 1.3 Add an internal helper that creates an overlay for a diagnostic,
  assigns proofread-owned face/category metadata, stores `proofread-diagnostic`,
  and tracks it in `proofread--overlays`.

## 2. Overlay Lifecycle

- [ ] 2.1 Ensure created overlays remain a display layer while diagnostics stay
  available in `proofread--diagnostics`.
- [ ] 2.2 Add a cheap modification hook that deletes or invalidates only the
  modified proofread-owned overlay.
- [ ] 2.3 Implement `proofread-clear` to delete current-buffer proofread
  overlays and clear proofread overlay state without touching unrelated
  overlays.
- [ ] 2.4 Ensure disabling `proofread-mode` also removes proofread-owned
  overlays through the same cleanup path.

## 3. Validation

- [ ] 3.1 Add ERT coverage that created overlays have category
  `proofread-overlay` and the expected `proofread-diagnostic` property.
- [ ] 3.2 Add ERT coverage that `proofread-clear` deletes proofread overlays but
  preserves unrelated overlays.
- [ ] 3.3 Add ERT coverage that editing text inside a proofread overlay deletes
  or invalidates it without deleting unrelated overlays.
- [ ] 3.4 Run batch load and ERT smoke checks for the proofread package.
