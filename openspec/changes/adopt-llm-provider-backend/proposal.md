## Why

The current real backend path makes proofread maintain Ollama-specific model,
endpoint, HTTP, timeout, and option handling directly. That duplicates work
already covered by GNU ELPA's `llm` provider abstraction and makes it harder for
users to switch between Ollama, OpenAI-compatible services, local providers, or
remote providers.

This change moves provider and model management behind `llm` while keeping
proofread responsible for proofreading-specific behavior: chunk prompts, JSON
diagnostics, conservative range validation, stale result rejection, caching, and
overlays.

## What Changes

- Add GNU ELPA `llm` as a package dependency.
- Add a `llm` backend choice for `proofread-backend`.
- Add `proofread-llm-provider` for a user-supplied `llm` provider object, such
  as one created with `make-llm-ollama`.
- Dispatch request-ready chunks through `llm-chat-async`.
- Build proofreading prompts with `llm-make-chat-prompt`, using JSON
  `response-format` or a JSON schema when supported.
- Route `llm` success text through the existing JSON diagnostic parser and
  proofread result pipeline.
- Route `llm` errors through the existing backend error result path.
- Add a stable `llm` provider cache identity helper that does not store provider
  objects, API keys, callbacks, buffers, or request handles in cache keys.
- Keep the direct Ollama backend as legacy/transition behavior in this change;
  do not remove it yet.
- Do not add streaming, new UI, real network tests, or provider-specific model
  configuration in proofread.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `proofread-package`: Add a provider-based `llm` backend that supersedes direct
  provider-specific model management for new integrations while reusing
  proofread's existing request, cache, stale rejection, parser, and overlay
  behavior.

## Impact

- Affects `lisp/proofread.el` backend selection, availability checks, backend
  identity/cache helpers, prompt construction, and backend dispatch.
- Affects `test/proofread-tests.el` with offline tests for `llm` provider
  availability, async success, async error, stale rejection, cache identity, and
  JSON parser reuse.
- Affects package metadata and Nix packaging so `llm` and its dependencies are
  available in the clean Emacs test environments.
- Leaves existing direct Ollama public variables and backend behavior in place
  for compatibility during the transition.
