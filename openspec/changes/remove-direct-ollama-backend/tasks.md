## 1. Generic JSON Diagnostic Contract

- [x] 1.1 Identify `proofread--ollama-*` helpers that implement generic JSON
  diagnostic prompt, response extraction, parsing, candidate validation, and
  diagnostic conversion.
- [x] 1.2 Introduce or rename provider-agnostic JSON diagnostic helper names for
  behavior still used by the `llm` backend.
- [x] 1.3 Update `proofread--llm-success-result` and prompt construction to call
  provider-agnostic JSON diagnostic helpers.
- [x] 1.4 Preserve prompt version, response-format, exact text matching,
  chunk-relative range validation, suggestion ordering, and conservative field
  handling.
- [x] 1.5 Ensure generic JSON helpers do not depend on Ollama response wrapper
  fields such as `"response"`.

## 2. Remove Direct Ollama Public Configuration

- [x] 2.1 Remove `ollama` from the public `proofread-backend` customization
  choices.
- [x] 2.2 Remove direct Ollama defcustoms: `proofread-ollama-base-url`,
  `proofread-ollama-model`, `proofread-ollama-options`, and
  `proofread-ollama-timeout`.
- [x] 2.3 Remove direct Ollama model, endpoint, and options from backend
  identity helper branches.
- [x] 2.4 Confirm the `llm` provider identity still excludes provider objects,
  callbacks, buffers, request ids, processes, timers, and API keys.

## 3. Remove Direct Ollama Transport

- [x] 3.1 Remove Ollama URL generation, payload construction, and prompt wrapper
  functions that are only used by direct HTTP transport.
- [x] 3.2 Remove Ollama `url-retrieve` submission, response buffer parsing, HTTP
  status handling, timeout handling, and response-buffer cleanup helpers.
- [x] 3.3 Remove `proofread--ollama-backend-check`.
- [x] 3.4 Remove the `ollama` branch from `proofread-backend-available-p`.
- [x] 3.5 Remove the `ollama` branch from `proofread-backend-check`, allowing
  explicit `ollama` calls to use the unsupported backend path.
- [x] 3.6 Remove direct Ollama request handle cancellation behavior while
  preserving `llm` cancellation behavior.

## 4. Test Migration

- [x] 4.1 Remove tests that only cover direct Ollama HTTP transport mechanics:
  URL construction, payload submission, unibyte HTTP data, response buffer
  cleanup, HTTP errors, connection errors, and timeout behavior.
- [x] 4.2 Replace direct Ollama availability tests with tests that `ollama` is
  unavailable and unsupported as a direct backend.
- [x] 4.3 Rename reusable JSON diagnostic parser test helpers from
  Ollama-specific names to provider-agnostic names.
- [x] 4.4 Rename JSON parser tests to provider-agnostic names while preserving
  coverage for valid JSON, extra text, non-JSON, malformed JSON, bad offsets,
  text mismatch, mixed valid/invalid candidates, suggestion order, and optional
  field handling.
- [x] 4.5 Ensure `llm` backend tests still verify JSON prompt construction,
  success callback parsing, invalid response errors, stale rejection, cache, and
  overlay pipeline behavior.
- [x] 4.6 Ensure mock backend, cache, stale rejection, diagnostics, overlays,
  suggestion application, ignore, navigation, and chunking tests still pass.

## 5. Documentation and Compatibility Notes

- [x] 5.1 Add or update developer-facing test comments only if needed to explain
  why JSON diagnostics are provider-agnostic.
- [x] 5.2 Ensure any user-visible error or unsupported backend behavior does not
  mention removed `proofread-ollama-*` configuration.
- [x] 5.3 Confirm there are no remaining direct Ollama symbols in
  `lisp/proofread.el` except migration-neutral strings in docs or tests where
  intentional.

## 6. Validation

- [x] 6.1 Run `openspec status --change "remove-direct-ollama-backend"` and
  ensure artifacts are complete.
- [x] 6.2 Run
  `openspec instructions apply --change "remove-direct-ollama-backend" --json`
  and ensure implementation instructions are available.
- [x] 6.3 Run `nix run .#emacs31-run-proofread-tests`.
- [x] 6.4 Run `nix run .#emacs31-byte-compile-proofread`.
- [x] 6.5 Run `nix run .#emacs30-run-proofread-tests`.
- [x] 6.6 Run `nix run .#emacs30-byte-compile-proofread`.
- [x] 6.7 Run
  `nix fmt -- --fail-on-change lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix`
  or the narrowed equivalent for files changed during implementation.
- [x] 6.8 Run
  `git diff --check -- lisp/proofread.el test/proofread-tests.el flake.nix tool/flake-module.nix openspec/changes/remove-direct-ollama-backend`.
