## 1. Visible Range Helpers

- [ ] 1.1 Add an internal helper that returns raw visible `(BEG . END)` ranges
  for all live windows displaying the current buffer.
- [ ] 1.2 Add an internal normalization helper that sorts ranges, discards empty
  or invalid ranges, and merges overlapping or adjacent ranges.
- [ ] 1.3 Ensure visible range collection uses window boundaries only and does
  not scan buffer text outside the collected ranges.

## 2. Command Integration

- [ ] 2.1 Update `proofread-check-visible` to collect normalized visible ranges
  for the current buffer.
- [ ] 2.2 Store collected ranges in `proofread--pending-ranges`, replacing any
  previous pending range state for the current buffer.
- [ ] 2.3 Keep `proofread-check-visible` from creating overlays, timers, cache
  entries, diagnostics, backend requests, or whole-buffer work.
- [ ] 2.4 Ensure the no-window case leaves `proofread--pending-ranges` empty
  instead of falling back to the whole buffer.

## 3. Tests

- [ ] 3.1 Add ERT coverage for a single visible window collecting that window's
  visible range.
- [ ] 3.2 Add ERT coverage for multiple windows displaying the same buffer with
  overlapping or adjacent ranges merged and deduplicated.
- [ ] 3.3 Add ERT coverage for a buffer with no live window producing no pending
  ranges.
- [ ] 3.4 Add ERT coverage that `proofread-check-visible` does not create
  overlays, timers, cache entries, diagnostics, or backend requests.

## 4. Validation

- [ ] 4.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 4.2 Run OpenSpec status or validation for `add-visible-region-discovery`
  and confirm the change is apply-ready.
