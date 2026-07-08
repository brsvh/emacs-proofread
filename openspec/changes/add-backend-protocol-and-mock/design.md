## Context

The package already has buffer-local request state, a placeholder
`proofread-backend` option, and planned request-ready chunks from
`add-pre-request-filtering`. The next boundary is the backend protocol: a stable
shape for dispatching chunk-level proofreading work and receiving asynchronous
results.

This change should define the protocol and a mock backend only. It should not
add network, subprocess, HTTP, CLI, or local model integration.

## Goals / Non-Goals

**Goals:**

- Define `proofread-backend` as the selected backend.
- Define `proofread-backend-available-p` and `proofread-backend-check`.
- Define a request plist that is region/chunk-oriented rather than word-level.
- Define callback result formats for success diagnostics and errors.
- Track active requests and remove them after both success and error callbacks.
- Provide an asynchronous mock backend for UI and scheduling tests.
- Ensure backend errors do not modify buffer text.

**Non-Goals:**

- No real HTTP backend.
- No CLI or subprocess backend.
- No local model backend.
- No authentication, transport retry, streaming, or rate limiting.
- No UI rendering of backend results beyond preserving returned diagnostics for
  later changes.

## Decisions

- Use plists for backend requests and callback results.

  Requests should include `:id`, `:buffer`, `:beg`, `:end`, `:text`,
  `:context-before`, `:context-after`, `:language`, `:major-mode`, and
  `:modified-tick`. Success callback results should include `:status 'ok`,
  `:request`, and `:diagnostics`; error results should include `:status 'error`,
  `:request`, `:error`, and optional `:message`. This matches the package's
  existing diagnostic plist style and avoids introducing structs before the
  protocol settles.

- Keep backend functions generic over backend symbols.

  `proofread-backend-available-p` and `proofread-backend-check` should accept a
  backend argument, defaulting at dispatch sites to `proofread-backend`. For the
  first implementation, the supported built-in backend is the mock backend.
  Later changes can dispatch to additional backend implementations without
  changing request or callback shapes.

- Make callbacks the only backend completion channel.

  `proofread-backend-check` should submit one request and return a request
  handle or id while invoking the supplied callback asynchronously on both
  success and error. It should not return diagnostics synchronously. This
  prevents mock behavior from hiding ordering issues that real backends will
  have.

- Use an Emacs timer for the mock backend.

  The mock backend should use `run-at-time` or an equivalent timer-based path to
  call the callback after the current call stack. Its default success result can
  return an empty diagnostic list, with test hooks or request fields allowing an
  error result to be exercised. A synchronous mock would be easier, but it would
  not test the asynchronous request lifecycle.

- Clean active request state in the callback wrapper.

  Dispatch should register active requests before calling the backend, wrap the
  backend callback, and remove the active request for both `ok` and `error`
  results before handing the result to caller-provided behavior. This keeps
  stale active requests from surviving backend failures.

## Risks / Trade-offs

- Mock behavior may diverge from future real backends -> Keep the mock limited
  to protocol timing and result shape, not model behavior.
- Error shape can grow later -> Use a minimal plist with `:error` and optional
  `:message` so callers can handle failures without depending on transport
  details.
- Timers can make tests more complex -> Use a short timer delay and tests that
  wait for callback completion rather than assuming synchronous execution.
- Request ids must be stable enough for cleanup -> Generate per-request ids and
  store active request entries by id or in a list containing that id.
