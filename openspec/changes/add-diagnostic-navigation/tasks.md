## 1. Diagnostic Ordering

- [ ] 1.1 Add an internal helper that filters diagnostics to valid navigation
  targets with integer or marker `:beg` and `:end` positions.
- [ ] 1.2 Add an internal helper that sorts proofread-owned diagnostics by
  `:beg` and then `:end`.
- [ ] 1.3 Ensure sorting is deterministic for overlapping diagnostics and
  diagnostics with equal start positions.
- [ ] 1.4 Add ERT coverage for sorting order and invalid-range filtering.

## 2. Navigation Target Selection

- [ ] 2.1 Add an internal helper that finds the nearest diagnostic strictly
  after point for `proofread-next`.
- [ ] 2.2 Add an internal helper that finds the nearest diagnostic strictly
  before point for `proofread-previous`.
- [ ] 2.3 Ensure target selection uses `proofread--diagnostics` and not foreign
  overlays.
- [ ] 2.4 Add ERT coverage for next/previous target selection around point.

## 3. Navigation Commands

- [ ] 3.1 Implement `proofread-next` as an interactive command that moves point
  to the next diagnostic target.
- [ ] 3.2 Implement `proofread-previous` as an interactive command that moves
  point to the previous diagnostic target.
- [ ] 3.3 Use a no-wrap boundary policy for both commands.
- [ ] 3.4 Provide consistent user feedback when no diagnostics exist.
- [ ] 3.5 Provide consistent user feedback at next/previous boundaries.
- [ ] 3.6 Ensure navigation commands do not modify buffer text.

## 4. Current Diagnostic Highlighting

- [ ] 4.1 Add state or helpers for identifying the current diagnostic in the
  current buffer.
- [ ] 4.2 Add a helper that clears previous current highlighting from
  proofread-owned overlays.
- [ ] 4.3 Add a helper that applies `proofread-current-face` or equivalent
  current visual state to the selected diagnostic's proofread-owned overlay.
- [ ] 4.4 Ensure current highlighting does not alter unrelated overlays.
- [ ] 4.5 Ensure disabling `proofread-mode` or clearing overlays removes current
  diagnostic visual state.

## 5. Tests

- [ ] 5.1 Add ERT coverage that `proofread-next` moves to the nearest diagnostic
  after point.
- [ ] 5.2 Add ERT coverage that `proofread-previous` moves to the nearest
  diagnostic before point.
- [ ] 5.3 Add ERT coverage that empty diagnostics leave point unchanged and
  report no target.
- [ ] 5.4 Add ERT coverage that next at the end does not wrap.
- [ ] 5.5 Add ERT coverage that previous at the beginning does not wrap.
- [ ] 5.6 Add ERT coverage that foreign overlays are ignored by navigation.
- [ ] 5.7 Add ERT coverage that navigating marks exactly one proofread-owned
  diagnostic as current.
- [ ] 5.8 Add ERT coverage that navigation preserves buffer text.

## 6. Validation

- [ ] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 6.2 Run OpenSpec status or validation for `add-diagnostic-navigation` and
  confirm the change is apply-ready.
