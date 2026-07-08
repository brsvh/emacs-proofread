## 1. Dispatch Entry Points

- [ ] 1.1 Add an internal dispatch helper that consumes request-ready chunks and
  submits one backend request per chunk.
- [ ] 1.2 Ensure dispatched request plists preserve buffer, range, text,
  context, language, `major-mode`, and modified tick metadata.
- [ ] 1.3 Update `proofread-check-visible` to collect visible ranges, build
  request-ready chunks, and dispatch them through the configured backend.
- [ ] 1.4 Preserve the existing visible-only behavior; do not fall back to
  whole-buffer scanning or whole-buffer dispatch.
- [ ] 1.5 Ensure dispatch is skipped or reported conservatively when no backend
  is available.

## 2. Active Request Lifecycle

- [ ] 2.1 Register active requests in the originating buffer before backend
  dispatch.
- [ ] 2.2 Keep active request state isolated between buffers.
- [ ] 2.3 Remove active request entries after success, error, and stale-result
  callback paths.
- [ ] 2.4 Ensure callbacks for killed buffers do not recreate buffer-local
  proofread state.

## 3. Stale Result Validation

- [ ] 3.1 Add an internal predicate/helper that validates buffer liveness and
  `proofread-mode` state before result application.
- [ ] 3.2 Validate that the current `buffer-chars-modified-tick` matches the
  request snapshot.
- [ ] 3.3 Validate that the request range is still valid in the live buffer.
- [ ] 3.4 Validate that current buffer text at the request range equals the
  request snapshot text.
- [ ] 3.5 Route all backend success results through the stale-result validator
  before recording diagnostics or creating overlays.

## 4. Result Application

- [ ] 4.1 Add a single internal result handler for backend callbacks.
- [ ] 4.2 For fresh successful results, record returned diagnostics in
  proofread-owned diagnostic state.
- [ ] 4.3 For fresh successful results, create proofread-owned overlays for
  returned diagnostics.
- [ ] 4.4 For backend error results, clear active request state without changing
  buffer text or creating overlays.
- [ ] 4.5 For stale results, leave proofread-owned diagnostic and overlay state
  unchanged.

## 5. Tests

- [ ] 5.1 Add ERT coverage that `proofread-check-visible` dispatches
  request-ready visible chunks through the backend path.
- [ ] 5.2 Add ERT coverage that active request state remains buffer-local across
  multiple buffers.
- [ ] 5.3 Add ERT coverage that a fresh successful result records diagnostics
  and creates proofread-owned overlays.
- [ ] 5.4 Add ERT coverage that a result for a killed buffer is dropped and
  creates no overlays.
- [ ] 5.5 Add ERT coverage that a result after disabling `proofread-mode` is
  dropped and does not mutate proofread-owned state.
- [ ] 5.6 Add ERT coverage that a changed modified tick rejects the result.
- [ ] 5.7 Add ERT coverage that a chunk text mismatch rejects the result.
- [ ] 5.8 Add ERT coverage that stale-result rejection clears the active request
  entry for live buffers.
- [ ] 5.9 Add ERT coverage that backend error results preserve buffer text and
  create no overlays.

## 6. Validation

- [ ] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [ ] 6.2 Run OpenSpec status or validation for
  `add-request-dispatch-stale-rejection` and confirm the change is apply-ready.
