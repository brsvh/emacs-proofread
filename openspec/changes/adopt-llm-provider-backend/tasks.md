## 1. Dependency and Public Configuration

- [x] 1.1 Add GNU ELPA `llm` to the package dependency metadata.
- [x] 1.2 Add `llm` to the Nix Emacs package/test environments used by the
  flake.
- [x] 1.3 Require the generic `llm` module needed for provider structs, prompt
  construction, async chat, provider names, and request cancellation.
- [x] 1.4 Extend `proofread-backend` customization to include the `llm` backend
  value.
- [x] 1.5 Add `proofread-llm-provider` as the user-supplied `llm` provider
  configuration entry point.

## 2. LLM Provider Identity and Availability

- [x] 2.1 Add a helper that determines whether `proofread-llm-provider` is
  configured enough for the `llm` backend to be available.
- [x] 2.2 Update `proofread-backend-available-p` so the `llm` backend is
  unavailable without a provider and available with one.
- [x] 2.3 Add a stable `llm` provider identity helper for cache keys.
- [x] 2.4 Ensure the `llm` provider identity does not include provider objects,
  API keys, callbacks, buffers, request ids, timers, processes, or other live
  state.
- [x] 2.5 Ensure changes to the stable `llm` provider identity produce cache
  misses for otherwise identical request-ready chunks.

## 3. Provider-Independent Prompt and Parser Reuse

- [x] 3.1 Add provider-independent wrappers for the existing proofreading JSON
  prompt contract.
- [x] 3.2 Build `llm` prompts with `llm-make-chat-prompt` from request text,
  allowed context, language, and `major-mode`.
- [x] 3.3 Request JSON output through `llm` `response-format` or an equivalent
  JSON schema when supported.
- [x] 3.4 Reuse or generalize the existing JSON diagnostic parser so `llm`
  responses and direct Ollama responses share the same safety rules.
- [x] 3.5 Keep chunk-relative offset validation, exact original text matching,
  suggestion order preservation, and conservative invalid-candidate dropping.

## 4. LLM Backend Adapter

- [x] 4.1 Implement `proofread--llm-backend-check` using `llm-chat-async`.
- [x] 4.2 Ensure `proofread--llm-backend-check` never invokes the proofread
  callback inline before returning.
- [x] 4.3 Convert `llm` success callback text into a proofread backend success
  result after JSON diagnostic parsing and validation.
- [x] 4.4 Convert `llm` error callback arguments into a proofread backend error
  result that includes the original request.
- [x] 4.5 Convert unparsable successful `llm` responses into proofread backend
  error results.
- [x] 4.6 Return and store a request handle that can be cancelled through `llm`
  when cancellation is available.
- [x] 4.7 Dispatch `proofread-backend-check` to the new `llm` backend while
  keeping existing `mock`, `ollama`, and unsupported backend behavior.

## 5. Integration With Existing Safety Boundaries

- [x] 5.1 Route `llm` backend results through the existing wrapped callback so
  active request cleanup is shared with other backends.
- [x] 5.2 Ensure stale `llm` results are dropped when the buffer is killed, mode
  is disabled, tick changes, or request text no longer matches.
- [x] 5.3 Ensure accepted fresh `llm` diagnostics create overlays only through
  the existing diagnostic application path.
- [x] 5.4 Ensure fresh successful `llm` diagnostics write to the diagnostic
  cache in chunk-relative form.
- [x] 5.5 Ensure `llm` backend errors do not modify buffer text, create
  overlays, or leave active requests.
- [x] 5.6 Keep the direct Ollama backend and its public configuration variables
  working during this transition.

## 6. Tests

- [x] 6.1 Add ERT coverage for `llm` backend availability with and without
  `proofread-llm-provider`.
- [x] 6.2 Add ERT coverage that `llm` backend dispatch calls `llm-chat-async`
  asynchronously with a prompt built from request fields.
- [x] 6.3 Add ERT coverage that `llm` success responses reuse the JSON
  diagnostic parser and enter the overlay pipeline.
- [x] 6.4 Add ERT coverage that `llm` error callbacks clear active requests and
  preserve buffer text.
- [x] 6.5 Add ERT coverage that unparsable successful `llm` responses create no
  overlays and become backend errors.
- [x] 6.6 Add ERT coverage that stale `llm` results are dropped for killed
  buffers, disabled mode, changed ticks, and text mismatch.
- [x] 6.7 Add ERT coverage that `llm` provider identity changes invalidate cache
  entries.
- [x] 6.8 Add ERT coverage that the raw provider object is not included in cache
  keys.
- [x] 6.9 Add ERT coverage that direct Ollama backend behavior remains
  selectable and independent from `proofread-llm-provider`.

## 7. Validation

- [x] 7.1 Run `openspec status --change "adopt-llm-provider-backend"` and ensure
  artifacts are complete.
- [x] 7.2 Run
  `openspec instructions apply --change "adopt-llm-provider-backend" --json` and
  ensure implementation instructions are available.
- [x] 7.3 Run `nix run .#emacs31-run-proofread-tests`.
- [x] 7.4 Run `nix run .#emacs31-byte-compile-proofread`.
- [x] 7.5 Run `nix run .#emacs30-run-proofread-tests`.
- [x] 7.6 Run `nix run .#emacs30-byte-compile-proofread`.
- [x] 7.7 Run
  `nix fmt -- --fail-on-change lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix`
  or the narrowed equivalent for files changed during implementation.
- [x] 7.8 Run
  `git diff --check -- lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix openspec/changes/adopt-llm-provider-backend`.
