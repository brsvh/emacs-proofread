## Context

The package already has a chunk-oriented backend protocol:
`proofread-backend-check` accepts a request plist and completes through an
asynchronous callback. Dispatch code registers active requests, removes them on
completion, rejects stale results, consults the diagnostic cache, and creates
overlays only after validation. The only supported backend today is `mock`.

Ollama exposes a local HTTP API by default at `http://localhost:11434/api` and
the generate endpoint accepts `POST /api/generate` requests. The endpoint can
return non-streaming responses when the request sets `stream` to `false`. This
change should use that non-streaming path so it can fit the existing one-shot
backend callback model.

This change depends on `add-model-aware-backend-configuration`: the Ollama
model, endpoint, and cache-relevant options must participate in backend identity
so changing them does not reuse diagnostics from a previous model.

## Goals / Non-Goals

**Goals:**

- Add `ollama` as a supported backend.
- Add Ollama-specific configuration for base URL, model, options, and timeout.
- Submit asynchronous non-streaming HTTP requests to Ollama's generate endpoint.
- Convert successful transport responses into the existing backend success
  result shape.
- Convert HTTP, parse, connection, timeout, and service errors into existing
  backend error result shape.
- Preserve the existing dispatch, active request cleanup, stale rejection,
  cache, and overlay paths.
- Test Ollama behavior with stubbed HTTP; tests must run without a real Ollama
  daemon or model.

**Non-Goals:**

- No streaming response support.
- No remote authentication or cloud Ollama configuration beyond a configurable
  base URL.
- No OpenAI-compatible endpoint support.
- No CLI or subprocess backend.
- No robust prompt/schema contract, extra-text recovery, or advanced model
  output validation; those belong to `add-ollama-json-diagnostic-contract`.

## Decisions

- Use Emacs built-in HTTP facilities.

  `url-retrieve` should submit Ollama requests asynchronously and invoke a
  sentinel callback when the response buffer arrives. This avoids adding a
  package dependency and keeps backend completion off editing and window hooks.
  The alternative of synchronous `url-retrieve-synchronously` is rejected
  because it can block visible checks and user interaction.

- Use `POST /api/generate` with `stream: false`.

  The generate endpoint matches the current request shape: each proofread chunk
  becomes one prompt and one completion. Setting `stream` to `false` produces a
  single HTTP response that maps directly to one backend callback. Streaming can
  be added later if the UI gains incremental diagnostics or cancellation.

- Keep the default endpoint local.

  `proofread-ollama-base-url` should default to the local Ollama API base URL.
  Users may customize it, but the default must avoid accidentally sending
  visible buffer text to a remote service.

- Build the HTTP payload from request-ready chunks only.

  The backend should use the existing request plist fields, including `:text`,
  `:context-before`, `:context-after`, `:language`, `:major-mode`, and the
  model-aware backend identity. It must not rescan the buffer or bypass
  pre-request filtering.

- Introduce a narrow Ollama response adapter.

  The first backend needs a conversion point from Ollama's JSON response to
  proofread diagnostics. This adapter may handle a simple expected diagnostics
  payload and should report backend errors for malformed transport responses.
  Deeper JSON contract hardening, prompt schema guarantees, and tolerant
  extraction from model prose are explicitly deferred.

- Reuse the existing backend result constructors.

  Ollama success should call the wrapped callback with
  `proofread--backend-success-result`. Ollama failures should call the wrapped
  callback with `proofread--backend-error-result`. This keeps active request
  cleanup and stale rejection behavior consistent with mock and unsupported
  backends.

## Risks / Trade-offs

- [Risk] Local Ollama may be slow or unavailable. -> Mitigation: make timeout
  configurable and convert failures to backend errors that do not modify buffers
  or leave active requests.

- [Risk] `url-retrieve` callback behavior is harder to test than pure mock
  callbacks. -> Mitigation: isolate request construction and response handling
  helpers, and stub the HTTP submit function in ERT.

- [Risk] Model output format may be unreliable before the JSON contract change.
  -> Mitigation: keep this change conservative; malformed model output should
  fail or produce no diagnostics rather than creating unverified overlays.

- [Risk] Remote endpoint customization can leak visible text. -> Mitigation:
  default to localhost and document that changing the base URL sends filtered
  visible chunks and context to that endpoint.

- [Risk] Timeout timers and HTTP callbacks can race. -> Mitigation: ensure
  exactly one backend callback is delivered per request and cleanup
  buffers/timers when either path wins.

## Migration Plan

No data migration is required. Users who do not set `proofread-backend` to
`ollama` keep the existing behavior. Users who enable Ollama must have the
Ollama service running and the configured model installed. Existing in-memory
cache entries remain governed by model-aware backend identity.

## Open Questions

- Should the first default model value be `qwen3:1.7b`, matching the local
  development environment, or a generic nil/default that requires users to set
  `proofread-ollama-model`?
- Should remote Ollama endpoints require an explicit opt-in flag beyond editing
  `proofread-ollama-base-url`?
