## Context

The current backend protocol routes request-ready chunks through
`proofread-backend-check`, records the selected backend in each request, and
uses backend identity as part of diagnostic cache keys. That is enough for the
mock backend, but real model backends need a richer identity. Two Ollama models,
or the same model with a different endpoint or prompt/options, can produce
different diagnostics for the same text.

This change prepares the backend layer for real model integrations without
adding transport. It should preserve the existing cache validation boundary:
cache hits still become diagnostics only after the current buffer text and
request freshness are revalidated.

## Goals / Non-Goals

**Goals:**

- Represent backend identity as stable structured data rather than only a
  backend symbol.
- Include model name, endpoint, prompt version, and relevant options in the
  identity used by cache keys and request metadata.
- Add configuration variables that future real backends can consume.
- Keep `mock` behavior compatible with existing tests and user configuration.
- Make cache invalidation behavior directly testable.

**Non-Goals:**

- No HTTP, CLI, subprocess, authentication, or local model process integration.
- No prompt design, JSON parsing, or diagnostic schema changes.
- No persistent cache or cross-buffer cache sharing.
- No migration of cached entries, since the cache is currently buffer-local and
  in-memory.

## Decisions

- Use a helper for backend identity.

  A dedicated helper should return the canonical identity for the selected
  backend. Cache key construction and request construction should call the same
  helper so dispatch, cache lookup, cache write, and later backend-specific code
  agree on the identity. This avoids duplicating identity rules across the
  request pipeline.

- Keep mock identity simple.

  For `mock`, the helper should continue returning an identity compatible with
  existing behavior, such as `mock`. The alternative of converting mock to a
  structured plist would create churn without making future real backends safer.

- Use structured identity for configurable model backends.

  For future real backends, the identity should be deterministic structured data
  containing the backend name, model name, endpoint, prompt version, and
  relevant options. It must not contain volatile data such as request ids, live
  buffer objects, timers, callbacks, or absolute buffer positions.

- Keep prompt version separate but included.

  `proofread-prompt-version` already invalidates cache entries. Keeping it in
  the identity path makes future prompt-contract changes explicit while
  preserving the existing cache behavior.

- Treat backend options as cache-relevant only when they affect diagnostics.

  Options that can change model output, such as temperature or provider-specific
  generation controls, should be included in identity. Runtime-only controls
  such as timeout should not invalidate diagnostic cache entries unless they can
  affect returned diagnostics.

## Risks / Trade-offs

- [Risk] Backend option identity may be too broad and reduce cache hits. ->
  Mitigation: define a separate cache-relevant options helper so runtime-only
  options can be excluded.

- [Risk] Backend option identity may be too narrow and reuse stale diagnostics.
  -> Mitigation: tests should prove model, endpoint, prompt version, and
  cache-relevant options all produce cache misses when changed.

- [Risk] Structured identities may be harder for users to inspect than symbols.
  -> Mitigation: keep public configuration simple and treat the structured value
  as an internal cache/request identity.

- [Risk] Future backends may need extra identity fields. -> Mitigation: use
  backend-specific identity construction so later changes can extend identity
  without changing the generic cache pipeline.

## Migration Plan

Existing in-memory cache entries are discarded when buffers or mode state are
cleared. No persistent migration is required. During implementation, keep mock
identity compatible so existing cache tests continue to pass while adding new
tests for model-aware identities.

## Open Questions

- Which exact public names should the reserved model, endpoint, and options
  variables use for non-Ollama generic backend configuration?
- Should the first real backend consume generic variables directly, or should
  each backend provide backend-specific aliases that feed the common identity
  helper?
