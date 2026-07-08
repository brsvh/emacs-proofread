## 1. Configuration

- [ ] 1.1 Audit current backend selection, backend identity, request dispatch,
  and cache code in `lisp/proofread.el`.
- [ ] 1.2 Add `ollama` to the accepted `proofread-backend` customization
  choices.
- [ ] 1.3 Add `proofread-ollama-base-url` with a localhost Ollama API default.
- [ ] 1.4 Add `proofread-ollama-model` for selecting the Ollama model.
- [ ] 1.5 Add `proofread-ollama-options` and `proofread-ollama-timeout`
  configuration.
- [ ] 1.6 Connect Ollama configuration to the model-aware backend identity from
  `add-model-aware-backend-configuration`.

## 2. Request Construction

- [ ] 2.1 Add an Ollama URL helper that builds the `/api/generate` endpoint from
  `proofread-ollama-base-url`.
- [ ] 2.2 Add an Ollama payload helper that includes model, prompt, options, and
  `stream: false`.
- [ ] 2.3 Ensure the payload is built from request plist text, context,
  language, and mode metadata rather than rescanning the buffer.
- [ ] 2.4 Ensure only request-ready filtered text and allowed context reach the
  Ollama payload.
- [ ] 2.5 Add JSON encoding helpers using Emacs built-in JSON support.

## 3. HTTP Transport

- [ ] 3.1 Implement an asynchronous Ollama submit helper using Emacs built-in
  HTTP facilities.
- [ ] 3.2 Ensure `proofread-backend-check` returns before the Ollama callback is
  invoked.
- [ ] 3.3 Add timeout handling that delivers exactly one backend result.
- [ ] 3.4 Ensure HTTP response buffers and timeout timers are cleaned up.
- [ ] 3.5 Convert connection failures and transport-level errors to backend
  error results.

## 4. Response Handling

- [ ] 4.1 Add an Ollama response parser for successful non-streaming generate
  responses.
- [ ] 4.2 Add a narrow adapter from a valid Ollama response payload to existing
  proofread diagnostic plists.
- [ ] 4.3 Convert HTTP status errors to backend error results.
- [ ] 4.4 Convert invalid JSON or malformed Ollama response bodies to backend
  error results.
- [ ] 4.5 Preserve existing stale result validation before any Ollama diagnostic
  creates an overlay.

## 5. Backend Integration Tests

- [ ] 5.1 Add ERT coverage that `ollama` is accepted by backend availability
  when required configuration is present.
- [ ] 5.2 Add ERT coverage that missing model configuration makes `ollama`
  unavailable.
- [ ] 5.3 Add ERT coverage that Ollama request payload includes configured
  model, filtered text, options, and `stream: false`.
- [ ] 5.4 Add ERT coverage that Ollama backend callbacks are asynchronous.
- [ ] 5.5 Add ERT coverage for successful Ollama responses producing proofread
  diagnostics.
- [ ] 5.6 Add ERT coverage that fresh Ollama diagnostics enter the existing
  overlay pipeline.
- [ ] 5.7 Add ERT coverage for HTTP error responses preserving buffer text and
  clearing active requests.
- [ ] 5.8 Add ERT coverage for connection failures preserving buffer text and
  clearing active requests.
- [ ] 5.9 Add ERT coverage for timeout behavior preserving buffer text and
  clearing active requests.
- [ ] 5.10 Add ERT coverage for invalid Ollama responses preserving buffer text
  and clearing active requests.
- [ ] 5.11 Ensure all Ollama tests stub HTTP behavior and do not require a real
  Ollama service or model.

## 6. Validation

- [ ] 6.1 Run the batch ERT command for Emacs 30 and confirm it passes.
- [ ] 6.2 Run the batch ERT command for Emacs 31 and confirm it passes.
- [ ] 6.3 Run byte-compilation validation for `lisp/proofread.el`.
- [ ] 6.4 Run formatting validation for changed files.
- [ ] 6.5 Run `openspec status --change "add-ollama-backend"` and confirm the
  change is complete.
- [ ] 6.6 Run `openspec instructions apply --change "add-ollama-backend" --json`
  and confirm the apply workflow is ready.
- [ ] 6.7 Run `git diff --check -- openspec/changes/add-ollama-backend` and
  confirm there are no whitespace errors in the change artifacts.
