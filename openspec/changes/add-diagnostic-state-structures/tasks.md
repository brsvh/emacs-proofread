## 1. Diagnostic Data

- [x] 1.1 Add diagnostic plist helper functions for constructing and reading
  proofread diagnostics.
- [x] 1.2 Ensure diagnostics can represent `:beg`, `:end`, `:text`, `:kind`,
  `:message`, `:suggestions`, `:confidence`, and `:source`.

## 2. Buffer-local State

- [x] 2.1 Add buffer-local variables for diagnostics, overlays, pending ranges,
  requests, and cache.
- [x] 2.2 Initialize proofread-owned buffer-local state when `proofread-mode` is
  enabled.
- [x] 2.3 Clear only proofread-owned buffer-local state when `proofread-mode` is
  disabled.

## 3. Validation

- [x] 3.1 Verify diagnostic helpers preserve all required fields.
- [x] 3.2 Verify enabling `proofread-mode` initializes independent state in
  separate buffers.
- [x] 3.3 Verify disabling `proofread-mode` clears proofread state without
  modifying unrelated buffer-local variables or overlays.
