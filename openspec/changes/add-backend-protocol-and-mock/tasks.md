## 1. Backend Protocol Data

- [x] 1.1 Define the request plist fields for chunk-level backend requests:
  `:id`, `:buffer`, `:beg`, `:end`, `:text`, `:context-before`,
  `:context-after`, `:language`, `:major-mode`, and `:modified-tick`.
- [x] 1.2 Add an internal helper that builds backend requests from request-ready
  chunks without reducing them to word-level requests.
- [x] 1.3 Define success callback result plists with `:status`, `:request`, and
  `:diagnostics`.
- [x] 1.4 Define error callback result plists with `:status`, `:request`,
  `:error`, and optional `:message`.

## 2. Backend Dispatch API

- [x] 2.1 Update `proofread-backend` documentation/type to represent the
  selected backend used for request dispatch.
- [x] 2.2 Add `proofread-backend-available-p` for checking whether a backend can
  accept proofreading requests.
- [x] 2.3 Add `proofread-backend-check` for submitting one request and invoking
  an asynchronous callback.
- [x] 2.4 Ensure unsupported backends report unavailable or fail through the
  error callback without modifying buffer text.

## 3. Active Request Lifecycle

- [x] 3.1 Register active request state before backend dispatch.
- [x] 3.2 Wrap backend callbacks so successful completions remove the active
  request before caller-visible handling.
- [x] 3.3 Wrap backend callbacks so error completions remove the active request
  before caller-visible handling.
- [x] 3.4 Ensure backend error callbacks do not modify buffer text or leave
  stale request entries.

## 4. Mock Backend

- [x] 4.1 Add a built-in mock backend that reports available.
- [x] 4.2 Implement mock successful completion through an Emacs timer so the
  callback is not invoked inline.
- [x] 4.3 Implement mock error completion through the same asynchronous path.
- [x] 4.4 Keep mock diagnostics simple and protocol-shaped, without pretending
  to be a real model backend.

## 5. Tests

- [x] 5.1 Add ERT coverage that backend request plists contain buffer, range,
  text, context, language, `major-mode`, and modified tick fields.
- [x] 5.2 Add ERT coverage that mock backend success callback is asynchronous
  and returns a success result with diagnostics.
- [x] 5.3 Add ERT coverage that mock backend error callback is asynchronous and
  returns an error result.
- [x] 5.4 Add ERT coverage that successful callbacks clear active request state.
- [x] 5.5 Add ERT coverage that error callbacks preserve buffer text and clear
  active request state.

## 6. Validation

- [x] 6.1 Run the project proofread ERT test package through the flake-provided
  Emacs test command.
- [x] 6.2 Run OpenSpec status or validation for `add-backend-protocol-and-mock`
  and confirm the change is apply-ready.
