## Why

Request scheduling and UI behavior need a stable backend contract before real
LLM integrations exist. Defining the backend protocol with an asynchronous mock
backend lets the rest of the proofreading pipeline be developed and tested
without depending on HTTP, CLI, or local model services.

## What Changes

- Define the `proofread-backend` option as the selected backend symbol or object
  used by request dispatch.
- Define the backend functions `proofread-backend-check` and
  `proofread-backend-available-p`.
- Define the request plist fields used for region/chunk-level proofreading.
- Define callback result formats for successful diagnostics and backend errors.
- Add asynchronous mock backend behavior that calls callbacks later rather than
  inline.
- Ensure backend error callbacks do not modify buffer text and do not leave
  active request state behind.
- Do not implement real HTTP, CLI, or local model backends.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add a backend protocol, request/callback data shapes,
  active request cleanup expectations, and an asynchronous mock backend for
  development and tests.

## Impact

- Affects `lisp/proofread.el` backend dispatch helpers, active request state,
  and mock backend implementation.
- Adds ERT coverage in `test/proofread-tests.el` for backend request shape,
  asynchronous mock success callbacks, asynchronous error callbacks, buffer
  preservation, and stale active request cleanup.
- Depends on `add-pre-request-filtering` so backend input is already
  request-ready chunk text.
- Adds no network, subprocess, HTTP, CLI, or local model integration.
