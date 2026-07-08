## Context

The package now has request-ready chunks, a chunk-oriented backend protocol, an
asynchronous mock backend, and buffer-local active request state. The next
boundary is connecting those pieces so `proofread-check-visible` can dispatch
work while still rejecting backend results that no longer match the originating
buffer state.

The first implementation should be conservative. Any buffer edit after request
dispatch invalidates the old result by comparing `buffer-chars-modified-tick`.
The request also records chunk boundaries and text so callbacks can reject
results whose range no longer contains the requested text. This avoids position
remapping until there is a stronger need for it.

## Goals / Non-Goals

**Goals:**

- Dispatch request-ready chunks through `proofread-backend-check`.
- Register active requests before dispatch and clean them up after completion.
- Validate buffer liveness, `proofread-mode`, modified tick, range validity, and
  chunk text before applying successful diagnostics.
- Drop stale success and error results without creating overlays or mutating
  visible proofreading state.
- Keep request tracking isolated by buffer.

**Non-Goals:**

- No complex position remapping after edits.
- No retry, cancellation transport, debounce scheduling, or rate limiting.
- No real backend integration.
- No full-buffer command behavior.
- No advanced diagnostic reconciliation across overlapping chunks.

## Decisions

- Dispatch from request-ready chunks, not paragraph chunks.

  The previous filtering change established request-ready chunks as the input
  boundary before cache/backend work. Dispatch should consume that boundary so
  ignored text is not cached, sent, or later represented in diagnostics.
  Dispatching earlier paragraph chunks would require duplicate filtering checks
  and could accidentally reintroduce skipped text.

- Use request metadata as the stale-result contract.

  Each active request already carries `:buffer`, `:beg`, `:end`, `:text`, and
  `:modified-tick`. The callback validator should compare those fields against
  the live buffer before applying diagnostics. This keeps the rule explicit and
  testable without adding a separate snapshot object.

- Treat any modified tick change as stale.

  The first version should reject all results after any edit, even if the edit
  happened outside the chunk. This may discard usable results, but it prevents
  incorrect overlays and keeps the implementation simple until position mapping
  exists.

- Gate all result application through one internal helper.

  Backend callbacks should remove active request state, then route the result
  through a single stale-check/apply helper. That helper should be the only
  place where diagnostics from backend results can alter
  `proofread--diagnostics` or create overlays. Tests can then assert stale
  results have no visible effect.

- Drop stale results silently.

  Stale results are expected during normal editing, mode disabling, and buffer
  killing. Reporting each stale result would be noisy. The helper can return an
  internal status for tests, but user-visible messages should not be required.

## Risks / Trade-offs

- Conservative tick rejection may discard valid diagnostics after unrelated
  edits -> Accept for the first version; later position mapping can narrow the
  invalidation policy.
- Timer callbacks may run after buffers are killed -> Always check
  `buffer-live-p` before switching buffers or mutating state.
- Disabling `proofread-mode` clears buffer-local state while requests are still
  in flight -> Callbacks must re-check mode state and drop results without
  recreating state.
- Diagnostics from the mock backend may be empty -> Tests should also use
  protocol-shaped diagnostics to verify fresh-result application separately from
  mock default behavior.
