## Why

`proofread-mode` needs a minimal, loadable Emacs Lisp package entry point before
diagnostic state, overlays, timers, requests, and backend behavior can be added
incrementally. Establishing the skeleton first keeps later changes small and
reviewable, and gives all follow-up work a stable public command surface.

## What Changes

- Add `lisp/proofread.el` as the initial package file.
- Define the `proofread` customization group and basic user options.
- Define buffer-local `proofread-mode`.
- Add placeholder interactive commands for the public command names.
- Ensure enabling the mode has no expensive or visible side effects.
- Do not add overlays, timers, requests, cache behavior, or real proofreading.

## Capabilities

### New Capabilities

- `proofread-package`: Loadable package skeleton, buffer-local minor mode entry
  point, and public command surface for future proofreading behavior.

### Modified Capabilities

None.

## Impact

- Adds `lisp/proofread.el`.
- Establishes the public symbols later changes will extend: `proofread-mode`,
  `proofread-check-visible`, `proofread-check-buffer`, `proofread-next`,
  `proofread-previous`, `proofread-describe`, `proofread-apply-suggestion`,
  `proofread-ignore`, and `proofread-clear`.
- Adds no runtime dependency, network behavior, background work, or user-visible
  diagnostics.
