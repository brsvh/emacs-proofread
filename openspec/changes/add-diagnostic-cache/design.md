## Context

Idle scheduling means proofread can revisit the same visible text after
scrolling, window changes, or repeated idle callbacks. Without a cache, those
unchanged chunks would be sent to the backend again even when earlier
diagnostics are still valid for the same text and configuration.

The package already has buffer-local cache state, request-ready chunks, backend
dispatch, and stale-result rejection. The cache should sit before backend
dispatch for each request-ready chunk, and cached results should enter the same
validation/application path as fresh backend results.

## Goals / Non-Goals

**Goals:**

- Build deterministic cache keys for request-ready chunks.
- Include chunk text hash, language, `major-mode`, backend identity, prompt
  version, and relevant configuration version data in each cache key.
- Read the cache before backend dispatch and skip backend calls on hits.
- Write the cache only from accepted fresh successful backend results.
- Store diagnostics in a chunk-relative form that does not depend on absolute
  buffer positions.
- Validate current buffer text before applying cached diagnostics.

**Non-Goals:**

- No persistent disk cache.
- No cross-project or cross-Emacs-session cache sharing.
- No global LRU/size limit in the first implementation.
- No cache reuse across different backend names, prompt versions, languages,
  modes, or relevant configuration versions.
- No change to stale-result rejection semantics.

## Decisions

- Use a structured cache key helper.

  A single helper should build keys from normalized inputs so cache read and
  write paths cannot drift. The key should include a hash of the chunk text
  rather than the full text to keep keys compact, while the current request
  still carries full text for validation.

- Include backend and prompt identity in the key.

  Diagnostics depend on the backend and prompt contract, not only on text.
  Changing `proofread-backend`, a prompt version constant/customization, or
  relevant proofreading configuration must create a different key and miss old
  entries.

- Store chunk-relative diagnostics.

  Cache values should not store absolute buffer positions as their canonical
  data. Diagnostics should be converted to offsets relative to the chunk start
  when written, then converted back to absolute ranges for the current request
  only after validation succeeds.

- Treat cache hits as result sources, not validation bypasses.

  A cache hit should produce a protocol-shaped successful result or use the same
  internal result handler as backend success. The handler must still confirm
  buffer liveness, mode state, modified tick/text match as appropriate, and
  current chunk text before recording diagnostics or creating overlays.

- Write the cache after fresh-result acceptance.

  Results rejected as stale must not be cached. Backend errors must not be
  cached. Writing only after fresh-result validation prevents stale diagnostics
  from becoming future cache hits.

## Risks / Trade-offs

- Text hashes can theoretically collide -> Use a stable Emacs hashing function
  plus current text validation before application; collision risk does not
  bypass validation.
- Relative diagnostics require conversion helpers -> Keep conversion narrow and
  test exact offset behavior.
- Configuration versioning can be incomplete -> Start with explicit prompt and
  cache configuration version fields so future filtering/prompt changes have a
  clear invalidation point.
- No size limit can grow memory in long sessions -> Accept initially; add LRU or
  per-buffer size limits in a later change if needed.
