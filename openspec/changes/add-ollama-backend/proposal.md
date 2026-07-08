## Why

`proofread` has an asynchronous backend protocol and mock backend, but it still
cannot produce diagnostics from a real local model. Adding an Ollama backend
lets users run proofreading through a local model such as `qwen3:1.7b` while
reusing the existing visible-range, filtering, cache, stale rejection, and
overlay pipeline.

## What Changes

- Add `ollama` as a supported `proofread-backend` value.
- Add `proofread-ollama-base-url`, defaulting to the local Ollama API endpoint.
- Add `proofread-ollama-model`, allowing users to select `qwen3:1.7b` or another
  installed model.
- Add `proofread-ollama-options` and timeout configuration.
- Submit non-streaming Ollama `POST /api/generate` requests with
  `stream: false`.
- Convert HTTP success and failure paths into existing backend callback result
  plists.
- Reuse existing request dispatch, active request cleanup, stale rejection,
  cache, and overlay behavior.
- Do not implement streaming responses, remote authentication, OpenAI-compatible
  endpoints, CLI backends, or prompt/parser hardening beyond the minimal
  response conversion needed by this backend.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: The package gains a first real backend named `ollama`
  that can asynchronously submit request-ready chunks to a local Ollama model
  and convert backend outcomes into proofread result plists.

## Impact

- Affects `lisp/proofread.el` backend availability, backend dispatch, Ollama
  configuration, HTTP request construction, response handling, and backend error
  conversion.
- Adds ERT coverage in `test/proofread-tests.el` using stubbed HTTP behavior;
  tests must not require a running Ollama service or model.
- Depends on `add-model-aware-backend-configuration` so model and endpoint
  changes participate in backend identity and cache invalidation.
- Adds no package dependency beyond Emacs built-in HTTP/JSON facilities.
