## Why

The package skeleton establishes command and mode entry points, but later
proofreading behavior needs a stable internal data model before overlays,
requests, navigation, and caching can be implemented safely. Adding diagnostic
and buffer-local state structures now prevents later changes from using overlays
as the primary business state.

## What Changes

- Add diagnostic plist helpers for the minimum diagnostic fields.
- Add buffer-local state for diagnostics, overlays, pending ranges, requests,
  and cache.
- Initialize proofread buffer state when `proofread-mode` is enabled.
- Clear only proofread-owned buffer state when `proofread-mode` is disabled.
- Do not create real overlays, schedule requests, or implement cache behavior.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add requirements for diagnostic representation and
  buffer-local proofread state.

## Impact

- Updates `lisp/proofread.el`.
- Adds private helper/state symbols under the `proofread--` namespace.
- Does not change the public command names established by the package skeleton.
- Does not add runtime dependencies, network behavior, timers, or user-visible
  diagnostics.
