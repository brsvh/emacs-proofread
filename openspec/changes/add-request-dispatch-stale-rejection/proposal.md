## Why

Asynchronous backend results can arrive after the originating buffer has
changed, been killed, or had `proofread-mode` disabled. Dispatch and stale
result rejection are needed now so later UI and scheduling work cannot apply
diagnostics to the wrong buffer state.

## What Changes

- Dispatch request-ready chunks through the backend protocol.
- Track active backend requests by buffer while they are in flight.
- Preserve request metadata needed for conservative stale-result validation:
  buffer, mode state, modified tick, chunk boundaries, and chunk text.
- Validate backend callbacks before applying diagnostics or mutating
  proofread-owned buffer state.
- Drop results when the buffer is killed, `proofread-mode` is disabled, the
  buffer modified tick changed, or the chunk text no longer matches.
- Do not implement complex position remapping for edited buffers.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add request dispatch from request-ready chunks and
  conservative stale-result rejection for asynchronous backend callbacks.

## Impact

- Affects `lisp/proofread.el` request dispatch, callback validation, active
  request cleanup, and diagnostic application boundaries.
- Adds ERT coverage in `test/proofread-tests.el` for killed buffers, disabled
  mode, modified ticks, text mismatch, and successful fresh results.
- Depends on `add-backend-protocol-and-mock` for request/result shapes and the
  asynchronous mock backend.
- Adds no real HTTP, CLI, local model backend, retry logic, or position
  remapping.
