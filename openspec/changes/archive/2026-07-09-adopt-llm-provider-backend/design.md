## Context

Proofread already has a chunk-oriented backend protocol, request tracking, stale
result rejection, diagnostic cache, JSON diagnostic parsing, overlays,
navigation, and manual application. The direct Ollama backend added the first
real model path, but it also made proofread responsible for HTTP transport,
provider-specific endpoint/model/options configuration, timeout behavior, and
response buffer cleanup.

GNU ELPA's `llm` package provides a provider abstraction for Emacs Lisp
applications that need LLMs. It includes provider modules such as Ollama and
OpenAI-compatible services, asynchronous chat calls, JSON response-format
support, a provider error hierarchy, cancellation hooks, model/provider naming,
and a development log. Proofread should use that provider boundary rather than
expanding provider-specific code.

The safety boundary does not move to `llm`. Proofread must still treat model
output as untrusted: diagnostic locations must be chunk-relative, original text
must match exactly, and stale request validation must run before overlays or
cache writes.

## Goals / Non-Goals

**Goals:**

- Introduce a `llm` backend that fits the existing proofread backend protocol.
- Let users configure model/provider details with `llm` provider objects.
- Use `llm-chat-async` for asynchronous completion.
- Use `llm-make-chat-prompt` to build the proofreading prompt and request JSON
  output where supported.
- Reuse proofread's existing JSON diagnostic parser, stale rejection, cache, and
  overlay application path.
- Define a stable cache identity for `llm` providers without storing provider
  objects or secrets in cache keys.
- Keep the direct Ollama backend available during the transition.
- Keep tests offline by stubbing `llm` calls or using fake providers.

**Non-Goals:**

- No removal of the direct Ollama backend in this change.
- No streaming diagnostics or incremental UI.
- No new diagnostic schema beyond the existing JSON contract.
- No real network, real Ollama daemon, or real model calls in tests.
- No proofread-owned provider-specific model variables for new integrations.
- No automatic provider setup UI or model picker.

## Decisions

- Add `llm` as a dependency and require only the generic client surface.

  Proofread should depend on the generic `llm` package for provider structs,
  prompt construction, async chat, cancellation, names, and errors. Users remain
  responsible for requiring provider-specific modules, such as `llm-ollama`, and
  constructing the provider object they want proofread to use.

- Use `proofread-llm-provider` as the user-facing provider entry point.

  A single provider variable keeps proofread out of provider-specific model and
  endpoint configuration. For example, a user can set it to an Ollama provider
  configured with `make-llm-ollama`, or later to an OpenAI-compatible provider
  without proofread adding new endpoint/model custom variables.

- Keep `proofread-backend` as the dispatch selector.

  `proofread-backend` should accept `llm` as a supported backend value. This
  preserves the existing backend protocol and lets the direct `ollama` backend
  stay available as a legacy transition path.

- Build a provider-independent proofreading prompt.

  The prompt text should remain proofread-owned because it defines the
  diagnostic contract. `llm-make-chat-prompt` should receive the prompt text and
  a JSON `response-format` or JSON schema when available. This is an output
  shaping hint only; proofread must still parse and validate the returned text.

- Convert `llm` callbacks to proofread backend results.

  `llm-chat-async` success callbacks should produce proofread success results
  only after parsing the returned text into validated diagnostics. Error
  callbacks should produce proofread backend error results. Both paths should go
  through the existing wrapped callback so active request cleanup and stale
  rejection behavior remain centralized.

- Reuse the existing JSON diagnostic parser by generalizing names or wrappers.

  The current parser was introduced for Ollama responses, but its real contract
  is provider-independent: parse one JSON diagnostic payload, validate
  chunk-relative ranges and exact text, preserve valid suggestions, and drop
  unsafe candidates. Implementation can keep compatibility wrappers for direct
  Ollama while exposing provider-neutral helpers for the `llm` backend.

- Use stable provider identity for cache keys.

  Cache keys must not contain provider objects, API keys, callbacks, buffers,
  live process handles, request ids, or timers. A helper should derive stable
  identity from safe data such as an explicit `proofread-llm-provider-id`, the
  value returned by `llm-name`, and proofread prompt/configuration versions. If
  the identity cannot be derived safely, users must have a way to provide an
  explicit cache identity string or sexp.

- Keep direct Ollama as legacy until a follow-up removal/deprecation change.

  Removing direct Ollama in the same change would mix provider migration with a
  breaking cleanup. Keeping it allows side-by-side debugging and gives users a
  rollback path if the `llm` adapter exposes provider-specific issues.

## Risks / Trade-offs

- [Risk] `llm` response-format support varies by provider. -> Mitigation: treat
  response-format as a hint and continue strict proofread parser validation.

- [Risk] Provider object identity may be unstable or may contain secrets. ->
  Mitigation: never put provider objects in cache keys; use safe identity
  helpers and tests that prove provider objects are excluded.

- [Risk] `llm` callbacks run in a buffer context selected by `llm`, not
  necessarily the source buffer. -> Mitigation: proofread results carry the
  original request, and all buffer mutations continue to happen after explicit
  buffer-live, mode, tick, and text validation.

- [Risk] The direct Ollama backend and `llm` backend may diverge in prompts or
  parsing behavior during the transition. -> Mitigation: share the prompt
  contract and parser helpers where practical and keep both paths covered by
  tests.

- [Risk] Adding `llm` increases package closure size and introduces transitive
  dependencies. -> Mitigation: update package metadata and Nix package
  construction explicitly, and keep tests in clean Emacs environments.

## Migration Plan

No user-visible migration is required for existing direct Ollama users because
the `ollama` backend remains available. New recommended configuration should use
`proofread-backend` set to `llm` and `proofread-llm-provider` set to a provider
object from `llm`.

After this change is stable, a follow-up change can decide whether to deprecate
or remove direct Ollama variables and transport helpers.

## Open Questions

- Should proofread require users to set an explicit `proofread-llm-provider-id`,
  or is `llm-name` sufficient as the default cache identity?
- Should the provider identity include `llm` default chat parameters when they
  are introspectable, or should users bump
  `proofread-cache-configuration-version` when provider options change?
- Should direct Ollama documentation immediately move to a legacy section, or
  wait until the `llm` backend has been tested interactively?
