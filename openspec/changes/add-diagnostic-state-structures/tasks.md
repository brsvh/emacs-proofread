## 1. Diagnostic Data

- [ ] 1.1 Add diagnostic plist helper functions for constructing and reading
  proofread diagnostics.
- [ ] 1.2 Ensure diagnostics can represent `:beg`, `:end`, `:text`, `:kind`,
  `:message`, `:suggestions`, `:confidence`, and `:source`.

## 2. Buffer-local State

- [ ] 2.1 Add buffer-local variables for diagnostics, overlays, pending ranges,
  requests, and cache.
- [ ] 2.2 Initialize proofread-owned buffer-local state when `proofread-mode` is
  enabled.
- [ ] 2.3 Clear only proofread-owned buffer-local state when `proofread-mode` is
  disabled.

## 3. Validation

- [ ] 3.1 Verify diagnostic helpers preserve all required fields.
- [ ] 3.2 Verify enabling `proofread-mode` initializes independent state in
  separate buffers.
- [ ] 3.3 Verify disabling `proofread-mode` clears proofread state without
  modifying unrelated buffer-local variables or overlays.
