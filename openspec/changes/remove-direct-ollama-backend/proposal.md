## Why

`proofread` now has a generic GNU ELPA `llm` provider backend, so the direct
Ollama HTTP backend is duplicated transport code with separate configuration,
timeout, URL buffer, and cleanup behavior. Removing it keeps model access behind
one provider abstraction while preserving the proofread-specific JSON diagnostic
contract and safety pipeline.

## What Changes

- **BREAKING**: Remove the `ollama` value as a supported direct
  `proofread-backend`.
- Remove direct Ollama user options such as `proofread-ollama-base-url`,
  `proofread-ollama-model`, `proofread-ollama-options`, and
  `proofread-ollama-timeout`.
- Remove direct Ollama HTTP request construction, response buffer handling,
  timeout handling, request cancellation, and backend dispatch code.
- Replace direct Ollama transport tests with generic `llm` backend and JSON
  diagnostic contract tests.
- Preserve the JSON diagnostic prompt, response-format, parser, validation, and
  stale/cache/overlay safety behavior used by the `llm` backend.
- Preserve the `mock` backend and the `llm` backend provider configuration
  surface.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: remove the direct Ollama backend requirements, keep
  provider-based `llm` backend behavior, and make the JSON diagnostic contract
  provider-agnostic instead of direct-Ollama-specific.

## Impact

- Affected code: `lisp/proofread.el`.
- Affected tests: `test/proofread-tests.el`.
- Affected public configuration: direct `proofread-ollama-*` variables and
  `proofread-backend` value `ollama` are removed.
- Migration path: users should configure `proofread-backend` as `llm` and set
  `proofread-llm-provider` with providers such as `make-llm-ollama` or
  `make-llm-deepseek`.
- No new dependency is introduced.
